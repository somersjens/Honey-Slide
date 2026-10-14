import Foundation
import CoreGraphics

@main struct HoneySlideChecks {
    static func main() {
        checkContinuousCheckpoints()
        checkFixedQuestionSessions()
        checkSteering()
        checkGeneratedTurns()
        checkStraightTravelAndRails()
        checkIdleCheckpoints()
        checkDividerChannels()
        checkDividerSweeps()
        checkDoubleSpeedCadence()
        checkProjection()
        checkFixedWidthRails()
        checkAnswerLayout()
        checkCameraPassage()
        checkImpactLifecycle()
        checkCollectionMotion()
        checkStraightLandings()
        checkCachedProjection()
        print("PASS: full-tube divider clearance through answered tails, immediate freedom before/after walls, 440 units/s with 6.6-second cadence, rounded, irregular course shapes, straight unattended travel, rail release at opposite turns and fixed-width verges, consistent slow-frame physics, continuous camera passage, straight checkpoint landings with stable dividers, pot impacts and Honey collection, fixed-question sessions and scores that only increase, ten-minute projection and undistorted pot proportions")
    }

    private static func checkCollectionMotion() {
        // All lanes and phone/tablet proportions: the first pose must match
        // the contact pot, the last must match the HUD, and neither can snap.
        for viewport in [CGSize(width: 667, height: 375), CGSize(width: 852, height: 393), CGSize(width: 1194, height: 834)] {
            for lane in -1...1 {
                let hudScale = min(viewport.width / 1600, viewport.height / 900)
                let ground = HoneySlideRules.ridingPoint(depth: HoneySlideRules.playerDepth,
                    lateral: Double(lane) * HoneySlideRules.laneSpacing, distance: 0)
                let potScale = HoneySlideRules.answerScale(depth: HoneySlideRules.playerDepth)
                let origin = CGPoint(x: ground.x / 1600 * viewport.width,
                    y: ground.y / 900 * viewport.height - 61 * potScale * viewport.width / 1600)
                let safeInset = viewport.width == 852 ? 59.0 : 0
                let sideInset = safeInset + max(12, 22 * hudScale)
                let hudWidth = viewport.width - 2 * sideInset
                let scorePanelWidth = (67.2 + 16 + 244 + 64) * hudScale
                let target = CGPoint(x: viewport.width - sideInset - scorePanelWidth + (32 + 67.2 / 2) * hudScale,
                                     y: max(10, 32 * hudScale) + 60 * hudScale)
                let initialScale = potScale * viewport.width / 1600 / 2
                let finalScale = 67.2 * hudScale / 308
                let signWidth = min(760 * hudScale, hudWidth * 0.5, hudWidth - 2 * (scorePanelWidth + 20 * hudScale))
                let sign = CGRect(x: (viewport.width - signWidth) / 2, y: max(10, 32 * hudScale),
                                  width: signWidth, height: 120 * hudScale)
                func pose(_ progress: Double) -> HoneyCollectionMotion {
                    HoneyCollectionMotion(progress: progress, origin: origin, target: target,
                                          initialScale: initialScale, finalScale: finalScale)
                }
                assert(pose(0).center == origin && pose(0).scale == initialScale && pose(0).rotation == 0)
                assert(pose(1).center == target && abs(pose(1).scale - finalScale) < 1e-12)
                var previous = pose(0)
                var lowestY = origin.y
                var landingStarted = false
                for frame in 1...1000 {
                    let current = pose(Double(frame) / 1000)
                    let direction = target.x >= origin.x ? 1.0 : -1
                    assert(direction * (current.center.x - previous.center.x) >= -1e-9)
                    assert(direction * (target.x - current.center.x) >= -1e-9)
                    lowestY = min(lowestY, current.center.y)
                    if current.center.y > previous.center.y { landingStarted = true }
                    if landingStarted {
                        assert(current.center.y >= previous.center.y)
                        assert(current.center.y <= target.y)
                    }
                    assert(current.scale <= previous.scale && current.scale >= finalScale - 1e-12)
                    assert(hypot(current.center.x - previous.center.x, current.center.y - previous.center.y) < 3)
                    let bounds = CGRect(x: current.center.x - 154 * current.scale,
                        y: current.center.y - 166 * current.scale, width: 308 * current.scale, height: 332 * current.scale)
                    assert(!bounds.intersects(sign), "Collecting pot disappeared behind the question sign")
                    previous = current
                }
                assert(landingStarted && lowestY < target.y - 332 * finalScale * 0.15)
                // Position and size settle without an end-of-flight wobble.
                for t in [0.00001, 0.99999] {
                    let endpoint = t < 0.5 ? pose(0) : pose(1)
                    let near = pose(t)
                    assert(hypot(near.center.x - endpoint.center.x, near.center.y - endpoint.center.y) < 0.0001)
                    assert(abs(near.scale - endpoint.scale) < 0.00001)
                }
            }
        }
    }

    private static func checkCachedProjection() {
        var maximumError = 0.0
        // Ten minutes of course positions, including horizon clipping, the
        // two lookup-grid boundaries and the exact near-camera fallback.
        for frame in 0..<200 {
            let elapsed = Double(frame) * 3.017
            let course = HoneySlideCourse(seed: UInt64(frame % 8), initialSegments: 128)
            let projection = HoneySlideProjection(elapsed: elapsed, course: course)
            for index in 0..<1300 {
                let depth = (Double(index) + 0.314) / 1000
                for offset in [-4.0, -1, 0, 1, 4] {
                    let actual = projection.point(depth: depth, offset: offset)
                    let exact = HoneySlideRules.trackPoint(depth: depth, offset: offset, distance: elapsed, course: course)
                    let error = max(abs(actual.x - exact.x), abs(actual.y - exact.y))
                    maximumError = max(maximumError, error)
                    assert(error < 0.5, "Projection cache changed a visible position: \(error)")
                }
            }
            for depth in [0.0, 1.3, 1.30001, 2, 12] {
                let actual = projection.point(depth: depth, offset: 1)
                let exact = HoneySlideRules.trackPoint(depth: depth, offset: 1, distance: elapsed, course: course)
                assert(abs(actual.x - exact.x) < 0.5 && abs(actual.y - exact.y) < 0.5)
            }
        }
        print("Projection cache: maximum error \(maximumError) logical pixels")
    }

