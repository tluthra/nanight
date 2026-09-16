import AppKit
import AVFoundation
import CoreImage

enum NanightScreenshotError: LocalizedError {
    case windowUnavailable
    case imageUnavailable

    var errorDescription: String? {
        switch self {
        case .windowUnavailable:
            return "Open the camera popover and try again."
        case .imageUnavailable:
            return "No video frame is available. Wait for live video and try again."
        }
    }
}

@MainActor
enum NanightScreenshot {
    static func save(model: NanightAppModel, interaction: NanightVideoInteraction, pixelScale: CGFloat) async throws -> URL {
        let viewport = interaction.viewportSize
        let scale = interaction.displayScale
        let rotation = interaction.rotationDegrees
        let offset = interaction.offset
        let aspectFit = model.player != nil
        let frame = try await captureFrame(model: model)
        let image = try render(frame: frame, viewport: viewport, scale: scale,
                               rotation: rotation, offset: offset, pixelScale: pixelScale, aspectFit: aspectFit)
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw NanightScreenshotError.imageUnavailable
        }
        let downloads = try FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask,
                                                    appropriateFor: nil, create: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss.SSS"
        let filename = "Nanight \(formatter.string(from: Date())) \(UUID().uuidString.prefix(8)).png"
        let url = downloads.appendingPathComponent(filename)
        try png.write(to: url, options: .atomic)
        return url
    }

    static func captureFrame(model: NanightAppModel, requireFresh: Bool = false) async throws -> CGImage {
        let buffer: CVPixelBuffer
        if let player = model.player, let item = player.currentItem {
            guard !requireFresh || player.timeControlStatus == .playing else {
                throw NanightScreenshotError.imageUnavailable
            }
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ])
            item.add(output)
            defer { item.remove(output) }
            var frame: CVPixelBuffer?
            for _ in 0..<20 {
                try await Task.sleep(nanoseconds: 25_000_000)
                guard player.currentItem === item else { throw NanightScreenshotError.imageUnavailable }
                frame = output.copyPixelBuffer(forItemTime: player.currentTime(), itemTimeForDisplay: nil)
                if frame != nil { break }
            }
            guard let frame else { throw NanightScreenshotError.imageUnavailable }
            buffer = frame
        } else if let player = model.rtmpPlayer,
                  !requireFresh || ProcessInfo.processInfo.systemUptime - player.screenshotFrameAt < 3,
                  let frame = player.screenshotPixelBuffer {
            buffer = frame
        } else {
            throw NanightScreenshotError.imageUnavailable
        }
        let source = CIImage(cvPixelBuffer: buffer)
        guard let frame = CIContext().createCGImage(source, from: source.extent) else {
            throw NanightScreenshotError.imageUnavailable
        }
        return frame
    }

    static func render(frame: CGImage, viewport: CGSize, scale: CGFloat, rotation: Double,
                       offset: CGSize, pixelScale: CGFloat, aspectFit: Bool) throws -> CGImage {
        guard let context = CGContext(data: nil, width: Int((viewport.width * pixelScale).rounded()),
                                      height: Int((viewport.height * pixelScale).rounded()),
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw NanightScreenshotError.imageUnavailable
        }
        context.scaleBy(x: pixelScale, y: pixelScale)
        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(origin: .zero, size: viewport))
        // SwiftUI uses a downward Y axis, while this bitmap context uses upward Y.
        context.translateBy(x: viewport.width / 2 + offset.width, y: viewport.height / 2 - offset.height)
        context.rotate(by: -rotation * .pi / 180)
        context.scaleBy(x: scale, y: scale)
        var size = NanightVideoInteraction.surfaceSize
        if aspectFit {
            let fit = min(size.width / CGFloat(frame.width), size.height / CGFloat(frame.height))
            size = CGSize(width: CGFloat(frame.width) * fit, height: CGFloat(frame.height) * fit)
        }
        context.interpolationQuality = .high
        context.draw(frame, in: CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height))
        guard let image = context.makeImage() else { throw NanightScreenshotError.imageUnavailable }
        return image
    }
}
