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
    private(set) var elapsed = 0.0
    var distance: Double { HoneySlideRules.worldDistance(elapsed) }
    private(set) var lateral = 0.0
    private(set) var lateralVelocity = 0.0
    var tubeHeading: Double { lateralVelocity * 5 + sin(elapsed * 3.4) * 1.7 }
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
    var targetLateral = 0.0
    var heldDirection = 0.0
    private var holdElapsed = 0.0
    private var nextCheckpointID = 0
    private var optionCache: [UUID: [AnswerOption]] = [:]

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
        heldDirection = direction
        holdElapsed = 0
        // A tap changes one lane; a sustained press also allows free steering.
        let lane = round(targetLateral / 0.66)
        targetLateral = max(-0.78, min(0.78, (lane + direction) * 0.66))
    }

    mutating func release() { heldDirection = 0; holdElapsed = 0 }

    mutating func advance(seconds: Double) {
        guard seconds > 0, seconds.isFinite else { return }
        elapsed += seconds
        feedbackRemaining = max(0, feedbackRemaining - seconds)
        impacts.removeAll { $0.age(at: elapsed) > 2.0 }
        holdElapsed += seconds
        if heldDirection != 0 && holdElapsed > 0.24 {
            targetLateral = max(-0.78, min(0.78, targetLateral + heldDirection * seconds * 1.25))
        }
        // The two physical dividers capture the nearest channel at their
        // leading noses. Once between the walls, steering cannot cross them.
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
            targetLateral = Double(channel! - 1) * 0.66
        }
        // Small integration steps keep steering stable even after a slow frame.
        var remaining = min(seconds, 0.3)
        while remaining > 0.00001 {
            let dt = min(1.0 / 120, remaining)
            let acceleration = (targetLateral - lateral) * 95 - lateralVelocity * 18
            lateralVelocity += acceleration * dt
            lateral = max(-0.80, min(0.80, lateral + lateralVelocity * dt))
            if let channel {
                // Keep the entire tube clear of both divider faces while it
                // settles into the middle of the channel, even after a flick.
                let center = Double(channel - 1) * 0.66
                let halfChannel = HoneySlideRules.laneBoundary - channelProgress * (HoneySlideRules.laneBoundary - 0.22)
                let safe = max(center - halfChannel, min(center + halfChannel, lateral))
                if safe != lateral { lateral = safe; lateralVelocity = 0 }
            }
            remaining -= dt
        }
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
                lateral: Double(index - 1) * HoneySlideRules.laneSpacing, distance: elapsed),
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
