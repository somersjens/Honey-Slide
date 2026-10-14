import Foundation
import CoreGraphics

/// One uninterrupted flight in screen coordinates, with zero velocity at both
/// ends. The pot moves sideways and shrinks before rising past the question
/// sign, then drops into the score icon's exact centre.
struct HoneyCollectionMotion {
    let center: CGPoint
    let scale: Double
    let rotation: Double

    init(progress: Double, origin: CGPoint, target: CGPoint,
         initialScale: Double, finalScale: Double) {
        let t = max(0, min(1, progress))
        let u = t * t * (3 - 2 * t), v = 1 - u
        let dx = target.x - origin.x, dy = target.y - origin.y
        // First travel out beside the question sign. The high final control
        // point produces one natural apex, followed by a short downward landing.
        let liftY = origin.y + dy * 0.10
        let approach = CGPoint(x: target.x, y: target.y - 332 * finalScale * 2.2)
        center = CGPoint(x: origin.x + dx * (1 - v * v * v * v),
                         y: v * v * v * origin.y + 3 * v * v * u * liftY
                         + 3 * v * u * u * approach.y + u * u * u * target.y)
        scale = finalScale + (initialScale - finalScale) * v * v
        rotation = -10 * sin(u * .pi)
    }
}
