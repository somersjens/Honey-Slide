//
//  MathQuestion.swift
//  Elephant Challenge: Math Memory
//
//  The value type a round is built from, plus the answer-equality rules that
//  guarantee a question has exactly one correct card.
//

import Foundation

public struct MathQuestion: Equatable, Codable, Sendable {
    /// The sum as shown on the question card, e.g. "7 × 8 = ?".
    public let prompt: String
    /// The one correct answer, as shown on its card.
    public let correctAnswer: String
    /// Plausible wrong answers. Unique, and never equal in value to the
    /// correct answer (see `AnswerValue`).
    public let distractors: [String]
    /// Which sub-level this question was drawn from (1-based).
    public let sourceLevel: Int
    /// Which operation it practises — used to avoid two identical kinds of
    /// question in a row.
    public let kind: QuestionKind

    public init(prompt: String,
                correctAnswer: String,
                distractors: [String],
                sourceLevel: Int,
                kind: QuestionKind) {
        self.prompt = prompt
        self.correctAnswer = correctAnswer
        self.distractors = distractors
        self.sourceLevel = sourceLevel
        self.kind = kind
    }

    /// The completed form shown after a mistake. Replacing the placeholder —
    /// rather than appending an answer — also handles forms such as
    /// `1/4 = ?/12`, where the answer belongs inside the expression.
    public var solvedPrompt: String {
        prompt.replacingOccurrences(of: "?", with: correctAnswer)
    }

    /// A question is only ever shown when this holds: a non-empty prompt, a
    /// non-empty answer, and distractors that are unique and all genuinely
    /// wrong. `QuestionGenerator` asserts this before handing a question out.
    public func isValid(requiredDistractors: Int) -> Bool {
        guard !prompt.isEmpty, !correctAnswer.isEmpty else { return false }
        guard distractors.count >= requiredDistractors else { return false }
        let correct = AnswerValue(correctAnswer)
        var seen: Set<AnswerValue> = [correct]
        for distractor in distractors.prefix(requiredDistractors) {
            guard !distractor.isEmpty else { return false }
            let value = AnswerValue(distractor)
            if value == correct { return false }
            if seen.contains(value) { return false }
            seen.insert(value)
        }
        return true
    }
}

public enum QuestionKind: String, Codable, Sendable, CaseIterable {
    case addition
    case subtraction
    case multiplication
    case fraction
    case percentage

    /// The topic this kind of question belongs to, used to decide which kinds
    /// a Supermix variant is allowed to draw.
    public var topic: MathTopic {
        switch self {
        case .addition:       return .addition
        case .subtraction:    return .subtraction
        case .multiplication: return .tables
        case .fraction:       return .fractions
        case .percentage:     return .percentages
        }
    }
}

// MARK: - Answer equality

/// Answers are compared by *meaning*, not by spelling, so a distractor can
/// never accidentally be a second correct answer: "6", "06" and "6/1" all
/// collapse to the same value, and "50%" never collides with the number 50.
public struct AnswerValue: Hashable, Sendable, Comparable {
    private enum Form: Hashable {
        /// A rational number in lowest terms.
        case rational(numerator: Int, denominator: Int)
        /// A percentage, in hundredths of a percent so 12.5% stays exact.
        case percent(Int)
        /// Anything we cannot parse falls back to its literal text.
        case text(String)
    }

    private let form: Form

    public init(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)

        if trimmed.hasSuffix("%") {
            let body = String(trimmed.dropLast())
            if let hundredths = Self.hundredths(body) {
                form = .percent(hundredths)
                return
            }
            form = .text(trimmed)
            return
        }

        if trimmed.contains("/") {
            let parts = trimmed.split(separator: "/", maxSplits: 1).map(String.init)
            if parts.count == 2,
               let numerator = Int(parts[0]),
               let denominator = Int(parts[1]),
               denominator != 0 {
                let reduced = Self.reduced(numerator, denominator)
                form = .rational(numerator: reduced.0, denominator: reduced.1)
                return
            }
            form = .text(trimmed)
            return
        }

        if let value = Int(trimmed) {
            form = .rational(numerator: value, denominator: 1)
            return
        }

        // A decimal answer ("2,5" or "2.5") is a rational like any other, so it
        // sorts among the whole numbers and never collides with one by
        // accident: 2,50 and 2,5 collapse to the same value.
        if trimmed.contains(",") || trimmed.contains("."),
           let hundredths = Self.hundredths(trimmed) {
            let reduced = Self.reduced(hundredths, 100)
            form = .rational(numerator: reduced.0, denominator: reduced.1)
            return
        }

        form = .text(trimmed)
    }

    /// Parses "12", "12.5" or "12,5" into hundredths. Used for percent answers
    /// and for the decimal answers the Percentages "Decimal" button produces.
    private static func hundredths(_ text: String) -> Int? {
        let normalized = text.replacingOccurrences(of: ",", with: ".")
        let parts = normalized.split(separator: ".", maxSplits: 1).map(String.init)
        guard let whole = Int(parts.first ?? "") else { return nil }
        guard parts.count > 1 else { return whole * 100 }
        var digits = parts[1]
        if digits.count == 1 { digits += "0" }
        guard let fraction = Int(digits.prefix(2)) else { return nil }
        return whole * 100 + (whole < 0 ? -fraction : fraction)
    }

    private static func reduced(_ numerator: Int, _ denominator: Int) -> (Int, Int) {
        let sign = denominator < 0 ? -1 : 1
        let n = numerator * sign
        let d = denominator * sign
        let divisor = max(1, gcd(abs(n), abs(d)))
        return (n / divisor, d / divisor)
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        b == 0 ? a : gcd(b, a % b)
    }

    /// The numeric worth of this answer, used to lay the cards out in order.
    /// Unparseable text sorts last but stays stable relative to its peers.
    private var sortKey: Double? {
        switch form {
        case .rational(let numerator, let denominator):
            return Double(numerator) / Double(denominator)
        case .percent(let hundredths):
            return Double(hundredths) / 100
        case .text:
            return nil
        }
    }

    public static func < (lhs: AnswerValue, rhs: AnswerValue) -> Bool {
        switch (lhs.sortKey, rhs.sortKey) {
        case let (l?, r?): return l < r
        case (nil, _?):    return false
        case (_?, nil):    return true
        case (nil, nil):   return false
        }
    }
}
