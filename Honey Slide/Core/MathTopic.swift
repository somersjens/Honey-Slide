//
//  MathTopic.swift
//  Elephant Challenge: Math Memory
//
//  The topic catalog and the difficulty curve behind it. Both the level cards
//  the player sees and the sums the generator produces read from here, so the
//  number on a card and the maths behind it can never drift apart.
//
//  Ported from Jumping Fox's ChallengeScaling/LevelCatalog, reduced to the one
//  practice form Math Memory needs.
//

import Foundation

// MARK: - Topics

public enum MathTopic: String, CaseIterable, Identifiable, Codable, Sendable {
    case addition
    case subtraction
    case tables
    case fractions
    case percentages
    case mixed

    public var id: String { rawValue }

    /// Localization key for the topic name.
    public var titleKey: String { "topic.\(rawValue)" }
    /// Localization key for the one-line "what this practises" summary.
    public var detailKey: String { "topic.\(rawValue).detail" }

    /// SF Symbol for the topic selector.
    public var symbolName: String {
        switch self {
        case .addition: return "plus"
        case .subtraction: return "minus"
        case .tables: return "multiply"
        case .fractions: return "divide"
        case .percentages: return "percent"
        case .mixed: return "star.fill"
        }
    }

    /// Small secondary glyph shown on a level card.
    public var operatorSymbol: String {
        switch self {
        case .addition: return "+"
        case .subtraction: return "−"
        case .tables: return "×"
        case .fractions: return "½"
        case .percentages: return "%"
        case .mixed: return "+ − × %"
        }
    }

    /// Point size for the topic glyph, before the iPad scale. Per symbol,
    /// because glyphs read optically different at the same size: the filled
    /// star reads widest, the percent sign reads tallest.
    public var symbolPointSize: CGFloat {
        switch self {
        case .mixed: return 17
        case .percentages: return 19
        default: return 21
        }
    }

    /// Supermix replaces the three order buttons with the 2×2 star grid: the
    /// four combinations are separate exercises, not three orderings of one.
    public var usesSupermixGrid: Bool { self == .mixed }

    /// Fractions and Percentages do not order their sub-levels; the same three
    /// buttons change what kind of sum comes out. They therefore carry their
    /// own labels and pop-out copy. Every other topic keeps Order · Random ·
    /// Mixed.
    public var modeOverride: ModeLabelOverride? {
        switch self {
        case .fractions:
            return ModeLabelOverride(
                orderTitleKey: "mode.fractions.single",
                randomTitleKey: "mode.fractions.multiple",
                infoHeaderKey: "info.mode.fractions.header",
                orderInfoKey: "info.mode.fractions.single",
                randomInfoKey: "info.mode.fractions.multiple"
            )
        case .percentages:
            return ModeLabelOverride(
                orderTitleKey: "mode.percentages.whole",
                randomTitleKey: "mode.percentages.decimal",
                infoHeaderKey: "info.mode.percentages.header",
                orderInfoKey: "info.mode.percentages.whole",
                randomInfoKey: "info.mode.percentages.decimal"
            )
        default:
            return nil
        }
    }
}

// MARK: - Difficulty scaling

/// The Supermix sub-choices: how many operations the mix draws from. Each one
/// adds the next operation to the one before it, so the ladder is strictly
/// widening rather than four unrelated sets.
public enum MixedVariant: String, CaseIterable, Identifiable, Codable, Sendable {
    case basic      // + −
    case times      // + − ×
    case fraction   // + − × ÷
    case all        // + − × ÷ %

    public var id: String { rawValue }

    /// The operator glyphs this variant practises, in their fixed order.
    public var operators: [String] {
        Array(["+", "−", "×", "÷", "%"].prefix(operationCount))
    }

    public var operationCount: Int {
        switch self {
        case .basic:    return 2
        case .times:    return 3
        case .fraction: return 4
        case .all:      return 5
        }
    }

    /// The topics a round of this variant can draw from.
    public var topics: [MathTopic] {
        let ladder: [MathTopic] = [.addition, .subtraction, .tables, .fractions, .percentages]
        return Array(ladder.prefix(operationCount))
    }

