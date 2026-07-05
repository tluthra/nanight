import AVFoundation
import CoreMedia
import HaishinKit

final class NanightAudioRenderer: NSObject, StreamOutput, @unchecked Sendable {
    private struct FormatSignature: Equatable {
        let commonFormat: AVAudioCommonFormat
        let sampleRate: Double
        let channelCount: AVAudioChannelCount
        let isInterleaved: Bool

        init(_ format: AVAudioFormat) {
            commonFormat = format.commonFormat
            sampleRate = format.sampleRate
            channelCount = format.channelCount
            isInterleaved = format.isInterleaved
        }

        var logDescription: String {
            "\(Int(sampleRate)) Hz, \(channelCount) ch, \(commonFormat), interleaved=\(isInterleaved)"
        }
    }

    private let queue = DispatchQueue(label: "com.tanooj.Nanight.audio-renderer")
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let prebufferCount = 8
    private let maxQueuedBuffers = 48
    private let diagnosticInterval: TimeInterval = 5

    private var nodeAttached = false
    private var currentFormat: FormatSignature?
    private var enabled = false
    private var queuedBuffers = 0
    private var playedBuffers = 0
    private var droppedBuffers = 0
    private var maxArrivalGapMs = 0.0
    private var lastArrivalAt: Date?
    private var lastDiagnosticLogAt: Date?
    private var playbackStarted = false

    func setEnabled(_ enabled: Bool) {
        queue.async {
            self.enabled = enabled

            if enabled {
                self.lastArrivalAt = nil
                self.maxArrivalGapMs = 0
                self.playerNode.volume = 1
                NanightLog.info("Audio renderer enabled")
            } else {
                self.resetPlayback(stopEngine: false)
                self.resetDiagnostics()
                NanightLog.info("Audio renderer disabled")
            }
        }
    }

    func stop() {
        queue.async {
            self.enabled = false
            self.resetPlayback(stopEngine: true)
            self.resetDiagnostics()
            NanightLog.info("Audio renderer stopped")
        }
    }

    func stream(_ stream: some StreamConvertible, didOutput audio: AVAudioBuffer, when: AVAudioTime) {
        guard let audioBuffer = audio as? AVAudioPCMBuffer else {
            return
        }

        queue.async {
            self.enqueue(audioBuffer)
        }
    }

    func stream(_ stream: some StreamConvertible, didOutput video: CMSampleBuffer) {
    }

    private func enqueue(_ audioBuffer: AVAudioPCMBuffer) {
        guard enabled else {
            return
        }

        do {
            try configureIfNeeded(for: audioBuffer.format)
        } catch {
            NanightLog.error("Audio renderer failed to start: \(error.localizedDescription)")
            resetPlayback(stopEngine: true)
            enabled = false
            return
        }

        guard engine.isRunning else {
            NanightLog.warning("Audio renderer dropped buffer because engine is not running")
            return
        }

        updateArrivalDiagnostics()

        if queuedBuffers >= maxQueuedBuffers {
            droppedBuffers += queuedBuffers
            resetPlayback(stopEngine: false)
            NanightLog.warning("Audio renderer reset after queued buffers exceeded \(maxQueuedBuffers)")
        }

        queuedBuffers += 1
        playerNode.scheduleBuffer(audioBuffer) { [weak self] in
            self?.queue.async {
                guard let self else {
                    return
                }
                self.queuedBuffers = max(0, self.queuedBuffers - 1)
                self.playedBuffers += 1
            }
        }

        if !playbackStarted && queuedBuffers >= prebufferCount {
            playerNode.play()
            playbackStarted = true
            NanightLog.info("Audio renderer playback started with \(queuedBuffers) buffered packet(s)")
        }

        logDiagnosticsIfNeeded(audioBuffer: audioBuffer)
    }

    private func configureIfNeeded(for format: AVAudioFormat) throws {
        if !nodeAttached {
            engine.attach(playerNode)
            nodeAttached = true
        }

        let signature = FormatSignature(format)
        if currentFormat != signature {
            resetPlayback(stopEngine: true)
            engine.disconnectNodeOutput(playerNode)
            engine.connect(playerNode, to: engine.mainMixerNode, format: format)
            currentFormat = signature
            NanightLog.info("Audio renderer format: \(signature.logDescription)")
        }

        if !engine.isRunning {
            try engine.start()
        }

        playerNode.volume = enabled ? 1 : 0
    }

    private func resetPlayback(stopEngine: Bool) {
        playerNode.volume = 0
        if playerNode.isPlaying {
            playerNode.stop()
        }
        playerNode.reset()
        queuedBuffers = 0
        playbackStarted = false

        if stopEngine {
            engine.stop()
        }
    }

    private func resetDiagnostics() {
        maxArrivalGapMs = 0
        lastArrivalAt = nil
        lastDiagnosticLogAt = nil
    }

    private func updateArrivalDiagnostics() {
        let now = Date()
        if let lastArrivalAt {
            maxArrivalGapMs = max(maxArrivalGapMs, now.timeIntervalSince(lastArrivalAt) * 1000)
        }
        lastArrivalAt = now
    }

    private func logDiagnosticsIfNeeded(audioBuffer: AVAudioPCMBuffer) {
        let now = Date()
        guard lastDiagnosticLogAt == nil || now.timeIntervalSince(lastDiagnosticLogAt ?? now) >= diagnosticInterval else {
            return
        }

        let packetMs = audioBuffer.format.sampleRate > 0
            ? Double(audioBuffer.frameLength) / audioBuffer.format.sampleRate * 1000
            : 0
        NanightLog.info(
            "Audio renderer diagnostics: packet=\(String(format: "%.1f", packetMs))ms queued=\(queuedBuffers) played=\(playedBuffers) dropped=\(droppedBuffers) maxGap=\(String(format: "%.1f", maxArrivalGapMs))ms"
        )
        maxArrivalGapMs = 0
        lastDiagnosticLogAt = now
    }
}
