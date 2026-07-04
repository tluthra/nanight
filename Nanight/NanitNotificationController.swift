import Foundation
import UserNotifications

enum NanitNotificationKind: String, CaseIterable {
    case motion
    case sound
    case offline
    case reconnected
    case authExpired
}

final class NanitNotificationController {
    private var lastSentAt: [NanitNotificationKind: Date] = [:]

    func requestPermission() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        } catch {
            return false
        }
    }

    func notify(
        kind: NanitNotificationKind,
        title: String,
        body: String,
        cooldown: TimeInterval,
        notificationsEnabled: Bool
    ) {
        guard notificationsEnabled else {
            return
        }

        if let lastSent = lastSentAt[kind], Date().timeIntervalSince(lastSent) < cooldown {
            return
        }

        lastSentAt[kind] = Date()

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "nanight-\(kind.rawValue)-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }
}
