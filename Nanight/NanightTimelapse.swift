import AppKit
import AVFoundation
import Combine
import ImageIO
import UniformTypeIdentifiers

@MainActor
final class NanightTimelapse: ObservableObject {
    enum State { case idle, recording, exporting, saved }
    @Published private(set) var state: State = .idle
    @Published var errorMessage: String?
    private var captureTask: Task<Void, Never>?
    private var activity: NSObjectProtocol?
    private let files = NanightTimelapseFiles()
    private var folder: URL?
    private var frames: [URL] = []

    func start(model: NanightAppModel) {
        guard state == .idle || state == .saved else { return }
        do {
            let downloads = try FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask,
                                                        appropriateFor: nil, create: true)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
            let folder = downloads.appendingPathComponent("Nanight Timelapse \(formatter.string(from: Date())) \(UUID().uuidString.prefix(6))", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            self.folder = folder
            frames = []
            errorMessage = nil
            state = .recording
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                              reason: "Recording a Nanight timelapse")
            captureTask = Task { [weak self, weak model] in
                guard let self else { return }
                while !Task.isCancelled && state == .recording {
                    let nextCapture = ContinuousClock.now.advanced(by: .seconds(5))
                    do {
                        guard let model else { break }
                        let frame = try await NanightScreenshot.captureFrame(model: model, requireFresh: true)
                        try Task.checkCancellation()
                        let timestamp = Int64(Date().timeIntervalSince1970 * 1_000)
                        let url = folder.appendingPathComponent(String(format: "%06d-%lld.jpg", frames.count + 1, timestamp))
                        try await files.save(frame, to: url)
                        // Include an in-flight write even when Stop was clicked during disk I/O.
                        frames.append(url)
                    } catch is CancellationError {
                        break
                    } catch is NanightScreenshotError {
                        // A disconnected or stale stream has no frame to record. Try again next interval.
                    } catch {
                        errorMessage = "Timelapse capture stopped: \(error.localizedDescription). Captured photos remain in Downloads."
                        stop()
                        break
                    }
                    do { try await Task.sleep(until: nextCapture, clock: .continuous) }
                    catch { break }
                }
            }
        } catch {
            errorMessage = "Couldn’t start timelapse: \(error.localizedDescription)"
        }
    }

    func stop() {
        guard state == .recording, let folder else { return }
        state = .exporting
        let capture = captureTask
        capture?.cancel()
        captureTask = nil
        Task {
            // Finish any pending JPEG write before collecting the ordered frame list.
            await capture?.value
            do {
                let video = try await files.export(frames: frames, folder: folder)
                state = .saved
                NSWorkspace.shared.activateFileViewerSelecting([video])
            } catch {
                state = .idle
                errorMessage = "Couldn’t create timelapse video: \(error.localizedDescription). Your photos are still in \(folder.path)."
            }
            if let activity {
                ProcessInfo.processInfo.endActivity(activity)
                self.activity = nil
            }
            if state == .saved {
                try? await Task.sleep(for: .seconds(2))
                if state == .saved { state = .idle }
            }
        }
    }
}

// Image compression and video encoding run away from the main actor. Only one image
// is decoded at a time, so overnight sessions do not accumulate image data in memory.
actor NanightTimelapseFiles {
    enum ExportError: LocalizedError {
        case failed(String)
        var errorDescription: String? {
            switch self { case .failed(let message): return message }
        }
    }

    func save(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ExportError.failed("The photo file could not be opened.")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ExportError.failed("The photo could not be saved. Check available disk space.")
        }
    }

    func export(frames: [URL], folder: URL) async throws -> URL {
        guard let first = frames.first, let image = Self.read(first) else {
            throw ExportError.failed("No photos were captured.")
        }
        let width = max(2, image.width / 2 * 2)
        let height = max(2, image.height / 2 * 2)
        let temporary = folder.appendingPathComponent("Timelapse.partial.mp4")
        let result = folder.appendingPathComponent("Timelapse.mp4")
        let writer = try AVAssetWriter(outputURL: temporary, fileType: .mp4)
        var completed = false
        defer {
            if !completed {
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: temporary)
            }
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ])
        guard writer.canAdd(input) else { throw ExportError.failed("The video encoder is unavailable.") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? ExportError.failed("The video encoder could not start.") }
        writer.startSession(atSourceTime: .zero)
        for (index, url) in frames.enumerated() {
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing, ContinuousClock.now < deadline else {
                    throw writer.error ?? ExportError.failed("The video encoder stopped responding.")
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            try Task.checkCancellation()
            try autoreleasepool {
                guard let frame = Self.read(url), let pool = adaptor.pixelBufferPool else {
                    throw ExportError.failed("A saved photo could not be read.")
                }
                var buffer: CVPixelBuffer?
                guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else {
                    throw ExportError.failed("A video frame could not be allocated.")
                }
                CVPixelBufferLockBaseAddress(buffer, [])
                defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
                guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                                              bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else {
                    throw ExportError.failed("A video frame could not be rendered.")
                }
                context.setFillColor(CGColor(gray: 0, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                let scale = min(CGFloat(width) / CGFloat(frame.width), CGFloat(height) / CGFloat(frame.height))
                let size = CGSize(width: CGFloat(frame.width) * scale, height: CGFloat(frame.height) * scale)
                context.draw(frame, in: CGRect(x: (CGFloat(width) - size.width) / 2, y: (CGFloat(height) - size.height) / 2,
                                              width: size.width, height: size.height))
                guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 30)) else {
                    throw writer.error ?? ExportError.failed("A video frame could not be encoded.")
                }
            }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: Int64(frames.count), timescale: 30))
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? ExportError.failed("Video export failed.") }
        try FileManager.default.moveItem(at: temporary, to: result)
        completed = true
        return result
    }

    private static func read(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
