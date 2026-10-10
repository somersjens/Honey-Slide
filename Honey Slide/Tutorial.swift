//
//  Tutorial.swift
//  Flying Penguin
//
//  The guided first run teaches the seven things a flight is made of: dragging
//  the penguin, tapping it to a height, diving under a set that holds no answer,
//  flying through the right hoop, tapping that hoop early for turbo, what a
//  wrong hoop costs — and that the life it costs comes straight back.
//
//  Nothing here re-implements a rule. The tutorial only decides *which* sets are
//  offered while a step is being taught, *what* is being said about it, and what
//  a mistake is allowed to cost during the lesson; the sum, the score and the
//  lives come out of `MemoryGame` exactly as they do in a normal session, which
//  is what makes the lesson true.
//

import SwiftUI
import Combine

/// The tutorial card and the HUD both publish geometry in this screen-wide
/// coordinate space, allowing lesson feedback to travel exactly between them.
enum TutorialMessageCoordinateSpace {
    static let game = "game"
}

struct TutorialMessageIconFrameKey: PreferenceKey {
    static let defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

// MARK: - Steps

/// The seven taught beats of a guided run, in the order they are taught.
enum TutorialStep: Int, Equatable, CaseIterable {
    /// Hold the penguin and drag it up and down.
    case dragToFly = 1
    /// Tap above and below the penguin instead of dragging it.
    case tapToFly
    /// A set with no right answer in it: dive underneath the lot.
    case diveUnder
    /// One of the three hoops carries the answer. Fly through it.
    case correctHoop
    /// Tap that hoop before the cone for the doubled, accelerated approach.
    case turbo
    /// What a wrong hoop costs.
    case wrongHoop
    /// Handing the game over.
    case goodLuck

    var messageKey: String { "tutorial.step\(rawValue)" }

    /// One glyph per lesson, so a step is recognisable before it is read.
    var symbolName: String {
        switch self {
        case .dragToFly:   return "hand.draw.fill"
        case .tapToFly:    return "hand.tap.fill"
        case .diveUnder:   return "arrow.down.circle.fill"
        case .correctHoop: return "checkmark.circle.fill"
        case .turbo:       return "bolt.fill"
        case .wrongHoop:   return "heart.slash.fill"
        case .goodLuck:    return "play.circle.fill"
        }
    }
}

// MARK: - What a step changes about the game

/// Everything the playing field and the view model have to know about the step
/// being taught, in one value. A default-constructed plan is an ordinary,
/// unguided session, which is what a finished tutorial leaves behind.
struct TutorialPlan: Equatable {
    var step: TutorialStep?

    /// No hoops at all: the first two steps are only about flying.
    var hidesHoops = false
    /// The water is off limits while movement is being taught.
    var blocksDiving = false
    /// Watch for the penguin being dragged to a low and to a high point.
    var tracksDrag = false
    /// Watch for a tap under and a tap above the penguin.
    var tracksTaps = false
    /// Every hoop in the set is wrong, so the only way through is underneath.
    var forcesNoCorrectAnswer = false
    /// Exactly one of the three hoops carries the answer.
    var forcesCorrectAnswer = false
    /// Put that answer in the top hoop. The turbo lesson asks for a tap on it
    /// while the cone, the wake and the message all live along the bottom of
    /// the screen; from the lowest lane the whole lesson piles up in one
    /// corner, and from the top it has room to be read.
    var putsAnswerOnTop = false
    /// Pulse the right hoop.
    var highlightsTurbo = false
    /// Freeze the next set as it arrives until the right hoop is tapped.
    var holdsForTurbo = false
    /// Put a broken-heart marker on each of the two wrong hoops.
    var marksWrongHoops = false
    /// Nothing a mistake does during this step may cost a life.
    var preventsLifeLoss = false
    /// Only passing underneath is free; a wrong hoop costs a life as it should.
    var preventsBypassLifeLoss = false
    /// The player has missed the dive lesson twice. The field demonstrates the
    /// complete move on the next set: down, underneath, and back into the air.
    var demonstratesDive = false

    var isRunning: Bool { step != nil }

