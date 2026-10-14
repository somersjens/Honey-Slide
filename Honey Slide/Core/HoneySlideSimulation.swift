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
    var motionLimit: Double {
        let bank = HoneySlideRules.trackHalfWidth(depth: HoneySlideRules.playerDepth,
            widthScale: HoneyTrackWidth.scale(answerCount: trackAnswerCount))
        let pot = 79 * HoneySlideRules.answerScale(depth: HoneySlideRules.playerDepth) + 4
        let outerLane = lanePositions.map(abs).max() ?? 0
        return max(0, (bank - pot) / HoneySlideRules.ridingHalfWidth(depth: HoneySlideRules.playerDepth) - outerLane)
    }
    func slot(for optionIndex: Int) -> Int {
        moment == .swapping && optionIndex < 2 ? 1 - optionIndex : optionIndex
    }

    func lateralPosition(at index: Int, elapsed: Double) -> Double {
        guard lanePositions.indices.contains(index) else { return 0 }
        let age = max(0, elapsed - (activatedAt ?? elapsed))
        var position = lanePositions[index]
        if moment == .swapping, lanePositions.count >= 2, index < 2 {
            let t = max(0, min(1, (age - 0.8) / 2.2))
            let smooth = t * t * (3 - 2 * t)
            position += (lanePositions[1 - index] - position) * smooth
        }
        if activatedAt != nil && isMoving && motionLimit > 0 {
            let phase = (age * 0.42 / motionLimit + 1).truncatingRemainder(dividingBy: 4)
            let bounce = 1 - abs(phase - 2)
            position += (motionPhase < .pi ? 1 : -1) * motionLimit * bounce
        }
        return position
    }
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
        jumpHeight * HoneySlideRules.jumpLift + finishFlightProgress * (2.5 + finishFlightProgress)
    }
    private(set) var blockedLogID: Int?
    private(set) var boostUntil = 0.0
    private(set) var slowUntil = 0.0
    private(set) var collisionUntil = 0.0
    private(set) var tempoUntil = 0.0
    private(set) var jumpStartedAt: Double?
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
        if hasFinishStarted { return hasFinishLaunched ? 0 : 1.25 }
        return (hasRaceStarted ? difficulty.speedFactor : 1) * (elapsed < tempoUntil ? 1.16 : 1)
            * (isBoosted ? 1.6 : 1) * (elapsed < slowUntil ? 0.55 : 1)
            * (elapsed < collisionUntil ? 0.65 : 1)
    }
    var cameraZoom: Double {
        HoneySlideRules.cameraZoom(widthScale: widthProfile.scale(at: distance + HoneySlideRules.playerAhead))
            * (1 - jumpHeight * 0.18)
    }
    var cameraOffset: Double {
        let displacement = lateral * HoneySlideRules.ridingHalfWidth(depth: HoneySlideRules.playerDepth) * cameraZoom
        let visible = 800 - HoneyTubeGeometry.spriteWidth(in: viewport) / viewport.width * 800 * cameraZoom - 12
        return (displacement < 0 ? -1.0 : 1.0) * max(0, abs(displacement) - visible)
    }
    var speed: Double { blockedLogID == nil ? HoneySlideRules.forwardSpeed * speedFactor : 0 }
    var jumpHeight: Double {
        jump?.height(at: distance + HoneySlideRules.playerAhead) ?? 0
    }
    var isAirborne: Bool { jumpHeight > 0.16 || hasFinishLaunched }
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
                configureCheckpoint(at: index, round: round, plan: plan)
            }
        }
        if finish == nil, let totalQuestions,
           let last = rounds.firstIndex(where: { $0.number == totalQuestions }) {
            let row = checkpoints[upcoming[last]]
            widthProfile.appendFinish(after: row.worldPosition)
            course.straightenFinish(after: row.worldPosition)
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

    private mutating func configureCheckpoint(at index: Int, round: GameRound, plan: HoneyRaceDifficulty) {
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
        widthProfile.append(answerCount: moving ? 4 : options.count, rowPosition: checkpoints[index].worldPosition)
        checkpoints[index].options = options
        checkpoints[index].lanePositions = options.indices.map {
            -span + 2 * span * Double($0) / Double(options.count - 1)
        }
        checkpoints[index].moment = moment
        checkpoints[index].motionPhase = Double.random(in: 0...(.pi * 2), using: &random)
        checkpoints[index].configuredAt = elapsed
        checkpoints[index].revealLead = moment == .quick ? 1350 : HoneySlideRules.drawDistance
        let row = checkpoints[index]
        let answerLane = row.lanePositions[options.firstIndex(where: \.isCorrect)!]
        func randomLane(_ generator: inout SeededGenerator) -> Double {
            [-span * 0.9, 0.0, span * 0.9].randomElement(using: &generator)!
        }
        if plan.completed >= 1 {
            let obstacle: HoneyTrackItemKind = [.hive, .log].randomElement(using: &random)!
            addItem(obstacle, row: row, lead: 1850, lane: randomLane(&random))
            if moment == .risk {
                addItem(.boost, row: row, lead: HoneySlideRules.checkpointSpacing / 2, lane: answerLane)
            } else {
                let modifier: HoneyTrackItemKind = (moving ? [.boost, .whirlpool] : [.boost, .whirlpool, .ramp]).randomElement(using: &random)!
                let lead = modifier == .ramp ? HoneySlideRules.rampLead : modifier == .boost ? HoneySlideRules.checkpointSpacing / 2 : 950
                let rampLane = row.dividerBoundaries.randomElement(using: &random) ?? 0
                addItem(modifier, row: row, lead: lead,
                        lane: modifier == .ramp ? rampLane : randomLane(&random))
            }
        }
        if level >= 2 && plan.completed.isMultiple(of: 3) {
            // A tall hive briefly hides a pot on the straight approach. It is
            // cleared before the row, leaving time to steer around it.
            addItem(.hive, row: row, lead: 1180, lane: answerLane)
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
                elapsed = min(elapsed + dt, finish!.launchedAt! + HoneySlideRules.finishFlightDuration)
                remaining -= dt
                if isFinishComplete { break }
                continue
            }
            let oldDistance = distance, oldPosition = distance + HoneySlideRules.playerAhead
            let oldCourse = course.sample(at: oldPosition), oldLateral = lateral
            elapsed += dt
            holdElapsed += dt
            if heldDirection != 0 && holdElapsed > 0.24 { targetLateral = steeringTarget + heldDirection * dt * 1.25 }
            let limits = dividerLimits()
            if hasSteeringTarget {
                let target = max(limits.lower, min(limits.upper, steeringTarget))
                let gain = hasFinishStarted ? 240.0 : 95
                let damping = hasFinishStarted ? 30.0 : 18
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
            if lateral != unconstrained || railContact != 0 { travelSlope = currentCourse.slope; steeringVelocity = 0 }
            let heading = max(-16, min(16, steeringVelocity * 5 + railContact * 2))
            tubeHeading += (heading - tubeHeading) * (1 - exp(-7 * dt))
            constrainToDividers()
            constrainToLogSides(previousLateral: oldLateral)
            contactItems(from: oldPosition, to: position)
            revealActiveCheckpoint()
            latchCheckpointCrossing(from: oldPosition, to: position)
            if hasFinishStarted, let ramp = finish?.rampPosition, position >= ramp - 40 {
                finish?.launchedAt = elapsed
                lateral = 0; tubeHeading = 0; steeringVelocity = 0
                blockedLogID = nil
            }
            lateralVelocity = (lateral - oldLateral) / dt
            remaining -= dt
        }
        feedbackRemaining = max(0, feedbackRemaining - seconds)
        impacts.removeAll { $0.age(at: elapsed) > 2.0 }
        let cameraDistance = distance
        items.removeAll { $0.worldPosition - cameraDistance < -250 }
        checkpoints.removeAll {
            $0.selectedIndex != nil && $0.worldPosition + HoneySlideRules.dividerTail - cameraDistance <= HoneySlideRules.nearClipAhead
        }
    }

    private func logInterval(_ item: HoneyTrackItem, distance: Double) -> ClosedRange<Double>? {
        return HoneyLogContact.forbidden(item, distance: distance, footprint: logFootprint,
            course: course, cameraZoom: cameraZoom, viewport: viewport)
    }

    private mutating func permittedDistance(to proposed: Double) -> Double {
        if clearsLogs { blockedLogID = nil; return proposed }
        if let id = blockedLogID, let item = items.first(where: { $0.id == id }) {
            // Release at the painted edge, using the same contact as approach.
            // A fixed world-space radius left a large invisible margin beside
            // the smaller perspective-scaled log.
            if logInterval(item, distance: proposed)?.contains(lateral) == true { return distance }
            blockedLogID = nil
        }
        var result = proposed
        for i in items.indices where items[i].kind == .log {
            let item = items[i]
            guard abs(item.worldPosition - distance - HoneySlideRules.playerAhead) < 850,
                  let contact = logInterval(item, distance: result), contact.contains(lateral) else { continue }
            var lower = distance, upper = result
            for _ in 0..<12 {
                let middle = (lower + upper) / 2
                if logInterval(item, distance: middle)?.contains(lateral) == true { upper = middle }
                else { lower = middle }
            }
            result = lower
            blockedLogID = item.id
            if items[i].contactedAt == nil { items[i].contactedAt = elapsed }
        }
        return result
    }

    private mutating func constrainToLogSides(previousLateral: Double) {
        guard !clearsLogs, blockedLogID == nil else { return }
        for item in items where item.kind == .log {
            guard abs(item.worldPosition - distance - HoneySlideRules.playerAhead) < 850,
                  let range = logInterval(item, distance: distance), range.contains(lateral) else { continue }
            if previousLateral <= range.lowerBound { lateral = range.lowerBound - 0.001 }
            else if previousLateral >= range.upperBound { lateral = range.upperBound + 0.001 }
            steeringVelocity = 0
        }
    }

    private mutating func dividerLimits() -> (lower: Double, upper: Double) {
        var lower = -railLimit, upper = railLimit
        guard !isAirborne else { return (lower, upper) }
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
                if let row = checkpoints.first(where: { $0.id == item.checkpointID }) {
                    jumpStartedAt = elapsed
                    jump = HoneyRaceJump(startPosition: position, peakPosition: row.worldPosition - 20,
                        landingPosition: row.worldPosition + HoneySlideRules.jumpLandingTail)
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
            steeringTarget = 0; hasSteeringTarget = true; touchSteering = true
            knockbackVelocity = 0; blockedLogID = nil
        }
    }
}
