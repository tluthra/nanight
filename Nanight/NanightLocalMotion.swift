import CoreImage
import CoreVideo
import Foundation

/// Coarse central-mattress image change, not clinical sleep or body-motion analysis.
/// Mean subtraction removes uniform drift; analysis interprets exposure changes.
nonisolated struct NanightMotionMeasurement: Sendable {
    var changedFraction: Float?
    var brightnessChange: Float?
    var valid = false
}

actor NanightLocalMotion {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var previous: [Float]?
    private var previousTime: TimeInterval?
    private var previousSession: Int?

    func measure(_ frame: NanightPresenceFrame, at time: TimeInterval, session: Int) -> NanightMotionMeasurement {
        let image = CIImage(cvPixelBuffer: frame.buffer)
        let region = image.extent.insetBy(dx: image.extent.width * 0.15, dy: image.extent.height * 0.15)
        let small = image.cropped(to: region)
            .transformed(by: CGAffineTransform(translationX: -region.minX, y: -region.minY))
            .transformed(by: CGAffineTransform(scaleX: 64 / region.width, y: 48 / region.height))
        var pixels = [UInt8](repeating: 0, count: 64 * 48 * 4)
        pixels.withUnsafeMutableBytes { bytes in
            context.render(small, toBitmap: bytes.baseAddress!, rowBytes: 64 * 4,
                           bounds: CGRect(x: 0, y: 0, width: 64, height: 48), format: .RGBA8,
                           colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
        var gray: [Float] = []
        gray.reserveCapacity(64 * 48)
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let red = Float(pixels[offset]) * 0.299
            let green = Float(pixels[offset + 1]) * 0.587
            let blue = Float(pixels[offset + 2]) * 0.114
            gray.append((red + green + blue) / 255)
        }
        defer { previous = gray; previousTime = time; previousSession = session }
        guard let previous, let previousTime, previousSession == session,
              time > previousTime, time - previousTime <= 8 else { return NanightMotionMeasurement() }
        let mean = gray.reduce(0, +) / Float(gray.count)
        let oldMean = previous.reduce(0, +) / Float(previous.count)
        let changed = zip(gray, previous).filter { abs(($0 - mean) - ($1 - oldMean)) > 0.07 }.count
        return NanightMotionMeasurement(changedFraction: Float(changed) / Float(gray.count),
                                        brightnessChange: abs(mean - oldMean), valid: true)
    }
}
