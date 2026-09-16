import Foundation

nonisolated struct NanightStateBlock: Identifiable, Sendable {
    let id: String
    let kind: String
    let start: Date
    var end: Date
    var inferredIntervals: [DateInterval] = []
    var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
    var title: String { kind == "SLEEPING" ? "Estimated sleep" : "In bed" }
    var durationText: String {
        let seconds = Int(duration)
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
    }
    var tooltip: String {
        "\(title)\nStart: \(start.formatted(date: .abbreviated, time: .standard))\nEnd: \(end.formatted(date: .abbreviated, time: .standard))\nDuration: \(durationText)" + (inferredIntervals.isEmpty ? "" : "\nIncludes inferred time:\n" + inferredIntervals.map { "\($0.start.formatted(date: .omitted, time: .standard)) to \($0.end.formatted(date: .omitted, time: .standard))" }.joined(separator: "\n"))
    }
}

/// Hysteresis uses elapsed time, not frame counts, except initial presence confirmation.
/// Short interruptions can recover presence, but never extend it without a positive sample.
nonisolated enum NanightPresenceObservation { case present, empty, uncertain }

nonisolated struct NanightRestState {
    static let interruptionGrace: TimeInterval = 30
    static let emptyConfirmation: TimeInterval = 120
    static let uncertainTimeout: TimeInterval = 180
    private(set) var inBed: NanightStateBlock?
    private(set) var sleeping: NanightStateBlock?
    private var lastSample: Date?
    private var lastPositive: Date?
    private var emptySince: Date?
    private var candidate: Date?
    private var matches = 0
    private var quietSince: Date?
    private var movingSince: Date?

    mutating func interrupt() {
        // A paused feed is unknown, not evidence of an empty crib. Keep the
        // presence identity for a brief recovery, but discard sleep evidence.
        sleeping = nil; quietSince = nil; movingSince = nil
        emptySince = nil
        if inBed == nil { candidate = nil; matches = 0 }
    }

    mutating func record(presence: NanightPresenceObservation, moving: Bool?, at time: Date) -> [NanightStateBlock] {
        if let lastSample {
            let gap = time.timeIntervalSince(lastSample)
            if gap < 0 || gap > Self.interruptionGrace { self = Self() }
            else if gap > 8 { interrupt() }
        }
        lastSample = time
        if presence != .present {
            if inBed == nil { candidate = nil; matches = 0; quietSince = nil }
            if presence == .empty {
                if emptySince == nil { emptySince = time }
            } else {
                emptySince = nil
            }
            let confirmedEmpty = emptySince.map { time.timeIntervalSince($0) >= Self.emptyConfirmation } ?? false
            let stalePresence = lastPositive.map { time.timeIntervalSince($0) >= Self.uncertainTimeout } ?? false
            if confirmedEmpty || stalePresence {
                inBed = nil; sleeping = nil; candidate = nil; matches = 0
                quietSince = nil; movingSince = nil
            }
            // Presence is sticky; sleep has a tighter uncertainty bound.
            if let lastPositive, time.timeIntervalSince(lastPositive) > 30 {
                sleeping = nil; quietSince = nil; movingSince = nil
            }
            return []
        }
        // A full empty period still ends the old block even if this sample
        // happens to be the first returning positive at the boundary.
        if let emptySince, time.timeIntervalSince(emptySince) >= Self.emptyConfirmation {
            inBed = nil; sleeping = nil; candidate = nil; matches = 0
            quietSince = nil; movingSince = nil
        }
        emptySince = nil
        lastPositive = time
        if candidate == nil { candidate = time }
        matches += 1
        if inBed == nil, matches >= 2 {
            inBed = NanightStateBlock(id: "IN_BED-\((candidate ?? time).timeIntervalSince1970)", kind: "IN_BED", start: candidate ?? time, end: time)
        }
        guard inBed != nil else { return [] }
        inBed?.end = time
        guard let moving else {
            // A lighting discontinuity or missing baseline makes sleep unknown.
            sleeping = nil; quietSince = nil; movingSince = nil
            return [inBed!]
        }
        if moving {
            quietSince = nil
            if movingSince == nil { movingSince = time }
            if time.timeIntervalSince(movingSince!) >= 30 { sleeping = nil }
        } else {
            movingSince = nil
            if quietSince == nil { quietSince = time }
            if sleeping == nil, time.timeIntervalSince(quietSince!) >= 120 {
                sleeping = NanightStateBlock(id: "SLEEPING-\(time.timeIntervalSince1970)", kind: "SLEEPING", start: time, end: time)
            }
        }
        sleeping?.end = time
        return [inBed, sleeping].compactMap { $0 }
    }
}