    private static func checkContinuousCheckpoints() {
        var correctPositions = Set<Int>()
        let frameTimes = [1.0 / 60, 1.0 / 30, 0.087, 0.12, 1.0 / 120]
        for topic in [MathTopic.addition, .subtraction, .tables, .fractions, .percentages, .mixed] {
            let engine = MemoryGame(level: MathLevel(topic: topic, index: 3), seed: 42)
            var ride = HoneySlideSimulation(courseSeed: 42)
            assert(engine.start())
            assert(engine.turnCardsOver()); assert(engine.beginAnswering())
            ride.synchronize(rounds: engine.visibleRounds, stage: 1, acceptingInput: true)
            assert(ride.checkpoints.count == GameConfig.preparedRoundRunway)
            assert(ride.checkpoints.last!.worldPosition > HoneySlideRules.drawDistance)
            for question in 0..<10 {
                let round = engine.round!
                let row = ride.activeCheckpoint!
                assert(row.roundID == round.id && row.options.count == 3)
                assert(Set(row.options.map { AnswerValue($0.text) }).count == 3)
                assert(row.options.filter(\.isCorrect).count == 1)
                let correctIndex = row.options.firstIndex(where: \.isCorrect)!
                correctPositions.insert(correctIndex)
                ride.steer(to: Double(correctIndex - 1) * 0.66)
                let preview = ride.checkpoints.filter { $0.selectedIndex == nil && $0.id != row.id }
                assert(preview.allSatisfy { $0.revealedAt == nil && $0.shutterProgress(at: ride.elapsed) == 0 })
                let initialZ = row.worldPosition
                let initialOptions = row.options
                var frame = 0
                var previousY = 0.0
                var previousRate = 0.0
                while ride.distance + HoneySlideRules.playerAhead < initialZ {
                    let dt = frameTimes[frame % frameTimes.count]
                    let oldDistance = ride.distance
                    let oldDepth = HoneySlideRules.depth(ahead: initialZ - oldDistance)
                    let oldY = HoneySlideRules.trackPoint(depth: oldDepth, offset: 0, distance: ride.elapsed).y
                    ride.advance(seconds: dt)
                    assert(abs(ride.distance - oldDistance - HoneySlideRules.forwardSpeed * dt) < 0.000001)
                    let newDepth = HoneySlideRules.depth(ahead: initialZ - ride.distance)
                    let newY = HoneySlideRules.trackPoint(depth: newDepth, offset: 0, distance: ride.elapsed).y
                    let rate = (newY - oldY) / dt
                    // Perspective may increase apparent speed; there is no ease-out near the bear.
                    assert(newY > previousY && rate + 0.00001 >= previousRate)
                    previousY = newY; previousRate = rate
                    assert(ride.activeCheckpoint!.worldPosition == initialZ)
                    assert(ride.activeCheckpoint!.options == initialOptions)
                    frame += 1
                }
                let hit = ride.crossing(roundID: round.id)!
                assert(hit.index == correctIndex && hit.option.isCorrect)
                let score = engine.cards
                assert(engine.select(optionID: hit.option.id, wrongAnswerCostHalves: 0) != .ignored)
                ride.markSelected(checkpointID: hit.checkpointID, index: hit.index, correct: true)
                assert(engine.cards == score + 1)
                assert(engine.select(optionID: hit.option.id) == .ignored)
                assert(ride.crossing(roundID: round.id) == nil)
                // Contact doesn't remove the old barrels: they continue past the rider.
                assert(ride.checkpoints.first { $0.id == row.id }?.selectedIndex == correctIndex)
                assert(ride.activeCheckpoint!.revealedAt == ride.elapsed)
                assert(ride.activeCheckpoint!.shutterProgress(at: ride.elapsed) == 0)
                assert(ride.activeCheckpoint!.shutterProgress(at: ride.elapsed + HoneySlideRules.shutterDuration) == 1)
                assert(ride.checkpoints.filter { $0.id > preview.first!.id }.allSatisfy { $0.revealedAt == nil })
                assert(engine.finishResolving()); engine.advance()
                assert(engine.turnCardsOver()); assert(engine.beginAnswering())
                ride.synchronize(rounds: engine.visibleRounds, stage: question < 9 ? 1 : 2, acceptingInput: true)
                for old in preview {
                    let promoted = ride.checkpoints.first { $0.id == old.id }!
                    assert(promoted.worldPosition == old.worldPosition)
                    assert(promoted.options == old.options)
                }
                assert(ride.activeCheckpoint!.id == preview.first!.id)
            }
            assert(engine.result.correctAnswers == 10)
            // A mistake costs one point and promotes the already-existing next question.
            let row = ride.activeCheckpoint!
            let wrongIndex = row.options.firstIndex { !$0.isCorrect }!
            ride.steer(to: Double(wrongIndex - 1) * 0.66)
            while ride.distance + HoneySlideRules.playerAhead < row.worldPosition {
                ride.advance(seconds: 1.0 / 60)
            }
            let future = ride.checkpoints.first { $0.id > row.id }!
            let hit = ride.crossing(roundID: engine.round!.id)!
            assert(!hit.option.isCorrect)
            let score = engine.cards
            assert(engine.select(optionID: hit.option.id, wrongAnswerCostHalves: 0) != .ignored)
            ride.markSelected(checkpointID: hit.checkpointID, index: hit.index, correct: false)
            assert(engine.finishResolving()); engine.advance()
            assert(engine.turnCardsOver()); assert(engine.beginAnswering())
            ride.synchronize(rounds: engine.visibleRounds, stage: 2, acceptingInput: true)
            assert(engine.cards == score)
            assert(engine.completedQuestions == 11)
            assert(ride.activeCheckpoint!.id == future.id)
            assert(ride.activeCheckpoint!.worldPosition == future.worldPosition)
            assert(ride.activeCheckpoint!.options == future.options)
            assert(ride.activeCheckpoint!.roundID == future.roundID)
            // Zero elapsed time (a pause) changes neither placement nor steering.
            let frozenDistance = ride.distance, frozenLateral = ride.lateral
            ride.advance(seconds: 0)
            assert(ride.distance == frozenDistance && ride.lateral == frozenLateral)
        }
        assert(correctPositions.count == 3)
        // Cadence is independent of score or stage, and every replenished row
        // enters beyond the draw distance rather than appearing mid-course.
        for stage in 1...5 {
            let engine = MemoryGame(level: MathLevel(topic: .addition, index: 1), seed: 7)
            var ride = HoneySlideSimulation(courseSeed: 42)
            assert(engine.start()); assert(engine.turnCardsOver()); assert(engine.beginAnswering())
            ride.synchronize(rounds: engine.visibleRounds, stage: stage, acceptingInput: true)
            let first = ride.activeCheckpoint!
            assert(ride.checkpoints.last!.worldPosition > HoneySlideRules.drawDistance)
            ride.advance(seconds: HoneySlideRules.approachDuration(stage: stage))
            let option = first.options.first(where: \.isCorrect)!
            assert(engine.select(optionID: option.id) != .ignored)
            ride.markSelected(checkpointID: first.id, index: first.options.firstIndex(of: option)!, correct: true)
            assert(engine.finishResolving()); engine.advance()
            assert(engine.turnCardsOver()); assert(engine.beginAnswering())
            ride.synchronize(rounds: engine.visibleRounds, stage: stage, acceptingInput: true)
            assert(ride.checkpoints.last!.worldPosition - ride.distance > HoneySlideRules.drawDistance)
            assert(HoneySlideRules.approachDuration(stage: stage) == HoneySlideRules.checkpointInterval)
        }
    }

