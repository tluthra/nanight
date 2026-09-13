import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import Nanight

@MainActor
struct StreamingRecoveryTests {
    private let fastTiming = NanightPlaybackTiming(initialFrameTimeout: 0.05, watchdogInterval: 0.01, retryDelayScale: 0.001)
    private let invalidURL = URL(string: "rtmps://localhost/invalid")!

    @Test func reopeningPopoverKeepsTheSameConnectionAttempt() async throws {
        let model = NanightAppModel()
        let player = NanightRTMPPlayer()
        model.rtmpPlayer = player
        defer { player.close() }
        var attempts = 0
        var cancellations = 0
        player.resolveStreamURL = { _ in
            attempts += 1
            do {
                try await Task.sleep(for: .seconds(10))
            } catch {
                cancellations += 1
                throw error
            }
            return invalidURL
        }
        player.start(url: invalidURL, muted: true, paused: false)
        try await waitUntil { attempts == 1 }
        for _ in 0..<10 {
            model.setVideoVisible(true)
            model.setVideoVisible(false)
            await Task.yield()
        }
        model.setVideoVisible(true)
        try await Task.sleep(for: .milliseconds(50))
        #expect(attempts == 1)
        #expect(cancellations == 0)
        #expect(player.readyStateText == "Connecting RTMPS stream")
    }

    @Test func explicitPauseSurvivesPopoverChangesAndResumesWhileHidden() async throws {
        let model = NanightAppModel()
        let player = NanightRTMPPlayer()
        model.rtmpPlayer = player
        defer { player.close() }
        var attempts = 0
        player.resolveStreamURL = { _ in
            attempts += 1
            try await Task.sleep(for: .seconds(10))
            return invalidURL
        }
        player.start(url: invalidURL, muted: true, paused: false)
        try await waitUntil { attempts == 1 }
        model.setVideoVisible(true)
        model.toggleVideo()
        model.setVideoVisible(false)
        model.setVideoVisible(true)
        await Task.yield()
        #expect(model.videoPaused)
        #expect(player.readyStateText == "Stream paused")
        #expect(attempts == 1)
        model.setVideoVisible(false)
        model.toggleVideo()
        try await waitUntil { attempts == 2 }
        #expect(!model.videoPaused)
    }

    @Test func hiddenPopoverMutesWithoutChangingTheAudioPreference() {
        let model = NanightAppModel()
        let player = AVPlayer()
        model.player = player
        model.audioMuted = false
        model.setVideoVisible(true)
        #expect(!player.isMuted)
        model.setVideoVisible(false)
        #expect(player.isMuted)
        #expect(!model.isAudioMuted)
        model.setVideoVisible(true)
        #expect(!player.isMuted)
        model.audioMuted = true
        model.setVideoVisible(false)
        model.setVideoVisible(true)
        #expect(player.isMuted)
    }

    @Test func hungURLResolutionIsReplacedByWatchdog() async throws {
        let player = NanightRTMPPlayer(timing: fastTiming)
        defer { player.close() }
        var attempts = 0
        player.resolveStreamURL = { _ in
            attempts += 1
            if attempts == 1 { try await Task.sleep(for: .seconds(10)) }
            return invalidURL
        }
        player.start(url: invalidURL, muted: true, paused: false)
        try await waitUntil { attempts == 2 && player.lastErrorMessage != nil }
        #expect(attempts == 2)
        #expect(player.readyStateText == "RTMPS playback failed")
    }

    @Test func earlyFailureRetriesBeforeInitialFrameTimeout() async throws {
        let player = NanightRTMPPlayer(timing: fastTiming)
        defer { player.close() }
        var attempts = 0
        player.resolveStreamURL = { _ in
            attempts += 1
            if attempts == 1 { throw URLError(.notConnectedToInternet) }
            return invalidURL
        }
        player.start(url: invalidURL, muted: true, paused: false)
        try await waitUntil { attempts == 2 }
        #expect(attempts == 2)
    }

    @Test func pauseCancelsRetryAndLateResolution() async throws {
        let player = NanightRTMPPlayer(timing: fastTiming)
        var attempts = 0
        player.resolveStreamURL = { _ in
            attempts += 1
            // Simulate a provider that returns even after cancellation.
            try? await Task.sleep(for: .milliseconds(100))
            return invalidURL
        }
        player.start(url: invalidURL, muted: true, paused: false)
        try await waitUntil { attempts == 1 }
        player.pause()
        try await Task.sleep(for: .milliseconds(150))
        #expect(attempts == 1)
        #expect(player.readyStateText == "Stream paused")
        #expect(player.lastErrorMessage == nil)
    }

