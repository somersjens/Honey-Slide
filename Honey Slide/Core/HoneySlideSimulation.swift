import Foundation
import CoreGraphics

/// Contact owns one visual outcome, independently of the next question.
struct HoneyPotImpact: Identifiable {
    let id: Int
    let startedAt: Double
    let worldPosition: Double
    let lane: Int
    let text: String
    let correct: Bool
    let origin: CGPoint
    let scale: Double

    func age(at elapsed: Double) -> Double { max(0, elapsed - startedAt) }
    func progress(at elapsed: Double) -> Double {
        min(1, age(at: elapsed) / (correct ? HoneySlideRules.collectionDuration : HoneySlideRules.tumbleDuration))
    }
}

/// A row stays at its course position before, during and after selection.
/// The scoring engine owns the question; this simulation owns its placement.
struct HoneyCheckpoint: Identifiable {
    let id: Int
    let worldPosition: Double
    var roundID: UUID?
    var options: [AnswerOption] = []
    var selectedIndex: Int?
    var guidedLane: Int?
    var wasCorrect = false
    var revealedAt: Double?
    var impactAt: Double?

    func shutterProgress(at elapsed: Double) -> Double {
        guard let revealedAt else { return 0 }
        let t = max(0, min(1, (elapsed - revealedAt) / HoneySlideRules.shutterDuration))
        return t * t * (3 - 2 * t)
    }
}

struct HoneySlideSimulation {
    private(set) var course: HoneySlideCourse
    private(set) var elapsed = 0.0
    var distance: Double { HoneySlideRules.worldDistance(elapsed) }
    private(set) var lateral = 0.0
    private(set) var lateralVelocity = 0.0
    private(set) var steeringVelocity = 0.0
    private(set) var travelSlope = 0.0
    private(set) var railContact = 0.0
    private(set) var tubeHeading = 0.0
    private var viewport = CGSize(width: 1600, height: 900)
    private var reduceMotion = false
    private var tubeHalfWidth: Double {
        HoneyTubeGeometry.spriteWidth(in: viewport) / viewport.width * 1600 * 0.46
    }
    var tubeFootprint: HoneyTubeFootprint {
        HoneyTubeGeometry.footprint(in: viewport, elapsed: elapsed,
            heading: tubeHeading, reduceMotion: reduceMotion)
    }
    var railLimit: Double {
        (HoneySlideRules.trackHalfWidth(depth: HoneySlideRules.playerDepth)
            - tubeHalfWidth - HoneySlideRules.railClearance)
            / HoneySlideRules.ridingHalfWidth(depth: HoneySlideRules.playerDepth)
    }
    var riderWorldX: Double {
        course.sample(at: distance + HoneySlideRules.playerAhead).x
            + lateral * HoneySlideRules.lateralWorldScale
    }
    private(set) var checkpoints: [HoneyCheckpoint] = []
    private(set) var feedbackRemaining = 0.0
    private(set) var lastWasCorrect = false
    private(set) var impacts: [HoneyPotImpact] = []
    private(set) var lastContact: HoneyPotImpact?
    var visualOutcomeSettled: Bool {
        guard let contact = lastContact else { return false }
        let duration = contact.correct ? HoneySlideRules.collectionDuration : HoneySlideRules.tumbleDuration
        return contact.age(at: elapsed) >= duration + 0.2
    }
    var pendingHoney: Int {
        impacts.filter { $0.correct && $0.age(at: elapsed) < HoneySlideRules.collectionDuration }.count
    }
    var hasVisibleImpact: Bool {
        impacts.contains {
            $0.age(at: elapsed) < ($0.correct ? HoneySlideRules.collectionDuration : HoneySlideRules.tumbleDuration)
        }
    }
    private var steeringTarget = 0.0
    private var hasSteeringTarget = false
    var targetLateral: Double {
        get { steeringTarget }
        set {
            steeringTarget = max(-railLimit, min(railLimit, newValue))
            hasSteeringTarget = true
        }
    }
    var heldDirection = 0.0
    private var holdElapsed = 0.0
    private var touchSteering = false
    private var nextCheckpointID = 0
    private var optionCache: [UUID: [AnswerOption]] = [:]

    init(courseSeed: UInt64 = UInt64.random(in: .min ... .max)) {
        course = HoneySlideCourse(seed: courseSeed)
    }

    var activeCheckpoint: HoneyCheckpoint? {
        checkpoints.first { $0.selectedIndex == nil }
    }

