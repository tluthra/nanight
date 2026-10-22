import AppKit
import Carbon
import Combine
import SwiftUI

struct NanightShortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var keyLabel: String

    static let defaultShortcut = NanightShortcut(
        keyCode: UInt32(kVK_ANSI_N),
        modifiers: UInt32(controlKey | optionKey | cmdKey),
        keyLabel: "N"
    )

    var label: String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        return result + keyLabel
    }

    init(keyCode: UInt32, modifiers: UInt32, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags
        // Require Control, Option, or Command so normal typing remains available.
        guard !flags.intersection([.control, .option, .command]).isEmpty else { return nil }
        let specialKeys: [UInt16: String] = [
            36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 117: "Forward Delete",
            123: "←", 124: "→", 125: "↓", 126: "↑", 115: "Home", 119: "End",
            116: "Page Up", 121: "Page Down", 122: "F1", 120: "F2", 99: "F3",
            118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9",
            109: "F10", 103: "F11", 111: "F12"
        ]
        let label = specialKeys[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? ""
        guard !label.isEmpty, label.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
        keyCode = UInt32(event.keyCode)
        keyLabel = label
        modifiers = 0
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
    }
}

@MainActor
final class NanightGlobalShortcut: ObservableObject {
    @Published private(set) var shortcut: NanightShortcut
    @Published private(set) var error: String?
    var isRecording = false
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var action: (() -> Void)?
    private let defaults: UserDefaults
    private static let defaultsKey = "globalCameraShortcut"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        shortcut = defaults.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode(NanightShortcut.self, from: $0) } ?? .defaultShortcut
    }

    func start(action: @escaping () -> Void) {
        self.action = action
        guard handler == nil else { return }
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated {
                let shortcut = Unmanaged<NanightGlobalShortcut>.fromOpaque(context).takeUnretainedValue()
                if !shortcut.isRecording { shortcut.action?() }
            }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else {
            error = "Unable to enable the global shortcut (\(status))."
            return
        }
        _ = update(shortcut)
    }

    @discardableResult
    func update(_ candidate: NanightShortcut) -> Bool {
        if candidate == shortcut, hotKey != nil {
            error = nil
            return true
        }
        var replacement: EventHotKeyRef?
        let status = RegisterEventHotKey(candidate.keyCode, candidate.modifiers,
                                        EventHotKeyID(signature: 0x4E414E49, id: 1),
                                        GetApplicationEventTarget(), 0, &replacement)
        guard status == noErr else {
            error = "This shortcut is unavailable. It may be used by another app. Choose a different shortcut."
            return false
        }
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = replacement
        shortcut = candidate
        defaults.set(try? JSONEncoder().encode(candidate), forKey: Self.defaultsKey)
        error = nil
        return true
    }

    func stop() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
        action = nil
    }
}

struct NanightShortcutSettings: View {
    @ObservedObject var shortcut: NanightGlobalShortcut
    @State private var monitor: Any?
    @State private var recording = false
    @State private var validationError: String?

    var body: some View {
        Section("Keyboard Shortcut") {
            HStack {
                Text("Show Nanight")
                Spacer()
                Button(recording ? "Press shortcut…" : shortcut.shortcut.label) {
                    if recording { stopRecording() } else { startRecording() }
                }
                .accessibilityLabel("Show Nanight shortcut")
                .accessibilityValue(recording ? "Recording" : shortcut.shortcut.label)
                Button("Reset") {
                    stopRecording()
                    shortcut.update(.defaultShortcut)
                }
                .disabled(shortcut.shortcut == .defaultShortcut)
            }
            Text(recording ? "Press a key with Control, Option, or Command. Press Escape to cancel." : "Bring Nanight forward from any app while it is running.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let error = validationError ?? shortcut.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onDisappear { stopRecording() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in
            stopRecording()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            stopRecording()
        }
    }

    private func startRecording() {
        validationError = nil
        recording = true
        shortcut.isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stopRecording()
            } else if let candidate = NanightShortcut(event: event) {
                validationError = nil
                if shortcut.update(candidate) { stopRecording() }
            } else {
                validationError = "Include Control, Option, or Command with your key."
            }
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        shortcut.isRecording = false
        validationError = nil
    }
}