    /// The rules that belong to a step. `holdsForTurbo` is layered on top by the
    /// director once the player has had their three free sets.
    static func plan(for step: TutorialStep?) -> TutorialPlan {
        var plan = TutorialPlan()
        plan.step = step
        switch step {
        case .dragToFly:
            plan.hidesHoops = true
            plan.blocksDiving = true
            plan.tracksDrag = true
        case .tapToFly:
            plan.hidesHoops = true
            plan.blocksDiving = true
            plan.tracksTaps = true
        case .diveUnder:
            plan.forcesNoCorrectAnswer = true
            plan.preventsLifeLoss = true
        case .correctHoop:
            plan.forcesCorrectAnswer = true
            plan.preventsLifeLoss = true
        case .turbo:
            plan.forcesCorrectAnswer = true
            plan.putsAnswerOnTop = true
            plan.preventsLifeLoss = true
            plan.highlightsTurbo = true
        case .wrongHoop:
            plan.forcesCorrectAnswer = true
            plan.marksWrongHoops = true
            plan.preventsBypassLifeLoss = true
        case .goodLuck, .none:
            break
        }
        return plan
    }
}

// MARK: - What the player did

/// The things a guided run listens for. They are raised by the playing field,
/// which is the only place that knows how a passage actually ended.
enum TutorialEvent: Equatable {
    /// Dragged down into the lower part of the flight band.
    case draggedLow
    /// Dragged up into the upper part of it.
    case draggedHigh
    /// Tapped below the penguin.
    case tappedBelow
    /// Tapped above it.
    case tappedAbove
    /// Flew underneath the complete set.
    case passedUnderSet
    /// Flew through the hoop carrying the answer.
    case passedCorrectHoop(withTurbo: Bool)
    /// Flew through one of the wrong hoops.
    case passedWrongHoop
}

// MARK: - Director

/// The state machine behind a guided run. It holds no game state of its own: it
/// is told what happened and answers two questions — what is on screen, and
/// which rules are bent while this step is being taught.
@MainActor
final class TutorialDirector {
    private(set) var plan = TutorialPlan()

    var step: TutorialStep? { plan.step }
    var isRunning: Bool { plan.isRunning }

    /// Raised whenever the plan changed, so the view model can mirror it onto
    /// its published properties in one place.
    var onChange: (() -> Void)?

    /// How long a step's own reaction is given before the next message replaces
    /// it: long enough to see that it worked, short enough not to wait.
    private static let moveHandover = 0.55
    /// A passage hands over inside its own feedback beat, deliberately before
    /// the engine installs the next sum: the set that arrives next is still the
    /// playing field's preview at that moment, so it can be re-tuned to the new
    /// lesson's rules before it ever becomes the set being flown at.
    private static let passHandover = 0.22
    /// The broken heart flying to the lives meter and returning its life is the
    /// point of step six; it gets enough time to land before the farewell.
    private static let heartHandover = 0.95
    /// How long the closing message stays up.
    private static let farewell = 3.5
    /// Sets the player may let pass in the turbo step before it waits for them.
    private static let turboFreeSets = 3
    /// Height tapping is an optional refinement after dragging has already
    /// proved the player can steer. Do not hold the rest of the tutorial here.
    private static let tapLessonTimeout = 5.0
    /// After two missed dive sets the next one becomes a visual demonstration,
    /// so a child can never remain stuck on an action they have not understood.
    private static let diveAttemptsBeforeDemonstration = 2
    /// The life lesson offers two chances to notice and choose a wrong hoop.
    /// After that, repeatedly taking the visibly safe answer no longer traps
    /// the player in the tutorial.
    private static let lifeLessonSafePassLimit = 2

    private var draggedLow = false
    private var draggedHigh = false
    private var tappedBelow = false
    private var tappedAbove = false
    private var passedSetsInTurboStep = 0
    private var missedDiveSets = 0
    private var safePassesInLifeLesson = 0
    /// True between a step being satisfied and the next one arriving, so the
    /// step that is on its way out cannot be completed a second time.
    private var isAdvancing = false
    private var stepWork: DispatchWorkItem?

    // MARK: Lifecycle

    func begin() {
        guard plan.step == nil else { return }
        draggedLow = false
        draggedHigh = false
        tappedBelow = false
        tappedAbove = false
        passedSetsInTurboStep = 0
        missedDiveSets = 0
        safePassesInLifeLesson = 0
        apply(.dragToFly)
    }

    /// Ends the run without finishing it — the screen is going away, or the
    /// session ended under the tutorial's feet.
    func cancel() {
        stepWork?.cancel()
        stepWork = nil
        isAdvancing = false
        guard plan.step != nil else { return }
        plan = TutorialPlan()
        onChange?()
    }

    // MARK: What happened

