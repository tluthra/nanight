import Foundation

nonisolated enum NanightAnalysisTiming {
    static let presenceInterval: TimeInterval = 10
    static let presenceFreshness: TimeInterval = 15
    static let motionInterval: TimeInterval = 3
    static let motionFreshness: TimeInterval = 8
    static let inferenceDeadline: TimeInterval = 8
}

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
    static let version = 3
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
        guard [1, 2].contains(observation.extractorVersion), observation.model == "MobileCLIP-S2",
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
        // Version 1 stored one frame's motion every three seconds. Version 2
        // stores the entire motion window with each ten-second classification.
        let sampleGap = observation.extractorVersion == 2
            ? NanightAnalysisTiming.presenceFreshness : NanightAnalysisTiming.motionFreshness
        let confirmationDuration = observation.extractorVersion == 2 ? NanightAnalysisTiming.presenceInterval : 0
        let emitted = rest.record(presence: presence, moving: moving, at: observation.timestamp,
                                  maximumSampleGap: sampleGap, minimumConfirmationDuration: confirmationDuration)
        gapInference.record(at: observation.timestamp, presence: presence, moving: moving, emitted: emitted,
                            baselineMissing: observation.changedFraction == nil && observation.brightnessChange == nil,
                            maximumSampleGap: sampleGap)
        status = NanightAnalysisStatus(inBed: rest.inBed != nil, sleeping: rest.sleeping != nil)
    }
}
