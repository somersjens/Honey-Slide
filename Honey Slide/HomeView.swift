//
//  HomeView.swift
//  Math Memory
//
//  Home screen: a wide landscape toolbar with the player and streak on the
//  left, the session choices on the right, and the level grid below. iPhone
//  keeps four columns; iPad uses three so the twelve free levels fill the
//  height as four rows.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct LevelSelection: Identifiable {
    let level: MathLevel
    /// True only for the run the welcome flow hands straight over to: the level
    /// opens playing, with the tutorial already running.
    var startsGuided = false
    var id: String { level.id }
}

/// What the player had before the session they just finished, so the level
/// score and the header total both visibly grow from there.
private struct ScoreCelebration: Identifiable {
    let levelID: String
    let levelStart: Int
    let topicStart: Int
    let totalStart: Int
    /// True only when this session turned an unfinished board into a maxed one.
    /// That inserts the planet-and-crown reveal before its bubble flies away.
    let revealsMaximum: Bool
    let id = UUID()
    /// Stamped when the celebration actually becomes visible, not when it was
    /// built — a stale timestamp makes every time-driven view skip straight to
    /// its finished state.
    var startedAt = Date()
}

struct HomeView: View {
    var onRestartOnboarding: (() -> Void)?

    @AppStorage(GameSettings.characterKey) private var characterID = CharacterCatalog.freeCharacterID
    @AppStorage(GameSettings.playerNameKey) private var playerName = ""
    @AppStorage(GameSettings.onboardingCompleteKey) private var onboardingComplete = false
    @AppStorage(GameSettings.totalCardsKey) private var totalCards = 0
    @AppStorage(GameSettings.topicKey) private var topicRaw = MathTopic.allCases[0].rawValue
    @AppStorage(GameSettings.mixedVariantKey) private var mixedVariantRaw = MixedVariant.allCases[0].rawValue
    @AppStorage(GameSettings.practiceModeKey) private var practiceModeRaw = PracticeMode.fallback.rawValue

    @ObservedObject private var premium = PremiumStore.shared
    @ObservedObject private var progressSync = ProgressSync.shared
    @ObservedObject private var language = LanguageManager.shared
    @Environment(\.scenePhase) private var scenePhase

    @State private var selection: LevelSelection?
    @State private var showPremium = false
    @State private var premiumInitialCharacterID: String?
    @State private var celebratedUnlockID: String?
    @State private var pendingUnlockIDs: [String] = []
    @State private var showGoalPicker = false
    @State private var showNameEditor = false
    @State private var nameDraft = ""
    @State private var infoPopup: InfoPopup?
    @State private var controlAnchors: [String: CGRect] = [:]
    @State private var viewportWidth: CGFloat = HomeView.seededWindowSize.width
    @State private var viewportHeight: CGFloat = HomeView.seededWindowSize.height
    @State private var suppressTopicTap = false
    /// The brief return-to-menu celebration after a session earned cards.
    @State private var celebration: ScoreCelebration?
    @State private var cardGlyphAnchors: [String: CGRect] = [:]
    @State private var flights: [CardFlight] = []
    @State private var lastPlayedLevelID: String?
    @State private var lastPlayedLevelBest = 0
    @State private var lastPlayedTopic = 0
    @State private var lastPlayedTotal = 0
    /// True from opening a level until the celebration for it is in place. The
    /// session banks its cards while the cover is still up and `@AppStorage`
    /// mirrors that write at once, so without this the menu behind the closing
    /// cover would show the new totals for a frame, snap back to the old ones
    /// and only then count up.
    @State private var holdsPreSessionValues = false
    /// Stamped the moment the flying card reaches the topic counter. Both the
    /// topic total and the grand total start counting up from it, together.
    @State private var cardArrival: Date?
    @State private var highlightsHeaderCards = false
    /// The stable value shown in the summary line under the name. It only
    /// changes once the return celebration has settled, so the remaining count
    /// is replaced in a single pop instead of ticking down with the total.
    @State private var unlockPrompt: NextCharacterPrompt?
    @State private var unlockPreviewTrigger = 0
    /// Topic totals span as many as 99 levels and several boards per level.
    /// Keep that storage scan out of SwiftUI body recomputation; refresh it
    /// only when the selected topic or the reconciled progress snapshot moves.
    @State private var topicCardTotal = 0

    private var character: AnimalCharacter { CharacterCatalog.current(isPremium: premium.isPremium) }
    private var topic: MathTopic { MathTopic(rawValue: topicRaw) ?? MathTopic.allCases[0] }
    private var mixedVariant: MixedVariant {
        MixedVariant(rawValue: mixedVariantRaw) ?? MixedVariant.allCases[0]
    }
    private var practiceMode: PracticeMode { PracticeMode.from(rawValue: practiceModeRaw) }
    private var isPad: Bool { AppLayout.isPad }

    private var displayName: String {
        playerName.isEmpty ? CharacterCatalog.defaultPlayerName : playerName
    }

    // MARK: - Metrics

    private var menuScale: CGFloat { isPad ? 1.4 : 1 }
    private var menuControlSpacing: CGFloat { isPad ? 14 : 10 }
    private var modeButtonHeight: CGFloat { isPad ? 58 : 37 }
    private var levelGridSpacing: CGFloat { isPad ? 16 : 10 }
    private var menuCardPadding: CGFloat { isPad ? 20 : 13 }
    private var menuCardSpacing: CGFloat { isPad ? 24 : 14 }
    /// The character is exactly as tall as the two control rows beside it — the
    /// topics and the row under them — so the two halves of the card square off.
    private var characterBox: CGFloat {
        topicButtonDiameter + menuControlSpacing + modeButtonHeight
    }
    private var streakBarHeight: CGFloat { isPad ? 36 : 24 }
    /// Where the divider sits. The player side only has to carry the character,
    /// three short lines and the streak bar, so the controls get the wider half.
    /// iPad gives the name and the two score lines room to sit larger next to
    /// the level cards.
    private var playerPanelWidth: CGFloat { isPad ? 530 : 325 }

