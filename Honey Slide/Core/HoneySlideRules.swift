import Foundation
import CoreGraphics

/// Adapts the saved six-option math boards to a three-barrel checkpoint while
/// preserving option identities understood by the existing scoring engine.
enum HoneySlideRules {
    /// All moving objects use these world units, including answer rows.
    static let forwardSpeed = 440.0
    static let focalLength = 360.0
    static let playerDepth = 0.84
    static let playerAhead = focalLength * (1 / playerDepth - 1)
    static let drawDistance = 10_000.0
    static let railHeight = 84.0
    static let scenerySpacing = 145.0
    static let shutterDuration = 0.42
    static let checkpointInterval = 6.6
    static let checkpointSpacing = forwardSpeed * checkpointInterval
    static let firstCheckpointPosition = playerAhead + checkpointSpacing
    static let straightHalfLength = 700.0
    static let collectionDuration = 0.65
    static let tumbleDuration = 0.95
    // Double the world spans with speed, preserving the time spent in a channel.
    static let dividerLead = 420.0
    static let dividerTail = 120.0
    static let dividerHalfWidth = 0.025
    static let dividerHeight = 58.0
    static let dividerSections = 18
    // Clip at the camera, after the complete pot and wall have left the view.
    // The former -80 cutoff froze ground projection with props still visible.
    static let nearClipDepth = 12.0
    static let nearClipAhead = focalLength * (1 / nearClipDepth - 1)
    static let laneSpacing = 0.66
    static let laneBoundary = laneSpacing / 2
    static let railClearance = 12.0

    // One fixed-width road, enlarged only by perspective. Changing width with
    // viewing distance made the verges bulge and pinch as corners approached.
    static let trackWorldHalfWidth = 800.0
    static let projectionScale = 1.2
    /// Lift the distant course under the question sign while preserving the
    /// rider's waterline and the exact projection used by touch and collisions.
    static let horizonY = 108.0
    static let groundScale = 780 * pow(playerDepth, 0.2) + (155 - horizonY) / playerDepth
    static func trackHalfWidth(depth: Double) -> Double {
        trackWorldHalfWidth * max(0, depth) * projectionScale
    }

    static func ridingHalfWidth(depth: Double) -> Double {
        min(740 * depth / playerDepth, trackHalfWidth(depth: depth) * 0.92)
    }

    /// Convert rider lane displacement back to the world spline's x units.
    static let lateralWorldScale = ridingHalfWidth(depth: playerDepth) / (playerDepth * projectionScale)

    /// The course fills any viewport; upright props preserve their proportions.
    static func billboardVerticalScale(viewport: CGSize) -> Double {
        guard viewport.width > 0, viewport.height > 0 else { return 1 }
        return (viewport.width / 1600) / (viewport.height / 900)
    }

    static func worldDistance(_ elapsed: Double) -> Double { elapsed * forwardSpeed }

    /// Inverse perspective: every sample is part of one fixed world spline.
    /// Depth zero converges to the horizon, rather than terminating at a cap.
    static func trackPoint(depth: Double, offset: Double, distance: Double,
                           course: HoneySlideCourse = .preview,
                           originCourse: Double? = nil, originSlope: Double? = nil) -> CGPoint {
        let t = max(0, min(nearClipDepth, depth))
        let world = worldDistance(distance)
        let ahead = focalLength * (1 / max(0.001, t) - 1)
        // Follow the course tangent instead of flattening the entire foreground.
        // A checkpoint on its straight approach still projects directly ahead.
        let origin = course.sample(at: world)
        let cameraX = originCourse ?? origin.x, cameraSlope = originSlope ?? origin.slope
        let center: Double
        // Project the fixed geometry directly. Compressing each point with
        // tanh flattened distant bends and moved their edges at different rates.
        if ahead >= drawDistance {
            let end = course.sample(at: world + drawDistance)
            // Continue the far tangent to its vanishing point. Capping world
            // distance and then forcing x=800 made a moving triangle at infinity.
            center = 800 + projectionScale * ((end.x - cameraX - end.slope * drawDistance) * t
                + (end.slope - cameraSlope) * focalLength * (1 - t))
        } else {
            let relative = course.sample(at: world + ahead).x - cameraX - cameraSlope * ahead
            center = 800 + relative * t * projectionScale
        }
        return CGPoint(x: center + offset * trackHalfWidth(depth: t),
                       y: groundY(depth: t))
    }

