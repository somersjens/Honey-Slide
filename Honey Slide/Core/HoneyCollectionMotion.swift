import Foundation
import CoreGraphics

/// One uninterrupted flight in screen coordinates. The same eased parameter
/// drives position and size, with zero velocity at both ends. The last arc
/// rises above the score icon and drops into its exact centre.
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
        let lift = CGPoint(x: origin.x + dx * 0.92, y: origin.y + dy * 0.10)
        let approach = CGPoint(x: target.x, y: target.y - 332 * finalScale * 2.2)
        center = CGPoint(x: v * v * v * origin.x + 3 * v * v * u * lift.x
                         + 3 * v * u * u * approach.x + u * u * u * target.x,
                         y: v * v * v * origin.y + 3 * v * v * u * lift.y
                         + 3 * v * u * u * approach.y + u * u * u * target.y)
        scale = initialScale + (finalScale - initialScale) * u
        rotation = -10 * sin(u * .pi)
    }
}
