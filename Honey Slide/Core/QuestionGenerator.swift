//
//  QuestionGenerator.swift
//  Number Reef
//
//  Turns a chosen level *and a chosen practice mode* into a validated question.
//
//  The three modes are the same three buttons the menu shows, and they mean
//  exactly what they say:
//
//  · Order  — a fixed, predictable route. No randomness at all: the sums are
//             computed straight from the session's step counter, so the same
//             level always walks the same path (2+2, 2+4, 2+6 …).
//  · Random — this level's own number only, shuffled. Every value comes up
//             exactly once per lap, so the practice stays even without the
//             answers simply counting up.
//  · Mixed  — this level *or a lower one*, jumbled together, leaning on the
//             harder end. This is the route the game generated before the
//             three buttons existed.
//
//  Fractions and Percentages are the two topics whose sub-levels are not
//  ordered at all, so their buttons change the *kind* of sum instead: single
//  versus multiple parts, whole versus decimal answers. See `MathTopic
//  .modeOverride`.
//
//  Supermix has no order to choose: each of its four combinations is its own
//  ladder, and every operation inside it climbs by the rules of its own menu.
//
//  The arithmetic rules are ported from Jumping Fox's QuestionEngine: the
//  distractors are the near-misses children actually produce, never values
//  plucked at random.
//

import Foundation

// MARK: - Shuffled cycle

/// Hands out a list of values in a shuffled order, but gives every value out
/// exactly once before any of them comes round again. A new lap never opens
/// with the value the previous lap closed on, so no sum can appear twice in a
/// row across the seam.
final class ShuffledCycle {
    private let values: [Int]
    private var remaining: [Int] = []
    private var last: Int?

    init(_ values: [Int]) {
        self.values = values
    }

    func next(_ random: RandomSource) -> Int {
        guard !values.isEmpty else { return 0 }
        if remaining.isEmpty {
            var lap = random.shuffled(values)
            if lap.count > 1, let last, lap.first == last {
                lap.swapAt(0, random.int(in: 1...(lap.count - 1)))
            }
            remaining = lap
        }
        let value = remaining.removeFirst()
        last = value
        return value
    }
}

// MARK: - Generator

public final class QuestionGenerator {
    public let level: MathLevel
    /// Which of the three menu buttons this session is playing.
    public let mode: PracticeMode
    private let random: RandomSource

    /// Last prompt handed out, so the same sum never appears twice in a row.
    private var lastPrompt: String?
    /// Last operation handed out, so a mixed level does not serve four
    /// multiplications in a row.
    private var lastKind: QuestionKind?
    /// Sub-levels used recently, so the same level does not dominate.
    private var recentSourceLevels: [Int] = []

    /// Position along the fixed Order route. Advanced only when a question is
    /// actually handed out, so a rejected attempt cannot skip a step.
    private var routeStep = 0
    /// The shuffled cycles the Random route runs on, one per purpose.
    private var cycles: [String: ShuffledCycle] = [:]

    /// Which operations a Supermix level draws from. Ignored by every other
    /// topic, which has exactly one operation by definition.
    private let mixedVariant: MixedVariant

    /// How a single question is built once the level and the numbers are
    /// settled: walking the fixed route, or drawing from a shuffled cycle.
    private enum Route {
        case fixed
        case shuffled
    }

    public init(level: MathLevel,
                mode: PracticeMode = .mixed,
                mixedVariant: MixedVariant = .all,
                random: RandomSource = RandomSource()) {
        self.level = level
        self.mode = mode
        self.mixedVariant = mixedVariant
        self.random = random
    }

    // MARK: - Public API

    /// A question for a normal round.
    /// - Parameter requiredDistractors: how many wrong answers the current card
    ///   mode needs. The generator keeps trying until it can supply that many.
    public func next(requiredDistractors: Int,
                     avoiding forbidden: Set<AnswerValue> = []) -> MathQuestion {
        generateValidated(requiredDistractors: requiredDistractors,
                          forceTopLevel: false,
                          avoiding: forbidden)
    }

    /// A harder question for the special double card: always drawn from the top
    /// of the available range rather than the weighted mix. Order and Random
    /// have no range to climb — the level's own number is all there is — so
    /// there it is simply the next question on the route.
    public func nextHarder(requiredDistractors: Int,
                           avoiding forbidden: Set<AnswerValue> = []) -> MathQuestion {
        generateValidated(requiredDistractors: requiredDistractors,
                          forceTopLevel: true,
                          avoiding: forbidden)
    }

