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
    private let audioPlayer = AudioPlayer(audioEngine: AVAudioEngine())
    private var connectTask: Task<Void, Never>?
    private var statusTasks: [Task<Void, Never>] = []
    private var currentURL: URL?
    private var isMuted = true

    func start(url: URL, muted: Bool, paused: Bool) {
        guard currentURL != url || stream == nil else {
            updateMuted(muted)
            if paused {
                close()
            }
            return
        }

        close()
        currentURL = url
        isMuted = muted
        lastErrorMessage = nil

        if paused {
            readyStateText = "RTMPS stream ready"
            NanightLog.info("HaishinKit RTMPS playback prepared while paused")
            return
        }

        connectTask = Task { [weak self] in
            await self?.connect(url: url)
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
        Task { [weak self] in
            guard let self, let stream = self.stream else {
                return
            }

            await stream.setSoundTransform(SoundTransform(volume: muted ? 0 : 1))
        }
    }

    func close() {
        connectTask?.cancel()
        connectTask = nil
        statusTasks.forEach { $0.cancel() }
        statusTasks.removeAll()

        let activeStream = stream
        let activeConnection = connection
        stream = nil
        connection = nil
        Task {
            do {
                _ = try await activeStream?.close()
                try await activeConnection?.close()
            } catch {
                NanightLog.error("HaishinKit RTMPS close failed: \(error.localizedDescription)")
            }
        }
    }

    private func connect(url: URL) async {
        readyStateText = "Connecting RTMPS stream"
        NanightLog.info("HaishinKit connecting to RTMPS stream")

        do {
            let target = try NanightRTMPTarget(url: url)
            let newConnection = RTMPConnection(flashVer: "MAC 9,0,124,2")
            let newStream = RTMPStream(connection: newConnection)

            await attachVideoView(to: newStream)
            await newStream.attachAudioPlayer(audioPlayer)
            await newStream.setSoundTransform(SoundTransform(volume: isMuted ? 0 : 1))

            connection = newConnection
            stream = newStream
            observeStatus(connection: newConnection, stream: newStream)

            _ = try await newConnection.connect(target.command)
            NanightLog.info("HaishinKit RTMPS connection opened")

            _ = try await newStream.play(target.streamName)
            await attachVideoView(to: newStream)
            readyStateText = "RTMPS stream open"
            NanightLog.info("HaishinKit RTMPS playback connected")
        } catch {
            lastErrorMessage = error.localizedDescription
            readyStateText = "RTMPS playback failed"
            NanightLog.error("HaishinKit RTMPS playback failed: \(error.localizedDescription)")
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
