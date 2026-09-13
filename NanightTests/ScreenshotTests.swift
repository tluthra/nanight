import AppKit
import Testing
@testable import Nanight

@MainActor
struct ScreenshotTests {
    private func quadrants() -> CGImage {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 100, pixelsHigh: 100,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for y in 0..<100 {
            for x in 0..<100 {
                let index = y * bitmap.bytesPerRow + x * 4
                bitmap.bitmapData![index] = (y < 50 && x < 50) || (y >= 50 && x >= 50) ? 255 : 0
                bitmap.bitmapData![index + 1] = x >= 50 ? 255 : 0
                bitmap.bitmapData![index + 2] = y >= 50 ? 255 : 0
                bitmap.bitmapData![index + 3] = 255
            }
        }
        return bitmap.cgImage!.copy(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!
    }

    @Test func cropKeepsZoomAndPanWithoutFlippingTheFrame() throws {
        let interaction = NanightVideoInteraction()
        interaction.magnify(by: 1)
        interaction.pan(by: CGSize(width: 260, height: 146))
        let image = try NanightScreenshot.render(frame: quadrants(), viewport: interaction.viewportSize,
            scale: interaction.displayScale, rotation: 0, offset: interaction.offset, pixelScale: 2, aspectFit: false)
        #expect(image.width == 1040)
        #expect(image.height == 584)
        let bitmap = NSBitmapImageRep(cgImage: image)
        for (x, y) in [(100, 100), (900, 100), (100, 480), (900, 480)] {
            let color = bitmap.colorAt(x: x, y: y)!
            #expect(color.redComponent > 0.95)
            #expect(color.greenComponent < 0.05)
            #expect(color.blueComponent < 0.05)
        }
    }

    @Test func portraitRotationMatchesClockwiseVideoRotation() throws {
        let image = try NanightScreenshot.render(frame: quadrants(), viewport: CGSize(width: 292, height: 520),
            scale: 1, rotation: 90, offset: .zero, pixelScale: 1, aspectFit: false)
        #expect(image.width == 292)
        #expect(image.height == 520)
        let bitmap = NSBitmapImageRep(cgImage: image)
        let topLeft = bitmap.colorAt(x: 30, y: 30)!
        let topRight = bitmap.colorAt(x: 260, y: 30)!
        #expect(topLeft.blueComponent > 0.95)
        #expect(topLeft.redComponent < 0.05)
        #expect(topRight.redComponent > 0.95)
        #expect(topRight.blueComponent < 0.05)
    }
}