    /// Resets the anti-repeat memory for a fresh session.
    public func reset() {
        lastPrompt = nil
        lastKind = nil
        recentSourceLevels.removeAll()
        routeStep = 0
        cycles.removeAll()
    }

    // MARK: - Level mixing

    /// Picks which sub-level this question comes from. Only Mixed and Supermix
    /// ask: the selected level and every level below it are in play, the top of
    /// the range is guaranteed a minimum share, and otherwise weight grows with
    /// the level number.
    func pickSourceLevel(forceTop: Bool) -> Int {
        let top = level.index
        guard top > 1, !forceTop else { return top }

        if random.double(in: 0..<1) < GameConfig.topLevelMinimumShare {
            return top
        }

        // Weighted pick over 1...top. Weight of level i is i^exponent.
        let weights = (1...top).map { pow(Double($0), GameConfig.levelWeightExponent) }
        let total = weights.reduce(0, +)
        var threshold = random.double(in: 0..<total)
        for (offset, weight) in weights.enumerated() {
            threshold -= weight
            if threshold < 0 {
                let candidate = offset + 1
                // Nudge away from a level that just came up three times in a
                // row, so the mix keeps moving without ever excluding a level.
                if recentSourceLevels.suffix(3).allSatisfy({ $0 == candidate }), top > 1 {
                    return candidate == top ? max(1, top - 1) : candidate + 1
                }
                return candidate
            }
        }
        return top
    }

    private func cycle(_ key: String, _ values: @autoclosure () -> [Int]) -> ShuffledCycle {
        if let existing = cycles[key] { return existing }
        let created = ShuffledCycle(values())
        cycles[key] = created
        return created
    }

    // MARK: - Generation

    private func generateValidated(requiredDistractors: Int,
                                   forceTopLevel: Bool,
                                   avoiding forbidden: Set<AnswerValue>) -> MathQuestion {
        // Bounded retry: reject a repeat of the previous prompt, an answer that
        // is already on the board, and any question that cannot supply enough
        // genuinely-wrong distractors.
        let limit = forbidden.isEmpty ? 24 : 64
        var fallback: (question: MathQuestion, steps: Int)?
        for attempt in 0..<limit {
            // A rejected attempt walks the fixed route forward rather than
            // re-offering the sum that was just thrown away.
            let question = generate(forceTopLevel: forceTopLevel, stepOffset: attempt)
            guard question.isValid(requiredDistractors: requiredDistractors) else { continue }
            if forbidden.contains(AnswerValue(question.correctAnswer)) { continue }
            fallback = (question, attempt + 1)
            let repeatsPrompt = question.prompt == lastPrompt
            let repeatsKind = question.kind == lastKind
            // Only insist on a different operation for the first few attempts;
            // a single-operation topic has nothing else to offer.
            if repeatsPrompt { continue }
            if repeatsKind, attempt < 3, level.topic == .mixed { continue }
            return record(question, steps: attempt + 1)
        }
        // Every retry produced the same prompt (e.g. the table of 1 at card
        // mode 2). Hand back the last valid one rather than an invalid round.
        if let fallback { return record(fallback.question, steps: fallback.steps) }
        if forbidden.isEmpty { return record(emergencyQuestion(), steps: 1) }
        return record(emergencyDistinct(avoiding: forbidden), steps: 1)
    }

    private func record(_ question: MathQuestion, steps: Int) -> MathQuestion {
        lastPrompt = question.prompt
        lastKind = question.kind
        routeStep += max(1, steps)
        recentSourceLevels.append(question.sourceLevel)
        if recentSourceLevels.count > 8 { recentSourceLevels.removeFirst() }
        return question
    }

    private func generate(forceTopLevel: Bool, stepOffset: Int) -> MathQuestion {
        let step = routeStep + stepOffset

        // Supermix ignores the three order buttons: each of its combinations is
        // its own ladder. It picks an operation by weight, then plays that
        // operation by the rules of its own menu at a weighted sub-level —
        // level 1 gives only ×1 sums, never 4 × 7.
        if level.topic == .mixed {
            return supermixQuestion(step: step, forceTop: forceTopLevel)
        }

        switch mode {
        case .order:
            return question(topic: level.topic, source: level.index, route: .fixed, step: step)
        case .random:
            return question(topic: level.topic, source: level.index, route: .shuffled, step: step)
        case .mixed:
            return mixedQuestion(step: step, forceTop: forceTopLevel)
        }
    }