    @Test func manualReconnectSupersedesPendingAttempt() async throws {
        let player = NanightRTMPPlayer(timing: fastTiming)
        defer { player.close() }
        var attempts = 0
        player.resolveStreamURL = { _ in
            attempts += 1
            if attempts == 1 { try? await Task.sleep(for: .milliseconds(200)) }
            return invalidURL
        }
        player.start(url: invalidURL, muted: true, paused: false)
        try await waitUntil { attempts == 1 }
        player.reconnect()
        try await waitUntil { attempts == 2 && player.lastErrorMessage != nil }
        #expect(attempts == 2)
        #expect(player.readyStateText == "RTMPS playback failed")
    }

    @Test func repeatedFailuresRequestFreshCredentials() async throws {
        let player = NanightRTMPPlayer(timing: fastTiming)
        defer { player.close() }
        var refreshes: [Bool] = []
        player.resolveStreamURL = { force in
            refreshes.append(force)
            if !force { throw URLError(.cannotConnectToHost) }
            return invalidURL
        }
        player.start(url: invalidURL, muted: true, paused: false)
        try await waitUntil { refreshes.contains(true) }
        #expect(refreshes.prefix(3).allSatisfy { !$0 })
    }

    @Test func rejectedCredentialsRequireSignInInsteadOfRetryLoop() async throws {
        let player = NanightRTMPPlayer(timing: fastTiming)
        var attempts = 0
        player.resolveStreamURL = { _ in
            attempts += 1
            throw NanitAPIError.authExpired("Expired refresh token")
        }
        player.start(url: invalidURL, muted: true, paused: false)
        try await waitUntil { player.readyStateText == "Authentication required" }
        try await Task.sleep(for: .milliseconds(100))
        #expect(attempts == 1)
        #expect(player.lastErrorMessage == "Sign in again to resume video.")
    }

    @Test func invalidOrRegressingFramesDoNotClaimLiveness() {
        var tracker = NanightVideoFrameTracker()
        tracker.startMonitoring(at: 0)
        tracker.recordFrame(presentationTimeStamp: .invalid, at: 1)
        tracker.recordFrame(presentationTimeStamp: .indefinite, at: 2)
        #expect(tracker.state(at: 11) == .stalled)
        tracker.recordFrame(presentationTimeStamp: CMTime(value: 10, timescale: 1), at: 12)
        tracker.recordFrame(presentationTimeStamp: CMTime(value: 9, timescale: 1), at: 12.1)
        #expect(tracker.state(at: 12.1) != .live)
        tracker.recordFrame(presentationTimeStamp: CMTime(value: 11, timescale: 1), at: 12.2)
        #expect(tracker.state(at: 12.2) == .live)
    }

    @Test func mailboxDropsBacklogAndRetainsNewestFrame() {
        let mailbox = NanightLatestFrameMailbox<Int>()
        #expect(mailbox.offer(0))
        for frame in 1...10_000 { #expect(!mailbox.offer(frame)) }
        #expect(mailbox.take() == 10_000)
        #expect(mailbox.take() == nil)
        #expect(mailbox.offer(10_001))
        #expect(mailbox.take() == 10_001)
    }

    @Test func disconnectStatusesRecoverButBufferingDoesNotThrash() {
        for code in ["NetConnection.Connect.Closed", "NetConnection.Connect.Rejected", "NetStream.Play.Stop", "NetStream.Play.StreamNotFound"] {
            #expect(NanightStreamStatusPolicy.requiresReconnect(code))
        }
        for code in ["NetStream.Play.Start", "NetStream.Buffer.Empty", "NetStream.Buffer.Full", "NetConnection.Connect.Success"] {
            #expect(!NanightStreamStatusPolicy.requiresReconnect(code))
        }
    }

    @Test func targetParsingOnlyRemovesFinalPathComponent() throws {
        let target = try NanightRTMPTarget(url: URL(string: "rtmps://stream.example/camera/camera?key=camera")!)
        #expect(target.command == "rtmps://stream.example/camera?key=camera")
        #expect(target.streamName == "camera")
        for url in ["https://stream.example/app/key", "rtmps://stream.example/app/", "rtmps://stream.example/key", "rtmps://user:password@stream.example/app/key"] {
            #expect(throws: (any Error).self) { try NanightRTMPTarget(url: URL(string: url)!) }
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(condition())
    }
}
