//
//  PromoStillCompositionView.swift
//  Flying Penguin
//
//  Deterministic App Store stills built from the production playfield, rig,
//  menu background and level-card components.
//

import SwiftUI

enum PromoStillKind: String, CaseIterable {
    case turbo
    case dive
    case menu

    var headline: String {
        switch self {
        case .turbo: return "Fly, dive and master math"
        case .dive: return "Easy controls, endless fun"
        case .menu: return "Pick your topic and level"
        }
    }

    var filenameStem: String {
        switch self {
        case .turbo: return "app-store-still-fly-dive-math"
        case .dive: return "app-store-still-easy-controls"
        case .menu: return "app-store-still-pick-topic-level"
        }
    }
}

struct PromoStillCompositionView: View {
    let kind: PromoStillKind
    let outputSize: CGSize

    var body: some View {
        Group {
            switch kind {
            case .turbo, .dive:
                PromoGameplayStill(kind: kind, outputSize: outputSize)
            case .menu:
                PromoMenuStill(outputSize: outputSize)
            }
        }
        .frame(width: outputSize.width, height: outputSize.height)
        .clipped()
        .environment(\.colorScheme, .light)
    }
}

private struct PromoGameplayStill: View {
    let kind: PromoStillKind
    let outputSize: CGSize

    private let penguin = CharacterCatalog.character(id: "flying_penguin")

    private var isPadCanvas: Bool { outputSize.height / outputSize.width > 0.62 }
    private var waterline: CGFloat { outputSize.height * 0.90 }
    private var playerSize: CGFloat { outputSize.height * (isPadCanvas ? 0.245 : 0.235) }
    private var hoopSize: CGFloat {
        let questionBottom = outputSize.height * 0.141
        let answerBottom = waterline - outputSize.height * 0.012
        return max(1, (answerBottom - questionBottom) / 3)
    }
    private var lanes: [CGFloat] {
        let first = outputSize.height * 0.141 + hoopSize * 0.5
        return [first, first + hoopSize, first + hoopSize * 2]
    }
    /// Timing / question anchor kept mid-right so the marketing composition
    /// still has breathing room left of the flush answer column.
    private var hoopX: CGFloat { outputSize.width * (isPadCanvas ? 0.69 : 0.71) }
    /// Answer buttons sit flush against the trailing edge.
    private var answerButtonX: CGFloat { outputSize.width - hoopSize * 0.47 }
    private var playerX: CGFloat {
        if kind == .turbo {
            // The gameplay anchor sits directly below the marketing capsule,
            // leaving the complete answer stack readable on the right.
            return outputSize.width * 0.29
        }
        // Keep a full, obvious control gap before the bottom button. The brief
        // asks for roughly another fifth of the complete screen width here.
        return answerButtonX - hoopSize * 0.78 - outputSize.width * 0.20
    }
    private var playerY: CGFloat { kind == .turbo ? lanes[1] : lanes[2] }
    private var worldOffset: CGFloat { -outputSize.width * 0.22 }

    var body: some View {
        ZStack {
            worldBack

            if kind == .turbo {
                TurboSpeedWake(size: playerSize, phase: 0.68)
                    .position(x: playerX - playerSize * 0.58, y: playerY)
                    .opacity(0.96)
            }

            questionBadge
                .position(x: hoopX, y: outputSize.height * 0.090)
            hoopColumn

            RiggedPenguin(size: playerSize,
                          rig: penguin.rig,
                          pose: kind == .turbo ? .flying : .diving,
                          flightMotion: kind == .turbo ? .level : .falling,
                          reduceMotion: kind == .dive,
                          flightClock: 0.68)
                .position(x: playerX, y: playerY)
                .shadow(color: .black.opacity(0.18), radius: playerSize * 0.035, y: playerSize * 0.022)

            worldFront
            headline
        }
    }

