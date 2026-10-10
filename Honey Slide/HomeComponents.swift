//
//  HomeComponents.swift
//  Math Memory
//
//  The pieces the home screen is built from: the streak module, the goal
//  picker, the name editor, the level grid layout, and the level card itself.
//
//  These are ported from the original menu with their proportions intact. The
//  only change to the level card is that its score is measured in cards
//  instead of trophies.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Goal period

enum GoalPeriod: String, CaseIterable, Identifiable {
    case daily
    case weekly

    var id: String { rawValue }
    var title: String {
        self == .daily ? L("goalPeriod.daily") : L("goalPeriod.weekly")
    }
}

// MARK: - Streak

/// The streak module: one wide bar under the character, with the day count at
/// one end, the minutes played at the other, and the goal rail filling whatever
/// is left between them.
struct StreakBar: View {
    let accent: Color
    let height: CGFloat
    let action: () -> Void
    @ObservedObject private var tracker = PlaytimeTracker.shared
    @AppStorage("ui.goalPeriod") private var goalPeriodRaw = GoalPeriod.weekly.rawValue

    private var goalPeriod: GoalPeriod { GoalPeriod(rawValue: goalPeriodRaw) ?? .weekly }
    private var isPad: Bool { AppLayout.isPad }

    // Everything inside is a fraction of the bar's own height, so the module
    // keeps its proportions at whatever height the header hands it.
    private var scale: CGFloat { height / 26 }

    private var progressMinutes: Int {
        goalPeriod == .weekly ? tracker.weekMinutes : tracker.todayMinutes
    }

    private var goalMinutes: Int {
        goalPeriod == .weekly ? tracker.weeklyGoalMinutes : tracker.dailyGoalMinutes
    }

    private var goalProgress: Double {
        min(1, Double(progressMinutes) / Double(max(1, goalMinutes)))
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9 * scale) {
                headline
                    .foregroundStyle(accent)
                progressLine
                Text("common.minutesShort \(progressMinutes) \(goalMinutes)")
                    .font(.system(size: 11.5 * scale, weight: .semibold))
                    .foregroundStyle(accent.opacity(0.62))
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 11 * scale)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(accent.opacity(0.08), in: Capsule())
            .overlay(Capsule().stroke(accent.opacity(0.12), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("streak")
    }

    // The day count and its flame — or the day-one badge — read as one unit:
    // matched weights, baseline alignment, and a single tight gap keep the icon
    // from drifting away from the text beside it.
    @ViewBuilder private var headline: some View {
        if tracker.streakDays == 0 {
            HStack(alignment: .firstTextBaseline, spacing: 4 * scale) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13 * scale, weight: .bold))
                Text("streak.dayOne")
                    .font(.system(size: 13 * scale, weight: .heavy, design: .rounded))
            }
            .fixedSize()
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 4 * scale) {
                Text(verbatim: "\(tracker.streakDays)")
                    .font(.system(size: 17 * scale, weight: .heavy, design: .rounded))
                Image(systemName: "flame.fill")
                    .font(.system(size: 13 * scale, weight: .bold))
            }
            .fixedSize()
        }
    }

    // The rail is the only flexible part of the bar, so it takes whatever the
    // day count and the minutes leave over.
    private var progressLine: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(accent.opacity(0.15))
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(LinearGradient(colors: [accent.opacity(0.6), accent],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(6 * scale, proxy.size.width * goalProgress))
                        .animation(.snappy(duration: 0.4), value: goalProgress)
                }
        }
        .frame(height: 6 * scale)
    }
}

// MARK: - Goal picker

struct DailyGoalPicker: View {
    let theme: AnimalCharacter
    @ObservedObject private var tracker = PlaytimeTracker.shared
    @AppStorage("ui.goalPeriod") private var goalPeriodRaw = GoalPeriod.weekly.rawValue

    private var goalPeriod: GoalPeriod { GoalPeriod(rawValue: goalPeriodRaw) ?? .weekly }
    private let goalOptions = Array(stride(from: 5, through: 60, by: 5))
    private var isPad: Bool { AppLayout.isPad }

    var body: some View {
        VStack(alignment: .leading, spacing: isPad ? 18 : 12) {
            Text("goal.title")
                .font(isPad
                      ? .system(size: 30, weight: .heavy, design: .rounded)
                      : .headline)
                .foregroundStyle(isPad ? theme.deepColor : .primary)
            periodPicker

            Text(goalPeriod == .weekly ? "goal.promptWeekly" : "goal.promptDaily")
                .font(isPad
                      ? .system(size: 20, weight: .semibold, design: .rounded)
                      : .caption)
                .foregroundStyle(isPad ? theme.deepColor.opacity(0.7) : .secondary)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: isPad ? 12 : 8), count: 4),
                      spacing: isPad ? 12 : 8) {
                ForEach(goalOptions, id: \.self) { minutes in
                    Button {
                        goalPeriod == .weekly ? tracker.setWeeklyGoal(minutes) : tracker.setDailyGoal(minutes)
                    } label: {
                        Text(verbatim: "\(minutes)")
                    }
                    .font(isPad
                          ? .system(size: 24, weight: .bold, design: .rounded)
                          : .subheadline.weight(.bold))
                    .frame(maxWidth: .infinity, minHeight: isPad ? 56 : 36)
                    .background(selectedGoalMinutes == minutes ? theme.color : .white,
                                in: RoundedRectangle(cornerRadius: isPad ? 14 : 10))
                    .foregroundStyle(selectedGoalMinutes == minutes ? .white : theme.deepColor)
                }
            }
        }
        .frame(width: isPad ? 440 : 280)
    }

    private var selectedGoalMinutes: Int {
        goalPeriod == .weekly ? tracker.weeklyGoalMinutes : tracker.dailyGoalMinutes
    }

    private var periodPicker: some View {
        let picker = Picker("goal.period", selection: $goalPeriodRaw) {
            ForEach(GoalPeriod.allCases) { period in
                Text(period.title).tag(period.rawValue)
            }
        }
        .pickerStyle(.segmented)
        return Group {
            if isPad {
                picker
                    .controlSize(.large)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
            } else {
                picker
            }
        }
    }
}

// MARK: - Name editor

/// Themed sheet for editing the player's name, styled to match the app rather
/// than a plain system alert. Deliberately a short, self-sizing sheet that
/// rises over the menu — a full navigation stack reads far heavier here.
/// Renaming the player: a small card that floats over the menu rather than a
/// sheet that swallows it. The app is landscape, so a 300pt sheet took three
/// quarters of the height for one text field — this keeps the menu visible
/// behind a soft dim, which also makes it obvious what is being renamed.
struct NameEditorCard: View {
    let theme: AnimalCharacter
    @Binding var name: String
    let onSave: () -> Void
    let onCancel: () -> Void

    @FocusState private var focused: Bool
    @State private var appeared = false

    private var isPad: Bool { AppLayout.isPad }
    private var scale: CGFloat { isPad ? 1.2 : 1 }

