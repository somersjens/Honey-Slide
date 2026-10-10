//
//  MemoryGame.swift
//  Elephant Challenge: Math Memory
//
//  The session state machine. Every rule that decides what a tap does lives
//  here, and every transition is guarded by the current state — that is what
//  makes double taps, double scoring and double life loss impossible.
//
//  This type is deliberately free of SwiftUI and of timers: the view drives it
//  with explicit calls and asks it what to show. That keeps it fully testable.
//
//  The reef scene uses the same state machine: it opens a round straight
//  through `turnCardsOver` and `beginAnswering` — there is nothing to memorise
//  under water — and then hands over whichever answer bubble the fish touched.
//

import Foundation

// MARK: - State

public enum GameState: String, Equatable, Sendable {
    /// Session created, nothing shown yet.
    case intro
    /// The answer cards lie face up: this is the memorising beat. The question
    /// is still hidden, and a tap turns the cards over.
    case memorising
    /// The cards are mid-flip: they are turning face down while the question
    /// comes up. No input is accepted during the turn.
    case questionVisible
    /// The cards are face down and the question is readable. Exactly one tap
    /// is accepted — the player must remember where the answer was.
    case answering
    /// An answer was taken: feedback is showing, input is locked.
    case resolving
    /// Feedback finished; the next round can be installed.
    case roundComplete
    /// The level clock ended the run, or the player explicitly quit.
    case gameOver
}

public enum GameOverReason: String, Equatable, Sendable {
    case outOfLives
    case roundsCompleted
    case timeExpired
    case quit
}

/// What resolving a tap produced, so the view knows which feedback to play.
public enum AnswerOutcome: Equatable, Sendable {
    case correct(cardsEarned: Int, usedBonusFish: Bool)
    case wrong(correctOptionID: UUID, lostHalfLife: Bool)
    /// The tap was ignored (wrong state, or the round was already answered).
    case ignored
}

// MARK: - Result

public struct SessionResult: Equatable, Sendable {
    public var correctAnswers = 0
    public var wrongAnswers = 0
    public var cardsEarned = 0
    /// Cards awarded over and above the normal one-bubble reward.
    public var bonusCards = 0
    /// Kept under its persisted name for save compatibility; now counts caught
    /// 2x fish whose bonus was paid out.
    public var doubleCardsAnswered = 0
    public var isNewPersonalBest = false
    public var previousPersonalBest = 0
    public var unlockedCharacterIDs: [String] = []
    public var reason: GameOverReason = .roundsCompleted

    public init() {}
}

// MARK: - Engine

public final class MemoryGame {
    // MARK: Configuration

    public let level: MathLevel
    /// Which scoreboard this session plays on, so a paused run can only ever be
    /// resumed onto the exact board it came from.
    public let board: LevelBoard
    private let factory: RoundFactory

    // MARK: Observable state (read by the view)

    public private(set) var state: GameState = .intro
    public private(set) var round: GameRound?
    /// Every round still to be played, built before the board becomes live so
    /// a transition never shares question generation with the outgoing tongue,
    /// score animation and incoming swarm.
    private var preparedRounds: [GameRound] = []

    /// The active sum followed by the two sums already generated for the fly
    /// game's preview column. They are the exact rounds `advance()` will use;
    /// previewing them never creates a second question stream.
    public var visibleRounds: [GameRound] {
        ([round].compactMap { $0 } + preparedRounds).prefix(3).map { $0 }
    }

    public private(set) var roundNumber = 0
    public private(set) var cards = 0
    /// Lives in half units. 6 == three lives.
    public private(set) var lifeHalves = GameConfig.startingLifeHalves
    /// The option the player tapped this round, if any.
    public private(set) var selectedOptionID: UUID?
    public private(set) var lastOutcome: AnswerOutcome?
    public private(set) var result = SessionResult()
    public private(set) var heartFishProgress = 0
    public private(set) var heartFishTarget = GameConfig.heartFishCorrectAnswers
    public private(set) var isHeartFishAvailable = false

    /// The round the player first dropped to their last life on, if they have.
    /// The one rescue heart of the session is measured from here.
    private var rescueHeartArmedRound: Int?
    /// Set once that heart has been put in the world. It is never offered a
    /// second time, whether it was taken or flown straight past.
    private var hasSpentRescueHeart = false

    /// Whether the session's single rescue heart should be placed in the next
    /// set of hoops. It is owed to a player who has been down to their last
    /// life for a couple of passages, and never to one who is already all but
    /// finished — a rescue landing on the finish line rescues nothing.
    public var isRescueHeartDue: Bool {
        guard !hasSpentRescueHeart,
              state != .gameOver,
              lifeHalves > 0,
              lifeHalves < GameConfig.startingLifeHalves,
              let armed = rescueHeartArmedRound,
              roundNumber >= armed + GameConfig.rescueHeartDelayRounds
        else { return false }
        return Double(cards) < Double(board.maximum) * GameConfig.rescueHeartMaximumProgress
    }

