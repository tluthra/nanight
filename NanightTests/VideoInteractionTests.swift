import CoreGraphics
import Testing
@testable import Nanight

@MainActor
struct VideoInteractionTests {
    @Test func pinchIsProportionalAndKeepsThePointUnderThePointer() {
        let interaction = NanightVideoInteraction()
        let anchor = CGPoint(x: 80, y: -30)
        interaction.magnify(by: 1, around: anchor)
        #expect(interaction.scale == 2)
        #expect(interaction.offset == CGSize(width: -80, height: 30))
        interaction.magnify(by: 0.25, around: anchor)
        #expect(interaction.scale == 2.5)
        #expect(interaction.offset == CGSize(width: -120, height: 45))
        // The same image point remains under the cursor throughout the pinch.
        #expect((anchor.x - interaction.offset.width) / interaction.displayScale == anchor.x)
        #expect((anchor.y - interaction.offset.height) / interaction.displayScale == anchor.y)
    }

    @Test func zoomLimitsAndReturningToFitRecenterTheVideo() {
        let interaction = NanightVideoInteraction()
        interaction.magnify(by: 20)
        #expect(interaction.scale == 4)
        interaction.pan(by: CGSize(width: 10_000, height: -10_000))
        #expect(interaction.offset == CGSize(width: 780, height: -438))
        interaction.magnify(by: -0.99)
        #expect(interaction.scale == 1)
        #expect(interaction.offset == .zero)
        interaction.pan(by: CGSize(width: 30, height: 50))
        #expect(interaction.offset == .zero)
    }

    @Test(arguments: [44.0, 46, 89, 134, 136, 225, 271, 359, -44, -46, -91, -181, -359])
    func rotationTracksContinuouslyThenSnapsToTheNearestQuarterTurn(degrees: Double) {
        let interaction = NanightVideoInteraction()
        interaction.rotate(by: degrees)
        #expect(interaction.rotationDegrees == degrees)
        #expect(interaction.viewportSize == NanightVideoInteraction.surfaceSize)
        interaction.snapRotation()
        let target = (degrees / 90).rounded() * 90
        #expect(interaction.rotationDegrees == target)
        #expect(abs(target - degrees) <= 45)
        #expect(abs(interaction.displayScale - 1) < 0.000_001)
        let portrait = abs(target.truncatingRemainder(dividingBy: 180)) == 90
        #expect(interaction.viewportSize == (portrait ? CGSize(width: 292, height: 520) : CGSize(width: 520, height: 292)))
    }

    @Test func fullTurnsDoNotAnimateTheLongWayAround() {
        let interaction = NanightVideoInteraction()
        interaction.rotate(by: 359)
        interaction.snapRotation()
        #expect(interaction.rotationDegrees == 360)
        interaction.rotate(by: 91)
        interaction.snapRotation()
        #expect(interaction.rotationDegrees == 450)
        #expect(interaction.isPortrait)
        interaction.rotate(by: -181)
        interaction.snapRotation()
        #expect(interaction.rotationDegrees == 270)
    }

    @Test func portraitPanUsesScreenDirectionsAndRotatedBounds() {
        let interaction = NanightVideoInteraction()
        interaction.rotate(by: 90)
        interaction.snapRotation()
        interaction.magnify(by: 1)
        interaction.pan(by: CGSize(width: 10, height: -20))
        #expect(interaction.offset == CGSize(width: 10, height: -20))
        interaction.pan(by: CGSize(width: 10_000, height: -10_000))
        #expect(abs(interaction.offset.width - 146) < 0.000_001)
        #expect(abs(interaction.offset.height + 260) < 0.000_001)
    }

    @Test func rotationPreservesThePannedImagePositionThroughTheSnap() {
        let interaction = NanightVideoInteraction()
        interaction.magnify(by: 1)
        interaction.pan(by: CGSize(width: 50, height: 0))
        interaction.rotate(by: 90)
        interaction.snapRotation()
        #expect(abs(interaction.offset.width) < 0.000_001)
        #expect(abs(interaction.offset.height - 50) < 0.000_001)
        interaction.rotate(by: -90)
        interaction.snapRotation()
        #expect(abs(interaction.offset.width - 50) < 0.000_001)
        #expect(abs(interaction.offset.height) < 0.000_001)
    }

    @Test func repeatedPanMomentumCannotMoveTheVideoPastItsEdges() {
        let interaction = NanightVideoInteraction()
        interaction.rotate(by: -90)
        interaction.snapRotation()
        interaction.magnify(by: 2)
        for _ in 0..<500 { interaction.pan(by: CGSize(width: -13.25, height: 8.75)) }
        #expect(abs(interaction.offset.width + 292) < 0.000_001)
        #expect(abs(interaction.offset.height - 520) < 0.000_001)
    }

    @Test func invalidGestureValuesCannotCorruptTheTransform() {
        let interaction = NanightVideoInteraction()
        interaction.magnify(by: .nan)
        interaction.rotate(by: .infinity)
        interaction.pan(by: CGSize(width: CGFloat.infinity, height: 0))
        #expect(interaction.scale == 1)
        #expect(interaction.rotationDegrees == 0)
        #expect(interaction.offset == .zero)
        #expect(interaction.displayScale == 1)
    }
}
