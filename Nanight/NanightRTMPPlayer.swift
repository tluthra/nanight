@preconcurrency import AVKit
import Combine
import CoreMedia
import Foundation
import HaishinKit
import RTMPHaishinKit
import SwiftUI

enum NanightVideoFrameState: Equatable {
    case waitingForFrames
    case live
    case stalled
}

struct NanightVideoFrameTracker {
    let staleAfter: TimeInterval
    let initialFrameTimeout: TimeInterval

    private var monitoringStartedAt: TimeInterval?
    private var lastPresentationTimeStamp: CMTime?
    private var previousFrameUptime: TimeInterval?
    private var latestFrameUptime: TimeInterval?

    init(staleAfter: TimeInterval = 3, initialFrameTimeout: TimeInterval = 10) {
        self.staleAfter = staleAfter
        self.initialFrameTimeout = initialFrameTimeout
    }

    mutating func startMonitoring(at uptime: TimeInterval) {
        monitoringStartedAt = uptime
    }

    mutating func recordFrame(presentationTimeStamp: CMTime, at uptime: TimeInterval) {
        guard presentationTimeStamp.isNumeric else { return }
        if let lastPresentationTimeStamp,
           CMTimeCompare(lastPresentationTimeStamp, presentationTimeStamp) >= 0 {
            return
        }
        lastPresentationTimeStamp = presentationTimeStamp

        previousFrameUptime = latestFrameUptime
        latestFrameUptime = uptime
    }

    func state(at uptime: TimeInterval) -> NanightVideoFrameState {
        guard let latestFrameUptime else {
            if let monitoringStartedAt,
               uptime - monitoringStartedAt > initialFrameTimeout {
                return .stalled
            }
            return .waitingForFrames
        }

        guard let previousFrameUptime else {
            return uptime - latestFrameUptime > staleAfter ? .stalled : .waitingForFrames
        }

        if uptime - latestFrameUptime <= staleAfter,
           uptime - previousFrameUptime <= staleAfter {
            return .live
        }

        return .stalled
    }
}

enum NanightAutomaticReconnectPolicy {
    static let stableLiveInterval: TimeInterval = 10
    private static let minimumReconnectInterval: TimeInterval = 10
    private static let delays: [TimeInterval] = [1, 2, 4, 8, 15, 30]

    static func delay(
        forAttempt attempt: Int,
        secondsSinceLastReconnect: TimeInterval? = nil
    ) -> TimeInterval {
        let attemptIndex = min(max(attempt, 0), delays.count - 1)
        let backoffDelay = delays[attemptIndex]
        guard let secondsSinceLastReconnect else {
            return backoffDelay
        }

        let cooldownDelay = max(0, minimumReconnectInterval - max(0, secondsSinceLastReconnect))
        return max(backoffDelay, cooldownDelay)
    }

    static func nextAttempt(after attempt: Int) -> Int {
        min(attempt + 1, delays.count - 1)
    }
}

struct NanightPlaybackTiming {
    var initialFrameTimeout: TimeInterval = 20
    var watchdogInterval: TimeInterval = 0.5
    var retryDelayScale: Double = 1
}

// Keep at most one pending decoded frame when the main thread cannot keep up.
nonisolated final class NanightLatestFrameMailbox<Frame>: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: Frame?
    private var scheduled = false

    func offer(_ frame: Frame) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        pending = frame
        guard !scheduled else { return false }
        scheduled = true
        return true
    }

    func take() -> Frame? {
        lock.lock()
        defer { lock.unlock() }
        let frame = pending
        pending = nil
        scheduled = false
        return frame
    }
}