    /// Called by the view the moment the heart is actually placed, which is
    /// what spends it — not catching it.
    public func spendRescueHeart() {
        hasSpentRescueHeart = true
    }

    /// Set once the session is over; nil while playing.
    public private(set) var gameOverReason: GameOverReason?

    /// A wrong answer costs a life but leaves the sum standing: the coral keeps
    /// offering the same answers until the right one is caught. Only a correct
    /// answer moves the session on to the next sum.

    // MARK: Derived

    public var livesRemaining: Double {
        Double(lifeHalves) / Double(GameConfig.lifeGranularity)
    }

    /// Generated rounds have a defensive upper bound, although a normal run
    /// finishes as soon as the board's required questions are answered.
    public var maximumRounds: Int { GameConfig.maximumRoundCeiling }

    /// Whether a tap on an answer card can be accepted right now.
    public var acceptsInput: Bool { state == .answering }

    /// Whether the answer values are readable. They are during the memorising
    /// beat, and again while the round resolves so the player can see what they
    /// picked and where the right card was.
    public var showsAnswerValues: Bool {
        state == .memorising || state == .resolving || state == .roundComplete
    }

    /// Whether the question is readable. It appears only once the cards are
    /// face down, which is what makes this a memory game.
    public var showsQuestion: Bool {
        state != .intro && state != .memorising
    }

    // MARK: Init

    public init(level: MathLevel,
                mixedVariant: MixedVariant = .all,
                mode: PracticeMode = .mixed,
                seed: UInt64? = nil) {
        self.level = level
        self.board = LevelBoard(level: level,
                                mixedVariant: mixedVariant,
                                mode: mode)
        self.factory = RoundFactory(level: level,
                                    mixedVariant: mixedVariant,
                                    mode: board.mode,
                                    seed: seed)
    }

    // MARK: - Session lifecycle

    /// Composes the session's question sequence while the start/pause card is
    /// still covering the playfield, then deals the first few rounds. Later
    /// rounds are taken from that same sequence; the clock can outlast the
    /// first batch, and the factory extends the plan when it does.
    public func prepare(startingAt firstRound: Int = 1) {
        guard state == .intro, round == nil, preparedRounds.isEmpty else { return }
        let first = min(max(1, firstRound), maximumRounds)
        let count = min(maximumRounds - first + 1,
                        GameConfig.preparedSequenceLength(boardMaximum: board.maximum))
        factory.prepareSequence(startingAt: first, count: count)
        appendPreparedRounds(startingAt: first)
    }

    /// Starts the session and deals the first round's answer cards face up.
    @discardableResult
    public func start() -> Bool {
        guard state == .intro else { return false }
        prepare(startingAt: 1)
        roundNumber = 1
        round = preparedRounds.removeFirst()
        replenishPreparedRounds()
        state = .memorising
        return true
    }

    /// Resumes a level the player left part-way through, restoring the cards,
    /// lives and round they stopped on. Rejected if the record is not playable.
    @discardableResult
    public func resume(from session: PausedSession) -> Bool {
        guard state == .intro, session.isResumable else { return false }
        roundNumber = session.roundNumber
        cards = session.cards
        lifeHalves = session.lifeHalves
        result.correctAnswers = session.correctAnswers
        result.wrongAnswers = session.wrongAnswers
        result.doubleCardsAnswered = session.doubleCardsAnswered
        result.bonusCards = session.bonusCards
        result.cardsEarned = session.cards
        // A run that comes back already on its last life is owed the same
        // rescue as one that gets there in front of us.
        if lifeHalves > 0, lifeHalves <= GameConfig.rescueHeartLifeThresholdHalves {
            rescueHeartArmedRound = roundNumber
        }
        heartFishProgress = session.heartFishProgress ?? 0
        heartFishTarget = session.heartFishTarget ?? GameConfig.heartFishCorrectAnswers
        isHeartFishAvailable = session.isHeartFishAvailable ?? false
        if preparedRounds.first?.number != roundNumber {
            preparedRounds.removeAll(keepingCapacity: true)
            prepare(startingAt: roundNumber)
        }
        round = preparedRounds.removeFirst()
        replenishPreparedRounds()
        state = .memorising
        return true
    }