    private var worldBack: some View {
        ZStack {
            PolarSkyLayer(size: outputSize, worldOffset: worldOffset, theme: SceneryThemes.polar)
            SceneryHorizonBand(size: outputSize,
                               waterline: waterline,
                               worldOffset: worldOffset,
                               theme: SceneryThemes.polar)
            PolarWaterBackdrop(size: outputSize,
                               waterline: waterline,
                               worldOffset: worldOffset,
                               isPad: isPadCanvas,
                               theme: SceneryThemes.polar)
            DriftingFloaters(size: outputSize,
                             waterline: waterline,
                             worldOffset: worldOffset,
                             isPad: isPadCanvas,
                             depth: .behind,
                             theme: SceneryThemes.polar)
        }
    }

    private var worldFront: some View {
        ZStack {
            PolarWaterForeground(size: outputSize,
                                 waterline: waterline,
                                 worldOffset: worldOffset,
                                 isPad: isPadCanvas,
                                 theme: SceneryThemes.polar)
            DriftingFloaters(size: outputSize,
                             waterline: waterline,
                             worldOffset: worldOffset,
                             isPad: isPadCanvas,
                             depth: .front,
                             theme: SceneryThemes.polar)
        }
    }

    private var headline: some View {
        Text(verbatim: kind.headline)
            .font(.system(size: outputSize.height * (isPadCanvas ? 0.041 : 0.054),
                          weight: .black,
                          design: .rounded))
            .foregroundStyle(penguin.deepColor)
            .lineLimit(1)
            .minimumScaleFactor(0.68)
            .padding(.horizontal, outputSize.height * 0.025)
            .padding(.vertical, outputSize.height * 0.012)
            .background(.white.opacity(0.94), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.92), lineWidth: 3))
            .shadow(color: .black.opacity(0.14), radius: outputSize.height * 0.010, y: outputSize.height * 0.005)
            .frame(maxWidth: outputSize.width * 0.52)
            .position(x: outputSize.width * 0.29,
                      y: max(outputSize.height * 0.064, outputSize.height * 0.042 + 12))
    }

    private var questionBadge: some View {
        let fontSize = outputSize.height * (isPadCanvas ? 0.048 : 0.060)
        let question = kind == .turbo ? "7 × 8" : "6 + 9"
        return Text(verbatim: question)
            .font(.system(size: fontSize, weight: .black, design: .rounded))
            .foregroundStyle(penguin.deepColor)
            .lineLimit(1)
            .padding(.horizontal, fontSize * 0.72)
            .padding(.vertical, fontSize * 0.30)
            .background(.white.opacity(0.95), in: Capsule())
            .overlay(Capsule().stroke(penguin.color.opacity(0.42), lineWidth: max(2, fontSize * 0.055)))
            .shadow(color: .black.opacity(0.12), radius: fontSize * 0.12, y: fontSize * 0.06)
    }

    private var answers: [String] {
        kind == .turbo ? ["46", "56", "66"] : ["5", "10", "20"]
    }

    private var hoopColumn: some View {
        ZStack {
            ForEach(Array(answers.enumerated()), id: \.offset) { index, text in
                AnswerHoop(text: text,
                           tint: penguin.color,
                           size: hoopSize,
                           textScale: 1,
                           feedback: .none,
                           isPressed: kind == .turbo && index == 1)
                    .position(x: answerButtonX, y: lanes[index])
            }
        }
    }
}

private struct PromoMenuStill: View {
    let outputSize: CGSize

    private let penguin = CharacterCatalog.character(id: "flying_penguin")
    private let scores = [40, 34, 29, 22, 16, 9, 4, 0, 40, 31, 13, 6]