    private static func checkFixedQuestionSessions() {
        var totals = Set<Int>()
        for topic in [MathTopic.addition, .mixed] {
            for mode in PracticeMode.allCases {
                for pattern in 0...2 {
                    let engine = MemoryGame(level: MathLevel(topic: topic, index: 2), mode: mode, seed: 17)
                    assert(engine.start()); assert(engine.turnCardsOver()); assert(engine.beginAnswering())
                    totals.insert(engine.maximumRounds)
                    var expectedScore = 0
                    for n in 0..<engine.maximumRounds {
                        assert(engine.state == .answering && engine.roundNumber == n + 1)
                        assert(engine.completedQuestions == n)
                        // All wrong, all correct, and mistakes before/after earning honey.
                        let right = pattern == 1 || (pattern == 2 && n > 1 && n % 3 != 0)
                        let option = engine.round!.options.first { $0.isCorrect == right }!
                        let previousScore = engine.cards
                        assert(engine.select(optionID: option.id, usesBonusFish: true, wrongAnswerCostHalves: 6) != .ignored)
                        if right { expectedScore += 1 }
                        assert(engine.cards == expectedScore && engine.result.cardsEarned == expectedScore)
                        assert(engine.cards >= previousScore)
                        assert(engine.cards == engine.result.correctAnswers)
                        assert(engine.livesRemaining == GameConfig.startingLives)
                        assert(engine.completedQuestions == n + 1)
                        assert(engine.select(optionID: option.id) == .ignored)
                        assert(engine.finishResolving()); engine.advance()
                        if n + 1 < engine.maximumRounds {
                            assert(engine.state == .memorising)
                            assert(engine.turnCardsOver()); assert(engine.beginAnswering())
                        }
                    }
                    assert(engine.state == .gameOver && engine.gameOverReason == .roundsCompleted)
                    assert(engine.visibleRounds.isEmpty)
                    assert(engine.result.correctAnswers + engine.result.wrongAnswers == engine.maximumRounds)
                }
            }
        }
        assert(totals == Set([20, 30, 40, 50]))
        let engine = MemoryGame(level: MathLevel(topic: .addition, index: 1), mode: .order, seed: 5)
        assert(engine.start()); assert(engine.turnCardsOver()); assert(engine.beginAnswering())
        let wrong = engine.round!.options.first { !$0.isCorrect }!
        assert(engine.select(optionID: wrong.id) != .ignored)
        assert(engine.finishResolving()); engine.advance()
        let saved = engine.pausedSession(timeRemainingSeconds: 0)!
        assert(saved.cards == 0 && saved.wrongAnswers == 1 && saved.isResumable)
        let encoded = try! JSONEncoder().encode(saved)
        let loaded = try! JSONDecoder().decode(PausedSession.self, from: encoded)
        let resumed = MemoryGame(level: engine.level, mode: .order, seed: 6)
        assert(resumed.resume(from: loaded))
        assert(resumed.roundNumber == 2 && resumed.completedQuestions == 1 && resumed.cards == 0)
        for _ in 1..<resumed.maximumRounds {
            assert(resumed.turnCardsOver()); assert(resumed.beginAnswering())
            assert(resumed.select(optionID: resumed.round!.correctOption!.id) != .ignored)
            assert(resumed.finishResolving()); resumed.advance()
        }
        assert(resumed.state == .gameOver && resumed.cards == 19)
        assert(resumed.result.correctAnswers == 19 && resumed.result.wrongAnswers == 1)
    }

    private static func checkSteering() {
        var ride = HoneySlideSimulation(courseSeed: 42)
        ride.press(1); ride.release()
        for _ in 0..<60 { ride.advance(seconds: 1.0 / 120) }
        assert(ride.lateral > 0.57 && ride.lateral < 0.72)
        ride.press(-1); ride.release()
        for _ in 0..<60 { ride.advance(seconds: 1.0 / 120) }
        assert(abs(ride.lateral) < 0.1)
        ride.press(-1)
        for _ in 0..<120 { ride.advance(seconds: 1.0 / 120) }
        assert(ride.lateral < -0.70 && ride.lateral >= -ride.railLimit)
        ride.release()
        ride.steer(to: 0.66)
        for _ in 0..<120 { ride.advance(seconds: 1.0 / 120) }
        assert(ride.lateral > 0.60)
        for elapsed in stride(from: 0.0, through: 600, by: 3) {
            for depth in [0.1, 0.2, 0.4, 0.7, HoneySlideRules.playerDepth, 1.0, 1.3] {
                for lane in [-0.66, 0, 0.66] {
                    let touch = HoneySlideRules.ridingPoint(depth: depth, lateral: lane, distance: elapsed)
                    assert(abs(HoneySlideRules.steeringTarget(at: touch, elapsed: elapsed)! - lane) < 0.000001)
                }
                let edge = HoneySlideRules.trackPoint(depth: depth, offset: 1.1, distance: elapsed)
                assert(HoneySlideRules.steeringTarget(at: edge, elapsed: elapsed) == nil)
            }
        }
        assert(HoneySlideRules.steeringTarget(at: CGPoint(x: 800, y: 50), elapsed: 0) == nil)
        var slow = HoneySlideSimulation(courseSeed: 42), fast = HoneySlideSimulation(courseSeed: 42)
        slow.advance(seconds: 0.25)
        for _ in 0..<30 { fast.advance(seconds: 1.0 / 120) }
        assert(abs(slow.distance - fast.distance) < 0.000001)
    }

    private static func checkGeneratedTurns() {
        var shapes = Set<String>()
        var sawContinuingTurn = false
        var sawStraight = false
        var angles = Set<Int>()
        for seed in 0..<16 {
            var course = HoneySlideCourse(seed: UInt64(seed))
            let repeated = HoneySlideCourse(seed: UInt64(seed))
            let original = course.bends
            for (i, bend) in original.enumerated() {
                let other = repeated.bends[i]
                assert(bend.start == other.start && bend.length == other.length && bend.endSlope == other.endSlope)
                if i > 0, bend.direction != 0, bend.direction == original[i - 1].direction {
                    sawContinuingTurn = true
                }
                if bend.direction == 0 { sawStraight = true }
                assert(bend.length >= 1200 && bend.length <= 1700)
                let angle = abs(atan(bend.endSlope) - atan(bend.startSlope)) * 180 / .pi
                angles.insert(Int(angle))
                assert(angle <= 75.000001 && abs(atan(bend.endSlope)) <= 55.000001 * .pi / 180)
                for fraction in [0.1, 0.3, 0.5, 0.7, 0.9] {
                    let z = bend.start + bend.length * fraction
                    let rate = course.sample(at: z).turnRate
                    assert(bend.direction == 0 ? rate == 0 : rate * bend.direction > 0)
                    // The visible bend retains its direction, including the
                    // foreground formerly flattened to a straight strip.
                    let elapsed = (z - HoneySlideRules.playerAhead) / HoneySlideRules.forwardSpeed
                    for depth in [0.48, HoneySlideRules.playerDepth] {
                        let center = HoneySlideRules.trackPoint(depth: depth, offset: 0, distance: elapsed, course: course)
                        if bend.direction != 0 { assert((center.x - 800) * bend.direction > 0) }
                        for lane in [-0.66, 0, 0.66] {
                            let touch = HoneySlideRules.ridingPoint(depth: depth, lateral: lane, distance: elapsed, course: course)
                            let target = HoneySlideRules.steeringTarget(at: touch, elapsed: elapsed, course: course)!
                            assert(abs(target - lane) < 0.000001)
                        }
                    }
                }
            }
            shapes.insert(original.prefix(8).map { "\($0.start):\($0.length):\($0.endSlope)" }.joined(separator: ","))
            course.extend(through: 200_000)
            for (i, bend) in original.enumerated() {
                assert(course.bends[i].start == bend.start && course.bends[i].endSlope == bend.endSlope)
                assert(course.bends[i].startX == bend.startX)
            }
        }
        assert(shapes.count == 16 && sawContinuingTurn && sawStraight && angles.count > 15,
               "Generated courses still follow one repeating zigzag pattern")
        let firstRun = HoneySlideSimulation(), secondRun = HoneySlideSimulation()
        assert(firstRun.course.seed != secondRun.course.seed)
    }

