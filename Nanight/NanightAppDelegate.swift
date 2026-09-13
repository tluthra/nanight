import AppKit
import Combine
import SwiftUI

enum NanightMenuBarIconState: Equatable {
    case normal
    case idle
    case connecting
    case motion
    case sound
    case motionAndSound
}

final class NanightAppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    @MainActor let model = NanightAppModel()
    @MainActor private let videoInteraction = NanightVideoInteraction()

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var cancellable: AnyCancellable?
    private lazy var videoGestureInput = NanightVideoGestureInput(interaction: videoInteraction)
    private var localVideoGestureEventMonitor: Any?
    private var videoGestureHeartbeat: Task<Void, Never>?
    private var gestureEventsReceived = 0
    private var gestureEventsHandled = 0
    private var localOutsideClickEventMonitor: Any?
    private var globalOutsideClickEventMonitor: Any?
    private var popoverDebugSequence = 0
    private let defaultPopoverContentSize = NSSize(width: 520, height: 320)

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.statusItem = statusItem

        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            button.action = #selector(statusItemClicked(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            updateStatusItem()
        }

        cancellable = model.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in
                self?.updateStatusItem()
            }
        }

        installVideoGestureEventMonitor()
        NanightLog.gesture("BOOT revision=raw-events-v2 pid=\(ProcessInfo.processInfo.processIdentifier) app=\(Bundle.main.bundleURL.path)")
    }

    @MainActor
    private func updateStatusItem() {
        guard let button = statusItem?.button else {
            return
        }

        button.image = NanightMenuBarIconRenderer.image(for: model.menuBarIconState)
        button.contentTintColor = nil
    }

    @objc
    @MainActor
    private func statusItemClicked(_ sender: NSStatusBarButton) {
        NanightLog.info("Popover status item clicked event=\(NSApp.currentEvent?.type.debugNameForNanight ?? "nil") existingPopoverShown=\(popover?.isShown == true)")

        switch NSApp.currentEvent?.type {
        case .rightMouseUp:
            showMenu(from: sender)
        default:
            togglePopover(from: sender)
        }
    }

    @MainActor
    private func togglePopover(from sender: NSStatusBarButton) {
        if let popover, popover.isShown {
            NanightLog.info("Popover toggle closing current popover contentSize=\(popover.contentSize.debugDescription)")
            popover.performClose(sender)
            return
        }

        popoverDebugSequence += 1

        let createdPopover = popover == nil

        if popover == nil {
            let popover = NSPopover()
            popover.behavior = .transient
            popover.contentViewController = NSHostingController(rootView: NanightMenuView(
                model: model,
                videoInteraction: videoInteraction,
                takeScreenshot: { [weak self] in
                    guard let self, let popover = self.popover, popover.isShown,
                          let window = popover.contentViewController?.view.window else {
                        throw NanightScreenshotError.windowUnavailable
                    }
                    return try await NanightScreenshot.save(
                        model: self.model, interaction: self.videoInteraction,
                        pixelScale: window.backingScaleFactor
                    )
                }
            ))
            self.popover = popover
        }

        guard let popover else {
            NanightLog.warning("Popover #\(popoverDebugSequence) toggle skipped because popover creation failed")
            return
        }

        popover.delegate = self
        popover.contentSize = preferredContentSize
        NanightLog.info("Popover #\(popoverDebugSequence) toggle \(createdPopover ? "creating" : "reusing") popover contentSize=\(popover.contentSize.debugDescription) preferredContentSize=\(preferredContentSize.debugDescription) state=\(model.connectionState) viewport=\(videoInteraction.viewportSize.debugDescription)")
        // A menu-bar popover can be visible while Xcode or another app still owns
        // keyboard/gesture focus. Claim focus before asking for trackpad input.
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        logVideoGestureContext("SHOW returned")
        NanightLog.info("Popover #\(popoverDebugSequence) show returned isShown=\(popover.isShown) \(popover.debugWindowDescription)")
    }

    @MainActor
    func popoverDidShow(_ notification: Notification) {
        guard let shownPopover = notification.object as? NSPopover else {
            return
        }

        NanightLog.info("Popover #\(popoverDebugSequence) didShow contentSize=\(shownPopover.contentSize.debugDescription) \(shownPopover.debugWindowDescription)")
        installVideoGestureEventMonitor()
        videoGestureInput.reset()
        gestureEventsReceived = 0
        gestureEventsHandled = 0
        logVideoGestureContext("OPEN revision=raw-events-v2")
        startVideoGestureHeartbeat()
        installOutsideClickEventMonitors(for: shownPopover)
        updateVideoContainerSize(animated: false)
        model.setVideoVisible(true)
        NanightLog.info("Popover #\(popoverDebugSequence) didShow completed \(shownPopover.debugWindowDescription)")
    }

    @MainActor
    func popoverDidClose(_ notification: Notification) {
        let closedPopover = notification.object as? NSPopover
        NanightLog.info("Popover #\(popoverDebugSequence) didClose notificationPopoverShown=\(closedPopover?.isShown == true) storedPopoverShown=\(popover?.isShown == true)")
        videoGestureHeartbeat?.cancel()
        videoGestureHeartbeat = nil
        videoGestureInput.reset()
        settleVideoRotation(animated: false)
        logVideoGestureContext("CLOSE")
        model.setVideoVisible(false)
        removeOutsideClickEventMonitors()
        NanightLog.info("Popover #\(popoverDebugSequence) didClose cleanup completed retainedPopover=\(popover != nil)")
    }

    @MainActor
    private var preferredContentSize: NSSize {
        switch model.connectionState {
        case .signedIn, .offline:
            let videoSize = videoInteraction.viewportSize
            return NSSize(width: videoSize.width, height: videoSize.height)
        case .signedOut, .authExpired, .mfaRequired, .restoring:
            return defaultPopoverContentSize
        }
    }

    @MainActor
    private var videoGesturesAreActive: Bool {
        guard popover?.isShown == true else { return false }
        switch model.connectionState {
        case .signedIn, .offline: return true
        case .signedOut, .authExpired, .mfaRequired, .restoring: return false
        }
    }

    @MainActor
    private func settleVideoRotation(animated: Bool) {
        guard !videoGestureInput.isTransforming else { return }
        let animate = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let before = videoInteraction.diagnosticDescription
        withAnimation(animate ? .easeInOut(duration: NanightVideoInteraction.settlingDuration) : nil) {
            videoInteraction.snapRotation()
        }
        NanightLog.gesture("SNAP animated=\(animate) before={\(before)} after={\(videoInteraction.diagnosticDescription)}")
        updateVideoContainerSize(animated: animate)
    }

    @MainActor
    private func installVideoGestureEventMonitor() {
        guard localVideoGestureEventMonitor == nil else { return }
        let types: NSEvent.EventTypeMask = [.magnify, .rotate, .scrollWheel, .beginGesture, .endGesture, .gesture, .swipe]
        localVideoGestureEventMonitor = NSEvent.addLocalMonitorForEvents(matching: types) { [weak self] event in
            guard let self, let popover = self.popover, popover.isShown,
                  let view = popover.contentViewController?.view, let window = view.window else { return event }

            self.gestureEventsReceived += 1
            let sequence = self.gestureEventsReceived
            let phasedTypes: [NSEvent.EventType] = [.magnify, .rotate, .scrollWheel]
            let phase: NSEvent.Phase = phasedTypes.contains(event.type) ? event.phase : []
            let momentum: NSEvent.Phase = event.type == .scrollWheel ? event.momentumPhase : []
            let mouseInWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
            let pointer = view.convert(mouseInWindow, from: nil)
            let inside = view.bounds.contains(pointer)
            let acceptedWindow = NanightVideoGestureInput.routesToPopover(
                eventWindowNumber: event.windowNumber, popoverWindowNumber: window.windowNumber,
                popoverIsKey: window.isKeyWindow, pointerInside: inside,
                ownsSequence: self.videoGestureInput.ownsSequence
            )
            NanightLog.gesture("RAW #\(sequence) type=\(event.type) phase=\(phase.rawValue) momentum=\(momentum.rawValue) eventWindow=\(event.windowNumber) popoverWindow=\(window.windowNumber) key=\(window.isKeyWindow) appActive=\(NSApp.isActive) pointerInside=\(inside) videoAllowed=\(self.videoGesturesAreActive) route=\(acceptedWindow)")

            guard self.videoGesturesAreActive, acceptedWindow else {
                if !self.videoGesturesAreActive { self.videoGestureInput.reset() }
                NanightLog.gesture("DROP #\(sequence) reason=\(acceptedWindow ? "video inactive" : "window mismatch")")
                return event
            }

            let location = event.windowNumber == window.windowNumber
                ? view.convert(event.locationInWindow, from: nil) : pointer
            var input = NanightVideoGestureEvent(type: event.type, phase: phase, momentumPhase: momentum)
            input.anchor = CGPoint(x: location.x - view.bounds.midX,
                                   y: (location.y - view.bounds.midY) * (view.isFlipped ? 1 : -1))
            // These NSEvent accessors are valid only for their corresponding types.
            switch event.type {
            case .magnify: input.magnification = event.magnification
            case .rotate: input.counterclockwiseDegrees = CGFloat(event.rotation)
            case .scrollWheel:
                input.scroll = CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY)
                input.precise = event.hasPreciseScrollingDeltas
            default: break
            }

            let before = self.videoInteraction.diagnosticDescription
            let result = self.videoGestureInput.handle(input)
            if result.consumed { self.gestureEventsHandled += 1 }
            NanightLog.gesture("APPLY #\(sequence) action=\(result.reason) magnify=\(input.magnification) rotateCCW=\(input.counterclockwiseDegrees) scroll=\(input.scroll) precise=\(input.precise) anchor=\(input.anchor) consumed=\(result.consumed) settle=\(result.settle) before={\(before)} after={\(self.videoInteraction.diagnosticDescription)}")
            if result.settle { self.settleVideoRotation(animated: true) }
            return result.consumed ? nil : event
        }
        NanightLog.gesture("INSTALL revision=raw-events-v2 localMonitor=\(localVideoGestureEventMonitor != nil) types=magnify,rotate,scrollWheel,beginGesture,endGesture,gesture,swipe")
    }

    @MainActor
    private func logVideoGestureContext(_ label: String) {
        let window = popover?.contentViewController?.view.window
        let responder = window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        let pointer = window.map { $0.convertPoint(fromScreen: NSEvent.mouseLocation) } ?? .zero
        NanightLog.gesture("\(label) shown=\(popover?.isShown == true) appActive=\(NSApp.isActive) window=\(window?.windowNumber ?? -1) key=\(window?.isKeyWindow == true) canKey=\(window?.canBecomeKey == true) firstResponder=\(responder) windowFrame=\(window?.frame ?? .zero) viewBounds=\(popover?.contentViewController?.view.bounds ?? .zero) pointerInWindow=\(pointer) received=\(gestureEventsReceived) handled=\(gestureEventsHandled) \(videoInteraction.diagnosticDescription)")
    }

    @MainActor
    private func startVideoGestureHeartbeat() {
        #if DEBUG
        videoGestureHeartbeat?.cancel()
        videoGestureHeartbeat = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self, self.popover?.isShown == true else { return }
                self.logVideoGestureContext("HEARTBEAT")
            }
        }
        #endif
    }

    @MainActor
    private func updateVideoContainerSize(animated: Bool) {
        let nextSize = preferredContentSize

        if let popover {
            if popover.contentSize != nextSize {
                NanightLog.gesture("RESIZE from=\(popover.contentSize) to=\(nextSize) animated=\(animated)")
                NanightLog.info("Popover resize from=\(popover.contentSize.debugDescription) to=\(nextSize.debugDescription) animated=\(animated) shown=\(popover.isShown)")
                // NSPopover already animates contentSize changes. Moving its window
                // separately interrupts that transition and can expose its backing material.
                let previousAnimates = popover.animates
                popover.animates = animated
                popover.contentSize = nextSize
                popover.animates = previousAnimates
                NanightLog.gesture("RESIZE native contentSize=\(popover.contentSize) windowFrame=\(popover.contentViewController?.view.window?.frame ?? .zero)")
            } else {
                NanightLog.info("Popover resize skipped size already \(nextSize.debugDescription) shown=\(popover.isShown)")
            }
        } else {
            NanightLog.info("Popover resize skipped no popover nextSize=\(nextSize.debugDescription)")
        }
    }

    @MainActor
    private func installOutsideClickEventMonitors(for popover: NSPopover) {
        removeOutsideClickEventMonitors()

        let mouseEvents: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

        localOutsideClickEventMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseEvents) { [weak self, weak popover] event in
            guard let self,
                  let popover,
                  popover.isShown
            else {
                return event
            }

            if self.isEventInsidePopover(event, popover: popover) || self.isEventInsideStatusItem(event) {
                return event
            }

            Task { @MainActor in
                self.closePopoverFromOutsideClick()
            }
            return event
        }

        globalOutsideClickEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseEvents) { [weak self, weak popover] _ in
            guard let popover, popover.isShown else {
                return
            }

            Task { @MainActor in
                self?.closePopoverFromOutsideClick()
            }
        }
    }

    private func isEventInsidePopover(_ event: NSEvent, popover: NSPopover) -> Bool {
        guard let contentView = popover.contentViewController?.view,
              let eventWindow = event.window,
              eventWindow === contentView.window
        else {
            return false
        }

        return contentView.bounds.contains(contentView.convert(event.locationInWindow, from: nil))
    }

    private func isEventInsideStatusItem(_ event: NSEvent) -> Bool {
        guard let button = statusItem?.button,
              let eventWindow = event.window,
              eventWindow === button.window
        else {
            return false
        }

        return button.bounds.contains(button.convert(event.locationInWindow, from: nil))
    }

    @MainActor
    private func closePopoverFromOutsideClick() {
        guard let popover, popover.isShown else {
            return
        }

        popover.performClose(nil)
    }

    private func removeOutsideClickEventMonitors() {
        if let localOutsideClickEventMonitor {
            NSEvent.removeMonitor(localOutsideClickEventMonitor)
            self.localOutsideClickEventMonitor = nil
            NanightLog.info("Popover removed local outside click monitor")
        }

        if let globalOutsideClickEventMonitor {
            NSEvent.removeMonitor(globalOutsideClickEventMonitor)
            self.globalOutsideClickEventMonitor = nil
            NanightLog.info("Popover removed global outside click monitor")
        }
    }

    @MainActor
    private func showMenu(from sender: NSStatusBarButton) {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: model.activeCamera?.name ?? "Nanight", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Refresh", action: #selector(refreshAccount), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: model.isAudioMuted ? "Unmute" : "Mute", action: #selector(toggleAudio), keyEquivalent: "m"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Settings", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Sign Out", action: #selector(signOut), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Nanight", action: #selector(quit), keyEquivalent: "q"))

        for item in menu.items {
            item.target = self
        }

        statusItem?.menu = menu
        sender.performClick(nil)
        statusItem?.menu = nil
    }

    @objc
    @MainActor
    private func refreshAccount() {
        Task {
            await model.refreshCameras()
            await model.refreshEvents()
        }
    }

    @objc
    @MainActor
    private func toggleAudio() {
        model.toggleAudio()
    }

    @objc
    @MainActor
    private func openSettings() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    @objc
    @MainActor
    private func signOut() {
        model.signOut()
    }

    @objc
    private func quit() {
        NSApplication.shared.terminate(nil)
    }

}

