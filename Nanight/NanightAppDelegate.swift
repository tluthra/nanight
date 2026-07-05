import AppKit
import Combine
import QuartzCore
import SwiftUI

enum NanightMenuBarIconState: Equatable {
    case normal
    case connecting
    case motion
    case sound
    case motionAndSound
}

final class NanightAppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    @MainActor let model = NanightAppModel()

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var cancellable: AnyCancellable?
    private var localOutsideClickEventMonitor: Any?
    private var globalOutsideClickEventMonitor: Any?
    private var localGestureDebugEventMonitor: Any?
    private var popoverDebugSequence = 0
    private var popoverDebugGestureCounts = GestureDebugCounts()
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

        installGestureDebugEventMonitor()
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
        popoverDebugGestureCounts = GestureDebugCounts()

        let createdPopover = popover == nil

        if popover == nil {
            let popover = NSPopover()
            popover.behavior = .transient
            popover.contentViewController = NSHostingController(rootView: NanightMenuView(
                model: model,
                onVideoViewportChange: { [weak self] in
                    Task { @MainActor in
                        NanightLog.info("Popover video viewport callback")
                        self?.updateVideoContainerSize(animated: false)
                    }
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
        NanightLog.info("Popover #\(popoverDebugSequence) toggle \(createdPopover ? "creating" : "reusing") popover contentSize=\(popover.contentSize.debugDescription) preferredContentSize=\(preferredContentSize.debugDescription) state=\(model.connectionState) videoScale=\(model.videoZoomScale) rotationQuarterTurns=\(model.videoRotationQuarterTurns) viewport=\(model.videoViewportSize.debugDescription)")
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        NanightLog.info("Popover #\(popoverDebugSequence) show returned isShown=\(popover.isShown) \(popover.debugWindowDescription)")
    }

    @MainActor
    func popoverDidShow(_ notification: Notification) {
        guard let shownPopover = notification.object as? NSPopover else {
            return
        }

        NanightLog.info("Popover #\(popoverDebugSequence) didShow contentSize=\(shownPopover.contentSize.debugDescription) \(shownPopover.debugWindowDescription)")
        installOutsideClickEventMonitors(for: shownPopover)
        updateVideoContainerSize(animated: false)
        model.setVideoVisible(true)
        NanightLog.info("Popover #\(popoverDebugSequence) didShow completed \(shownPopover.debugWindowDescription)")
    }

    @MainActor
    func popoverDidClose(_ notification: Notification) {
        let closedPopover = notification.object as? NSPopover
        NanightLog.info("Popover #\(popoverDebugSequence) didClose notificationPopoverShown=\(closedPopover?.isShown == true) storedPopoverShown=\(popover?.isShown == true) appGestureCounts=\(popoverDebugGestureCounts.debugDescription)")
        model.setVideoVisible(false)
        removeOutsideClickEventMonitors()
        NanightLog.info("Popover #\(popoverDebugSequence) didClose cleanup completed retainedPopover=\(popover != nil)")
    }

    @MainActor
    private var preferredContentSize: NSSize {
        switch model.connectionState {
        case .signedIn, .offline:
            let videoSize = model.videoViewportSize
            return NSSize(width: videoSize.width, height: videoSize.height)
        case .signedOut, .authExpired, .mfaRequired, .restoring:
            return defaultPopoverContentSize
        }
    }

    @MainActor
    private func updateVideoContainerSize(animated: Bool) {
        let nextSize = preferredContentSize

        if let popover {
            if popover.contentSize != nextSize {
                NanightLog.info("Popover resize from=\(popover.contentSize.debugDescription) to=\(nextSize.debugDescription) animated=\(animated) shown=\(popover.isShown)")
                if animated,
                   popover.isShown,
                   let popoverWindow = popover.contentViewController?.view.window {
                    let startFrame = popoverWindow.frame
                    popover.contentSize = nextSize
                    let endFrame = popoverWindow.frame
                    popoverWindow.setFrame(startFrame, display: true)

                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 0.32
                        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                        popoverWindow.animator().setFrame(endFrame, display: true)
                    }
                } else {
                    popover.contentSize = nextSize
                }
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

    private func installGestureDebugEventMonitor() {
        let gestureEvents: NSEvent.EventTypeMask = [.beginGesture, .endGesture, .magnify, .rotate]

        localGestureDebugEventMonitor = NSEvent.addLocalMonitorForEvents(matching: gestureEvents) { [weak self] event in
            guard let self else {
                return event
            }

            self.popoverDebugGestureCounts.record(event)
            let popoverWindow = self.popover?.contentViewController?.view.window
            let windowMatches = event.window === popoverWindow
            let firstResponder = event.window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"

            NanightLog.info("Popover #\(self.popoverDebugSequence) appGestureEvent event=\(event.type.debugNameForNanight) phase=\(event.phase.debugNameForNanight) windowMatchesPopover=\(windowMatches) firstResponder=\(firstResponder) \(event.debugGestureValueDescription)")

            return event
        }

        NanightLog.info("Popover installed app gesture debug event monitor")
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

private struct GestureDebugCounts {
    private(set) var beginGesture = 0
    private(set) var endGesture = 0
    private(set) var magnify = 0
    private(set) var rotate = 0

    mutating func record(_ event: NSEvent) {
        switch event.type {
        case .beginGesture:
            beginGesture += 1
        case .endGesture:
            endGesture += 1
        case .magnify:
            magnify += 1
        case .rotate:
            rotate += 1
        default:
            break
        }
    }

    var debugDescription: String {
        "begin=\(beginGesture) end=\(endGesture) magnify=\(magnify) rotate=\(rotate)"
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
        case .scrollWheel:
            return "scrollWheel"
        case .magnify:
            return "magnify"
        case .rotate:
            return "rotate"
        case .beginGesture:
            return "beginGesture"
        case .endGesture:
            return "endGesture"
        default:
            return String(describing: self)
        }
    }
}

private extension NSEvent {
    var debugGestureValueDescription: String {
        switch type {
        case .magnify:
            return "magnification=\(magnification)"
        case .rotate:
            return "rotation=\(rotation)"
        default:
            return "value=none"
        }
    }
}

private extension NSEvent.Phase {
    var debugNameForNanight: String {
        if isEmpty {
            return "none"
        }

        var names: [String] = []

        if contains(.began) {
            names.append("began")
        }

        if contains(.stationary) {
            names.append("stationary")
        }

        if contains(.changed) {
            names.append("changed")
        }

        if contains(.ended) {
            names.append("ended")
        }

        if contains(.cancelled) {
            names.append("cancelled")
        }

        if contains(.mayBegin) {
            names.append("mayBegin")
        }

        return names.joined(separator: "+")
    }
}

private enum NanightMenuBarIconRenderer {
    static func image(for state: NanightMenuBarIconState) -> NSImage {
        guard state != .normal else {
            let image = NSImage(systemSymbolName: "moon", accessibilityDescription: "Nanight")
            image?.isTemplate = true
            return image ?? NSImage(size: NSSize(width: 18, height: 18))
        }

        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            drawStreaksIfNeeded(for: state, in: rect)
            drawMoon(in: rect)
            drawSoundWavesIfNeeded(for: state, in: rect)
            drawConnectingDotIfNeeded(for: state, in: rect)
            return true
        }
        image.accessibilityDescription = "Nanight"
        image.isTemplate = false
        return image
    }

    private static func drawMoon(in rect: NSRect) {
        guard let symbol = NSImage(systemSymbolName: "moon", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
        else {
            return
        }

        let drawRect = NSRect(x: rect.midX - 7, y: rect.midY - 7, width: 14, height: 14)
        symbol.draw(in: drawRect)

        NSColor.labelColor.setFill()
        drawRect.fill(using: .sourceIn)
    }

    private static func drawConnectingDotIfNeeded(for state: NanightMenuBarIconState, in rect: NSRect) {
        guard state == .connecting else {
            return
        }

        NSColor.systemYellow.setFill()
        NSBezierPath(ovalIn: NSRect(x: rect.maxX - 4.2, y: rect.minY + 2.8, width: 3.6, height: 3.6)).fill()
    }

    private static func drawStreaksIfNeeded(for state: NanightMenuBarIconState, in rect: NSRect) {
        guard state == .motion || state == .motionAndSound else {
            return
        }

        NSColor.systemYellow.setStroke()

        let lines: [(start: NSPoint, end: NSPoint, width: CGFloat)] = [
            (NSPoint(x: rect.minX + 1.4, y: rect.midY + 3.8), NSPoint(x: rect.minX + 5.8, y: rect.midY + 3.8), 1.1),
            (NSPoint(x: rect.minX + 0.8, y: rect.midY + 0.3), NSPoint(x: rect.minX + 5.4, y: rect.midY + 0.3), 1.0),
            (NSPoint(x: rect.minX + 2.2, y: rect.midY - 3.0), NSPoint(x: rect.minX + 5.8, y: rect.midY - 3.0), 0.9)
        ]

        for line in lines {
            let path = NSBezierPath()
            path.lineCapStyle = .round
            path.lineWidth = line.width
            path.move(to: line.start)
            path.line(to: line.end)
            path.stroke()
        }
    }

    private static func drawSoundWavesIfNeeded(for state: NanightMenuBarIconState, in rect: NSRect) {
        guard state == .sound || state == .motionAndSound else {
            return
        }

        NSColor.systemOrange.setStroke()

        for index in 0..<2 {
            let inset = CGFloat(index) * 2.6
            let arcRect = NSRect(
                x: rect.midX - 1.4 - inset,
                y: rect.midY - 4.8 - inset,
                width: 9.5 + inset * 2,
                height: 9.5 + inset * 2
            )
            let path = NSBezierPath()
            path.lineWidth = index == 0 ? 1.2 : 1.0
            path.lineCapStyle = .round
            path.appendArc(
                withCenter: NSPoint(x: arcRect.midX, y: arcRect.midY),
                radius: arcRect.width / 2,
                startAngle: -36,
                endAngle: 36
            )
            path.stroke()
        }
    }
}
