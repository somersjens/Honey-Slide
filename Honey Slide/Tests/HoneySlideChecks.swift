import Foundation
import CoreGraphics

@main struct HoneySlideChecks {
    static func main() {
        checkObstacleRacer()
        checkMovingTrainsAndEarlyItems()
        checkAdaptiveTrackWidth()
        checkRaceSessions()
        checkRaceRewardsAndResume()
        checkTrackEffects()
        checkRampClearsAnswers()
        checkRaceCameraPassage()
        checkFinishSequence()
        checkFixedQuestionSessions()
        checkSteering()
        checkGeneratedTurns()
        checkStraightTravelAndRails()
        checkProjection()
        checkFixedWidthRails()
        checkAnswerLayout()
        checkImpactLifecycle()
        checkCollectionMotion()
        checkStraightLandings()
        checkCachedProjection()
        print("PASS: obstacle racer, variable/moving answers, late reveals, real misses, track effects, future runway, forced answer channels, solid logs, whirlpools, high jumps and Honey-only rewards, fixed-question sessions, course physics and projection")
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
            ride.steer(to: row.lateralPosition(at: index, elapsed: ride.elapsed))
            while ride.crossing(roundID: row.roundID!) == nil { ride.advance(seconds: 1.0 / 120) }
            let depth = HoneySlideRules.depth(ahead: row.worldPosition - ride.distance)
            let origin = HoneySlideRules.ridingPoint(depth: depth, lateral: row.lateralPosition(at: index, elapsed: ride.elapsed), distance: ride.travelTime, course: ride.course)
            let hit = ride.crossing(roundID: row.roundID!)!
            assert(engine.select(optionID: hit.option!.id) != .ignored)
            ride.markSelected(checkpointID: row.id, index: index, correct: correct)
            let impact = ride.impacts.first!
            assert(impact.id == row.id && impact.origin == origin && impact.text == hit.option!.text)
            assert(impact.scale == HoneySlideRules.answerScale(depth: depth) * row.potSize && impact.correct == correct)
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
            assert(ride.elapsed == time && ride.impacts[0].text == hit.option!.text)
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


    private static func readyEngine() -> MemoryGame {
        let engine = MemoryGame(level: MathLevel(topic: .addition, index: 3), seed: 42)
        assert(engine.start()); assert(engine.turnCardsOver()); assert(engine.beginAnswering())
        return engine
    }

    private static func avoidLogs(_ ride: inout HoneySlideSimulation, target: Double) {
        if let log = ride.items.filter({ $0.kind == .log && $0.worldPosition - ride.distance - HoneySlideRules.playerAhead > -220 && $0.worldPosition - ride.distance - HoneySlideRules.playerAhead < 850 })
            .min(by: { $0.worldPosition < $1.worldPosition }), abs(ride.lateral - log.lateral) < 0.65 || ride.blockedLogID != nil {
            ride.steer(to: log.lateral >= 0 ? -ride.railLimit : ride.railLimit)
        } else { ride.steer(to: target) }
    }

    private static func checkObstacleRacer() {
        let engine = readyEngine()
        var counts = Set<Int>(), moments = Set<HoneyAnswerMoment>(), kinds = Set<HoneyTrackItemKind>()
        for seed in 0..<80 {
            var ride = HoneySlideSimulation(courseSeed: UInt64(seed))
            ride.synchronize(rounds: engine.visibleRounds, stage: 1, acceptingInput: true, completed: seed < 20 ? 0 : 20, streak: seed < 20 ? 0 : 8)
            assert(ride.checkpoints.count == GameConfig.preparedRoundRunway)
            for row in ride.checkpoints {
                assert((2...5).contains(row.options.count) && row.options.filter(\.isCorrect).count == 1)
                assert(Set(row.options.map { AnswerValue($0.text) }).count == row.options.count)
                assert(row.dividerBoundaries.count == (row.isMoving ? 0 : row.options.count - 1))
                counts.insert(row.options.count); moments.insert(row.moment)
            }
            kinds.formUnion(ride.items.map(\.kind))
            let rows = ride.checkpoints, items = ride.items
            ride.synchronize(rounds: engine.visibleRounds, stage: 3, acceptingInput: true, completed: 30, streak: 12)
            assert(ride.items.map(\.id) == items.map(\.id))
            for row in rows {
                let stable = ride.checkpoints.first { $0.id == row.id }!
                assert(stable.options == row.options && stable.lanePositions == row.lanePositions && stable.worldPosition == row.worldPosition)
            }
            assert(ride.checkpoints.dropFirst().allSatisfy { $0.activatedAt == nil && $0.revealedAt == nil })
            for item in items { assert(ride.items.first { $0.id == item.id }!.worldPosition == item.worldPosition) }
        }
        assert(counts == Set(2...5) && moments == Set(HoneyAnswerMoment.allCases))
        assert(kinds == Set(HoneyTrackItemKind.allCases) && kinds.count == 5)
        // Promotion preserves all visible pots, walls and props; replenishment
        // happens beyond draw distance, where objects can enter at the horizon.
        var ride = HoneySlideSimulation(courseSeed: 3)
        ride.synchronize(rounds: engine.visibleRounds, stage: 1, acceptingInput: true)
        let row = ride.activeCheckpoint!, future = Array(ride.checkpoints.dropFirst()), oldItems = ride.items
        let correct = row.options.firstIndex(where: \.isCorrect)!
        ride.steer(to: row.lateralPosition(at: correct, elapsed: ride.elapsed))
        while ride.crossing(roundID: engine.round!.id) == nil { ride.advance(seconds: 1.0 / 120) }
        let hit = ride.crossing(roundID: engine.round!.id)!
        assert(hit.isCorrect && engine.select(optionID: hit.option!.id) != .ignored)
        ride.markSelected(checkpointID: row.id, index: hit.index, correct: hit.isCorrect)
        assert(engine.finishResolving()); engine.advance(); assert(engine.turnCardsOver()); assert(engine.beginAnswering())
        ride.synchronize(rounds: engine.visibleRounds, stage: 1, acceptingInput: true, completed: 1, streak: 1)
        for old in future {
            let current = ride.checkpoints.first { $0.id == old.id }!
            assert(current.options == old.options && current.worldPosition == old.worldPosition)
        }
        for old in oldItems { assert(ride.items.first { $0.id == old.id }?.worldPosition == old.worldPosition) }
        let previousIDs = Set(oldItems.map(\.id))
        assert(ride.items.filter { !previousIDs.contains($0.id) }.allSatisfy { $0.worldPosition - ride.distance > HoneySlideRules.drawDistance })
        print("Runway: 80 seeds, all answer moments/counts, persistent future pots and five prop types")
    }

    private static func checkMovingTrainsAndEarlyItems() {
        let engine = readyEngine()
        var movingKinds = Set<HoneyAnswerMoment>()
        for seed in 0..<80 {
            var ride = HoneySlideSimulation(courseSeed: UInt64(seed))
            ride.synchronize(rounds: engine.visibleRounds, stage: 1, acceptingInput: true, completed: 20, streak: 8)
            for row in ride.checkpoints where row.isMoving {
                assert(row.options.count == 3 && row.trackAnswerCount == 4 && row.dividerBoundaries.isEmpty)
                movingKinds.insert(row.moment)
                guard row.activatedAt != nil else {
                    assert(row.options.indices.allSatisfy { row.lateralPosition(at: $0, elapsed: 100) == row.lanePositions[$0] })
                    continue
                }
                let width = HoneySlideRules.trackHalfWidth(depth: HoneySlideRules.playerDepth,
                    widthScale: HoneyTrackWidth.scale(answerCount: 4))
                var furthest = 0.0, reversals = 0, previousDelta = 0.0, previousMiddle = 0.0
                for time in stride(from: 0.0, through: 12, by: 0.02) {
                    let positions = row.options.indices.map { row.lateralPosition(at: $0, elapsed: time) }.sorted()
                    let middle = positions.reduce(0, +) / 3
                    furthest = max(furthest, abs(middle))
                    let delta = middle - previousMiddle
                    if abs(delta) > 1e-6 && delta * previousDelta < 0 { reversals += 1 }
                    if abs(delta) > 1e-6 { previousDelta = delta }
                    previousMiddle = middle
                    for lane in positions {
                        let bounds = HoneySlideRules.potBounds(depth: HoneySlideRules.playerDepth, lateral: lane,
                            elapsed: 0, billboardYScale: 1)
                        assert(bounds.minX >= 800 - width && bounds.maxX <= 800 + width)
                    }
                    if time > 3.1 {
                        assert(abs(positions[1] - positions[0] - HoneySlideRules.laneSpacing) < 1e-6)
                        assert(abs(positions[2] - positions[1] - HoneySlideRules.laneSpacing) < 1e-6)
                    }
                }
                assert(furthest > row.motionLimit - 0.01 && reversals >= 3)
            }
            for item in ride.items {
                let bank = HoneySlideRules.trackHalfWidth(depth: HoneySlideRules.playerDepth,
                    widthScale: ride.widthProfile.scale(at: item.worldPosition)) / HoneySlideRules.ridingHalfWidth(depth: HoneySlideRules.playerDepth)
                assert(item.lateral + item.kind.artworkLateralBounds.lowerBound > -bank)
                assert(item.lateral + item.kind.artworkLateralBounds.upperBound < bank)
                assert((2...3).contains(ride.items.filter { $0.checkpointID == item.checkpointID }.count))
            }
        }
        assert(movingKinds == Set([.moving, .swapping]))
        var fresh = HoneySlideSimulation(courseSeed: 4)
        fresh.synchronize(rounds: engine.visibleRounds, stage: 1, acceptingInput: true)
        assert(fresh.items.filter { $0.checkpointID == fresh.checkpoints[0].id }.isEmpty)
        for row in fresh.checkpoints.dropFirst() {
            assert(fresh.items.filter { $0.checkpointID == row.id }.count >= 2)
        }
        for _ in 0..<5 {
            assert(engine.select(optionID: engine.round!.correctOption!.id) != .ignored)
            assert(engine.finishResolving()); engine.advance(); assert(engine.turnCardsOver()); assert(engine.beginAnswering())
        }
        let saved = engine.pausedSession()!
        let resumed = MemoryGame(level: engine.level, seed: 9)
        resumed.prepare(startingAt: saved.roundNumber)
        var reopened = HoneySlideSimulation(courseSeed: 7)
        reopened.synchronize(rounds: resumed.visibleRounds, stage: 1, acceptingInput: false)
        let row = reopened.activeCheckpoint!, initialItems = reopened.items
        assert(initialItems.filter { $0.checkpointID == row.id }.count >= 2)
        assert(initialItems.filter { $0.checkpointID == row.id }.allSatisfy { $0.worldPosition < HoneySlideRules.drawDistance })
        assert(resumed.resume(from: saved)); assert(resumed.turnCardsOver()); assert(resumed.beginAnswering())
        reopened.synchronize(rounds: resumed.visibleRounds, stage: 1, acceptingInput: true,
            completed: resumed.completedQuestions, streak: resumed.correctStreak)
        assert(reopened.items.map(\.id) == initialItems.map(\.id))
        print("Layout: three bouncing pots on a four-option road without walls; props from question two, visible on resume, all inside banks")
    }

    private static func checkAdaptiveTrackWidth() {
        assert(HoneyTrackWidth.scale(answerCount: 3) == 1)
        assert(HoneyTrackWidth.scale(answerCount: 4) > 1 && HoneyTrackWidth.scale(answerCount: 5) > HoneyTrackWidth.scale(answerCount: 4))
        var profile = HoneyTrackWidth()
        let first = HoneySlideRules.firstCheckpointPosition, second = first + HoneySlideRules.checkpointSpacing
        profile.append(answerCount: 2, rowPosition: first); profile.append(answerCount: 5, rowPosition: second)
        assert(profile.scale(at: first) == 0.8 && profile.scale(at: second) == 1.64)
        let course = HoneySlideCourse(seed: 42)
        for world in stride(from: 0.0, through: second + 2000, by: 131) {
            let time = world / HoneySlideRules.forwardSpeed
            let zoom = HoneySlideRules.cameraZoom(widthScale: profile.scale(at: world + HoneySlideRules.playerAhead))
            let projection = HoneySlideProjection(elapsed: time, course: course, widthProfile: profile, cameraZoom: zoom, cameraOffset: 40)
            for depth in [0.04, 0.1, 0.4, 0.84, 1.3, 2] {
                let actual = projection.point(depth: depth, offset: 1)
                let exact = HoneySlideRules.trackPoint(depth: depth, offset: 1, distance: time, course: course,
                    widthProfile: profile, cameraZoom: zoom, cameraOffset: 40)
                assert(abs(actual.x - exact.x) < 0.5 && abs(actual.y - exact.y) < 0.5)
                guard depth <= 1.3 else { continue }
                for lateral in [-0.4, 0, 0.4] {
                    let touch = HoneySlideRules.ridingPoint(depth: depth, lateral: lateral, distance: time, course: course, cameraZoom: zoom, cameraOffset: 40)
                    let target = HoneySlideRules.steeringTarget(at: touch, elapsed: time, course: course, widthProfile: profile, cameraZoom: zoom, cameraOffset: 40)!
                    assert(abs(target - lateral) < 1e-6)
                }
            }
        }
        let engine = readyEngine()
        var counts = Set<Int>()
        for seed in 0..<40 {
            for size in [CGSize(width: 852, height: 393), CGSize(width: 1194, height: 834)] {
                var ride = HoneySlideSimulation(courseSeed: UInt64(seed)); ride.configureViewport(size)
                ride.synchronize(rounds: engine.visibleRounds, stage: 1, acceptingInput: true, completed: 20, streak: 8)
                let row = ride.activeCheckpoint!
                counts.insert(row.options.count)
                assert(row.potSize == 1)
                for index in row.options.indices {
                    let bounds = HoneySlideRules.potBounds(depth: HoneySlideRules.playerDepth, lateral: row.lanePositions[index], elapsed: 0,
                        billboardYScale: HoneySlideRules.billboardVerticalScale(viewport: size), cameraZoom: ride.cameraZoom)
                    assert(bounds.minX > 0 && bounds.maxX < 1600)
                }
            }
        }
        assert(counts == Set(2...5))
        print("Width: 4/5 answers exceed the original width; camera fits full-size pots and touch inversion")
    }

    private static func checkRaceRewardsAndResume() {
        let engine = readyEngine()
        for number in 1...7 {
            let correct = number != 5
            assert(engine.select(optionID: engine.round!.options.first { $0.isCorrect == correct }!.id) != .ignored)
            assert(engine.cards == engine.result.correctAnswers)
            assert(engine.correctStreak == (number < 5 ? number : number - 5))
            assert(engine.finishResolving()); engine.advance(); assert(engine.turnCardsOver()); assert(engine.beginAnswering())
        }
        let saved = engine.pausedSession()!
        let data = try! JSONEncoder().encode(saved)
        var object = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        assert(object["racePoints"] == nil && object["bestRaceCombo"] == nil)
        object["racePoints"] = 9000; object["bestRaceCombo"] = 4
        let oldData = try! JSONSerialization.data(withJSONObject: object)
        let old = try! JSONDecoder().decode(PausedSession.self, from: oldData)
        let resumed = MemoryGame(level: engine.level, seed: 1)
        assert(resumed.resume(from: old) && resumed.cards == 6 && resumed.correctStreak == 2)
    }

    private static func checkTrackEffects() {
        let engine = readyEngine()
        for size in [CGSize(width: 852, height: 393), CGSize(width: 1194, height: 834)] {
            var stopped: HoneySlideSimulation?
            var logID = -1, logLane = 0.0
            for seed in 0..<30 where stopped == nil {
                var ride = HoneySlideSimulation(courseSeed: UInt64(seed)); ride.configureViewport(size)
                ride.synchronize(rounds: engine.visibleRounds, stage: 1, acceptingInput: true, completed: 20, streak: 8)
                guard let log = ride.items.filter({ $0.checkpointID == 0 && $0.kind == .log }).min(by: { $0.worldPosition < $1.worldPosition }) else { continue }
                ride.steer(to: log.lateral)
                for _ in 0..<2000 {
                    ride.advance(seconds: 1.0 / 120)
                    if ride.blockedLogID == log.id { stopped = ride; logID = log.id; logLane = log.lateral; break }
                }
            }
            assert(stopped != nil)
            var ride = stopped!
            let distance = ride.distance, time = ride.elapsed
            ride.steer(to: logLane); ride.advance(seconds: 2)
            assert(ride.distance == distance && ride.elapsed > time && ride.blockedLogID == logID && ride.speed == 0)
            assert(ride.items.first { $0.id == logID } != nil)
            let log = ride.items.first { $0.id == logID }!
            let depth = HoneySlideRules.depth(ahead: log.worldPosition - ride.distance)
            let scale = depth / HoneySlideRules.playerDepth * ride.cameraZoom
            let position = HoneySlideRules.ridingPoint(depth: depth, lateral: log.lateral,
                distance: ride.travelTime, course: ride.course, cameraZoom: ride.cameraZoom)
            let paintedBottom = position.y + HoneyLogGeometry.maxY * scale * HoneySlideRules.billboardVerticalScale(viewport: size)
            assert(abs(paintedBottom - ride.logFootprint.minY) < 9, "Stopped ahead of the visible tube nose")
            assert(ride.logFootprint.minY > ride.tubeFootprint.minY + 35, "Log collision still includes the empty space around the bear")
            let origin = HoneySlideRules.ridingPoint(depth: HoneySlideRules.playerDepth, lateral: 0,
                distance: ride.travelTime, course: ride.course, cameraZoom: ride.cameraZoom).x
            let width = HoneySlideRules.ridingHalfWidth(depth: HoneySlideRules.playerDepth) * ride.cameraZoom
            let edge = position.x + (logLane >= 0 ? HoneyLogGeometry.backCenter - HoneyLogGeometry.backRadius
                : HoneyLogGeometry.frontCenter + HoneyLogGeometry.frontRadius) * scale
            let side = logLane >= 0 ? -1.0 : 1.0
            // Just four logical pixels beside the visible bark, rather than
            // steering all the way to the opposite rail to release the stop.
            ride.steer(to: (edge - origin - ride.logFootprint.center.x + side * (sqrt(ride.logFootprint.xx) + 4)) / width)
            var escaped = false
            for _ in 0..<240 {
                ride.advance(seconds: 1.0 / 120)
                if ride.distance > distance + 1 { escaped = true; break }
            }
            assert(escaped && ride.blockedLogID == nil, "Invisible log margin prevented steering past the bark")
        }
        for kind in [HoneyTrackItemKind.whirlpool, .ramp, .boost] {
            var contactRide: HoneySlideSimulation?
            for seed in 0..<100 where contactRide == nil {
                var ride = HoneySlideSimulation(courseSeed: UInt64(seed))
                ride.synchronize(rounds: engine.visibleRounds, stage: 1, acceptingInput: true, completed: 8)
                guard let item = ride.items.first(where: { $0.checkpointID == 0 && $0.kind == kind }) else { continue }
                for _ in 0..<2000 {
                    avoidLogs(&ride, target: item.lateral)
                    ride.advance(seconds: 1.0 / 120)
                    if ride.items.first(where: { $0.id == item.id })?.contactedAt != nil { contactRide = ride; break }
                    if ride.distance + HoneySlideRules.playerAhead > item.worldPosition + 100 { break }
                }
            }
            assert(contactRide != nil, "No contact with \(kind)")
            var ride = contactRide!
            if kind == .whirlpool {
                assert(abs(ride.slowUntil - ride.elapsed - 2) < 0.02)
                let timer = ride.slowUntil, frozen = ride.distance
                ride.advance(seconds: 0); assert(ride.distance == frozen && ride.slowUntil == timer)
                ride.advance(seconds: 1.9); assert(ride.elapsed < timer)
                ride.advance(seconds: 0.11); assert(ride.elapsed > timer && ride.slowUntil == timer)
            } else if kind == .ramp {
                let launchTime = ride.elapsed, jump = ride.jump!
                while ride.distance + HoneySlideRules.playerAhead < jump.peakPosition { ride.advance(seconds: 1.0 / 240) }
                assert(ride.jumpHeight > 0.99 && ride.isAirborne)
                assert(ride.jumpHeight * 393 * HoneySlideRules.jumpLift > 130)
                while ride.distance + HoneySlideRules.playerAhead < jump.landingPosition + 5 { ride.advance(seconds: 1.0 / 240) }
                assert(!ride.isAirborne)
                assert(ride.elapsed - launchTime < 2)
            } else {
                assert(abs(ride.boostUntil - ride.elapsed - 3) < 0.02)
                ride.advance(seconds: 3.01); assert(!ride.isBoosted)
            }
        }
        print("Effects: visible hull contact and close steering escape, two-second whirlpool, short distance-based jumps")
    }

    private static func checkRampClearsAnswers() {
        let engine = readyEngine()
        for count in 2...5 {
            for size in [CGSize(width: 852, height: 393), CGSize(width: 1194, height: 834)] {
                var layout: HoneySlideSimulation?
                for seed in 0..<450 where layout == nil {
                    var candidate = HoneySlideSimulation(courseSeed: UInt64(seed)); candidate.configureViewport(size)
                    candidate.synchronize(rounds: engine.visibleRounds, stage: 1, acceptingInput: true, completed: 20, streak: 8)
                    if candidate.activeCheckpoint?.options.count == count,
                       candidate.items.contains(where: { $0.checkpointID == 0 && $0.kind == .ramp }) { layout = candidate }
                }
                assert(layout != nil)
                var ride = layout!
                let ramp = ride.items.first { $0.checkpointID == 0 && $0.kind == .ramp }!
                assert(abs(ride.activeCheckpoint!.worldPosition - ramp.worldPosition - HoneySlideRules.rampLead) < 1e-9)
                assert(ride.activeCheckpoint!.dividerBoundaries.contains { abs($0 - ramp.lateral) < 1e-9 })
                var frames = 0
                while ride.crossing(roundID: engine.round!.id) == nil {
                    if !ride.isAirborne { avoidLogs(&ride, target: ramp.lateral) }
                    ride.advance(seconds: 1.0 / 120)
                    frames += 1; assert(frames < 3000)
                }
                let row = ride.activeCheckpoint!
                assert(ride.crossing(roundID: engine.round!.id)!.index == nil && ride.isAirborne)
                let tubeBottom = ride.tubeFootprint.maxY - ride.jumpHeight * 900 * HoneySlideRules.jumpLift
                let top = row.options.indices.map {
                    HoneySlideRules.potBounds(depth: HoneySlideRules.playerDepth,
                        lateral: row.lateralPosition(at: $0, elapsed: ride.elapsed), elapsed: ride.travelTime,
                        billboardYScale: HoneySlideRules.billboardVerticalScale(viewport: size),
                        course: ride.course, cameraZoom: ride.cameraZoom).minY
                }.min()!
                assert(tubeBottom < top - 15, "The ramp did not lift the whole tube over the answer pots")
                let originalHeight = HoneyTubeGeometry.spriteWidth(in: size) * HoneyTubeGeometry.imageAspect
                let spriteHeight = originalHeight * ride.cameraZoom
                let bearTop = size.height * 0.735 + (originalHeight - spriteHeight) * 0.212 - spriteHeight / 2
                    - ride.jumpHeight * size.height * HoneySlideRules.jumpLift + ride.jumpCameraOffset * size.height / 900
                let hudScale = min(size.width / 1600, size.height / 900)
                assert(bearTop >= 120 * hudScale + max(10, 32 * hudScale) + 8, "High jump hid the bear behind the HUD")
                let crossingTime = ride.elapsed
                while ride.distance + HoneySlideRules.playerAhead < row.worldPosition + HoneySlideRules.jumpLandingTail + 5 {
                    ride.advance(seconds: 1.0 / 240)
                }
                assert(!ride.isAirborne && ride.elapsed - crossingTime < 0.65, "Ramp still flies too far beyond the answers")
            }
        }
        print("Ramp: whole tube clears the answer row for 2–5 pots on phone/tablet")
    }

    private static func checkRaceCameraPassage() {
        let engine = readyEngine()
        var counts = Set<Int>()
        for count in 2...5 {
            for size in [CGSize(width: 852, height: 393), CGSize(width: 1194, height: 834)] {
                var layout: HoneySlideSimulation?
                for seed in 0..<100 where layout == nil {
                    var candidate = HoneySlideSimulation(courseSeed: UInt64(seed)); candidate.configureViewport(size)
                    candidate.synchronize(rounds: engine.visibleRounds, stage: 1, acceptingInput: true,
                        completed: count <= 3 ? 0 : 20, streak: count <= 3 ? 0 : 8)
                    if candidate.activeCheckpoint?.options.count == count, candidate.activeCheckpoint?.isMoving == false,
                       !candidate.items.contains(where: { $0.checkpointID == 0 && $0.kind == .ramp }) {
                        layout = candidate
                    }
                }
                assert(layout != nil)
                for entry in 0..<count {
                    var ride = layout!
                    let row = ride.activeCheckpoint!
                    counts.insert(row.options.count)
                    ride.steer(to: row.lanePositions[entry])
                    var frames = 0
                    while ride.activeCheckpoint!.guidedLane == nil {
                        avoidLogs(&ride, target: row.lanePositions[entry]); ride.advance(seconds: 1.0 / 120)
                        frames += 1; assert(frames < 3000)
                    }
                    let lane = ride.activeCheckpoint!.guidedLane!
                    // Request a different channel after the tube's nose enters.
                    ride.steer(to: lane < count / 2 ? ride.railLimit : -ride.railLimit)
                    while ride.crossing(roundID: engine.round!.id) == nil {
                        ride.advance(seconds: 1.0 / 120)
                        frames += 1; assert(frames < 4000)
                        assert(ride.activeCheckpoint!.guidedLane == lane)
                    }
                    let hit = ride.crossing(roundID: engine.round!.id)!
                    assert(hit.index != nil && row.slot(for: hit.index!) == lane, "Late steering crossed a divider")
                    ride.markSelected(checkpointID: row.id, index: hit.index, correct: hit.isCorrect)
                    ride.advance(seconds: 0.05)
                    assert(ride.checkpoints.first { $0.id == row.id }!.guidedLane == lane)
                    // Check release just past the tail, before the next row's
                    // early obstacle can add knockback to the steering result.
                    while ride.distance + HoneySlideRules.playerAhead < row.worldPosition + HoneySlideRules.dividerTail + 180 {
                        ride.advance(seconds: 1.0 / 120)
                    }
                    assert(row.dividerBoundaries.allSatisfy {
                        HoneyDividerContact.forbiddenLateral(rowPosition: row.worldPosition, boundary: $0,
                            distance: ride.distance, footprint: ride.tubeFootprint, course: ride.course,
                            cameraZoom: ride.cameraZoom) == nil
                    })
                    ride.steer(to: 0); ride.advance(seconds: 0.8)
                    assert(abs(ride.lateral) < 0.03)
                }
            }
        }
        assert(counts == Set(2...5))
        print("Dividers: every channel for 2–5 answers on phone/tablet; late steering and answered tails remain solid")
        for size in [CGSize(width: 852, height: 393), CGSize(width: 1194, height: 834)] {
            var ride = HoneySlideSimulation(courseSeed: 0); ride.configureViewport(size)
            ride.synchronize(rounds: engine.visibleRounds, stage: 1, acceptingInput: true)
            let row = ride.activeCheckpoint!
            ride.steer(to: row.lanePositions[0])
            while row.worldPosition - ride.distance - HoneySlideRules.playerAhead > 450 {
                ride.advance(seconds: 1.0 / 120)
            }
            assert(ride.activeCheckpoint!.guidedLane == nil, "Divider committed the answer too early")
            ride.steer(to: row.lanePositions[1])
            while ride.crossing(roundID: engine.round!.id) == nil { ride.advance(seconds: 1.0 / 120) }
            assert(ride.crossing(roundID: engine.round!.id)!.index == 1, "Late lane switch was blocked before the shorter divider")
        }
        // Slow frames cannot tunnel through a log or a divider.
        var slow = HoneySlideSimulation(courseSeed: 12)
        slow.synchronize(rounds: engine.visibleRounds, stage: 1, acceptingInput: true, completed: 20, streak: 8)
        slow.steer(to: 0); var fast = slow
        slow.advance(seconds: 10)
        for _ in 0..<1200 { fast.advance(seconds: 1.0 / 120) }
        assert(abs(slow.distance - fast.distance) < 1e-5 && abs(slow.lateral - fast.lateral) < 1e-5)
        assert(slow.blockedLogID == fast.blockedLogID)
    }

    private static func checkRaceSessions() {
        var attempts = 0
        for topic in [MathTopic.addition, .subtraction, .tables, .fractions, .percentages, .mixed] {
            let engine = MemoryGame(level: MathLevel(topic: topic, index: 3), seed: 33)
            assert(engine.start()); assert(engine.turnCardsOver()); assert(engine.beginAnswering())
            var ride = HoneySlideSimulation(courseSeed: 17)
            ride.synchronize(rounds: engine.visibleRounds, stage: 1, acceptingInput: true)
            while engine.state != .gameOver {
                let round = engine.round!, row = ride.activeCheckpoint!
                let right = engine.completedQuestions % 4 != 3
                let index = row.options.firstIndex { $0.isCorrect == right }!
                var frames = 0
                while ride.crossing(roundID: round.id) == nil {
                    avoidLogs(&ride, target: row.lateralPosition(at: index, elapsed: ride.elapsed))
                    ride.advance(seconds: 1.0 / 60)
                    frames += 1; assert(frames < 2500, "Autopilot stranded behind a log")
                }
                let hit = ride.crossing(roundID: round.id)!
                let verdict = hit.option.map { engine.select(optionID: $0.id) } ?? engine.missAnswer()
                assert(verdict != .ignored)
                ride.markSelected(checkpointID: hit.checkpointID, index: hit.index, correct: hit.isCorrect)
                assert(engine.cards == engine.result.correctAnswers)
                assert(engine.finishResolving()); engine.advance(); attempts += 1
                if engine.state != .gameOver {
                    assert(engine.turnCardsOver()); assert(engine.beginAnswering())
                    ride.synchronize(rounds: engine.visibleRounds, stage: 1, acceptingInput: true,
                        completed: engine.completedQuestions, streak: engine.correctStreak, mistakes: engine.mistakeStreak)
                }
            }
            ride.advance(seconds: 3); assert(ride.visualOutcomeSettled)
        }
        assert(attempts == 250)
        print("Sessions: 250 questions over six math topics, one Honey per correct answer, no secondary score")
    }

    private static func checkFinishSequence() {
        for (count, airborne) in [(2, false), (3, false), (4, false), (5, false), (4, true)] {
            for size in [CGSize(width: 852, height: 393), CGSize(width: 1194, height: 834)] {
                let engine = readyEngine()
                while engine.completedQuestions < engine.maximumRounds - 1 {
                    assert(engine.select(optionID: engine.round!.correctOption!.id) != .ignored)
                    assert(engine.finishResolving()); engine.advance()
                    assert(engine.turnCardsOver()); assert(engine.beginAnswering())
                }
                var layout: HoneySlideSimulation?
                // A four-pot ramp row is rarer now: moving rows always have
                // three pots and only stationary rows can contain a ramp.
                for seed in 0..<1000 where layout == nil {
                    var candidate = HoneySlideSimulation(courseSeed: UInt64(seed)); candidate.configureViewport(size)
                    candidate.synchronize(rounds: engine.visibleRounds, stage: 1, acceptingInput: true,
                        completed: engine.completedQuestions, streak: 8, totalQuestions: engine.maximumRounds)
                    let hasRamp = candidate.items.contains(where: { $0.kind == .ramp && $0.id != candidate.finish?.rampID })
                    if candidate.activeCheckpoint?.options.count == count, candidate.activeCheckpoint?.isMoving == false, hasRamp == airborne { layout = candidate }
                }
                assert(layout != nil)
                var ride = layout!
                let finish = ride.finish!, row = ride.activeCheckpoint!
                assert(!ride.hasFinishStarted && finish.rampPosition < HoneySlideRules.drawDistance)
                let plannedItems = ride.items.count, plannedWidths = ride.widthProfile.transitions.count
                ride.synchronize(rounds: engine.visibleRounds, stage: 1, acceptingInput: true,
                    completed: engine.completedQuestions, streak: 8, totalQuestions: engine.maximumRounds)
                assert(ride.items.count == plannedItems && ride.widthProfile.transitions.count == plannedWidths)
                var width = ride.widthProfile.scale(at: row.worldPosition)
                for position in stride(from: row.worldPosition + HoneySlideRules.dividerTail,
                    through: row.worldPosition + HoneySlideRules.finishFunnelLength + 50, by: 25) {
                    let next = ride.widthProfile.scale(at: position)
                    assert(next <= width + 1e-9 && next >= HoneySlideRules.finishWidth)
                    width = next
                }
                assert(abs(width - HoneySlideRules.finishWidth) < 1e-9)
                let anchor = ride.course.sample(at: row.worldPosition)
                let end = ride.course.sample(at: finish.roadEnd)
                assert(end.turnRate == 0 && abs(end.x - anchor.x - anchor.slope * (finish.roadEnd - row.worldPosition)) < 1e-6)
                let target = airborne ? ride.items.first { $0.kind == .ramp && $0.id != finish.rampID }!.lateral
                    : row.lanePositions[count.isMultiple(of: 2) ? count - 1 : 0]
                var frames = 0
                while ride.crossing(roundID: engine.round!.id) == nil {
                    avoidLogs(&ride, target: target); ride.advance(seconds: 1.0 / 120)
                    frames += 1; assert(frames < 3000)
                }
                assert(!ride.hasFinishStarted && !ride.hasFinishLaunched)
                let hit = ride.crossing(roundID: engine.round!.id)!
                assert(airborne ? hit.option == nil : hit.option != nil)
                assert((hit.option.map { engine.select(optionID: $0.id) } ?? engine.missAnswer()) != .ignored)
                assert(engine.finishResolving()); engine.advance(); assert(engine.state == .gameOver)
                let finalHoney = engine.cards
                ride.markSelected(checkpointID: hit.checkpointID, index: hit.index, correct: hit.isCorrect)
                assert(ride.hasFinishStarted && !ride.isFinishComplete)
                let started = ride
                ride.steer(to: ride.railLimit); ride.press(-1)
                assert(ride.targetLateral == 0 && ride.heldDirection == 0)
                while !ride.hasFinishLaunched {
                    ride.advance(seconds: 1.0 / 120)
                    assert(ride.railLimit > 0 && abs(ride.lateral) <= ride.railLimit + 1e-5)
                    frames += 1; assert(frames < 4500)
                }
                assert(abs(ride.lateral) < 0.001 && !ride.isFinishComplete)
                assert(ride.elapsed - ride.finish!.startedAt! < 1.05, "Finish launch still has a long runout")
                if airborne { assert(ride.jumpHeight == 0, "Normal ramp had not landed before the finish ramp") }
                assert(abs(ride.widthProfile.scale(at: ride.distance + HoneySlideRules.playerAhead) - HoneySlideRules.finishWidth) < 1e-9)
                let launchDistance = ride.distance, launchTime = ride.elapsed
                ride.advance(seconds: 0); assert(ride.distance == launchDistance && ride.elapsed == launchTime)
                ride.advance(seconds: HoneySlideRules.finishFlightDuration * 0.55)
                let spriteHeight = HoneyTubeGeometry.spriteWidth(in: size) * HoneyTubeGeometry.imageAspect * ride.cameraZoom
                assert(size.height * 0.735 + spriteHeight / 2 - ride.riderLift * size.height < 0,
                    "Result could cover a bear still in view")
                assert(!ride.isFinishComplete && ride.distance == launchDistance)
                ride.advance(seconds: HoneySlideRules.finishFlightDuration * 0.45 + 0.01)
                assert(ride.isFinishComplete && ride.visualOutcomeSettled && engine.cards == finalHoney && engine.completedQuestions == engine.maximumRounds)
                let settledTime = ride.elapsed
                ride.advance(seconds: 10); assert(ride.elapsed == settledTime && ride.distance == launchDistance)
                var stalled = started
                stalled.advance(seconds: 10)
                assert(stalled.isFinishComplete && abs(stalled.distance - launchDistance) < 1e-5)
                assert(HoneySlideSimulation().finish == nil)
            }
        }
        print("Finish: visible funnel and terminal ramp, 2–5 final answers, centered exit, offscreen launch before results, pause and long frames")
    }
}
