//
//  OnboardingView.swift
//  Elephant Challenge: Math Memory
//
//  Welcome flow: name → topic → starting point.
//
//  The last step asks exactly the same question as the three order buttons in
//  the menu, only in children's language — it is literally a pre-selection of
//  `PracticeMode`. Pick the star on step two and there is no order to set, so
//  the same answer is mapped onto the star's simplest and most complete button
//  instead.
//

import SwiftUI
import UIKit

struct OnboardingView: View {
    var onFinished: (() -> Void)?

    @AppStorage(GameSettings.playerNameKey) private var playerName = ""
    @AppStorage(GameSettings.onboardingCompleteKey) private var isComplete = false
    @AppStorage(GameSettings.topicKey) private var topicRaw = MathTopic.allCases[0].rawValue
    @AppStorage(GameSettings.practiceModeKey) private var practiceModeRaw = PracticeMode.fallback.rawValue
    @AppStorage(GameSettings.mixedVariantKey) private var mixedVariantRaw = MixedVariant.allCases[0].rawValue
    @ObservedObject private var language = LanguageManager.shared
    @State private var step = 0
    @FocusState private var isNameFieldFocused: Bool

    @ObservedObject private var premium = PremiumStore.shared

    private var isPad: Bool { AppLayout.isPad }
    private var contentWidth: CGFloat { isPad ? 680 : 560 }
    private var onboardingCharacter: AnimalCharacter {
        CharacterCatalog.current(isPremium: premium.isPremium)
    }
    private var accent: Color { onboardingCharacter.color }
    private var deepAccent: Color { onboardingCharacter.deepColor }

