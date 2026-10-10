import Foundation
import CoreGraphics

/// Adapts the saved six-option math boards to a three-barrel checkpoint while
/// preserving option identities understood by the existing scoring engine.
enum HoneySlideRules {
    /// All moving objects use these world units, including answer rows.
    static let forwardSpeed = 220.0
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
    static let straightHalfLength = 350.0
    static let collectionDuration = 0.65
    static let tumbleDuration = 0.95
    static let penaltyDuration = 1.15
    // The same world span defines the visible walls and their physical funnel.
    static let dividerLead = 210.0
    static let dividerTail = 60.0
    static let dividerHalfWidth = 0.025
    static let dividerHeight = 58.0
    static let dividerSections = 9
    // Clip at the camera, after the complete pot and wall have left the view.
    // The former -80 cutoff froze ground projection with props still visible.
    static let nearClipDepth = 12.0
    static let nearClipAhead = focalLength * (1 / nearClipDepth - 1)
    static let laneSpacing = 0.66
    static let laneBoundary = laneSpacing / 2

    /// The course fills any viewport; upright props preserve their proportions.
    static func billboardVerticalScale(viewport: CGSize) -> Double {
        guard viewport.width > 0, viewport.height > 0 else { return 1 }
        return (viewport.width / 1600) / (viewport.height / 900)
    }

    static func worldDistance(_ elapsed: Double) -> Double { elapsed * forwardSpeed }

    /// Inverse perspective: every sample is part of one fixed world spline.
    /// Depth zero converges to the horizon, rather than terminating at a cap.
    static func trackPoint(depth: Double, offset: Double, distance: Double, originCourse: Double? = nil) -> CGPoint {
        let t = max(0, min(nearClipDepth, depth))
        let world = worldDistance(distance)
        let ahead = min(drawDistance, focalLength * (1 / max(0.001, t) - 1))
        // The camera translates along the course. A local tangent must not
        // whip the distant scenery sideways when a straight meets a bend.
        // The camera faces straight along the final approach. Curvature stays
        // in the distance; a checkpoint never slides sideways just before hit.
        let settle = max(0, min(1, (0.55 - t) / 0.23))
        let nearBlend = settle * settle * (3 - 2 * settle)
        // The complete landing is straight. Do not evaluate a spline (and
        // its sine anchors) only to multiply its result by zero.
        let center: Double
        if nearBlend == 0 {
            center = 800
        } else {
            let projectedBend = (course(world + ahead) - (originCourse ?? course(world))) * t * 1.35
            center = 800 + 300 * tanh(projectedBend / 500) * nearBlend
        }
        return CGPoint(x: center + offset * (1550 * pow(t, 1.55)),
                       y: groundY(depth: t))
    }

    /// Every checkpoint occupies a fixed straight landing. C2-continuous
    /// bends connect the landings; all rails, trees and walls use this spline.
    static func course(_ z: Double) -> Double {
        let cell = floor((z - firstCheckpointPosition) / checkpointSpacing)
        let left = firstCheckpointPosition + cell * checkpointSpacing
        let blendLength = checkpointSpacing - 2 * straightHalfLength
        let t = max(0, min(1, (z - left - straightHalfLength) / blendLength))
        let eased = t * t * t * (10 + t * (-15 + 6 * t))
        func anchor(_ position: Double) -> Double {
            2400 * sin(position / 1600) + 1300 * sin(position / 3300 + 1.2)
        }
        return anchor(left) + (anchor(left + checkpointSpacing) - anchor(left)) * eased
    }

    static func courseSlope(_ z: Double) -> Double {
        let cell = floor((z - firstCheckpointPosition) / checkpointSpacing)
        let left = firstCheckpointPosition + cell * checkpointSpacing
        let length = checkpointSpacing - 2 * straightHalfLength
        let t = max(0, min(1, (z - left - straightHalfLength) / length))
        let delta = 2400 * (sin((left + checkpointSpacing) / 1600) - sin(left / 1600))
            + 1300 * (sin((left + checkpointSpacing) / 3300 + 1.2) - sin(left / 3300 + 1.2))
        return delta * 30 * t * t * (t - 1) * (t - 1) / length
    }

    /// The near ground opens below the camera's downward view. This has the
    /// same value and velocity at contact, then carries a passed pot down out
    /// of frame instead of leaving its growing crown behind the bear's head.
    static func groundY(depth: Double) -> Double {
        let t = max(0, depth), belowRider = max(0, t - playerDepth)
        return 155 + 780 * pow(t, 1.2) + 800 * belowRider * belowRider
    }

    static func groundDepth(screenY: Double) -> Double {
        let y = max(155.001, screenY)
        var t = min(1.3, pow((y - 155) / 780, 1 / 1.2))
        for _ in 0..<6 {
            let derivative = 936 * pow(max(0.001, t), 0.2) + 1600 * max(0, t - playerDepth)
            t = max(0.001, min(1.3, t - (groundY(depth: t) - y) / derivative))
        }
        return t
    }

    static func depth(ahead: Double) -> Double {
        focalLength / (focalLength + max(nearClipAhead, ahead))
    }

    static func ridingPoint(depth: Double, lateral: Double, distance: Double) -> CGPoint {
        let center = trackPoint(depth: depth, offset: 0, distance: distance)
        let roadWidth = 1550 * pow(max(0, depth), 1.55)
        let ridingWidth = min(740 * depth / playerDepth, roadWidth * 0.78)
        return CGPoint(x: center.x + lateral * ridingWidth, y: center.y)
    }

    /// Invert the same projection used to place barrels. A tap on a far lane
    /// selects that lane, rather than a screen-x position close to the centre.
    static func steeringTarget(at point: CGPoint, elapsed: Double) -> Double? {
        guard point.y >= 155 else { return nil }
        let depth = groundDepth(screenY: point.y)
        let center = trackPoint(depth: depth, offset: 0, distance: elapsed)
        let edge = trackPoint(depth: depth, offset: 1, distance: elapsed)
        guard abs(point.x - center.x) <= edge.x - center.x else { return nil }
        let width = ridingPoint(depth: depth, lateral: 1, distance: elapsed).x - center.x
        return max(-0.78, min(0.78, (point.x - center.x) / max(1, width)))
    }

    /// Stronger perspective keeps distant rows small, while the contact row
    /// occupies the three broad lanes without overlapping its neighbours.
    static func answerScale(depth: Double) -> Double {
        let relative = max(0, depth) / playerDepth
        // Preserve small distant targets, then continue with a matching slope
        // through contact. Near pots no longer outgrow their lane separation.
        return 1.88 * (relative <= 1 ? pow(relative, 1.4)
                       : relative + 0.4 * (1 - exp(-(relative - 1))))
    }

    static func potBounds(depth: Double, lateral: Double, elapsed: Double,
                          billboardYScale: Double) -> CGRect {
        let p = ridingPoint(depth: depth, lateral: lateral, distance: elapsed)
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
