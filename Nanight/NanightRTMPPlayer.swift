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
    private var audioRenderer: NanightAudioRenderer?
    private var connectTask: Task<Void, Never>?
    private var statusTasks: [Task<Void, Never>] = []
    private var currentURL: URL?
    private var audioEnabled = false
    private var playbackGeneration = 0

    func start(url: URL, muted: Bool, paused: Bool) {
        let shouldEnableAudio = !muted
        let needsRestart = currentURL != url || stream == nil

        currentURL = url
        audioEnabled = shouldEnableAudio
        lastErrorMessage = nil

        if paused {
            close()
            currentURL = url
            readyStateText = "RTMPS stream ready"
            NanightLog.info("HaishinKit RTMPS playback prepared while paused")
            return
        }

        guard needsRestart else {
            applyAudioEnabled(shouldEnableAudio)
            NanightLog.info("HaishinKit RTMPS playback already matches requested audio state")
            return
        }

        close()
        currentURL = url
        audioEnabled = shouldEnableAudio
        lastErrorMessage = nil

        playbackGeneration += 1
        let generation = playbackGeneration
        connectTask = Task { [weak self] in
            await self?.connect(url: url, generation: generation, audioEnabled: shouldEnableAudio)
        }
    }

    func play() {
        guard let currentURL else {
            readyStateText = "Stream unavailable"
            NanightLog.warning("HaishinKit play skipped because stream URL is missing")
            return
        }

        NanightLog.info("Starting HaishinKit RTMPS playback")
        start(url: currentURL, muted: !audioEnabled, paused: false)
    }

    func pause() {
        NanightLog.info("Stopping HaishinKit RTMPS playback")
        close()
        readyStateText = "Stream paused"
    }

    func updateMuted(_ muted: Bool) {
        let shouldEnableAudio = !muted
        audioEnabled = shouldEnableAudio
        applyAudioEnabled(shouldEnableAudio)
    }

    func close() {
        playbackGeneration += 1
        connectTask?.cancel()
        connectTask = nil
        statusTasks.forEach { $0.cancel() }
        statusTasks.removeAll()

        let activeStream = stream
        let activeConnection = connection
        let activeAudioRenderer = audioRenderer
        audioRenderer?.setEnabled(false)
        audioRenderer = nil
        stream = nil
        connection = nil
        Task {
            if let activeStream, let activeAudioRenderer {
                await activeStream.removeOutput(activeAudioRenderer)
            }
            activeAudioRenderer?.stop()

            if let activeStream {
                do {
                    _ = try await activeStream.close()
                } catch {
                    NanightLog.warning("HaishinKit RTMPS stream close skipped: \(error.localizedDescription)")
                }
            }

            if let activeConnection {
                do {
                    try await activeConnection.close()
                } catch {
                    NanightLog.warning("HaishinKit RTMPS connection close skipped: \(error.localizedDescription)")
                }
            }
        }
    }

    private func connect(url: URL, generation: Int, audioEnabled: Bool) async {
        readyStateText = "Connecting RTMPS stream"
        NanightLog.info("HaishinKit connecting to RTMPS stream")

        do {
            let target = try NanightRTMPTarget(url: url)
            let newConnection = RTMPConnection(flashVer: "MAC 9,0,124,2")
            let newStream = RTMPStream(connection: newConnection)

            await attachVideoView(to: newStream)
            guard isCurrentPlayback(generation) else {
                await closeInactiveSession(stream: newStream, connection: newConnection, audioRenderer: nil)
                return
            }

            connection = newConnection
            stream = newStream
            let newAudioRenderer = NanightAudioRenderer()
            newAudioRenderer.setEnabled(audioEnabled)
            audioRenderer = newAudioRenderer
            await newStream.addOutput(newAudioRenderer)
            NanightLog.info(audioEnabled ? "Audio renderer attached to RTMPS stream" : "Audio renderer attached muted")

            observeStatus(connection: newConnection, stream: newStream)

            _ = try await newConnection.connect(target.command)
            guard isCurrentPlayback(generation) else {
                await closeInactiveSession(stream: newStream, connection: newConnection, audioRenderer: newAudioRenderer)
                return
            }
            NanightLog.info("HaishinKit RTMPS connection opened")

            _ = try await newStream.play(target.streamName)
            guard isCurrentPlayback(generation) else {
                await closeInactiveSession(stream: newStream, connection: newConnection, audioRenderer: newAudioRenderer)
                return
            }
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

    private func applyAudioEnabled(_ enabled: Bool) {
        audioRenderer?.setEnabled(enabled)
    }

    private func closeInactiveSession(stream: RTMPStream, connection: RTMPConnection, audioRenderer: NanightAudioRenderer?) async {
        if let audioRenderer {
            audioRenderer.setEnabled(false)
            await stream.removeOutput(audioRenderer)
            audioRenderer.stop()
        }

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
