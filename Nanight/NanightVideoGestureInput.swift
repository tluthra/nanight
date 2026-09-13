import AppKit

// A value snapshot of native input, also used by the event-delivery tests.
struct NanightVideoGestureEvent {
    let type: NSEvent.EventType
    var phase: NSEvent.Phase = []
    var momentumPhase: NSEvent.Phase = []
    var magnification: CGFloat = 0
    var counterclockwiseDegrees: CGFloat = 0
    var scroll: CGSize = .zero
    var precise = true
    var anchor: CGPoint = .zero
}

@MainActor
final class NanightVideoGestureInput {
    struct Result {
        let consumed: Bool
        let settle: Bool
        let reason: String
    }

    private let interaction: NanightVideoInteraction
    private(set) var isMagnifying = false
    private(set) var isRotating = false
    private var sequenceActive = false
    private var acceptsMomentum = false

    var isTransforming: Bool { isMagnifying || isRotating }
    var ownsSequence: Bool { sequenceActive || isTransforming || acceptsMomentum }

    init(interaction: NanightVideoInteraction) {
        self.interaction = interaction
    }

    static func routesToPopover(eventWindowNumber: Int, popoverWindowNumber: Int, popoverIsKey: Bool, pointerInside: Bool, ownsSequence: Bool) -> Bool {
        if eventWindowNumber == popoverWindowNumber { return true }
        // Local monitors already restrict us to this app. A popover may not be
        // key, so windowless input over its video must still be accepted.
        // Outside its bounds, only continue a sequence owned by the key popover.
        return eventWindowNumber <= 0 && (pointerInside || (popoverIsKey && ownsSequence))
    }

    func reset() {
        isMagnifying = false
        isRotating = false
        sequenceActive = false
        acceptsMomentum = false
    }

    func handle(_ event: NanightVideoGestureEvent) -> Result {
        let terminal = event.phase.contains(.ended) || event.phase.contains(.cancelled)
        switch event.type {
        case .beginGesture:
            reset()
            sequenceActive = true
            return Result(consumed: true, settle: false, reason: "sequence began")
        case .endGesture:
            reset()
            return Result(consumed: true, settle: true, reason: "sequence ended")
        case .magnify:
            acceptsMomentum = false
            isMagnifying = !terminal
            if !event.phase.contains(.cancelled) {
                interaction.magnify(by: event.magnification, around: event.anchor)
            }
            return Result(consumed: true, settle: terminal && !isTransforming && !sequenceActive, reason: "pinch")
        case .rotate:
            acceptsMomentum = false
            isRotating = !terminal
            if !event.phase.contains(.cancelled) {
                interaction.rotate(by: -Double(event.counterclockwiseDegrees))
            }
            return Result(consumed: true, settle: terminal && !isTransforming && !sequenceActive, reason: "rotate")
        case .scrollWheel:
            guard event.precise else { return Result(consumed: false, settle: false, reason: "non-trackpad scroll") }
            guard !isTransforming else { return Result(consumed: true, settle: false, reason: "pan suppressed during transform") }
            if event.phase.contains(.cancelled) || event.momentumPhase.contains(.cancelled) {
                acceptsMomentum = false
                return Result(consumed: true, settle: false, reason: "pan cancelled")
            }
            if event.momentumPhase.isEmpty {
                acceptsMomentum = true
            } else if !acceptsMomentum {
                return Result(consumed: true, settle: false, reason: "old momentum suppressed")
            }
            interaction.pan(by: event.scroll)
            if event.momentumPhase.contains(.ended) { acceptsMomentum = false }
            return Result(consumed: true, settle: false, reason: interaction.scale == 1 ? "pan at fit limit" : "pan")
        default:
            return Result(consumed: false, settle: false, reason: "unhandled event")
        }
    }
}
