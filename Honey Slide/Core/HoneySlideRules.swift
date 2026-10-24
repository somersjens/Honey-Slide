import Foundation
import CoreGraphics

/// Adapts the saved six-option math boards to race checkpoints while
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
    static let jumpLift = 0.56
    static let rampLead = 430.0
    /// The launch plank runs along a divider and meets the answer stones.
    /// The flight leaves the lip and peaks 20 units before the row, so one
    /// sine from lip to landing is a single smooth arc.
    static let launchDeckLead = 520.0
    static let launchLipLead = 220.0
    static let jumpLandingTail = 180.0
    static let finishWidth = 0.34
    static let finishFunnelStart = 80.0
    static let finishFunnelLength = 500.0
    static let finishRampLead = 560.0
    static let finishFlightDuration = 0.6875

    static func cameraZoom(widthScale: Double) -> Double {
        max(0.68, min(1, 1 - max(0, widthScale - 1) * 0.5))
    }
    // Leave room for a late lane change before entering the answer passages.
    static let dividerLead = 180.0
    static let dividerTail = 120.0
    static let dividerHalfWidth = 0.016
    static let dividerHeight = 58.0
    static let dividerSections = 10
    // Clip at the camera, after the complete pot and wall have left the view.
    // The former -80 cutoff froze ground projection with props still visible.
    static let nearClipDepth = 12.0
    static let nearClipAhead = focalLength * (1 / nearClipDepth - 1)
    static let laneSpacing = 0.66
    static let laneBoundary = laneSpacing / 2
    /// Center distance at which neighboring pot bellies meet and do not overlap.
    static var answerTouchSpacing: Double {
        let depth = playerDepth
        let paintedWidth = 162 * answerScale(depth: depth)
        return paintedWidth / ridingHalfWidth(depth: depth)
    }
    static let railClearance = 12.0

    // The reference road width. Race widths are sampled at fixed world
    // positions, so a widening section travels with the course geometry.
    static let trackWorldHalfWidth = 800.0
    static let projectionScale = 1.2
    /// Lift the distant course under the question sign while preserving the
    /// rider's waterline and the exact projection used by touch and collisions.
    static let horizonY = 108.0
    static let groundScale = 780 * pow(playerDepth, 0.2) + (155 - horizonY) / playerDepth
    static func trackHalfWidth(depth: Double, widthScale: Double = 1) -> Double {
        trackWorldHalfWidth * max(0, depth) * projectionScale * widthScale
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
                           originCourse: Double? = nil, originSlope: Double? = nil,
                           widthProfile: HoneyTrackWidth = .standard, cameraZoom: Double = 1, cameraOffset: Double = 0) -> CGPoint {
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
        return CGPoint(x: 800 - cameraOffset + (center - 800) * cameraZoom
            + offset * trackHalfWidth(depth: t, widthScale: widthProfile.scale(at: world + ahead)) * cameraZoom,
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
                            course: HoneySlideCourse = .preview, cameraZoom: Double = 1, cameraOffset: Double = 0) -> CGPoint {
        let center = trackPoint(depth: depth, offset: 0, distance: distance, course: course, cameraZoom: cameraZoom, cameraOffset: cameraOffset)
        let ridingWidth = ridingHalfWidth(depth: max(0, depth)) * cameraZoom
        return CGPoint(x: center.x + lateral * ridingWidth, y: center.y)
    }

    /// Invert the same projection used to place barrels. A tap on a far lane
    /// selects that lane, rather than a screen-x position close to the centre.
    static func steeringTarget(at point: CGPoint, elapsed: Double, course: HoneySlideCourse = .preview,
                               widthProfile: HoneyTrackWidth = .standard, cameraZoom: Double = 1, cameraOffset: Double = 0) -> Double? {
        guard point.y >= horizonY else { return nil }
        let depth = groundDepth(screenY: point.y)
        let center = trackPoint(depth: depth, offset: 0, distance: elapsed, course: course, cameraZoom: cameraZoom, cameraOffset: cameraOffset)
        let edge = trackPoint(depth: depth, offset: 1, distance: elapsed, course: course, widthProfile: widthProfile, cameraZoom: cameraZoom, cameraOffset: cameraOffset)
        let half = edge.x - center.x
        // A folded bank reports a negative width and would flip steering.
        guard half > 12, abs(point.x - center.x) <= half else { return nil }
        let width = ridingPoint(depth: depth, lateral: 1, distance: elapsed, course: course, cameraZoom: cameraZoom, cameraOffset: cameraOffset).x - center.x
        return (point.x - center.x) / max(1, width)
    }

    /// Linear perspective preserves readable distant answers at the larger
    /// checkpoint spacing, with continuous size and velocity through contact.
    static func answerScale(depth: Double) -> Double {
        1.88 * max(0, depth) / playerDepth
    }

    static func potBounds(depth: Double, lateral: Double, elapsed: Double,
                          billboardYScale: Double, course: HoneySlideCourse = .preview, sizeFactor: Double = 1, cameraZoom: Double = 1, cameraOffset: Double = 0) -> CGRect {
        let p = ridingPoint(depth: depth, lateral: lateral, distance: elapsed, course: course, cameraZoom: cameraZoom, cameraOffset: cameraOffset)
        let s = CGFloat(answerScale(depth: depth) * sizeFactor * cameraZoom)
        let vertical = s * CGFloat(billboardYScale)
        let origin = CGPoint(x: p.x - 79 * s, y: p.y - 144 * vertical)
        return CGRect(origin: origin, size: CGSize(width: 158 * s, height: 166 * vertical))
    }

    /// Fixed endpoints of each wall block; promotion and proximity never
    /// retessellate the wall or move its joints to a different world position.
    static func dividerSegment(rowPosition: Double, index: Int, tail: Double = dividerTail) -> (far: Double, near: Double) {
        let step = (dividerLead + tail) / Double(dividerSections)
        let far = rowPosition + tail - Double(index) * step
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