    /// Side inset and the width inside it. iPhone keeps the shared landscape
    /// canvas. On iPad the previous inset was the 28pt gutter plus whatever the
    /// 1180pt cap left empty on a wide screen; that whole margin is halved so
    /// the level grid can use the width that used to sit beside it.
    private struct MenuCanvas {
        var inset: CGFloat
        var contentWidth: CGFloat
    }

    private func menuCanvas(for screenWidth: CGFloat) -> MenuCanvas {
        let gutter = AppLayout.landscapeGutter
        guard screenWidth > 1 else {
            return MenuCanvas(inset: gutter, contentWidth: 0)
        }
        if !isPad {
            let content = min(AppLayout.landscapeContentWidth, screenWidth - gutter * 2)
            return MenuCanvas(inset: gutter, contentWidth: max(0, content))
        }
        let legacyFrame = min(screenWidth, AppLayout.landscapeContentWidth + gutter * 2)
        let legacyInset = (screenWidth - legacyFrame) / 2 + gutter
        let inset = max(12, (legacyInset / 2).rounded())
        return MenuCanvas(inset: inset, contentWidth: max(0, screenWidth - inset * 2))
    }

    /// iPhone stays at up to four columns. iPad lays the twelve free levels out
    /// as three columns, which is four rows and fills the height the four-by-three
    /// grid left empty. A very narrow window drops to two so a card stays tappable.
    private var levelColumnCount: Int {
        let canvas = menuCanvas(for: viewportWidth)
        if !isPad {
            let width = canvas.contentWidth > 1 ? canvas.contentWidth : AppLayout.landscapeContentWidth
            let minimum: CGFloat = 118
            let fitting = Int(((width + levelGridSpacing) / (minimum + levelGridSpacing)).rounded(.down))
            return min(4, max(1, fitting))
        }
        return canvas.contentWidth > 1 && canvas.contentWidth < 520 ? 2 : 3
    }