    var body: some View {
        ZStack {
            onboardingBackground

            GeometryReader { proxy in
                ScrollView {
                    let horizontalPadding: CGFloat = isPad ? 48 : 24
                    let columnSpacing: CGFloat = isPad ? 48 : 24
                    let panelInset: CGFloat = isPad ? 28 : 18
                    let artworkSide = min(isPad ? 230 : 170,
                                          max(isPad ? 170 : 110, proxy.size.height * 0.42))
                    let stepWidth = min(contentWidth,
                        max(300, proxy.size.width - horizontalPadding * 2
                            - artworkSide - columnSpacing - panelInset * 2))

                    HStack(alignment: .center, spacing: columnSpacing) {
                        if onboardingCharacter.hangsOnLeadingSide {
                            onboardingArtwork(side: artworkSide)
                        }

                        Group {
                            switch step {
                            case 0: nameStep
                            case 1: subjectStep
                            default: practiceModeStep(availableWidth: stepWidth)
                            }
                        }
                        .id(step)
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                        .frame(width: stepWidth)

                        if !onboardingCharacter.hangsOnLeadingSide {
                            onboardingArtwork(side: artworkSide)
                        }
                    }
                    .padding(panelInset)
                    .spaceMenuPanel(accent: accent, cornerRadius: 30, prominent: true)
                    .padding(.horizontal, horizontalPadding)
                    // Reserve the complete flag/back-button band. Long titles
                    // can wrap without ever sliding underneath either control.
                    .padding(.top, isPad ? 76 : 60)
                    .padding(.bottom, isPad ? 28 : 18)
                    .frame(maxWidth: AppLayout.landscapeContentWidth)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .center)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .foregroundStyle(SpaceMenuPalette.ink)
        .overlay(alignment: .top) {
            onboardingProgress
                .padding(.top, isPad ? 30 : 17)
        }
        .overlay(alignment: .topLeading) {
            // Steps 2 and 3 can step back to correct a wrong choice. Mirrors
            // the language flag: same glass style, same top inset, left corner.
            if step > 0 {
                backButton
                    .padding(.top, isPad ? 20 : 8)
                    .padding(.leading, isPad ? 28 : 16)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .topTrailing) {
            LanguagePicker(tint: .white.opacity(0.88),
                           scale: isPad ? 1.25 : 1)
                .padding(.top, isPad ? 20 : 8)
                .padding(.trailing, isPad ? 28 : 16)
        }
    }

    private func onboardingArtwork(side: CGFloat) -> some View {
        // The name step's form is narrower than the columns on the next two
        // screens, which left the character hugging the card edge. Nudge it
        // toward the form so it sits in the middle of that open space.
        let nameStepNudge: CGFloat = step == 0 ? side * 0.34 : 0
        let towardForm = onboardingCharacter.hangsOnLeadingSide ? nameStepNudge : -nameStepNudge
        return ZStack {
            SpaceOrbitHalo(accent: accent, diameter: side)
            CharacterPortrait(character: onboardingCharacter,
                              side: side * 0.9,
                              magnification: 1.02)
        }
        .frame(width: side, height: side)
        .offset(x: towardForm)
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: onboardingCharacter.id)
    }

    private var backButton: some View {
        Button {
            advance(to: step - 1)
        } label: {
            Image(systemName: "chevron.backward")
                .font(.system(size: isPad ? 26 : 22, weight: .semibold))
                .foregroundStyle(.white.opacity(0.88))
                .padding(.horizontal, isPad ? 16 : 13)
                .padding(.vertical, isPad ? 11 : 8)
                .liquidGlassCapsule()
                .contentShape(Capsule())
        }
    }

    private var onboardingBackground: some View {
        SpaceMenuBackground(accent: accent)
    }

    /// A compact mission-progress rail that makes the three welcome pages read
    /// as one launch sequence without adding new localized copy.
    private var onboardingProgress: some View {
        HStack(spacing: isPad ? 9 : 7) {
            ForEach(0..<3, id: \.self) { index in
                Capsule()
                    .fill(index <= step ? accent : Color.white.opacity(0.28))
                    .frame(width: index == step ? (isPad ? 36 : 28) : (isPad ? 12 : 9),
                           height: isPad ? 8 : 6)
                    .shadow(color: index == step ? accent.opacity(0.7) : .clear,
                            radius: 5)
            }
        }
        .padding(.horizontal, isPad ? 16 : 13)
        .padding(.vertical, isPad ? 10 : 8)
        .background(SpaceMenuPalette.void.opacity(0.62), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.22), lineWidth: 1))
        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: step)
    }

    private var nameStep: some View {
        VStack(spacing: 24) {
            VStack(spacing: 10) {
                OnboardingTitle(
                    text: L("onboarding.name.title"),
                    fontSize: isPad ? 44 : 35
                )

                Text("onboarding.name.subtitle")
                    .font(isPad ? .title2.weight(.medium) : .title3.weight(.medium))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }

            TextField(String(), text: $playerName, prompt: Text("name.placeholder"))
                .font(.system(size: isPad ? 34 : 26, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)
                .focused($isNameFieldFocused)
                .textContentType(.name)
                .submitLabel(.next)
                .onSubmit { goToSubjects() }
                .padding(.horizontal, isPad ? 22 : 16)
                .padding(.vertical, isPad ? 18 : 14)
                .background(.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(isNameFieldFocused ? accent : deepAccent.opacity(0.18),
                                lineWidth: isNameFieldFocused ? 2 : 1)
                )
                .frame(maxWidth: isPad ? 400 : 300)
                .animation(.snappy(duration: 0.2), value: isNameFieldFocused)

            Button("common.continue") { goToSubjects() }
                .buttonStyle(OnboardingButtonStyle(isPad: isPad,
                                                   accent: accent,
                                                   deepAccent: deepAccent))
                .frame(width: isPad ? 260 : 210)
        }
    }

    private var subjectStep: some View {
        VStack(spacing: 14) {
            OnboardingTitle(
                text: L("onboarding.subject.title"),
                fontSize: isPad ? 42 : 32
            )

            Text("onboarding.subject.subtitle")
                .font(isPad ? .title3 : .body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 4)

            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: isPad ? 12 : 9),
                GridItem(.flexible(), spacing: isPad ? 12 : 9)
            ], spacing: isPad ? 12 : 9) {
                ForEach(MathTopic.allCases) { option in
                    Button {
                        topicRaw = option.rawValue
                        advance(to: 2)
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: option.symbolName)
                                .font(.system(size: isPad ? 28 : 21, weight: .bold))
                                .frame(width: isPad ? 44 : 30)
                            Text(verbatim: L(key: option.titleKey))
                                .font(isPad ? .title3.weight(.semibold) : .title3.weight(.semibold))
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.forward")
                                .font(.footnote.weight(.bold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, isPad ? 26 : 16)
                        .frame(maxWidth: .infinity, minHeight: isPad ? 68 : 52)
                        .background(.white.opacity(0.78), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(accent.opacity(0.26), lineWidth: 1.25)
                        }
                    }
                    .buttonStyle(OnboardingOptionStyle())
                    .accessibilityIdentifier("onboarding-topic-\(option.rawValue)")
                    .foregroundStyle(deepAccent)
                }
            }
        }
    }

    private var topic: MathTopic { MathTopic(rawValue: topicRaw) ?? MathTopic.allCases[0] }

    /// The three starting points, in the same order as the buttons in the menu.
    private static let modeChoices:
        [(mode: PracticeMode, startingLevel: Int, titleKey: String, subtitleKey: String)] = [
        (.order,  2,  "onboarding.level.beginner.title",     "onboarding.level.beginner.subtitle"),
        (.random, 5,  "onboarding.level.intermediate.title", "onboarding.level.intermediate.subtitle"),
        (.mixed,  10, "onboarding.level.advanced.title",     "onboarding.level.advanced.subtitle")
    ]

    /// The last step: how far along the player already is. This is the same
    /// question the three order buttons ask, phrased for a child — answering it
    /// leaves the menu already set the way they said, and hands over to it.
    private func practiceModeStep(availableWidth: CGFloat) -> some View {
        let sizing = choiceSizing(
            titles: Self.modeChoices.map { L(key: $0.titleKey) },
            subtitles: Self.modeChoices.map { L(key: $0.subtitleKey) },
            availableWidth: availableWidth
        )
        return VStack(spacing: isPad ? 14 : 10) {
            OnboardingTitle(
                text: L("onboarding.level.title"),
                fontSize: isPad ? 42 : 32
            )

            ForEach(Self.modeChoices, id: \.mode) { choice in
                Button { select(choice) } label: {
                    OnboardingChoiceLabel(
                        title: L(key: choice.titleKey),
                        subtitle: L(key: choice.subtitleKey),
                        icon: choice.mode.symbolName,
                        textScale: sizing.scale,
                        allowsTwoLines: sizing.allowsTwoLines,
                        rowHeight: sizing.rowHeight,
                        isSelected: choice.mode.rawValue == practiceModeRaw,
                        accent: accent,
                        deepAccent: deepAccent
                    )
                }
                .buttonStyle(OnboardingOptionStyle())
                .accessibilityIdentifier("onboarding-mode-\(choice.mode.rawValue)")
            }
        }
    }

    /// Stores the chosen starting point and hands over to the home screen.
    /// Supermix has no order buttons of its own, so the same answer is mapped
    /// onto its ladder: the most confident choice opens the most complete
    /// combination, the other two start on the simplest.
    ///
    /// The selection lands first, so the tick is visible for the moment the
    /// welcome flow fades out rather than the screen swapping out under the tap.
    ///
    /// This is also where the welcome flow hands over to the tutorial: the last
    /// answer chooses the exercise and its starting level is opened, guided,
    /// the moment the menu has settled — so the first thing a child does after
    /// being asked three questions is play.
    private func select(_ choice: (mode: PracticeMode, startingLevel: Int, titleKey: String, subtitleKey: String)) {
        let mode = choice.mode
        withAnimation(.snappy(duration: 0.18)) {
            practiceModeRaw = mode.rawValue
        }
        if topic.usesSupermixGrid {
            let target = mode == .mixed ? MixedVariant.allCases.last : MixedVariant.allCases.first
            if let target { mixedVariantRaw = target.rawValue }
        }
        TutorialCenter.shared.requestAutoStart(topic: topic, index: choice.startingLevel)
        AppAudio.shared.playMenuTap()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            isComplete = true
            onFinished?()
        }
    }

    /// Uses one shared scale for every row of a choice step, based on the
    /// widest title or subtitle in the active language, so the rows look
    /// identical in every language. If a modest scale-down is not enough, all
    /// three rows grow equally and may use a second line.
    private func choiceSizing(
        titles: [String],
        subtitles: [String],
        availableWidth: CGFloat
    ) -> (scale: CGFloat, allowsTwoLines: Bool, rowHeight: CGFloat) {
        let titleSize: CGFloat = isPad ? 20 : 20
        let subtitleSize: CGFloat = isPad ? 17 : 16
        let titleFont = UIFont.systemFont(ofSize: titleSize, weight: .semibold)
        let subtitleFont = UIFont.systemFont(ofSize: subtitleSize)
        let titleAttributes: [NSAttributedString.Key: Any] = [.font: titleFont]
        let subtitleAttributes: [NSAttributedString.Key: Any] = [.font: subtitleFont]

        let widestTitle = titles.map {
            ($0 as NSString).size(withAttributes: titleAttributes).width
        }.max() ?? 0
        let widestSubtitle = subtitles.map {
            ($0 as NSString).size(withAttributes: subtitleAttributes).width
        }.max() ?? 0
        let widestText = max(widestTitle, widestSubtitle)

        // Space occupied by the row padding, icon, trailing glyph and HStack
        // gaps. The trailing glyph is measured at its widest: the selected row
        // carries a tick rather than a chevron, and reserving only the chevron
        // is what used to truncate the longest subtitle on exactly that row.
        // A small safety inset avoids wrapping caused by fractional glyph
        // measurements at different display scales.
        let reservedWidth: CGFloat = isPad ? 190 : 146
        let textWidth = max(1, availableWidth - reservedWidth)
        let requiredScale = min(1, textWidth / max(1, widestText))
        let minimumComfortableScale: CGFloat = isPad ? 0.82 : 0.78
        let allowsTwoLines = requiredScale < minimumComfortableScale
        let scale = max(requiredScale, minimumComfortableScale)
        let rowHeight: CGFloat = isPad
            ? (allowsTwoLines ? 120 : 94)
            : (allowsTwoLines ? 88 : 62)

        return (scale, allowsTwoLines, rowHeight)
    }

    private func goToSubjects() {
        let trimmedName = playerName.trimmingCharacters(in: .whitespacesAndNewlines)
        // Keep an omitted name empty in storage. The displayed fallback is
        // resolved live, so changing the app language also changes Frog/Kikker.
        playerName = trimmedName
        isNameFieldFocused = false
        advance(to: 1)
    }

    private func advance(to newStep: Int) {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.84)) {
            step = newStep
        }
    }
}