    /// The near ground opens below the camera's downward view. This has the
    /// same value and velocity at contact, then carries a passed pot down out
    /// of frame instead of leaving its growing crown behind the bear's head.
    static func groundY(depth: Double) -> Double {
        let t = max(0, depth), belowRider = max(0, t - playerDepth)
        // A flat straight has straight projected verges. Only the ground below
        // the rider opens out to carry passed objects out of the viewport.
        return horizonY + groundScale * t + 800 * belowRider * belowRider
    }

    static func groundDepth(screenY: Double, height: Double = 0) -> Double {
        let y = max(horizonY + 0.001, screenY)
        var t = min(1.3, (y - horizonY) / (groundScale - height))
        for _ in 0..<6 {
            let derivative = groundScale - height + 1600 * max(0, t - playerDepth)
            t = max(0.001, min(1.3, t - (groundY(depth: t) - height * t - y) / derivative))
        }
        return t
    }

    static func depth(ahead: Double) -> Double {
        focalLength / (focalLength + max(nearClipAhead, ahead))
    }

    static func ridingPoint(depth: Double, lateral: Double, distance: Double,
                            course: HoneySlideCourse = .preview) -> CGPoint {
        let center = trackPoint(depth: depth, offset: 0, distance: distance, course: course)
        let ridingWidth = ridingHalfWidth(depth: max(0, depth))
        return CGPoint(x: center.x + lateral * ridingWidth, y: center.y)
    }

    /// Invert the same projection used to place barrels. A tap on a far lane
    /// selects that lane, rather than a screen-x position close to the centre.
    static func steeringTarget(at point: CGPoint, elapsed: Double, course: HoneySlideCourse = .preview) -> Double? {
        guard point.y >= horizonY else { return nil }
        let depth = groundDepth(screenY: point.y)
        let center = trackPoint(depth: depth, offset: 0, distance: elapsed, course: course)
        let edge = trackPoint(depth: depth, offset: 1, distance: elapsed, course: course)
        guard abs(point.x - center.x) <= edge.x - center.x else { return nil }
        let width = ridingPoint(depth: depth, lateral: 1, distance: elapsed, course: course).x - center.x
        return (point.x - center.x) / max(1, width)
    }

    /// Linear perspective preserves readable distant answers at the larger
    /// checkpoint spacing, with continuous size and velocity through contact.
    static func answerScale(depth: Double) -> Double {
        1.88 * max(0, depth) / playerDepth
    }

    static func potBounds(depth: Double, lateral: Double, elapsed: Double,
                          billboardYScale: Double, course: HoneySlideCourse = .preview) -> CGRect {
        let p = ridingPoint(depth: depth, lateral: lateral, distance: elapsed, course: course)
        let s = CGFloat(answerScale(depth: depth))
        let vertical = s * CGFloat(billboardYScale)
        let origin = CGPoint(x: p.x - 79 * s, y: p.y - 144 * vertical)
        return CGRect(origin: origin, size: CGSize(width: 158 * s, height: 166 * vertical))
    }

    /// Fixed endpoints of each wall block; promotion and proximity never
    /// retessellate the wall or move its joints to a different world position.
    static func dividerSegment(rowPosition: Double, index: Int) -> (far: Double, near: Double) {
        let step = (dividerLead + dividerTail) / Double(dividerSections)
        let far = rowPosition + dividerTail - Double(index) * step
        return (far, far - step)
    }

    /// Scenery enters at the same horizon as the track, never in mid-air.
    static func distantOpacity(ahead: Double) -> Double {
        max(0, min(1, (drawDistance - ahead) / 1600))
    }

    /// Sample in world distance so distant bends retain their curvature after
    /// perspective compression. Near-camera spacing stays fine for rail faces.
    static let trackDepthSamples: [Double] = {
        var ahead = focalLength * (1 / 1.3 - 1)
        var samples: [Double] = []
        while ahead < drawDistance {
            samples.append(depth(ahead: ahead))
            ahead += max(12, max(0, ahead) * 0.04)
        }
        samples.append(depth(ahead: drawDistance))
        samples.append(0)
        return samples.reversed()
    }()

    static func options(for round: GameRound) -> [AnswerOption] {
        guard let answer = round.correctOption else { return [] }
        return ([answer] + Array(round.options.filter { !$0.isCorrect }.shuffled().prefix(2))).shuffled()
    }
    static func collisionIndex(lateral: Double) -> Int {
        lateral < -laneBoundary ? 0 : lateral > laneBoundary ? 2 : 1
    }
    static func approachDuration(stage: Int) -> Double {
        checkpointInterval
    }
}
