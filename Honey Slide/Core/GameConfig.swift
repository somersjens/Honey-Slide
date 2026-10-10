//
//  GameConfig.swift
//  Elephant Challenge: Math Memory
//
//  The single source of truth for every tunable gameplay number. Nothing in the
//  game may hardcode a life count, a probability, a duration or an unlock
//  requirement — it is declared here and read from here.
//

import Foundation

// MARK: - Central configuration

public enum GameConfig {

    // MARK: Answers

    /// Space Lion keeps six unique answers visible: three on each side wall.
    /// The two bottom tiles of the old eight-button cockpit are gone.
    public static let answerBubbleCount = 6

    /// Buttons stacked in one side column.
    public static var answerColumnCount: Int { answerBubbleCount / 2 }

    /// Wrong answers a question must supply: every button but the right one.
    public static var distractorCount: Int { answerBubbleCount - 1 }

    // MARK: Lives

    /// Lives a session starts with. Lives are tracked internally in half units.
    public static let startingLives = 3.0
    /// A wrong answer costs one whole life.
    public static let wrongAnswerCost = 1.0

    /// Internal granularity: lives are stored as an integer number of halves,
    /// so no floating point rounding can ever strand the player on 0.4999
    /// lives.
    public static let lifeGranularity = 2
    public static var startingLifeHalves: Int { Int(startingLives * Double(lifeGranularity)) }
    public static var wrongAnswerCostHalves: Int { Int(wrongAnswerCost * Double(lifeGranularity)) }

    // MARK: Session

    /// A stage always contains ten successfully answered questions. Completing
    /// a stage moves the ship to a new destination and tightens the clock.
    public static let questionsPerStage = 10

    /// Seconds available per question in each successive stage. These are
    /// converted into one continuous stage clock (100, 80, 70, 60 and 50
    /// seconds), so a mistake costs time without silently changing question.
    public static let secondsPerQuestionByStage = [10, 8, 7, 6, 5]

    public static func stageDuration(stage: Int) -> Int {
        let index = min(max(1, stage), secondsPerQuestionByStage.count) - 1
        return questionsPerStage * secondsPerQuestionByStage[index]
    }

    /// How long the forward flight between two destinations remains visible.
    public static let stageTravelDuration = 2.35

    /// Defensive upper bound for generated questions and restored sessions.
    public static let maximumRoundCeiling = 10_000

    /// Keep a small runway of live rounds ready while allowing a timed run to
    /// continue well beyond its target without holding thousands of rounds.
    public static let preparedRoundRunway = 4

    /// How many distinct rounds are composed before the first sum is shown.
    /// A wrong answer reopens the same round, and the board ends as soon as its
    /// maximum number of correct answers is reached. Preparing twelve times the
    /// board maximum therefore built hundreds of rounds that could never be
    /// played, synchronously on the main actor while the game was opening.
    /// `RoundFactory` completes the final ten-question stage itself, so
    /// returning the exact board maximum still preserves the rolling answer
    /// bank without preparing unreachable stages.
    public static func preparedSequenceLength(boardMaximum: Int) -> Int {
        max(1, boardMaximum)
    }

    /// Cards awarded for a correct answer on a normal card.
    public static let normalCardReward = 1

    // MARK: Bonuses

    /// Two correct answers inside a second earn this on top of the catch. The
    /// banner announcing it reads the same number, so the two cannot drift.
    public static let hoopComboBonus = 1

    /// A 2x fish swims across the level this many times. Catching it doubles
    /// the next correct answer; a missed fish simply leaves the screen.
    public static let bonusFishCount = 1...3
    public static let bonusFishMultiplier = 2

    /// Once a player has been hurt, this many correct answers earn a chance to
    /// catch a heart fish. Missing it does not throw the work away: four more
    /// correct answers bring it back.
    public static let heartFishCorrectAnswers = 8
    public static let heartFishRetryCorrectAnswers = 4
    /// A normal catch restores half a life. At the last half-heart it restores
    /// a whole life, giving the player a meaningful comeback without ever
    /// exceeding the three-life starting capacity.
    public static let heartFishRecoveryHalves = 1
    public static let criticalHeartFishRecoveryHalves = 2

