import AppKit
import Combine

@MainActor
final class NanightVideoInteraction: ObservableObject {
    static let surfaceSize = CGSize(width: 520, height: 292)
    static let settlingDuration: TimeInterval = 0.28

    @Published private(set) var scale: CGFloat = 1
    @Published private(set) var offset: CGSize = .zero
    // Keep an unwrapped angle so 359 degrees settles to 360, not a full turn to 0.
    @Published private(set) var rotationDegrees: Double = 0
    @Published private(set) var isPortrait = false

    var viewportSize: CGSize {
        isPortrait
            ? CGSize(width: Self.surfaceSize.height, height: Self.surfaceSize.width)
            : Self.surfaceSize
    }

    var displayScale: CGFloat {
        let bounds = rotatedBounds
        return scale * min(viewportSize.width / bounds.width, viewportSize.height / bounds.height)
    }

    var diagnosticDescription: String {
        String(format: "zoom=%.4f displayScale=%.4f angle=%.3f offset=(%.2f,%.2f) viewport=(%.0f,%.0f)",
               Double(scale), Double(displayScale), rotationDegrees, Double(offset.width), Double(offset.height),
               Double(viewportSize.width), Double(viewportSize.height))
    }

    private var rotatedBounds: CGSize {
        let radians = rotationDegrees * .pi / 180
        let cosine = abs(cos(radians))
        let sine = abs(sin(radians))
        return CGSize(
            width: Self.surfaceSize.width * cosine + Self.surfaceSize.height * sine,
            height: Self.surfaceSize.width * sine + Self.surfaceSize.height * cosine
        )
    }

    func magnify(by magnification: CGFloat, around anchor: CGPoint = .zero) {
        guard magnification.isFinite, anchor.x.isFinite, anchor.y.isFinite else { return }
        let nextScale = min(max(scale * max(0, 1 + magnification), 1), 4)
        let ratio = nextScale / scale
        scale = nextScale
        // Anchor coordinates are relative to the viewport center, with Y down.
        offset = clampedOffset(CGSize(
            width: anchor.x + (offset.width - anchor.x) * ratio,
            height: anchor.y + (offset.height - anchor.y) * ratio
        ))
    }

    func pan(by delta: CGSize) {
        guard delta.width.isFinite, delta.height.isFinite else { return }
        offset = clampedOffset(CGSize(width: offset.width + delta.width, height: offset.height + delta.height))
    }

    func rotate(by degrees: Double) {
        guard degrees.isFinite, (rotationDegrees + degrees).isFinite else { return }
        let previousScale = displayScale
        rotationDegrees += degrees
        rotateOffset(by: degrees, scaleRatio: displayScale / previousScale)
    }

    func snapRotation() {
        let target = (rotationDegrees / 90).rounded() * 90
        let delta = target - rotationDegrees
        let previousScale = displayScale
        rotationDegrees = target
        isPortrait = abs(target.truncatingRemainder(dividingBy: 180)) == 90
        rotateOffset(by: delta, scaleRatio: displayScale / previousScale)
    }

    private func rotateOffset(by degrees: Double, scaleRatio: CGFloat) {
        let radians = degrees * .pi / 180
        let x = offset.width * cos(radians) - offset.height * sin(radians)
        let y = offset.width * sin(radians) + offset.height * cos(radians)
        offset = clampedOffset(CGSize(width: x * scaleRatio, height: y * scaleRatio))
    }

    private func clampedOffset(_ candidate: CGSize) -> CGSize {
        guard scale > 1 else { return .zero }
        let bounds = rotatedBounds
        let maxX = max(0, (bounds.width * displayScale - viewportSize.width) / 2)
        let maxY = max(0, (bounds.height * displayScale - viewportSize.height) / 2)
        return CGSize(
            width: min(max(candidate.width, -maxX), maxX),
            height: min(max(candidate.height, -maxY), maxY)
        )
    }
}
