import AppKit
import Combine
import SwiftUI

final class NanightAppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    @MainActor let model = NanightAppModel()

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var cancellable: AnyCancellable?

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
        popover.contentSize = NSSize(width: 520, height: 320)
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: NanightMenuView(model: model))
        self.popover = popover
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        model.setVideoVisible(true)
    }

    @MainActor
    func popoverDidClose(_ notification: Notification) {
        model.setVideoVisible(false)
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