    /// A snapshot of the session as it stands, for storing when the player
    /// leaves. Nil once the session is over — there is nothing to come back to.
    public func pausedSession(hasBonusFishPower: Bool = false,
                              lastMissedChallenge: String? = nil,
                              timeRemainingSeconds: Int? = nil,
                              answerPaces: [AnswerPace]? = nil,
                              currentQuestionElapsedSeconds: TimeInterval? = nil) -> PausedSession? {
        guard state != .intro, state != .gameOver else { return nil }
        return PausedSession(boardID: board.storageID,
                             roundNumber: roundNumber,
                             cards: cards,
                             lifeHalves: lifeHalves,
                             correctAnswers: result.correctAnswers,
                             wrongAnswers: result.wrongAnswers,
                             doubleCardsAnswered: result.doubleCardsAnswered,
                             bonusCards: result.bonusCards,
                             // Legacy field: the helper it counted is gone.
                             flamethrowersUsed: 0,
                             hasBonusFishPower: hasBonusFishPower,
                             heartFishProgress: heartFishProgress,
                             heartFishTarget: heartFishTarget,
                             isHeartFishAvailable: isHeartFishAvailable,
                             lastMissedChallenge: lastMissedChallenge,
                             timeRemainingSeconds: timeRemainingSeconds,
                             answerPaces: answerPaces,
                             currentQuestionElapsedSeconds: currentQuestionElapsedSeconds)
    }

    /// The tap that turns the answer cards face down and brings the question
    /// up. From here on the player is working from memory.
    @discardableResult
    public func turnCardsOver() -> Bool {
        guard state == .memorising else { return false }
        state = .questionVisible
        return true
    }

    /// Called once the cards have finished turning. From here the round accepts
    /// exactly one answer.
    @discardableResult
    public func beginAnswering() -> Bool {
        guard state == .questionVisible else { return false }
        state = .answering
        return true
    }

    // MARK: - Answering

    /// Resolves a tap on an answer card. Any tap that arrives in the wrong
    /// state — a second tap on the same round, a tap during feedback, a tap on
    /// a burned card — is ignored without touching the score.
    @discardableResult
    public func select(optionID: UUID,
                       usesBonusFish: Bool = false,
                       wrongAnswerCostHalves overrideWrongAnswerCostHalves: Int? = nil) -> AnswerOutcome {
        guard state == .answering,
              let round,
              selectedOptionID == nil,
              let option = round.options.first(where: { $0.id == optionID })
        else {
            // Deliberately leaves `lastOutcome` alone: an ignored tap must not
            // disturb the feedback the view is currently showing.
            return .ignored
        }

        // Lock input for the whole of the resolve phase, before any scoring.
        selectedOptionID = optionID
        state = .resolving

        let outcome: AnswerOutcome
        if option.isCorrect {
            // A caught bonus fish or a successful early golden approach
            // doubles this answer.
            let earned = usesBonusFish
                ? GameConfig.normalCardReward * GameConfig.bonusFishMultiplier
                : GameConfig.normalCardReward
            cards += earned
            result.correctAnswers += 1
            result.cardsEarned += earned
            if usesBonusFish {
                result.doubleCardsAnswered += 1
            }
            result.bonusCards += earned - GameConfig.normalCardReward
            advanceHeartFishProgressIfNeeded()
            outcome = .correct(cardsEarned: earned,
                               usedBonusFish: usesBonusFish)
        } else {
            result.wrongAnswers += 1
            let lifeCost = overrideWrongAnswerCostHalves
                ?? GameConfig.wrongAnswerCostHalves
            spendLifeHalves(lifeCost)
            outcome = .wrong(correctOptionID: round.correctOption?.id ?? optionID,
                             lostHalfLife: lifeCost == 1)
        }
        lastOutcome = outcome
        return outcome
    }

    /// Restores life when the passing heart fish is caught. The return value is
    /// the number of half-hearts restored, or zero when the catch was stale.
    @discardableResult
    public func catchHeartFish() -> Int {
        guard isHeartFishAvailable,
              lifeHalves > 0,
              lifeHalves < GameConfig.startingLifeHalves else { return 0 }
        let recovery = lifeHalves == 1
            ? GameConfig.criticalHeartFishRecoveryHalves
            : GameConfig.heartFishRecoveryHalves
        let previous = lifeHalves
        lifeHalves = min(GameConfig.startingLifeHalves, lifeHalves + recovery)
        resetHeartFishProgress()
        return lifeHalves - previous
    }

    /// Gives life back outright, which is what the guided run's heart pick-up
    /// does: the lesson costs a life on purpose and hands it straight back, so
    /// the real game never starts a heart down. Capped at the starting lives,
    /// and refused once the session is already over.
    @discardableResult
    public func restoreLifeHalves(_ halves: Int) -> Int {
        guard halves > 0, lifeHalves > 0, lifeHalves < GameConfig.startingLifeHalves else { return 0 }
        let previous = lifeHalves
        lifeHalves = min(GameConfig.startingLifeHalves, lifeHalves + halves)
        return lifeHalves - previous
    }