    private static func checkIdleCheckpoints() {
        // Actual answer guides must not trap the rider at its first outside
        // rail or recenter it. Rounded corners can also pass through the middle.
        for seed in 0..<8 {
            var ride = HoneySlideSimulation(courseSeed: UInt64(seed))
            let engine = MemoryGame(level: MathLevel(topic: .addition, index: 1), seed: 71)
            assert(engine.start()); assert(engine.turnCardsOver()); assert(engine.beginAnswering())
            ride.synchronize(rounds: engine.visibleRounds, stage: 1, acceptingInput: true)
            var visited = Set<Int>()
            for _ in 0..<10 {
                let round = engine.round!
                while ride.crossing(roundID: round.id) == nil {
                    ride.advance(seconds: 1.0 / 60)
                    assert(ride.heldDirection == 0 && ride.steeringVelocity == 0)
                }
                let hit = ride.crossing(roundID: round.id)!
                visited.insert(hit.index)
                assert(hit.index >= 0 && hit.index <= 2)
                ride.markSelected(checkpointID: hit.checkpointID, index: hit.index, correct: hit.option.isCorrect)
                assert(engine.select(optionID: hit.option.id) != .ignored)
                assert(engine.finishResolving()); engine.advance()
                assert(engine.turnCardsOver()); assert(engine.beginAnswering())
                ride.synchronize(rounds: engine.visibleRounds, stage: 1, acceptingInput: true)
            }
            assert(visited.contains(0) && visited.contains(2),
                   "Varied course never released its idle rider from one outside lane")
            assert(engine.completedQuestions == 10)
        }
    }

    private static func checkStraightTravelAndRails() {
        for seed in 0..<16 {
            var idle = HoneySlideSimulation(courseSeed: UInt64(seed))
            let bends = idle.course.bends
            let firstSide = -bends[0].direction
            let firstEnd = (bends[1].start - HoneySlideRules.playerAhead) / HoneySlideRules.forwardSpeed - 0.01
            let initialWorldX = idle.riderWorldX
            var hitRail = false
            var ridingRailFrames = 0
            while idle.elapsed < firstEnd {
                let previous = idle.lateral, heading = idle.tubeHeading
                idle.advance(seconds: min(1.0 / 120, firstEnd - idle.elapsed))
                assert(abs(idle.lateral - previous) < 0.02)
                assert(abs(idle.tubeHeading - heading) < 1)
                assert(abs(idle.tubeHeading) <= 16)
                assert(idle.targetLateral == 0 && idle.steeringVelocity == 0)
                if !hitRail && idle.railContact == 0 {
                    assert(abs(idle.riderWorldX - initialWorldX) < 0.000001,
                           "Idle rider steered before making contact with a wall")
                    assert(idle.travelSlope == 0 && idle.tubeHeading == 0)
                }
                if idle.railContact != 0 { hitRail = true }
                if hitRail {
                    assert(abs(idle.lateral - firstSide * idle.railLimit) < 0.000001,
                           "Rider left the outside rail without steering")
                    ridingRailFrames += 1
                }
            }
            assert(hitRail && ridingRailFrames > 30)
            let reversal = bends.indices.dropFirst().first { bends[$0].direction == -bends[0].direction }!
            let secondEnd = (bends[reversal + 1].start - HoneySlideRules.playerAhead) / HoneySlideRules.forwardSpeed - 0.01
            var leftFirstRail = false
            var lastSlope = idle.travelSlope
            while idle.elapsed < secondEnd {
                let dt = min(1.0 / 120, secondEnd - idle.elapsed)
                let previousX = idle.riderWorldX
                let previousSlope = idle.travelSlope
                idle.advance(seconds: dt)
                if idle.railContact == 0 {
                    leftFirstRail = true
                    // Detachment restores the existing straight trajectory;
                    // it does not apply an automatic target on the other side.
                    assert(abs(idle.travelSlope - previousSlope) < 0.000001)
                    assert(abs(idle.riderWorldX - previousX - previousSlope * HoneySlideRules.forwardSpeed * dt) < 0.000001)
                    assert(abs(idle.travelSlope - lastSlope) < 0.000001)
                } else {
                    lastSlope = idle.travelSlope
                }
                assert(idle.steeringVelocity == 0 && idle.targetLateral == 0)
            }
            assert(leftFirstRail && idle.lateral * firstSide < idle.railLimit - 0.10,
                   "Opposite corner failed to release the rider from its rail")

            // Steering away from a contacted rail must work immediately.
            idle.steer(to: 0)
            idle.advance(seconds: 0.8)
            assert(abs(idle.lateral) < 0.03 && idle.railContact == 0)
            let pausedLateral = idle.lateral, pausedHeading = idle.tubeHeading
            idle.advance(seconds: 0)
            assert(idle.lateral == pausedLateral && idle.tubeHeading == pausedHeading)

            var released = HoneySlideSimulation(courseSeed: UInt64(seed))
            released.steer(to: 0)
            released.advance(seconds: 1)
            released.release()
            released.advance(seconds: firstEnd - 1)
            assert(abs(released.lateral - firstSide * released.railLimit) < 0.000001)
            var keyboard = HoneySlideSimulation(courseSeed: UInt64(seed))
            keyboard.press(bends[0].direction)
            keyboard.advance(seconds: firstEnd)
            assert(keyboard.lateral * bends[0].direction > 0.60)

            // A slow frame traverses the same bend and wall contact as fast frames.
            var slow = HoneySlideSimulation(courseSeed: UInt64(seed))
            var fast = HoneySlideSimulation(courseSeed: UInt64(seed))
            slow.advance(seconds: 10)
            for _ in 0..<1200 { fast.advance(seconds: 1.0 / 120) }
            assert(abs(slow.distance - fast.distance) < 0.000001)
            assert(abs(slow.lateral - fast.lateral) < 0.000001)
            assert(abs(slow.tubeHeading - fast.tubeHeading) < 0.000001)
        }
        // The tube's footprint changes with phone/tablet aspect ratio. Its edge
        // must meet the same projected rail, without hiding the rider offscreen.
        for size in [CGSize(width: 852, height: 393), CGSize(width: 1194, height: 834)] {
            var ride = HoneySlideSimulation(courseSeed: 42)
            ride.configureViewport(size)
            let spriteWidth = HoneyTubeGeometry.spriteWidth(in: size) / size.width * 1600
            let contact = ride.railLimit * HoneySlideRules.ridingHalfWidth(depth: HoneySlideRules.playerDepth)
            let rail = HoneySlideRules.trackHalfWidth(depth: HoneySlideRules.playerDepth)
            assert(abs(rail - contact - spriteWidth * 0.46 - HoneySlideRules.railClearance) < 0.000001)
            assert(800 + contact + spriteWidth / 2 < 1640)
        }
    }