    /// Mixed draws the same kind of sum as Random, but from a lower rung of the
    /// ladder as often as from this one. What "lower" means depends on the
    /// topic: a smaller number to add, an earlier table, a denominator that
    /// divides this one, a percentage taught before this one.
    private func mixedQuestion(step: Int, forceTop: Bool) -> MathQuestion {
        switch level.topic {
        case .fractions:
            let pool = MathScaling.easierFractionDenominators(level.index)
            return fractionsQuestion(source: level.index,
                                     denominator: resolvedDenominator(source: level.index,
                                                                      pool: pool),
                                     route: .shuffled,
                                     step: step)
        case .percentages:
            let pool = MathScaling.earlierPercentages(level.index)
            return percentagesQuestion(source: level.index,
                                       percentage: resolvedPercentage(source: level.index,
                                                                      pool: pool),
                                       decimal: wantsDecimal())
        case .mixed:
            return supermixQuestion(step: step, forceTop: forceTop)
        default:
            let source = pickSourceLevel(forceTop: forceTop)
            return question(topic: level.topic, source: source, route: .shuffled, step: step)
        }
    }

    private func question(topic: MathTopic, source: Int, route: Route, step: Int) -> MathQuestion {
        switch topic {
        case .addition:
            return additionQuestion(source: source, route: route, step: step)
        case .subtraction:
            return subtractionQuestion(source: source, route: route, step: step)
        case .tables:
            return tablesQuestion(source: source, route: route, step: step)
        case .fractions:
            return fractionsQuestion(source: source,
                                     denominator: resolvedDenominator(source: source, pool: nil),
                                     route: route,
                                     step: step)
        case .percentages:
            return percentagesQuestion(source: source,
                                       percentage: resolvedPercentage(source: source, pool: nil),
                                       decimal: route == .fixed ? false : wantsDecimal())
        case .mixed:
            return supermixQuestion(step: step, forceTop: false)
        }
    }

    /// Last resort when the practised route cannot produce an answer that is
    /// still free. Stays on the session's operation and walks outward until
    /// the result is outside `forbidden`, so a block of six never has to reuse
    /// a number that is already sitting on a button.
    private func emergencyDistinct(avoiding forbidden: Set<AnswerValue>) -> MathQuestion {
        let source = level.index
        switch level.topic {
        case .subtraction:
            let take = max(1, source)
            for extra in 1..<120 {
                let left = take + extra
                let answer = left - take
                if forbidden.contains(AnswerValue("\(answer)")) { continue }
                return build(prompt: "\(left) − \(take) = ?",
                             answer: answer,
                             wrong: [answer + 1, answer - 1, answer + 2, left],
                             source: source,
                             kind: .subtraction)
            }
        case .tables:
            let table = max(1, source)
            for multiplier in 1..<120 {
                let answer = table * multiplier
                if forbidden.contains(AnswerValue("\(answer)")) { continue }
                return build(prompt: "\(table) × \(multiplier) = ?",
                             answer: answer,
                             wrong: [answer + table, answer + 1, answer - 1, table],
                             source: source,
                             kind: .multiplication)
            }
        case .fractions:
            let denominator = max(2, MathScaling.fractionDenominator(source))
            for factor in 1..<120 {
                let answer = factor
                if forbidden.contains(AnswerValue("\(answer)")) { continue }
                let whole = denominator * factor
                return build(prompt: "1/\(denominator) × \(whole) = ?",
                             answer: answer,
                             wrong: [answer + 1, answer - 1, whole, denominator],
                             source: source,
                             kind: .fraction)
            }
        case .percentages:
            let percentage = max(1, MathScaling.percentage(source))
            let base = Self.percentageBase(percentage)
            for factor in 1..<160 {
                let whole = base * factor
                let answer = whole * percentage / 100
                if forbidden.contains(AnswerValue("\(answer)")) { continue }
                return build(prompt: "\(percentage)% × \(whole) = ?",
                             answer: answer,
                             wrong: [answer + 1, answer - 1, answer + base, whole],
                             source: source,
                             kind: .percentage)
            }
        case .addition, .mixed:
            break
        }
        let add = max(1, level.topic == .mixed ? 2 : source)
        for other in 1..<160 {
            let answer = add + other
            if forbidden.contains(AnswerValue("\(answer)")) { continue }
            return build(prompt: "\(add) + \(other) = ?",
                         answer: answer,
                         wrong: [answer + 1, answer - 1, answer + 2, other],
                         source: source,
                         kind: .addition)
        }
        return emergencyQuestion()
    }

