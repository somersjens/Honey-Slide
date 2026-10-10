import Foundation
import CoreGraphics

/// One projection table per rendered frame, shared by water, banks and rails.
/// Physics and answer placement continue to use the exact rules. Interpolation
/// error stays below half a logical pixel, including distant tight bends.
struct HoneySlideProjection {
    private static let depthLimit = 1.3
    private static let axisCount = 640
    private static let nearStep = 8.0
    private static let splitAhead = 1536.0
    private static let farStep = 32.0
    private static let nearCount = Int(splitAhead / nearStep)
    private static let farCount = Int(ceil((HoneySlideRules.drawDistance - splitAhead) / farStep))
    // Width and elevation depend only on depth, so build them once per process.
    private static let axes: [CGPoint] = (0...axisCount).map { index in
        let depth = Double(index) / Double(axisCount) * depthLimit
        return CGPoint(x: 1550 * pow(depth, 1.55), y: HoneySlideRules.groundY(depth: depth))
    }
    let elapsed: Double
    private let origin: Double
    private let endCourse: Double
    private let nearCenters: [Double]
    private let farCenters: [Double]

    init(elapsed: Double) {
        self.elapsed = elapsed
        let world = HoneySlideRules.worldDistance(elapsed)
        let origin = HoneySlideRules.course(world)
        self.origin = origin
        endCourse = HoneySlideRules.course(world + HoneySlideRules.drawDistance)
        nearCenters = (0...Self.nearCount).map { index in
            let depth = HoneySlideRules.depth(ahead: Double(index) * Self.nearStep)
            return HoneySlideRules.trackPoint(depth: depth, offset: 0, distance: elapsed, originCourse: origin).x
        }
        farCenters = (0...Self.farCount).map { index in
            let depth = HoneySlideRules.depth(ahead: Self.splitAhead + Double(index) * Self.farStep)
            return HoneySlideRules.trackPoint(depth: depth, offset: 0, distance: elapsed, originCourse: origin).x
        }
    }

    func point(depth: Double, offset: Double) -> CGPoint {
        let t = max(0, min(HoneySlideRules.nearClipDepth, depth))
        guard t <= Self.depthLimit else {
            return HoneySlideRules.trackPoint(depth: t, offset: offset, distance: elapsed, originCourse: origin)
        }
        let axisIndex = t / Self.depthLimit * Double(Self.axisCount)
        let i = min(Self.axisCount - 1, Int(axisIndex))
        let fraction = axisIndex - Double(i)
        let a = Self.axes[i], b = Self.axes[i + 1]
        let width = a.x + (b.x - a.x) * fraction
        let y = a.y + (b.y - a.y) * fraction
        let center: Double
        if t >= 0.55 {
            center = 800
        } else {
            let ahead = HoneySlideRules.focalLength * (1 / max(0.001, t) - 1)
            if ahead >= HoneySlideRules.drawDistance {
                center = 800 + 300 * tanh((endCourse - origin) * t * 1.35 / 500)
            } else if ahead < Self.splitAhead {
                center = Self.interpolate(nearCenters, at: ahead / Self.nearStep)
            } else {
                center = Self.interpolate(farCenters, at: (ahead - Self.splitAhead) / Self.farStep)
            }
        }
        return CGPoint(x: center + offset * width, y: y)
    }

    private static func interpolate(_ values: [Double], at index: Double) -> Double {
        let i = min(values.count - 2, max(0, Int(index)))
        return values[i] + (values[i + 1] - values[i]) * (index - Double(i))
    }
}