    private static func checkImpactLifecycle() {
        for correct in [true, false] {
            let engine = MemoryGame(level: MathLevel(topic: .addition, index: 1), seed: 71)
            assert(engine.start()); assert(engine.turnCardsOver()); assert(engine.beginAnswering())
            var ride = HoneySlideSimulation(courseSeed: 42)
            ride.synchronize(rounds: engine.visibleRounds, stage: 1, acceptingInput: true)
            let row = ride.activeCheckpoint!
            let index = row.options.firstIndex { $0.isCorrect == correct }!
            ride.steer(to: Double(index - 1) * HoneySlideRules.laneSpacing)
            while ride.crossing(roundID: row.roundID!) == nil { ride.advance(seconds: 1.0 / 120) }
            let depth = HoneySlideRules.depth(ahead: row.worldPosition - ride.distance)
            let origin = HoneySlideRules.ridingPoint(depth: depth, lateral: Double(index - 1) * 0.66, distance: ride.elapsed)
            let hit = ride.crossing(roundID: row.roundID!)!
            assert(engine.select(optionID: hit.option.id) != .ignored)
            ride.markSelected(checkpointID: row.id, index: index, correct: correct)
            let impact = ride.impacts.first!
            assert(impact.id == row.id && impact.origin == origin && impact.text == hit.option.text)
            assert(impact.scale == HoneySlideRules.answerScale(depth: depth) && impact.correct == correct)
            assert(impact.progress(at: ride.elapsed) == 0)
            assert(!ride.visualOutcomeSettled)
            assert(ride.pendingHoney == (correct ? 1 : 0))
            assert(max(0, engine.cards - ride.pendingHoney) == 0)
            assert(ride.hasVisibleImpact)
            // A duplicate collision, a new question and a paused clock cannot
            // restart an effect or change the number carried by the old pot.
            ride.markSelected(checkpointID: row.id, index: index, correct: correct)
            assert(ride.impacts.count == 1)
            assert(engine.finishResolving()); engine.advance()
            assert(engine.turnCardsOver()); assert(engine.beginAnswering())
            ride.synchronize(rounds: engine.visibleRounds, stage: 1, acceptingInput: true)
            let time = ride.elapsed
            ride.advance(seconds: 0)
            assert(ride.elapsed == time && ride.impacts[0].text == hit.option.text)
            let duration = correct ? HoneySlideRules.collectionDuration : HoneySlideRules.tumbleDuration
            ride.advance(seconds: duration / 2)
            assert(abs(impact.progress(at: ride.elapsed) - 0.5) < 0.000001)
            assert(ride.pendingHoney == (correct ? 1 : 0))
            ride.advance(seconds: duration / 2 + 0.001)
            assert(impact.progress(at: ride.elapsed) == 1 && ride.pendingHoney == 0)
            assert(!ride.hasVisibleImpact)
            if !correct {
                assert(engine.cards == 0)
            }
            ride.advance(seconds: 2.1)
            assert(ride.impacts.isEmpty)
            assert(ride.visualOutcomeSettled && ride.lastContact?.id == row.id)
            // Frame stalls can skip drawing an effect's last frame; they must
            // never strand the final question behind an unfinished result.
            ride.advance(seconds: 4)
            assert(ride.visualOutcomeSettled)
        }
    }

    private static func checkStraightLandings() {
        let course = HoneySlideCourse.preview
        for index in 0..<100 {
            let row = HoneySlideRules.firstCheckpointPosition + Double(index) * HoneySlideRules.checkpointSpacing
            let anchor = course.sample(at: row)
            for dz in stride(from: -349.0, through: 279, by: 13) {
                let sample = course.sample(at: row + dz)
                assert(abs(sample.x - anchor.x - anchor.slope * dz) < 0.000001)
                assert(abs(sample.slope - anchor.slope) < 0.000001 && sample.turnRate == 0)
            }
            for camera in stride(from: row - HoneySlideRules.playerAhead - HoneySlideRules.dividerLead,
                                 through: row + 250, by: 17) {
                for block in 0..<HoneySlideRules.dividerSections {
                    let segment = HoneySlideRules.dividerSegment(rowPosition: row, index: block)
                    for z in [segment.far, segment.near] where z - camera > HoneySlideRules.nearClipAhead {
                        let depth = HoneySlideRules.depth(ahead: z - camera)
                        let center = HoneySlideRules.trackPoint(depth: depth, offset: 0,
                            distance: camera / HoneySlideRules.forwardSpeed, course: course)
                        assert(abs(center.x - 800) < 0.000001)
                    }
                }
            }
        }
        for bend in course.bends {
            for edge in [bend.start, bend.end] {
                let before = course.sample(at: edge - 0.0001), after = course.sample(at: edge + 0.0001)
                assert(abs(after.x - before.x) < 0.003)
                assert(abs(after.slope - before.slope) < 0.000001)
                assert(abs(after.turnRate - before.turnRate) < 0.000001)
            }
        }
    }

    private static func checkDividerChannels() {
        let engine = MemoryGame(level: MathLevel(topic: .addition, index: 1), mode: .order, seed: 9)
        assert(engine.start()); assert(engine.turnCardsOver()); assert(engine.beginAnswering())
        for size in [CGSize(width: 852, height: 393), CGSize(width: 1194, height: 834)] {
            for start in [-0.66, -0.40, -0.331, -0.32, -0.06, 0.06, 0.32, 0.331, 0.40, 0.66] {
                var ride = HoneySlideSimulation(courseSeed: 42)
                ride.configureViewport(size)
                ride.synchronize(rounds: engine.visibleRounds, stage: 1, acceptingInput: true)
                let row = ride.activeCheckpoint!
                ride.steer(to: start)
                while ride.activeCheckpoint!.guidedLane == nil {
                    let before = ride.lateral
                    ride.advance(seconds: 1.0 / 120)
                    assert(abs(ride.lateral - before) < 0.065, "Tube jumped at divider entrance: \(ride.lateral - before), start \(start), size \(size), time \(ride.elapsed)")
                }
                let nearest = ride.activeCheckpoint!.guidedLane!
                assert((0..<3).contains(nearest))
                assert(ride.distance + HoneySlideRules.playerAhead < row.worldPosition - HoneySlideRules.dividerLead,
                    "Capture must include the front of the tube")
                while ride.crossing(roundID: row.roundID!) == nil {
                    // A late tap, drag, or held key cannot cut across a wall.
                    ride.steer(to: nearest == 2 ? -0.78 : 0.78)
                    ride.press(nearest == 2 ? -1 : 1)
                    ride.advance(seconds: 1.0 / 60)
                    assert(ride.activeCheckpoint!.guidedLane == nearest)
                    assert(HoneySlideRules.collisionIndex(lateral: ride.lateral) == nearest)
                    assertTubeClear(ride, row: row)
                }
                let hit = ride.crossing(roundID: row.roundID!)!
                assert(hit.index == nearest && hit.option == row.options[nearest])
                ride.markSelected(checkpointID: row.id, index: hit.index, correct: hit.option.isCorrect)
                assert(ride.activeCheckpoint!.guidedLane == nil)
                ride.release()
                let requested = nearest == 2 ? -0.66 : 0.66
                ride.steer(to: requested)
                // The answered row remains a physical obstacle, including its tail.
                for _ in 0..<24 {
                    ride.advance(seconds: 1.0 / 120)
                    assert(HoneySlideRules.collisionIndex(lateral: ride.lateral) == nearest)
                    assertTubeClear(ride, row: row)
                    assert(ride.targetLateral == requested, "Wall replaced the player's steering request")
                }
                for _ in 0..<156 { ride.advance(seconds: 1.0 / 120) }
                assert(abs(ride.lateral - requested) < 0.03, "Steering did not resume beyond the wall")
            }
        }
        // Phone and tablet canvases have different aspect ratios, but both
        // dimensions of every upright pot must use the same physical scale.
        for size in [CGSize(width: 852, height: 393), CGSize(width: 1194, height: 834),
                     CGSize(width: 1600, height: 900), CGSize(width: 932, height: 430)] {
            let sx = size.width / 1600, sy = size.height / 900
            let correction = HoneySlideRules.billboardVerticalScale(viewport: size)
            let renderedRatio = (130 * sx) / (116 * sy * correction)
            assert(abs(renderedRatio - 130.0 / 116) < 0.000001)
        }
    }

