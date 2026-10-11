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
    private var tubeHalfWidth = 195.0
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
    var penaltyProgress: Double? {
        guard let last = impacts.last, !last.correct,
              last.age(at: elapsed) < HoneySlideRules.penaltyDuration else { return nil }
        return last.age(at: elapsed) / HoneySlideRules.penaltyDuration
    }
    var hasVisibleImpact: Bool {
        impacts.contains {
            $0.age(at: elapsed) < ($0.correct ? HoneySlideRules.collectionDuration : HoneySlideRules.penaltyDuration)
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

    mutating func configureViewport(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let spriteWidth = min(size.width * 0.285, size.height * 0.43)
        tubeHalfWidth = spriteWidth / size.width * 1600 * 0.46
        lateral = max(-railLimit, min(railLimit, lateral))
        steeringTarget = max(-railLimit, min(railLimit, steeringTarget))
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
            var channel: Int?
            var channelProgress = 0.0
            if let i = checkpoints.firstIndex(where: { $0.selectedIndex == nil }),
               distance + HoneySlideRules.playerAhead >= checkpoints[i].worldPosition - HoneySlideRules.dividerLead {
                if checkpoints[i].guidedLane == nil {
                    checkpoints[i].guidedLane = HoneySlideRules.collisionIndex(lateral: lateral)
                }
                channel = checkpoints[i].guidedLane
                channelProgress = min(1, max(0, (distance + HoneySlideRules.playerAhead
                    - (checkpoints[i].worldPosition - HoneySlideRules.dividerLead)) / HoneySlideRules.dividerLead))
                // Only an actual steering command targets the middle of the
                // selected channel. An idle rider keeps sliding along its rail.
                if hasSteeringTarget {
                    steeringTarget = Double(channel! - 1) * HoneySlideRules.laneSpacing
                }
            }
            if hasSteeringTarget {
                // Deliberate lane selection follows the road while the player
                // steers. A released tap finishes that one requested lane change.
                travelSlope = currentCourse.slope
                let acceleration = (steeringTarget - lateral) * 95 - steeringVelocity * 18
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
            if let channel {
                // Keep the tube clear of divider faces. Outer channels still
                // allow an unattended rider to travel alongside the outer rail.
                let center = Double(channel - 1) * 0.66
                let halfChannel = HoneySlideRules.laneBoundary - channelProgress * (HoneySlideRules.laneBoundary - 0.22)
                let low = channel == 0 ? -railLimit : center - halfChannel
                let high = channel == 2 ? railLimit : center + halfChannel
                let safe = max(low, min(high, lateral))
                if safe != lateral {
                    lateral = safe
                    travelSlope = currentCourse.slope
                    steeringVelocity = 0
                    railContact = 0
                }
            }
            lateralVelocity = (lateral - oldLateral) / dt
            // Relative motion caused by the road is not a steering animation.
            let heading = max(-16, min(16, steeringVelocity * 5 + railContact * 2))
            tubeHeading += (heading - tubeHeading) * (1 - exp(-7 * dt))
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

    /// Crossing is measured in world distance, never by an eased animation.
    func crossing(roundID: UUID) -> (checkpointID: Int, index: Int, option: AnswerOption)? {
        guard let row = activeCheckpoint, row.roundID == roundID,
              distance + HoneySlideRules.playerAhead >= row.worldPosition,
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
