import Foundation
import CoreGraphics

@main struct HoneySlideChecks {
    static func main() {
        checkContinuousCheckpoints()
        checkFixedQuestionSessions()
        checkSteering()
        checkDividerChannels()
        checkProjection()
        checkAnswerLayout()
        checkCameraPassage()
        checkImpactLifecycle()
        checkCollectionMotion()
        checkStraightLandings()
        checkCachedProjection()
        print("PASS: continuous course and camera passage, straight checkpoint landings with stable dividers, contact-owned pot impacts and delayed Honey collection, collision-timed shutters, fixed-question sessions and ±1 scoring, constant travel, tap steering, ten-minute projection and undistorted pot proportions")
    }

    private static func checkCollectionMotion() {
        // All lanes and phone/tablet proportions: the first pose must match
        // the contact pot, the last must match the HUD, and neither can snap.
        for viewport in [CGSize(width: 852, height: 393), CGSize(width: 1194, height: 834)] {
            for lane in -1...1 {
                let hudScale = min(viewport.width / 1600, viewport.height / 900)
                let ground = HoneySlideRules.ridingPoint(depth: HoneySlideRules.playerDepth,
                    lateral: Double(lane) * HoneySlideRules.laneSpacing, distance: 0)
                let potScale = HoneySlideRules.answerScale(depth: HoneySlideRules.playerDepth)
                let origin = CGPoint(x: ground.x / 1600 * viewport.width,
                    y: ground.y / 900 * viewport.height - 61 * potScale * viewport.width / 1600)
                let safeInset = viewport.width == 852 ? 59.0 : 0
                let target = CGPoint(x: viewport.width - safeInset - (58 + 127.5) * hudScale, y: 92 * hudScale)
                let initialScale = potScale * viewport.width / 1600 / 2
                let finalScale = 71 * hudScale / 308
                let signWidth = min(viewport.width * 0.5, 760 * hudScale)
                let sign = CGRect(x: (viewport.width - signWidth) / 2, y: 32 * hudScale,
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
            let projection = HoneySlideProjection(elapsed: elapsed)
            for index in 0..<1300 {
                let depth = (Double(index) + 0.314) / 1000
                for offset in [-4.0, -1, 0, 1, 4] {
                    let actual = projection.point(depth: depth, offset: offset)
                    let exact = HoneySlideRules.trackPoint(depth: depth, offset: offset, distance: elapsed)
                    let error = max(abs(actual.x - exact.x), abs(actual.y - exact.y))
                    maximumError = max(maximumError, error)
                    assert(error < 0.5, "Projection cache changed a visible position: \(error)")
                }
            }
            for depth in [0.0, 1.3, 1.30001, 2, 12] {
                let actual = projection.point(depth: depth, offset: 1)
                let exact = HoneySlideRules.trackPoint(depth: depth, offset: 1, distance: elapsed)
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
            var ride = HoneySlideSimulation()
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
                ride.targetLateral = Double(correctIndex - 1) * 0.66
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
            ride.targetLateral = Double(wrongIndex - 1) * 0.66
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
            assert(engine.cards == score - 1)
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
            var ride = HoneySlideSimulation()
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
                        // All wrong, all correct, and a mix including a zero-score floor.
                        let right = pattern == 1 || (pattern == 2 && n > 1 && n % 3 != 0)
                        let option = engine.round!.options.first { $0.isCorrect == right }!
                        assert(engine.select(optionID: option.id, usesBonusFish: true, wrongAnswerCostHalves: 6) != .ignored)
                        expectedScore = right ? expectedScore + 1 : max(0, expectedScore - 1)
                        assert(engine.cards == expectedScore && engine.result.cardsEarned == expectedScore)
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
        var ride = HoneySlideSimulation()
        ride.press(1); ride.release()
        for _ in 0..<60 { ride.advance(seconds: 1.0 / 120) }
        assert(ride.lateral > 0.57 && ride.lateral < 0.72)
        ride.press(-1); ride.release()
        for _ in 0..<60 { ride.advance(seconds: 1.0 / 120) }
        assert(abs(ride.lateral) < 0.1)
        ride.press(-1)
        for _ in 0..<120 { ride.advance(seconds: 1.0 / 120) }
        assert(ride.lateral < -0.70 && ride.lateral >= -0.80)
        ride.release()
        ride.targetLateral = 0.66
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
        var slow = HoneySlideSimulation(), fast = HoneySlideSimulation()
        slow.advance(seconds: 0.25)
        for _ in 0..<30 { fast.advance(seconds: 1.0 / 120) }
        assert(abs(slow.distance - fast.distance) < 0.000001)
    }

    private static func checkImpactLifecycle() {
        for correct in [true, false] {
            let engine = MemoryGame(level: MathLevel(topic: .addition, index: 1), seed: 71)
            assert(engine.start()); assert(engine.turnCardsOver()); assert(engine.beginAnswering())
            var ride = HoneySlideSimulation()
            ride.synchronize(rounds: engine.visibleRounds, stage: 1, acceptingInput: true)
            let row = ride.activeCheckpoint!
            let index = row.options.firstIndex { $0.isCorrect == correct }!
            ride.targetLateral = Double(index - 1) * HoneySlideRules.laneSpacing
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
            assert(ride.penaltyProgress == (correct ? nil : 0))
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
            if !correct {
                assert(ride.penaltyProgress != nil) // remains legible after the splash
                assert(engine.cards == 0) // no debt at a zero score
            }
            ride.advance(seconds: 2.1)
            assert(ride.impacts.isEmpty && ride.penaltyProgress == nil)
            assert(ride.visualOutcomeSettled && ride.lastContact?.id == row.id)
            // Frame stalls can skip drawing an effect's last frame; they must
            // never strand the final question behind an unfinished result.
            ride.advance(seconds: 4)
            assert(ride.visualOutcomeSettled)
        }
    }

    private static func checkStraightLandings() {
        for index in 0..<100 {
            let row = HoneySlideRules.firstCheckpointPosition + Double(index) * HoneySlideRules.checkpointSpacing
            let anchor = HoneySlideRules.course(row)
            for dz in stride(from: -349.0, through: 349, by: 13) {
                assert(abs(HoneySlideRules.course(row + dz) - anchor) < 0.000001)
                assert(HoneySlideRules.courseSlope(row + dz) == 0)
            }
            for camera in stride(from: row - HoneySlideRules.playerAhead - HoneySlideRules.dividerLead,
                                 through: row + 300, by: 17) {
                for block in 0..<HoneySlideRules.dividerSections {
                    let segment = HoneySlideRules.dividerSegment(rowPosition: row, index: block)
                    for z in [segment.far, segment.near] where z - camera > HoneySlideRules.nearClipAhead {
                        let depth = HoneySlideRules.depth(ahead: z - camera)
                        let center = HoneySlideRules.trackPoint(depth: depth, offset: 0,
                            distance: camera / HoneySlideRules.forwardSpeed)
                        assert(abs(center.x - 800) < 0.000001)
                    }
                }
            }
            // Smooth joins keep banks/scenery from jumping on entering a bend.
            for edge in [row - 350, row + 350] {
                assert(abs(HoneySlideRules.course(edge + 0.1) - HoneySlideRules.course(edge - 0.1)) < 0.001)
                assert(abs(HoneySlideRules.courseSlope(edge + 0.1) - HoneySlideRules.courseSlope(edge - 0.1)) < 0.001)
            }
        }
    }

    private static func checkDividerChannels() {
        let engine = MemoryGame(level: MathLevel(topic: .addition, index: 1), mode: .order, seed: 9)
        assert(engine.start()); assert(engine.turnCardsOver()); assert(engine.beginAnswering())
        for start in [-0.66, -0.40, -0.331, -0.32, -0.06, 0.06, 0.32, 0.331, 0.40, 0.66] {
            var ride = HoneySlideSimulation()
            ride.synchronize(rounds: engine.visibleRounds, stage: 1, acceptingInput: true)
            let row = ride.activeCheckpoint!
            ride.targetLateral = start
            let entersAt = (row.worldPosition - HoneySlideRules.playerAhead - HoneySlideRules.dividerLead)
                / HoneySlideRules.forwardSpeed
            while ride.elapsed + 1.0 / 120 < entersAt {
                ride.advance(seconds: 1.0 / 120)
                assert(ride.activeCheckpoint!.guidedLane == nil)
            }
            let nearest = HoneySlideRules.collisionIndex(lateral: ride.lateral)
            let expected = (0..<3).min { abs(ride.lateral - Double($0 - 1) * 0.66)
                < abs(ride.lateral - Double($1 - 1) * 0.66) }!
            assert(nearest == expected)
            let before = ride.lateral
            ride.advance(seconds: entersAt - ride.elapsed + 0.001)
            assert(ride.activeCheckpoint!.guidedLane == nearest)
            assert(abs(ride.lateral - before) < 0.02) // no snap at the noses
            let center = Double(nearest - 1) * 0.66
            while ride.crossing(roundID: row.roundID!) == nil {
                // A late tap, drag, or held key cannot cut across a wall.
                ride.targetLateral = nearest == 2 ? -0.78 : 0.78
                ride.press(nearest == 2 ? -1 : 1)
                ride.advance(seconds: 1.0 / 60)
                assert(ride.activeCheckpoint!.guidedLane == nearest)
                assert(HoneySlideRules.collisionIndex(lateral: ride.lateral) == nearest)
                assert(ride.targetLateral == center)
            }
            let hit = ride.crossing(roundID: row.roundID!)!
            assert(hit.index == nearest && hit.option == row.options[nearest])
            assert(abs(ride.lateral - center) < 0.03)
            ride.markSelected(checkpointID: row.id, index: hit.index, correct: hit.option.isCorrect)
            assert(ride.activeCheckpoint!.guidedLane == nil)
            ride.release()
            ride.targetLateral = nearest == 2 ? -0.66 : 0.66
            for _ in 0..<80 { ride.advance(seconds: 1.0 / 120) }
            assert(abs(ride.lateral - ride.targetLateral) < 0.03)
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
            assert(midLeft.x > 0 && midRight.x < 1600)
            let now = HoneySlideRules.trackPoint(depth: 0.2, offset: 0, distance: second)
            let next = HoneySlideRules.trackPoint(depth: 0.2, offset: 0, distance: second + 1.0 / 60)
            assert(now.x.isFinite && abs(next.x - now.x) < 6)
            var priorLeft = 800.0, priorRight = 800.0
            for depth in stride(from: 0.55, through: HoneySlideRules.playerDepth, by: 0.01) {
                let center = HoneySlideRules.ridingPoint(depth: depth, lateral: 0, distance: second)
                let left = HoneySlideRules.ridingPoint(depth: depth, lateral: -0.66, distance: second)
                let right = HoneySlideRules.ridingPoint(depth: depth, lateral: 0.66, distance: second)
                assert(center.x == 800 && left.x < priorLeft && right.x > priorRight)
                priorLeft = left.x; priorRight = right.x
            }
            for depth in [0.1, 0.2, 0.4, 0.84] {
                let center = HoneySlideRules.trackPoint(depth: depth, offset: 0, distance: second)
                let edge = HoneySlideRules.trackPoint(depth: depth, offset: 1, distance: second)
                let player = HoneySlideRules.ridingPoint(depth: depth, lateral: 0.80, distance: second)
                assert(player.x - center.x < (edge.x - center.x) * 0.8)
            }
        }
    }

    private static func checkAnswerLayout() {
        let contact = HoneySlideRules.answerScale(depth: HoneySlideRules.playerDepth)
        let riderWidth = min(1600 * 0.285, 900 * 0.43)
        assert((154 * contact / riderWidth) > 0.74 && (154 * contact / riderWidth) < 0.80)
        assert(HoneySlideRules.answerScale(depth: 0.1) < 0.24)
        assert(HoneySlideRules.answerScale(depth: 0.2) < 0.48)
        // Check every bend over ten minutes, including shadows and honey caps.
        // The full contact row fits the viewport, and all three targets have
        // a visible gap even before they reach the player.
        for second in stride(from: 0.0, through: 600.0, by: 0.5) {
            for depth in [0.08, 0.1, 0.2, 0.4, 0.6, HoneySlideRules.playerDepth] {
                let centers = [-0.66, 0, 0.66].map {
                    HoneySlideRules.ridingPoint(depth: depth, lateral: $0, distance: second).x
                }
                let fullWidth = 154 * HoneySlideRules.answerScale(depth: depth)
                assert(centers[1] - centers[0] > fullWidth)
                assert(centers[2] - centers[1] > fullWidth)
                assert(centers[0] - fullWidth / 2 > 0)
                assert(centers[2] + fullWidth / 2 < 1600)
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
            var ride = HoneySlideSimulation()
            ride.synchronize(rounds: engine.visibleRounds, stage: 1, acceptingInput: true)
            let row = ride.activeCheckpoint!
            ride.targetLateral = Double(selectedLane - 1) * HoneySlideRules.laneSpacing
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
                assert(center.x == 800)
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
