import Foundation
import OSLog

nonisolated enum NanightLog {
    private static let logger = Logger(subsystem: "com.tanooj.Nanight", category: "playback")
    static func info(_ message: String) {
        write("INFO", message)
    }

    static func warning(_ message: String) {
        write("WARN", message)
    }

    static func error(_ message: String) {
        write("ERROR", message)
    }

    private static func write(_ level: String, _ message: String) {
        // Keep dynamic details private, since callers can include account or stream data.
        switch level {
        case "ERROR": logger.error("[\(level, privacy: .public)] \(message)")
        case "WARN": logger.warning("[\(level, privacy: .public)] \(message)")
        default: logger.notice("[\(level, privacy: .public)] \(message)")
        }
    }
}