    /// Last-resort question, used only if every generator attempt failed
    /// validation. Always solvable and always has four distinct distractors.
    private func emergencyQuestion() -> MathQuestion {
        let a = random.int(in: 2...9)
        let b = random.int(in: 2...9)
        let answer = a + b
        return MathQuestion(
            prompt: "\(a) + \(b) = ?",
            correctAnswer: "\(answer)",
            distractors: [answer + 1, answer - 1, answer + 2, answer + 3].map(String.init),
            sourceLevel: 1,
            kind: .addition
        )
    }

    // MARK: - Addition

    private func additionQuestion(source: Int, route: Route, step: Int) -> MathQuestion {
        let add = source
        let other: Int
        let swapsSides: Bool
        switch route {
        case .fixed:
            // The fixed route: three groups of five, then round again. The
            // practised number always leads, so the pattern stays visible.
            other = PracticeRoute.additionOther(number: add, step: step)
            swapsSides = false
        case .shuffled:
            let ceiling = MathScaling.additionCeiling(source)
            other = cycle("add.\(source)", Array(1...ceiling)).next(random)
            // Sides swap so the practised number is not always on the left;
            // addition is commutative, so this is a genuine variation.
            swapsSides = random.bool()
        }
        let answer = add + other
        let (a, b) = swapsSides ? (other, add) : (add, other)
        // Real child errors, all close to the answer: counting slips (±1/±2),
        // forgetting to add, and adding the number twice.
        var wrong = [answer + 1, answer - 1, answer + 2, answer - 2, other, answer + add]
        if answer >= 15 { wrong += [answer + 10, answer - 10] }
        return build(prompt: "\(a) + \(b) = ?",
                     answer: answer,
                     wrong: wrong,
                     source: source,
                     kind: .addition)
    }

    // MARK: - Subtraction

    private func subtractionQuestion(source: Int, route: Route, step: Int) -> MathQuestion {
        let take = source
        let left: Int
        switch route {
        case .fixed:
            left = PracticeRoute.subtractionStart(number: take, step: step)
        case .shuffled:
            let ceiling = MathScaling.subtractionCeiling(source)
            left = cycle("sub.\(source)", Array(take...max(take, ceiling))).next(random)
        }
        // Never swapped: a subtraction is not commutative.
        let answer = left - take
        // Counting slips, forgetting to subtract, and subtracting twice.
        var wrong = [answer + 1, answer - 1, answer + 2, answer - 2, left, answer - take]
        if answer >= 12 { wrong += [answer + 10, answer - 10] }
        if left >= 10, take >= 10, left % 10 < take % 10 {
            // The classic column mistake: smaller digit taken from the larger
            // one per column (52 − 38 → 26 instead of 14).
            wrong.append((left / 10 - take / 10) * 10 + (take % 10 - left % 10))
        }
        return build(prompt: "\(left) − \(take) = ?",
                     answer: answer,
                     wrong: wrong,
                     source: source,
                     kind: .subtraction)
    }

    // MARK: - Tables

    /// Roughly 2% of multiplications become a "× 0 = 0" reminder. Never on the
    /// fixed route, which may not be interrupted.
    private static let zeroMultiplyChance = 0.02

    private func tablesQuestion(source: Int, route: Route, step: Int) -> MathQuestion {
        let table = min(GameConfig.maximumLevel, source)

        if route == .shuffled, random.double(in: 0..<1) < Self.zeroMultiplyChance {
            let prompt = random.bool() ? "\(table) × 0 = ?" : "0 × \(table) = ?"
            // The tempting mistakes: answering the number itself, or 1.
            return build(prompt: prompt,
                         answer: 0,
                         wrong: [table, 1, table + 1, 2, max(2, table * 2), table * 3],
                         source: source,
                         kind: .multiplication)
        }

        let multiplier: Int
        let swapsSides: Bool
        switch route {
        case .fixed:
            // The endless ×1 … ×12 loop, always with the table in front.
            multiplier = PracticeRoute.tableMultiplier(step: step)
            swapsSides = false
        case .shuffled:
            // Every multiplier exactly once per lap, and the table may stand on
            // either side of the ×.
            multiplier = cycle("table", Array(1...12)).next(random)
            swapsSides = random.bool()
        }
        let answer = table * multiplier
        let (a, b) = swapsSides ? (multiplier, table) : (table, multiplier)
        // Neighbouring multiples in the SAME table and the neighbouring TABLE
        // with the same multiplier — exactly the confusions children have.
        let wrong = [table * (multiplier + 1), table * max(1, multiplier - 1),
                     (table + 1) * multiplier, max(0, table - 1) * multiplier,
                     answer + 1, answer - 1, answer + table, answer + 10]
        return build(prompt: "\(a) × \(b) = ?",
                     answer: answer,
                     wrong: wrong,
                     source: source,
                     kind: .multiplication)
    }