    private var trimmed: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() {
        guard !trimmed.isEmpty else { return }
        onSave()
    }

    var body: some View {
        ZStack {
            // Tapping beside the card is the quickest way out, and the dim is
            // what keeps the menu readable but clearly out of reach.
            Color.black.opacity(appeared ? 0.42 : 0)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onCancel)

            card
                .scaleEffect(appeared ? 1 : 0.92)
                .opacity(appeared ? 1 : 0)
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.84), value: appeared)
        .onAppear {
            appeared = true
            focused = true
        }
    }

    private var card: some View {
        HStack(spacing: 16 * scale) {
            CharacterPortrait(character: theme,
                              side: 64 * scale,
                              magnification: 1)

            VStack(alignment: .leading, spacing: 10 * scale) {
                Text("name.whatsYourName")
                    .font(.system(size: 17 * scale, weight: .heavy, design: .rounded))
                    .foregroundStyle(theme.deepColor)

                TextField(String(), text: $name, prompt: Text("name.placeholder"))
                    .font(.system(size: 18 * scale, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.deepColor)
                    .focused($focused)
                    .textContentType(.name)
                    .submitLabel(.done)
                    .onSubmit(save)
                    .padding(.horizontal, 12 * scale)
                    .padding(.vertical, 9 * scale)
                    .background(.white.opacity(0.85),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(focused ? theme.color : theme.deepColor.opacity(0.16),
                                    lineWidth: focused ? 2 : 1)
                    )
                    .animation(.snappy(duration: 0.18), value: focused)
                    .frame(width: 190 * scale)
            }

            VStack(spacing: 8 * scale) {
                Button(action: save) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 17 * scale, weight: .heavy))
                        .frame(width: 44 * scale, height: 40 * scale)
                        .background(
                            LinearGradient(colors: [theme.color, theme.deepColor],
                                           startPoint: .top, endPoint: .bottom),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
                        .foregroundStyle(.white)
                        .opacity(trimmed.isEmpty ? 0.4 : 1)
                }
                .disabled(trimmed.isEmpty)

                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 15 * scale, weight: .bold))
                        .frame(width: 44 * scale, height: 34 * scale)
                        .background(.white.opacity(0.8),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .foregroundStyle(theme.deepColor.opacity(0.7))
                }
            }
            .buttonStyle(.plain)
        }
        .padding(18 * scale)
        .background(
            LinearGradient(colors: [theme.skyColor, .white],
                           startPoint: .top, endPoint: .bottom),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(.white.opacity(0.8), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.22), radius: 22, y: 10)
        .fixedSize()
    }
}

// MARK: - Level grid layout

/// Lays the level cards out in equal-width columns, fitting as many as the
/// available width allows without ever going below `minimumCardWidth`.
struct AdaptiveLevelGrid: Layout {
    let spacing: CGFloat
    let minimumCardWidth: CGFloat
    let maximumColumns: Int
    let cardHeight: CGFloat

    init(spacing: CGFloat,
         minimumCardWidth: CGFloat = 104,
         maximumColumns: Int = .max,
         cardHeight: CGFloat = 96) {
        self.spacing = spacing
        self.minimumCardWidth = minimumCardWidth
        self.maximumColumns = maximumColumns
        self.cardHeight = cardHeight
    }

    private func metrics(for width: CGFloat, itemCount: Int) -> (columns: Int, cardWidth: CGFloat) {
        // SwiftUI may probe a custom Layout with an infinite width before the
        // surrounding landscape HStack has settled. Converting that probe to
        // Int traps at runtime, so calculate against a finite intrinsic width.
        let fallbackColumns = min(max(1, itemCount), maximumColumns)
        let fallbackWidth = minimumCardWidth * CGFloat(fallbackColumns)
            + spacing * CGFloat(max(0, fallbackColumns - 1))
        let safeWidth = width.isFinite && width > 0 ? width : fallbackWidth
        let rawColumns = (safeWidth + spacing) / max(1, minimumCardWidth + spacing)
        let cappedColumns = min(CGFloat(max(1, itemCount)), max(1, rawColumns))
        let possibleColumns = Int(cappedColumns.rounded(.down))
        let columns = min(max(1, itemCount), possibleColumns, maximumColumns)
        let cardWidth = max(1, (safeWidth - CGFloat(columns - 1) * spacing) / CGFloat(columns))
        return (columns, cardWidth)
    }

    func sizeThatFits(proposal: ProposedViewSize,
                      subviews: Subviews,
                      cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let fallbackColumns = min(subviews.count, maximumColumns)
        let fallbackWidth = minimumCardWidth * CGFloat(fallbackColumns)
            + spacing * CGFloat(fallbackColumns - 1)
        let proposedWidth = proposal.width ?? fallbackWidth
        let width = proposedWidth.isFinite && proposedWidth > 0 ? proposedWidth : fallbackWidth
        let columns = metrics(for: width, itemCount: subviews.count).columns
        let rows = Int(ceil(Double(subviews.count) / Double(columns)))
        return CGSize(width: width, height: CGFloat(rows) * cardHeight + CGFloat(rows - 1) * spacing)
    }

    func placeSubviews(in bounds: CGRect,
                       proposal: ProposedViewSize,
                       subviews: Subviews,
                       cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let grid = metrics(for: bounds.width, itemCount: subviews.count)
        for (index, subview) in subviews.enumerated() {
            let row = index / grid.columns
            let column = index % grid.columns
            let x = bounds.minX + CGFloat(column) * (grid.cardWidth + spacing)
            let y = bounds.minY + CGFloat(row) * (cardHeight + spacing)
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                          proposal: ProposedViewSize(width: grid.cardWidth, height: cardHeight))
        }
    }
}

// MARK: - Tier marker shapes

