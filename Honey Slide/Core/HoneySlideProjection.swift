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
    private static let nearStart = -88.0
    private static let nearCount = Int((splitAhead - nearStart) / nearStep)
    private static let farCount = Int(ceil((HoneySlideRules.drawDistance - splitAhead) / farStep))
    // Width and elevation depend only on depth, so build them once per process.
    private static let axes: [CGPoint] = (0...axisCount).map { index in
        let depth = Double(index) / Double(axisCount) * depthLimit
        return CGPoint(x: HoneySlideRules.trackHalfWidth(depth: depth), y: HoneySlideRules.groundY(depth: depth))
    }
    let elapsed: Double
    private let course: HoneySlideCourse
    private let widthProfile: HoneyTrackWidth
    private let cameraZoom: Double
    private let cameraOffset: Double
    private let origin: Double
    private let slope: Double
    private let endCourse: Double
    private let endSlope: Double
    private let nearCenters: [Double]
    private let farCenters: [Double]

    init(elapsed: Double, course: HoneySlideCourse = .preview, widthProfile: HoneyTrackWidth = .standard, cameraZoom: Double = 1, cameraOffset: Double = 0) {
        self.elapsed = elapsed
        self.course = course
        self.widthProfile = widthProfile
        self.cameraZoom = cameraZoom
        self.cameraOffset = cameraOffset
        let world = HoneySlideRules.worldDistance(elapsed)
        let start = course.sample(at: world)
        self.origin = start.x
        self.slope = start.slope
        let end = course.sample(at: world + HoneySlideRules.drawDistance)
        endCourse = end.x
        endSlope = end.slope
        nearCenters = (0...Self.nearCount).map { index in
            let depth = HoneySlideRules.depth(ahead: Self.nearStart + Double(index) * Self.nearStep)
            return HoneySlideRules.trackPoint(depth: depth, offset: 0, distance: elapsed,
                course: course, originCourse: start.x, originSlope: start.slope).x
        }
        farCenters = (0...Self.farCount).map { index in
            let depth = HoneySlideRules.depth(ahead: Self.splitAhead + Double(index) * Self.farStep)
            return HoneySlideRules.trackPoint(depth: depth, offset: 0, distance: elapsed,
                course: course, originCourse: start.x, originSlope: start.slope).x
        }
    }

    func point(depth: Double, offset: Double) -> CGPoint {
        let t = max(0, min(HoneySlideRules.nearClipDepth, depth))
        guard t <= Self.depthLimit else {
            return HoneySlideRules.trackPoint(depth: t, offset: offset, distance: elapsed,
                course: course, originCourse: origin, originSlope: slope, widthProfile: widthProfile, cameraZoom: cameraZoom, cameraOffset: cameraOffset)
        }
        let axisIndex = t / Self.depthLimit * Double(Self.axisCount)
        let i = min(Self.axisCount - 1, Int(axisIndex))
        let fraction = axisIndex - Double(i)
        let a = Self.axes[i], b = Self.axes[i + 1]
        let ahead = HoneySlideRules.focalLength * (1 / max(0.001, t) - 1)
        let width = (a.x + (b.x - a.x) * fraction)
            * widthProfile.scale(at: HoneySlideRules.worldDistance(elapsed) + ahead)
        let y = a.y + (b.y - a.y) * fraction
        let center: Double
        if ahead >= HoneySlideRules.drawDistance {
            center = 800 + HoneySlideRules.projectionScale
                * ((endCourse - origin - endSlope * HoneySlideRules.drawDistance) * t
                   + (endSlope - slope) * HoneySlideRules.focalLength * (1 - t))
        } else if ahead < Self.splitAhead {
            center = Self.interpolate(nearCenters, at: (ahead - Self.nearStart) / Self.nearStep)
        } else {
            center = Self.interpolate(farCenters, at: (ahead - Self.splitAhead) / Self.farStep)
        }
        return CGPoint(x: 800 - cameraOffset + (center - 800 + offset * width) * cameraZoom, y: y)
    }

    private static func interpolate(_ values: [Double], at index: Double) -> Double {
        let i = min(values.count - 2, max(0, Int(index)))
        return values[i] + (values[i + 1] - values[i]) * (index - Double(i))
    }
}