    // MARK: - Fractions

    /// The denominator this question works with. Premium levels review the
    /// friendly denominators on big round wholes; `pool` is set only by Mixed,
    /// which reviews the easier denominators that divide this one.
    private func resolvedDenominator(source: Int, pool: [Int]?) -> Int {
        if source > GameConfig.freeLevelCount {
            return random.element(MathScaling.premiumFractionDenominators) ?? 4
        }
        if let pool, !pool.isEmpty {
            return random.weightedHardPick(pool) ?? MathScaling.fractionDenominator(source)
        }
        return MathScaling.fractionDenominator(source)
    }

    private func fractionsQuestion(source: Int,
                                   denominator: Int,
                                   route: Route,
                                   step: Int) -> MathQuestion {
        // "Single" keeps every question to one part of a whole; "Multiple"
        // opens up the forms that need more than one part.
        var forms: [String] = ["fractionOf", "fractionOf"]
        if denominator <= 5 { forms.append("equivalent") }
        if route == .shuffled, denominator >= 3, denominator <= 12 {
            forms += ["addSame", "subSame"]
        }

        switch random.element(forms) ?? "fractionOf" {
        case "equivalent":
            // "1/4 = ?/12" — the numerator that keeps the fraction equal.
            let scale = random.int(in: 2...3)
            let answer = scale
            return build(prompt: "1/\(denominator) = ?/\(denominator * scale)",
                         answer: answer,
                         wrong: [1, denominator, scale + 1, scale + 2,
                                 denominator * scale, denominator + scale],
                         source: source,
                         kind: .fraction)

        case "addSame":
            let n1 = random.int(in: 1...(denominator - 2))
            let n2 = random.int(in: 1...(denominator - 1 - n1))
            let sum = n1 + n2
            let correct = "\(sum)/\(denominator)"
            // Adding the denominators too, and being one part out.
            let wrong = ["\(sum)/\(denominator * 2)",
                         "\(min(denominator - 1, sum + 1))/\(denominator)",
                         "\(max(1, sum - 1))/\(denominator)",
                         "\(n1)/\(denominator)",
                         "\(n2)/\(denominator)",
                         "\(sum)/\(denominator + 1)"]
            return buildText(prompt: "\(n1)/\(denominator) + \(n2)/\(denominator) = ?",
                             answer: correct,
                             wrong: wrong,
                             source: source,
                             kind: .fraction)

        case "subSame":
            let n1 = random.int(in: 2...(denominator - 1))
            let n2 = random.int(in: 1...(n1 - 1))
            let difference = n1 - n2
            let correct = "\(difference)/\(denominator)"
            let wrong = ["\(difference)/\(max(2, denominator - n2))",
                         "\(min(denominator - 1, difference + 1))/\(denominator)",
                         "\(n1 + n2)/\(denominator)",
                         "\(n2)/\(denominator)",
                         "\(n1)/\(denominator)",
                         "\(difference)/\(denominator + 1)"]
            return buildText(prompt: "\(n1)/\(denominator) − \(n2)/\(denominator) = ?",
                             answer: correct,
                             wrong: wrong,
                             source: source,
                             kind: .fraction)

        default:
            // "3/8 × 40 = ?" — always divide first, so the answer stays whole
            // and the intermediate step is the one the child actually takes.
            let factor: Int
            if source > GameConfig.freeLevelCount {
                let target = max(2, MathScaling.premiumCeiling(source) / denominator)
                factor = random.int(in: max(1, target - 2)...(target + 2))
            } else if route == .fixed {
                // A shuffled factor, so a fixed route does not simply hand out
                // 1, 2, 3, 4 as its answers.
                factor = cycle("fraction.whole", PracticeRoute.wholeFactors).next(random)
            } else {
                factor = random.int(in: 1...6)
            }
            let whole = denominator * factor
            let unit = whole / denominator
            // "Single" is always the unit fraction; "Multiple" mostly takes
            // several parts but still drops back to one about a quarter of the
            // time, so a single part never stops being practised.
            let numerator: Int
            if route == .fixed || denominator <= 2 {
                numerator = 1
            } else if random.double(in: 0..<1) < 0.25 {
                numerator = 1
            } else {
                numerator = random.int(in: 2...(denominator - 1))
            }
            let answer = unit * numerator
            // Forgot to multiply (unit), numerator one off, the complement.
            let wrong = [unit, whole, answer + unit, answer - unit,
                         whole - answer, answer + 1, answer - 1, answer + 10]
            return build(prompt: "\(numerator)/\(denominator) × \(whole) = ?",
                         answer: answer,
                         wrong: wrong,
                         source: source,
                         kind: .fraction)
        }
    }