    func report(_ event: TutorialEvent) {
        guard let step = plan.step, !isAdvancing else { return }

        switch step {
        case .dragToFly:
            switch event {
            case .draggedLow:  draggedLow = true
            case .draggedHigh: draggedHigh = true
            default: return
            }
            if draggedLow && draggedHigh {
                advance(to: .tapToFly, after: Self.moveHandover)
            }

        case .tapToFly:
            switch event {
            case .tappedBelow: tappedBelow = true
            case .tappedAbove: tappedAbove = true
            default: return
            }
            if tappedBelow && tappedAbove {
                advance(to: .diveUnder, after: Self.moveHandover)
            }

        case .diveUnder:
            // Only going underneath the whole set teaches the lesson. A wrong
            // hoop costs nothing here. After two missed sets, demonstrate the
            // complete move on the next one instead of leaving the child stuck.
            if event == .passedUnderSet {
                advance(to: .correctHoop, after: Self.passHandover)
            } else if event == .passedWrongHoop {
                missedDiveSets += 1
                if missedDiveSets >= Self.diveAttemptsBeforeDemonstration,
                   !plan.demonstratesDive {
                    plan.demonstratesDive = true
                    onChange?()
                }
            }

        case .correctHoop:
            if case .passedCorrectHoop = event {
                advance(to: .turbo, after: Self.passHandover)
            }

        case .turbo:
            switch event {
            case .passedCorrectHoop(let withTurbo) where withTurbo:
                advance(to: .wrongHoop, after: Self.passHandover)
            case .passedCorrectHoop, .passedUnderSet, .passedWrongHoop:
                // Three sets to try it unaided; after that the next one waits.
                passedSetsInTurboStep += 1
                if passedSetsInTurboStep >= Self.turboFreeSets, !plan.holdsForTurbo {
                    plan.holdsForTurbo = true
                    onChange?()
                }
            default: break
            }

        case .wrongHoop:
            switch event {
            case .passedWrongHoop:
                advance(to: .goodLuck, after: Self.heartHandover)
            case .passedCorrectHoop, .passedUnderSet:
                safePassesInLifeLesson += 1
                if safePassesInLifeLesson >= Self.lifeLessonSafePassLimit {
                    advance(to: .goodLuck, after: Self.passHandover)
                }
            default: break
            }

        case .goodLuck:
            break
        }
    }

    // MARK: Plumbing

    private func advance(to step: TutorialStep, after delay: Double) {
        isAdvancing = true
        schedule(after: delay) { [weak self] in
            guard let self else { return }
            self.apply(step)
            guard step == .goodLuck else { return }
            self.schedule(after: Self.farewell) { [weak self] in
                self?.cancel()
            }
        }
    }

    private func apply(_ step: TutorialStep) {
        isAdvancing = false
        plan = TutorialPlan.plan(for: step)
        onChange?()

        guard step == .tapToFly else { return }
        schedule(after: Self.tapLessonTimeout) { [weak self] in
            guard let self, self.plan.step == .tapToFly, !self.isAdvancing else { return }
            self.advance(to: .diveUnder, after: 0)
        }
    }

    private func schedule(after delay: Double, work: @escaping () -> Void) {
        stepWork?.cancel()
        let item = DispatchWorkItem(block: work)
        stepWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }
}

// MARK: - Hand-overs between screens

/// The one piece of tutorial state that outlives a screen: the welcome flow asks
/// for a level to be opened straight into a guided run.
@MainActor
final class TutorialCenter: ObservableObject {
    static let shared = TutorialCenter()

    private static let completedKey = "tutorial.completed"

    /// The level the welcome flow wants opened, guided, the moment the menu
    /// appears. Nil at every other launch.
    @Published private(set) var autoStartLevel: MathLevel?

    /// True from the last welcome answer until the guided level is on screen.
    /// While it holds, the welcome screen stays put and the menu is built up
    /// behind it: the child answered a question and the game rises over that
    /// same screen, rather than the menu flashing past in between.
    @Published private(set) var isHandingOverFromWelcome = false

    private init() {}

    /// Whether the player has ever been through a guided run. Only used to keep
    /// the welcome flow from insisting a second time on a replayed onboarding.
    var hasCompleted: Bool {
        UserDefaults.standard.bool(forKey: Self.completedKey)
    }

    /// Called as the welcome flow hands over: the level selected by the
    /// player's starting-point choice is what they will be taught on.
    func requestAutoStart(topic: MathTopic, index: Int) {
        autoStartLevel = MathLevel(topic: topic, index: index)
        isHandingOverFromWelcome = true
    }

