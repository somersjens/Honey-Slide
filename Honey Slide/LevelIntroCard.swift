//
//  LevelIntroCard.swift
//  Math Memory
//
//  The card shown before a level starts: what kind of sums it holds, which
//  levels the questions are drawn from, and how much Honey can be collected.
//  Restored from the original start screen; only the settings it offers have
//  changed, since lives and the answer helper are no longer optional here.
//

import SwiftUI

/// Short, child-friendly descriptions of what a level contains. All copy comes
/// from the string catalog, and every number is read from `MathScaling` so the
/// text always matches the questions the player will actually get.
enum LevelIntro {
    /// Title plus the three explanation lines for a level.
    static func info(for board: LevelBoard) -> (title: String, bullets: [String]) {
        let level = board.level
        let n = max(1, level.index)

        let title: String
        let topicLine: String
        switch level.topic {
        case .addition:
            title = L("levelIntro.addition.title \(n)")
            topicLine = L("levelIntro.addition.intro")
        case .subtraction:
            title = L("levelIntro.subtraction.title \(n)")
            topicLine = L("levelIntro.subtraction.intro")
        case .tables:
            title = L("levelIntro.tables.title \(n)")
            topicLine = L("levelIntro.tables.intro")
        case .fractions:
            let d = MathScaling.fractionDenominator(n)
            title = L("levelIntro.fractions.title \(d)")
            topicLine = L("levelIntro.fractions.intro")
        case .percentages:
            // The percent sign travels inside the argument, so no catalog value
            // contains a bare "%".
            let p = "\(MathScaling.percentage(n))%"
            title = L("levelIntro.percentages.title \(p)")
            topicLine = L("levelIntro.percentages.intro")
        case .mixed:
            title = L("levelIntro.mixed.title \(n)")
            topicLine = L("levelIntro.mixed.intro")
        }

        // Line two: which sums this run actually draws, which depends on the
        // order button — and picking the right card out of the ones on offer.
        let levelLine = modeLine(for: board)

        let honeyLine = L(key: "honey.rules %lld", count: board.maximum)

        return (title, [topicLine, levelLine, honeyLine])
    }

    /// The middle line, written for the mode being played. Mixed is the only
    /// one that reaches down to the levels below, so it is the only one that
    /// names a range; Order and Random describe this level's own sums. On
    /// Fractions and Percentages the three buttons change the *kind* of sum,
    /// so those two topics get their own wording.
    private static func modeLine(for board: LevelBoard) -> String {
        let n = max(1, board.level.index)

        // Supermix has no order buttons — its four combinations are the choice
        // — and it always draws from this level and every level below it.
        if board.level.topic.usesSupermixGrid || board.mode == .mixed {
            return n == 1
                ? L("levelIntro.levelRange.first")
                : L("levelIntro.levelRange \(n)")
        }

        let topicPart: String
        switch board.level.topic {
        case .fractions:   topicPart = "fractions."
        case .percentages: topicPart = "percentages."
        default:           topicPart = ""
        }
        let suffix = board.mode == .order ? "order" : "random"
        return L(key: "levelIntro.mode.\(topicPart)\(suffix)")
    }

    /// The glyph shown beside the first line.
    static func symbol(for level: MathLevel) -> String {
        level.topic.symbolName
    }
}

struct LevelIntroCard: View {
    let board: LevelBoard
    let theme: AnimalCharacter
    /// True when this instance was opened by the in-game pause button. A saved
    /// session also makes the card a continuation screen on a later visit.
    var isPauseCard = false
    /// Supplied directly by a live run. A reopened saved run falls back to the
    /// same value stored in `paused` below.
    var lastMissedChallenge: String? = nil
    /// Whether the run this card starts is a guided one. Owned by the game
    /// screen, because the card goes away and the run does not.
    @Binding var isTutorialArmed: Bool

    private var level: MathLevel { board.level }
    let onStart: () -> Void
    let onExit: () -> Void

    /// Raised when the tutorial is asked for on a run that is already under way.
    @State private var showsTutorialNotice = false

