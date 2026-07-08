@preconcurrency import AVKit
import Combine
import HaishinKit
import RTMPHaishinKit
import SwiftUI

@MainActor
final class NanightRTMPPlayer: ObservableObject {
    @Published private(set) var readyStateText = "Idle"
    @Published private(set) var lastErrorMessage: String?

    private var view: PiPHKView?
    private var connection: RTMPConnection?
    private var stream: RTMPStream?
    private var audioEngine: AVAudioEngine?
    private var audioPlayer: AudioPlayer?
    private var connectTask: Task<Void, Never>?
    private var statusTasks: [Task<Void, Never>] = []
    private var currentURL: URL?
    private var isMuted = true
    private var playbackGeneration = 0

    func start(url: URL, muted: Bool, paused: Bool) {
        let needsRestart = currentURL != url || stream == nil

        currentURL = url
        isMuted = muted
        lastErrorMessage = nil

        if paused {
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

        let session = invalidatePlayback()
        currentURL = url
        isMuted = muted
        lastErrorMessage = nil

        playbackGeneration += 1
        let generation = playbackGeneration
        connectTask = Task { [weak self] in
            await self?.closeSession(session)
            await self?.connect(url: url, generation: generation)
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
        guard let currentURL else {
            return
        }

        NanightLog.info("Restarting RTMPS playback to apply \(muted ? "muted" : "unmuted") audio output")
        restart(url: currentURL, muted: muted)
    }

    func close() {
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
            await self?.closeSession(session)
            await self?.connect(url: url, generation: generation)
        }
    }

    private func invalidatePlayback() -> NanightRTMPPlaybackSession {
        playbackGeneration += 1
        connectTask?.cancel()
        connectTask = nil
        statusTasks.forEach { $0.cancel() }
        statusTasks.removeAll()

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
            await configureAudio(muted: isMuted, stream: newStream)

            observeStatus(connection: newConnection, stream: newStream)

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
        }
    }

    private func isCurrentPlayback(_ generation: Int) -> Bool {
        generation == playbackGeneration
    }

    private func configureAudio(muted: Bool, stream: RTMPStream) async {
        guard !muted else {
            await stream.attachAudioPlayer(nil)
            audioPlayer = nil
            audioEngine = nil
            NanightLog.info("HaishinKit audio output detached for muted stream")
            return
        }

        let newAudioEngine = AVAudioEngine()
        let newAudioPlayer = AudioPlayer(audioEngine: newAudioEngine)
        audioEngine = newAudioEngine
        audioPlayer = newAudioPlayer
        await stream.attachAudioPlayer(newAudioPlayer)
        await applyStreamMute(muted, to: stream)
        NanightLog.info("HaishinKit audio output attached \(muted ? "muted" : "unmuted")")
    }

    private func applyAudioState(to stream: RTMPStream, generation: Int) async {
        if isMuted {
            await stream.attachAudioPlayer(nil)
            audioPlayer = nil
            audioEngine = nil
            NanightLog.info("HaishinKit audio output detached after muted playback start")
        } else {
            await applyStreamMute(false, to: stream)
            scheduleMuteRefresh(for: stream, generation: generation)
        }
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
                    Task {
                        await self.applyStreamMute(muted, to: stream)
                    }
                }
            }
        }
    }

    private func closeInactiveSession(stream: RTMPStream, connection: RTMPConnection) async {
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

    private func observeStatus(connection: RTMPConnection, stream: RTMPStream) {
        statusTasks.forEach { $0.cancel() }
        statusTasks = [
            Task { [weak self] in
                for await status in await connection.status {
                    await MainActor.run {
                        self?.readyStateText = status.code
                        NanightLog.info("HaishinKit connection status: \(status.code)")
                    }
                }
            },
            Task { [weak self] in
                for await status in await stream.status {
                    await MainActor.run {
                        self?.readyStateText = status.code
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