    /// Taken by the menu, once.
    func takeAutoStartLevel() -> MathLevel? {
        defer { autoStartLevel = nil }
        return autoStartLevel
    }

    /// The guided level covers the screen, so the welcome screen underneath it
    /// has nothing left to hold. Also called when the hand-over cannot happen,
    /// so a failed start can never leave the welcome screen on top.
    func finishWelcomeHandover() {
        isHandingOverFromWelcome = false
    }

    /// A guided run has begun.
    func guidedRunStarted() {
        UserDefaults.standard.set(true, forKey: Self.completedKey)
    }
}

// MARK: - The message card

/// What a tutorial says, wherever it says it. Deliberately the same card the
/// standing sum is drawn on — white, the character's own colour around it — so a
/// tutorial message reads as part of the game rather than as an overlay on it.
struct TutorialMessageCard: View {
    let text: String
    /// The glyph for this particular lesson — see `TutorialStep.symbolName`.
    let symbolName: String
    let theme: AnimalCharacter
    var isPad: Bool = AppLayout.isPad
    /// The playing field hands over a fixed band so the swarm can steer around
    /// it; the menu lets the card size itself.
    var fixedSize: CGSize?

    var body: some View {
        HStack(alignment: .center, spacing: isPad ? 14 : 10) {
            Image(systemName: symbolName)
                .font(.system(size: isPad ? 26 : 20, weight: .bold))
                .foregroundStyle(theme.color)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: TutorialMessageIconFrameKey.self,
                            value: proxy.frame(in: .named(TutorialMessageCoordinateSpace.game))
                        )
                    }
                }

            Text(verbatim: text)
                .font(.system(size: isPad ? 20 : 15.5, weight: .heavy, design: .rounded))
                .foregroundStyle(theme.deepColor)
                .multilineTextAlignment(.leading)
                // One line, always. The card is a band across the bottom of a
                // landscape screen with three lanes of hoops above it: a second
                // line grows downward into the lowest lane and covers the very
                // answer the lesson is talking about. A long sentence in a long
                // language shrinks to fit instead — the caller caps how wide
                // the card may get, and the type follows.
                .lineLimit(1)
                .minimumScaleFactor(0.4)
                .allowsTightening(true)
        }
        .padding(.horizontal, isPad ? 20 : 14)
        .padding(.vertical, isPad ? 14 : 10)
        .frame(width: fixedSize?.width, height: fixedSize?.height)
        .background(.white.opacity(0.96),
                    in: RoundedRectangle(cornerRadius: isPad ? 23 : 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: isPad ? 23 : 18, style: .continuous)
                .stroke(theme.color, lineWidth: isPad ? 5 : 4)
        }
        .shadow(color: theme.deepColor.opacity(0.18), radius: 10, y: 5)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - "Not now" notice

/// Shown when the tutorial is asked for in the middle of a run. It is the same
/// card the level intro is built from — white sheet, one heavy heading, one line
/// of explanation and a single filled button in the character's deep colour.
struct TutorialNoticeCard: View {
    let theme: AnimalCharacter
    let onDismiss: () -> Void

    private var isPad: Bool { AppLayout.isPad }
    private var scale: CGFloat { isPad ? 1.2 : 1 }

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)

            VStack(spacing: 14 * scale) {
                Image(systemName: "graduationcap.fill")
                    .font(.system(size: 30 * scale, weight: .bold))
                    .foregroundStyle(theme.color)

                Text("tutorial.notice.title")
                    .font(.system(size: 22 * scale, weight: .heavy, design: .rounded))
                    .foregroundStyle(theme.deepColor)
                    .multilineTextAlignment(.center)

                Text("tutorial.notice.message")
                    .font(.system(size: 15 * scale, weight: .regular))
                    .foregroundStyle(theme.deepColor.opacity(0.84))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Button(action: onDismiss) {
                    Text("common.ok")
                        .font(.system(size: 17 * scale, weight: .heavy))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13 * scale)
                        .foregroundStyle(.white)
                        .background(theme.deepColor,
                                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("tutorial-notice-ok")
                .padding(.top, 2 * scale)
            }
            .padding(24 * scale)
            .frame(width: isPad ? 420 : 340)
            // Same light fill as the start/pause card: `.background` turns
            // black in Dark Mode against this card's deep-purple copy.
            .background(Color.white.opacity(0.96),
                        in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(theme.deepColor.opacity(0.14), lineWidth: 1))
            .shadow(color: theme.deepColor.opacity(0.3), radius: 18, y: 8)
        }
        .transition(.opacity)
    }
}