enum NanightVideoPresentation {
    static func displayImmediately(_ sample: CMSampleBuffer) {
        // HaishinKit has already paced decoded frames. Do not schedule them a second time.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
              CFArrayGetCount(attachments) > 0 else { return }
        let entry = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(entry, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    }
}

enum NanightStreamStatusPolicy {
    static func requiresReconnect(_ code: String) -> Bool {
        ["NetConnection.Connect.Closed", "NetConnection.Connect.Failed",
         "NetConnection.Connect.Rejected", "NetConnection.Connect.AppShutdown",
         "NetConnection.Connect.IdleTimeOut", "NetConnection.Connect.NetworkChange",
         "NetConnection.Connect.InvalidApp", "NetStream.Connect.Closed",
         "NetStream.Connect.Failed", "NetStream.Connect.Rejected", "NetStream.Failed",
         "NetStream.Play.Failed", "NetStream.Play.Stop", "NetStream.Play.StreamNotFound",
         "NetStream.Play.UnpublishNotify", "NetStream.Play.NoSupportedTrackFound",
         "NetStream.Play.FileStructureInvalid"].contains(code)
    }
}

@MainActor
final class NanightRTMPPlayer: ObservableObject {
    @Published private(set) var readyStateText = "Idle"
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var videoFrameState: NanightVideoFrameState = .waitingForFrames

    let babyPresence = NanightBabyPresence()

    private var view: PiPHKView?
    private(set) var screenshotPixelBuffer: CVPixelBuffer?
    private(set) var screenshotFrameAt: TimeInterval = 0
    private var connection: RTMPConnection?
    private var stream: RTMPStream?
    private var audioRenderer: NanightAudioRenderer?
    var resolveStreamURL: ((Bool) async throws -> URL)?
    private var requiresFreshToken = false
    private var transportFailed = false
    private var wantsPlayback = false
    private var isSleeping = false
    private var automaticReconnectTask: Task<Void, Never>?
    private var automaticReconnectAttempt = 0
    private var didResetReconnectBackoffForLiveRun = false
    private var lastAutomaticReconnectAt: TimeInterval?
    private var liveSinceUptime: TimeInterval?
    private var connectTask: Task<Void, Never>?
    private var frameWatchdogTask: Task<Void, Never>?
    private var statusTasks: [Task<Void, Never>] = []
    private var currentURL: URL?
    private var frameTracker: NanightVideoFrameTracker
    private let timing: NanightPlaybackTiming
    nonisolated private let pendingFrame = NanightLatestFrameMailbox<(RTMPStream, CMSampleBuffer)>()
    private var isMuted = true
    private var playbackGeneration = 0
    private var receivedFrameCount = 0
    private var presentedFrameCount = 0
    private var lastFrameDiagnosticAt: TimeInterval = 0

