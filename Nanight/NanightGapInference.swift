import Foundation

/// Retrospective estimates only. Missing frames never establish a live state.
nonisolated struct NanightGapInference {
    static let maximumGap: TimeInterval = 2 * 3600
    private(set) var blocks: [String: NanightStateBlock] = [:]
    private var aliases: [String: String] = [:]
    private var lastTime: Date?
    private var lastBed: NanightStateBlock?
    private var lastSleep: NanightStateBlock?
    private var quietSince: Date?
    private var lastQuietTime: Date?
    private var pending: Bridge?

    private struct Bridge {
        let bed: NanightStateBlock
        let sleep: NanightStateBlock?
        let quietStart: Date?
        let before: Date
        let after: Date
        var joinedBed = false
    }

    mutating func boundary(reset: Bool) {
        if reset {
            lastTime = nil; lastBed = nil; lastSleep = nil; quietSince = nil; lastQuietTime = nil; pending = nil
        }
        // An interruption retains only the last actual sample as evidence.
    }

    mutating func record(at time: Date, presence: NanightPresenceObservation, moving: Bool?,
                         emitted: [NanightStateBlock], baselineMissing: Bool = false) {
        if let lastTime, time.timeIntervalSince(lastTime) > NanightRestState.interruptionGrace {
            pending = nil
            if let bed = lastBed, bed.duration >= 30,
               time.timeIntervalSince(lastTime) <= Self.maximumGap, presence == .present {
                let quietStart = quietSince.flatMap { lastTime.timeIntervalSince($0) >= 30 ? $0 : nil }
                pending = Bridge(bed: bed, sleep: lastSleep, quietStart: quietStart, before: lastTime, after: time)
            }
            quietSince = nil
        } else if let lastTime, time.timeIntervalSince(lastTime) > 8 {
            quietSince = nil; lastQuietTime = nil; pending = nil
        }
        if presence != .present { pending = nil }
        if presence == .present && moving == false {
            if quietSince == nil { quietSince = time }
            lastQuietTime = time
        } else if !(presence == .present && moving == nil && baselineMissing
                    && lastQuietTime.map { time.timeIntervalSince($0) <= 8 } == true) {
            quietSince = nil; lastQuietTime = nil
        }

        for block in emitted { save(block) }
        let bed = emitted.first { $0.kind == "IN_BED" }
        let sleep = emitted.first { $0.kind == "SLEEPING" }
        if var bridge = pending, let bed {
            if !bridge.joinedBed, time.timeIntervalSince(bridge.after) >= 30 {
                join(bed, to: bridge.bed, inferred: DateInterval(start: bridge.before, end: bridge.after))
                bridge.joinedBed = true
            }
            if bridge.joinedBed, let sleep, let quietStart = bridge.quietStart,
               let resumedQuiet = quietSince, resumedQuiet.timeIntervalSince(bridge.after) <= 8,
               time.timeIntervalSince(resumedQuiet) >= 120 {
                let previous = bridge.sleep ?? NanightStateBlock(
                    id: "SLEEPING-inferred-\(quietStart.timeIntervalSince1970)", kind: "SLEEPING",
                    start: quietStart.addingTimeInterval(120), end: bridge.before)
                if previous.start < sleep.start {
                    // Include the unobserved gap and the retrospective portion before
                    // sleep was confirmed again. Never label this as observed time.
                    join(sleep, to: previous, inferred: DateInterval(
                        start: max(previous.start, bridge.before), end: sleep.start))
                }
                pending = nil
            } else if time.timeIntervalSince(bridge.after) > 300 {
                pending = nil
            } else { pending = bridge }
        }
        lastTime = time
        lastBed = presence == .present ? bed.map { blocks[aliases[$0.id] ?? $0.id] ?? $0 } : nil
        lastSleep = presence == .present ? sleep.map { blocks[aliases[$0.id] ?? $0.id] ?? $0 } : nil
    }

    private mutating func save(_ block: NanightStateBlock) {
        let id = aliases[block.id] ?? block.id
        if var existing = blocks[id] {
            existing.end = max(existing.end, block.end)
            blocks[id] = existing
        } else { blocks[id] = block }
    }

    private mutating func join(_ current: NanightStateBlock, to previous: NanightStateBlock, inferred: DateInterval) {
        let oldID = aliases[current.id] ?? current.id
        let id = aliases[previous.id] ?? previous.id
        var merged = blocks[id] ?? previous
        merged.end = current.end
        merged.inferredIntervals.append(inferred)
        blocks.removeValue(forKey: oldID)
        blocks[id] = merged
        aliases[current.id] = id
    }
}
