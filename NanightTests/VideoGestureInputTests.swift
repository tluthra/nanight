import AppKit
import Testing
@testable import Nanight

@MainActor
struct VideoGestureInputTests {
    @Test func routesWindowlessInputOverThePopoverWithoutCapturingOtherWindows() {
        #expect(NanightVideoGestureInput.routesToPopover(eventWindowNumber: 7, popoverWindowNumber: 7, popoverIsKey: false, pointerInside: true, ownsSequence: false))
        #expect(NanightVideoGestureInput.routesToPopover(eventWindowNumber: 0, popoverWindowNumber: 7, popoverIsKey: true, pointerInside: true, ownsSequence: false))
        #expect(NanightVideoGestureInput.routesToPopover(eventWindowNumber: 0, popoverWindowNumber: 7, popoverIsKey: true, pointerInside: false, ownsSequence: true))
        #expect(NanightVideoGestureInput.routesToPopover(eventWindowNumber: 0, popoverWindowNumber: 7, popoverIsKey: false, pointerInside: true, ownsSequence: false))
        #expect(!NanightVideoGestureInput.routesToPopover(eventWindowNumber: 0, popoverWindowNumber: 7, popoverIsKey: false, pointerInside: false, ownsSequence: true))
        #expect(!NanightVideoGestureInput.routesToPopover(eventWindowNumber: 0, popoverWindowNumber: 7, popoverIsKey: true, pointerInside: false, ownsSequence: false))
        #expect(!NanightVideoGestureInput.routesToPopover(eventWindowNumber: 8, popoverWindowNumber: 7, popoverIsKey: true, pointerInside: true, ownsSequence: true))
    }

    @Test func nativePinchAndRotateSequenceReachesTheTransformAndSettlesOnRelease() {
        let interaction = NanightVideoInteraction()
        let input = NanightVideoGestureInput(interaction: interaction)
        _ = input.handle(.init(type: .beginGesture))
        let pinch = input.handle(.init(type: .magnify, phase: .began, magnification: 1))
        #expect(pinch.consumed)
        #expect(interaction.scale == 2)
        let rotate = input.handle(.init(type: .rotate, phase: .began, counterclockwiseDegrees: -73))
        #expect(rotate.consumed)
        #expect(interaction.rotationDegrees == 73)
        #expect(!input.handle(.init(type: .magnify, phase: .ended)).settle)
        #expect(!input.handle(.init(type: .rotate, phase: .ended)).settle)
        #expect(input.handle(.init(type: .endGesture)).settle)
        interaction.snapRotation()
        #expect(interaction.rotationDegrees == 90)
        #expect(interaction.isPortrait)
        #expect(!input.isTransforming)
        #expect(!input.ownsSequence)
    }

    @Test func unphasedInputStillEndsAtTheNativeSequenceBoundary() {
        let interaction = NanightVideoInteraction()
        let input = NanightVideoGestureInput(interaction: interaction)
        _ = input.handle(.init(type: .magnify, magnification: 0.5))
        _ = input.handle(.init(type: .rotate, counterclockwiseDegrees: 60))
        #expect(interaction.scale == 1.5)
        #expect(interaction.rotationDegrees == -60)
        #expect(input.isTransforming)
        #expect(input.handle(.init(type: .endGesture)).settle)
        #expect(!input.isTransforming)
    }

    @Test func cancelledRotationDoesNotBlockSubsequentPan() {
        let interaction = NanightVideoInteraction()
        interaction.magnify(by: 1)
        let input = NanightVideoGestureInput(interaction: interaction)
        _ = input.handle(.init(type: .rotate, phase: .began, counterclockwiseDegrees: -20))
        let cancellation = input.handle(.init(type: .rotate, phase: .cancelled, counterclockwiseDegrees: 300))
        #expect(cancellation.settle)
        #expect(interaction.rotationDegrees == 20)
        #expect(!input.isTransforming)
        interaction.snapRotation()
        #expect(input.handle(.init(type: .scrollWheel, phase: .began, scroll: CGSize(width: 20, height: 10))).consumed)
        #expect(interaction.offset == CGSize(width: 20, height: 10))
    }

    @Test func freshScrollHasMomentumAndPinchCancelsAnOldCoast() {
        let interaction = NanightVideoInteraction()
        interaction.magnify(by: 1)
        let input = NanightVideoGestureInput(interaction: interaction)
        _ = input.handle(.init(type: .scrollWheel, phase: .began, scroll: CGSize(width: 10, height: 5)))
        _ = input.handle(.init(type: .scrollWheel, phase: .ended))
        _ = input.handle(.init(type: .scrollWheel, momentumPhase: .began, scroll: CGSize(width: 5, height: 2)))
        #expect(interaction.offset == CGSize(width: 15, height: 7))
        _ = input.handle(.init(type: .magnify, phase: .began))
        _ = input.handle(.init(type: .magnify, phase: .ended))
        let oldMomentum = input.handle(.init(type: .scrollWheel, momentumPhase: .changed, scroll: CGSize(width: 50, height: 50)))
        #expect(oldMomentum.reason == "old momentum suppressed")
        #expect(interaction.offset == CGSize(width: 15, height: 7))
        input.reset()
        #expect(!input.ownsSequence)
    }

    @Test func ordinaryMouseWheelIsNotConsumed() {
        let interaction = NanightVideoInteraction()
        interaction.magnify(by: 1)
        let input = NanightVideoGestureInput(interaction: interaction)
        let result = input.handle(.init(type: .scrollWheel, scroll: CGSize(width: 0, height: 20), precise: false))
        #expect(!result.consumed)
        #expect(interaction.offset == .zero)
    }
}