    /// Independently sample the complete rendered oval against every wall face.
    /// This catches extrema missed by the contact solver, and checks selected rows.
    private static func assertTubeClear(_ ride: HoneySlideSimulation, row: HoneyCheckpoint) {
        let footprint = ride.tubeFootprint
        let playerX = HoneySlideRules.trackPoint(depth: HoneySlideRules.playerDepth, offset: 0,
            distance: ride.elapsed, course: ride.course).x
        let far = row.worldPosition + HoneySlideRules.dividerTail - ride.distance
        guard far > HoneySlideRules.nearClipAhead else { return }
        let tf = HoneySlideRules.depth(ahead: far)
        let tn = HoneySlideRules.depth(ahead: row.worldPosition - HoneySlideRules.dividerLead - ride.distance)
        let top = HoneySlideRules.groundY(depth: tf) - HoneySlideRules.dividerHeight * tf
        let bottom = HoneySlideRules.groundY(depth: tn)
        let lane = ride.checkpoints.first { $0.id == row.id }!.guidedLane ?? HoneySlideRules.collisionIndex(lateral: ride.lateral)
        for sample in 0...120 {
            let y = footprint.minY + (footprint.maxY - footprint.minY) * Double(sample) / 120
            guard y > top && y < bottom else { continue }
            let depths = [max(tf, HoneySlideRules.groundDepth(screenY: y)),
                min(tn, HoneySlideRules.groundDepth(screenY: y, height: HoneySlideRules.dividerHeight))]
            let tube = footprint.slice(at: y)
            let tubeLeft = playerX + ride.lateral * 740 + tube.lowerBound
            let tubeRight = playerX + ride.lateral * 740 + tube.upperBound
            for boundary in [-0.33, 0.33] {
                let edges = depths.flatMap { depth in
                    [boundary - 0.03, boundary + 0.03].map {
                        HoneySlideRules.ridingPoint(depth: depth, lateral: $0,
                            distance: ride.elapsed, course: ride.course).x
                    }
                }
                if (boundary < 0 && lane == 0) || (boundary > 0 && lane < 2) {
                    assert(tubeRight <= edges.min()! + 0.01, "Right tube edge intersects divider: \(tubeRight - edges.min()!) at y \(y), time \(ride.elapsed), lane \(lane), lateral \(ride.lateral), heading \(ride.tubeHeading), bounds \(String(describing: HoneyDividerContact.forbiddenLateral(rowPosition: row.worldPosition, boundary: boundary, distance: ride.distance, footprint: footprint, course: ride.course)))")
                } else {
                    assert(tubeLeft >= edges.max()! - 0.01, "Left tube edge intersects divider: \(edges.max()! - tubeLeft), time \(ride.elapsed), lane \(lane)")
                }
            }
        }
    }

    private static func checkDividerSweeps() {
        let engine = MemoryGame(level: MathLevel(topic: .addition, index: 1), seed: 9)
        assert(engine.start()); assert(engine.turnCardsOver()); assert(engine.beginAnswering())
        for reduced in [false, true] {
            for size in [CGSize(width: 852, height: 393), CGSize(width: 1194, height: 834),
                         CGSize(width: 1600, height: 900), CGSize(width: 932, height: 430)] {
                for lane in 0..<3 {
                    var ride = HoneySlideSimulation(courseSeed: 42)
                    ride.configureViewport(size, reduceMotion: reduced)
                    ride.synchronize(rounds: engine.visibleRounds, stage: 1, acceptingInput: true)
                    let row = ride.activeCheckpoint!
                    ride.steer(to: Double(lane - 1) * 0.66)
                    // Before physical contact all three lanes remain available.
                    ride.advance(seconds: 4.6)
                    assert(ride.activeCheckpoint!.guidedLane == nil)
                    ride.steer(to: Double(1 - lane) * 0.66)
                    ride.advance(seconds: 0.5)
                    assert(ride.activeCheckpoint!.guidedLane == nil)
                    assert(abs(ride.lateral - Double(1 - lane) * 0.66) < 0.09)
                    ride.steer(to: Double(lane - 1) * 0.66)
                    while ride.activeCheckpoint!.guidedLane == nil { ride.advance(seconds: 1.0 / 120) }
                    let captured = ride.activeCheckpoint!.guidedLane!
                    let opposite = captured == 2 ? -0.66 : 0.66
                    // A single long frame must agree with the fine integration.
                    var fast = ride, slow = ride
                    fast.steer(to: opposite); slow.steer(to: opposite)
                    slow.advance(seconds: 0.75)
                    for _ in 0..<90 { fast.advance(seconds: 1.0 / 120); assertTubeClear(fast, row: row) }
                    assert(abs(fast.lateral - slow.lateral) < 0.000001)
                    assert(abs(fast.tubeHeading - slow.tubeHeading) < 0.000001)
                    ride = fast
                    while ride.crossing(roundID: row.roundID!) == nil {
                        ride.advance(seconds: 1.0 / 120)
                        assertTubeClear(ride, row: row)
                    }
                    let hit = ride.crossing(roundID: row.roundID!)!
                    ride.markSelected(checkpointID: row.id, index: hit.index, correct: hit.option.isCorrect)
                    // Resize while still alongside an answered divider.
                    ride.configureViewport(size.width == 1194 ? CGSize(width: 852, height: 393) : CGSize(width: 1194, height: 834), reduceMotion: reduced)
                    assertTubeClear(ride, row: row)
                    var tailFrames = 0
                    while HoneyDividerContact.forbiddenLateral(rowPosition: row.worldPosition, boundary: 0.33,
                        distance: ride.distance, footprint: ride.tubeFootprint, course: ride.course) != nil {
                        ride.advance(seconds: 1.0 / 120)
                        assertTubeClear(ride, row: row)
                        tailFrames += 1
                        assert(tailFrames < 120)
                    }
                    assert(tailFrames > 24, "Wall released while the rear of the tube was still alongside it")
                    let before = ride.lateral
                    ride.advance(seconds: 1.0 / 120)
                    assert((ride.lateral - before) * (opposite - before) > 0,
                        "Tube remained locked after clearing the wall")
                    ride.advance(seconds: 0.75)
                    assert(abs(ride.lateral - opposite) < 0.03)
                }
            }
        }
    }

