import SwiftUI

@main
struct NanightApp: App {
    @NSApplicationDelegateAdaptor(NanightAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(model: appDelegate.model)
        }
    }
}
