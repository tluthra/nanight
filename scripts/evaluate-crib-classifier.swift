// Compile alongside Nanight/NanightCribClassifier.swift. See docs/crib-classifier.md.
import CoreImage
import CoreVideo
import Foundation

@main struct EvaluateCribClassifier {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 6 else {
            print("Usage: evaluate-crib-classifier MODEL.mlmodelc CribPrompts.json DAY_BABY.png IR_BABY.png EMPTY_POPOVER.png")
            exit(2)
        }
        let classifier = NanightCribClassifier(modelURL: URL(fileURLWithPath: args[1]), promptsURL: URL(fileURLWithPath: args[2]))
        let context = CIContext()
        var failures = 0
        for (index, path) in args.dropFirst(3).enumerated() {
            guard var original = CIImage(contentsOf: URL(fileURLWithPath: path)) else { exit(2) }
            if index == 2 {
                // This supplied negative includes popover chrome. Remove only the
                // border; overlays stay, and do not become a training feature.
                let rect = CGRect(x: 13, y: original.extent.height - 481, width: 831, height: 465)
                original = original.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
            }
            let variants: [(String, CIImage)] = [
                ("original", original),
                ("grayscale", original.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])),
                ("darker", original.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: -0.6])),
                ("brighter", original.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: 0.3])),
                ("mirrored", original.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: original.extent.width, ty: 0)))
            ]
            for (name, image) in variants {
                var buffer: CVPixelBuffer?
                guard CVPixelBufferCreate(kCFAllocatorDefault, Int(image.extent.width), Int(image.extent.height), kCVPixelFormatType_32BGRA,
                                          [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer) == kCVReturnSuccess,
                      let buffer else { exit(2) }
                context.render(image, to: buffer, bounds: image.extent, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
                let result = try await classifier.classify(NanightPresenceFrame(buffer: buffer))
                let passed = result.detected == (index < 2)
                if !passed { failures += 1 }
                print("image=\(index + 1) variant=\(name) detected=\(result.detected) margin=\(String(format: "%.4f", result.margin)) ms=\(Int(result.milliseconds)) \(passed ? "PASS" : "FAIL")")
            }
        }
        guard failures == 0 else { exit(1) }
    }
}