/// The folded, clipped-corner marker used for the middle tier.
private struct CornerFlagShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.width * 0.18, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.width * 0.82, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.height * 0.18),
                          control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.height * 0.54))
        path.addQuadCurve(to: CGPoint(x: rect.width * 0.91, y: rect.height * 0.66),
                          control: CGPoint(x: rect.maxX, y: rect.height * 0.61))
        path.addLine(to: CGPoint(x: rect.width * 0.23, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.height * 0.84),
                          control: CGPoint(x: rect.width * 0.03, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.height * 0.18))
        path.addQuadCurve(to: CGPoint(x: rect.width * 0.18, y: rect.minY),
                          control: CGPoint(x: rect.minX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

/// The swallowtail ribbon marker used for the highest non-complete tier.
private struct PennantShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.width * 0.18, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.width * 0.82, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.height * 0.18),
                          control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.height * 0.86))
        path.addQuadCurve(to: CGPoint(x: rect.width * 0.87, y: rect.maxY),
                          control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.width * 0.58, y: rect.height * 0.74))
        path.addQuadCurve(to: CGPoint(x: rect.midX, y: rect.height * 0.71),
                          control: CGPoint(x: rect.width * 0.54, y: rect.height * 0.71))
        path.addLine(to: CGPoint(x: rect.width * 0.13, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.height * 0.86),
                          control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.height * 0.18))
        path.addQuadCurve(to: CGPoint(x: rect.width * 0.18, y: rect.minY),
                          control: CGPoint(x: rect.minX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Level card

enum LevelCardStatus: Equatable {
    case locked
    case available
    case recommended
    case completed
}

/// A level card: the big central number, the card score line, a three-dot
/// progress indicator and the top-left tier badge. Reaching the completion
/// score turns it into the gold "completed" card.
struct LevelCardView: View {
    let level: MathLevel
    let status: LevelCardStatus
    let best: Int
    /// What a full score is worth on the board being shown, which depends on
    /// the selected exercise.
    var maximum: Int = GameConfig.levelMaximum
    /// How often this board has been taken to its maximum. From the second time
    /// onward the completed card carries a ×N badge.
    var maxCompletions = 0
    /// Cards banked in the run waiting to be continued, or nil when this level
    /// was not left part-way through.
    var pausedCards: Int?
    /// Set for the level just returned from: its score counts up from the value
    /// the player had before the session, and the card is briefly outlined.
    var celebrationStart: Int?
    var celebrationStartedAt: Date?
    /// iPad cards preserve the iPhone design, scaled as one component.
    var cardHeight: CGFloat = 96
    let theme: AnimalCharacter
    let action: () -> Void

    @State private var scorePulse = false
    @State private var completionRevealed = false

    private var cardScale: CGFloat { cardHeight / 96 }
    private var isLocked: Bool { status == .locked }

    // MARK: Tiers

    /// Achievement tiers, keyed off the card score. Their colors keep the
    /// selected character's hue, stepping from its primary color through its
    /// deep color to a darker finish as the score increases.
    private enum Tier {
        case empty
        case one
        case two
        case three
        case maxed

        func color(for theme: AnimalCharacter) -> Color {
            switch self {
            case .empty:  return Color(white: 0.72)
            case .one:    return theme.color
            case .two:    return theme.deepColor
            case .three:
                return Color(red: theme.deepRGB.0 * 0.76,
                             green: theme.deepRGB.1 * 0.76,
                             blue: theme.deepRGB.2 * 0.76)
            case .maxed:  return Color(red: 0.30, green: 0.62, blue: 0.24)
            }
        }

        /// How many of the three progress dots are active.
        var activeDots: Int {
            switch self {
            case .empty:          return 0
            case .one:            return 1
            case .two:            return 2
            case .three, .maxed:  return 3
            }
        }
    }

    /// Tier boundaries come from the central configuration, so the card art
    /// follows the economy rather than repeating its numbers.
    private func tier(for score: Int) -> Tier {
        if score >= maximum { return .maxed }
        let maximum = Double(maximum)
        let shares = GameConfig.levelTierShares
        switch Double(score) {
        case ..<(maximum * shares[0]): return .empty
        case ..<(maximum * shares[1]): return .one
        case ..<(maximum * shares[2]): return .two
        default:                       return .three
        }
    }

    private var tier: Tier { tier(for: best) }

    /// During a return animation the score still starts at its old value. Keep
    /// every score-coloured detail in that old tier too; otherwise a maxed
    /// bubble turns green before its number has actually reached the maximum.
    private var displayedTier: Tier {
        guard isNewMaximumCelebration, !completionRevealed else { return tier }
        return tier(for: celebrationStart ?? best)
    }

    private var displayedBest: Int {
        isNewMaximumCelebration && !completionRevealed ? (celebrationStart ?? best) : best
    }

    private var showsCompletedAppearance: Bool {
        tier == .maxed && !isLocked && (!isNewMaximumCelebration || completionRevealed)
    }

    /// A level that crosses its maximum on this return stays in its ordinary
    /// card until the bubbles have finished counting. Only then do the gold
    /// card, crown and planets arrive together.
    private var isNewMaximumCelebration: Bool {
        celebrationStartedAt != nil && (celebrationStart ?? best) < maximum && best >= maximum
    }

    // MARK: Body

    var body: some View {
        Button {
            AppAudio.shared.playMenuTap()
            action()
        } label: {
            Group {
                if showsCompletedAppearance {
                    completedCard
                        .transition(.opacity.combined(with: .scale(scale: 0.88, anchor: .bottom)))
                } else {
                    standardCard
                        .transition(.opacity)
                }
            }
            .frame(height: cardHeight)
            .opacity(isLocked ? 0.55 : 1)
            .scaleEffect((status == .recommended ? 1.02 : 1) * (scorePulse ? 1.04 : 1))
            .overlay {
                if let celebrationStartedAt {
                    LevelReturnFocusGlow(startedAt: celebrationStartedAt,
                                         cornerRadius: 18 * cardScale,
                                         lineWidth: 4 * cardScale,
                                         glowRadius: 9 * cardScale,
                                         strokeColor: theme.deepColor,
                                         glowColor: theme.color)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(isLocked)
        .onAppear { animateIfCelebrating() }
        .onChange(of: celebrationStartedAt) { _, _ in animateIfCelebrating() }
        .accessibilityIdentifier("level-\(level.index)")
    }

    /// A little kick on the glyph at the moment the number lands.
    private func animateIfCelebrating() {
        completionRevealed = !isNewMaximumCelebration
        guard celebrationStartedAt != nil, (celebrationStart ?? best) < best else {
            scorePulse = false
            return
        }
        let landing = Self.scoreCountDelay + Self.scoreCountDuration
        DispatchQueue.main.asyncAfter(deadline: .now() + landing) {
            withAnimation(.spring(response: 0.52, dampingFraction: 0.62)) {
                scorePulse = true
                if isNewMaximumCelebration { completionRevealed = true }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + landing + 0.62) {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.7)) { scorePulse = false }
        }
    }

    // MARK: Standard card

    private var standardCard: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 4) {
                Spacer(minLength: 2)
                Text(level.cardNumber)
                    .font(.system(size: 36 * cardScale, weight: .heavy, design: .rounded))
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .foregroundStyle(theme.deepColor)
                centerLine
                Spacer(minLength: 2)
                progressDots(active: displayedTier.activeDots,
                             color: displayedTier.color(for: theme))
                    .padding(.bottom, 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(8 * cardScale)

            tierBadge
                .padding(.top, 9 * cardScale)
                .padding(.leading, 9 * cardScale)
        }
        .background(cardFill, in: RoundedRectangle(cornerRadius: 18 * cardScale))
        .overlay(alignment: .bottomTrailing) {
            // A quiet orbit line keeps every level tile in the same visual
            // world as the large menu panels without competing with its score.
            Ellipse()
                .stroke(theme.color.opacity(displayedBest == 0 ? 0.10 : 0.16),
                        lineWidth: max(1, cardScale))
                .frame(width: 82 * cardScale, height: 28 * cardScale)
                .rotationEffect(.degrees(-18))
                .offset(x: 24 * cardScale, y: 10 * cardScale)
                .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18 * cardScale))
        .overlay(
            RoundedRectangle(cornerRadius: 18 * cardScale)
                .stroke(borderColor, lineWidth: (status == .recommended ? 2.5 : 1) * cardScale)
        )
        .shadow(color: theme.color.opacity(status == .recommended ? 0.22 : 0.10),
                radius: 6, x: 0, y: 3)
    }

    private var cardFill: LinearGradient {
        LinearGradient(
            colors: displayedBest == 0
                ? [Color.white.opacity(0.76), SpaceMenuPalette.starlight.opacity(0.48)]
                : [Color.white, theme.skyColor.opacity(0.92)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var borderColor: Color {
        if status == .recommended { return theme.color }
        return theme.color.opacity(displayedBest == 0 ? 0.28 : 0.44)
    }

    // MARK: Center score line

    @ViewBuilder
    private var centerLine: some View {
        if status == .recommended && best == 0 {
            Text("menu.startHere")
                .font(.system(size: 13 * cardScale, weight: .bold))
                .foregroundStyle(theme.deepColor)
                // Longer translations shrink to fit rather than truncating.
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .allowsTightening(true)
        } else if isLocked {
            Image(systemName: "lock.fill")
                .font(.system(size: 10 * cardScale, weight: .bold))
                .foregroundStyle(theme.deepColor.opacity(0.75))
        } else if let pausedCards {
            // A paused level shows its best score next to what the waiting run
            // has already banked, so the reason to go back is on the card.
            HStack(spacing: 3 * cardScale) {
                cardChip
                Rectangle()
                    .fill(theme.deepColor.opacity(0.25))
                    .frame(width: 1, height: 11 * cardScale)
                HStack(spacing: 2 * cardScale) {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 8 * cardScale))
                    Text(verbatim: "\(pausedCards)")
                        .font(.system(size: 12 * cardScale, weight: .bold))
                        .monospacedDigit()
                }
                .foregroundStyle(theme.deepColor.opacity(0.7))
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        } else {
            cardChip
        }
    }

    /// The score, with its bubble after the number — the way a count is read
    /// aloud ("twelve bubbles"), not the way a price is written.
    private var cardChip: some View {
        HStack(spacing: 3 * cardScale) {
            CountingNumber(from: celebrationStart ?? best,
                           to: best,
                           startedAt: celebrationStartedAt,
                           delay: Self.scoreCountDelay,
                           duration: Self.scoreCountDuration)
                .font(.system(size: 13 * cardScale, weight: .bold))
            LevelCardCurrencyIcon(size: 15 * cardScale)
                // The launch anchor is read from the unscaled layout frame, so
                // the flying card starts exactly overlapping this glyph.
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(key: CardGlyphAnchorKey.self,
                                               value: [level.id: proxy.frame(in: .named("home"))])
                    }
                }
                .scaleEffect(scorePulse ? 1.48 : 1)
                .rotationEffect(.degrees(scorePulse ? -12 : 0))
        }
        .foregroundStyle(displayedTier == .empty
                         ? Color(white: 0.6)
                         : displayedTier.color(for: theme))
    }

    /// The level's own score is the first thing that moves on returning: it
    /// counts up here, and only then does the reward fly to the totals.
    static let scoreCountDelay = 0.25
    static let scoreCountDuration = 0.7

    // MARK: Tier badge (top-left)

    @ViewBuilder
    private var tierBadge: some View {
        switch displayedTier {
        case .empty:
            // No score yet: leave the corner empty.
            EmptyView()
        case .one:
            RoundedRectangle(cornerRadius: 1.8)
                .fill(displayedTier.color(for: theme))
                .frame(width: 11 * cardScale, height: 11 * cardScale)
                .rotationEffect(.degrees(45))
                .padding(.leading, 1)
        case .two:
            CornerFlagShape()
                .fill(displayedTier.color(for: theme))
                .frame(width: 14 * cardScale, height: 16.5 * cardScale)
        case .three, .maxed:
            PennantShape()
                .fill(displayedTier.color(for: theme))
                .frame(width: 14 * cardScale, height: 16.5 * cardScale)
        }
    }

    // MARK: Progress dots

    private func progressDots(active: Int, color: Color) -> some View {
        HStack(spacing: 6 * cardScale) {
            ForEach(0..<3) { index in
                Circle()
                    .fill(index < active ? color : Color(white: 0.85))
                    .frame(width: 6 * cardScale, height: 6 * cardScale)
            }
        }
    }

    // MARK: Completed card

    /// The completed card celebrates in two colours: a theme-specific `hero`
    /// (number, score, dots and ribbon behind the crown) and a gold `metal`
    /// (crown, border and glow). Each hero colour is deliberately dark enough
    /// to stay crisp on the warm maximum-card background.
    private var completedPalette: (hero: Color, metal: Color) {
        Self.completedPalette(for: theme)
    }

    static func completedPalette(for theme: AnimalCharacter) -> (hero: Color, metal: Color) {
        let gold = Color(red: 0.87, green: 0.66, blue: 0.12)
        let hero: Color
        switch theme.id {
        case "flying_penguin":
            hero = theme.deepColor
        case "frog":
            hero = Color(red: 0.40, green: 0.24, blue: 0.62)
        case "bunny":
            hero = Color(red: 0.47, green: 0.20, blue: 0.36)
        case "dog":
            hero = Color(red: 0.68, green: 0.25, blue: 0.16)
        case "lion":
            hero = Color(red: 0.18, green: 0.48, blue: 0.24)
        case "octopus":
            hero = Color(red: 0.08, green: 0.38, blue: 0.43)
        case "crab":
            hero = Color(red: 0.08, green: 0.30, blue: 0.55)
        case "elephant":
            hero = Color(red: 0.47, green: 0.23, blue: 0.34)
        case "bear":
            hero = Color(red: 0.08, green: 0.39, blue: 0.37)
        case "fox":
            hero = Color(red: 0.19, green: 0.27, blue: 0.58)
        default:
            hero = theme.deepColor
        }
        return (hero, gold)
    }

    private var completedCard: some View {
        let (hero, metal) = completedPalette
        return ZStack {
            VStack(spacing: 3) {
                Spacer(minLength: 8)
                Text(level.cardNumber)
                    .font(.system(size: 36 * cardScale, weight: .heavy, design: .rounded))
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .foregroundStyle(hero)
                HStack(spacing: 3 * cardScale) {
                    CountingNumber(from: celebrationStart ?? best,
                                   to: best,
                                   startedAt: celebrationStartedAt,
                                   delay: Self.scoreCountDelay,
                                   duration: Self.scoreCountDuration)
                        .font(.system(size: 13 * cardScale, weight: .bold))
                    LevelCardCurrencyIcon(size: 15 * cardScale)
                        // Once the max card has been revealed, the flight must
                        // still start on this exact bubble. Without an anchor
                        // here the standard card's disappearing glyph leaves
                        // the return animation with no source point.
                        .background {
                            GeometryReader { proxy in
                                Color.clear.preference(key: CardGlyphAnchorKey.self,
                                                       value: [level.id: proxy.frame(in: .named("home"))])
                            }
                        }
                        .scaleEffect(scorePulse ? 1.48 : 1)
                }
                .foregroundStyle(hero)
                // The repeat marker is a superscript detail beside the score,
                // not a second item in the centred layout. It appears from the
                // second maximum onward; the first is marked by crown and gold.
                .overlay(alignment: .topTrailing) {
                    if maxCompletions >= 2 {
                        maxCompletionBadge(fill: hero, metal: metal)
                            // The wrapper is only an alignment column: the badge
                            // keeps its natural width and grows to the right, so
                            // a wider label ("MAX") never creeps back over the
                            // number instead of staying pinned beside it.
                            .frame(width: 23 * cardScale, alignment: .leading)
                            .offset(x: 20 * cardScale, y: -7 * cardScale)
                    }
                }
                Spacer(minLength: 2)
                progressDots(active: 3, color: metal)
                    .padding(.bottom, 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(8 * cardScale)
        }
        .background(
            LinearGradient(colors: [Color(red: 1.0, green: 0.96, blue: 0.85),
                                    Color(red: 0.99, green: 0.90, blue: 0.68)],
                           startPoint: .top, endPoint: .bottom),
            in: RoundedRectangle(cornerRadius: 18 * cardScale)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18 * cardScale)
                .stroke(metal, lineWidth: 2.5 * cardScale)
        )
        .overlay {
            completedPlanets(color: hero)
        }
        .overlay(alignment: .top) {
            completedRibbon(fill: hero, crown: metal)
                .offset(y: -9 * cardScale)
        }
        .shadow(color: metal.opacity(0.35), radius: 6, y: 3)
    }

    /// One ringed planet on each side of a maxed level, mirrored so the pair
    /// stays symmetrical. On a wide card they sit beside the number instead of
    /// against the border, and a little below centre so the crown above them
    /// does not pull the card top-heavy.
    private func completedPlanets(color: Color) -> some View {
        let side = 36 * 1.2 * cardScale
        // Two digits, plus a gap so the rings do not touch the numeral.
        let preferredLane = 54 * cardScale
        return GeometryReader { proxy in
            let lane = min(preferredLane, max(0, proxy.size.width - side * 2))
            HStack(spacing: 0) {
                CompletionPlanet(color: color, revealStartedAt: planetRevealStartedAt)
                    .frame(width: side, height: side)

                Color.clear.frame(width: lane)

                CompletionPlanet(color: color, revealStartedAt: planetRevealStartedAt)
                    .frame(width: side, height: side)
                    .scaleEffect(x: -1, y: 1)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .offset(y: 3 * cardScale)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The completed card is inserted at this exact instant. Giving both
    /// planets the shared timestamp keeps them synchronized even when
    /// SwiftUI creates one side a frame later than the other.
    private var planetRevealStartedAt: Date? {
        guard isNewMaximumCelebration, let celebrationStartedAt else { return nil }
        return celebrationStartedAt.addingTimeInterval(Self.scoreCountDelay + Self.scoreCountDuration)
    }

    /// A small ribbon overlapping the top edge, carrying the crown. The ribbon
    /// takes the hero colour and the crown the contrasting metal, so the badge
    /// reads as an object sitting on the card rather than a floating glyph.
    private func completedRibbon(fill: Color, crown: Color) -> some View {
        Image(systemName: "crown.fill")
            .font(.system(size: 11 * cardScale, weight: .bold))
            .foregroundStyle(crown)
            .padding(.horizontal, 11 * cardScale)
            .padding(.vertical, 4 * cardScale)
            .background(RoundedRectangle(cornerRadius: 6 * cardScale).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: 6 * cardScale)
                .stroke(.white.opacity(0.6), lineWidth: 1))
            .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
    }

    /// "×3" — or the word for "max" once the tally is capped. Deliberately
    /// smaller than the score: the airy outline is its visual footprint.
    private func maxCompletionBadge(fill: Color, metal: Color) -> some View {
        let isCapped = maxCompletions >= GameConfig.maximumCompletionCount
        let label = isCapped ? L("menu.maximumCount") : "×\(maxCompletions)"
        let cornerRadius = 3.5 * cardScale
        return Text(verbatim: label)
            .fixedSize()
            .font(.system(size: 6.4 * cardScale, weight: .heavy, design: .rounded))
            .foregroundStyle(fill)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .padding(.horizontal, 2 * cardScale)
            .padding(.vertical, 1 * cardScale)
            .background(.white.opacity(0.5),
                        in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(metal.opacity(0.8), lineWidth: 1 * cardScale))
            .shadow(color: metal.opacity(0.18), radius: 2, y: 1)
    }
}

/// The ringed planet beside a maxed level number. The opposite side is
/// mirrored. The far half of the ring is drawn behind the disc, so it does
/// not cross the face.
private struct CompletionPlanet: View {
    let color: Color
    /// Nil means this is an already-completed card and should render fully.
    let revealStartedAt: Date?

    /// Matches the warm fill of the completed card, so the glint reads as a
    /// highlight instead of a second theme colour.
    private static let highlight = Color(red: 1.0, green: 0.96, blue: 0.85)

    /// Room around the disc for the tilted ring.
    private static let frameFactor: CGFloat = 1.9

    /// The reveal lasts well under a second, after which the planet is still.
    /// Left running, the timeline would wake every completed card at full rate
    /// for as long as the screen is up, including while a level is being played
    /// over it.
    @State private var hasSettled = false
    /// Comfortably past the spring reveal.
    private static let revealDuration: TimeInterval = 0.7

    var body: some View {
        TimelineView(.animation(paused: hasSettled)) { context in
            let elapsed = revealStartedAt.map {
                max(0, context.date.timeIntervalSince($0))
            } ?? .greatestFiniteMagnitude
            let progress = revealProgress(at: elapsed)
            GeometryReader { proxy in
                let diameter = min(proxy.size.width, proxy.size.height) / Self.frameFactor
                planet(diameter: diameter)
                    .scaleEffect(progress, anchor: .center)
                    .opacity(min(1, Double(progress)))
                    .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
        .task(id: revealStartedAt) {
            guard let revealStartedAt else {
                hasSettled = true
                return
            }
            hasSettled = false
            let remaining = Self.revealDuration
                - Date().timeIntervalSince(revealStartedAt)
            if remaining > 0 {
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                guard !Task.isCancelled else { return }
            }
            hasSettled = true
        }
    }

    private func planet(diameter: CGFloat) -> some View {
        ZStack {
            ringHalf(diameter: diameter, front: false)
            Circle()
                .fill(color)
                .overlay(alignment: .topLeading) {
                    Circle()
                        .fill(Self.highlight)
                        .frame(width: diameter * 0.28, height: diameter * 0.28)
                        .offset(x: diameter * 0.16, y: diameter * 0.14)
                }
                .clipShape(Circle())
                .frame(width: diameter, height: diameter)
            ringHalf(diameter: diameter, front: true)
        }
    }

    /// Far half first, near half after the disc. Both share the same tilt, so
    /// the rear arc stays behind the planet instead of crossing its face.
    private func ringHalf(diameter: CGFloat, front: Bool) -> some View {
        RingArc(isFront: front)
            .stroke(color, style: StrokeStyle(lineWidth: max(1.1, diameter * 0.10),
                                              lineCap: .butt))
            .frame(width: diameter * 1.55, height: diameter * 0.62)
            .rotationEffect(.degrees(22))
    }

    private func revealProgress(at elapsed: TimeInterval) -> CGFloat {
        let raw = min(1, max(0, (elapsed - 0.08) / 0.32))
        let c1 = 1.70158
        let c3 = c1 + 1
        return CGFloat(1 + c3 * pow(raw - 1, 3) + c1 * pow(raw - 1, 2))
    }
}

/// One half of the ring, in the ring's own plane before it is tilted.
/// The upper half is the far side; the lower half passes in front of the disc.
private struct RingArc: Shape {
    var isFront: Bool

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radiusX = rect.width / 2
        let radiusY = rect.height / 2
        // 0 is the right tip. The lower half runs through the bottom of the
        // ellipse; the upper half is the far side of the ring.
        let start = isFront ? 0.0 : Double.pi
        let end = isFront ? Double.pi : Double.pi * 2
        var path = Path()
        let steps = 48
        for step in 0...steps {
            let t = start + (end - start) * Double(step) / Double(steps)
            let point = CGPoint(x: center.x + radiusX * cos(t),
                                y: center.y + radiusY * sin(t))
            if step == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        return path
    }
}

/// The currency star, inset slightly inside its layout frame so it keeps a
/// little breathing room at compact sizes.
private struct LevelCardCurrencyIcon: View {
    let size: CGFloat

    var body: some View {
        CurrencyIcon(size: size * 0.88)
            .frame(width: size * 0.88, height: size * 0.88)
            .frame(width: size, height: size)
    }
}

// MARK: - Tap-again info pop-out

/// The little themed card shown when the already-selected topic is tapped
/// again. `anchor` is the tapped control's frame in the shared "home" space.
struct InfoPopup: Identifiable {
    let header: String
    let message: String
    let anchor: CGRect
    let id = UUID()
}

struct InfoPopoutCard: View {
    let header: String
    let message: String
    let caretOffset: CGFloat
    let theme: AnimalCharacter
    private var isPad: Bool { AppLayout.isPad }

    private static func headerPointSize(isPad: Bool) -> CGFloat { isPad ? 18 : 11 }
    private static func messagePointSize(isPad: Bool) -> CGFloat { isPad ? 28 : 16 }
    private static func horizontalInset(isPad: Bool) -> CGFloat { isPad ? 24 : 14 }

    /// Width needed for the header or message, including the card's horizontal
    /// padding. Longer messages deliberately use the narrowest width that still
    /// fits them on two lines, instead of making the pop-out screen-wide.
    static func preferredWidth(header: String,
                               message: String,
                               isPad: Bool,
                               maximum: CGFloat) -> CGFloat {
#if canImport(UIKit)
        let headerFont = UIFont.systemFont(ofSize: headerPointSize(isPad: isPad), weight: .heavy)
        let messageFont = UIFont.systemFont(ofSize: messagePointSize(isPad: isPad), weight: .bold)
        // `Text(header)` adds 0.6 points between every pair of letters below.
        // Include that tracking here too, or a heading can be measured a little
        // too narrowly and wrap even when the pop-out has room to grow.
        let uppercasedHeader = header.uppercased()
        let headerTracking = CGFloat(max(0, uppercasedHeader.count - 1)) * 0.6
        let headerWidth = (uppercasedHeader as NSString)
            .size(withAttributes: [.font: headerFont]).width + headerTracking
        let messageString = message as NSString
        let messageWidth = messageString
            .size(withAttributes: [.font: messageFont]).width
        let horizontalPadding = horizontalInset(isPad: isPad) * 2
        let maximumContentWidth = max(1, maximum - horizontalPadding)

        // Keep short explanations on one line. For longer translations, find
        // the smallest content width that needs no more than two lines, so the
        // second line does not leave a large empty tail in the card.
        if max(headerWidth, messageWidth) <= maximumContentWidth {
            return ceil(max(headerWidth, messageWidth) + horizontalPadding)
        }

        var lowerBound = min(maximumContentWidth, max(headerWidth, isPad ? 280 : 170))
        var upperBound = maximumContentWidth
        let twoLineHeight = messageFont.lineHeight * 2.05

        for _ in 0..<9 {
            let candidate = (lowerBound + upperBound) / 2
            let measured = messageString.boundingRect(
                with: CGSize(width: candidate, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: messageFont],
                context: nil
            )
            if measured.height <= twoLineHeight {
                upperBound = candidate
            } else {
                lowerBound = candidate
            }
        }

        return ceil(upperBound + horizontalPadding)
#else
        return min(isPad ? 480 : 250, maximum)
#endif
    }

    var body: some View {
        VStack(spacing: 0) {
            Triangle()
                .fill(.white)
                .frame(width: isPad ? 24 : 18, height: isPad ? 12 : 9)
                .overlay(alignment: .bottom) {
                    // Hide the seam where the caret meets the card body.
                    Rectangle().fill(.white).frame(height: 1).padding(.horizontal, 2)
                }
                .offset(x: caretOffset)

            VStack(alignment: .leading, spacing: isPad ? 8 : 3) {
                Text(header.uppercased())
                    .font(.system(size: Self.headerPointSize(isPad: isPad), weight: .heavy))
                    .tracking(0.6)
                    .foregroundStyle(theme.deepColor.opacity(0.55))
                Text(message)
                    .font(.system(size: Self.messagePointSize(isPad: isPad), weight: .bold))
                    .foregroundStyle(theme.deepColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Self.horizontalInset(isPad: isPad))
            .padding(.vertical, isPad ? 20 : 11)
            .background(.white, in: RoundedRectangle(cornerRadius: isPad ? 20 : 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: isPad ? 20 : 16, style: .continuous)
                .stroke(theme.deepColor.opacity(0.18), lineWidth: 1))
        }
        .shadow(color: theme.deepColor.opacity(0.22), radius: 14, y: 6)
    }
}

/// An upward-pointing triangle for the pop-out caret.
private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// A number that counts from one value to another over a fixed window, driven
/// by elapsed time so no change event can be coalesced or missed.
struct CountingNumber: View {
    let from: Int
    let to: Int
    /// Nil renders the final value straight away, with no count-up.
    let startedAt: Date?
    var delay = 0.0
    var duration = 0.78

    /// A finished (or never-started) count is a plain number. The timeline is
    /// stopped for it, so a total sitting on the menu does not keep the
    /// display link awake for the life of the screen.
    @State private var hasSettled = false

    var body: some View {
        TimelineView(.animation(paused: hasSettled)) { context in
            let elapsed = startedAt.map { context.date.timeIntervalSince($0) }
                ?? .greatestFiniteMagnitude
            let progress = startedAt == nil
                ? 1
                : min(1, max(0, (elapsed - delay) / duration))
            let eased = 1 - pow(1 - progress, 3)
            let value = Int((Double(from) + Double(to - from) * eased).rounded())
            // Grouped in the language being read, so a five- or six-figure
            // total stays a number a child can actually read off the screen.
            Text(verbatim: LNumber(value))
                .contentTransition(.numericText())
                .monospacedDigit()
                // A gentle swell that peaks mid-count and settles again.
                .scaleEffect(1 + sin(progress * .pi) * 0.13)
        }
        .task(id: startedAt) {
            guard let startedAt else {
                hasSettled = true
                return
            }
            hasSettled = false
            let remaining = delay + duration - Date().timeIntervalSince(startedAt)
            if remaining > 0 {
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                guard !Task.isCancelled else { return }
            }
            hasSettled = true
        }
    }
}

// MARK: - Card total / next character

/// The next animal still to be earned and how many cards are missing. Held as a
/// value rather than recomputed on the spot, so the summary line can keep the
/// old count on screen while a return celebration counts the total up.
struct NextCharacterPrompt: Equatable {
    let characterID: String
    let remaining: Int

    var character: AnimalCharacter { CharacterCatalog.character(id: characterID) }
}

private struct CardSummaryWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// The quiet line under the player's name. Normally the running card total;
/// once the player has started collecting, the same slot briefly previews the
/// next character to earn, so the menu needs no permanent row for it.
struct AlternatingCardSummary: View {
    let totalFrom: Int
    let totalTo: Int
    /// Nil renders the total straight away, with no count-up.
    let celebrationStartedAt: Date?
    var countDelay = 0.0
    var countDuration = 0.78
    let prompt: NextCharacterPrompt?
    /// Bumped once a level return has fully settled: the new remaining count is
    /// then previewed at once instead of waiting out the ordinary cycle.
    let immediatePreviewID: Int
    /// While the return celebration runs, the total owns the slot.
    let isCelebrationActive: Bool
    /// True for the beat in which a reward has just joined the totals.
    var isHighlighted = false
    let accent: Color
    let isPad: Bool
    let action: () -> Void

    @ObservedObject private var language = LanguageManager.shared
    @State private var showsPreview = false
    @State private var displayedPrompt: NextCharacterPrompt?
    @State private var handledImmediatePreviewID = 0
    @State private var availableWidth: CGFloat = 0

    private var scale: CGFloat { isPad ? 1.4 : 1 }
    private var baseFontSize: CGFloat { isPad ? 20 : 14 }
    private var iconSize: CGFloat { isPad ? 17 : 12 }
    private var artworkSide: CGFloat { 28 * scale }
    /// Both alternatives share this height, so the taller artwork grows around
    /// the text line instead of pushing the player's name upward.
    private var opticalLineHeight: CGFloat { baseFontSize * 1.4 }

    var body: some View {
        HStack(spacing: 4) {
            // The card glyph never takes part in the swap: holding it perfectly
            // still avoids the dip two crossfading icons would produce.
            CurrencyIcon(size: iconSize)
                .scaleEffect(isHighlighted ? 1.32 : 1)
                .rotationEffect(.degrees(isHighlighted ? -10 : 0))

            alternatingValues
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(key: CardSummaryWidthKey.self,
                                               value: proxy.size.width)
                    }
                }
                .onPreferenceChange(CardSummaryWidthKey.self) { width in
                    guard abs(width - availableWidth) > 0.5 else { return }
                    withTransaction(Transaction(animation: nil)) { availableWidth = width }
                }
        }
        .foregroundStyle(accent)
        .lineLimit(1)
        .task(id: cycleID) { await runPreviewCycle() }
    }

    // MARK: Contents

    private var alternatingValues: some View {
        let contentScale = contentScale
        return ZStack(alignment: .leading) {
            CountingNumber(from: totalFrom,
                           to: totalTo,
                           startedAt: celebrationStartedAt,
                           delay: countDelay,
                           duration: countDuration)
                .font(.system(size: baseFontSize, weight: .heavy, design: .rounded))
                .opacity(showsPreview ? 0 : 1)
                .blur(radius: showsPreview ? 2.2 : 0)
                .scaleEffect(showsPreview ? 0.985 : 1, anchor: .leading)
                .reportAnchor("headerTotal")
                // Deliberately not hidden while the preview shows: the total is
                // the authoritative reading of this line, and a slot that came
                // and went would make it unfindable.
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("card-total")

            if let displayedPrompt {
                promptLabel(displayedPrompt, contentScale: contentScale)
            }
        }
        .frame(height: opticalLineHeight, alignment: .leading)
    }

    private func promptLabel(_ prompt: NextCharacterPrompt, contentScale: CGFloat) -> some View {
        let animal = prompt.character
        return Button(action: action) {
            HStack(alignment: .center, spacing: 3 * scale * contentScale) {
                Text(verbatim: remainingText(prompt.remaining))
                    .font(.system(size: baseFontSize * contentScale,
                                  weight: .heavy, design: .rounded))
                    .contentTransition(.numericText())
                    .allowsTightening(true)
                    // Deliberately *not* fixed-size: this text must be able to
                    // give way. `contentScale` already sizes the group to fit,
                    // and it is measured from the width this row is offered —
                    // a text that refused to compress would widen that offer
                    // instead, and with it the whole menu card.
                    .minimumScaleFactor(0.6)
                Image(systemName: "arrow.forward")
                    .font(.system(size: 10 * scale * contentScale, weight: .bold))
                    // The arrow sits optically a fraction above rounded numerals
                    // at this size.
                    .offset(y: 0.8 * scale * contentScale)
                    .opacity(0.58)
                animal.thumbnail
                    .resizable()
                    .scaledToFit()
                    .frame(width: artworkSide * contentScale,
                           height: artworkSide * contentScale)
                    // Keep the full visual size, but let it extend equally above
                    // and below a text-height layout footprint.
                    .frame(height: opticalLineHeight * contentScale)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(showsPreview ? 1 : 0)
        .blur(radius: showsPreview ? 0 : 2.2)
        .scaleEffect(showsPreview ? 1 : 0.985, anchor: .leading)
        .allowsHitTesting(showsPreview)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("next-character")
        .accessibilityHidden(!showsPreview)
    }

    private func remainingText(_ remaining: Int) -> String {
        L("home.cardsRemaining \(remaining)")
    }

    // MARK: Fitting

    /// The prompt must never wrap or truncate, so when the header column is too
    /// narrow for the longest translation the whole group shrinks instead.
    private var contentScale: CGFloat {
        guard prompt != nil, availableWidth > 0, naturalPromptWidth > availableWidth else { return 1 }
        // A small rounding margin, so the non-wrapping text never lands exactly
        // on the clipping boundary after pixel quantisation.
        return max(0.01, (availableWidth - 2 * scale) / naturalPromptWidth)
    }

    private var naturalPromptWidth: CGFloat {
        guard let prompt else { return 0 }
        // Two HStack gaps plus the forward arrow, beside the measured text.
        let decoration = 6 * scale + 10 * scale + artworkSide
#if canImport(UIKit)
        let system = UIFont.systemFont(ofSize: baseFontSize, weight: .heavy)
        let font = system.fontDescriptor.withDesign(.rounded)
            .map { UIFont(descriptor: $0, size: baseFontSize) } ?? system
        let text = ceil((remainingText(prompt.remaining) as NSString)
            .size(withAttributes: [.font: font]).width)
        return text + decoration
#else
        return baseFontSize * 4 + decoration
#endif
    }

    // MARK: Cycle

    private var cycleID: String {
        let promptID = prompt.map { "\($0.characterID)-\($0.remaining)" } ?? "total"
        return "\(promptID)-\(immediatePreviewID)-\(isCelebrationActive)"
    }

    @MainActor
    private func runPreviewCycle() async {
        // A returning session owns this line until its card count, flight and
        // total count-up have all settled. Cancelling here also hides a preview
        // that happened to be on screen when the return began.
        guard !isCelebrationActive else {
            withTransaction(Transaction(animation: nil)) { showsPreview = false }
            return
        }

        guard let prompt else {
            showsPreview = false
            displayedPrompt = nil
            handledImmediatePreviewID = immediatePreviewID
            return
        }

        do {
            if displayedPrompt != prompt {
                if immediatePreviewID != handledImmediatePreviewID {
                    // Only a completed level return bumps the trigger; a launch
                    // or an iCloud merge updates the value silently and waits
                    // for the ordinary cycle. Install the *new* remaining
                    // value before fading it in; showing the previous prompt
                    // for a beat made the end of the sequence feel one step
                    // behind the counters.
                    displayedPrompt = prompt
                    withAnimation(.easeInOut(duration: 0.32)) { showsPreview = true }
                    try await Task.sleep(nanoseconds: 2_200_000_000)
                    withAnimation(.easeInOut(duration: 0.32)) { showsPreview = false }
                } else {
                    displayedPrompt = prompt
                    showsPreview = false
                }
            }
            handledImmediatePreviewID = immediatePreviewID

            try await Task.sleep(nanoseconds: 5_000_000_000)
            while !Task.isCancelled {
                withAnimation(.easeInOut(duration: 0.55)) { showsPreview = true }
                try await Task.sleep(nanoseconds: 3_000_000_000)
                withAnimation(.easeInOut(duration: 0.55)) { showsPreview = false }
                try await Task.sleep(nanoseconds: 5_000_000_000)
            }
        } catch {
            // SwiftUI cancels this task when the prompt changes or the view goes.
        }
    }
}

/// One card in flight from a level card up to the header total. Its geometry
/// lives in the shared "home" space, so it starts exactly on the level card's
/// glyph and lands exactly on the header's.
struct CardFlight: Identifiable {
    let id = UUID()
    let celebrationID: UUID
    let source: CGRect
    let destination: CGRect
    let sourcePointSize: CGFloat
    let destinationPointSize: CGFloat
    let arcHeight: CGFloat
    let color: Color
    let startedAt: Date
    let duration: TimeInterval
}

/// Draws the flying card from the elapsed time each frame, so the arc is a real
/// curved path — a plain `.position` animation would cut straight across.
struct CardFlightView: View {
    let flight: CardFlight

    var body: some View {
        TimelineView(.animation) { context in
            let elapsed = max(0, context.date.timeIntervalSince(flight.startedAt))
            let t = min(1, elapsed / flight.duration)
            // Ease progress along the path; keep the arc keyed to raw `t` so the
            // lift peaks at the midpoint of the flight.
            let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
            let x = flight.source.midX + (flight.destination.midX - flight.source.midX) * eased
            let y = flight.source.midY + (flight.destination.midY - flight.source.midY) * eased
                - CGFloat(sin(Double(t) * .pi)) * flight.arcHeight
            let size = flight.sourcePointSize
                + (flight.destinationPointSize - flight.sourcePointSize) * eased
            // Merge softly into the header glyph over the last stretch.
            let fade = t > 0.88 ? max(0, 1 - (t - 0.88) / 0.12) : 1
            CurrencyIcon(size: size)
                .foregroundStyle(flight.color)
                .shadow(color: flight.color.opacity(0.35), radius: 3, y: 1)
                .opacity(fade)
                .position(x: x, y: y)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A time-driven focus outline around the level just returned from. This
/// deliberately has no `@State` or `onChange`: as long as the celebration
/// exists, the current frame can derive the correct glow intensity.
struct LevelReturnFocusGlow: View {
    let startedAt: Date
    let cornerRadius: CGFloat
    let lineWidth: CGFloat
    let glowRadius: CGFloat
    let strokeColor: Color
    let glowColor: Color

    /// The glow is fully faded by 1.98s (see `glowOpacity`). The view itself
    /// may outlive the celebration it belongs to, so stop the clock once there
    /// is nothing left to draw rather than keep redrawing an invisible ring.
    @State private var hasSettled = false

    var body: some View {
        TimelineView(.animation(paused: hasSettled)) { context in
            let elapsed = max(0, context.date.timeIntervalSince(startedAt))
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(strokeColor, lineWidth: lineWidth)
                .shadow(color: glowColor.opacity(0.85), radius: glowRadius)
                .opacity(glowOpacity(at: elapsed))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: startedAt) {
            hasSettled = false
            let remaining = 2.0 - Date().timeIntervalSince(startedAt)
            if remaining > 0 {
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                guard !Task.isCancelled else { return }
            }
            hasSettled = true
        }
    }

    private func glowOpacity(at elapsed: TimeInterval) -> Double {
        if elapsed < 0.28 { return elapsed / 0.28 }
        if elapsed < 1.45 { return 1 }
        if elapsed < 1.98 { return 1 - ((elapsed - 1.45) / 0.53) }
        return 0
    }
}

/// Frames of each level card's card glyph, keyed by level id, in "home" space.
/// These are the launch points for the card that flies up to the header total.
struct CardGlyphAnchorKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Frames of the on-screen topic controls, keyed by name, in "home" space.
struct ControlAnchorKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// Reports this control's frame in the shared "home" coordinate space so a
    /// pop-out can be positioned directly under it.
    func reportAnchor(_ key: String) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(key: ControlAnchorKey.self,
                                       value: [key: proxy.frame(in: .named("home"))])
            }
        )
    }
}