/// Keeps translated onboarding headings compact without leaving an orphaned
/// word on the second line. A short heading is allowed to remain on one line;
/// otherwise the fallback inserts the most visually even word-boundary break.
private struct OnboardingTitle: View {
    let text: String
    let fontSize: CGFloat

    private var normalizedText: String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private var balancedText: String {
        Self.balancedTwoLineText(normalizedText, fontSize: fontSize)
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            // `fixedSize` makes this candidate report its true one-line width,
            // so ViewThatFits only chooses it when it genuinely fits.
            titleText(normalizedText)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: true)

            titleText(balancedText)
                .lineLimit(2)
                .minimumScaleFactor(0.68)
                .allowsTightening(true)
                .fixedSize(horizontal: false, vertical: true)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    private func titleText(_ value: String) -> some View {
        Text(verbatim: value)
            .font(.system(size: fontSize, weight: .heavy, design: .rounded))
    }

    private static func balancedTwoLineText(_ text: String, fontSize: CGFloat) -> String {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count > 1 else { return text }

        let baseFont = UIFont.systemFont(ofSize: fontSize, weight: .heavy)
        let font = baseFont.fontDescriptor.withDesign(.rounded)
            .map { UIFont(descriptor: $0, size: fontSize) } ?? baseFont
        let attributes: [NSAttributedString.Key: Any] = [.font: font]

        var bestIndex = 1
        var smallestDifference = CGFloat.greatestFiniteMagnitude

        for index in 1..<words.count {
            let firstLine = words[..<index].joined(separator: " ")
            let secondLine = words[index...].joined(separator: " ")
            let firstWidth = (firstLine as NSString).size(withAttributes: attributes).width
            let secondWidth = (secondLine as NSString).size(withAttributes: attributes).width
            let difference = abs(firstWidth - secondWidth)

            if difference < smallestDifference {
                smallestDifference = difference
                bestIndex = index
            }
        }

        return words[..<bestIndex].joined(separator: " ")
            + "\n"
            + words[bestIndex...].joined(separator: " ")
    }
}

