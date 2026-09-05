@preconcurrency import AVKit
import AudioToolbox
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
        if presentationTimeStamp.isValid {
            if let lastPresentationTimeStamp,
               CMTimeCompare(lastPresentationTimeStamp, presentationTimeStamp) == 0 {
                return
            }
            lastPresentationTimeStamp = presentationTimeStamp
        }

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

@MainActor
final class NanightRTMPPlayer: ObservableObject {
    @Published private(set) var readyStateText = "Idle"
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var videoFrameState: NanightVideoFrameState = .waitingForFrames

    private var view: PiPHKView?
    private var connection: RTMPConnection?
    private var stream: RTMPStream?
    private var audioEngine: AVAudioEngine?
    private var audioPlayer: AudioPlayer?
    private var automaticReconnectTask: Task<Void, Never>?
    private var automaticReconnectAttempt = 0
    private var didResetReconnectBackoffForLiveRun = false
    private var lastAutomaticReconnectAt: TimeInterval?
    private var liveSinceUptime: TimeInterval?
    private var connectTask: Task<Void, Never>?
    private var frameWatchdogTask: Task<Void, Never>?
    private var statusTasks: [Task<Void, Never>] = []
    private var currentURL: URL?
    private var frameTracker = NanightVideoFrameTracker()
    private var isMuted = true
    private var playbackGeneration = 0

    func start(url: URL, muted: Bool, paused: Bool) {
        let needsRestart = currentURL != url || stream == nil

        currentURL = url
        isMuted = muted
        lastErrorMessage = nil

        if paused {
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
            await self.closeSession(session)
            guard !Task.isCancelled, self.isCurrentPlayback(generation) else {
                return
            }
            await self.connect(url: url, generation: generation)
        }
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
        applyEngineOutputMute(muted)
        Task { [weak self] in
            guard let self, let stream = self.stream else {
                return
            }

            await self.applyStreamMute(muted, to: stream)
        }
    }

