import Foundation

/// Persisted numeric evidence only. Changing interpretation never changes these rows.
nonisolated struct NanightSignalObservation: Codable, Sendable, Identifiable {
    enum Kind: String, Codable { case sample, interruption, reset, failure }
    var id = UUID().uuidString
    let timestamp: Date
    let session: UUID
    let kind: Kind
    var extractorVersion = 1
    var model = "MobileCLIP-S2"
    var babySimilarity: Float?
    var emptySimilarity: Float?
    var changedFraction: Float?
    var brightnessChange: Float?
    var motionValid = false
    var inferenceMilliseconds: Double?
}

nonisolated struct NanightAnalysisStatus: Sendable {
    var inBed = false
    var sleeping = false
}

/// One reducer for both live observations and replay from SQLite.
nonisolated struct NanightSignalAnalysis {
    static let version = 2
    private var rest = NanightRestState()
    private var session: UUID?
    private(set) var status = NanightAnalysisStatus()
    private var gapInference = NanightGapInference()
    var blocks: [String: NanightStateBlock] { gapInference.blocks }
    private(set) var lastTimestamp: Date?

    mutating func consume(_ observation: NanightSignalObservation) {
        if session != observation.session {
            rest = NanightRestState(); session = observation.session
            gapInference.boundary(reset: true)
        }
        lastTimestamp = observation.timestamp
        guard observation.kind == .sample else {
            if observation.kind == .reset { rest = NanightRestState() }
            else { rest.interrupt() }
            gapInference.boundary(reset: observation.kind != .interruption)
            status = NanightAnalysisStatus()
            return
        }
        guard observation.extractorVersion == 1, observation.model == "MobileCLIP-S2",
              let baby = observation.babySimilarity, let empty = observation.emptySimilarity,
              baby.isFinite, empty.isFinite else {
            rest.interrupt(); gapInference.boundary(reset: true)
            status = NanightAnalysisStatus(); return
        }
        let margin = baby - empty
        let presence: NanightPresenceObservation = baby >= 0.2 && margin >= 0.015 ? .present
            : empty >= 0.2 && margin <= -0.015 ? .empty : .uncertain
        var moving: Bool?
        if observation.motionValid, let fraction = observation.changedFraction,
           let brightness = observation.brightnessChange, fraction.isFinite, brightness.isFinite,
           brightness < 0.15 {
            moving = fraction > 0.04
        }
        let emitted = rest.record(presence: presence, moving: moving, at: observation.timestamp)
        gapInference.record(at: observation.timestamp, presence: presence, moving: moving, emitted: emitted,
                            baselineMissing: observation.changedFraction == nil && observation.brightnessChange == nil)
        status = NanightAnalysisStatus(inBed: rest.inBed != nil, sleeping: rest.sleeping != nil)
    }
}