private extension NSPopover {
    var debugWindowDescription: String {
        guard let contentView = contentViewController?.view else {
            return "contentView=nil"
        }

        guard let window = contentView.window else {
            return "contentViewFrame=\(contentView.frame.debugDescription) window=nil"
        }

        let firstResponder = window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        return "contentViewFrame=\(contentView.frame.debugDescription) windowFrame=\(window.frame.debugDescription) firstResponder=\(firstResponder)"
    }
}

private extension NSEvent.EventType {
    var debugNameForNanight: String {
        switch self {
        case .leftMouseUp:
            return "leftMouseUp"
        case .rightMouseUp:
            return "rightMouseUp"
        case .leftMouseDown:
            return "leftMouseDown"
        case .rightMouseDown:
            return "rightMouseDown"
        default:
            return String(describing: self)
        }
    }
}

private enum NanightMenuBarIconRenderer {
    static func image(for state: NanightMenuBarIconState) -> NSImage {
        symbolImage(named: symbolName(for: state))
            ?? symbolImage(named: "moon")
            ?? NSImage(size: NSSize(width: 18, height: 18))
    }

    private static func symbolName(for state: NanightMenuBarIconState) -> String {
        switch state {
        case .normal:
            return "moon"
        case .idle:
            return "moon.zzz"
        case .connecting:
            return "moon"
        case .motion, .motionAndSound:
            return "moon.haze"
        case .sound:
            return "moon.dust"
        }
    }

    private static func symbolImage(named name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Nanight")
        image?.isTemplate = true
        return image
    }
}
