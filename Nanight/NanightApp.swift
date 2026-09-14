import SwiftUI

@main
struct NanightApp: App {
    @NSApplicationDelegateAdaptor(NanightAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(model: appDelegate.model, updater: appDelegate.updater)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesButton(updater: appDelegate.updater)
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings") {
                    appDelegate.openSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