    // MARK: - Percentages

    private static let percentageFraction: [Int: String] = [
        50: "1/2", 25: "1/4", 75: "3/4", 20: "1/5", 10: "1/10", 5: "1/20",
        80: "4/5", 90: "9/10"
    ]

    /// The smallest whole that makes "p% of whole" a whole number.
    private static func percentageBase(_ p: Int) -> Int {
        max(1, 100 / gcd(100, p))
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }

    private func resolvedPercentage(source: Int, pool: [Int]?) -> Int {
        if source > GameConfig.freeLevelCount {
            return random.element(MathScaling.premiumPercentages) ?? 25
        }
        if let pool, !pool.isEmpty {
            return random.weightedHardPick(pool) ?? MathScaling.percentage(source)
        }
        return MathScaling.percentage(source)
    }

    /// Whether this percentage question lands behind the decimal point.
    /// "Decimal" puts exactly two of every five questions there; Mixed spreads
    /// them thinner at one in five. Every other route stays whole.
    private func wantsDecimal() -> Bool {
        switch mode {
        case .order:  return false
        case .random: return cycle("decimal.random", [1, 1, 0, 0, 0]).next(random) == 1
        case .mixed:  return cycle("decimal.mixed", [1, 0, 0, 0, 0]).next(random) == 1
        }
    }

    private func percentagesQuestion(source: Int,
                                     percentage: Int,
                                     decimal: Bool) -> MathQuestion {
        // A friendly percentage occasionally becomes a fraction conversion.
        if !decimal,
           let fraction = Self.percentageFraction[percentage],
           random.double(in: 0..<1) < 0.15 {
            let others = MathScaling.percentageLevels
                .filter { $0 != percentage }
                .prefix(12)
                .map { "\($0)%" }
            return buildText(prompt: "\(fraction) = ?",
                             answer: "\(percentage)%",
                             wrong: random.shuffled(Array(others)),
                             source: source,
                             kind: .percentage)
        }

        if decimal, let question = decimalPercentageQuestion(percentage: percentage,
                                                             source: source) {
            return question
        }

        let base = Self.percentageBase(percentage)
        let factor: Int
        if source > GameConfig.freeLevelCount {
            let target = max(1, MathScaling.premiumCeiling(source) / base)
            factor = random.int(in: max(1, target - 2)...(target + 2))
        } else {
            // The whole always divides cleanly, and its factor is shuffled
            // rather than drawn fresh, so the answers do not simply climb.
            factor = cycle("percentage.whole", PracticeRoute.percentageFactors).next(random)
        }
        let whole = base * factor
        let answer = whole * percentage / 100

        return build(prompt: "\(percentage)% × \(whole) = ?",
                     answer: answer,
                     wrong: wholePercentageDistractors(percentage: percentage,
                                                       whole: whole,
                                                       answer: answer),
                     source: source,
                     kind: .percentage)
    }

    /// Neighbouring percentages of the SAME whole (25% vs 50% mix-ups), the
    /// complement, and counting slips.
    private func wholePercentageDistractors(percentage: Int,
                                            whole: Int,
                                            answer: Int) -> [Int] {
        let neighbours = MathScaling.percentageLevels
            .filter { $0 != percentage && whole * $0 % 100 == 0 }
            .sorted { abs($0 - percentage) < abs($1 - percentage) }
            .prefix(3)
            .map { whole * $0 / 100 }
        return neighbours + [whole - answer, answer + 1, answer - 1,
                             answer + 10, answer * 2]
    }