    func close() {
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
            await self.closeSession(session)
            guard !Task.isCancelled, self.isCurrentPlayback(generation) else {
                return
            }
            await self.connect(url: url, generation: generation)
        }
    }

    private func invalidatePlayback() -> NanightRTMPPlaybackSession {
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
        frameTracker = NanightVideoFrameTracker()
        videoFrameState = .waitingForFrames

        let session = NanightRTMPPlaybackSession(
            stream: stream,
            connection: connection,
            audioEngine: audioEngine
        )
        stream = nil
        connection = nil
        audioPlayer = nil
        audioEngine = nil
        return session
    }

    private func closeSession(_ session: NanightRTMPPlaybackSession) async {
        if let stream = session.stream {
            await stream.removeOutput(self)
            await stream.attachAudioPlayer(nil)
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

        if session.audioEngine?.isRunning == true {
            session.audioEngine?.stop()
        }
    }

    private func connect(url: URL, generation: Int) async {
        guard !Task.isCancelled, isCurrentPlayback(generation) else {
            return
        }

        readyStateText = "Connecting RTMPS stream"
        NanightLog.info("HaishinKit connecting to RTMPS stream")

        do {
            let target = try NanightRTMPTarget(url: url)
            let newConnection = RTMPConnection(flashVer: "MAC 9,0,124,2")
            let newStream = RTMPStream(connection: newConnection)

            await attachVideoView(to: newStream)
            guard isCurrentPlayback(generation) else {
                await closeInactiveSession(stream: newStream, connection: newConnection)
                return
            }

            connection = newConnection
            stream = newStream
            await newStream.addOutput(self)
            await configureAudio(muted: isMuted, stream: newStream)

            observeStatus(connection: newConnection, stream: newStream, generation: generation)

            _ = try await newConnection.connect(target.command)
            guard isCurrentPlayback(generation) else {
                await closeInactiveSession(stream: newStream, connection: newConnection)
                return
            }
            NanightLog.info("HaishinKit RTMPS connection opened")

            _ = try await newStream.play(target.streamName)
            guard isCurrentPlayback(generation) else {
                await closeInactiveSession(stream: newStream, connection: newConnection)
                return
            }
            startFrameWatchdog(generation: generation)
            await applyAudioState(to: newStream, generation: generation)
            await attachVideoView(to: newStream)
            readyStateText = "RTMPS stream open"
            NanightLog.info("HaishinKit RTMPS playback connected")
        } catch {
            guard isCurrentPlayback(generation) else {
                return
            }
            lastErrorMessage = error.localizedDescription
            readyStateText = "RTMPS playback failed"
            NanightLog.error("HaishinKit RTMPS playback failed: \(error.localizedDescription)")

            if !(error is NanightRTMPPlayerError) {
                videoFrameState = .stalled
                scheduleAutomaticReconnect()
            }
        }
    }

    private func isCurrentPlayback(_ generation: Int) -> Bool {
        generation == playbackGeneration
    }

    private func startFrameWatchdog(generation: Int) {
        frameWatchdogTask?.cancel()
        frameTracker.startMonitoring(at: ProcessInfo.processInfo.systemUptime)
        frameWatchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 500_000_000)
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

    private func receivedVideoFrame(presentationTimeStamp: CMTime, from stream: RTMPStream) {
        guard self.stream === stream else {
            return
        }

        frameTracker.recordFrame(
            presentationTimeStamp: presentationTimeStamp,
            at: ProcessInfo.processInfo.systemUptime
        )
        refreshVideoFrameState()
    }

    private func refreshVideoFrameState() {
        let now = ProcessInfo.processInfo.systemUptime
        let nextState = frameTracker.state(at: now)

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
            NanightLog.info("HaishinKit video frames are live")
        case .stalled:
            NanightLog.warning("HaishinKit video frames stalled")
            scheduleAutomaticReconnect()
        }
    }

    private func scheduleAutomaticReconnect() {
        guard automaticReconnectTask == nil,
              let url = currentURL
        else {
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        let secondsSinceLastReconnect = lastAutomaticReconnectAt.map { now - $0 }
        let delay = NanightAutomaticReconnectPolicy.delay(
            forAttempt: automaticReconnectAttempt,
            secondsSinceLastReconnect: secondsSinceLastReconnect
        )
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

            guard self.isCurrentPlayback(generation),
                  self.videoFrameState == .stalled,
                  self.currentURL == url
            else {
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
        let newAudioEngine = AVAudioEngine()
        let newAudioPlayer = AudioPlayer(audioEngine: newAudioEngine)
        audioEngine = newAudioEngine
        audioPlayer = newAudioPlayer
        applyEngineOutputMute(muted)
        await stream.attachAudioPlayer(newAudioPlayer)
        await applyStreamMute(muted, to: stream)
        NanightLog.info("HaishinKit audio output attached \(muted ? "muted" : "unmuted")")
    }

    private func applyAudioState(to stream: RTMPStream, generation: Int) async {
        applyEngineOutputMute(isMuted)
        await applyStreamMute(isMuted, to: stream)
        scheduleMuteRefresh(for: stream, generation: generation)
    }

    private func applyEngineOutputMute(_ muted: Bool) {
        guard let parameterTree = audioEngine?.outputNode.auAudioUnit.parameterTree,
              let volumeParameter = parameterTree.parameter(withAddress: AUParameterAddress(kHALOutputParam_Volume))
        else {
            NanightLog.warning("HaishinKit audio output mute skipped because output volume parameter is unavailable")
            return
        }

        volumeParameter.value = muted ? 0 : 1
        NanightLog.info("HaishinKit audio output node \(muted ? "muted" : "unmuted")")
    }

    private func applyStreamMute(_ muted: Bool, to stream: RTMPStream) async {
        await stream.setSoundTransform(SoundTransform(volume: muted ? 0 : 1))
        NanightLog.info("HaishinKit audio player node \(muted ? "muted" : "unmuted")")
    }

    private func scheduleMuteRefresh(for stream: RTMPStream, generation: Int) {
        for delayNanoseconds in [250_000_000, 1_000_000_000, 2_000_000_000] {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delayNanoseconds))
                await MainActor.run {
                    guard let self, self.isCurrentPlayback(generation), self.stream === stream else {
                        return
                    }

                    let muted = self.isMuted
                    self.applyEngineOutputMute(muted)
                    Task {
                        await self.applyStreamMute(muted, to: stream)
                    }
                }
            }
        }
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
                        NanightLog.info("HaishinKit connection status: \(status.code)")
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
                        NanightLog.info("HaishinKit stream status: \(status.code)")
                    }
                }
            }
        ]
    }

    private func attachVideoView(to stream: RTMPStream) async {
        guard let view else {
            NanightLog.info("HaishinKit video view not ready yet")
            return
        }

        await stream.addOutput(view)
        NanightLog.info("HaishinKit video view attached to RTMPS stream")
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

        let presentationTimeStamp = video.presentationTimeStamp
        Task { @MainActor [weak self] in
            self?.receivedVideoFrame(presentationTimeStamp: presentationTimeStamp, from: stream)
        }
    }
}

private struct NanightRTMPPlaybackSession {
    let stream: RTMPStream?
    let connection: RTMPConnection?
    let audioEngine: AVAudioEngine?
}

private struct NanightRTMPTarget {
    let command: String
    let streamName: String

    init(url: URL) throws {
        let pathComponents = url.pathComponents
        guard pathComponents.count >= 3,
              let streamName = pathComponents.last,
              !streamName.isEmpty
        else {
            throw NanightRTMPPlayerError.invalidURL
        }

        self.streamName = streamName
        let targetPath = "/" + streamName
        let absoluteString = url.absoluteString
        guard let range = absoluteString.range(of: targetPath) else {
            throw NanightRTMPPlayerError.invalidURL
        }
        self.command = absoluteString.replacingOccurrences(of: targetPath, with: "", options: [], range: range)
    }
}

extension NanightRTMPPlayer: PiPHKViewRepresentable.PreviewSource {
    nonisolated func connect(to view: PiPHKView) {
        Task { @MainActor in
            self.view = view
            if let stream = self.stream {
                await self.attachVideoView(to: stream)
            }
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
