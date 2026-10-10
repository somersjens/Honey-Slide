//
//  RoundFactory.swift
//  Elephant Challenge: Math Memory
//
//  Builds one complete round: the question and the six answer buttons.
//
//  The whole sequence is composed before the first sum is shown, one
//  ten-question stage at a time. A stage starts with six different answers.
//  After a correct answer only that answer's button receives a new value; the
//  other five stay exactly where they are. The new value belongs to a question
//  waiting later in the stage whenever one is still needed, so every upcoming
//  question always has its answer on the board. A stage boundary may replace
//  all six values at once.
//

import Foundation

// MARK: - Answer card

public struct AnswerOption: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let text: String
    public let isCorrect: Bool

    public init(id: UUID = UUID(), text: String, isCorrect: Bool) {
        self.id = id
        self.text = text
        self.isCorrect = isCorrect
    }
}

// MARK: - Round

public struct GameRound: Identifiable, Equatable, Sendable {
    public let id: UUID
    /// 1-based position in the session.
    public let number: Int
    public let question: MathQuestion
    /// Exactly one option has `isCorrect == true`.
    public let options: [AnswerOption]
    public init(id: UUID = UUID(),
                number: Int,
                question: MathQuestion,
                options: [AnswerOption]) {
        self.id = id
        self.number = number
        self.question = question
        self.options = options
    }

    public var correctOption: AnswerOption? {
        options.first { $0.isCorrect }
    }
}

// MARK: - Factory

public final class RoundFactory {
    private struct PlannedRound {
        let question: MathQuestion
        let options: [AnswerOption]
    }

    private let generator: QuestionGenerator
    private let random: RandomSource
    /// One identity per button for the whole session. The label on a button
    /// changes; the button itself does not, so SwiftUI does not rebuild it
    /// after every answer.
    private let slotIDs: [UUID]
    private var plans: [Int: PlannedRound] = [:]
    private var sequenceOrigin: Int?

    public init(level: MathLevel,
                mixedVariant: MixedVariant = .all,
                mode: PracticeMode = .mixed,
                seed: UInt64? = nil) {
        let random = RandomSource(seed: seed)
        self.random = random
        self.generator = QuestionGenerator(level: level,
                                           mode: mode,
                                           mixedVariant: mixedVariant,
                                           random: random)
        self.slotIDs = (0..<GameConfig.answerBubbleCount).map { _ in UUID() }
    }

    public func reset() {
        generator.reset()
        plans.removeAll(keepingCapacity: true)
        sequenceOrigin = nil
    }

    /// Composes `count` rounds, starting at `first`, before play begins.
    /// Stages are completed even when `count` stops in the middle of one, so
    /// lazy runway replenishment never creates a second answer sequence.
    public func prepareSequence(startingAt first: Int, count: Int) {
        reset()
        let origin = max(1, first)
        sequenceOrigin = origin
        guard count > 0 else { return }
        ensurePlanned(through: origin + count - 1)
    }

    /// Builds the round for a given 1-based round number. The question and its
    /// button assignment were decided when the stage was composed.
    public func makeRound(number: Int) -> GameRound {
        if sequenceOrigin == nil { sequenceOrigin = number }
        ensurePlanned(through: number)
        let planned = plans[number] ?? planFallback(number: number)
        return GameRound(number: number,
                         question: planned.question,
                         options: planned.options)
    }

    private func ensurePlanned(through last: Int) {
        let origin = sequenceOrigin ?? last
        if sequenceOrigin == nil { sequenceOrigin = origin }
        var next = plans.keys.max().map { $0 + 1 } ?? origin
        if plans.isEmpty { next = origin }
        while next <= last {
            let stageEnd = ((next - 1) / GameConfig.questionsPerStage + 1)
                * GameConfig.questionsPerStage
            planStage(startingAt: next, endingAt: stageEnd)
            next = stageEnd + 1
        }
    }