    mutating func synchronize(rounds: [GameRound], stage: Int, acceptingInput: Bool) {
        guard !rounds.isEmpty, acceptingInput || checkpoints.isEmpty else { return }
        let spacing = HoneySlideRules.forwardSpeed * HoneySlideRules.approachDuration(stage: stage)
        var upcoming = checkpoints.indices.filter { checkpoints[$0].selectedIndex == nil }
        while upcoming.count < rounds.count {
            let position = (checkpoints.last?.worldPosition
                            ?? distance + HoneySlideRules.playerAhead) + spacing
            checkpoints.append(HoneyCheckpoint(id: nextCheckpointID, worldPosition: position))
            nextCheckpointID += 1
            upcoming.append(checkpoints.count - 1)
        }
        for (i, round) in rounds.enumerated() {
            if optionCache[round.id] == nil {
                optionCache[round.id] = HoneySlideRules.options(for: round)
            }
            checkpoints[upcoming[i]].roundID = round.id
            checkpoints[upcoming[i]].options = optionCache[round.id]!
        }
        if acceptingInput, let first = upcoming.first, checkpoints[first].revealedAt == nil {
            checkpoints[first].revealedAt = elapsed
        }
        let retained = Set(checkpoints.compactMap(\.roundID))
        optionCache = optionCache.filter { retained.contains($0.key) }
    }

    mutating func press(_ direction: Double) {
        touchSteering = false
        heldDirection = direction
        holdElapsed = 0
        // A tap changes one lane; a sustained press also allows free steering.
        let lane = round(lateral / HoneySlideRules.laneSpacing)
        targetLateral = (lane + direction) * HoneySlideRules.laneSpacing
    }

    mutating func steer(to target: Double) {
        touchSteering = true
        targetLateral = target
    }

    mutating func configureViewport(_ size: CGSize, reduceMotion: Bool = false) {
        guard size.width > 0, size.height > 0 else { return }
        viewport = size
        self.reduceMotion = reduceMotion
        lateral = max(-railLimit, min(railLimit, lateral))
        steeringTarget = max(-railLimit, min(railLimit, steeringTarget))
        constrainToDividers()
    }

    mutating func release() { heldDirection = 0; holdElapsed = 0; touchSteering = false }

    mutating func advance(seconds: Double) {
        guard seconds > 0, seconds.isFinite else { return }
        course.extend(through: distance + seconds * HoneySlideRules.forwardSpeed + HoneySlideRules.drawDistance)
        // Integrate straight travel, input and wall contact on the same distance
        // clock. Long frames must not skip the turn or its channel entrance.
        var remaining = seconds
        while remaining > 0.00001 {
            let dt = min(1.0 / 120, remaining)
            let oldPosition = distance + HoneySlideRules.playerAhead
            let oldCourse = course.sample(at: oldPosition)
            let oldLateral = lateral
            elapsed += dt
            holdElapsed += dt
            let position = distance + HoneySlideRules.playerAhead
            let currentCourse = course.sample(at: position)
            if heldDirection != 0 && holdElapsed > 0.24 {
                targetLateral = steeringTarget + heldDirection * dt * 1.25
            }
            let limits = dividerLimits()
            if hasSteeringTarget {
                // Deliberate lane selection follows the road while the player
                // steers. A released tap finishes that one requested lane change.
                travelSlope = currentCourse.slope
                // Keep the player's request, but remove its component through
                // a solid wall. It resumes when the tube fully clears the end.
                let reachableTarget = max(limits.lower, min(limits.upper, steeringTarget))
                let acceleration = (reachableTarget - lateral) * 95 - steeringVelocity * 18
                steeringVelocity += acceleration * dt
                lateral += steeringVelocity * dt
                if !touchSteering && heldDirection == 0,
                   abs(steeringTarget - lateral) < 0.003, abs(steeringVelocity) < 0.02 {
                    hasSteeringTarget = false
                    steeringVelocity = 0
                }
            } else {
                // Keep the rider's world heading. The bending course moves
                // underneath that straight trajectory, towards the outside rail.
                // A rail can push us along its tangent, but cannot pull us back
                // when the next corner turns away from that trajectory.
                lateral += (travelSlope * (position - oldPosition)
                    - (currentCourse.x - oldCourse.x)) / HoneySlideRules.lateralWorldScale
                steeringVelocity = 0
            }
            let unconstrained = lateral
            lateral = max(-railLimit, min(railLimit, lateral))
            railContact = abs(lateral) >= railLimit - 1e-9 ? (lateral < 0 ? -1 : 1) : 0
            if lateral != unconstrained || railContact != 0 {
                // Contact removes motion through the wall and aligns forward
                // travel to its tangent. There is no bounce or pull to the centre.
                travelSlope = currentCourse.slope
                steeringVelocity = 0
            }
            // Relative motion caused by the road is not a steering animation.
            let heading = max(-16, min(16, steeringVelocity * 5 + railContact * 2))
            tubeHeading += (heading - tubeHeading) * (1 - exp(-7 * dt))
            // Resolve the final drawn pose too: a lean must never rotate the
            // visible tube onto a wall after its position was already checked.
            constrainToDividers()
            lateralVelocity = (lateral - oldLateral) / dt
            remaining -= dt
        }
        // Preserve exact elapsed travel even for a sub-integration-step frame.
        elapsed += max(0, remaining)
        feedbackRemaining = max(0, feedbackRemaining - seconds)
        impacts.removeAll { $0.age(at: elapsed) > 2.0 }
        let cameraDistance = distance
        checkpoints.removeAll {
            $0.selectedIndex != nil && $0.worldPosition + HoneySlideRules.dividerTail
                - cameraDistance <= HoneySlideRules.nearClipAhead
        }
    }