    /// A percentage question whose answer lands behind the decimal point.
    ///
    /// Everything is counted in hundredths as an integer, so the answer is
    /// exact by construction. Only wholes that produce one of the allowed
    /// fractional parts are eligible — a tenth, a quarter or a rounded third —
    /// and the answer stays small enough to check by hand. Nil when this
    /// percentage cannot produce such an answer at all, in which case the
    /// caller falls back to a whole one.
    private func decimalPercentageQuestion(percentage: Int, source: Int) -> MathQuestion? {
        guard percentage > 0 else { return nil }
        // The whole stays in the same family as the one a whole-number question
        // would use, so a decimal round is about the comma and not about
        // suddenly much bigger multiplication.
        let familyCeiling = source > GameConfig.freeLevelCount
            ? MathScaling.premiumCeiling(source)
            : Self.percentageBase(percentage) * 8
        let highestWhole = max(1, min(familyCeiling,
                                      DecimalAnswer.maximumHundredths / percentage))
        var candidates: [Int] = []
        for whole in 1...highestWhole {
            let hundredths = whole * percentage
            guard DecimalAnswer.allowedFractionalParts.contains(hundredths % 100) else { continue }
            candidates.append(whole)
        }
        guard let whole = random.element(candidates) else { return nil }

        let hundredths = whole * percentage
        // The mistakes a decimal answer actually attracts: dropping the comma
        // (rounding down, and rounding to the nearest), being one tenth out,
        // and being one whole out.
        let wrong = [(hundredths / 100) * 100,
                     ((hundredths + 50) / 100) * 100,
                     hundredths + 10,
                     hundredths - 10,
                     hundredths + 100,
                     hundredths - 100,
                     whole * 100 - hundredths]
        return buildDecimal(prompt: "\(percentage)% × \(whole) = ?",
                            answer: hundredths,
                            wrong: wrong,
                            source: source,
                            kind: .percentage)
    }

    // MARK: - Supermix

    /// Harder operations carry more weight, so a mixed level keeps climbing.
    private static let mixedWeights: [(QuestionKind, Double)] = [
        (.addition, 12), (.subtraction, 16), (.multiplication, 24),
        (.fraction, 22), (.percentage, 26)
    ]

    private func supermixQuestion(step: Int, forceTop: Bool) -> MathQuestion {
        // Only the operations the chosen Supermix variant covers are in play.
        let allowed = Self.mixedWeights.filter { kind, _ in
            mixedVariant.topics.contains(kind.topic)
        }
        let pool = allowed.isEmpty ? Self.mixedWeights : allowed
        let total = pool.reduce(0) { $0 + $1.1 }
        var threshold = random.double(in: 0..<total)
        var chosen = pool[0].0
        for (kind, weight) in pool {
            threshold -= weight
            if threshold < 0 { chosen = kind; break }
        }
        // Every operation climbs by the rules of its own menu, at a sub-level
        // weighted toward the top of the range.
        let source = pickSourceLevel(forceTop: forceTop)
        switch chosen {
        case .addition:
            return additionQuestion(source: source, route: .shuffled, step: step)
        case .subtraction:
            return subtractionQuestion(source: source, route: .shuffled, step: step)
        case .multiplication:
            return tablesQuestion(source: source, route: .shuffled, step: step)
        case .fraction:
            return fractionsQuestion(source: source,
                                     denominator: resolvedDenominator(source: source, pool: nil),
                                     route: .shuffled,
                                     step: step)
        case .percentage:
            return percentagesQuestion(source: source,
                                       percentage: resolvedPercentage(source: source, pool: nil),
                                       decimal: false)
        }
    }

    // MARK: - Assembly

    /// Builds a numeric question: drops negatives and duplicates, then pads
    /// with near-miss offsets until there are always enough wrong answers.
    private func build(prompt: String,
                       answer: Int,
                       wrong: [Int],
                       source: Int,
                       kind: QuestionKind) -> MathQuestion {
        var seen: Set<Int> = [answer]
        var distractors: [Int] = []
        for candidate in wrong where candidate >= 0 && !seen.contains(candidate) {
            seen.insert(candidate)
            distractors.append(candidate)
        }
        // Pad with the closest unused offsets, so even a tiny answer like 0
        // still yields four distinct, plausible neighbours.
        var offset = 1
        while distractors.count < 12 && offset < 40 {
            for candidate in [answer + offset, answer - offset] where candidate >= 0 {
                if !seen.contains(candidate) {
                    seen.insert(candidate)
                    distractors.append(candidate)
                }
            }
            offset += 1
        }
        return MathQuestion(prompt: prompt,
                            correctAnswer: "\(answer)",
                            distractors: random.shuffled(distractors).map(String.init),
                            sourceLevel: source,
                            kind: kind)
    }