    private static func checkDoubleSpeedCadence() {
        let engine = MemoryGame(level: MathLevel(topic: .addition, index: 1), seed: 7)
        assert(engine.start()); assert(engine.turnCardsOver()); assert(engine.beginAnswering())
        var ride = HoneySlideSimulation(courseSeed: 42)
        ride.synchronize(rounds: engine.visibleRounds, stage: 1, acceptingInput: true)
        for question in 1...20 {
            let row = ride.activeCheckpoint!
            let index = row.options.firstIndex(where: \.isCorrect)!
            ride.steer(to: Double(index - 1) * 0.66)
            let toContact = (row.worldPosition - ride.distance - HoneySlideRules.playerAhead) / 440
            let before = ride.distance
            ride.advance(seconds: toContact)
            assert(abs(ride.distance - before - 440 * toContact) < 0.000001)
            assert(abs(ride.elapsed - Double(question) * 6.6) < 0.000001)
            let hit = ride.crossing(roundID: engine.round!.id)!
            ride.markSelected(checkpointID: row.id, index: hit.index, correct: hit.option.isCorrect)
            assert(engine.select(optionID: hit.option.id) != .ignored)
            assert(engine.finishResolving()); engine.advance()
            if question < 20 {
                assert(engine.turnCardsOver()); assert(engine.beginAnswering())
                ride.synchronize(rounds: engine.visibleRounds, stage: 1, acceptingInput: true)
            }
        }
        let initialDepth = HoneySlideRules.depth(ahead: HoneySlideRules.firstCheckpointPosition)
        let initialWidth = 154 * HoneySlideRules.answerScale(depth: initialDepth)
        assert(initialWidth >= 36 && initialWidth <= 39, "Distant active answers became unreadably small")
        assert(HoneySlideRules.shutterDuration == 0.42 && HoneySlideRules.collectionDuration == 0.65)
        print("Speed/cadence: 440 units/s, 20 contacts at 6.6 s intervals; initial pot width \(initialWidth)")
    }

    private static func checkProjection() {
        let samples = HoneySlideRules.trackDepthSamples
        assert(samples.first == 0 && abs(samples.last! - 1.3) < 0.000001)
        assert(zip(samples, samples.dropFirst()).allSatisfy { $0 < $1 })
        assert(samples.count < 180)
        for ahead in stride(from: 0.0, through: HoneySlideRules.drawDistance, by: 24) {
            let t = HoneySlideRules.depth(ahead: ahead)
            assert(abs(HoneySlideRules.focalLength * (1 / t - 1) - ahead) < 0.00001)
        }
        for second in stride(from: 0.0, through: 600.0, by: 0.5) {
            let left = HoneySlideRules.trackPoint(depth: 1.3, offset: -1, distance: second)
            let right = HoneySlideRules.trackPoint(depth: 1.3, offset: 1, distance: second)
            assert(left.x < 0 && right.x > 1600 && left.y > 900)
            let midLeft = HoneySlideRules.trackPoint(depth: 0.48, offset: -1, distance: second)
            let midRight = HoneySlideRules.trackPoint(depth: 0.48, offset: 1, distance: second)
            assert(midLeft.x < 1600 && midRight.x > 0)
            let now = HoneySlideRules.trackPoint(depth: 0.2, offset: 0, distance: second)
            let next = HoneySlideRules.trackPoint(depth: 0.2, offset: 0, distance: second + 1.0 / 60)
            // Sharper corners move the distant view faster, continuously.
            assert(now.x.isFinite && abs(next.x - now.x) < 18)
            var priorSpread = 0.0
            for depth in stride(from: 0.55, through: HoneySlideRules.playerDepth, by: 0.01) {
                let center = HoneySlideRules.ridingPoint(depth: depth, lateral: 0, distance: second)
                let left = HoneySlideRules.ridingPoint(depth: depth, lateral: -0.66, distance: second)
                let right = HoneySlideRules.ridingPoint(depth: depth, lateral: 0.66, distance: second)
                assert(left.x < center.x && right.x > center.x)
                assert(right.x - left.x > priorSpread)
                priorSpread = right.x - left.x
            }
            for depth in [0.1, 0.2, 0.4, 0.84] {
                let center = HoneySlideRules.trackPoint(depth: depth, offset: 0, distance: second)
                let edge = HoneySlideRules.trackPoint(depth: depth, offset: 1, distance: second)
                let player = HoneySlideRules.ridingPoint(depth: depth, lateral: 0.80, distance: second)
                assert(player.x - center.x < (edge.x - center.x) * 0.8)
            }
        }
    }