    // MARK: The rescue heart

    /// What a heart floating in the flight path puts back, in halves — one
    /// whole life.
    public static let lifeHeartRecoveryHalves = 2
    /// A session offers exactly one rescue heart, and only to a player who is
    /// down to this much life: one heart, or the last half of one.
    public static let rescueHeartLifeThresholdHalves = 2
    /// How long the player carries on alone before it appears. Two passages is
    /// enough for the loss to have sunk in and short enough to still feel like
    /// an answer to it.
    public static let rescueHeartDelayRounds = 2
    /// Never offered once the board is this far along: a rescue arriving on the
    /// finish line rescues nothing.
    public static let rescueHeartMaximumProgress = 0.9

    // MARK: Timing (seconds)
    //
    // The brief is explicit: the next round must be able to start within
    // roughly 300–600 ms. These are the only durations gameplay may use.

    /// Card flip animation.
    public static let cardFlipDuration = 0.28
    /// Answer cards fading/scaling in once the question is visible.
    public static let answerRevealDuration = 0.18
    /// How long correct/wrong feedback stays on screen before the next round.
    /// A correct catch is deliberately short: the swarm for the next sum is
    /// already swooping in while the tongue is still reeling the last fly home,
    /// which is what keeps a good run from stalling between questions.
    public static let correctFeedbackDuration = 0.18
    public static let wrongFeedbackDuration = 0.34
    /// Gap between feedback ending and the next round's closed cards appearing.
    public static let roundTransitionDuration = 0.12

    /// Total time from answering to the next round being interactive.
    public static var nextRoundDelay: (correct: Double, wrong: Double) {
        (correctFeedbackDuration + roundTransitionDuration,
         wrongFeedbackDuration + roundTransitionDuration)
    }

    // MARK: Levels

    /// Levels available without Premium.
    public static let freeLevelCount = 12
    /// Highest level Premium unlocks.
    public static let maximumLevel = 99

    /// How strongly question selection leans toward the highest available
    /// sub-level. Weight of sub-level i (1-based) is `i ^ levelWeightExponent`,
    /// so lower levels stay in the mix but the top of the range dominates.
    public static let levelWeightExponent = 1.0
    /// The selected level itself is guaranteed at least this share of rounds,
    /// so "the highest available difficulty appears regularly" is not left to
    /// chance on a level-40 run.
    public static let topLevelMinimumShare = 0.35

    // MARK: Characters

    /// Total earned cards required to unlock each character, in catalog order.
    /// Index 0 is the starter character and is therefore always 0.
    ///
    /// The second half of the catalog is Premium-exclusive: `nil` means the
    /// character cannot be earned with cards at all, no matter the total.
    public static let characterUnlockRequirements: [Int?] = [
        0,          // lion — Space Lion starter
        500,        // octopus
        1_500,      // crab
        3_000,      // elephant
        5_000,      // bear
        nil, nil, nil, nil, nil   // fox, frog, penguin, bunny, dog — Premium
    ]

    // MARK: Level progress

    /// What a full score is worth depends on the chosen exercise. Supermix is
    /// intentionally the only route that goes all the way to 50 bubbles.
    public static let orderLevelMaximum = 20
    public static let randomLevelMaximum = 30
    public static let mixedLevelMaximum = 40
    public static let supermixLevelMaximum = 50

    /// Default used by views before they receive their concrete board.
    public static let levelMaximum = mixedLevelMaximum

    /// Ceiling on the "reached the maximum ×N" tally, so a long-lived save
    /// cannot grow the badge without bound.
    public static let maximumCompletionCount = 100

    /// The three progress dots fill at these shares of `levelCompletionCards`,
    /// so the card art follows the economy instead of hardcoded scores.
    public static let levelTierShares = [0.01, 0.4, 0.75]

    // MARK: Storage

    /// Bumped whenever the persisted shape changes; drives migration.
    public static let storageVersion = 5
}