    /// Builds one complete (or, after restoring a paused game, partial) stage.
    ///
    /// The first six questions seed the six slots. Their play order is
    /// shuffled. Each of the first four answers then installs one new question
    /// at the back of that queue. Once all ten questions have been supplied,
    /// the used slot still gets a fresh distractor so the physical feedback is
    /// consistent, but the other five slots remain untouched.
    private func planStage(startingAt first: Int, endingAt last: Int) {
        let width = GameConfig.answerBubbleCount
        let roundCount = max(0, last - first + 1)
        guard roundCount > 0 else { return }

        let openingQuestionCount = min(width, roundCount)
        var openingQuestions: [MathQuestion] = []
        var openingAnswers: Set<AnswerValue> = []
        while openingQuestions.count < openingQuestionCount {
            let question = nextDistinctQuestion(avoiding: openingAnswers)
            openingQuestions.append(question)
            openingAnswers.insert(AnswerValue(question.correctAnswer))
        }

        var pendingQuestions = random.shuffled(openingQuestions)
        var board = openingQuestions.map(\.correctAnswer)
        while board.count < width {
            board.append(freshFiller(avoiding: Set(board.map(AnswerValue.init)),
                                     preferred: openingQuestions.flatMap(\.distractors)))
        }
        board.sort { AnswerValue($0) < AnswerValue($1) }

        for offset in 0..<roundCount {
            guard !pendingQuestions.isEmpty else { break }
            let question = pendingQuestions.removeFirst()
            let correct = AnswerValue(question.correctAnswer)
            guard let correctSlot = board.firstIndex(where: { AnswerValue($0) == correct }) else {
                plans[first + offset] = planFallback(number: first + offset)
                continue
            }

            let options = board.enumerated().map { index, text in
                AnswerOption(id: slotIDs[index],
                             text: text,
                             isCorrect: index == correctSlot)
            }
            plans[first + offset] = PlannedRound(question: question, options: options)

            // There is no following board to update after the final question.
            guard offset + 1 < roundCount else { continue }

            let supplied = offset + 1 + pendingQuestions.count
            if supplied < roundCount {
                let replacementQuestion = nextDistinctQuestion(
                    avoiding: Set(board.map(AnswerValue.init))
                )
                board[correctSlot] = replacementQuestion.correctAnswer
                pendingQuestions.append(replacementQuestion)
            } else {
                board[correctSlot] = freshFiller(
                    avoiding: Set(board.map(AnswerValue.init)),
                    preferred: question.distractors
                )
            }
        }
    }

    private func nextDistinctQuestion(avoiding forbidden: Set<AnswerValue>) -> MathQuestion {
        let generated = generator.next(requiredDistractors: GameConfig.distractorCount,
                                       avoiding: forbidden)
        if !forbidden.contains(AnswerValue(generated.correctAnswer)) { return generated }
        return syntheticQuestion(avoiding: forbidden)
    }

    /// Gives an already-spent slot a visibly new value when no later question
    /// needs that slot. Prefer a believable near-miss from the question; the
    /// numeric walk is only a defensive fallback for an exhausted list.
    private func freshFiller(avoiding forbidden: Set<AnswerValue>,
                             preferred: [String]) -> String {
        if let candidate = preferred.first(where: { !forbidden.contains(AnswerValue($0)) }) {
            return candidate
        }
        var value = 0
        while forbidden.contains(AnswerValue("\(value)")) { value += 1 }
        return "\(value)"
    }

    /// A plain sum whose result is still free. Used only when the practised
    /// route cannot supply another distinct answer for this board.
    private func syntheticQuestion(avoiding forbidden: Set<AnswerValue>) -> MathQuestion {
        var answer = 0
        while forbidden.contains(AnswerValue("\(answer)")) { answer += 1 }
        return MathQuestion(prompt: "0 + \(answer) = ?",
                            correctAnswer: "\(answer)",
                            distractors: (1...6).map { String(answer + $0) },
                            sourceLevel: 1,
                            kind: .addition)
    }

    /// Only reached when a stage could not be filled. Keeps the session
    /// playable with the same six buttons rather than failing the round.
    private func planFallback(number: Int) -> PlannedRound {
        let question = generator.next(requiredDistractors: GameConfig.distractorCount,
                                      avoiding: [])
        var texts = [question.correctAnswer]
        for distractor in question.distractors where texts.count < slotIDs.count {
            let values = Set(texts.map(AnswerValue.init))
            if !values.contains(AnswerValue(distractor)) { texts.append(distractor) }
        }
        while texts.count < slotIDs.count {
            texts.append(freshFiller(avoiding: Set(texts.map(AnswerValue.init)),
                                     preferred: []))
        }
        let shuffled = random.shuffled(texts)
        let correct = AnswerValue(question.correctAnswer)
        let options = slotIDs.enumerated().map { index, id in
            AnswerOption(id: id,
                         text: shuffled[index],
                         isCorrect: AnswerValue(shuffled[index]) == correct)
        }
        let planned = PlannedRound(question: question, options: options)
        plans[number] = planned
        return planned
    }
}