    init(timing: NanightPlaybackTiming = NanightPlaybackTiming()) {
        self.timing = timing
        frameTracker = NanightVideoFrameTracker(initialFrameTimeout: timing.initialFrameTimeout)
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc func willSleep() {
        isSleeping = true
        // Stop accepting audio synchronously before asynchronous stream teardown.
        audioRenderer?.stop()
        let session = invalidatePlayback()
        readyStateText = "Stream suspended during sleep"
        NanightLog.info("Suspending RTMPS playback for system sleep")
        Task { await closeSession(session) }
    }

    @objc func didWake() {
        guard isSleeping else { return }
        isSleeping = false
        guard wantsPlayback, let currentURL else { return }
        NanightLog.info("Rebuilding RTMPS playback after system wake")
        start(url: currentURL, muted: isMuted, paused: false)
    }

    func start(url: URL, muted: Bool, paused: Bool) {
        wantsPlayback = !paused
        let needsRestart = currentURL != url || stream == nil

        currentURL = url
        isMuted = muted
        lastErrorMessage = nil

        if paused || isSleeping {
            resetAutomaticReconnectBackoff()
            let session = invalidatePlayback()
            currentURL = url
            readyStateText = "RTMPS stream ready"
            NanightLog.info("HaishinKit RTMPS playback prepared while paused")
            Task {
                await closeSession(session)
            }
            return
        }

        guard needsRestart else {
            updateMuted(muted)
            NanightLog.info("HaishinKit RTMPS playback already matches requested audio state")
            return
        }

        resetAutomaticReconnectBackoff()
        let session = invalidatePlayback()
        currentURL = url
        isMuted = muted
        lastErrorMessage = nil

        playbackGeneration += 1
        let generation = playbackGeneration
        connectTask = Task { [weak self] in
            guard let self else {
                return
            }
            // Teardown may be waiting on a dead server. It must not gate the next attempt.
            Task { await self.closeSession(session) }
            guard !Task.isCancelled, self.isCurrentPlayback(generation) else {
                return
            }
            await self.connect(url: url, generation: generation)
        }
    }

    func reconnect() {
        guard let currentURL, wantsPlayback, !isSleeping else { return }
        resetAutomaticReconnectBackoff()
        restart(url: currentURL, muted: isMuted)
    }

    func play() {
        guard let currentURL else {
            readyStateText = "Stream unavailable"
            NanightLog.warning("HaishinKit play skipped because stream URL is missing")
            return
        }

        NanightLog.info("Starting HaishinKit RTMPS playback")
        start(url: currentURL, muted: isMuted, paused: false)
    }

    func pause() {
        NanightLog.info("Stopping HaishinKit RTMPS playback")
        close()
        readyStateText = "Stream paused"
    }

    func updateMuted(_ muted: Bool) {
        isMuted = muted
        audioRenderer?.setEnabled(!muted)
    }

    func close() {
        wantsPlayback = false
        resetAutomaticReconnectBackoff()
        let session = invalidatePlayback()
        Task {
            await closeSession(session)
        }
    }

    private func restart(url: URL, muted: Bool) {
        let session = invalidatePlayback()
        currentURL = url
        isMuted = muted
        lastErrorMessage = nil

        playbackGeneration += 1
        let generation = playbackGeneration
        connectTask = Task { [weak self] in
            guard let self else {
                return
            }
            // Teardown may be waiting on a dead server. It must not gate the next attempt.
            Task { await self.closeSession(session) }
            guard !Task.isCancelled, self.isCurrentPlayback(generation) else {
                return
            }
            await self.connect(url: url, generation: generation)
        }
    }

    private func invalidatePlayback() -> NanightRTMPPlaybackSession {
        babyPresence.suspend()
        playbackGeneration += 1
        automaticReconnectTask?.cancel()
        automaticReconnectTask = nil
        connectTask?.cancel()
        connectTask = nil
        frameWatchdogTask?.cancel()
        frameWatchdogTask = nil
        statusTasks.forEach { $0.cancel() }
        statusTasks.removeAll()
        liveSinceUptime = nil
        didResetReconnectBackoffForLiveRun = false
        transportFailed = false
        frameTracker = NanightVideoFrameTracker(initialFrameTimeout: timing.initialFrameTimeout)
        receivedFrameCount = 0
        presentedFrameCount = 0
        lastFrameDiagnosticAt = 0
        screenshotPixelBuffer = nil
        (view?.layer as? AVSampleBufferDisplayLayer)?.flushAndRemoveImage()
        videoFrameState = .waitingForFrames

        let session = NanightRTMPPlaybackSession(
            stream: stream,
            connection: connection,
            audioRenderer: audioRenderer
        )
        stream = nil
        connection = nil
        audioRenderer?.stop()
        audioRenderer = nil
        return session
    }

    private func closeSession(_ session: NanightRTMPPlaybackSession) async {
        session.audioRenderer?.stop()
        if let stream = session.stream {
            await stream.removeOutput(self)
            if let renderer = session.audioRenderer {
                await stream.removeOutput(renderer)
            }
            do {
                _ = try await stream.close()
            } catch {
                NanightLog.warning("HaishinKit RTMPS stream close skipped: \(error.localizedDescription)")
            }
        }

        if let connection = session.connection {
            do {
                try await connection.close()
            } catch {
                NanightLog.warning("HaishinKit RTMPS connection close skipped: \(error.localizedDescription)")
            }
        }
    }

    private func connect(url: URL, generation: Int) async {
        guard !Task.isCancelled, isCurrentPlayback(generation) else {
            return
        }

        readyStateText = "Connecting RTMPS stream"
        NanightLog.info("HaishinKit connecting to RTMPS stream")

        startFrameWatchdog(generation: generation)
        do {
            let forceRefresh = requiresFreshToken || automaticReconnectAttempt >= 3
            let resolvedURL = try await resolveStreamURL?(forceRefresh) ?? url
            guard isCurrentPlayback(generation), !transportFailed else { return }
            requiresFreshToken = false
            currentURL = resolvedURL
            let target = try NanightRTMPTarget(url: resolvedURL)
            let newConnection = RTMPConnection(flashVer: "MAC 9,0,124,2")
            let newStream = RTMPStream(connection: newConnection)

            connection = newConnection
            stream = newStream
            await newStream.addOutput(self)
            guard isCurrentPlayback(generation), !transportFailed else {
                await closeInactiveSession(stream: newStream, connection: newConnection)
                return
            }
            await configureAudio(muted: isMuted, stream: newStream)
            guard isCurrentPlayback(generation), !transportFailed else {
                await closeInactiveSession(stream: newStream, connection: newConnection)
                return
            }

            observeStatus(connection: newConnection, stream: newStream, generation: generation)

            _ = try await newConnection.connect(target.command)
            guard isCurrentPlayback(generation), !transportFailed else {
                await closeInactiveSession(stream: newStream, connection: newConnection)
                return
            }
            NanightLog.info("HaishinKit RTMPS connection opened")

            _ = try await newStream.play(target.streamName)
            guard isCurrentPlayback(generation), !transportFailed else {
                await closeInactiveSession(stream: newStream, connection: newConnection)
                return
            }
            audioRenderer?.setEnabled(!isMuted)
            readyStateText = "RTMPS stream open"
            NanightLog.info("HaishinKit RTMPS playback connected")
        } catch {
            guard isCurrentPlayback(generation) else {
                return
            }
            if let apiError = error as? NanitAPIError {
                switch apiError {
                case .authExpired, .invalidCredentials:
                    close()
                    lastErrorMessage = "Sign in again to resume video."
                    readyStateText = "Authentication required"
                    return
                default: break
                }
            }
            lastErrorMessage = error.localizedDescription
            readyStateText = "RTMPS playback failed"
            NanightLog.error("HaishinKit RTMPS playback failed: \(error.localizedDescription)")

            if !(error is NanightRTMPPlayerError) {
                failPlayback(reason: "Connection attempt failed")
            } else {
                frameWatchdogTask?.cancel()
            }
        }
    }

    private func isCurrentPlayback(_ generation: Int) -> Bool {
        generation == playbackGeneration && wantsPlayback && !isSleeping
    }

    private func startFrameWatchdog(generation: Int) {
        frameWatchdogTask?.cancel()
        frameTracker.startMonitoring(at: ProcessInfo.processInfo.systemUptime)
        let interval = UInt64(timing.watchdogInterval * 1_000_000_000)
        frameWatchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: interval)
                } catch {
                    return
                }

