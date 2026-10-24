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
    var previewTexts: [String] = []
    var selectedIndex: Int?
    var moment: HoneyAnswerMoment = .normal
    var lanePositions: [Double] = []
    var motionPhase = 0.0
    var configuredAt: Double?
    var activatedAt: Double?
    var guidedLane: Int?
    var revealLead = HoneySlideRules.drawDistance

    var potSize: Double { 1 }
    var isMoving: Bool { moment == .moving || moment == .swapping }
    var trackAnswerCount: Int { isMoving ? 4 : options.count }
    var dividerBoundaries: [Double] {
        isMoving ? [] : zip(lanePositions, lanePositions.dropFirst()).map { ($0 + $1) / 2 }
    }
    /// How far an end pot travels past its neighbor before it turns around.
    var motionLimit: Double {
        let bank = HoneySlideRules.trackHalfWidth(depth: HoneySlideRules.playerDepth,
            widthScale: HoneyTrackWidth.scale(answerCount: trackAnswerCount))
        let pot = 79 * HoneySlideRules.answerScale(depth: HoneySlideRules.playerDepth) + 4
        let limit = max(0, (bank - pot) / HoneySlideRules.ridingHalfWidth(depth: HoneySlideRules.playerDepth))
        return max(0, limit - HoneySlideRules.answerTouchSpacing)
    }
    func slot(for optionIndex: Int) -> Int {
        moment == .swapping && optionIndex < 2 ? 1 - optionIndex : optionIndex
    }

    /// Three pots swing like a Newton's cradle. Future rows are already in
    /// motion; they do not wait until the previous answer is collected.
    /// At each impact the neighbors meet, and their centers never cross.
    func lateralPosition(at index: Int, elapsed: Double) -> Double {
        guard lanePositions.indices.contains(index) else { return 0 }
        guard isMoving else { return lanePositions[index] }
        // Each pot keeps its cradle slot. Crossing slots made the left pot
        // become the middle one and overlap its neighbour.
        let slots = cradleSlots(at: elapsed)
        let slot = Double(index)
        let lower = max(0, min(slots.count - 1, Int(floor(slot))))
        let upper = min(slots.count - 1, lower + 1)
        let fraction = min(1, max(0, slot - Double(lower)))
        return slots[lower] * (1 - fraction) + slots[upper] * fraction
    }

    private func cradleSlots(at elapsed: Double) -> [Double] {
        let spacing = HoneySlideRules.answerTouchSpacing
        let amplitude = motionLimit
        let cycle = elapsed * 0.3125 + motionPhase / (.pi * 2)
        let phase = cycle - floor(cycle)
        let beat = min(3, Int(phase * 4))
        let local = phase * 4 - Double(beat)
        let incoming = cos(local * .pi / 2)
        let outgoing = sin(local * .pi / 2)
        var left = -spacing
        var right = spacing
        switch beat {
        case 0: left = -spacing - amplitude * incoming
        case 1: right = spacing + amplitude * outgoing
        case 2: right = spacing + amplitude * incoming
        default: left = -spacing - amplitude * outgoing
        }
        return [left, 0, right]
    }
    /// The ramp is the scoring choice: none of the pots is correct.
    var correctIsAbsent = false
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
    private(set) var widthProfile = HoneyTrackWidth()
    private(set) var elapsed = 0.0
    private(set) var distance = 0.0
    /// Projection APIs accept the old constant-speed clock; derive it from
    /// actual travel so camera, touch, pots and collisions share one position.
    var travelTime: Double { distance / HoneySlideRules.forwardSpeed }
    private(set) var difficulty = HoneyRaceDifficulty(completed: 0, streak: 0, mistakes: 0)
    private(set) var items: [HoneyTrackItem] = []
    private(set) var finish: HoneyFinish?
    var hasFinishStarted: Bool { finish?.startedAt != nil }
    var hasFinishLaunched: Bool { finish?.launchedAt != nil }
    var finishFlightProgress: Double {
        guard let launch = finish?.launchedAt else { return 0 }
        return min(1, max(0, (elapsed - launch) / HoneySlideRules.finishFlightDuration))
    }
    var isFinishComplete: Bool {
        finish?.launchedAt.map { elapsed >= $0 + HoneySlideRules.finishFlightDuration } ?? false
    }
    var riderLift: Double {
        let p = finishFlightProgress
        let eased = p * p * (3 - 2 * p)
        return jumpHeight * HoneySlideRules.jumpLift + eased * (2.5 + eased)
    }
    private(set) var blockedLogID: Int?
    private(set) var boostUntil = 0.0
    private(set) var slowUntil = 0.0
    private(set) var collisionUntil = 0.0
    private(set) var tempoUntil = 0.0
    private(set) var jumpStartedAt: Double?
    private var finishLaunchPace = 1.0
    private(set) var jump: HoneyRaceJump?
    private(set) var lastItemKind: HoneyTrackItemKind?
    private(set) var lastItemAt = -10.0
    private var knockbackVelocity = 0.0
    private var latchedCrossing: HoneyCheckpointCrossing?
    private var random: SeededGenerator
    private var nextItemID = 0
    private var hasRaceStarted = false

    var isBoosted: Bool { elapsed < boostUntil }
    var isSlowed: Bool { elapsed < slowUntil || elapsed < collisionUntil }
    var speedFactor: Double {
        if hasFinishLaunched { return 0 }
        return (hasRaceStarted ? difficulty.speedFactor : 1) * (elapsed < tempoUntil ? 1.16 : 1)
            * (isBoosted ? 1.6 : 1) * (elapsed < slowUntil ? 0.55 : 1)
            * (elapsed < collisionUntil ? 0.65 : 1)
    }
    private var targetCameraZoom: Double {
        HoneySlideRules.cameraZoom(widthScale: widthProfile.scale(at: distance + HoneySlideRules.playerAhead))
    }
    /// Eased toward the road width so a widening or narrowing stretch does not
    /// rescale every sprite in one step.
    private var smoothedZoom: Double?
    var cameraZoom: Double { smoothedZoom ?? targetCameraZoom }
    private var rawCameraOffset: Double {
        let displacement = lateral * HoneySlideRules.ridingHalfWidth(depth: HoneySlideRules.playerDepth) * cameraZoom
        let visible = 800 - HoneyTubeGeometry.spriteWidth(in: viewport) / viewport.width * 800 * cameraZoom - 12
        return (displacement < 0 ? -1.0 : 1.0) * max(0, abs(displacement) - visible)
    }
    private var smoothedOffset = 0.0
    var cameraOffset: Double { smoothedOffset }
    var speed: Double { blockedLogID == nil ? HoneySlideRules.forwardSpeed * speedFactor : 0 }
    var jumpHeight: Double {
        jump?.height(at: distance + HoneySlideRules.playerAhead) ?? 0
    }
    /// Nose up on the way up and nose down on the way down, following the sine.
    var jumpPitch: Double {
        guard let jump else { return 0 }
        let span = jump.landingPosition - jump.startPosition
        guard span > 0 else { return 0 }
        let t = (distance + HoneySlideRules.playerAhead - jump.startPosition) / span
        guard t > 0, t < 1 else { return 0 }
        return -cos(t * .pi) * 18
    }
    var isAirborne: Bool { jumpHeight > 0.16 || hasFinishLaunched }
    /// From the moment the plank is taken until the landing, the rider keeps
    /// the line they were on. Divider walls do not steer that flight into a lane.
    var isCoastingJump: Bool {
        guard let jump, jumpStartedAt != nil else { return false }
        return distance + HoneySlideRules.playerAhead < jump.landingPosition
    }
    /// Follow the high jump just enough to keep the bear below the wooden HUD.
    /// The same translation moves the ground, props and grounded shadow, so
    /// the physical lift relative to the answer pots remains unchanged.
    var jumpCameraOffset: Double {
        let hudScale = min(viewport.width / 1600, viewport.height / 900)
        let safeTop = 120 * hudScale + max(10, 32 * hudScale) + 10
        let originalHeight = HoneyTubeGeometry.spriteWidth(in: viewport) * HoneyTubeGeometry.imageAspect
        let height = originalHeight * cameraZoom
        let groundTop = viewport.height * 0.735 + (originalHeight - height) * 0.212 - height / 2
        let follow = max(0, safeTop - groundTop + viewport.height * HoneySlideRules.jumpLift)
        return jumpHeight * follow * 900 / viewport.height
    }
    private var clearsLogs: Bool {
        jumpHeight * viewport.height * HoneySlideRules.jumpLift > 130 * cameraZoom * viewport.width / 1600
    }

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
            heading: tubeHeading, reduceMotion: reduceMotion, cameraZoom: cameraZoom)
    }
    var logFootprint: HoneyTubeFootprint {
        HoneyTubeGeometry.footprint(in: viewport, elapsed: 0,
            heading: 0, reduceMotion: true, cameraZoom: cameraZoom, logContact: true)
    }
    var railLimit: Double {
        (HoneySlideRules.trackHalfWidth(depth: HoneySlideRules.playerDepth,
                widthScale: widthProfile.scale(at: distance + HoneySlideRules.playerAhead))
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

    init(courseSeed: UInt64 = UInt64.random(in: .min ... .max)) {
        course = HoneySlideCourse(seed: courseSeed)
        random = SeededGenerator(seed: courseSeed ^ 0xBEE)
    }

    var activeCheckpoint: HoneyCheckpoint? {
        checkpoints.first { $0.selectedIndex == nil }
    }

    mutating func synchronize(rounds: [GameRound], stage: Int, acceptingInput: Bool,
                              completed: Int = 0, streak: Int = 0, mistakes: Int = 0,
                              totalQuestions: Int? = nil) {
        guard !rounds.isEmpty, acceptingInput || checkpoints.isEmpty else { return }
        hasRaceStarted = true
        difficulty = HoneyRaceDifficulty(completed: completed, streak: streak, mistakes: mistakes)
        let spacing = HoneySlideRules.checkpointSpacing
        var upcoming = checkpoints.indices.filter { checkpoints[$0].selectedIndex == nil }
        while upcoming.count < rounds.count {
            let position = (checkpoints.last?.worldPosition
                            ?? distance + HoneySlideRules.playerAhead) + spacing
            checkpoints.append(HoneyCheckpoint(id: nextCheckpointID, worldPosition: position))
            nextCheckpointID += 1
            upcoming.append(checkpoints.count - 1)
        }
        for (i, round) in rounds.enumerated() {
            let index = upcoming[i]
            checkpoints[index].roundID = round.id
            checkpoints[index].previewTexts = round.options.map(\.text)
            if checkpoints[index].configuredAt == nil {
                let plan = HoneyRaceDifficulty(completed: max(completed + i, round.number - 1), streak: streak, mistakes: mistakes)
                configureCheckpoint(at: index, round: round, plan: plan, isFinal: round.number == totalQuestions)
            }
        }
        if finish == nil, let totalQuestions,
           let last = rounds.firstIndex(where: { $0.number == totalQuestions }) {
            let row = checkpoints[upcoming[last]]
            widthProfile.appendFinish(after: row.worldPosition)
            // Straighten from a full draw distance before the last row, but
            // never under the rider. The ramp and the last answers then sit
            // on the visible centerline instead of popping in around a bend.
            let approach = row.worldPosition - HoneySlideRules.drawDistance
            course.straightenFinish(after: max(approach, distance + HoneySlideRules.playerAhead))
            let rampID = nextItemID
            addItem(.ramp, row: row, lead: -HoneySlideRules.finishRampLead, lane: 0)
            finish = HoneyFinish(checkpointID: row.id, rowPosition: row.worldPosition,
                rampID: rampID, rampPosition: row.worldPosition + HoneySlideRules.finishRampLead)
        }
        if acceptingInput, let first = upcoming.first, checkpoints[first].activatedAt == nil {
            checkpoints[first].activatedAt = elapsed
        }
        revealActiveCheckpoint()
    }

    private mutating func configureCheckpoint(at index: Int, round: GameRound, plan: HoneyRaceDifficulty, isFinal: Bool) {
        let level = plan.level
        let moments: [HoneyAnswerMoment] = level == 0 ? [.normal]
            : level == 1 ? [.normal, .moving, .risk]
            : [.normal, .narrow, .moving, .swapping, .quick, .risk]
        let moment = moments.randomElement(using: &random)!
        let moving = moment == .moving || moment == .swapping
        let count = moving ? 3 : moment == .narrow ? 5 : moment == .normal && level > 0 ? 3
            : Int.random(in: 2...(level == 0 ? 3 : level == 1 ? 4 : 5), using: &random)
        guard let correct = round.correctOption else { return }
        let wrong = round.options.filter { !$0.isCorrect }.shuffled(using: &random)
        let options = ([correct] + wrong.prefix(count - 1)).shuffled(using: &random)
        let spacing = moment == .narrow ? 0.64 : HoneySlideRules.laneSpacing
        let span = Double(count - 1) * spacing / 2
        widthProfile.append(answerCount: moving ? 4 : count, rowPosition: checkpoints[index].worldPosition)
        checkpoints[index].lanePositions = (0..<count).map {
            -span + (count == 1 ? 0 : 2 * span * Double($0) / Double(count - 1))
        }
        checkpoints[index].moment = moment
        checkpoints[index].motionPhase = Double.random(in: 0...(.pi * 2), using: &random)
        checkpoints[index].configuredAt = elapsed
        // Open the numbers for the whole approach, including when this row
        // has more pots than the one just answered.
        checkpoints[index].revealLead = HoneySlideRules.checkpointSpacing + 500
        checkpoints[index].options = options
        let row = checkpoints[index]
        let answerLane = options.firstIndex(where: \.isCorrect).map { row.lanePositions[$0] } ?? 0
        func randomLane(_ generator: inout SeededGenerator) -> Double {
            [-span * 0.9, 0.0, span * 0.9].randomElement(using: &generator)!
        }
        if plan.completed >= 1 {
            // The final approach shows the end ramp, not a whirlpool standing in for it.
            let modifier: HoneyTrackItemKind
            if moment == .risk || (moving && isFinal) {
                modifier = .boost
            } else if moving {
                modifier = [.boost, .whirlpool].randomElement(using: &random)!
            } else if isFinal {
                modifier = [.boost, .ramp].randomElement(using: &random)!
            } else {
                modifier = [.boost, .whirlpool, .ramp].randomElement(using: &random)!
            }
            if modifier == .ramp, wrong.count >= count, Int.random(in: 0...count, using: &random) == 0 {
                // One extra choice, the ramp itself: each pot and "none of them"
                // are equally likely. Jumping the empty set still scores.
                checkpoints[index].options = Array(wrong.prefix(count))
                checkpoints[index].correctIsAbsent = true
            }
            let lead = modifier == .ramp ? HoneySlideRules.rampLead : modifier == .boost ? HoneySlideRules.checkpointSpacing / 2 : 950
            let rampLane = checkpoints[index].dividerBoundaries.randomElement(using: &random) ?? 0
            addItem(modifier, row: row, lead: lead,
                    lane: modifier == .ramp ? rampLane : (modifier == .boost && moment == .risk ? answerLane : randomLane(&random)))
            addDriftingLogs(for: row, rampLane: modifier == .ramp ? rampLane : nil)
        }
    }

    private mutating func addDriftingLogs(for row: HoneyCheckpoint, rampLane: Double?) {
        // One, two or three trunks, spread so they never travel as a pair.
        let count = Int.random(in: 1...3, using: &random)
        let leads = count == 1 ? [1900.0] : count == 2 ? [1450.0, 2500] : [1400.0, 2050, 2700]
        let lanes = [-0.38, 0.3, -0.12]
        for index in 0..<count {
            let lead = leads[index]
            var placed = lanes[index % lanes.count]
            if let rampLane, abs(placed - rampLane) < 0.7 {
                placed = rampLane >= 0 ? -0.55 : 0.55
            }
            addItem(.log, row: row, lead: lead, lane: placed)
        }
    }

    private mutating func addItem(_ kind: HoneyTrackItemKind, row: HoneyCheckpoint, lead: Double, lane: Double) {
        let position = row.worldPosition - lead
        let bank = HoneySlideRules.trackHalfWidth(depth: HoneySlideRules.playerDepth,
            widthScale: widthProfile.scale(at: position)) / HoneySlideRules.ridingHalfWidth(depth: HoneySlideRules.playerDepth)
        let bounds = kind.artworkLateralBounds
        let fittingLane = max(-bank - bounds.lowerBound + 0.004, min(bank - bounds.upperBound - 0.004, lane))
        items.append(HoneyTrackItem(id: nextItemID, checkpointID: row.id, kind: kind,
            worldPosition: position, lateral: fittingLane))
        nextItemID += 1
    }

    private mutating func revealActiveCheckpoint() {
        guard let index = checkpoints.firstIndex(where: { $0.selectedIndex == nil }),
              checkpoints[index].activatedAt != nil, checkpoints[index].revealedAt == nil,
              checkpoints[index].worldPosition - distance - HoneySlideRules.playerAhead <= checkpoints[index].revealLead else { return }
        checkpoints[index].revealedAt = elapsed
    }

    mutating func press(_ direction: Double) {
        guard !hasFinishStarted else { return }
        touchSteering = false
        heldDirection = direction
        holdElapsed = 0
        // A tap changes one lane; a sustained press also allows free steering.
        let positions = activeCheckpoint.map { row in
            row.options.indices.map { row.lateralPosition(at: $0, elapsed: elapsed) }
        } ?? [-0.66, 0, 0.66]
        let next = direction > 0 ? positions.sorted().first { $0 > lateral + 0.06 }
            : positions.sorted().reversed().first { $0 < lateral - 0.06 }
        targetLateral = next ?? direction * railLimit
    }

    mutating func steer(to target: Double) {
        guard !hasFinishStarted else { return }
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
        guard seconds > 0, seconds.isFinite, !isFinishComplete else { return }
        course.extend(through: distance + seconds * HoneySlideRules.forwardSpeed * 2.5 + HoneySlideRules.drawDistance)
        var remaining = seconds
        // Ignore the floating-point remainder after the final full step. A
        // sub-pixel approach probe could otherwise release a blocked log at
        // the exact touching point without moving the rider away from it.
        while remaining > 1e-9 {
            let dt = min(1.0 / 120, remaining)
            if hasFinishLaunched {
                let end = finish!.launchedAt! + HoneySlideRules.finishFlightDuration
                let step = min(dt, max(0, end - elapsed))
                if step > 0, let roadEnd = finish?.roadEnd {
                    // Travel forward along the ramp, and stop at its end so the
                    // flight does not carry the camera into the trees.
                    let glide = max(0, 1 - finishFlightProgress * 0.35)
                    let proposed = distance + HoneySlideRules.forwardSpeed * finishLaunchPace * glide * step
                    distance = min(roadEnd, proposed)
                }
                elapsed = min(elapsed + dt, end)
                remaining -= dt
                if isFinishComplete { break }
                continue
            }
            let oldDistance = distance, oldPosition = distance + HoneySlideRules.playerAhead
            let oldCourse = course.sample(at: oldPosition), oldLateral = lateral
            elapsed += dt
            holdElapsed += dt
            startVisibleLogDrift()
            if heldDirection != 0 && holdElapsed > 0.24 { targetLateral = steeringTarget + heldDirection * dt * 1.25 }
            let limits = dividerLimits()
            if isCoastingJump {
                // Hold the line left on the plank. Steering resumes after landing.
                steeringVelocity = 0
            } else if hasSteeringTarget {
                let target = max(limits.lower, min(limits.upper, steeringTarget))
                let gain = 95.0
                let damping = 18.0
                steeringVelocity += ((target - lateral) * gain - steeringVelocity * damping) * dt
                lateral += steeringVelocity * dt
                if !touchSteering && heldDirection == 0,
                   abs(steeringTarget - lateral) < 0.003, abs(steeringVelocity) < 0.02 {
                    hasSteeringTarget = false; steeringVelocity = 0
                }
            } else { steeringVelocity = 0 }
            lateral += knockbackVelocity * dt
            knockbackVelocity *= exp(-7 * dt)
            distance = permittedDistance(to: oldDistance + HoneySlideRules.forwardSpeed * speedFactor * dt)
            let position = distance + HoneySlideRules.playerAhead
            let currentCourse = course.sample(at: position)
            if hasSteeringTarget { travelSlope = currentCourse.slope }
            else {
                lateral += (travelSlope * (position - oldPosition)
                    - (currentCourse.x - oldCourse.x)) / HoneySlideRules.lateralWorldScale
            }
            let unconstrained = lateral
            lateral = max(-railLimit, min(railLimit, lateral))
            railContact = abs(lateral) >= railLimit - 1e-9 ? (lateral < 0 ? -1 : 1) : 0
            if lateral != unconstrained || railContact != 0 {
                travelSlope = currentCourse.slope
                // A push into the bank stops. Steering back toward the honey does not,
                // so the view does not rock once the pinch is behind the rider.
                if steeringVelocity * lateral > 0 { steeringVelocity = 0 }
            }
            let heading = max(-16, min(16, steeringVelocity * 5 + railContact * 2))
            tubeHeading += (heading - tubeHeading) * (1 - exp(-7 * dt))
            constrainToDividers()
            constrainToLogSides(previousLateral: oldLateral)
            contactItems(from: oldPosition, to: position)
            revealActiveCheckpoint()
            latchCheckpointCrossing(from: oldPosition, to: position)
            if hasFinishStarted, let ramp = finish?.rampPosition, position >= ramp - 40, finish?.launchedAt == nil {
                finishLaunchPace = max(0.9, speedFactor)
                finish?.launchedAt = elapsed
                steeringVelocity = 0
                clearBlockedLog()
            }
            lateralVelocity = (lateral - oldLateral) / dt
            easeCamera(dt)
            remaining -= dt
        }
        feedbackRemaining = max(0, feedbackRemaining - seconds)
        impacts.removeAll { $0.age(at: elapsed) > 2.0 }
        let cameraDistance = distance
        items.removeAll { $0.posed(at: elapsed).worldPosition - cameraDistance < -250 }
        checkpoints.removeAll {
            $0.selectedIndex != nil && $0.worldPosition + HoneySlideRules.dividerTail - cameraDistance <= HoneySlideRules.nearClipAhead
        }
    }

    private mutating func easeCamera(_ dt: Double) {
        let zoomTarget = targetCameraZoom
        let blend = 1 - exp(-5 * dt)
        if smoothedZoom == nil {
            smoothedZoom = zoomTarget
            smoothedOffset = rawCameraOffset
            return
        }
        smoothedZoom! += (zoomTarget - smoothedZoom!) * blend
        let delta = rawCameraOffset - smoothedOffset
        // Ignore a tiny target so a rail flicker cannot pan the whole scene.
        if abs(delta) > 18 || abs(smoothedOffset) > 24 {
            smoothedOffset += max(-90 * dt, min(90 * dt, delta))
        } else {
            smoothedOffset += (0 - smoothedOffset) * blend
        }
    }

    private mutating func startVisibleLogDrift() {
        let view = distance + HoneySlideRules.playerAhead
        for index in items.indices where items[index].kind == .log && items[index].driftStartedAt == nil {
            if items[index].worldPosition - view < 2800 {
                items[index].driftStartedAt = elapsed
            }
        }
    }

    private func logInterval(_ item: HoneyTrackItem, distance: Double) -> ClosedRange<Double>? {
        let sink = checkpoints.first(where: { $0.id == item.checkpointID })
            .map { item.sinkProgress(rowPosition: $0.worldPosition) } ?? 0
        return HoneyLogContact.forbidden(item, distance: distance, footprint: logFootprint,
            course: course, cameraZoom: cameraZoom, viewport: viewport, sinkProgress: sink)
    }

    private func logCoreHalf(_ item: HoneyTrackItem) -> Double {
        let depth = HoneySlideRules.depth(ahead: item.worldPosition - distance)
        return HoneyLogContact.coreHalf(depth: depth, cameraZoom: cameraZoom, viewport: viewport)
    }

    /// The middle of a trunk stops the rider. The ends overlap as a light shove
    /// and do not hold forward travel.
    private func logTouch(_ item: HoneyTrackItem, distance: Double) -> (solid: Bool, bump: Bool) {
        guard let full = logInterval(item, distance: distance), full.contains(lateral) else { return (false, false) }
        let solid = abs(lateral - item.lateral) <= logCoreHalf(item)
        return (solid, !solid)
    }

    private mutating func permittedDistance(to proposed: Double) -> Double {
        if clearsLogs { clearBlockedLog(); return proposed }
        var result = proposed
        var blockingID: Int?
        for i in items.indices where items[i].kind == .log {
            let posed = items[i].posed(at: elapsed)
            guard abs(posed.worldPosition - distance - HoneySlideRules.playerAhead) < 850 else { continue }
            let touch = logTouch(posed, distance: result)
            if touch.bump {
                if items[i].contactedAt == nil {
                    items[i].contactedAt = elapsed
                    let away = lateral >= posed.lateral ? 1.0 : -1.0
                    knockbackVelocity = away * 0.85
                }
                continue
            }
            let ahead = posed.worldPosition - distance - HoneySlideRules.playerAhead
            if ahead > 180 {
                continue
            }
            let held = logTouch(posed, distance: distance)
            if held.solid || (blockedLogID == items[i].id && logInterval(posed, distance: distance) != nil
                && abs(lateral - posed.lateral) <= logCoreHalf(posed) && ahead > -30) {
                // The rider stops in the world. The trunk's own drift is untouched,
                // so sitting against it does not slow the log down.
                result = distance
                blockingID = items[i].id
                if items[i].contactedAt == nil { items[i].contactedAt = elapsed }
                continue
            }
            guard touch.solid else { continue }
            var lower = distance, upper = result
            for _ in 0..<12 {
                let middle = (lower + upper) / 2
                if logTouch(posed, distance: middle).solid { upper = middle }
                else { lower = middle }
            }
            result = lower
            blockingID = items[i].id
            if items[i].contactedAt == nil { items[i].contactedAt = elapsed }
        }
        if let blockingID {
            pinBlockedLog(blockingID)
        } else if blockedLogID != nil {
            clearBlockedLog()
        }
        return result
    }

    private mutating func pinBlockedLog(_ id: Int) {
        blockedLogID = id
    }

    private mutating func clearBlockedLog() {
        blockedLogID = nil
    }

    private mutating func constrainToLogSides(previousLateral: Double) {
        guard !clearsLogs, blockedLogID == nil else { return }
        for item in items where item.kind == .log {
            let posed = item.posed(at: elapsed)
            guard abs(posed.worldPosition - distance - HoneySlideRules.playerAhead) < 850 else { continue }
            let core = logCoreHalf(posed)
            let band = (posed.lateral - core)...(posed.lateral + core)
            guard logTouch(posed, distance: distance).solid, band.contains(lateral) else { continue }
            if previousLateral <= band.lowerBound { lateral = band.lowerBound - 0.001 }
            else if previousLateral >= band.upperBound { lateral = band.upperBound + 0.001 }
            steeringVelocity = 0
        }
    }

    private mutating func dividerLimits() -> (lower: Double, upper: Double) {
        var lower = -railLimit, upper = railLimit
        guard !isAirborne, !isCoastingJump else { return (lower, upper) }
        let footprint = tubeFootprint
        for i in checkpoints.indices {
            let row = checkpoints[i]
            let boundaries = row.dividerBoundaries
            guard !boundaries.isEmpty, abs(row.worldPosition - distance - HoneySlideRules.playerAhead) < 950 else { continue }
            let contacts = boundaries.map { boundary in
                HoneyDividerContact.forbiddenLateral(rowPosition: row.worldPosition, boundary: boundary,
                    distance: distance, footprint: footprint, course: course, cameraZoom: cameraZoom,
                    tail: row.id == finish?.checkpointID ? 0 : HoneySlideRules.dividerTail)
            }
            guard contacts.contains(where: { $0 != nil }) else { continue }
            if checkpoints[i].guidedLane == nil {
                let centers = zip(boundaries, contacts).map { boundary, range in
                    range.map { ($0.lowerBound + $0.upperBound) / 2 } ?? boundary
                }
                checkpoints[i].guidedLane = centers.filter { lateral > $0 }.count
            }
            let lane = checkpoints[i].guidedLane!
            for (index, contact) in contacts.enumerated() {
                guard let contact else { continue }
                if lane <= index { upper = min(upper, contact.lowerBound) }
                else { lower = max(lower, contact.upperBound) }
            }
        }
        return (lower, upper)
    }

    private mutating func constrainToDividers() {
        var limits = dividerLimits()
        for _ in 0..<5 where limits.lower > limits.upper { tubeHeading *= 0.5; limits = dividerLimits() }
        if limits.lower > limits.upper { tubeHeading = 0; limits = dividerLimits() }
        let safe = max(limits.lower, min(limits.upper, lateral))
        if safe != lateral {
            if (lateral - safe) * steeringVelocity > 0 { steeringVelocity = 0 }
            lateral = safe
            travelSlope = course.sample(at: distance + HoneySlideRules.playerAhead).slope
            railContact = 0
        }
    }

    private mutating func contactItems(from oldPosition: Double, to position: Double) {
        guard !isAirborne else { return }
        for index in items.indices {
            let item = items[index]
            guard item.id != finish?.rampID, item.contactedAt == nil,
                  item.worldPosition + item.kind.halfLength >= oldPosition,
                  item.worldPosition - item.kind.halfLength <= position else { continue }
            let riderRadius = item.kind.isObstacle ? tubeHalfWidth / 740 : 0.05
            guard abs(item.lateral - lateral) <= item.kind.halfWidth + riderRadius else { continue }
            items[index].contactedAt = elapsed
            lastItemKind = item.kind
            lastItemAt = elapsed
            switch item.kind {
            case .boost: boostUntil = elapsed + 3
            case .whirlpool: slowUntil = elapsed + 2
            case .ramp:
                if let rowIndex = checkpoints.firstIndex(where: { $0.id == item.checkpointID }) {
                    let row = checkpoints[rowIndex]
                    checkpoints[rowIndex].guidedLane = nil
                    let start = row.worldPosition - HoneySlideRules.launchLipLead
                    let landing = row.worldPosition + HoneySlideRules.jumpLandingTail
                    jumpStartedAt = elapsed
                    jump = HoneyRaceJump(startPosition: start, peakPosition: (start + landing) / 2,
                        landingPosition: landing)
                }
            case .hive:
                collisionUntil = elapsed + 1.1
                let away = lateral == item.lateral ? (item.lateral >= 0 ? -1.0 : 1.0)
                    : (lateral < item.lateral ? -1.0 : 1.0)
                knockbackVelocity = away * 2.4
            case .log: break
            }
        }
    }

    private mutating func latchCheckpointCrossing(from oldPosition: Double, to position: Double) {
        guard latchedCrossing == nil, let row = activeCheckpoint, !row.options.isEmpty,
              oldPosition <= row.worldPosition, position + 1e-7 >= row.worldPosition else { return }
        let closest = row.options.indices.min {
            abs(row.lateralPosition(at: $0, elapsed: elapsed) - lateral)
                < abs(row.lateralPosition(at: $1, elapsed: elapsed) - lateral)
        }!
        let radius = 0.20 * row.potSize
        let captured = row.guidedLane.flatMap { lane in row.options.indices.first { row.slot(for: $0) == lane } }
        let index: Int? = isAirborne ? nil : captured ?? (abs(row.lateralPosition(at: closest, elapsed: elapsed) - lateral) <= radius ? closest : nil)
        latchedCrossing = HoneyCheckpointCrossing(checkpointID: row.id, index: index,
            option: index.map { row.options[$0] })
    }

    func crossing(roundID: UUID) -> HoneyCheckpointCrossing? {
        guard let row = activeCheckpoint, row.roundID == roundID,
              let contact = latchedCrossing, contact.checkpointID == row.id else { return nil }
        return contact
    }

    mutating func markSelected(checkpointID: Int, index: Int?, correct: Bool) {
        guard let i = checkpoints.firstIndex(where: { $0.id == checkpointID }),
              checkpoints[i].selectedIndex == nil,
              index == nil || checkpoints[i].options.indices.contains(index!) else { return }
        let row = checkpoints[i]
        checkpoints[i].selectedIndex = index ?? -1
        checkpoints[i].wasCorrect = correct
        checkpoints[i].impactAt = elapsed
        let depth = HoneySlideRules.depth(ahead: row.worldPosition - distance)
        let impact = HoneyPotImpact(id: checkpointID, startedAt: elapsed,
            worldPosition: row.worldPosition, lane: index ?? -1,
            text: index.map { row.options[$0].text } ?? "",
            correct: correct, origin: HoneySlideRules.ridingPoint(depth: depth,
                lateral: index.map { row.lateralPosition(at: $0, elapsed: elapsed) } ?? lateral,
                distance: travelTime, course: course, cameraZoom: cameraZoom, cameraOffset: cameraOffset),
            scale: HoneySlideRules.answerScale(depth: depth) * row.potSize * cameraZoom)
        impacts.append(impact)
        lastContact = impact
        lastWasCorrect = correct
        feedbackRemaining = correct ? 1.0 : 1.8
        latchedCrossing = nil
        if correct && (difficulty.streak + 1).isMultiple(of: 3) { tempoUntil = elapsed + 4 }
        if !correct { tempoUntil = elapsed }
        if checkpointID == finish?.checkpointID, !hasFinishStarted {
            finish?.startedAt = elapsed
            heldDirection = 0; holdElapsed = 0
            // Keep the speed and the lane. The narrowing bank carries a side
            // answer inward; nothing yanks the rider to the centre.
            steeringTarget = 0; hasSteeringTarget = false; steeringVelocity = 0
            touchSteering = false
            knockbackVelocity = 0; clearBlockedLog()
        }
    }
}