    private var isPadCanvas: Bool { outputSize.height / outputSize.width > 0.62 }
    // These measurements are the production menu's landscape hierarchy,
    // scaled to the two store canvases rather than stretched per subview.
    private var outerInset: CGFloat { isPadCanvas ? 70 : 50 }
    private var contentTop: CGFloat { isPadCanvas ? 130 : 30 }
    private var menuHeight: CGFloat { isPadCanvas ? 290 : 210 }
    private var levelHeight: CGFloat { isPadCanvas ? 210 : 140 }
    private var gridGap: CGFloat { isPadCanvas ? 27 : 18 }
    private var sectionGap: CGFloat { isPadCanvas ? 26 : 18 }
    private var bannerHeight: CGFloat { isPadCanvas ? 144 : 96 }

    var body: some View {
        ZStack(alignment: .top) {
            MenuPolarBackground(accent: penguin.color)

            VStack(spacing: sectionGap) {
                menuCard
                    .frame(height: menuHeight)
                levelGrid
                promoBanner
                    .frame(height: bannerHeight)
            }
            .padding(.horizontal, outerInset)
            .padding(.top, contentTop)
        }
    }

    private var menuCard: some View {
        HStack(spacing: isPadCanvas ? 30 : 22) {
            playerPanel
                .frame(width: isPadCanvas ? 800 : 650)

            Rectangle()
                .fill(penguin.deepColor.opacity(0.20))
                .frame(width: 2)
                .padding(.vertical, isPadCanvas ? 4 : 2)

            VStack(spacing: isPadCanvas ? 22 : 15) {
                topicPicker
                modePicker
            }
            .frame(maxWidth: .infinity)
        }
        .padding(isPadCanvas ? 30 : 22)
        .background {
            RoundedRectangle(cornerRadius: isPadCanvas ? 32 : 25, style: .continuous)
                .fill(.white.opacity(0.78))
                .overlay {
                    RoundedRectangle(cornerRadius: isPadCanvas ? 32 : 25, style: .continuous)
                        .stroke(.white.opacity(0.92), lineWidth: 2)
                }
        }
        .shadow(color: penguin.deepColor.opacity(0.11), radius: 18, y: 9)
    }