                guard let self, self.isCurrentPlayback(generation) else {
                    return
                }
                self.refreshVideoFrameState()
            }
        }
    }

    private func receivedVideoFrame(_ sample: CMSampleBuffer, from stream: RTMPStream) {
        guard self.stream === stream, wantsPlayback, !isSleeping, !transportFailed else {
            return
        }

        guard sample.isValid, CMSampleBufferDataIsReady(sample), sample.presentationTimeStamp.isNumeric else { return }
        // Liveness measures decoded frames, independently of display backpressure.
        receivedFrameCount += 1
        let now = ProcessInfo.processInfo.systemUptime
        frameTracker.recordFrame(presentationTimeStamp: sample.presentationTimeStamp, at: now)
        if let buffer = CMSampleBufferGetImageBuffer(sample) {
            screenshotPixelBuffer = buffer
            screenshotFrameAt = now
            babyPresence.submit(buffer, at: now)
        }
        if let layer = view?.layer as? AVSampleBufferDisplayLayer {
            if layer.status == .failed {
                NanightLog.warning("Resetting video display: \(layer.error?.localizedDescription ?? "unknown error")")
                layer.flushAndRemoveImage()
            }
            if layer.isReadyForMoreMediaData {
                NanightVideoPresentation.displayImmediately(sample)
                layer.enqueue(sample)
                presentedFrameCount += 1
            }
        }
        if now - lastFrameDiagnosticAt >= 5 {
            lastFrameDiagnosticAt = now
            NanightLog.info("Video frames: received=\(receivedFrameCount) presented=\(presentedFrameCount) generation=\(playbackGeneration)")
        }
        refreshVideoFrameState()
    }

    private func refreshVideoFrameState() {
        let now = ProcessInfo.processInfo.systemUptime
        let displayFailed = (view?.layer as? AVSampleBufferDisplayLayer)?.status == .failed
        let inputState = frameTracker.state(at: now)
        let nextState: NanightVideoFrameState = transportFailed || displayFailed ? .stalled : inputState
        if nextState != .live && videoFrameState == .live { babyPresence.suspend() }
        babyPresence.expire(at: now)

        if nextState == .live {
            if videoFrameState != .live {
                liveSinceUptime = now
                didResetReconnectBackoffForLiveRun = false
            } else if !didResetReconnectBackoffForLiveRun,
                      let liveSinceUptime,
                      now - liveSinceUptime >= NanightAutomaticReconnectPolicy.stableLiveInterval {
                automaticReconnectAttempt = 0
                lastAutomaticReconnectAt = nil
                didResetReconnectBackoffForLiveRun = true
                NanightLog.info("HaishinKit automatic reconnect backoff reset after stable video")
            }
        } else {
            liveSinceUptime = nil
            didResetReconnectBackoffForLiveRun = false
        }

        // A display failure can precede an input stall without changing the UI state.
        // Recovery must still start when the input later stops advancing.
        if nextState == .stalled && (transportFailed || inputState == .stalled) {
            readyStateText = "Reconnecting stream"
            scheduleAutomaticReconnect()
        }

        guard nextState != videoFrameState else {
            return
        }

        videoFrameState = nextState
        switch nextState {
        case .waitingForFrames:
            break
        case .live:
            automaticReconnectTask?.cancel()
            automaticReconnectTask = nil
            readyStateText = "Live video"
            lastErrorMessage = nil
            NanightLog.info("HaishinKit video frames are live")
        case .stalled:
            screenshotPixelBuffer = nil
            (view?.layer as? AVSampleBufferDisplayLayer)?.flushAndRemoveImage()
            NanightLog.warning("Video stalled: received=\(receivedFrameCount) presented=\(presentedFrameCount) displayFailed=\(displayFailed) transportFailed=\(transportFailed)")
            if transportFailed || inputState == .stalled {
                readyStateText = "Reconnecting stream"
            } else {
                readyStateText = "Recovering video display"
            }
        }
    }

    private func scheduleAutomaticReconnect() {
        guard wantsPlayback, !isSleeping, automaticReconnectTask == nil,
              let url = currentURL
        else {
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        let secondsSinceLastReconnect = lastAutomaticReconnectAt.map { now - $0 }
        let delay = NanightAutomaticReconnectPolicy.delay(
            forAttempt: automaticReconnectAttempt,
            secondsSinceLastReconnect: secondsSinceLastReconnect
        ) * timing.retryDelayScale
        let attempt = automaticReconnectAttempt + 1
        automaticReconnectAttempt = NanightAutomaticReconnectPolicy.nextAttempt(
            after: automaticReconnectAttempt
        )
        let generation = playbackGeneration
        NanightLog.info("HaishinKit scheduling automatic reconnect attempt \(attempt) in \(Int(delay))s")

        automaticReconnectTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return
            }

            guard let self else {
                return
            }

            guard self.isCurrentPlayback(generation), self.currentURL == url else { return }
            guard self.transportFailed || self.frameTracker.state(at: ProcessInfo.processInfo.systemUptime) == .stalled else {
                self.automaticReconnectTask = nil
                return
            }

            let muted = self.isMuted
            self.automaticReconnectTask = nil
            self.lastAutomaticReconnectAt = ProcessInfo.processInfo.systemUptime
            NanightLog.info("HaishinKit automatically reconnecting stalled video")
            self.restart(url: url, muted: muted)
        }
    }

    private func resetAutomaticReconnectBackoff() {
        automaticReconnectAttempt = 0
        lastAutomaticReconnectAt = nil
        liveSinceUptime = nil
        didResetReconnectBackoffForLiveRun = false
    }

    private func configureAudio(muted: Bool, stream: RTMPStream) async {
        // Leave HaishinKit's audio player detached so its unchecked play() path cannot run.
        let renderer = NanightAudioRenderer()
        audioRenderer = renderer
        renderer.setEnabled(!muted)
        await stream.addOutput(renderer)
        NanightLog.info("Protected audio renderer attached")
    }

    private func closeInactiveSession(stream: RTMPStream, connection: RTMPConnection) async {
        await stream.removeOutput(self)
        await stream.attachAudioPlayer(nil)

        do {
            _ = try await stream.close()
        } catch {
            NanightLog.warning("HaishinKit inactive stream close skipped: \(error.localizedDescription)")
        }

        do {
            try await connection.close()
        } catch {
            NanightLog.warning("HaishinKit inactive connection close skipped: \(error.localizedDescription)")
        }
    }

    private func observeStatus(connection: RTMPConnection, stream: RTMPStream, generation: Int) {
        statusTasks.forEach { $0.cancel() }
        statusTasks = [
            Task { [weak self] in
                for await status in await connection.status {
                    await MainActor.run {
                        guard let self,
                              self.isCurrentPlayback(generation),
                              self.connection === connection
                        else {
                            return
                        }
                        self.readyStateText = status.code
                        self.handleStatus(status.code)
                    }
                }
            },
            Task { [weak self] in
                for await status in await stream.status {
                    await MainActor.run {
                        guard let self,
                              self.isCurrentPlayback(generation),
                              self.stream === stream
                        else {
                            return
                        }
                        self.readyStateText = status.code
                        self.handleStatus(status.code)
                    }
                }
            }
        ]
    }

    private func handleStatus(_ code: String) {
        guard NanightStreamStatusPolicy.requiresReconnect(code) else { return }
        if code.hasSuffix("Rejected") || code.hasSuffix("StreamNotFound") {
            requiresFreshToken = true
        }
        failPlayback(reason: code)
    }

    private func failPlayback(reason: String) {
        transportFailed = true
        audioRenderer?.stop()
        videoFrameState = .stalled
        readyStateText = "Reconnecting stream"
        screenshotPixelBuffer = nil
        (view?.layer as? AVSampleBufferDisplayLayer)?.flushAndRemoveImage()
        NanightLog.warning("Stream recovery: \(reason)")
        scheduleAutomaticReconnect()
    }

}