    /// The session waiting to be continued, if the player left this level
    /// part-way through.
    private var paused: PausedSession? {
        PausedSessionStore.shared.session(board)
    }

    private var isContinuation: Bool { isPauseCard || paused != nil }
    private var displayedLastChallenge: String? {
        lastMissedChallenge ?? paused?.lastMissedChallenge
    }

    @ObservedObject private var audio = AppAudio.shared
    @ObservedObject private var language = LanguageManager.shared

    private var isPad: Bool { AppLayout.isPad }
    private var scale: CGFloat { isPad ? 1.2 : 1 }
    /// Text on the larger iPad card gets one additional readability step;
    /// buttons intentionally keep their established touch proportions.
    private var textScale: CGFloat { isPad ? 1.296 : 1 }
    private var actionScale: CGFloat { isPad ? 1.2 : 1 }
    /// The heading leads the copy without competing with the portrait.
    private var titleScale: CGFloat { 1.2 }
    /// The tile glyphs and their explanatory copy step down separately, so the
    /// three lines stay comfortably readable rather than shouting.
    private var featureIconScale: CGFloat { 0.8 }
    private var featureTextScale: CGFloat { isPad ? (1.1 * 0.9) : (0.88 * 0.9 * 1.1) }
    /// The portrait sets the height of the whole heading: the title sits on one
    /// line above the two audio buttons, and together they fill exactly this.
    private var portraitSize: CGFloat { 88 * scale }
    private var audioRowHeight: CGFloat { 34 * scale }
    private var headingSpacing: CGFloat { 8 * scale }

    var body: some View {
        let info = LevelIntro.info(for: board)
        let features = [
            IntroFeature(icon: LevelIntro.symbol(for: level), text: info.bullets[0]),
            IntroFeature(number: level.cardNumber, text: info.bullets[1]),
            IntroFeature(icon: Currency.iconName, text: info.bullets[2])
        ]

        return ZStack {
            HoneyModalBackdrop(accent: theme.color)

            GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        HStack(alignment: .top, spacing: 0) {
                            // Stable action column: the title, audio and
                            // navigation stay together on both the start and
                            // pause versions. The buttons are pushed to the
                            // bottom so the last one lines up with the last
                            // description opposite it.
                            VStack(alignment: .leading, spacing: 0) {
                                heading(title: info.title)

                                Spacer(minLength: 16 * scale)

                                actionButtons
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .padding(.trailing, 22 * scale)

                            Rectangle()
                                .fill(theme.color.opacity(0.26))
                                .frame(width: 1)

                            // The information side deliberately contains only
                            // the three descriptions and their icons.
                            VStack(spacing: 12 * scale) {
                                ForEach(features) { feature in
                                    featureCard(feature)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.leading, 22 * scale)
                        }
                        .fixedSize(horizontal: false, vertical: true)

                        // Only a paused run adds height below that shared
                        // baseline; otherwise the card ends right after it.
                        if isContinuation {
                            pausedMessage
                                .padding(.top, 14 * scale)
                        }
                    }
                    .padding(24 * scale)
                    .frame(maxWidth: isPad ? 900 : 760)
                    .honeyMenuPanel(accent: theme.color,
                                    cornerRadius: 28,
                                    prominent: true)
                    .padding(AppLayout.landscapeGutter)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: proxy.size.height, alignment: .center)
                }
                .scrollBounceBehavior(.basedOnSize)
            }

            if showsTutorialNotice {
                TutorialNoticeCard(theme: theme) {
                    AppAudio.shared.playMenuTap()
                    withAnimation(.easeOut(duration: 0.2)) { showsTutorialNotice = false }
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showsTutorialNotice)
    }

