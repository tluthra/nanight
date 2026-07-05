import AppKit
import Combine
import QuartzCore
import SwiftUI

final class NanightAppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    @MainActor let model = NanightAppModel()

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var cancellable: AnyCancellable?
    private var localOutsideClickEventMonitor: Any?
    private var globalOutsideClickEventMonitor: Any?
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

        let image = NSImage(systemSymbolName: model.menuBarSystemImage, accessibilityDescription: "Nanight")
        image?.isTemplate = true
        button.image = image
        button.contentTintColor = nil
    }

    @objc
    @MainActor
    private func statusItemClicked(_ sender: NSStatusBarButton) {
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
            popover.performClose(sender)
            return
        }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = preferredContentSize
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: NanightMenuView(
            model: model,
            onVideoViewportChange: { [weak self] in
                Task { @MainActor in
                    self?.updateVideoContainerSize(animated: false)
                }
            }
        ))
        self.popover = popover
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }

    @MainActor
    func popoverDidShow(_ notification: Notification) {
        guard let shownPopover = notification.object as? NSPopover else {
            return
        }

        installOutsideClickEventMonitors(for: shownPopover)
        updateVideoContainerSize(animated: false)
        model.setVideoVisible(true)
    }

    @MainActor
    func popoverDidClose(_ notification: Notification) {
        model.setVideoVisible(false)
        removeOutsideClickEventMonitors()
        popover?.delegate = nil
        popover = nil
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
            }
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
        }

        if let globalOutsideClickEventMonitor {
            NSEvent.removeMonitor(globalOutsideClickEventMonitor)
            self.globalOutsideClickEventMonitor = nil
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