    /// Adds the fly game's speed bonus without bypassing the normal result and
    /// persistence totals. The caller has already established that this was a
    /// second correct catch inside the combo window.
    public func awardFlyComboBonus() {
        guard state == .resolving,
              case .correct? = lastOutcome else { return }
        cards += GameConfig.hoopComboBonus
        result.cardsEarned += GameConfig.hoopComboBonus
        result.bonusCards += GameConfig.hoopComboBonus
    }

    /// A missed heart fish returns after four more correct answers, rather than
    /// making the player repeat the full eight-answer charge.
    public func missHeartFish() {
        guard isHeartFishAvailable else { return }
        isHeartFishAvailable = false
        heartFishTarget = heartFishProgress + GameConfig.heartFishRetryCorrectAnswers
    }

    // MARK: - Round transitions

    /// Called by the view when the feedback animation has finished.
    @discardableResult
    public func finishResolving() -> Bool {
        guard state == .resolving else { return false }
        state = .roundComplete
        return true
    }

    /// Reopens the active question after a wrong answer. Its option identities
    /// and values stay untouched, so the player can try the same sum again.
    @discardableResult
    public func retryCurrentRound() -> Bool {
        guard state == .roundComplete, round != nil else { return false }
        selectedOptionID = nil
        lastOutcome = nil
        state = .memorising
        return true
    }

    /// Ends an active run when Space Lion's level clock reaches zero.
    public func expireTime() {
        guard state != .intro, state != .gameOver else { return }
        finish(reason: .timeExpired)
    }

    /// Installs the next round after a correct answer. Ten correct answers make
    /// a stage; the final stage completes exactly at the board target.
    @discardableResult
    public func advance() -> GameState {
        guard state == .roundComplete else { return state }

        if result.correctAnswers >= board.maximum {
            finish(reason: .roundsCompleted)
            return state
        }

        roundNumber += 1
        if preparedRounds.isEmpty { appendPreparedRounds(startingAt: roundNumber) }
        round = preparedRounds.removeFirst()
        replenishPreparedRounds()
        selectedOptionID = nil
        lastOutcome = nil
        state = .memorising
        return state
    }

    /// Ends the session early (the player left the game screen).
    public func quit() {
        guard state != .gameOver else { return }
        finish(reason: .quit)
    }

    // MARK: - Private

    private func spendLifeHalves(_ halves: Int) {
        let wasFull = lifeHalves == GameConfig.startingLifeHalves
        lifeHalves = max(0, lifeHalves - halves)
        if wasFull && lifeHalves > 0 { resetHeartFishProgress() }
        // The rescue heart is armed by the mistake that put the player on their
        // last life, and counts its passages from there.
        if rescueHeartArmedRound == nil, lifeHalves > 0,
           lifeHalves <= GameConfig.rescueHeartLifeThresholdHalves {
            rescueHeartArmedRound = roundNumber
        }
    }

    private func appendPreparedRounds(startingAt first: Int) {
        guard first <= maximumRounds else { return }
        let last = min(maximumRounds,
                       first + GameConfig.preparedRoundRunway - 1)
        preparedRounds.append(contentsOf: (first...last).map {
            factory.makeRound(number: $0)
        })
    }

    private func replenishPreparedRounds() {
        guard preparedRounds.count < GameConfig.preparedRoundRunway else { return }
        let first = (preparedRounds.last?.number ?? roundNumber) + 1
        guard first <= maximumRounds else { return }
        let amount = GameConfig.preparedRoundRunway - preparedRounds.count
        let last = min(maximumRounds, first + amount - 1)
        preparedRounds.append(contentsOf: (first...last).map {
            factory.makeRound(number: $0)
        })
    }

    private func advanceHeartFishProgressIfNeeded() {
        guard lifeHalves > 0,
              lifeHalves < GameConfig.startingLifeHalves,
              !isHeartFishAvailable else { return }
        heartFishProgress += 1
        if heartFishProgress >= heartFishTarget {
            isHeartFishAvailable = true
        }
    }

    private func resetHeartFishProgress() {
        heartFishProgress = 0
        heartFishTarget = GameConfig.heartFishCorrectAnswers
        isHeartFishAvailable = false
    }

    private func finish(reason: GameOverReason) {
        gameOverReason = reason
        result.reason = reason
        state = .gameOver
    }

    /// Fills in the persistence-derived parts of the result. Called by the view
    /// model once the score has been recorded, so the engine itself stays free
    /// of storage concerns.
    public func applyProgressOutcome(previousBest: Int,
                                     isNewPersonalBest: Bool,
                                     unlockedCharacterIDs: [String]) {
        result.previousPersonalBest = previousBest
        result.isNewPersonalBest = isNewPersonalBest
        result.unlockedCharacterIDs = unlockedCharacterIDs
    }
}