    /// Portrait on the left; beside it the level title on a single line with
    /// the two audio buttons underneath. The pair is pinned to the portrait's
    /// height, so the heading reads as one block whatever the title says.
    private func heading(title: String) -> some View {
        HStack(alignment: .top, spacing: 12 * scale) {
            characterPortrait

            VStack(alignment: .leading, spacing: headingSpacing) {
                Text(title)
                    .font(.system(size: 29 * textScale * titleScale,
                                  weight: .heavy, design: .rounded))
                    .foregroundStyle(theme.deepColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                    .allowsTightening(true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

                audioControlRow
            }
            .frame(height: portraitSize)
        }
    }

    /// What the main button promises. A continuation always says Continue —
    /// the tutorial cannot be switched on there — so the guided wording only
    /// ever replaces the plain Start.
    private var startTitleKey: LocalizedStringKey {
        if isContinuation { return "game.intro.continue" }
        return isTutorialArmed ? "game.intro.startTutorial" : "game.intro.start"
    }

    private var actionButtons: some View {
        VStack(spacing: 10) {
            Button(action: onStart) {
                Text(startTitleKey)
                    .font(.system(size: 17 * actionScale, weight: .heavy))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14 * actionScale)
                    .foregroundStyle(.white)
                    .background(
                        LinearGradient(colors: [theme.color, theme.deepColor],
                                       startPoint: .topLeading,
                                       endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(.white.opacity(0.42), lineWidth: 1)
                    }
                    .shadow(color: theme.color.opacity(0.28), radius: 8, y: 4)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("intro-start")

            Button(action: onExit) {
                Text("game.intro.backToMainMenu")
                    .font(.system(size: 17 * actionScale, weight: .heavy))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14 * actionScale)
                    .foregroundStyle(theme.deepColor)
                    .background(.white.opacity(0.7),
                                in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(theme.color.opacity(0.32), lineWidth: 1.25))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("intro-back")
        }
    }

    /// Confirms that the run is safely waiting without repeating a potentially
    /// awkward singular/plural bubble count.
    private var pausedMessage: some View {
        // Both halves mirror the columns above: pause status stays beneath the
        // actions, while the latest missed challenge sits beneath the three
        // level explanations. Before the first mistake that half stays empty.
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "pause.fill")
                Text("game.intro.progressPaused")
            }
            .font(.system(size: 13 * textScale, weight: .semibold))
            .foregroundStyle(theme.deepColor.opacity(0.62))
            .frame(maxWidth: .infinity)
            .padding(.trailing, 22 * scale)

            Color.clear.frame(width: 1, height: 0)

            Group {
                if let displayedLastChallenge {
                    HStack(spacing: 6) {
                        Image(systemName: "clock.arrow.circlepath")
                        Text(verbatim: displayedLastChallenge)
                            .lineLimit(1)
                            .minimumScaleFactor(0.55)
                    }
                    .font(.system(size: 13 * textScale, weight: .semibold))
                    .foregroundStyle(theme.deepColor.opacity(0.62))
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("intro-last-challenge")
                } else {
                    Color.clear
                        .frame(maxWidth: .infinity)
                        .frame(height: 0)
                }
            }
                .padding(.leading, 22 * scale)
        }
        .accessibilityIdentifier("intro-paused")
    }

    // MARK: - Pieces

    private var characterPortrait: some View {
        ZStack {
            HoneyGlowHalo(accent: theme.color, diameter: portraitSize)
            CharacterPortrait(character: theme,
                              side: portraitSize * 0.9,
                              magnification: 1.02)
        }
        .frame(width: portraitSize, height: portraitSize)
    }

    /// Music and sound effects are controlled separately, so a player can keep
    /// the feedback sounds while silencing the background track.
    private var audioControlRow: some View {
        HStack(spacing: 8 * scale) {
            audioButton(icon: "music.note",
                        isOn: audio.musicEnabled) {
                withAnimation(.snappy(duration: 0.2)) { audio.toggleMusic() }
            }

            audioButton(icon: "speaker.wave.2.fill",
                        isOn: audio.gameSoundsEnabled) {
                withAnimation(.snappy(duration: 0.2)) { audio.toggleGameSounds() }
            }

            tutorialButton
        }
    }