    private var levelGridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: levelGridSpacing),
              count: levelColumnCount)
    }

    /// iPhone cards keep their fixed height. iPad cards grow so the free levels
    /// and the premium banner together fill the screen, instead of leaving the
    /// lower half of a 13-inch display empty.
    private var levelCardHeight: CGFloat {
        guard isPad else { return 88 }
        let viewport = viewportHeight
        guard viewport > 1 else { return 124 }
        let rows = CGFloat(max(1, Int((CGFloat(GameConfig.freeLevelCount) / CGFloat(levelColumnCount)).rounded(.up))))
        let header = characterBox + menuCardPadding * 2
        let betweenHeaderAndGrid: CGFloat = 22
        let banner = premium.isPremium ? CGFloat(0) : premiumBannerBlock
        let gridSpacing = levelGridSpacing * (rows - 1)
        let chrome = AppLayout.landscapeGutter * 2
            + header
            + betweenHeaderAndGrid
            + gridSpacing
            + banner
            + 8
        let fitted = (viewport - chrome) / rows
        return min(172, max(100, fitted.rounded(.toNearestOrAwayFromZero)))
    }

    /// The gap above the "more levels" banner, plus the banner's padding and
    /// its two lines. Used only to budget the level-card height.
    private var premiumBannerBlock: CGFloat {
        let vertical: CGFloat = 20
        let title: CGFloat = 24
        let subtitle: CGFloat = 20
        return 14 + vertical * 2 + title + 2 + subtitle
    }

    /// The room the topics and the row under them have, worked out from the same
    /// numbers the card is laid out with. Knowing it here means the controls can
    /// size themselves to the screen without a nested `GeometryReader` — and the
    /// character, which has to match their height, can read that height too.
    private var controlColumnWidth: CGFloat {
        let content = menuCanvas(for: viewportWidth).contentWidth
        return max(0, content - menuCardPadding * 2 - playerPanelWidth - menuCardSpacing * 2 - 1)
    }

    /// Window size inside the safe area, used to lay the iPad menu out on the
    /// first frame. Reading it on every frame wedges SwiftUI's update pass, so
    /// it only seeds state until the live geometry arrives.
    private static var seededWindowSize: CGSize {
#if canImport(UIKit)
        guard AppLayout.isPad else { return .zero }
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
        guard let window else { return .zero }
        let insets = window.safeAreaInsets
        return CGSize(width: max(0, window.bounds.width - insets.left - insets.right),
                      height: max(0, window.bounds.height - insets.top - insets.bottom))
#else
        return .zero
#endif
    }

    /// The six topic circles grow to fill their row, so what is left between them
    /// is a deliberate gap rather than leftover space. On iPad they stop at a
    /// size that still reads clearly next to the large level cards.
    private var topicButtonDiameter: CGFloat {
        let gap: CGFloat = isPad ? 12 : 8
        let fits = (controlColumnWidth - gap * 5) / 6
        return min(isPad ? 84 : 46, max(isPad ? 64 : 38, fits))
    }

    var body: some View {
        ZStack {
            SpaceMenuBackground(accent: character.color)

            GeometryReader { proxy in
                let canvas = menuCanvas(for: proxy.size.width)
                ScrollView {
                    VStack(alignment: .leading, spacing: isPad ? 22 : 14) {
                        menuCard
                            .zIndex(1)
                        levelGrid
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .zIndex(0)
                    }
                    .padding(.horizontal, canvas.inset)
                    .padding(.vertical, AppLayout.landscapeGutter)
                    .frame(width: canvas.contentWidth + canvas.inset * 2)
                    .frame(maxWidth: .infinity)
                }
                .onAppear {
                    viewportWidth = proxy.size.width
                    viewportHeight = proxy.size.height
                }
                .onChange(of: proxy.size.width) { _, width in viewportWidth = width }
                .onChange(of: proxy.size.height) { _, height in viewportHeight = height }
                .onPreferenceChange(ControlAnchorKey.self) { controlAnchors = $0 }
                .onPreferenceChange(CardGlyphAnchorKey.self) { cardGlyphAnchors = $0 }
                .overlay(alignment: .topLeading) { infoPopoutOverlay }
                .overlay {
                    ForEach(flights) { flight in
                        CardFlightView(flight: flight)
                    }
                    // Both endpoints were measured with `frame(in:)`, which
                    // reports the real, physical geometry whatever the language
                    // — but `.position` is a layout placement and mirrors its x
                    // in a right-to-left one. Left as-is the card launches from
                    // the level tile's mirror image and lands on the header's,
                    // so the whole arc plays across the wrong half of the menu.
                    // The overlay is nothing but a moving glyph, so pinning it
                    // costs no reading direction: it has nothing to read.
                    .environment(\.layoutDirection, .leftToRight)
                }
            }
        }
        .coordinateSpace(name: "home")
        // Every counter on the menu — the two header totals, the level cards,
        // the summary line and the card in flight between them — counts in the
        // selected character's own food.
        .fullScreenCover(item: $selection, onDismiss: handleSessionDismissed) { item in
            GameView(request: GameSessionRequest(level: item.level,
                                                 mixedVariant: mixedVariant,
                                                 mode: practiceMode,
                                                 startsGuided: item.startsGuided))
                .gameEnvironment()
        }
        .sheet(isPresented: $showPremium, onDismiss: {
            premiumInitialCharacterID = nil
            celebratedUnlockID = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                presentNextUnlockIfAny()
            }
        }) {
            PremiumView(initialCharacterID: premiumInitialCharacterID,
                        celebratedUnlockCharacterID: celebratedUnlockID)
                .premiumSheetPresentation()
        }
        // Renaming happens over the menu, not instead of it: a card this small
        // has no business taking the whole screen, and seeing the menu behind
        // it makes plain whose name is being changed.
        .overlay {
            if showNameEditor {
                NameEditorCard(
                    theme: character,
                    name: $nameDraft,
                    onSave: {
                        playerName = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        withAnimation(.easeOut(duration: 0.2)) { showNameEditor = false }
                    },
                    onCancel: {
                        withAnimation(.easeOut(duration: 0.2)) { showNameEditor = false }
                    }
                )
                .transition(.opacity)
            }
        }
        .task {
            premium.startInitialRefresh()
            totalCards = Progress.store.totalCards
            refreshTopicCardTotal()
            synchronizeUnlockPrompt(animated: false)
            startTutorialLevelIfRequested()
        }
        .onChange(of: topicRaw) { _, _ in
            refreshTopicCardTotal()
        }
        .onChange(of: progressSync.revision) { _, _ in
            // The cloud pass writes a complete local snapshot before changing
            // the revision, so this is one cheap UI update rather than hundreds
            // of cloud-backed reads during layout.
            totalCards = Progress.store.totalCards
            refreshTopicCardTotal()
        }
        .onChange(of: totalCards) { _, _ in
            // A returning session banks its cards before any of the celebration
            // is visible. Hold the old prompt until that flow releases it;
            // iCloud or restored progress may update it right away.
            guard celebration == nil, !holdsPreSessionValues else { return }
            synchronizeUnlockPrompt(animated: unlockPrompt != nil)
        }
        .onAppear {
            // Decode the selected character's gameplay frames while the menu is
            // calm, so the first answer does not pay for a PNG decode.
            SpaceLionPlayfield.prewarmArtwork(for: character)
            AppAudio.shared.prepare()
            AppAudio.shared.startMusic()
        }
        .onChange(of: character.id) { _, _ in
            SpaceLionPlayfield.prewarmArtwork(for: character)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            AppAudio.shared.startMusic()
        }
    }

    // MARK: - Menu card

    /// Everything above the level grid lives in one card, so the boundary
    /// between "settings for the next run" and "pick a level" stays obvious.
    private var menuCard: some View {
        HStack(alignment: .top, spacing: menuCardSpacing) {
            playerPanel
                .frame(width: playerPanelWidth)

            Rectangle()
                .fill(character.deepColor.opacity(0.2))
                .frame(width: 1)
                .padding(.vertical, 2)

            // The session choices form one long control block beside the
            // player. In landscape this is faster to scan than a tall sidebar
            // and leaves the entire next row available to the levels.
            VStack(spacing: menuControlSpacing) {
                topicPicker
                if topic.usesSupermixGrid {
                    supermixPicker
                } else {
                    modePicker
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(menuCardPadding)
        .spaceMenuPanel(accent: character.color, cornerRadius: 24, prominent: true)
    }

    /// The player side is exactly as tall as the two rows of controls across the
    /// divider: the character fills that height on the left, and beside it the
    /// three lines that describe the player sit at the top with the streak bar
    /// pushed to the bottom. The bar therefore starts where the character ends
    /// and finishes level with the row of subcategory buttons.
    private var playerPanel: some View {
        HStack(alignment: .center, spacing: isPad ? 16 : 10) {
            characterButton

            VStack(alignment: .leading, spacing: isPad ? 6 : 3) {
                Button {
                    nameDraft = playerName
                    showNameEditor = true
                } label: {
                    Text(verbatim: displayName)
                        .font(.system(size: isPad ? 36 : 18, weight: .heavy, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.58)
                }
                .buttonStyle(.plain)
                .foregroundStyle(character.deepColor)

                totalCounter
                topicHeader

                Spacer(minLength: isPad ? 5 : 4)

                StreakBar(accent: character.deepColor, height: streakBarHeight) {
                    NotificationManager.shared.requestAuthorizationOnStreakTap {
                        showGoalPicker = true
                    }
                }
                .popover(isPresented: $showGoalPicker, arrowEdge: .top) {
                    DailyGoalPicker(theme: character)
                        .padding()
                        .presentationCompactAdaptation(.popover)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: characterBox)
    }

    // MARK: Character

    private var characterButton: some View {
        let box = characterBox
        return ZStack {
            SpaceOrbitHalo(accent: character.color, diameter: box)
            CharacterPortrait(character: character,
                              side: box * 0.9,
                              magnification: 1.02)
        }
        .frame(width: box, height: box)
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        // One exclusive recognizer decides between the two actions. A
        // successful hold can therefore never fall through into the tap that
        // opens the character collection.
        .gesture(characterGesture)
        .accessibilityIdentifier("home-character")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { openCharacterCollectionFromCharacter() }
    }

    private var characterGesture: some Gesture {
        LongPressGesture(minimumDuration: 2, maximumDistance: 24)
            .exclusively(before: TapGesture())
            .onEnded { result in
                switch result {
                case .first(let completed) where completed:
                    restartOnboarding()
                case .second:
                    openCharacterCollectionFromCharacter()
                default:
                    break
                }
            }
    }

    private func openCharacterCollectionFromCharacter() {
        AppAudio.shared.playMenuTap()
        openCharacterCollection()
    }

    /// Grand total and selected-category total intentionally share the exact
    /// same icon-number-label grammar and typography.
    private var totalCounter: some View {
        let total = headerCount(start: celebration?.totalStart,
                                heldStart: lastPlayedTotal,
                                current: totalCards)
        return HStack(spacing: isPad ? 8 : 5) {
            CurrencyIcon(size: isPad ? 26 : 14)
                .scaleEffect(highlightsHeaderCards ? 1.32 : 1)
                .rotationEffect(.degrees(highlightsHeaderCards ? -10 : 0))
            CountingNumber(from: total.from,
                           to: total.to,
                           startedAt: total.at,
                           duration: Self.headerCountDuration)
            Text("home.totalLabel")
        }
        .font(.system(size: isPad ? 26 : 14, weight: .bold, design: .rounded))
        .foregroundStyle(character.deepColor)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: totalCards)
    }

    /// Recomputes the next animal to earn. The prompt is a stored value rather
    /// than a derived one so it can be held steady while a return celebration is
    /// still counting the total up, then swapped in one movement afterwards.
    private func synchronizeUnlockPrompt(animated: Bool) {
        let next: NextCharacterPrompt?
        if totalCards > 0,
           let milestone = CharacterUnlocks.nextMilestone(totalCards: totalCards) {
            next = NextCharacterPrompt(characterID: milestone.characterID,
                                       remaining: milestone.remaining)
        } else {
            // Before the first card, and once the last card character has been
            // earned, the line is simply the total.
            next = nil
        }

        guard next != unlockPrompt else { return }
        if animated {
            withAnimation(.easeInOut(duration: 0.28)) { unlockPrompt = next }
        } else {
            withTransaction(Transaction(animation: nil)) { unlockPrompt = next }
        }
    }

    // MARK: Topic

    private var topicHeader: some View {
        let count = headerCount(start: celebration?.topicStart,
                                heldStart: lastPlayedTopic,
                                current: topicCards)
        return HStack(spacing: isPad ? 8 : 5) {
            // The card that flies up from the level card aims here, so the
            // reward visibly joins this topic before the totals move.
            CurrencyIcon(size: isPad ? 26 : 14)
                .scaleEffect(highlightsHeaderCards ? 1.32 : 1)
                .rotationEffect(.degrees(highlightsHeaderCards ? -10 : 0))
                .reportAnchor("topicTotal")
            CountingNumber(from: count.from,
                           to: count.to,
                           startedAt: count.at,
                           duration: Self.headerCountDuration)
            Text(verbatim: L(key: topic.titleKey))
        }
        .font(.system(size: isPad ? 26 : 14, weight: .bold, design: .rounded))
        .foregroundStyle(character.deepColor)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }

    /// Cards earned across every level of the selected topic.
    private var topicCards: Int {
        topicCardTotal
    }

    /// Every board counts: a level's scores on two, three and four cards — and
    /// on each Supermix combination — all contribute to its topic, so switching
    /// never appears to wipe progress off the topic total.
    private func topicCards(for topic: MathTopic) -> Int {
        Progress.store.storedScoreTotal(for: topic)
    }

    private func refreshTopicCardTotal() {
        topicCardTotal = topicCards(for: topic)
    }

    /// The scoreboard the menu is currently showing for a level.
    private func board(for level: MathLevel) -> LevelBoard {
        LevelBoard(level: level, mixedVariant: mixedVariant, mode: practiceMode)
    }

    /// The score a level card shows. The level just played keeps its old score
    /// until the celebration is ready to count it up.
    private func heldBest(for level: MathLevel, board: LevelBoard) -> Int {
        if holdsPreSessionValues, level.id == lastPlayedLevelID { return lastPlayedLevelBest }
        return Progress.store.storedBestScore(board)
    }

    /// The six topics share the full width, matching the level cards below.
    private var topicPicker: some View {
        HStack(spacing: 0) {
            ForEach(Array(MathTopic.allCases.enumerated()), id: \.element.id) { index, option in
                topicButton(option)
                    .frame(width: topicButtonDiameter, height: topicButtonDiameter)

                if index < MathTopic.allCases.count - 1 {
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func topicButton(_ option: MathTopic) -> some View {
        let isSelected = option == topic
        return Button {
            // A long press may also end as a button tap; consume that trailing
            // action instead of switching topic.
            guard !suppressTopicTap else {
                suppressTopicTap = false
                return
            }
            AppAudio.shared.playMenuTap()
            // Tapping the already-selected topic reveals its description
            // instead of re-selecting it (which would do nothing).
            if isSelected {
                showInfoPopup(header: L("info.topic.header"),
                              message: L(key: option.detailKey),
                              anchorKey: "topic.\(option.rawValue)")
            } else {
                infoPopup = nil
                topicRaw = option.rawValue
            }
        } label: {
            topicIcon(option, isSelected: isSelected)
                .frame(maxWidth: .infinity)
                .frame(height: topicButtonDiameter)
                .background(
                    isSelected
                        ? AnyShapeStyle(LinearGradient(colors: [character.color, character.deepColor],
                                                       startPoint: .topLeading,
                                                       endPoint: .bottomTrailing))
                        : AnyShapeStyle(Color.white.opacity(0.72)),
                    in: Circle()
                )
                .overlay(Circle().stroke(character.color.opacity(isSelected ? 0.62 : 0.30),
                                         lineWidth: isSelected ? 1.5 : 1))
                .reportAnchor("topic.\(option.rawValue)")
                .animation(.snappy(duration: 0.2), value: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("topic-\(option.rawValue)")
        // Holding the star runs the return celebration end to end, which is the
        // only practical way to check the whole chain — card count-up, flight,
        // both totals and the unlock sheet — without playing two full levels.
        .highPriorityGesture(
            LongPressGesture(minimumDuration: 2).onEnded { _ in
                suppressTopicTap = true
                runReturnCelebrationSelfTest()
            },
            including: option == .mixed ? .all : .none
        )
    }

    private func topicIcon(_ option: MathTopic, isSelected: Bool) -> some View {
        // Bare glyphs, not the `.circle.fill` variants: the button already
        // provides the circle, so the only solid is the selected one. Per-symbol
        // point sizes even out their differing optical heights, and the glyph
        // tracks the circle so a wider row never leaves the symbols swimming.
        let scale = menuScale * topicButtonDiameter / (isPad ? 58 : 38)
        let size = option.symbolPointSize * scale
        return Image(systemName: option.symbolName)
            .font(.system(size: size, weight: .bold))
            .frame(height: 24 * scale)
            .foregroundStyle(isSelected ? .white : character.deepColor)
    }

    // MARK: Practice mode

    /// Order · Random · Mixed: three equally wide buttons that decide the order
    /// and the spread of the sums, not what they are about. On Fractions and
    /// Percentages the same three buttons carry different labels, because there
    /// they change the kind of sum instead — see `MathTopic.modeOverride`.
    ///
    /// The label stays on one line and shrinks to fit, so a longer word in
    /// another language still sits three abreast without shrinking the base
    /// size of the shorter labels.
    private var modePicker: some View {
        HStack(spacing: isPad ? 12 : 8) {
            ForEach(PracticeMode.allCases) { mode in
                let isSelected = mode == practiceMode
                Button {
                    AppAudio.shared.playMenuTap()
                    // Tapping the one already chosen explains it instead of
                    // re-selecting it, which would do nothing.
                    if isSelected {
                        showInfoPopup(header: L(key: mode.infoHeaderKey(for: topic)),
                                      message: L(key: mode.infoKey(for: topic)),
                                      anchorKey: "mode.\(mode.rawValue)")
                    } else {
                        infoPopup = nil
                        practiceModeRaw = mode.rawValue
                    }
                } label: {
                    Text(verbatim: L(key: mode.titleKey(for: topic)))
                        .font(.system(size: isPad ? 25 : 14.5, weight: .bold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .frame(maxWidth: .infinity)
                        .frame(height: modeButtonHeight)
                        .padding(.horizontal, isPad ? 8 : 2)
                        .background(
                            isSelected
                                ? AnyShapeStyle(LinearGradient(colors: [character.color,
                                                                        character.deepColor],
                                                               startPoint: .topLeading,
                                                               endPoint: .bottomTrailing))
                                : AnyShapeStyle(Color.white.opacity(0.72)),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(character.color.opacity(isSelected ? 0.58 : 0.30),
                                        lineWidth: isSelected ? 1.5 : 1)
                        )
                        .foregroundStyle(isSelected ? .white : character.deepColor)
                        .reportAnchor("mode.\(mode.rawValue)")
                        .animation(.snappy(duration: 0.2), value: isSelected)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("mode-\(mode.rawValue)")
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            }
        }
    }

    /// The four Supermix combinations, shown only while Supermix is selected.
    /// Each button spells out the operations it practises, and its width follows
    /// its own operators — so the ladder from `+ −` to `+ − × ÷ %` is visible in
    /// the button widths themselves. The row still spans exactly as wide as the
    /// topics above it: the space left over goes into the buttons rather than
    /// into gaps, which keeps the four reading as one group.
    private var supermixPicker: some View {
        let variants = MixedVariant.allCases
        let gap = supermixGap
        let glyphs = variants.reduce(CGFloat.zero) { $0 + supermixGlyphWidth($1) }
        return GeometryReader { proxy in
            let free = proxy.size.width - glyphs - gap * CGFloat(variants.count - 1)
            // Shared out over the eight button edges, but never below the inset
            // that keeps the glyphs clear of the rounded corners.
            let inset = max(supermixMinimumInset, free / CGFloat(variants.count * 2))
            HStack(spacing: gap) {
                ForEach(variants) { variant in
                    supermixButton(variant, inset: inset)
                }
            }
        }
        .frame(height: modeButtonHeight)
    }

    private func supermixButton(_ variant: MixedVariant, inset: CGFloat) -> some View {
        let isSelected = variant == mixedVariant
        return Button {
            AppAudio.shared.playMenuTap()
            // Tapping the one already chosen explains it instead.
            if isSelected {
                showInfoPopup(header: L("info.topic.header"),
                              message: L(key: variant.detailKey),
                              anchorKey: "super.\(variant.rawValue)")
            } else {
                infoPopup = nil
                mixedVariantRaw = variant.rawValue
            }
        } label: {
            supermixLabel(variant)
            .lineLimit(1)
            .foregroundStyle(isSelected ? .white : character.deepColor)
            .padding(.horizontal, inset)
            .frame(height: modeButtonHeight)
            .background(
                isSelected
                    ? AnyShapeStyle(LinearGradient(colors: [character.color, character.deepColor],
                                                   startPoint: .topLeading,
                                                   endPoint: .bottomTrailing))
                    : AnyShapeStyle(Color.white.opacity(0.68)),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(character.color.opacity(isSelected ? 0.58 : 0.32),
                        lineWidth: isSelected ? 1.5 : 1))
            .reportAnchor("super.\(variant.rawValue)")
            .animation(.snappy(duration: 0.2), value: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("supermix-\(variant.rawValue)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var supermixGap: CGFloat { isPad ? 10 : 7 }
    private var supermixMinimumInset: CGFloat { isPad ? 10 : 5 }
    private var supermixSlotSpacing: CGFloat { 2 }

    /// One slot per operator. They keep their full size until the row would
    /// stop fitting — on the narrowest phone the four buttons still have to sit
    /// side by side, so there the glyphs give way rather than the layout.
    private var supermixSlotWidth: CGFloat {
        let base: CGFloat = isPad ? 30 : 14
        guard controlColumnWidth > 0 else { return base }
        let variants = MixedVariant.allCases
        let slots = variants.reduce(CGFloat.zero) { total, variant in
            total + variant.operators.reduce(CGFloat.zero) {
                $0 + (MixedVariant.heavyOperatorGlyphs[$1] ?? 1)
            }
        }
        let spacings = variants.reduce(0) { $0 + $1.operationCount - 1 }
        let fixed = supermixSlotSpacing * CGFloat(spacings)
            + supermixGap * CGFloat(variants.count - 1)
            + supermixMinimumInset * CGFloat(variants.count * 2)
        return min(base, max(isPad ? 18 : 9, (controlColumnWidth - fixed) / slots))
    }

    /// What a button's operators occupy on their own, before any padding — the
    /// row's spacing is worked out from these.
    private func supermixGlyphWidth(_ variant: MixedVariant) -> CGFloat {
        let slots = variant.operators.reduce(CGFloat.zero) { total, symbol in
            total + supermixSlotWidth * (MixedVariant.heavyOperatorGlyphs[symbol] ?? 1)
        }
        return slots + supermixSlotSpacing * CGFloat(variant.operators.count - 1)
    }

    /// One equal slot per operator, so the glyphs inside a button are evenly
    /// spaced however many there are.
    ///
    /// `%` reads optically heavier than the rest at the same point size, so it
    /// gets its own smaller size and a narrower slot.
    private func supermixLabel(_ variant: MixedVariant) -> some View {
        let glyph = supermixSlotWidth * (isPad ? 0.91 : 1)
        let font = Font.system(size: glyph, weight: .heavy, design: .rounded)
        let heavyFont = Font.system(size: glyph * 0.82, weight: .heavy, design: .rounded)

        return HStack(spacing: supermixSlotSpacing) {
            ForEach(Array(variant.operators.enumerated()), id: \.offset) { _, symbol in
                let heavy = MixedVariant.heavyOperatorGlyphs[symbol]
                Text(verbatim: symbol)
                    .font(heavy == nil ? font : heavyFont)
                    .frame(width: supermixSlotWidth * (heavy ?? 1))
            }
        }
    }

    // MARK: - Info pop-out

    private func showInfoPopup(header: String, message: String, anchorKey: String) {
        guard let anchor = controlAnchors[anchorKey] else { return }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            infoPopup = InfoPopup(header: header, message: message, anchor: anchor)
        }
        // Self-dismissing, so it never gets in the way of the next choice.
        let shown = infoPopup?.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.6) {
            guard infoPopup?.id == shown else { return }
            withAnimation(.easeOut(duration: 0.22)) { infoPopup = nil }
        }
    }

    @ViewBuilder
    private var infoPopoutOverlay: some View {
        if let popup = infoPopup, viewportWidth > 0 {
            let horizontalInset: CGFloat = isPad ? 26 : 16
            let maximumWidth = viewportWidth - horizontalInset * 2
            let width = InfoPopoutCard.preferredWidth(header: popup.header,
                                                      message: popup.message,
                                                      isPad: isPad,
                                                      maximum: maximumWidth)
            // Centre the card under its control, then keep it fully on screen.
            let desiredX = popup.anchor.midX - width / 2
            let clampedX = min(max(horizontalInset, desiredX),
                               max(horizontalInset, viewportWidth - horizontalInset - width))
            let caretOffset = popup.anchor.midX - (clampedX + width / 2)

            InfoPopoutCard(header: popup.header,
                           message: popup.message,
                           caretOffset: caretOffset,
                           theme: character)
                .frame(width: width)
                .offset(x: clampedX, y: popup.anchor.maxY + 4)
                .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .top)))
                .allowsHitTesting(false)
        }
    }

    // MARK: - Level grid

    private var levelGrid: some View {
        let levels = LevelCatalog.levels(for: topic)
        let regular = levels.filter { !$0.requiresPremium }
        let premiumLevels = levels.filter { $0.requiresPremium }
        let hasProgress = topicCardTotal > 0
        let recommendedID = hasProgress ? nil : regular.first?.id

        return VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(columns: levelGridColumns,
                      alignment: .leading,
                      spacing: levelGridSpacing) {
                ForEach(regular) { level in
                    levelCard(level, recommendedID: recommendedID)
                        .frame(height: levelCardHeight)
                }
            }

            if !premiumLevels.isEmpty {
                premiumSection(premiumLevels)
            }
        }
    }

    private func levelCard(_ level: MathLevel, recommendedID: String?) -> some View {
        let board = board(for: level)
        return LevelCardView(
            level: level,
            status: status(for: level, recommendedID: recommendedID),
            best: heldBest(for: level, board: board),
            maximum: board.maximum,
            maxCompletions: Progress.store.storedMaxCompletionCount(board),
            pausedCards: PausedSessionStore.shared.session(board)?.cards,
            celebrationStart: celebration?.levelID == level.id
                ? celebration?.levelStart : nil,
            celebrationStartedAt: celebration?.levelID == level.id
                ? celebration?.startedAt : nil,
            cardHeight: levelCardHeight,
            theme: character
        ) {
            infoPopup = nil
            // Snapshot what this level and the total are worth *now*. This has
            // to happen on the tap: the cover's content builder re-runs while
            // the session is live, so anything captured there would be
            // overwritten with post-session values.
            rememberBeforePlaying(level)
            selection = LevelSelection(level: level)
        }
    }

    private func status(for level: MathLevel, recommendedID: String?) -> LevelCardStatus {
        if level.requiresPremium && !premium.isPremium { return .locked }
        // Completion is per board: the crown belongs to the scoreboard the
        // player is looking at, not to the level as a whole.
        let board = board(for: level)
        if Progress.store.storedBestScore(board) >= board.maximum { return .completed }
        if level.id == recommendedID { return .recommended }
        return .available
    }

    @ViewBuilder
    private func premiumSection(_ levels: [MathLevel]) -> some View {
        if premium.isPremium {
            VStack(spacing: 14) {
                HStack(spacing: 10) {
                    Rectangle()
                        .fill(character.deepColor.opacity(0.28))
                        .frame(height: 1.5)
                    HStack(spacing: 5) {
                        Text("menu.premiumLevels")
                            .font(.subheadline.weight(.bold))
                        Image(systemName: "crown.fill")
                            .font(.caption.weight(.bold))
                    }
                    .foregroundStyle(character.deepColor)
                    .fixedSize()
                    Rectangle()
                        .fill(character.deepColor.opacity(0.28))
                        .frame(height: 1.5)
                }

                LazyVGrid(columns: levelGridColumns,
                          alignment: .leading,
                          spacing: levelGridSpacing) {
                    ForEach(levels) { level in
                        levelCard(level, recommendedID: nil)
                            .frame(height: levelCardHeight)
                    }
                }
            }
        } else {
            Button {
                AppAudio.shared.playMenuTap()
                openCharacterCollection()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "crown.fill")
                        .font(.system(size: isPad ? 24 : 17, weight: .bold))
                        .foregroundStyle(.yellow)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("menu.moreLevels")
                            .font(.system(size: isPad ? 20 : 15, weight: .bold))
                            .foregroundStyle(.white)
                        Text("menu.unlockWithPremium")
                            .font(.system(size: isPad ? 16 : 12, weight: .regular))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                    Spacer()
                    Image(systemName: "chevron.forward")
                        .font(.system(size: isPad ? 20 : 15, weight: .bold))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.trailing, isPad ? 22 : 11)
                }
                .padding(isPad ? 20 : 14)
                .background(
                    LinearGradient(colors: [character.color, character.deepColor],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 14)
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("premium-levels")
        }
    }

    // MARK: - Actions

    /// Records what the level and the running total were worth before play, so
    /// the return can count up from there. The session banks its cards while
    /// the cover is still up and `@AppStorage` mirrors that write immediately,
    /// so reading these on dismissal would only ever see the new values.
    private func rememberBeforePlaying(_ level: MathLevel) {
        lastPlayedLevelID = level.id
        lastPlayedLevelBest = Progress.store.storedBestScore(board(for: level))
        lastPlayedTopic = topicCards(for: level.topic)
        lastPlayedTotal = Progress.store.totalCards
        holdsPreSessionValues = true
    }

    /// The hand-over from the welcome flow. The menu builds itself here, behind
    /// the welcome screen that is still on top, and the guided level rises over
    /// that — one continuous movement from the last answer into the game. Only
    /// once the level covers the screen is the welcome screen let go, out of
    /// sight, leaving the settled menu underneath to return to.
    private func startTutorialLevelIfRequested() {
        guard let level = TutorialCenter.shared.takeAutoStartLevel() else {
            TutorialCenter.shared.finishWelcomeHandover()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.tutorialHandoverDelay) {
            guard selection == nil else {
                TutorialCenter.shared.finishWelcomeHandover()
                return
            }
            rememberBeforePlaying(level)
            selection = LevelSelection(level: level, startsGuided: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.tutorialCoverDuration) {
                TutorialCenter.shared.finishWelcomeHandover()
            }
        }
    }

    private func openCharacterCollection(initialCharacterID: String? = nil) {
        premiumInitialCharacterID = initialCharacterID
        showPremium = true
    }

    private func restartOnboarding() {
        AppAudio.shared.playMenuTap()
        if let onRestartOnboarding {
            onRestartOnboarding()
        } else {
            withAnimation(.easeInOut(duration: 0.35)) {
                onboardingComplete = false
            }
        }
    }

    // MARK: Return celebration

    /// How long the two header counters take to reach their new value.
    private static let headerCountDuration = 0.95
    /// The moment the level card's own score has finished counting up, which is
    /// when the reward leaves the card.
    private static var cardSettleDelay: Double {
        LevelCardView.scoreCountDelay + LevelCardView.scoreCountDuration + 0.1
    }
    /// Gives the springing max card, planets and crown a clear beat on screen
    /// before the reward bubble starts its flight to the topic total.
    private static let maximumRevealPause = 0.9
    private static let flightDuration = 0.62

    /// The `(from, to, startedAt)` a header counter should use. It holds the
    /// pre-session value while the reward is still on the level card and in
    /// flight, then counts up the moment the card lands. Without a celebration
    /// it simply shows the live value.
    private func headerCount(start: Int?,
                             heldStart: Int,
                             current: Int) -> (from: Int, to: Int, at: Date?) {
        if let start, celebration != nil {
            // Both counters read this, so they always move as one.
            if let cardArrival { return (start, current, cardArrival) }
            return (start, start, nil)
        }
        // The session is still on screen, or its cover is closing: keep showing
        // what the player left with until the celebration takes over.
        if holdsPreSessionValues { return (heldStart, heldStart, nil) }
        return (current, current, nil)
    }

    // MARK: Tutorial

    /// How long the last welcome answer is left standing before the guided
    /// level rises over it. Just enough for the tick on the chosen row to
    /// register — the menu is being built behind it and needs no time of its
    /// own, so any longer only stalls the movement into the game.
    private static let tutorialHandoverDelay = 0.2

    /// The full-screen cover's own presentation. The welcome screen is held for
    /// this long after the level is asked for, so it is released behind a game
    /// that already covers it rather than in view.
    private static let tutorialCoverDuration = 0.7

    /// Back from a session: bank the totals and celebrate anything earned. The
    /// before-values are captured first, so the level score and the headers
    /// count up from what the player had rather than snapping to the new value.
    private func handleSessionDismissed() {
        recordSessionReturn()
    }

    private func recordSessionReturn() {
        let levelID = lastPlayedLevelID
        let levelStart = lastPlayedLevelBest
        let topicStart = lastPlayedTopic
        let totalStart = lastPlayedTotal

        totalCards = Progress.store.totalCards
        refreshTopicCardTotal()
        let levelNow = levelID
            .flatMap { LevelCatalog.level(id: $0) }
            .map { Progress.store.storedBestScore(board(for: $0)) } ?? 0

        if let levelID, levelNow > levelStart || totalCards > totalStart {
            let level = LevelCatalog.level(id: levelID)
            let revealsMaximum = level.map {
                levelStart < board(for: $0).maximum && levelNow >= board(for: $0).maximum
            } ?? false
            let celebration = ScoreCelebration(levelID: levelID,
                                               levelStart: levelStart,
                                               topicStart: topicStart,
                                               totalStart: totalStart,
                                               revealsMaximum: revealsMaximum)
            self.celebration = celebration
            cardArrival = nil
            // The celebration now owns these values, and it starts from the
            // very same ones the hold was showing.
            holdsPreSessionValues = false
            AppAudio.shared.playCardCount()
            // The level card counts up on its own first; the reward only leaves
            // it once that has landed.
            let departureDelay = Self.cardSettleDelay
                + (celebration.revealsMaximum ? Self.maximumRevealPause : 0)
            DispatchQueue.main.asyncAfter(deadline: .now() + departureDelay) {
                guard self.celebration?.id == celebration.id else { return }
                self.launchCardFlight(for: celebration)
            }
            // Clear it once every part of the celebration has played out.
            let lifetime = departureDelay + Self.flightDuration
                + Self.headerCountDuration + 0.12
            DispatchQueue.main.asyncAfter(deadline: .now() + lifetime) {
                guard self.celebration?.id == celebration.id else { return }
                self.celebration = nil
                self.cardArrival = nil
                // Card count, flight and totals are all finished now: preview
                // the new remaining count once, straight away.
                self.unlockPreviewTrigger &+= 1
                self.synchronizeUnlockPrompt(animated: true)
            }
            pendingUnlockIDs = CharacterUnlockStore.unannouncedUnlocks(at: totalCards).map(\.id)
            // Let the whole celebration play before a character sheet takes over.
            DispatchQueue.main.asyncAfter(deadline: .now() + lifetime + 0.25) {
                presentNextUnlockIfAny()
            }
        } else {
            holdsPreSessionValues = false
            synchronizeUnlockPrompt(animated: unlockPrompt != nil)
            pendingUnlockIDs = CharacterUnlockStore.unannouncedUnlocks(at: totalCards).map(\.id)
            presentNextUnlockIfAny()
        }
    }

    /// Sends one card arcing from the level card's glyph up to the topic
    /// counter, which is what makes the score feel like it was carried there.
    /// If either endpoint is unknown the reward simply lands straight away.
    private func launchCardFlight(for celebration: ScoreCelebration) {
        guard let source = cardGlyphAnchors[celebration.levelID],
              let destination = controlAnchors["topicTotal"] else {
            landHeaderCards(for: celebration)
            return
        }
        let flight = CardFlight(celebrationID: celebration.id,
                                source: source,
                                destination: destination,
                                sourcePointSize: isPad ? 13 : 9,
                                destinationPointSize: isPad ? 22 : 15,
                                arcHeight: isPad ? 64 : 44,
                                color: celebration.revealsMaximum
                                    ? LevelCardView.completedPalette(for: character).hero
                                    : character.color,
                                startedAt: Date(),
                                duration: Self.flightDuration)
        flights.append(flight)
        AppAudio.shared.playCardFlight()
        DispatchQueue.main.asyncAfter(deadline: .now() + flight.duration) {
            flights.removeAll { $0.id == flight.id }
            landHeaderCards(for: celebration)
        }
    }

    /// The reward merges into the header: the topic total and the grand total
    /// start counting at the same instant, and the topic glyph gives a small
    /// welcoming pulse.
    private func landHeaderCards(for celebration: ScoreCelebration) {
        guard self.celebration?.id == celebration.id else { return }
        cardArrival = Date()
        AppAudio.shared.playCardTotal()
        withAnimation(.spring(response: 0.42, dampingFraction: 0.56)) {
            highlightsHeaderCards = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.66) {
            withAnimation(.easeOut(duration: 0.24)) {
                highlightsHeaderCards = false
            }
        }
    }

    // MARK: Self-test

    /// Drives the complete return sequence twice from the menu, then hands over
    /// to a real character unlock. Everything runs through the same code a
    /// finished session uses, so what it shows is what a player would see.
    ///
    /// This writes real progress: both levels are pushed to their maximum and
    /// the total is topped up to the next milestone.
    private func runReturnCelebrationSelfTest() {
        let levels = LevelCatalog.levels(for: topic).filter { !$0.requiresPremium }
        guard levels.count >= 2 else { return }

        let full = board(for: levels[0]).maximum
        // One celebration from start to the moment the unlock sheet may appear.
        let step = Self.cardSettleDelay + Self.maximumRevealPause + Self.flightDuration
            + Self.headerCountDuration + 0.6

        awardForSelfTest(levels[0], cards: full)
        DispatchQueue.main.asyncAfter(deadline: .now() + step) {
            // Top the running total up to the next milestone, so the second
            // return ends on a genuine unlock rather than a simulated one.
            if let milestone = CharacterUnlocks.nextMilestone(totalCards: Progress.store.totalCards) {
                var announced = Progress.store.announcedUnlocks
                announced.remove(milestone.characterID)
                Progress.store.announcedUnlocks = announced
            }
            awardForSelfTest(levels[1], cards: full, reachNextMilestone: true)
        }
    }

    /// Banks a score exactly the way a finished session does, then runs the
    /// ordinary return handler so the whole celebration plays.
    private func awardForSelfTest(_ level: MathLevel,
                                  cards: Int,
                                  reachNextMilestone: Bool = false) {
        rememberBeforePlaying(level)
        let store = Progress.store
        let board = board(for: level)
        let gained = max(0, min(cards, board.maximum) - store.bestScore(board))
        _ = store.recordScore(cards, board: board)
        store.recordMaxCompletion(board)
        _ = store.addCards(gained)
        if reachNextMilestone,
           let milestone = CharacterUnlocks.nextMilestone(totalCards: store.totalCards) {
            _ = store.addCards(milestone.remaining)
        }
        handleSessionDismissed()
    }

    private func presentNextUnlockIfAny() {
        guard !showPremium, !pendingUnlockIDs.isEmpty else { return }
        let next = pendingUnlockIDs.removeFirst()
        CharacterUnlockStore.markAnnounced(next)
        celebratedUnlockID = next
        premiumInitialCharacterID = next
        showPremium = true
    }
}