    private mutating func dividerLimits() -> (lower: Double, upper: Double) {
        let footprint = tubeFootprint
        var lower = -railLimit, upper = railLimit
        for i in checkpoints.indices {
            let row = checkpoints[i]
            let left = HoneyDividerContact.forbiddenLateral(rowPosition: row.worldPosition,
                boundary: -HoneySlideRules.laneBoundary, distance: distance,
                footprint: footprint, course: course)
            let right = HoneyDividerContact.forbiddenLateral(rowPosition: row.worldPosition,
                boundary: HoneySlideRules.laneBoundary, distance: distance,
                footprint: footprint, course: course)
            guard left != nil || right != nil else { continue }
            if checkpoints[i].guidedLane == nil {
                // Choose the side at the actual front contact, where perspective
                // makes the nose narrower than the road at the sprite anchor.
                // Midpoint-only lane choice could snap an edge rider across it.
                let leftMiddle = left.map { ($0.lowerBound + $0.upperBound) / 2 } ?? -0.33
                let rightMiddle = right.map { ($0.lowerBound + $0.upperBound) / 2 } ?? 0.33
                checkpoints[i].guidedLane = lateral < leftMiddle ? 0 : lateral > rightMiddle ? 2 : 1
            }
            let lane = checkpoints[i].guidedLane!
            if let left {
                if lane == 0 { upper = min(upper, left.lowerBound) }
                else { lower = max(lower, left.upperBound) }
            }
            if let right {
                if lane == 2 { lower = max(lower, right.upperBound) }
                else { upper = min(upper, right.lowerBound) }
            }
        }
        return (lower, upper)
    }

    private mutating func constrainToDividers() {
        var limits = dividerLimits()
        // A wide tablet tube can fit upright where a large lean cannot. Reduce
        // only that lean, retaining lateral control and the current channel.
        for _ in 0..<5 where limits.lower > limits.upper {
            tubeHeading *= 0.5
            limits = dividerLimits()
        }
        if limits.lower > limits.upper {
            tubeHeading = 0
            limits = dividerLimits()
        }
        let safe = max(limits.lower, min(limits.upper, lateral))
        if safe != lateral {
            let intoWall = (lateral - safe) * steeringVelocity > 0
            lateral = safe
            if intoWall { steeringVelocity = 0 }
            travelSlope = course.sample(at: distance + HoneySlideRules.playerAhead).slope
            railContact = 0
        }
    }

    /// Crossing is measured in world distance, never by an eased animation.
    func crossing(roundID: UUID) -> (checkpointID: Int, index: Int, option: AnswerOption)? {
        guard let row = activeCheckpoint, row.roundID == roundID,
              distance + HoneySlideRules.playerAhead + 1e-7 >= row.worldPosition,
              row.options.count == 3 else { return nil }
        let index = row.guidedLane ?? HoneySlideRules.collisionIndex(lateral: lateral)
        return (row.id, index, row.options[index])
    }

    mutating func markSelected(checkpointID: Int, index: Int, correct: Bool) {
        guard let i = checkpoints.firstIndex(where: { $0.id == checkpointID }),
              checkpoints[i].selectedIndex == nil else { return }
        checkpoints[i].selectedIndex = index
        checkpoints[i].wasCorrect = correct
        checkpoints[i].impactAt = elapsed
        let depth = HoneySlideRules.depth(ahead: checkpoints[i].worldPosition - distance)
        let impact = HoneyPotImpact(id: checkpointID, startedAt: elapsed,
            worldPosition: checkpoints[i].worldPosition, lane: index, text: checkpoints[i].options[index].text,
            correct: correct, origin: HoneySlideRules.ridingPoint(depth: depth,
                lateral: Double(index - 1) * HoneySlideRules.laneSpacing, distance: elapsed, course: course),
            scale: HoneySlideRules.answerScale(depth: depth))
        impacts.append(impact)
        lastContact = impact
        lastWasCorrect = correct
        feedbackRemaining = correct ? 1.0 : 1.8
        if let next = checkpoints.indices.first(where: { checkpoints[$0].selectedIndex == nil }) {
            checkpoints[next].revealedAt = elapsed
        }
    }
}