extension NanightRTMPPlayer: StreamOutput {
    nonisolated func stream(
        _ stream: some StreamConvertible,
        didOutput audio: AVAudioBuffer,
        when: AVAudioTime
    ) {
    }

    nonisolated func stream(_ stream: some StreamConvertible, didOutput video: CMSampleBuffer) {
        guard let stream = stream as? RTMPStream else {
            return
        }

        guard pendingFrame.offer((stream, video)) else { return }
        Task { @MainActor [weak self] in
            guard let self, let (source, frame) = self.pendingFrame.take() else { return }
            self.receivedVideoFrame(frame, from: source)
        }
    }
}

private struct NanightRTMPPlaybackSession {
    let stream: RTMPStream?
    let connection: RTMPConnection?
    let audioRenderer: NanightAudioRenderer?
}

struct NanightRTMPTarget {
    let command: String
    let streamName: String

    init(url: URL) throws {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["rtmp", "rtmps"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.fragment == nil,
              let slash = components.percentEncodedPath.lastIndex(of: "/"),
              slash != components.percentEncodedPath.startIndex
        else { throw NanightRTMPPlayerError.invalidURL }
        let encodedName = String(components.percentEncodedPath[components.percentEncodedPath.index(after: slash)...])
        guard !encodedName.isEmpty else { throw NanightRTMPPlayerError.invalidURL }
        streamName = encodedName.removingPercentEncoding ?? encodedName
        components.percentEncodedPath = String(components.percentEncodedPath[..<slash])
        guard let command = components.url?.absoluteString else { throw NanightRTMPPlayerError.invalidURL }
        self.command = command
    }
}

extension NanightRTMPPlayer: PiPHKViewRepresentable.PreviewSource {
    nonisolated func connect(to view: PiPHKView) {
        Task { @MainActor in
            self.screenshotPixelBuffer = nil
            self.view = view
            (view.layer as? AVSampleBufferDisplayLayer)?.flushAndRemoveImage()
        }
    }
}

private enum NanightRTMPPlayerError: LocalizedError {
    case invalidURL
    case sessionUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "HaishinKit could not parse the RTMPS stream URL."
        case .sessionUnavailable:
            return "HaishinKit could not create an RTMPS playback session."
        }
    }
}
