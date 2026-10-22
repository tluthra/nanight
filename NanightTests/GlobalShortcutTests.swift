import AppKit
import Carbon
import Testing
@testable import Nanight

@MainActor
struct GlobalShortcutTests {
    @Test func defaultAndSavedShortcutLoad() throws {
        let suite = "NanightShortcutTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(NanightGlobalShortcut(defaults: defaults).shortcut == .defaultShortcut)
        let saved = NanightShortcut(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey | shiftKey), keyLabel: "K")
        defaults.set(try JSONEncoder().encode(saved), forKey: "globalCameraShortcut")
        #expect(NanightGlobalShortcut(defaults: defaults).shortcut == saved)
        defaults.set(Data("invalid".utf8), forKey: "globalCameraShortcut")
        #expect(NanightGlobalShortcut(defaults: defaults).shortcut == .defaultShortcut)
    }

    @Test func recordingRejectsTypingAndAcceptsModifiedKeys() throws {
        func event(_ modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                         timestamp: 0, windowNumber: 0, context: nil, characters: "n",
                                         charactersIgnoringModifiers: "n", isARepeat: false,
                                         keyCode: UInt16(kVK_ANSI_N)))
        }
        #expect(NanightShortcut(event: try event([])) == nil)
        #expect(NanightShortcut(event: try event(.shift)) == nil)
        #expect(NanightShortcut(event: try event([.control, .option, .command])) == .defaultShortcut)
    }
}