    private var playerPanel: some View {
        HStack(spacing: isPadCanvas ? 24 : 16) {
            ZStack {
                RoundedRectangle(cornerRadius: isPadCanvas ? 24 : 18, style: .continuous)
                    .fill(LinearGradient(colors: [penguin.skyColor, penguin.tintColor],
                                         startPoint: .top,
                                         endPoint: .bottom))
                    .overlay {
                        RoundedRectangle(cornerRadius: isPadCanvas ? 24 : 18, style: .continuous)
                            .stroke(.white.opacity(0.92), lineWidth: 3)
                    }
                CharacterPortrait(character: penguin,
                                  side: isPadCanvas ? 196 : 142,
                                  magnification: 1.04)
            }
            .frame(width: isPadCanvas ? 218 : 158,
                   height: isPadCanvas ? 218 : 158)
            .shadow(color: penguin.deepColor.opacity(0.18), radius: 10, y: 5)

            VStack(alignment: .leading, spacing: isPadCanvas ? 10 : 7) {
                Text(verbatim: "Penguin")
                    .font(.system(size: isPadCanvas ? 36 : 27,
                                  weight: .heavy,
                                  design: .rounded))
                    .foregroundStyle(penguin.deepColor)

                counter(value: "2,400", label: "Total")
                counter(value: "800", label: "Times tables")

                Spacer(minLength: isPadCanvas ? 4 : 2)
                streakBar
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private var streakBar: some View {
        HStack(spacing: isPadCanvas ? 11 : 8) {
            HStack(spacing: 5) {
                Image(systemName: "sparkles")
                Text(verbatim: "Day 7")
            }
            .font(.system(size: isPadCanvas ? 20 : 15,
                          weight: .heavy,
                          design: .rounded))

            GeometryReader { proxy in
                Capsule()
                    .fill(penguin.deepColor.opacity(0.13))
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(penguin.deepColor.opacity(0.82))
                            .frame(width: proxy.size.width * 0.62)
                    }
            }
            .frame(height: isPadCanvas ? 9 : 7)

            Text(verbatim: "24/30 min")
                .font(.system(size: isPadCanvas ? 17 : 12.5, weight: .semibold))
                .fixedSize()
        }
        .foregroundStyle(penguin.deepColor.opacity(0.76))
        .padding(.horizontal, isPadCanvas ? 15 : 11)
        .frame(maxWidth: .infinity)
        .frame(height: isPadCanvas ? 42 : 31)
        .background(penguin.deepColor.opacity(0.08), in: Capsule())
    }

    private func counter(value: String, label: String) -> some View {
        HStack(spacing: isPadCanvas ? 12 : 8) {
            CurrencyIcon(size: isPadCanvas ? 28 : 21)
            Text(verbatim: value)
                .monospacedDigit()
            Text(verbatim: label)
        }
        .font(.system(size: isPadCanvas ? 24 : 18,
                      weight: .bold,
                      design: .rounded))
        .foregroundStyle(penguin.deepColor)
        .lineLimit(1)
    }

    private var topicPicker: some View {
        HStack(spacing: 0) {
            ForEach(Array(MathTopic.allCases.enumerated()), id: \.element.id) { index, topic in
                let selected = topic == .tables
                Image(systemName: topic.symbolName)
                    .font(.system(size: isPadCanvas ? 40 : 30, weight: .bold))
                    .foregroundStyle(selected ? .white : penguin.deepColor)
                    .frame(width: isPadCanvas ? 106 : 76,
                           height: isPadCanvas ? 106 : 76)
                    .background(selected ? penguin.deepColor : .white.opacity(0.72), in: Circle())
                    .overlay(Circle().stroke(penguin.deepColor.opacity(selected ? 0 : 0.25), lineWidth: 2))

                if index < MathTopic.allCases.count - 1 {
                    Spacer(minLength: isPadCanvas ? 12 : 8)
                }
            }
        }
    }

    private var modePicker: some View {
        HStack(spacing: isPadCanvas ? 20 : 14) {
            ForEach(PracticeMode.allCases) { mode in
                let selected = mode == .mixed
                let label: String = switch mode {
                case .order: "Order"
                case .random: "Random"
                case .mixed: "Mixed"
                }
                Text(verbatim: label)
                    .font(.system(size: isPadCanvas ? 25 : 18,
                                  weight: .bold,
                                  design: .rounded))
                    .frame(maxWidth: .infinity)
                    .frame(height: isPadCanvas ? 64 : 46)
                    .background(selected ? penguin.deepColor : .white.opacity(0.72),
                                in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(penguin.deepColor.opacity(selected ? 0 : 0.25), lineWidth: 2)
                    }
                    .foregroundStyle(selected ? .white : penguin.deepColor)
            }
        }
    }

    private var levelGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: gridGap), count: 4),
                  spacing: gridGap) {
            ForEach(Array(scores.enumerated()), id: \.offset) { index, score in
                let level = MathLevel(topic: .tables, index: index + 1)
                LevelCardView(level: level,
                              status: score == GameConfig.levelMaximum ? .completed : .available,
                              best: score,
                              maximum: GameConfig.levelMaximum,
                              maxCompletions: score == GameConfig.levelMaximum ? 2 : 0,
                              cardHeight: levelHeight,
                              theme: penguin,
                              action: {})
                    .frame(height: levelHeight)
            }
        }
    }

    private var promoBanner: some View {
        Text(verbatim: "Pick your topic and level")
            .font(.system(size: isPadCanvas ? 43 : 31,
                          weight: .black,
                          design: .rounded))
            .foregroundStyle(penguin.deepColor)
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .padding(.horizontal, isPadCanvas ? 34 : 26)
            .padding(.vertical, isPadCanvas ? 14 : 10)
            .background(.white.opacity(0.94), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.92), lineWidth: 3))
            .shadow(color: .black.opacity(0.13), radius: isPadCanvas ? 14 : 10, y: isPadCanvas ? 7 : 5)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
