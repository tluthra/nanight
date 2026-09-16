import Foundation
import Testing
@testable import Nanight

struct SignalAnalysisTests {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)
    private func sample(_ seconds: Double, session: UUID, baby: Float = 0.3, empty: Float = 0.2,
                        fraction: Float = 0) -> NanightSignalObservation {
        NanightSignalObservation(timestamp: origin.addingTimeInterval(seconds), session: session,
            kind: .sample, babySimilarity: baby, emptySimilarity: empty,
            changedFraction: fraction, brightnessChange: 0, motionValid: true)
    }

    @Test func numericEvidenceReplaysIdenticallyAndDuplicatesDoNotConfirmPresence() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("test.sqlite")
        let store = NanightActivityStore(url: url), session = UUID()
        let first = sample(0, session: session)
        #expect(try await store.recordSignal(camera: "one", observation: first).inBed == false)
        #expect(try await store.recordSignal(camera: "one", observation: first).inBed == false)
        var direct = NanightSignalAnalysis()
        direct.consume(first)
        for t in stride(from: 3, through: 180, by: 3) {
            let obs = sample(Double(t), session: session, baby: t == 153 ? 0.18 : 0.3,
                             empty: 0.2, fraction: t == 156 ? 0.1 : 0)
            direct.consume(obs)
            let status = try await store.recordSignal(camera: "one", observation: obs)
            #expect(status.inBed == direct.status.inBed)
            #expect(status.sleeping == direct.status.sleeping)
        }
        let reopened = NanightActivityStore(url: url)
        let saved = try await reopened.signals(camera: "one")
        #expect(saved.count == 61)
        #expect(saved[51].babySimilarity == 0.18)
        #expect(saved[52].changedFraction == 0.1)
        var replay = NanightSignalAnalysis()
        saved.forEach { replay.consume($0) }
        #expect(replay.status.sleeping)
        #expect(replay.blocks.count == 2)
        #expect(replay.blocks.mapValues(\.end) == direct.blocks.mapValues(\.end))
        #expect(try await reopened.signals(camera: "two").isEmpty)
        let days = try await reopened.days(camera: "one", endingAt: origin, count: 1)
        #expect(days[0].blocks.count == 2)
        try await reopened.clear(at: origin.addingTimeInterval(181))
        _ = try await reopened.recordSignal(camera: "one", observation: first)
        #expect(try await reopened.signals(camera: "one").isEmpty)
        #expect(try await reopened.days(camera: "one", endingAt: origin, count: 1)[0].blocks.isEmpty)
    }

    @Test func delayedBoundaryReplaysAndCameraSessionsStaySeparate() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = NanightActivityStore(url: folder.appendingPathComponent("test.sqlite")), session = UUID()
        for t in stride(from: 0, through: 150, by: 3) {
            _ = try await store.recordSignal(camera: "one", observation: sample(Double(t), session: session))
        }
        let boundary = NanightSignalObservation(timestamp: origin.addingTimeInterval(140), session: session, kind: .interruption)
        let status = try await store.recordSignal(camera: "one", observation: boundary)
        #expect(status.inBed)
        #expect(!status.sleeping)
        #expect(try await store.recordSignal(camera: "two", observation: sample(153, session: UUID())).inBed == false)
        #expect(try await store.recordSignal(camera: "one", observation: sample(153, session: UUID())).inBed == false)
    }

    @Test func invalidMotionAndExposureDoNotBecomeQuietEvidence() {
        var analysis = NanightSignalAnalysis()
        let session = UUID()
        for t in stride(from: 0, through: 180, by: 3) {
            var obs = sample(Double(t), session: session)
            obs.brightnessChange = 0.2
            analysis.consume(obs)
        }
        #expect(analysis.status.inBed)
        #expect(!analysis.status.sleeping)
    }
    @Test func laptopGapJoinsPresenceAndRetrospectivelyEstimatesSleep() {
        var analysis = NanightSignalAnalysis()
        let session = UUID()
        // Quiet presence before closing the lid, not yet two minutes of sleep evidence.
        for t in stride(from: 0, through: 60, by: 3) { analysis.consume(sample(Double(t), session: session)) }
        analysis.consume(NanightSignalObservation(timestamp: origin.addingTimeInterval(61), session: session, kind: .interruption))
        #expect(!analysis.status.inBed)
        #expect(analysis.blocks.count == 1)
        let resume = 60 + 56 * 60
        for t in stride(from: resume, through: resume + 150, by: 3) {
            var obs = sample(Double(t), session: session)
            if t == resume { obs.motionValid = false }
            analysis.consume(obs)
        }
        let beds = analysis.blocks.values.filter { $0.kind == "IN_BED" }
        let sleeps = analysis.blocks.values.filter { $0.kind == "SLEEPING" }
        #expect(beds.count == 1)
        #expect(beds.first?.start == origin)
        #expect(beds.first?.inferredIntervals.first?.duration == TimeInterval(56 * 60))
        #expect(sleeps.count == 1)
        #expect(sleeps.first?.start == origin.addingTimeInterval(120))
        #expect(sleeps.first?.duration ?? 0 > 50 * 60)
        #expect(sleeps.first?.tooltip.contains("Includes inferred time") == true)
        #expect(analysis.status.sleeping)
    }

    @Test func movingAfterReturnCanBridgePresenceButNotSleep() {
        var analysis = NanightSignalAnalysis()
        let session = UUID()
        for t in stride(from: 0, through: 150, by: 3) { analysis.consume(sample(Double(t), session: session)) }
        for t in stride(from: 3600, through: 3780, by: 3) {
            analysis.consume(sample(Double(t), session: session, fraction: 0.2))
        }
        #expect(analysis.blocks.values.filter { $0.kind == "IN_BED" }.count == 1)
        #expect(analysis.blocks.values.filter { $0.kind == "SLEEPING" }.allSatisfy { $0.inferredIntervals.isEmpty })
        #expect(!analysis.status.sleeping)
    }

    @Test func emptyResetAndExcessiveGapsPreventInference() {
        for scenario in ["empty", "reset", "long", "session", "failure"] {
            var analysis = NanightSignalAnalysis()
            let session = UUID()
            for t in stride(from: 0, through: 150, by: 3) { analysis.consume(sample(Double(t), session: session)) }
            if scenario == "reset" || scenario == "failure" {
                analysis.consume(NanightSignalObservation(timestamp: origin.addingTimeInterval(151), session: session,
                    kind: scenario == "reset" ? .reset : .failure))
            }
            let resume = scenario == "long" ? 3 * 3600 : 3600
            if scenario == "empty" { analysis.consume(sample(Double(resume - 3), session: session, baby: 0.1, empty: 0.3)) }
            let afterSession = scenario == "session" ? UUID() : session
            for t in stride(from: resume, through: resume + 150, by: 3) {
                analysis.consume(sample(Double(t), session: afterSession))
            }
            #expect(analysis.blocks.values.filter { $0.kind == "IN_BED" }.count == 2, "Scenario: \(scenario)")
            #expect(analysis.blocks.values.allSatisfy { $0.inferredIntervals.isEmpty })
        }
    }

    @Test func gapInferenceReplaysFromSavedEvidence() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("test.sqlite")
        let store = NanightActivityStore(url: url), session = UUID()
        for t in Array(stride(from: 0, through: 150, by: 3)) + Array(stride(from: 3600, through: 3750, by: 3)) {
            _ = try await store.recordSignal(camera: "one", observation: sample(Double(t), session: session))
        }
        let reopened = NanightActivityStore(url: url)
        let before = try await store.days(camera: "one", endingAt: origin, count: 1)[0].blocks
        let after = try await reopened.days(camera: "one", endingAt: origin, count: 1)[0].blocks
        #expect(before.map(\.tooltip) == after.map(\.tooltip))
        #expect(after.count == 2)
        #expect(after.allSatisfy { !$0.inferredIntervals.isEmpty })
        #expect(try await reopened.signals(camera: "one").count == 102)
    }

    @Test func briefBaselineRestartAfterWakeDoesNotDiscardQuietGapEvidence() {
        var analysis = NanightSignalAnalysis()
        let session = UUID()
        for t in stride(from: 0, through: 60, by: 3) { analysis.consume(sample(Double(t), session: session)) }
        for t in stride(from: 3600, through: 3900, by: 3) {
            var obs = sample(Double(t), session: session)
            if t == 3600 || t == 3708 {
                analysis.consume(NanightSignalObservation(timestamp: obs.timestamp, session: session, kind: .interruption))
                obs.motionValid = false; obs.changedFraction = nil; obs.brightnessChange = nil
            }
            analysis.consume(obs)
        }
        let sleep = analysis.blocks.values.filter { $0.kind == "SLEEPING" }
        #expect(sleep.count == 1)
        #expect(sleep.first?.start == origin.addingTimeInterval(120))
        #expect(sleep.first?.inferredIntervals.isEmpty == false)
    }

}
