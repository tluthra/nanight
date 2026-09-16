import Foundation
import SQLite3

nonisolated struct NanightHistoryEvent: Identifiable, Sendable {
    let timestamp: Date
    let kind: String
    var id: String { "\(kind)-\(timestamp.timeIntervalSince1970)" }
}

nonisolated struct NanightHistoryDay: Identifiable, Sendable {
    let date: Date
    let end: Date
    var events: [NanightHistoryEvent] = []
    var observations: [DateInterval] = []
    var blocks: [NanightStateBlock] = []
    var id: Date { date }
    var observedSeconds: TimeInterval { observations.reduce(0) { $0 + $1.duration } }
}

/// A single connection, isolated off the UI actor. History has no retention limit.
actor NanightActivityStore {
    private let url: URL
    private var db: OpaquePointer?
    private var clearedBefore = -Double.infinity
    private var lastObservation: (camera: String, session: UUID, row: Int64, time: Date)?
    private var analyses: [String: NanightSignalAnalysis] = [:]
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nanight", isDirectory: true).appendingPathComponent("activity.sqlite")
    }

    deinit { sqlite3_close(db) }

    private func open() throws {
        guard db == nil else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            let error = failure()
            sqlite3_close(db)
            db = nil
            throw error
        }
        do {
            sqlite3_busy_timeout(db, 3000)
            try execute("PRAGMA journal_mode=WAL")
            try execute("CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value REAL NOT NULL)")
            try statement("SELECT value FROM metadata WHERE key='cleared_before'") { stmt in
                let status = sqlite3_step(stmt)
                if status == SQLITE_ROW { clearedBefore = sqlite3_column_double(stmt, 0) }
                else if status != SQLITE_DONE { throw failure() }
            }
            try execute("CREATE TABLE IF NOT EXISTS events (camera TEXT NOT NULL, time REAL NOT NULL, kind TEXT NOT NULL, PRIMARY KEY(camera, time, kind)) WITHOUT ROWID")
            try execute("CREATE TABLE IF NOT EXISTS observations (id INTEGER PRIMARY KEY, camera TEXT NOT NULL, start REAL NOT NULL, end REAL NOT NULL)")
            try execute("CREATE INDEX IF NOT EXISTS observations_camera_end ON observations(camera, end)")
            try execute("CREATE TABLE IF NOT EXISTS signal_observations (id TEXT PRIMARY KEY, camera TEXT NOT NULL, time REAL NOT NULL, payload TEXT NOT NULL)")
            try execute("CREATE INDEX IF NOT EXISTS signals_camera_time ON signal_observations(camera,time)")
        } catch {
            sqlite3_close(db)
            db = nil
            throw error
        }
    }

    private func failure() -> NSError {
        NSError(domain: "NanightActivityStore", code: Int(sqlite3_errcode(db)),
                userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }

    private func statement(_ sql: String, _ body: (OpaquePointer) throws -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        defer { sqlite3_finalize(statement) }
        try body(statement)
    }

    private func bind(_ text: String, to statement: OpaquePointer, at index: Int32) {
        sqlite3_bind_text(statement, index, text, -1, transient)
    }

    private func finish(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }

    func record(camera: String, events: [NanightHistoryEvent], at now: Date, session: UUID) throws {
        try open()
        try execute("BEGIN IMMEDIATE")
        let previous = lastObservation
        do {
            try statement("INSERT OR IGNORE INTO events(camera,time,kind) VALUES(?,?,?)") { stmt in
                for event in events {
                    let kind = event.kind.uppercased()
                    guard ["MOTION", "SOUND"].contains(kind), event.timestamp.timeIntervalSince1970.isFinite,
                          event.timestamp.timeIntervalSince1970 > max(0, clearedBefore), event.timestamp <= now else { continue }
                    sqlite3_reset(stmt)
                    sqlite3_clear_bindings(stmt)
                    bind(camera, to: stmt, at: 1)
                    sqlite3_bind_double(stmt, 2, event.timestamp.timeIntervalSince1970)
                    bind(kind, to: stmt, at: 3)
                    try finish(stmt)
                }
            }
            // Persist only through the last successful poll. Never extrapolate across
            // sleep, crashes, failed polling, camera changes, or a new process session.
            if let last = lastObservation, last.camera == camera, last.session == session,
               now >= last.time, now.timeIntervalSince(last.time) <= 75 {
                try statement("UPDATE observations SET end=? WHERE id=?") { stmt in
                    sqlite3_bind_double(stmt, 1, now.timeIntervalSince1970)
                    sqlite3_bind_int64(stmt, 2, last.row)
                    try finish(stmt)
                }
                lastObservation = (camera, session, last.row, now)
            } else {
                try statement("INSERT INTO observations(camera,start,end) VALUES(?,?,?)") { stmt in
                    bind(camera, to: stmt, at: 1)
                    sqlite3_bind_double(stmt, 2, now.timeIntervalSince1970)
                    sqlite3_bind_double(stmt, 3, now.timeIntervalSince1970)
                    try finish(stmt)
                }
                lastObservation = (camera, session, sqlite3_last_insert_rowid(db), now)
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            lastObservation = previous
            throw error
        }
    }

    /// Append evidence before interpreting it. Repeated IDs never overwrite raw data.
    func recordSignal(camera: String, observation: NanightSignalObservation) throws -> NanightAnalysisStatus {
        try open()
        guard observation.timestamp.timeIntervalSince1970.isFinite,
              observation.timestamp.timeIntervalSince1970 > clearedBefore else { return NanightAnalysisStatus() }
        let payload = String(decoding: try JSONEncoder().encode(observation), as: UTF8.self)
        try statement("INSERT OR IGNORE INTO signal_observations(id,camera,time,payload) VALUES(?,?,?,?)") { stmt in
            bind(observation.id, to: stmt, at: 1)
            bind(camera, to: stmt, at: 2)
            sqlite3_bind_double(stmt, 3, observation.timestamp.timeIntervalSince1970)
            bind(payload, to: stmt, at: 4)
            try finish(stmt)
        }
        if sqlite3_changes(db) > 0, var cached = analyses[camera] {
            if let last = cached.lastTimestamp, observation.timestamp < last {
                analyses[camera] = nil
            } else {
                cached.consume(observation)
                analyses[camera] = cached
            }
        }
        return try analysis(camera: camera).status
    }

    func signals(camera: String) throws -> [NanightSignalObservation] {
        try open()
        var result: [NanightSignalObservation] = []
        try statement("SELECT payload FROM signal_observations WHERE camera=? ORDER BY time,rowid") { stmt in
            bind(camera, to: stmt, at: 1)
            var status = sqlite3_step(stmt)
            while status == SQLITE_ROW {
                let payload = String(cString: sqlite3_column_text(stmt, 0))
                result.append(try JSONDecoder().decode(NanightSignalObservation.self, from: Data(payload.utf8)))
                status = sqlite3_step(stmt)
            }
            guard status == SQLITE_DONE else { throw failure() }
        }
        return result
    }

    private func analysis(camera: String) throws -> NanightSignalAnalysis {
        if let cached = analyses[camera] { return cached }
        var result = NanightSignalAnalysis()
        for observation in try signals(camera: camera) { result.consume(observation) }
        analyses[camera] = result
        return result
    }

    func clear(at date: Date = Date()) throws {
        try open()
        try execute("BEGIN IMMEDIATE")
        do {
            try execute("DELETE FROM events")
            try execute("DELETE FROM observations")
            try execute("DELETE FROM signal_observations")
            try statement("INSERT OR REPLACE INTO metadata(key,value) VALUES('cleared_before',?)") { stmt in
                sqlite3_bind_double(stmt, 1, date.timeIntervalSince1970)
                try finish(stmt)
            }
            try execute("COMMIT")
            clearedBefore = date.timeIntervalSince1970
            lastObservation = nil
            analyses.removeAll()
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func earliestDate(camera: String) throws -> Date? {
        try open()
        var result: Date?
        try statement("SELECT MIN(time) FROM (SELECT MIN(time) AS time FROM events WHERE camera=? UNION ALL SELECT MIN(start) AS time FROM observations WHERE camera=? UNION ALL SELECT MIN(time) AS time FROM signal_observations WHERE camera=?)") { stmt in
            bind(camera, to: stmt, at: 1)
            bind(camera, to: stmt, at: 2)
            bind(camera, to: stmt, at: 3)
            guard sqlite3_step(stmt) == SQLITE_ROW else { throw failure() }
            if sqlite3_column_type(stmt, 0) != SQLITE_NULL { result = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0)) }
        }
        return result
    }

    func days(camera: String, endingAt date: Date, count: Int, calendar: Calendar = .current) throws -> [NanightHistoryDay] {
        try open()
        let today = calendar.startOfDay(for: date)
        var days = (0..<max(0, min(count, 31))).compactMap { offset -> NanightHistoryDay? in
            guard let start = calendar.date(byAdding: .day, value: -offset, to: today),
                  let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
            return NanightHistoryDay(date: start, end: end)
        }
        guard let start = days.last?.date, let end = days.first?.end else { return [] }
        let indexes = Dictionary(uniqueKeysWithValues: days.enumerated().map { ($0.element.date, $0.offset) })
        try statement("SELECT time,kind FROM events WHERE camera=? AND time>=? AND time<? ORDER BY time") { stmt in
            bind(camera, to: stmt, at: 1)
            sqlite3_bind_double(stmt, 2, start.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 3, end.timeIntervalSince1970)
            var status = sqlite3_step(stmt)
            while status == SQLITE_ROW {
                let timestamp = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0))
                if let index = indexes[calendar.startOfDay(for: timestamp)] {
                    days[index].events.append(NanightHistoryEvent(timestamp: timestamp, kind: String(cString: sqlite3_column_text(stmt, 1))))
                }
                status = sqlite3_step(stmt)
            }
            guard status == SQLITE_DONE else { throw failure() }
        }
        try statement("SELECT start,end FROM observations WHERE camera=? AND end>? AND start<? ORDER BY start") { stmt in
            bind(camera, to: stmt, at: 1)
            sqlite3_bind_double(stmt, 2, start.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 3, end.timeIntervalSince1970)
            var status = sqlite3_step(stmt)
            while status == SQLITE_ROW {
                let a = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0))
                let b = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1))
                for index in days.indices {
                    let lower = max(a, days[index].date), upper = min(b, days[index].end)
                    if upper > lower { days[index].observations.append(DateInterval(start: lower, end: upper)) }
                }
                status = sqlite3_step(stmt)
            }
            guard status == SQLITE_DONE else { throw failure() }
        }
        for block in try analysis(camera: camera).blocks.values.sorted(by: { $0.start < $1.start }) {
            for index in days.indices where block.end >= days[index].date && block.start < days[index].end {
                days[index].blocks.append(block)
            }
        }
        return days
    }
}
