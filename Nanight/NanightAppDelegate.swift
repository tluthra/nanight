import AppKit
import Combine
import QuartzCore
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

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var cancellable: AnyCancellable?
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
            popover.contentViewController = NSHostingController(rootView: NanightMenuView(model: model))
            self.popover = popover
        }

        guard let popover else {
            NanightLog.warning("Popover #\(popoverDebugSequence) toggle skipped because popover creation failed")
            return
        }

        popover.delegate = self
        popover.contentSize = preferredContentSize
        NanightLog.info("Popover #\(popoverDebugSequence) toggle \(createdPopover ? "creating" : "reusing") popover contentSize=\(popover.contentSize.debugDescription) preferredContentSize=\(preferredContentSize.debugDescription) state=\(model.connectionState) viewport=\(model.videoViewportSize.debugDescription)")
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
        NanightLog.info("Popover #\(popoverDebugSequence) didClose notificationPopoverShown=\(closedPopover?.isShown == true) storedPopoverShown=\(popover?.isShown == true)")
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