    /// Builds a question whose answer sits behind the decimal point. Values are
    /// carried in hundredths right up to the moment they become text, so the
    /// cards read 2,5 and never 2.4999999.
    private func buildDecimal(prompt: String,
                              answer: Int,
                              wrong: [Int],
                              source: Int,
                              kind: QuestionKind) -> MathQuestion {
        var seen: Set<Int> = [answer]
        var distractors: [Int] = []
        for candidate in wrong where candidate >= 0 && !seen.contains(candidate) {
            seen.insert(candidate)
            distractors.append(candidate)
        }
        // Pad with neighbouring tenths, so a padded card is the same kind of
        // number as the real answer rather than an obvious outsider.
        var offset = 10
        while distractors.count < 12 && offset <= 400 {
            for candidate in [answer + offset, answer - offset] where candidate > 0 {
                if !seen.contains(candidate) {
                    seen.insert(candidate)
                    distractors.append(candidate)
                }
            }
            offset += 10
        }
        return MathQuestion(prompt: prompt,
                            correctAnswer: DecimalAnswer.text(hundredths: answer),
                            distractors: random.shuffled(distractors)
                                .map { DecimalAnswer.text(hundredths: $0) },
                            sourceLevel: source,
                            kind: kind)
    }

    /// Builds a question whose answers are text (fractions, percentages).
    private func buildText(prompt: String,
                           answer: String,
                           wrong: [String],
                           source: Int,
                           kind: QuestionKind) -> MathQuestion {
        let correct = AnswerValue(answer)
        var seen: Set<AnswerValue> = [correct]
        var distractors: [String] = []
        for candidate in wrong {
            let value = AnswerValue(candidate)
            guard value != correct, !seen.contains(value) else { continue }
            seen.insert(value)
            distractors.append(candidate)
        }
        // Pad so even a tiny denominator (thirds) can fill a four-card round.
        // Fractions get neighbouring parts and neighbouring denominators;
        // percentages get nearby percentages. Both stay plausible.
        if distractors.count < 8 {
            for candidate in Self.padding(for: answer) {
                guard distractors.count < 12 else { break }
                let value = AnswerValue(candidate)
                guard value != correct, !seen.contains(value) else { continue }
                seen.insert(value)
                distractors.append(candidate)
            }
        }
        // The visible board only needs a handful of wrong answers, but boundary
        // values such as 100% or 1/2 still have to pad out to a full set.
        if distractors.count < 12, answer.hasSuffix("%"),
           let percentage = Int(answer.dropLast()) {
            for delta in 1...100 {
                for number in [percentage - delta, percentage + delta]
                    where number >= 0 && number <= 100 {
                    guard distractors.count < 12 else { break }
                    let candidate = "\(number)%"
                    let value = AnswerValue(candidate)
                    guard value != correct, !seen.contains(value) else { continue }
                    seen.insert(value)
                    distractors.append(candidate)
                }
                if distractors.count >= 12 { break }
            }
        }
        if distractors.count < 12, answer.contains("/") {
            let parts = answer.split(separator: "/", maxSplits: 1).compactMap { Int($0) }
            if parts.count == 2, parts[1] > 0 {
                for denominator in 2...(parts[1] + 12) {
                    for numerator in 1..<denominator {
                        guard distractors.count < 12 else { break }
                        let candidate = "\(numerator)/\(denominator)"
                        let value = AnswerValue(candidate)
                        guard value != correct, !seen.contains(value) else { continue }
                        seen.insert(value)
                        distractors.append(candidate)
                    }
                    if distractors.count >= 12 { break }
                }
            }
        }
        return MathQuestion(prompt: prompt,
                            correctAnswer: answer,
                            distractors: random.shuffled(distractors),
                            sourceLevel: source,
                            kind: kind)
    }

    /// Plausible neighbours for a textual answer, used only when the
    /// hand-written near-misses did not yield enough distinct options.
    private static func padding(for answer: String) -> [String] {
        if answer.hasSuffix("%") {
            guard let value = Int(answer.dropLast()) else { return [] }
            return [value + 5, value - 5, value + 10, value - 10,
                    value + 15, value - 15, value + 20, value - 20,
                    value + 25, value - 25, value + 50, value / 2, value * 2]
                .filter { $0 > 0 && $0 <= 100 && $0 != value }
                .map { "\($0)%" }
        }
        let parts = answer.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let numerator = Int(parts[0]),
              let denominator = Int(parts[1]), denominator > 1 else { return [] }
        var candidates: [String] = []
        for n in 1..<max(2, denominator) where n != numerator {
            candidates.append("\(n)/\(denominator)")
        }
        for d in [denominator + 1, denominator + 2, denominator * 2] {
            candidates.append("\(numerator)/\(d)")
        }
        return candidates
    }
}
