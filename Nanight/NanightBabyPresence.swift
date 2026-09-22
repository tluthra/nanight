import Combine
import CoreVideo
import Foundation
import OSLog

@MainActor
final class NanightBabyPresence: ObservableObject {
    @Published private(set) var possibleBaby = false
    @Published private(set) var likelySleeping = false
    var onObservation: ((NanightSignalObservation) async throws -> NanightAnalysisStatus)?
    private var session = UUID()
    private let classify: @MainActor (NanightPresenceFrame) async throws -> NanightCribClassification
    private let measure: @MainActor (NanightPresenceFrame, TimeInterval, Int) async -> NanightMotionMeasurement
    private let uptime: () -> TimeInterval
    private var motionWindow = NanightMotionWindow()
    private var lastResult: TimeInterval?
    private static let logger = Logger(subsystem: "com.tanooj.Nanight", category: "presence")
    private var lastSample: TimeInterval = -.infinity
    private var lastMotionSample: TimeInterval = -.infinity
    private var generation = 0
    private(set) var isProcessing = false

    init(classify: @escaping @MainActor (NanightPresenceFrame) async throws -> NanightCribClassification = {
        try await NanightCribClassifier.shared.classify($0)
    }, measure: (@MainActor (NanightPresenceFrame, TimeInterval, Int) async -> NanightMotionMeasurement)? = nil,
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.classify = classify
        if let measure { self.measure = measure }
        else {
            let motion = NanightLocalMotion()
            self.measure = { await motion.measure($0, at: $1, session: $2) }
        }
        self.uptime = uptime
    }

    func reset() {
        generation += 1
        recordBoundary(.reset)
        session = UUID()
        likelySleeping = false
        lastResult = nil
        possibleBaby = false
        lastSample = -.infinity
        lastMotionSample = -.infinity
        motionWindow = NanightMotionWindow()
    }

    func suspend() {
        generation += 1
        recordBoundary(.interruption)
        likelySleeping = false
        lastResult = nil
        possibleBaby = false
        lastSample = -.infinity
        lastMotionSample = -.infinity
        motionWindow = NanightMotionWindow()
    }

    private func recordBoundary(_ kind: NanightSignalObservation.Kind) {
        guard let recorder = onObservation else { return }
        let observation = NanightSignalObservation(timestamp: Date(), session: session, kind: kind)
        Task {
            do { _ = try await recorder(observation) }
            catch { Self.logger.error("Could not save observation boundary") }
        }
    }

    func expire(at time: TimeInterval) {
        if let lastResult, time - lastResult > NanightAnalysisTiming.presenceFreshness { suspend() }
    }

    func submit(_ buffer: CVPixelBuffer, at time: TimeInterval) {
        guard !isProcessing else { return }
        let needsPresence = time - lastSample >= NanightAnalysisTiming.presenceInterval
        let needsMotion = time - lastMotionSample >= NanightAnalysisTiming.motionInterval
        guard needsPresence || needsMotion else { return }
        isProcessing = true
        if needsPresence { lastSample = time }
        if needsMotion { lastMotionSample = time }
        let expectedGeneration = generation
        let sampleSession = session
        let recorder = onObservation
        let classify = classify, measure = measure
        let frame = NanightPresenceFrame(buffer: buffer)
        Task { [weak self] in
            // One frame/job at a time, including persistence. Never queue video
            // frames behind inference or a slow history write.
            defer { self?.isProcessing = false }
            guard self?.generation == expectedGeneration else { return }
            if needsMotion {
                let movement = await measure(frame, time, expectedGeneration)
                guard let self, self.generation == expectedGeneration else { return }
                self.motionWindow.append(movement, at: time)
            }
            guard needsPresence else { return }
            let result: NanightCribClassification
            do {
                result = try await classify(frame)
            } catch {
                guard let self else { return }
                guard self.generation == expectedGeneration else { return }
                self.recordBoundary(.failure)
                self.suspend()
                self.lastSample = time
                Self.logger.error("Crib classification failed: \(String(describing: error), privacy: .public)")
                return
            }
            guard let self else { return }
            guard self.generation == expectedGeneration else { return }
            let now = self.uptime()
            // A delayed inference must not revive a stale frame.
            guard now - time <= NanightAnalysisTiming.inferenceDeadline else { self.suspend(); return }
            self.lastResult = time
            let movement = self.motionWindow.take(at: time)
            let observation = NanightSignalObservation(timestamp: Date().addingTimeInterval(time - now), session: sampleSession,
                kind: .sample, extractorVersion: 2, babySimilarity: result.babySimilarity, emptySimilarity: result.emptySimilarity,
                changedFraction: movement.changedFraction, brightnessChange: movement.brightnessChange,
                motionValid: movement.valid, inferenceMilliseconds: result.milliseconds)
            do {
                guard let recorder else { return }
                // Persistence happens first. The returned status comes from analysis
                // of the saved observations, never directly from this frame.
                let status = try await recorder(observation)
                guard self.generation == expectedGeneration else { return }
                self.possibleBaby = status.inBed
                self.likelySleeping = status.sleeping
            } catch {
                guard self.generation == expectedGeneration else { return }
                self.possibleBaby = false
                self.likelySleeping = false
                Self.logger.error("Could not save numeric observation")
            }
            Self.logger.notice("baby_similarity=\(result.babySimilarity, privacy: .public) empty_similarity=\(result.emptySimilarity, privacy: .public) margin=\(result.margin, privacy: .public) inference_ms=\(Int(result.milliseconds), privacy: .public) possible_baby=\(self.possibleBaby, privacy: .public)")
        }
    }
}
