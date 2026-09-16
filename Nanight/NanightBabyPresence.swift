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
    private let motion = NanightLocalMotion()
    private var lastResult: TimeInterval?
    private static let logger = Logger(subsystem: "com.tanooj.Nanight", category: "presence")
    private var lastSample: TimeInterval = -.infinity
    private var generation = 0
    private var busy = false

    func reset() {
        generation += 1
        recordBoundary(.reset)
        session = UUID()
        likelySleeping = false
        lastResult = nil
        possibleBaby = false
        lastSample = -.infinity
    }

    func suspend() {
        generation += 1
        recordBoundary(.interruption)
        likelySleeping = false
        lastResult = nil
        possibleBaby = false
        lastSample = -.infinity
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
        if let lastResult, time - lastResult > 8 { suspend() }
    }

    func submit(_ buffer: CVPixelBuffer, at time: TimeInterval) {
        guard !busy, time - lastSample >= 3 else { return }
        busy = true
        lastSample = time
        let expectedGeneration = generation
        let sampleSession = session
        let recorder = onObservation
        let frame = NanightPresenceFrame(buffer: buffer)
        Task { [weak self] in
            let result: NanightCribClassification
            let movement: NanightMotionMeasurement
            do {
                result = try await NanightCribClassifier.shared.classify(frame)
                movement = await self?.motion.measure(frame, at: time, session: expectedGeneration) ?? NanightMotionMeasurement()
            } catch {
                guard let self else { return }
                self.busy = false
                guard self.generation == expectedGeneration else { return }
                self.recordBoundary(.failure)
                self.suspend()
                self.lastSample = time
                Self.logger.error("Crib classification failed: \(String(describing: error), privacy: .public)")
                return
            }
            guard let self else { return }
            self.busy = false
            guard self.generation == expectedGeneration else { return }
            let now = ProcessInfo.processInfo.systemUptime
            // A delayed inference must not revive a stale frame.
            guard now - time <= 8 else { self.suspend(); return }
            self.lastResult = time
            let observation = NanightSignalObservation(timestamp: Date().addingTimeInterval(time - now), session: sampleSession,
                kind: .sample, babySimilarity: result.babySimilarity, emptySimilarity: result.emptySimilarity,
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
