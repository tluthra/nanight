import CoreImage
import CoreVideo
import Foundation
import Testing
@testable import Nanight

@MainActor struct LocalMotionTests {
    private func frame(level: CGFloat, patch: Bool = false) throws -> NanightPresenceFrame {
        let bounds = CGRect(x: 0, y: 0, width: 128, height: 96)
        var image = CIImage(color: CIColor(red: level, green: level, blue: level)).cropped(to: bounds)
        if patch {
            image = CIImage(color: CIColor(red: 0.75, green: 0.75, blue: 0.75))
                .cropped(to: CGRect(x: 45, y: 30, width: 30, height: 30)).composited(over: image)
        }
        var buffer: CVPixelBuffer?
        #expect(CVPixelBufferCreate(kCFAllocatorDefault, 128, 96, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess)
        let value = try #require(buffer)
        CIContext().render(image, to: value, bounds: bounds, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        return NanightPresenceFrame(buffer: value)
    }
    @Test func distinguishesLocalChangeFromBrightnessAndSessionGaps() async throws {
        let motion = NanightLocalMotion()
        let base = try frame(level: 0.4), brighter = try frame(level: 0.43), changed = try frame(level: 0.43, patch: true)
        #expect(await motion.measure(base, at: 0, session: 1).valid == false)
        #expect(await motion.measure(base, at: 3, session: 1).changedFraction! < 0.04)
        #expect(await motion.measure(brighter, at: 6, session: 1).changedFraction! < 0.04)
        #expect(await motion.measure(changed, at: 9, session: 1).changedFraction! > 0.04)
        #expect(await motion.measure(base, at: 12, session: 2).valid == false)
        #expect(await motion.measure(base, at: 30, session: 2).valid == false)
    }

    @Test func motionWindowKeepsPeaksAndNeverTurnsInvalidSamplesIntoQuiet() {
        var window = NanightMotionWindow()
        window.append(NanightMotionMeasurement(changedFraction: 0.2, brightnessChange: 0.01, valid: true), at: 3)
        window.append(NanightMotionMeasurement(changedFraction: 0, brightnessChange: 0.2, valid: true), at: 6)
        window.append(NanightMotionMeasurement(changedFraction: 0, brightnessChange: 0, valid: true), at: 9)
        let peaks = window.take(at: 10)
        #expect(peaks.changedFraction == 0.2)
        #expect(peaks.brightnessChange == 0.2)
        #expect(peaks.valid)
        #expect(!window.take(at: 11).valid)
        window.append(NanightMotionMeasurement(), at: 12)
        window.append(NanightMotionMeasurement(changedFraction: 0, brightnessChange: 0, valid: true), at: 15)
        #expect(!window.take(at: 20).valid)
        window.append(NanightMotionMeasurement(changedFraction: 0, brightnessChange: 0, valid: true), at: 21)
        #expect(!window.take(at: 30).valid)
    }
}