    /// Localization key for the one-line explanation.
    public var detailKey: String { "info.super.\(rawValue)" }

    // MARK: Operator layout

    /// Glyphs that read optically heavier than the rest at the same point size,
    /// with the factor their own size and slot are scaled by.
    public static let heavyOperatorGlyphs: [String: CGFloat] = ["%": 0.8]
}

public enum MathScaling {
    /// Fraction denominators for all 99 levels, in the intended learning order.
    public static let fractionDenominators = [
        2, 4, 8, 3, 6, 12, 5, 10, 20, 7, 14, 28, 16, 32, 64, 128, 256, 512,
        24, 48, 96, 192, 384, 768, 40, 80, 160, 320, 640, 56, 112, 224, 448, 896,
        9, 18, 36, 72, 144, 288, 576, 11, 22, 44, 88, 176, 352, 704, 13, 26, 52,
        104, 208, 416, 832, 15, 30, 60, 120, 240, 480, 960, 17, 34, 68, 136, 272,
        544, 19, 38, 76, 152, 304, 608, 21, 42, 84, 168, 336, 672, 23, 46, 92,
        184, 368, 736, 25, 50, 100, 200, 400, 800, 27, 54, 108, 216, 432, 864, 1000]

    /// Percentages for all 99 levels, in the intended learning order.
    public static let percentageLevels = [
        25, 50, 75, 5, 10, 15, 20, 40, 80, 30, 60, 90, 35, 45, 55, 65, 70, 85, 95,
        2, 4, 6, 8, 12, 14, 16, 18, 22, 24, 26, 28, 32, 34, 36, 38, 42, 44, 46, 48,
        52, 54, 56, 58, 62, 64, 66, 68, 72, 74, 76, 78, 82, 84, 86, 88, 92, 94, 96,
        98, 1, 3, 7, 9, 11, 13, 17, 19, 21, 23, 27, 29, 31, 33, 37, 39, 41, 43, 47,
        49, 51, 53, 57, 59, 61, 63, 67, 69, 71, 73, 77, 79, 81, 83, 87, 89, 91, 93,
        97, 99]

    /// The denominator practised at a given level.
    public static func fractionDenominator(_ level: Int) -> Int {
        fractionDenominators[clampIndex(level, count: fractionDenominators.count)]
    }

    /// The percentage practised at a given level.
    public static func percentage(_ level: Int) -> Int {
        percentageLevels[clampIndex(level, count: percentageLevels.count)]
    }

    private static func clampIndex(_ level: Int, count: Int) -> Int {
        min(max(0, level - 1), count - 1)
    }

    /// Highest number added at a given addition level. The other operand grows
    /// with it, so level 3 gives sums like 14 + 3 but never 14 + 9.
    public static func additionCeiling(_ level: Int) -> Int {
        max(10, level * 5 + 3)
    }

    /// Highest starting number at a given subtraction level.
    public static func subtractionCeiling(_ level: Int) -> Int {
        max(10, level * 6 + 3)
    }

    /// The tables available at a given level: this level's table and every
    /// table below it (capped at 99).
    public static func tablePool(_ level: Int) -> [Int] {
        Array(1...min(GameConfig.maximumLevel, max(1, level)))
    }

    /// The big round "whole" a high-level fraction/percentage question works
    /// with. Climbs in tens from 110 (level 13) toward ~970 (level 99).
    public static func premiumCeiling(_ level: Int) -> Int {
        100 + max(1, level - 12) * 10
    }

    /// The friendly denominators reviewed by high-level fraction questions.
    public static let premiumFractionDenominators = [2, 4, 5, 8, 10, 20, 25]
    /// The friendly percentages reviewed by high-level percentage questions.
    public static let premiumPercentages = [50, 25, 10, 20, 75, 5]

    // MARK: Mixed-mode pools