    /// The third switch in the row: play this level with the tutorial. It sits
    /// with the two audio buttons because it is the same kind of thing — a
    /// choice about how the run about to start will play, made in the moment
    /// before it does.
    ///
    /// A run already under way cannot be turned into a lesson half-way, so on a
    /// continuation the button explains itself instead of doing nothing.
    private var tutorialButton: some View {
        Button {
            AppAudio.shared.playMenuTap()
            guard !isContinuation else {
                withAnimation(.easeInOut(duration: 0.2)) { showsTutorialNotice = true }
                return
            }
            withAnimation(.snappy(duration: 0.2)) { isTutorialArmed.toggle() }
        } label: {
            Image(systemName: "graduationcap.fill")
                .font(.system(size: 16 * scale, weight: .heavy))
                .foregroundStyle(isTutorialArmed ? .white : theme.deepColor)
                .frame(width: 42 * scale, height: audioRowHeight)
                .background(isTutorialArmed ? AnyShapeStyle(theme.deepColor)
                                            : AnyShapeStyle(theme.skyColor))
                .clipShape(RoundedRectangle(cornerRadius: 12 * scale, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12 * scale, style: .continuous)
                    .stroke(theme.color.opacity(isTutorialArmed ? 0.50 : 0.24), lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("intro-tutorial")
        .accessibilityAddTraits(isTutorialArmed ? [.isButton, .isSelected] : .isButton)
    }

    private func audioButton(icon: String,
                             isOn: Bool,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Image(systemName: icon)
                    .font(.system(size: 17 * scale, weight: .heavy))
                if !isOn {
                    // The struck-through glyph reads as "off" at a glance.
                    Capsule()
                        .fill(theme.deepColor)
                        .frame(width: 23 * scale, height: 2.3 * scale)
                        .rotationEffect(.degrees(-45))
                }
            }
            .foregroundStyle(theme.deepColor.opacity(isOn ? 1 : 0.55))
            .frame(width: 42 * scale, height: audioRowHeight)
            .background(theme.skyColor)
            .clipShape(RoundedRectangle(cornerRadius: 12 * scale, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12 * scale, style: .continuous)
                .stroke(theme.color.opacity(0.24), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func featureCard(_ feature: IntroFeature) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Group {
                if let number = feature.number {
                    Text(verbatim: number)
                        .font(.system(size: 34 * textScale * featureIconScale,
                                      weight: .heavy, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.48)
                        .allowsTightening(true)
                } else {
                    if feature.icon == Currency.iconName {
                        CurrencyIcon(size: 28 * textScale * featureIconScale)
                    } else {
                        Image(systemName: feature.icon)
                            .font(.system(size: (feature.icon == "multiply" ? 34 : 28)
                                          * textScale * featureIconScale, weight: .bold))
                    }
                }
            }
            .foregroundStyle(.white)
            .frame(width: 54 * scale, height: 54 * scale)
            .background(
                LinearGradient(colors: [theme.color, theme.deepColor],
                               startPoint: .topLeading,
                               endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.44), lineWidth: 1))

            Text(emphasizedAttributedString(feature.text))
                .font(.system(size: 15 * textScale * featureTextScale, weight: .regular))
                .foregroundStyle(theme.deepColor.opacity(0.84))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10 * scale)
        .padding(.vertical, 6 * scale)
        .background(
            LinearGradient(colors: [theme.skyColor.opacity(0.58),
                                    HoneyMenuPalette.gloss.opacity(0.55)],
                           startPoint: .leading,
                           endPoint: .trailing),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(theme.color.opacity(0.20), lineWidth: 1))
    }

    private struct IntroFeature: Identifiable {
        let icon: String
        let number: String?
        let text: String

        init(icon: String, text: String) {
            self.icon = icon
            self.number = nil
            self.text = text
        }

        init(number: String, text: String) {
            self.icon = "number"
            self.number = number
            self.text = text
        }

        var id: String { "\(icon)-\(number ?? "")-\(text)" }
    }

    /// A single-stroke divider avoids the doubled edge a dashed rectangle
    /// creates at this small height.
    private struct DashedDivider: View {
        let color: Color

        var body: some View {
            GeometryReader { proxy in
                Path { path in
                    path.move(to: CGPoint(x: 0, y: proxy.size.height / 2))
                    path.addLine(to: CGPoint(x: proxy.size.width, y: proxy.size.height / 2))
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
            }
            .frame(height: 2)
        }
    }
}
