import AppKit
import Combine
import Sparkle
import SwiftUI

enum NanightMenuBarIconState: Equatable {
    case normal
    case idle
    case connecting
    case motion
    case sound
    case motionAndSound
}

final class NanightAppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {
    @MainActor let model = NanightAppModel()
    @MainActor let updater = NanightUpdater()
    @MainActor private let videoInteraction = NanightVideoInteraction()

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var floatingWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var historyWindow: NSWindow?
    private var workspaceObservers: [NSObjectProtocol] = []
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
        updater.start()
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.statusItem = statusItem

        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            #if DEBUG
            statusItem.length = NSStatusItem.variableLength
            button.toolTip = "Nanight (Development)"
            #endif
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

        for name in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.model.interruptObservation() }
            })
        }
        installVideoGestureEventMonitor()
        NanightLog.gesture("BOOT revision=raw-events-v2 pid=\(ProcessInfo.processInfo.processIdentifier) app=\(Bundle.main.bundleURL.path)")
        DispatchQueue.main.async { [weak self] in
            self?.showCamera()
        }
    }

    @MainActor
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showCamera()
        return false
    }

    @MainActor
    private func showCamera() {
        if let popover, popover.isShown {
            NSApp.activate(ignoringOtherApps: true)
            popover.contentViewController?.view.window?.makeKey()
            return
        }

        guard let button = statusItem?.button else { return }
        togglePopover(from: button)
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
        if let floatingWindow {
            NSApp.activate(ignoringOtherApps: true)
            floatingWindow.makeKeyAndOrderFront(nil)
            return
        }

        if let popover, popover.isShown {
            NanightLog.info("Popover toggle closing current popover contentSize=\(popover.contentSize.debugDescription)")
            popover.performClose(sender)
            return
        }

        model.activityExpanded = false
        popoverDebugSequence += 1

        let createdPopover = popover == nil

        if popover == nil {
            let popover = NSPopover()
            popover.behavior = .transient
            popover.contentViewController = NanightCameraHostingController(rootView: cameraView(isFloating: false))
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
    private func cameraView(isFloating: Bool) -> NanightMenuView {
        NanightMenuView(
            model: model,
            videoInteraction: videoInteraction,
            takeScreenshot: { [weak self] in
                guard let self, let window = self.activeVideoView?.window else {
                    throw NanightScreenshotError.windowUnavailable
                }
                return try await NanightScreenshot.save(
                    model: self.model, interaction: self.videoInteraction,
                    pixelScale: window.backingScaleFactor
                )
            },
            isFloating: isFloating,
            toggleFloating: { [weak self] in self?.toggleFloatingWindow() },
            toggleActivity: { [weak self] in self?.toggleActivity() },
            openHistory: { [weak self] in self?.openHistory() }
        )
    }

    @MainActor
    private func toggleActivity() {
        let expanding = !model.activityExpanded
        if expanding {
            let screen = activeVideoView?.window?.screen ?? NSScreen.main
            let cameraHeight = activeVideoView?.bounds.height ?? videoInteraction.viewportSize.height
            let available = (screen?.visibleFrame.height ?? 800) - cameraHeight - 36
            guard available >= 140 else { openHistory(); return }
            model.activityPanelHeight = min(240, available)
        }
        let animate = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        model.activityExpanded = expanding
        updateVideoContainerSize(animated: animate)
        if let window = floatingWindow {
            let delta = model.activityPanelHeight * (expanding ? 1 : -1)
            var frame = window.frame
            frame.origin.y -= delta
            frame.size.height += delta
            window.contentMinSize = NSSize(width: 360, height: 240 + (expanding ? model.activityPanelHeight : 0))
            window.setFrame(frame, display: true, animate: animate)
        }
    }

    @objc @MainActor
    func openHistory() {
        if historyWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: NanightHistoryView(model: model)))
            window.title = "Activity History"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 780, height: 620))
            window.contentMinSize = NSSize(width: 480, height: 380)
            window.center()
            historyWindow = window
        }
        popover?.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)
        historyWindow?.makeKeyAndOrderFront(nil)
    }

    @MainActor
    private var activeVideoView: NSView? {
        if let floatingWindow { return floatingWindow.contentViewController?.view }
        return popover?.isShown == true ? popover?.contentViewController?.view : nil
    }

    @MainActor
    private func toggleFloatingWindow() {
        if let floatingWindow {
            floatingWindow.close()
            return
        }

        let origin = popover?.contentViewController?.view.window?.frame.origin
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: preferredContentSize),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = model.activeCamera?.name ?? "Nanight"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 360, height: 240 + (model.activityExpanded ? model.activityPanelHeight : 0))
        window.contentViewController = NanightCameraHostingController(rootView: cameraView(isFloating: true).ignoresSafeArea())
        window.setContentSize(preferredContentSize)
        window.delegate = self
        floatingWindow = window
        popover?.performClose(nil)
        // The RTMP player connects to one surface. Recreate the popover on its
        // next open so it reconnects after the floating surface is removed.
        popover = nil
        if let origin { window.setFrameOrigin(origin) } else { window.center() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        model.setVideoVisible(true)
    }

    @MainActor
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === floatingWindow else { return }
        floatingWindow = nil
        videoGestureInput.reset()
        model.setVideoVisible(false)
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
        // A pin action transfers the current view to the floating window.
        // Otherwise, dismissing the popover also dismisses its activity section.
        if floatingWindow == nil {
            model.activityExpanded = false
        }
        NanightLog.info("Popover #\(popoverDebugSequence) didClose notificationPopoverShown=\(closedPopover?.isShown == true) storedPopoverShown=\(popover?.isShown == true)")
        videoGestureHeartbeat?.cancel()
        videoGestureHeartbeat = nil
        videoGestureInput.reset()
        settleVideoRotation(animated: false)
        logVideoGestureContext("CLOSE")
        model.setVideoVisible(floatingWindow != nil)
        removeOutsideClickEventMonitors()
        NanightLog.info("Popover #\(popoverDebugSequence) didClose cleanup completed retainedPopover=\(popover != nil)")
    }

    @MainActor
    private var preferredContentSize: NSSize {
        switch model.connectionState {
        case .signedIn, .offline:
            let videoSize = videoInteraction.viewportSize
            return NSSize(width: videoSize.width, height: videoSize.height + (model.activityExpanded ? model.activityPanelHeight : 0))
        case .signedOut, .authExpired, .mfaRequired, .restoring:
            return defaultPopoverContentSize
        }
    }

    @MainActor
    private var videoGesturesAreActive: Bool {
        guard activeVideoView != nil else { return false }
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
            guard let self, let view = self.activeVideoView, let window = view.window else { return event }

            self.gestureEventsReceived += 1
            let sequence = self.gestureEventsReceived
            let phasedTypes: [NSEvent.EventType] = [.magnify, .rotate, .scrollWheel]
            let phase: NSEvent.Phase = phasedTypes.contains(event.type) ? event.phase : []
            let momentum: NSEvent.Phase = event.type == .scrollWheel ? event.momentumPhase : []
            let mouseInWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
            let pointer = view.convert(mouseInWindow, from: nil)
            var cameraBounds = view.bounds
            if self.model.activityExpanded {
                cameraBounds.size.height = max(0, cameraBounds.height - self.model.activityPanelHeight)
                if !view.isFlipped { cameraBounds.origin.y += self.model.activityPanelHeight }
            }
            let inside = cameraBounds.contains(pointer)
            guard inside || self.videoGestureInput.ownsSequence else { return event }
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
            input.anchor = CGPoint(x: location.x - cameraBounds.midX,
                                   y: (location.y - cameraBounds.midY) * (view.isFlipped ? 1 : -1))
            let viewport = self.videoInteraction.viewportSize
            let fitScale = max(0.001, min(cameraBounds.width / viewport.width, cameraBounds.height / viewport.height))
            input.anchor.x /= fitScale
            input.anchor.y /= fitScale
            // These NSEvent accessors are valid only for their corresponding types.
            switch event.type {
            case .magnify: input.magnification = event.magnification
            case .rotate: input.counterclockwiseDegrees = CGFloat(event.rotation)
            case .scrollWheel:
                input.scroll = CGSize(width: event.scrollingDeltaX / fitScale, height: event.scrollingDeltaY / fitScale)
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
        if floatingWindow == nil, model.activityExpanded {
            let available = (statusItem?.button?.window?.screen?.visibleFrame.height ?? 800) - videoInteraction.viewportSize.height - 36
            if available < 140 { model.activityExpanded = false }
            else { model.activityPanelHeight = min(240, available) }
        }
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
        menu.showsStateColumn = false
        menu.addItem(NSMenuItem(title: model.activeCamera?.name ?? "Nanight", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Activity History", action: #selector(openHistory), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Settings", action: #selector(openSettings), keyEquivalent: ","))
        let updateItem = NSMenuItem(title: "Check for Updates…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
        menu.addItem(updateItem)
        menu.addItem(NSMenuItem(title: "Sign Out", action: #selector(signOut), keyEquivalent: ""))
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Nanight", action: #selector(quit), keyEquivalent: "q")
        quitItem.attributedTitle = NSAttributedString(
            string: quitItem.title,
            attributes: [.foregroundColor: NSColor.systemRed]
        )
        menu.addItem(quitItem)

        for item in menu.items {
            item.target = self
            item.image = nil
        }
        updateItem.target = updater.controller

        statusItem?.menu = menu
        sender.performClick(nil)
        statusItem?.menu = nil
    }

    // Use an app-specific selector so macOS does not infer a Settings gear.
    @objc(nanightOpenSettings)
    @MainActor
    func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model, updater: updater)))
            window.title = "Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        popover?.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
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

// The delegate owns camera-container sizing. Inserting history must not also
// change the host's intrinsic/minimum size before the AppKit resize begins.
final class NanightCameraHostingController<Content: View>: NSViewController {
    // Avoid Swift 6.3's optimizer crash in synthesized generic deinitializers.
    // https://github.com/swiftlang/swift/issues/87736
    @inline(never) deinit {}

    init(rootView: Content) {
        super.init(nibName: nil, bundle: nil)
        let host = NSHostingView(rootView: rootView)
        host.sizingOptions = []
        // Keep SwiftUI out of the window-content role. Even with sizingOptions
        // disabled, animated rotation can make a root host recursively resize
        // the popover from windowDidLayout until the main thread overflows.
        let container = NSView(frame: host.frame)
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        view = container
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(rootView:)") }
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
        let icon = symbolImage(named: symbolName(for: state))
            ?? symbolImage(named: "moon")
            ?? NSImage(size: NSSize(width: 18, height: 18))
        #if DEBUG
        if let ladybug = symbolImage(named: "ladybug") {
            let spacing: CGFloat = 5
            let size = NSSize(width: icon.size.width + spacing + ladybug.size.width,
                              height: max(icon.size.height, ladybug.size.height))
            let image = NSImage(size: size, flipped: false) { _ in
                icon.draw(in: NSRect(x: 0, y: (size.height - icon.size.height) / 2,
                                     width: icon.size.width, height: icon.size.height))
                ladybug.draw(in: NSRect(x: icon.size.width + spacing, y: (size.height - ladybug.size.height) / 2,
                                        width: ladybug.size.width, height: ladybug.size.height))
                return true
            }
            image.isTemplate = true
            return image
        }
        #endif
        return icon
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
