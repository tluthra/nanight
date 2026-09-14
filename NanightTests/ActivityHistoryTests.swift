import Foundation
import Testing
@testable import Nanight

@MainActor
struct ActivityHistoryTests {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("history.sqlite")
    }
    private func event(_ time: Date, _ kind: String = "MOTION") -> NanightHistoryEvent {
        NanightHistoryEvent(timestamp: time, kind: kind)
    }
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return value
    }
    private func date(_ year: Int = 2026, _ month: Int = 9, _ day: Int = 14, _ hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    @Test func duplicatesPersistAcrossConnectionsAndCamerasStaySeparate() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = NanightActivityStore(url: url)
        let now = date(), session = UUID()
        try await store.record(camera: "a", events: [event(now), event(now), event(now, "SOUND"), event(now, "UNKNOWN")], at: now, session: session)
        let reopened = NanightActivityStore(url: url)
        try await reopened.record(camera: "a", events: [event(now)], at: now.addingTimeInterval(30), session: UUID())
        try await reopened.record(camera: "b", events: [event(now)], at: now, session: UUID())
        let a = try await reopened.days(camera: "a", endingAt: now, count: 1, calendar: calendar)
        let b = try await reopened.days(camera: "b", endingAt: now, count: 1, calendar: calendar)
        #expect(a[0].events.count == 2)
        #expect(b[0].events.count == 1)
        #expect(a[0].observedSeconds == 0) // A reopened connection never fills the intervening time.
    }

    @Test func pollingGapsAndSessionChangesDoNotBecomeQuietTime() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = NanightActivityStore(url: url)
        let now = date(), session = UUID()
        for offset in [0.0, 30, 60, 180, 210] {
            try await store.record(camera: "a", events: [], at: now.addingTimeInterval(offset), session: session)
        }
        try await store.record(camera: "a", events: [], at: now.addingTimeInterval(220), session: UUID())
        let days = try await store.days(camera: "a", endingAt: now, count: 1, calendar: calendar)
        #expect(days[0].observedSeconds == 90)
        #expect(days[0].observations.count == 2)
    }

    @Test func midnightAndDSTUseCalendarDays() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = NanightActivityStore(url: url)
        let midnight = date(2026, 3, 8, 0), session = UUID()
        try await store.record(camera: "a", events: [event(midnight.addingTimeInterval(-1))], at: midnight.addingTimeInterval(-30), session: session)
        try await store.record(camera: "a", events: [event(midnight)], at: midnight.addingTimeInterval(30), session: session)
        let days = try await store.days(camera: "a", endingAt: midnight, count: 2, calendar: calendar)
        #expect(days[0].end.timeIntervalSince(days[0].date) == 23 * 3600)
        #expect(days[0].events.count == 1)
        #expect(days[1].events.isEmpty) // A future timestamp from the first response was ignored.
        #expect(days[0].observedSeconds == 30)
        #expect(days[1].observedSeconds == 30)
        let fall = try await store.days(camera: "a", endingAt: date(2026, 11, 1), count: 1, calendar: calendar)
        #expect(fall[0].end.timeIntervalSince(fall[0].date) == 25 * 3600)
    }

    @Test func oldEventsRemainAndClearRemovesAllCameras() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = NanightActivityStore(url: url)
        let old = date(2020, 1, 1), now = date()
        try await store.record(camera: "a", events: [event(old)], at: now, session: UUID())
        try await store.record(camera: "b", events: [event(old)], at: now, session: UUID())
        #expect(try await store.earliestDate(camera: "a") == old)
        #expect(try await store.days(camera: "a", endingAt: old, count: 1, calendar: calendar)[0].events.count == 1)
        try await store.clear(at: now)
        #expect(try await store.earliestDate(camera: "a") == nil)
        #expect(try await store.earliestDate(camera: "b") == nil)
        let reopened = NanightActivityStore(url: url)
        try await reopened.record(camera: "a", events: [event(old), event(now.addingTimeInterval(5))], at: now.addingTimeInterval(30), session: UUID())
        let current = try await reopened.days(camera: "a", endingAt: now, count: 1, calendar: calendar)
        #expect(current[0].events.count == 1)
        #expect(current[0].events[0].timestamp == now.addingTimeInterval(5))
    }
}