private struct OnboardingButtonStyle: ButtonStyle {
    let isPad: Bool
    let accent: Color
    let deepAccent: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(isPad ? .title3.weight(.bold) : .headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, isPad ? 22 : 15)
            .background(
                LinearGradient(colors: [accent, deepAccent],
                               startPoint: .topLeading,
                               endPoint: .bottomTrailing),
                in: Capsule()
            )
            .overlay(Capsule().stroke(.white.opacity(0.46), lineWidth: 1))
            .shadow(color: accent.opacity(0.28), radius: 8, y: 4)
            .foregroundStyle(.white)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
    }
}

private struct OnboardingOptionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(.white.opacity(configuration.isPressed ? 0.52 : 0), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
}

private struct OnboardingChoiceLabel: View {
    let title: String
    let subtitle: String
    let icon: String
    let textScale: CGFloat
    let allowsTwoLines: Bool
    let rowHeight: CGFloat
    /// The topic step has no persisted choice yet, so it opts out.
    var isSelected = false
    let accent: Color
    let deepAccent: Color
    private var isPad: Bool { AppLayout.isPad }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
            .font(isPad ? .title2 : .title3)
            .frame(width: isPad ? 44 : 30)
                .foregroundStyle(deepAccent)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 20 * textScale, weight: .semibold))
                    .lineLimit(allowsTwoLines ? 2 : 1)
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle)
                    .font(.system(size: (isPad ? 17 : 16) * textScale))
                    .lineLimit(allowsTwoLines ? 2 : 1)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            // A tick on the active choice, a chevron on the rest, so the
            // selected option is unmistakable.
            Image(systemName: isSelected ? "checkmark.circle.fill" : "chevron.forward")
                .font(isSelected ? .title3.weight(.bold) : .footnote.weight(.bold))
                .foregroundStyle(isSelected ? deepAccent : .secondary)
        }
        .padding(.horizontal, isPad ? 26 : 16)
        .frame(maxWidth: .infinity)
        .frame(height: rowHeight)
        .background(isSelected ? AnyShapeStyle(accent.opacity(0.18))
                               : AnyShapeStyle(.white.opacity(0.78)),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(accent.opacity(isSelected ? 0.95 : 0.24),
                        lineWidth: isSelected ? 2.5 : 1.25)
        )
        .foregroundStyle(SpaceMenuPalette.ink)
        .animation(.easeInOut(duration: 0.18), value: isSelected)
    }
}