    private static func checkFixedWidthRails() {
        // Perspective must project the same physical width at every distance.
        // In particular, the visible foreground cannot have a bulge or pinch
        // that travels along the verges when the camera advances.
        for seed in 0..<8 {
            let course = HoneySlideCourse(seed: UInt64(seed), initialSegments: 128)
            for elapsed in stride(from: 0.0, through: 600, by: 1.3) {
                for ahead in [20.0, 80, 240, 480, 900, 1800, 4000] {
                    let depth = HoneySlideRules.depth(ahead: ahead)
                    let left = HoneySlideRules.trackPoint(depth: depth, offset: -1, distance: elapsed, course: course)
                    let right = HoneySlideRules.trackPoint(depth: depth, offset: 1, distance: elapsed, course: course)
                    let halfWidth = (right.x - left.x) / (2 * depth * HoneySlideRules.projectionScale)
                    assert(abs(halfWidth - HoneySlideRules.trackWorldHalfWidth) < 0.000001)
                    let camera = course.sample(at: HoneySlideRules.worldDistance(elapsed))
                    let vertex = course.sample(at: HoneySlideRules.worldDistance(elapsed) + ahead)
                    let expectedCenter = 800 + (vertex.x - camera.x - camera.slope * ahead)
                        * depth * HoneySlideRules.projectionScale
                    assert(abs((left.x + right.x) / 2 - expectedCenter) < 0.000001,
                           "A bend was deformed independently of its fixed world geometry")
                }
            }
            for row in 1..<20 {
                let landing = HoneySlideRules.playerAhead + Double(row) * HoneySlideRules.checkpointSpacing
                let elapsed = (landing - 300) / HoneySlideRules.forwardSpeed
                for side in [-1.0, 1.0] {
                    let points = [100.0, 200, 300, 400, 500].map {
                        HoneySlideRules.trackPoint(depth: HoneySlideRules.depth(ahead: $0),
                            offset: side, distance: elapsed, course: course)
                    }
                    let a = points.first!, b = points.last!
                    for p in points.dropFirst().dropLast() {
                        let cross = (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
                        assert(abs(cross) < 0.000001,
                               "Straight rail bulges despite unchanged world geometry")
                    }
                }
            }
        }
    }

    private static func checkAnswerLayout() {
        let contact = HoneySlideRules.answerScale(depth: HoneySlideRules.playerDepth)
        let riderWidth = min(1600 * 0.285, 900 * 0.43)
        assert((154 * contact / riderWidth) > 0.74 && (154 * contact / riderWidth) < 0.80)
        assert(HoneySlideRules.answerScale(depth: 0.1) < 0.24)
        assert(HoneySlideRules.answerScale(depth: 0.2) < 0.48)
        // Pots retain clear gaps through every bend. A distant row can go
        // around the corner; the real answer landing must remain fully visible.
        for second in stride(from: 0.0, through: 600.0, by: 0.5) {
            for depth in [0.08, 0.1, 0.2, 0.4, 0.6, HoneySlideRules.playerDepth] {
                let centers = [-0.66, 0, 0.66].map {
                    HoneySlideRules.ridingPoint(depth: depth, lateral: $0, distance: second).x
                }
                let fullWidth = 154 * HoneySlideRules.answerScale(depth: depth)
                assert(centers[1] - centers[0] > fullWidth)
                assert(centers[2] - centers[1] > fullWidth)
                if depth >= HoneySlideRules.playerDepth {
                    assert(centers[0] - fullWidth / 2 > 0)
                    assert(centers[2] + fullWidth / 2 < 1600)
                }
            }
        }
        for seed in 0..<16 {
            let course = HoneySlideCourse(seed: UInt64(seed), initialSegments: 128)
            for index in 1...90 {
                let row = HoneySlideRules.playerAhead + Double(index) * HoneySlideRules.checkpointSpacing
                // All three complete choices must be visible before the guides
                // capture a lane, and stay visible all the way to contact.
                for remaining in stride(from: 0.0, through: 300, by: 10) {
                    let elapsed = (row - HoneySlideRules.playerAhead - remaining) / HoneySlideRules.forwardSpeed
                    let depth = HoneySlideRules.depth(ahead: HoneySlideRules.playerAhead + remaining)
                    for lane in [-0.66, 0, 0.66] {
                        let bounds = HoneySlideRules.potBounds(depth: depth, lateral: lane,
                            elapsed: elapsed, billboardYScale: 1, course: course)
                        assert(bounds.minX > 0 && bounds.maxX < 1600,
                               "A sharp corner concealed an answer at the decision point")
                    }
                }
            }
        }
    }

    private static func checkCameraPassage() {
        let viewport = CGRect(x: 0, y: 0, width: 1600, height: 900)
        let engine = MemoryGame(level: MathLevel(topic: .addition, index: 1), seed: 29)
        assert(engine.start()); assert(engine.turnCardsOver()); assert(engine.beginAnswering())
        let sizes = [CGSize(width: 852, height: 393), CGSize(width: 1194, height: 834),
                     CGSize(width: 1600, height: 900), CGSize(width: 932, height: 430)]
        for selectedLane in 0..<3 {
            var ride = HoneySlideSimulation(courseSeed: 42)
            ride.synchronize(rounds: engine.visibleRounds, stage: 1, acceptingInput: true)
            let row = ride.activeCheckpoint!
            ride.steer(to: Double(selectedLane - 1) * HoneySlideRules.laneSpacing)
            while ride.crossing(roundID: row.roundID!) == nil { ride.advance(seconds: 1.0 / 120) }
            let hit = ride.crossing(roundID: row.roundID!)!
            ride.markSelected(checkpointID: row.id, index: hit.index, correct: hit.option.isCorrect)
            let options = row.options
            let contactTime = ride.elapsed
            var previousSpread = 0.0, previousY = 0.0, priorTop = Array(repeating: 0.0, count: sizes.count)
            var visibleAfterContact = false
            // Follow the SAME row through contact, over the camera and cleanup.
            while ride.checkpoints.contains(where: { $0.id == row.id }) {
                let retained = ride.checkpoints.first { $0.id == row.id }!
                assert(retained.worldPosition == row.worldPosition && retained.options == options)
                let ahead = row.worldPosition - ride.distance
                let depth = HoneySlideRules.depth(ahead: ahead)
                let center = HoneySlideRules.ridingPoint(depth: depth, lateral: 0, distance: ride.elapsed)
                let right = HoneySlideRules.ridingPoint(depth: depth, lateral: 0.66, distance: ride.elapsed)
                assert(right.x - center.x >= previousSpread && center.y >= previousY)
                if depth <= 1.3 { assert(abs(center.x - 800) < 0.000001) }
                assert(right.x - center.x > 158 * HoneySlideRules.answerScale(depth: depth))
                previousSpread = right.x - center.x; previousY = center.y
                for (index, size) in sizes.enumerated() {
                    let bounds = HoneySlideRules.potBounds(depth: depth, lateral: 0, elapsed: ride.elapsed,
                        billboardYScale: HoneySlideRules.billboardVerticalScale(viewport: size))
                    assert(bounds.minY >= priorTop[index])
                    priorTop[index] = bounds.minY
                    if ride.elapsed - contactTime >= 1 { assert(!bounds.intersects(viewport)) }
                    if ahead < 0 && bounds.intersects(viewport) { visibleAfterContact = true }
                }
                // A fixed world block cannot change size or jump endpoints at
                // a former LOD boundary (700/1800 units) or on row promotion.
                for block in 0..<HoneySlideRules.dividerSections {
                    let segment = HoneySlideRules.dividerSegment(rowPosition: retained.worldPosition, index: block)
                    assert(abs(segment.far - segment.near - 30) < 0.000001)
                    if block + 1 < HoneySlideRules.dividerSections {
                        assert(segment.near == HoneySlideRules.dividerSegment(rowPosition: row.worldPosition, index: block + 1).far)
                    }
                }
                ride.advance(seconds: 1.0 / 120)
            }
            assert(visibleAfterContact)
            let finalDepth = HoneySlideRules.depth(ahead: row.worldPosition - ride.distance)
            for size in sizes {
                for lane in [-0.66, 0, 0.66] {
                    assert(!HoneySlideRules.potBounds(depth: finalDepth, lateral: lane, elapsed: ride.elapsed,
                        billboardYScale: HoneySlideRules.billboardVerticalScale(viewport: size)).intersects(viewport))
                }
            }
        }
        // The contact scale has no discontinuity in value or velocity.
        let d = HoneySlideRules.playerDepth, epsilon = 0.00001
        let at = HoneySlideRules.answerScale(depth: d)
        let before = HoneySlideRules.answerScale(depth: d - epsilon)
        let after = HoneySlideRules.answerScale(depth: d + epsilon)
        assert(abs((at - before) / epsilon - (after - at) / epsilon) < 0.001)
        assert(HoneySlideRules.trackPoint(depth: 2, offset: 0, distance: 0).y
               > HoneySlideRules.trackPoint(depth: 1.3, offset: 0, distance: 0).y)
    }
}
