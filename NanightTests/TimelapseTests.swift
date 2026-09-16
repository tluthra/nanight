import AppKit
import AVFoundation
import Testing
@testable import Nanight

@MainActor
struct TimelapseTests {
    @Test func exportsOrderedPhotosAtThirtyFramesPerSecond() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = NanightTimelapseFiles()
        var frames: [URL] = []
        for index in 0..<60 {
            let context = CGContext(data: nil, width: 320, height: 180, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            context.setFillColor(index < 30 ? NSColor.red.cgColor : NSColor.blue.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
            context.setFillColor(NSColor.green.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 320, height: 60))
            let url = folder.appendingPathComponent("\(index).jpg")
            try await files.save(context.makeImage()!, to: url)
            frames.append(url)
        }
        let video = try await files.export(frames: frames, folder: folder)
        let asset = AVURLAsset(url: video)
        let duration = try await asset.load(.duration)
        #expect(abs(duration.seconds - 2) < 0.01)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try #require(tracks.first)
        let size = try await track.load(.naturalSize)
        let rate = try await track.load(.nominalFrameRate)
        #expect(size == CGSize(width: 320, height: 180))
        #expect(abs(rate - 30) < 0.1)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        for (seconds, isRed) in [(0.2, true), (1.2, false)] {
            let image = try generator.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 30), actualTime: nil)
            let bitmap = NSBitmapImageRep(cgImage: image)
            let top = try #require(bitmap.colorAt(x: 160, y: 20)?.usingColorSpace(.deviceRGB))
            let bottom = try #require(bitmap.colorAt(x: 160, y: 160)?.usingColorSpace(.deviceRGB))
            #expect(bottom.greenComponent > 0.7)
            #expect(isRed ? top.redComponent > 0.7 : top.blueComponent > 0.7)
        }
        #expect(frames.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("Timelapse.partial.mp4").path))
    }

    @Test func failedExportPreservesPhotosAndRemovesPartialVideo() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = NanightTimelapseFiles()
        let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(NSColor.red.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let photo = folder.appendingPathComponent("first.jpg")
        try await files.save(context.makeImage()!, to: photo)
        do {
            _ = try await files.export(frames: [photo, folder.appendingPathComponent("missing.jpg")], folder: folder)
            Issue.record("Unreadable frame should fail export")
        } catch {
            #expect(error.localizedDescription.contains("could not be read"))
        }
        #expect(FileManager.default.fileExists(atPath: photo.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["first.jpg"])
    }

    @Test func rejectsEmptySessionWithoutCreatingVideo() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            _ = try await NanightTimelapseFiles().export(frames: [], folder: folder)
            Issue.record("Empty export should fail")
        } catch {
            #expect(error.localizedDescription.contains("No photos"))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }
}