    /// The denominators a Mixed fractions round may draw at this level: this
    /// level's denominator plus the easier ones that were already introduced
    /// *and* divide it cleanly. A seventh of a whole is not an easier version
    /// of an eighth, so 8 reviews 2 and 4 — never 3, 5 or 7.
    public static func easierFractionDenominators(_ level: Int) -> [Int] {
        let index = clampIndex(level, count: fractionDenominators.count)
        let current = fractionDenominators[index]
        var pool: [Int] = []
        for candidate in fractionDenominators[...index]
        where current % candidate == 0 && !pool.contains(candidate) {
            pool.append(candidate)
        }
        // Ascending: easy → hard, which is the order `weightedHardPick` wants.
        return pool.sorted()
    }

    /// The percentages a Mixed percentages round may draw at this level: this
    /// one and every percentage taught before it, in learning order.
    public static func earlierPercentages(_ level: Int) -> [Int] {
        let index = clampIndex(level, count: percentageLevels.count)
        // Reversed so the current percentage sits last, where the weighted pick
        // leans hardest; the earliest ones stay in the mix but come up least.
        return Array(percentageLevels[...index]).reversed()
    }
}

// MARK: - The fixed Order route

/// The predictable climbing route the Order button plays. It is computed
/// straight from the session's step counter — no randomness at all — so the
/// same level always walks the same path.
///
/// Addition and subtraction run three groups of five sums (fifteen per lap)
/// and then start over; the tables simply cycle ×1 … ×12.
public enum PracticeRoute {
    public static let groupSize = 5
    /// What each group of five adds to the starting point, so the second and
    /// third lap are not a literal repeat of the first.
    public static let groupShifts = [0, 1, 3]

    public static var lapLength: Int { groupSize * groupShifts.count }

    private static func shift(_ step: Int) -> Int {
        groupShifts[(step / groupSize) % groupShifts.count]
    }

    private static func position(_ step: Int) -> Int { step % groupSize }

    /// The other operand of `n + ?`. For n = 2 this walks 2+2 … 2+10, then
    /// 2+3 … 2+11, then 2+5 … 2+13.
    public static func additionOther(number n: Int, step: Int) -> Int {
        n + shift(step) + position(step) * n
    }

    /// The starting number of `? − n`. For n = 2 this walks 12−2 … 4−2, then
    /// 13−2 … 5−2, then 15−2 … 7−2.
    public static func subtractionStart(number n: Int, step: Int) -> Int {
        max(n, 6 * n + shift(step) - position(step) * n)
    }

    /// The multiplier of `t × ?`, cycling 1 … 12 forever.
    public static func tableMultiplier(step: Int) -> Int {
        (step % 12) + 1
    }

    /// The whole a fraction or percentage question works with, taken from a
    /// small repeating set of factors so the answers do not simply count up.
    public static let wholeFactors = Array(1...6)
    public static let percentageFactors = Array(1...8)
}

// MARK: - Level

/// One selectable level within a topic.
public struct MathLevel: Identifiable, Hashable, Codable, Sendable {
    public let topic: MathTopic
    /// 1-based level number.
    public let index: Int

    public var id: String { "\(topic.rawValue).\(index)" }

    /// Levels beyond the free tier need Premium.
    public var requiresPremium: Bool { index > GameConfig.freeLevelCount }

    /// The big central number on the level card. Meaningful per topic: the
    /// number added/taken away, the table, the denominator, the percentage.
    public var cardNumber: String {
        switch topic {
        case .addition, .subtraction, .tables, .mixed:
            return "\(index)"
        case .fractions:
            return "\(MathScaling.fractionDenominator(index))"
        case .percentages:
            return "\(MathScaling.percentage(index))"
        }
    }

    public init(topic: MathTopic, index: Int) {
        self.topic = topic
        self.index = max(1, min(GameConfig.maximumLevel, index))
    }
}

public enum LevelCatalog {
    /// Every level of a topic, free tier first.
    public static func levels(for topic: MathTopic) -> [MathLevel] {
        (1...GameConfig.maximumLevel).map { MathLevel(topic: topic, index: $0) }
    }

    public static func level(id: String) -> MathLevel? {
        let parts = id.split(separator: ".")
        guard parts.count == 2,
              let topic = MathTopic(rawValue: String(parts[0])),
              let index = Int(parts[1]),
              (1...GameConfig.maximumLevel).contains(index) else { return nil }
        return MathLevel(topic: topic, index: index)
    }
}
