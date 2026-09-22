import CoreVideo
import Foundation
import Testing
@testable import Nanight

@MainActor
struct PresenceSamplingTests {
    private let positive = NanightCribClassification(babySimilarity: 0.3, emptySimilarity: 0.2, milliseconds: 1)
    private let quiet = NanightMotionMeasurement(changedFraction: 0, brightnessChange: 0, valid: true)

    private func buffer() throws -> CVPixelBuffer {
        var value: CVPixelBuffer?
        #expect(CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA, nil, &value) == kCVReturnSuccess)
        return try #require(value)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        try #require(condition())
    }

    @Test func minuteOfFramesRunsSixClassificationsAndTwentyMotionChecks() async throws {
        var now: TimeInterval = 0
        var classifications: [TimeInterval] = [], motions: [TimeInterval] = []
        var saved: [NanightSignalObservation] = []
        let detector = NanightBabyPresence(classify: { _ in
            classifications.append(now)
            return positive
        }, measure: { _, time, _ in
            motions.append(time)
            // Motion at three seconds must survive the quiet frames at six/nine.
            return NanightMotionMeasurement(changedFraction: time == 3 ? Float(0.2) : 0, brightnessChange: 0, valid: true)
        }, uptime: { now })
        detector.onObservation = { observation in saved.append(observation); return NanightAnalysisStatus(inBed: true) }
        let frame = try buffer()
        for second in 0..<60 {
            now = Double(second)
            detector.expire(at: now)
            // Multiple frames per tick must not enqueue duplicate analysis work.
            for _ in 0..<30 { detector.submit(frame, at: now) }
            try await waitUntil { !detector.isProcessing }
        }
        #expect(classifications == [0, 10, 20, 30, 40, 50])
        #expect(motions == stride(from: 0.0, to: 60, by: 3).map { $0 })
        #expect(saved.count == 6)
        #expect(saved.allSatisfy { $0.kind == .sample && $0.extractorVersion == 2 })
        #expect(saved[1].changedFraction == 0.2)
        #expect(saved[2].changedFraction == 0)
        #expect(saved.allSatisfy { $0.motionValid })
        #expect(detector.possibleBaby)
    }

    @Test func freshnessAllowsTenSecondCadenceButExpiresWithoutANewClassification() async throws {
        var now: TimeInterval = 0
        let detector = NanightBabyPresence(classify: { _ in positive }, measure: { _, _, _ in quiet }, uptime: { now })
        detector.onObservation = { _ in NanightAnalysisStatus(inBed: true, sleeping: true) }
        let frame = try buffer()
        detector.submit(frame, at: now)
        try await waitUntil { !detector.isProcessing }
        for time in [3.0, 6, 9, 12, 15] {
            now = time
            detector.expire(at: now)
            #expect(detector.possibleBaby)
            #expect(detector.likelySleeping)
        }
        now = 15.01
        detector.expire(at: now)
        #expect(!detector.possibleBaby)
        #expect(!detector.likelySleeping)
        detector.submit(frame, at: now)
        try await waitUntil { !detector.isProcessing }
        #expect(detector.possibleBaby)
        detector.suspend()
        #expect(!detector.possibleBaby)
        #expect(!detector.likelySleeping)
    }

    @Test(arguments: ["deadline", "suspend", "reset"])
    func lateInferenceCannotRestoreStalePresence(scenario: String) async throws {
        var now: TimeInterval = 0
        var pending: CheckedContinuation<NanightCribClassification, Never>?
        var saved: [NanightSignalObservation] = []
        let detector = NanightBabyPresence(classify: { _ in
            await withCheckedContinuation { pending = $0 }
        }, measure: { _, _, _ in quiet }, uptime: { now })
        detector.onObservation = { observation in saved.append(observation); return NanightAnalysisStatus(inBed: true) }
        detector.submit(try buffer(), at: now)
        try await waitUntil { pending != nil }
        if scenario == "suspend" { detector.suspend() }
        else if scenario == "reset" { detector.reset() }
        else { now = 9 } // Result age remains limited to eight seconds, not fifteen.
        pending?.resume(returning: positive)
        pending = nil
        try await waitUntil { !detector.isProcessing }
        #expect(saved.allSatisfy { $0.kind != .sample })
        #expect(!detector.possibleBaby)
    }

    @Test func slowPersistenceDoesNotQueueFramesOrExtraInference() async throws {
        var now: TimeInterval = 0
        var classifications = 0
        var pending: CheckedContinuation<NanightAnalysisStatus, Never>?
        let detector = NanightBabyPresence(classify: { _ in classifications += 1; return positive },
                                          measure: { _, _, _ in quiet }, uptime: { now })
        detector.onObservation = { _ in await withCheckedContinuation { pending = $0 } }
        let frame = try buffer()
        detector.submit(frame, at: now)
        try await waitUntil { pending != nil }
        for second in 1...30 {
            now = Double(second)
            detector.submit(frame, at: now)
        }
        #expect(classifications == 1)
        pending?.resume(returning: NanightAnalysisStatus())
        pending = nil
        try await waitUntil { !detector.isProcessing }
        #expect(classifications == 1)
        detector.onObservation = { _ in NanightAnalysisStatus() }
        detector.submit(frame, at: now)
        try await waitUntil { !detector.isProcessing }
        #expect(classifications == 2)
    }
}
