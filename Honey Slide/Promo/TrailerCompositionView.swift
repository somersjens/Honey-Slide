//
//  TrailerCompositionView.swift
//  Flying Penguin
//
//  Development-only, deterministic App Store teaser composition. Every frame
//  is a pure function of time and output size, so both requested aspect ratios
//  share one edit while the wider export reveals only additional scenery.
//

import SwiftUI

enum TrailerRuntime {
    static let exportFlag = "--export-app-store-teaser"
    static let stillExportFlag = "--export-app-store-stills"
    static var isStillExporting: Bool {
#if TRAILER_EXPORT
        ProcessInfo.processInfo.arguments.contains(stillExportFlag)
#else
        false
#endif
    }
    static var isExporting: Bool {
#if TRAILER_EXPORT
        ProcessInfo.processInfo.arguments.contains(exportFlag) || isStillExporting
#else
        // A normal App Store build cannot enter trailer mode even if another
        // process happens to pass the development launch argument.
        false
#endif
    }
}

struct TrailerCompositionView: View {
    static let duration: Double = 22

    let time: Double
    let outputSize: CGSize

    private let penguin = CharacterCatalog.character(id: "flying_penguin")
    private let bunny = CharacterCatalog.character(id: "bunny")
    private let dog = CharacterCatalog.character(id: "dog")
    private let crab = CharacterCatalog.character(id: "crab")

    var body: some View {
        ZStack {
            worldBack

            turboTransitionWake

            chooseScene
                .opacity(sceneOpacity(start: 0, end: 4.15, fadeIn: 0, fadeOut: 0.18))
            unlockScene
                .opacity(sceneOpacity(start: 3.95, end: 8.45, fadeIn: 0.18, fadeOut: 0.12))
            funScene
                .opacity(sceneOpacity(start: 8.33, end: 13.65, fadeIn: 0.12, fadeOut: 0.18))
            learnScene
                .opacity(sceneOpacity(start: 13.42, end: 22, fadeIn: 0.18, fadeOut: 0))

            // The production playfield draws the translucent near water after
            // the character. That exact ordering is what makes a real dive
            // submerge instead of looking pasted over the sea.
            worldFront

            diveSplashes
            promoOverlay
            appIconFinale
            transitionEffects
        }
        .frame(width: outputSize.width, height: outputSize.height)
        .clipped()
        .environment(\.colorScheme, .light)
    }

    // MARK: - Production playfield geometry

    private var isPadCanvas: Bool { outputSize.height / outputSize.width > 0.62 }
    private var waterline: CGFloat { outputSize.height * 0.90 }
    private var playerX: CGFloat { outputSize.width * 0.25 }
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
    private var questionY: CGFloat { outputSize.height * 0.090 }
    private var diveY: CGFloat { waterline + playerSize * 0.68 }
    private var cruiseSpeed: CGFloat {
        let duration: CGFloat = isPadCanvas ? 5.45 : 5
        return (outputSize.width + hoopSize - playerX) / duration
    }
    private var teaserGameplaySpeed: CGFloat { cruiseSpeed * 1.50 }
    private var launchPadHeight: CGFloat {
        min(outputSize.height * 0.17, outputSize.width * 0.0785)
    }
    private var cannonWidth: CGFloat { outputSize.width * 0.269 }
    private var cannonHeight: CGFloat { outputSize.width * 0.179 }
    private var cannonCentreY: CGFloat {
        guard isPadCanvas else { return outputSize.height * 0.735 }
        let deckY = waterline
            - launchPadHeight * (PolarScene.padWaterline - PolarScene.padDeckFraction)
        let visibleWheelBottom = CGFloat(586) / CGFloat(683)
        let wheelOffset = cannonHeight * (visibleWheelBottom - 0.5)
        return deckY - wheelOffset + min(3, launchPadHeight * 0.035)
    }
    private var cannonMuzzleY: CGFloat { cannonCentreY - cannonHeight * 0.22 }

    private func clamp(_ value: Double, _ lower: Double = 0, _ upper: Double = 1) -> Double {
        min(upper, max(lower, value))
    }
    private func progress(_ start: Double, _ end: Double) -> Double {
        guard end > start else { return time >= end ? 1 : 0 }
        return clamp((time - start) / (end - start))
    }
    private func smooth(_ value: Double) -> Double {
        let t = clamp(value)
        return t * t * (3 - 2 * t)
    }
    private func lerp(_ a: CGFloat, _ b: CGFloat, _ amount: Double) -> CGFloat {
        a + (b - a) * CGFloat(amount)
    }
    private func sceneOpacity(start: Double, end: Double, fadeIn: Double, fadeOut: Double) -> Double {
        guard time >= start, time <= end else { return 0 }
        let incoming = fadeIn == 0 ? 1 : clamp((time - start) / fadeIn)
        let outgoing = fadeOut == 0 ? 1 : clamp((end - time) / fadeOut)
        return min(incoming, outgoing)
    }
    private func hoopPassageTime(start: Double) -> Double {
        let startX = outputSize.width + hoopSize * 0.55
        return start + Double((startX - playerX) / teaserGameplaySpeed)
    }
    private func movingSetX(start: Double, end: Double) -> CGFloat {
        let startX = outputSize.width + hoopSize * 0.55
        let passage = hoopPassageTime(start: start)
        if time <= passage {
            return startX - teaserGameplaySpeed * CGFloat(max(0, time - start))
        }
        // Never freeze a retired stack at the left edge. This matters most on
        // the taller iPad master, where its larger rings otherwise remained
        // partly visible underneath the finale.
        return playerX - teaserGameplaySpeed * CGFloat(max(0, time - passage))
    }

    // MARK: - Scrolling world, split like the game renderer

    private var worldDistance: CGFloat {
        // Once the near-finished fuse fires, the teaser uses the same cruise
        // velocity as the production playfield for its entire longer edit.
        let runningTime = max(0, time - 0.22)
        return -CGFloat(runningTime * Double(teaserGameplaySpeed))
    }
    private var worldBack: some View {
        ZStack {
            worldBack(theme: SceneryThemes.polar).opacity(polarThemeWeight)
            worldBack(theme: SceneryThemes.blossom).opacity(sceneOpacity(start: 3.95, end: 5.37, fadeIn: 0.22, fadeOut: 0.22))
            worldBack(theme: SceneryThemes.garden).opacity(sceneOpacity(start: 5.15, end: 6.59, fadeIn: 0.22, fadeOut: 0.22))
            worldBack(theme: SceneryThemes.lagoon).opacity(sceneOpacity(start: 6.37, end: 7.83, fadeIn: 0.22, fadeOut: 0.22))
        }
    }
    private var worldFront: some View {
        ZStack {
            worldFront(theme: SceneryThemes.polar).opacity(polarThemeWeight)
            worldFront(theme: SceneryThemes.blossom).opacity(sceneOpacity(start: 3.95, end: 5.37, fadeIn: 0.22, fadeOut: 0.22))
            worldFront(theme: SceneryThemes.garden).opacity(sceneOpacity(start: 5.15, end: 6.59, fadeIn: 0.22, fadeOut: 0.22))
            worldFront(theme: SceneryThemes.lagoon).opacity(sceneOpacity(start: 6.37, end: 7.83, fadeIn: 0.22, fadeOut: 0.22))
        }
    }
    private var polarThemeWeight: Double {
        if time < 4.15 { return sceneOpacity(start: 0, end: 4.15, fadeIn: 0, fadeOut: 0.20) }
        return clamp((time - 7.61) / 0.22)
    }
    private func worldBack(theme: SceneryTheme) -> some View {
        ZStack {
            PolarSkyLayer(size: outputSize, worldOffset: worldDistance, theme: theme)
            SceneryHorizonBand(size: outputSize,
                               waterline: waterline,
                               worldOffset: worldDistance,
                               theme: theme)
            PolarWaterBackdrop(size: outputSize,
                               waterline: waterline,
                               worldOffset: worldDistance,
                               isPad: isPadCanvas,
                               theme: theme)
            DriftingFloaters(size: outputSize,
                             waterline: waterline,
                             worldOffset: worldDistance,
                             isPad: isPadCanvas,
                             depth: .behind,
                             theme: theme)
        }
        .frame(width: outputSize.width, height: outputSize.height)
    }
    private func worldFront(theme: SceneryTheme) -> some View {
        ZStack {
            PolarWaterForeground(size: outputSize,
                                 waterline: waterline,
                                 worldOffset: worldDistance,
                                 isPad: isPadCanvas,
                                 theme: theme)
            DriftingFloaters(size: outputSize,
                             waterline: waterline,
                             worldOffset: worldDistance,
                             isPad: isPadCanvas,
                             depth: .front,
                             theme: theme)
        }
        .frame(width: outputSize.width, height: outputSize.height)
    }

    // MARK: - Choose the right hoop

    private var chooseScene: some View {
        let shotTime = 0.22
        let passage = hoopPassageTime(start: shotTime)
        let hoopX = movingSetX(start: shotTime, end: 4.15)
        let launch = smooth(progress(0.32, 1.04))
        let characterX = lerp(outputSize.width * 0.245, playerX, launch)
        let characterY = lerp(cannonMuzzleY, lanes[1], launch)
        let success = time >= passage
        let launchSiteOffset = -outputSize.width * 0.52 * CGFloat(smooth(progress(0.32, 1.09)))
            - outputSize.width * 0.10 * CGFloat(max(0, time - 1.09))
        let cannonStage = time < 0.05 ? 0 : (time < shotTime ? 1 : (time < 0.32 ? 2 : 3))
        let pose: PenguinPose = time < 0.05 ? .loaded
            : (time < shotTime ? .compressed
               : (time < 1.04 ? .launching
               : (abs(hoopX - characterX) < hoopSize * 0.62 ? .threading : .flying)))

        return ZStack {
            CannonLaunchPad(theme: SceneryThemes.polar)
                .frame(width: outputSize.width * 0.25, height: launchPadHeight)
                .position(x: outputSize.width * 0.145 + launchSiteOffset,
                          y: waterline + launchPadHeight * (0.5 - PolarScene.padWaterline))

            CannonLaunchScene(stage: cannonStage,
                              reduceMotion: true,
                              layer: .base,
                              deterministicFuseProgress: CGFloat(0.50 + min(0.08, time / shotTime * 0.08)))
                .frame(width: cannonWidth, height: cannonHeight)
                .position(x: outputSize.width * 0.145 + launchSiteOffset, y: cannonCentreY)

            questionBadge("7 × 8", character: penguin)
                .position(x: hoopX, y: questionY)
            hoopColumn(texts: ["46", "56", "66"],
                       character: penguin,
                       centreX: hoopX,
                       feedbackIndex: success ? 1 : nil)

            riggedCharacter(penguin,
                            size: playerSize,
                            pose: pose,
                            motion: launch < 0.92 ? .rising : .level)
                .position(x: characterX, y: characterY)
                .opacity(progress(0.32, 0.48))
                .shadow(color: .black.opacity(0.18), radius: 6, y: 4)

            if time < 1.11 {
                CannonLaunchScene(stage: cannonStage,
                                  reduceMotion: true,
                                  layer: .barrelForeground,
                                  deterministicFuseProgress: CGFloat(0.50 + min(0.08, time / shotTime * 0.08)))
                    .frame(width: cannonWidth, height: cannonHeight)
                    .position(x: outputSize.width * 0.145 + launchSiteOffset, y: cannonCentreY)
            }

            hoopForegroundColumn(character: penguin,
                                 centreX: hoopX,
                                 playerX: characterX,
                                 feedbackIndex: success ? 1 : nil)

            successSparkles(centre: CGPoint(x: hoopX, y: lanes[1]),
                             amount: progress(passage, passage + 0.40),
                             tint: .green)
                .opacity(success ? 1 : 0)
        }
    }

    // MARK: - One continuous character/environment transformation

    private var unlockScene: some View {
        return ZStack {
            transformingCharacter(bunny,
                                  opacity: sceneOpacity(start: 3.95, end: 5.37, fadeIn: 0.22, fadeOut: 0.22))
            transformingCharacter(dog,
                                  opacity: sceneOpacity(start: 5.15, end: 6.59, fadeIn: 0.22, fadeOut: 0.22))
            transformingCharacter(crab,
                                  opacity: sceneOpacity(start: 6.37, end: 7.83, fadeIn: 0.22, fadeOut: 0.22))
            transformingCharacter(penguin,
                                  opacity: sceneOpacity(start: 7.61, end: 8.45, fadeIn: 0.22, fadeOut: 0.12))
        }
    }

    private func transformingCharacter(_ animal: AnimalCharacter, opacity: Double) -> some View {
        riggedCharacter(animal, size: playerSize, pose: .flying, motion: .level)
            .position(x: playerX, y: lanes[1])
            .opacity(opacity)
            .shadow(color: animal.deepColor.opacity(0.22), radius: 7, y: 4)
    }

    @ViewBuilder
    private var turboTransitionWake: some View {
        let divePassage = hoopPassageTime(start: 8.33)
        let ascent = smooth(progress(divePassage + 0.40, divePassage + 1.32))
        let resurfacingY = lerp(diveY, lanes[1], ascent)
        let finalLaneY = lerp(lanes[1], lanes[0], smooth(progress(13.72, 14.52)))
        let y = time < 13.42 ? resurfacingY : finalLaneY
        let opacity = sceneOpacity(start: divePassage + 0.58,
                                   end: 14.90,
                                   fadeIn: 0.22,
                                   fadeOut: 0.38)
        if opacity > 0 {
            TurboSpeedWake(size: playerSize, phase: time)
                .position(x: playerX - playerSize * 0.58, y: y)
                .opacity(opacity)
        }
    }

    // MARK: - Real dive under a moving set

    private var funScene: some View {
        let start = 8.33
        let passage = hoopPassageTime(start: start)
        let hoopX = movingSetX(start: start, end: 13.65)
        let descent = smooth(progress(passage - 1.55, passage - 0.55))
        let ascent = smooth(progress(passage + 0.40, passage + 1.32))
        let submergedY = lerp(lanes[1], diveY, descent)
        let characterY = ascent > 0 ? lerp(diveY, lanes[1], ascent) : submergedY
        let pose: PenguinPose
        let motion: PenguinFlightMotion
        if ascent >= 0.98 {
            pose = .flying
            motion = .level
        } else if ascent > 0 {
            pose = ascent < 0.82 ? .resurfacing : .recovering
            motion = .rising
        } else if descent > 0.74 {
            pose = .underwater
            motion = .falling
        } else if descent > 0 {
            pose = .diving
            motion = .falling
        } else {
            pose = .flying
            motion = .level
        }

        return ZStack {
            questionBadge("6 + 9", character: penguin)
                .position(x: hoopX, y: questionY)
            hoopColumn(texts: ["5", "10", "20"],
                       character: penguin,
                       centreX: hoopX,
                       feedbackIndex: nil)

            riggedCharacter(penguin,
                            size: playerSize,
                            pose: pose,
                            motion: motion)
                .position(x: playerX, y: characterY)
                .shadow(color: .black.opacity(0.18), radius: 6, y: 4)

            // It is usually empty during the dive because the character is
            // below the stack, but retaining the production near-rim test
            // keeps the shot truthful if timings are adjusted later.
            hoopForegroundColumn(character: penguin,
                                 centreX: hoopX,
                                 playerX: playerX,
                                 feedbackIndex: nil)
        }
    }

    // MARK: - Learn math through the top hoop

    private var learnScene: some View {
        let start = 13.42
        let passage = hoopPassageTime(start: start)
        let hoopX = movingSetX(start: start, end: 18.18)
        let laneMove = smooth(progress(13.72, 14.52))
        let characterY = lerp(lanes[1], lanes[0], laneMove)
        let success = time >= passage
        let pose: PenguinPose = abs(hoopX - playerX) < hoopSize * 0.62 ? .threading : .flying
        let finale = progress(passage + 0.50, passage + 3.40)

        return ZStack {
            questionBadge("1/4 = ?%", character: penguin)
                .position(x: hoopX, y: questionY)
            hoopColumn(texts: ["25", "50", "75"],
                       character: penguin,
                       centreX: hoopX,
                       feedbackIndex: success ? 0 : nil)

            riggedCharacter(penguin,
                            size: playerSize,
                            pose: pose,
                            motion: laneMove > 0 && laneMove < 1 ? .rising : .level)
                .modifier(CompletionFlightEffect(progress: CGFloat(finale),
                                                 sceneSize: outputSize,
                                                 start: CGPoint(x: playerX, y: characterY),
                                                 penguinSize: playerSize,
                                                 reduceMotion: false))
                .position(x: playerX, y: characterY)
                .shadow(color: .black.opacity(0.18), radius: 6, y: 4)

            hoopForegroundColumn(character: penguin,
                                 centreX: hoopX,
                                 playerX: playerX,
                                 feedbackIndex: success ? 0 : nil)

            successSparkles(centre: CGPoint(x: hoopX, y: lanes[0]),
                             amount: progress(passage, passage + 0.50),
                             tint: .green)
                .opacity(success ? 1 : 0)
        }
    }

    // MARK: - Overlays that remain part of the moving world

    @ViewBuilder
    private var diveSplashes: some View {
        let passage = hoopPassageTime(start: 8.33)
        let entering = smooth(progress(passage - 0.95, passage - 0.33))
        if entering > 0 && entering < 1 {
            WaterSplash(direction: .entering,
                        strength: 0.96,
                        reduceMotion: false,
                        deterministicProgress: CGFloat(entering))
                .frame(width: playerSize * (1.15 + 0.96 * 0.80),
                       height: playerSize * (0.78 + 0.96 * 0.62))
                .position(x: playerX, y: waterline)
        }

        let exiting = smooth(progress(passage + 0.66, passage + 1.26))
        if exiting > 0 && exiting < 1 {
            WaterSplash(direction: .exiting,
                        strength: 0.78,
                        reduceMotion: false,
                        deterministicProgress: CGFloat(exiting))
                .frame(width: playerSize * (1.15 + 0.78 * 0.80),
                       height: playerSize * (0.78 + 0.78 * 0.62))
                .position(x: playerX, y: waterline)
        }
    }

    @ViewBuilder
    private var promoOverlay: some View {
        if time < 4.01 {
            let hoopX = movingSetX(start: 0.22, end: 4.15)
            promoText("Choose the right hoop",
                      opacity: sceneOpacity(start: 0, end: 4.01, fadeIn: 0.14, fadeOut: 0.18)
                        * promoQuestionClearance(hoopX))
        } else if time < 8.37 {
            promoText("Unlock new characters", opacity: sceneOpacity(start: 4.01, end: 8.37, fadeIn: 0.18, fadeOut: 0.18))
        } else if time < 13.34 {
            let hoopX = movingSetX(start: 8.33, end: 13.65)
            promoText("Have fun",
                      opacity: sceneOpacity(start: 8.37, end: 13.34, fadeIn: 0.18, fadeOut: 0.18)
                        * promoQuestionClearance(hoopX))
        } else if time < 17.64 {
            let hoopX = movingSetX(start: 13.42, end: 18.18)
            promoText("Learn math",
                      opacity: sceneOpacity(start: 13.34, end: 17.64, fadeIn: 0.18, fadeOut: 0.18)
                        * promoQuestionClearance(hoopX))
        }
    }

    private func promoQuestionClearance(_ hoopX: CGFloat) -> Double {
        let distance = abs(hoopX - outputSize.width * 0.50)
        let hiddenRadius = outputSize.width * 0.12
        let fadeSpan = outputSize.width * 0.07
        return smooth(clamp(Double((distance - hiddenRadius) / fadeSpan)))
    }

    private var appIconFinale: some View {
        let arrival = smooth(progress(20.30, 21.02))
        let iconSize = min(outputSize.height * 0.72, outputSize.width * 0.52)
        return ZStack {
            Color(red: 0.02, green: 0.16, blue: 0.38)
                .opacity(arrival * 0.48)

            Circle()
                .fill(.white.opacity(0.38))
                .frame(width: iconSize * 1.38, height: iconSize * 1.38)
                .blur(radius: iconSize * 0.12)
                .scaleEffect(0.68 + CGFloat(arrival) * 0.32)

            Image("penguin-iOS-Default-1024x1024")
                .resizable()
                .scaledToFit()
                .frame(width: iconSize, height: iconSize)
                .shadow(color: .black.opacity(0.30), radius: iconSize * 0.07, y: iconSize * 0.04)
                .scaleEffect(0.45 + CGFloat(arrival) * 0.55)
                .rotationEffect(.degrees((1 - arrival) * -7))
        }
        .frame(width: outputSize.width, height: outputSize.height)
        .opacity(arrival)
    }

    @ViewBuilder
    private var transitionEffects: some View {
        let wipe = smooth(progress(3.85, 4.15))
        if wipe > 0 && wipe < 1 {
            Circle()
                .stroke(penguin.color,
                        lineWidth: hoopSize * (0.13 + CGFloat(wipe) * 0.52))
                .frame(width: hoopSize + CGFloat(wipe) * outputSize.width * 1.65,
                       height: hoopSize + CGFloat(wipe) * outputSize.width * 1.65)
                .position(x: playerX, y: lanes[1])
                .opacity(1 - abs(wipe - 0.5) * 1.34)
        }
    }

    // MARK: - Shared production visuals

    private func promoText(_ text: String, opacity: Double) -> some View {
        Text(text)
            .font(.system(size: outputSize.height * 0.035,
                          weight: .black,
                          design: .rounded))
            .foregroundStyle(Color(red: 0.04, green: 0.16, blue: 0.38))
            .lineLimit(1)
            .minimumScaleFactor(0.74)
            .padding(.horizontal, outputSize.height * 0.020)
            .padding(.vertical, outputSize.height * 0.009)
            .background(.white.opacity(0.93), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.86), lineWidth: 2))
            .shadow(color: .black.opacity(0.13), radius: 6, y: 3)
            .position(x: outputSize.width * 0.50,
                      y: max(outputSize.height * 0.045, outputSize.height * 0.035 + 8))
            .opacity(opacity)
    }

    private func questionBadge(_ text: String, character: AnimalCharacter) -> some View {
        let fontSize = outputSize.height * (isPadCanvas ? 0.048 : 0.060)
        return Text(text)
            .font(.system(size: fontSize, weight: .black, design: .rounded))
            .foregroundStyle(character.deepColor)
            .lineLimit(1)
            .minimumScaleFactor(0.78)
            .padding(.horizontal, fontSize * 0.72)
            .padding(.vertical, fontSize * 0.30)
            .background(.white.opacity(0.95), in: Capsule())
            .overlay(Capsule().stroke(character.color.opacity(0.42), lineWidth: max(2, fontSize * 0.055)))
            .shadow(color: .black.opacity(0.12), radius: fontSize * 0.12, y: fontSize * 0.06)
    }

    private var answerButtonX: CGFloat { outputSize.width - hoopSize * 0.47 }

    private func hoopColumn(texts: [String],
                            character: AnimalCharacter,
                            centreX _: CGFloat,
                            feedbackIndex: Int?) -> some View {
        // Answers always occupy the flush trailing-edge column. The moving
        // centre is kept at call sites for the question badge / sparkles.
        ZStack {
            ForEach(Array(texts.enumerated()), id: \.offset) { index, text in
                let feedback: HoopFeedback = feedbackIndex == index
                    ? .correct
                    : (feedbackIndex == nil ? .none : .inactive)
                AnswerHoop(text: text,
                           tint: character.color,
                           size: hoopSize,
                           textScale: 1,
                           feedback: feedback,
                           isPressed: feedbackIndex == index)
                    .position(x: answerButtonX, y: lanes[index])
            }
        }
    }

    @ViewBuilder
    private func hoopForegroundColumn(character _: AnimalCharacter,
                                      centreX _: CGFloat,
                                      playerX _: CGFloat,
                                      feedbackIndex _: Int?) -> some View {
        // Solid arcade buttons have no near-side rim to composite over the
        // character; the edge column already reads above the water.
        EmptyView()
    }

    private func riggedCharacter(_ animal: AnimalCharacter,
                                 size: CGFloat,
                                 pose: PenguinPose,
                                 motion: PenguinFlightMotion) -> some View {
        RiggedPenguin(size: size,
                      rig: animal.rig,
                      pose: pose,
                      flightMotion: motion,
                      reduceMotion: false,
                      flightClock: time)
    }

    private func unlockRays(color: Color, rotation: Double) -> some View {
        ZStack {
            ForEach(0..<12, id: \.self) { index in
                Capsule()
                    .fill(index.isMultiple(of: 2) ? color.opacity(0.50) : .white.opacity(0.72))
                    .frame(width: playerSize * 0.035,
                           height: playerSize * (index.isMultiple(of: 2) ? 0.72 : 0.54))
                    .offset(y: -playerSize * 1.12)
                    .rotationEffect(.degrees(Double(index) * 30 + rotation))
            }
        }
        .frame(width: playerSize * 3, height: playerSize * 3)
    }

    private func successSparkles(centre: CGPoint, amount: Double, tint: Color) -> some View {
        ZStack {
            ForEach(0..<10, id: \.self) { index in
                let angle = Double(index) * .pi * 2 / 10
                let radius = hoopSize * (0.52 + CGFloat(amount) * 0.62)
                Image(systemName: index.isMultiple(of: 2) ? "star.fill" : "sparkle")
                    .font(.system(size: hoopSize * (index.isMultiple(of: 2) ? 0.13 : 0.10),
                                  weight: .bold))
                    .foregroundStyle(index.isMultiple(of: 3) ? .white : tint)
                    .position(x: centre.x + CGFloat(cos(angle)) * radius,
                              y: centre.y + CGFloat(sin(angle)) * radius)
                    .scaleEffect(0.55 + CGFloat(sin(amount * .pi)) * 0.55)
                    .opacity(1 - clamp((amount - 0.60) / 0.40))
            }
        }
    }
}

#if os(iOS) && TRAILER_EXPORT
import AVFoundation
import UIKit

/// The app shows only this inert host when the explicit export flag is present.
/// Rendering, encoding, audio assembly and representative-frame capture all
/// happen offscreen, so there is no status bar, cursor, simulator chrome or
/// real-time frame pacing in the deliverable.
struct TrailerExportHost: View {
    @State private var status = "Preparing deterministic trailer…"

    var body: some View {
        ZStack {
            Color(red: 0.04, green: 0.16, blue: 0.38).ignoresSafeArea()
            VStack(spacing: 18) {
                ProgressView().tint(.white).scaleEffect(1.4)
                Text(status)
                    .font(.system(.headline, design: .rounded, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .task {
            do {
                let exporter = TrailerExporter { status = $0 }
                try await exporter.exportAll()
                status = "Export complete"
            } catch {
                status = "Export failed: \(error.localizedDescription)"
                try? TrailerExporter.writeFailure(error)
            }
        }
    }
}

@MainActor
private final class TrailerExporter {
    struct OutputSpec {
        let width: Int
        let height: Int
        var name: String { "app-store-teaser-\(width)x\(height)" }
        var size: CGSize { CGSize(width: width, height: height) }
    }

    struct SoundCue {
        let resource: String
        let ext: String
        let time: Double
        let volume: Float
    }

    static let framesPerSecond: Int32 = 30
    static let videoOutputs = [OutputSpec(width: 1920, height: 886),
                               OutputSpec(width: 1600, height: 1200)]
    static let stillOutputs = [OutputSpec(width: 2048, height: 944),
                               OutputSpec(width: 2048, height: 1535)]
    static let previewFrames: [Int: String] = {
        var frames: [Int: String] = [:]
        for second in 0..<Int(TrailerCompositionView.duration) {
            frames[second * Int(framesPerSecond)] = String(format: "%02ds", second)
        }
        // Checkpoints immediately around every visual handoff, not just on
        // whole seconds. They are retained for the repeatable QA pass.
        let transitions: [(Double, String)] = [
            (0.00, "00_00s"), (0.20, "00_20s"), (0.32, "00_32s"), (0.48, "00_48s"),
            (3.34, "03_34s"), (3.46, "03_46s"),
            (4.47, "04_47s"), (5.69, "05_69s"),
            (6.91, "06_91s"), (8.05, "08_05s"),
            (10.52, "10_52s"), (11.50, "11_50s"),
            (12.12, "12_12s"), (12.82, "12_82s"),
            (13.36, "13_36s"), (13.52, "13_52s"),
            (16.54, "16_54s"), (16.66, "16_66s"),
            (17.58, "17_58s"), (18.90, "18_90s"),
            (20.24, "20_24s"), (21.02, "21_02s")
        ]
        for (time, label) in transitions {
            frames[Int((time * Double(framesPerSecond)).rounded())] = label
        }
        return frames
    }()

    let updateStatus: (String) -> Void

    init(updateStatus: @escaping (String) -> Void) {
        self.updateStatus = updateStatus
    }

    func exportAll() async throws {
        if TrailerRuntime.isStillExporting {
            try exportStills()
            return
        }

        let root = try Self.exportRoot()
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let previews = root.appendingPathComponent("previews", isDirectory: true)
        try FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)

        for spec in Self.videoOutputs {
            updateStatus("Rendering \(spec.width) × \(spec.height)…")
            let silentURL = root.appendingPathComponent("\(spec.name)-silent.mp4")
            let finalURL = root.appendingPathComponent("\(spec.name).mp4")
            try await renderVideo(spec: spec, outputURL: silentURL, previewsURL: previews)
            updateStatus("Mixing real game audio for \(spec.width) × \(spec.height)…")
            try await mixAudio(videoURL: silentURL, outputURL: finalURL)
            try? FileManager.default.removeItem(at: silentURL)
        }

        let completion: [String: Any] = [
            "duration": TrailerCompositionView.duration,
            "fps": Int(Self.framesPerSecond),
            "outputs": Self.videoOutputs.map(\.name),
            "layout": "nativeLandscapeGameplay",
            "completedAt": ISO8601DateFormatter().string(from: Date())
        ]
        let data = try JSONSerialization.data(withJSONObject: completion, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: root.appendingPathComponent("export-complete.json"), options: .atomic)
    }

    private func exportStills() throws {
        let root = try Self.exportRoot()
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        var filenames: [String] = []
        for spec in Self.stillOutputs {
            for kind in PromoStillKind.allCases {
                updateStatus("Rendering \(kind.headline) — \(spec.width) × \(spec.height)…")
                let filename = "\(kind.filenameStem)-\(spec.width)x\(spec.height).png"
                let image = try renderedStill(kind: kind, spec: spec)
                guard let data = image.pngData() else { throw ExportError.pngData(filename) }
                try data.write(to: root.appendingPathComponent(filename), options: .atomic)
                filenames.append(filename)
            }
        }

        let completion: [String: Any] = [
            "outputs": filenames,
            "layout": "nativeLandscapeStills",
            "completedAt": ISO8601DateFormatter().string(from: Date())
        ]
        let data = try JSONSerialization.data(withJSONObject: completion, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: root.appendingPathComponent("export-complete.json"), options: .atomic)
    }

    private func renderedStill(kind: PromoStillKind, spec: OutputSpec) throws -> UIImage {
        let content = PromoStillCompositionView(kind: kind, outputSize: spec.size)
            .frame(width: spec.size.width, height: spec.size.height)
            .transaction { transaction in transaction.disablesAnimations = true }
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        renderer.isOpaque = true
        renderer.proposedSize = ProposedViewSize(spec.size)
        guard let image = renderer.uiImage else { throw ExportError.renderStill(kind.rawValue) }
        return image
    }

    private func renderVideo(spec: OutputSpec, outputURL: URL, previewsURL: URL) async throws {
        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let bitRate = spec.height <= 944 ? 18_000_000 : 24_000_000
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: spec.width,
            AVVideoHeightKey: spec.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate,
                AVVideoExpectedSourceFrameRateKey: Int(Self.framesPerSecond),
                AVVideoMaxKeyFrameIntervalKey: Int(Self.framesPerSecond)
            ]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: spec.width,
            kCVPixelBufferHeightKey as String: spec.height,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
                                                            sourcePixelBufferAttributes: attributes)
        guard writer.canAdd(input) else { throw ExportError.writerInput }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? ExportError.writerStart }
        writer.startSession(atSourceTime: .zero)

        let frameCount = Int(TrailerCompositionView.duration * Double(Self.framesPerSecond))
        for frame in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(2))
            }
            let frameTime = Double(frame) / Double(Self.framesPerSecond)
            let image = try renderedImage(time: frameTime, spec: spec)
            let pixelBuffer = try makePixelBuffer(image: image,
                                                  pool: adaptor.pixelBufferPool,
                                                  width: spec.width,
                                                  height: spec.height)
            let presentationTime = CMTime(value: CMTimeValue(frame), timescale: Self.framesPerSecond)
            guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
                throw writer.error ?? ExportError.appendFrame(frame)
            }

            if let label = Self.previewFrames[frame] {
                let name = "\(spec.name)-\(label).png"
                if let data = image.pngData() {
                    try data.write(to: previewsURL.appendingPathComponent(name), options: .atomic)
                }
            }

            if frame.isMultiple(of: Int(Self.framesPerSecond) * 2) {
                updateStatus("Rendering \(spec.width) × \(spec.height): \(Int(frameTime)) / \(Int(TrailerCompositionView.duration)) s")
                await Task.yield()
            }
        }

        input.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else { throw writer.error ?? ExportError.writerFinish }
    }

    private func renderedImage(time: Double, spec: OutputSpec) throws -> UIImage {
        let content = TrailerCompositionView(time: time, outputSize: spec.size)
            .frame(width: spec.size.width, height: spec.size.height)
            .transaction { transaction in
                // The trailer's motion is entirely driven by `time`.
                // Suppressing implicit state interpolation keeps arbitrary
                // offscreen frames crisp instead of creating ghosted limbs.
                transaction.disablesAnimations = true
            }
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        renderer.isOpaque = true
        renderer.proposedSize = ProposedViewSize(spec.size)
        guard let image = renderer.uiImage else { throw ExportError.renderFrame(time) }
        return image
    }

    private func makePixelBuffer(image: UIImage,
                                 pool: CVPixelBufferPool?,
                                 width: Int,
                                 height: Int) throws -> CVPixelBuffer {
        guard let cgImage = image.cgImage else { throw ExportError.missingCGImage }
        var optionalBuffer: CVPixelBuffer?
        let result: CVReturn
        if let pool {
            result = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &optionalBuffer)
        } else {
            result = CVPixelBufferCreate(nil, width, height,
                                         kCVPixelFormatType_32BGRA,
                                         [kCVPixelBufferCGImageCompatibilityKey: true,
                                          kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary,
                                         &optionalBuffer)
        }
        guard result == kCVReturnSuccess, let buffer = optionalBuffer else {
            throw ExportError.pixelBuffer(result)
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer),
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                                        | CGImageAlphaInfo.premultipliedFirst.rawValue) else {
            throw ExportError.bitmapContext
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    private func mixAudio(videoURL: URL, outputURL: URL) async throws {
        try? FileManager.default.removeItem(at: outputURL)
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: videoURL)
        guard let sourceVideo = try await videoAsset.loadTracks(withMediaType: .video).first,
              let destinationVideo = composition.addMutableTrack(withMediaType: .video,
                                                                 preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ExportError.videoTrack
        }
        let duration = CMTime(seconds: TrailerCompositionView.duration, preferredTimescale: 600)
        try destinationVideo.insertTimeRange(CMTimeRange(start: .zero, duration: duration),
                                             of: sourceVideo,
                                             at: .zero)

        var parameters: [AVMutableAudioMixInputParameters] = []
        if let musicURL = Bundle.main.url(forResource: "background_music", withExtension: "mp3") {
            let musicAsset = AVURLAsset(url: musicURL)
            if let musicSource = try await musicAsset.loadTracks(withMediaType: .audio).first,
               let musicTrack = composition.addMutableTrack(withMediaType: .audio,
                                                            preferredTrackID: kCMPersistentTrackID_Invalid) {
                let sourceDuration = try await musicAsset.load(.duration)
                var cursor = CMTime.zero
                while cursor < duration, sourceDuration.seconds > 0 {
                    let remaining = duration - cursor
                    let segment = min(sourceDuration, remaining)
                    try musicTrack.insertTimeRange(CMTimeRange(start: .zero, duration: segment),
                                                   of: musicSource,
                                                   at: cursor)
                    cursor = cursor + segment
                }
                let p = AVMutableAudioMixInputParameters(track: musicTrack)
                p.setVolume(0.16, at: .zero)
                p.setVolumeRamp(fromStartVolume: 0.16, toEndVolume: 0, timeRange: CMTimeRange(start: CMTime(seconds: 21.15, preferredTimescale: 600), duration: CMTime(seconds: 0.85, preferredTimescale: 600)))
                parameters.append(p)
            }
        }

        let cues: [SoundCue] = [
            .init(resource: "sfx_cannon_shoot", ext: "m4a", time: 0.185, volume: 0.95),
            .init(resource: "sfx_good", ext: "m4a", time: 3.39, volume: 0.88),
            .init(resource: "sfx_character_unlock", ext: "caf", time: 4.15, volume: 0.82),
            .init(resource: "sfx_character_unlock", ext: "caf", time: 5.37, volume: 0.82),
            .init(resource: "sfx_character_unlock", ext: "caf", time: 6.59, volume: 0.82),
            .init(resource: "sfx_character_unlock", ext: "caf", time: 7.83, volume: 0.88),
            .init(resource: "splash", ext: "caf", time: 10.55, volume: 0.82),
            .init(resource: "sfx_turbo", ext: "m4a", time: 12.08, volume: 0.62),
            .init(resource: "splash", ext: "caf", time: 12.16, volume: 0.58),
            .init(resource: "sfx_good", ext: "m4a", time: 16.59, volume: 0.92),
            .init(resource: "sfx_level_complete", ext: "caf", time: 17.09, volume: 0.76),
            .init(resource: "sfx_end_screen_celebration", ext: "m4a", time: 20.30, volume: 0.62)
        ]
        for cue in cues {
            guard let url = Bundle.main.url(forResource: cue.resource, withExtension: cue.ext) else { continue }
            let asset = AVURLAsset(url: url)
            guard let source = try await asset.loadTracks(withMediaType: .audio).first,
                  let track = composition.addMutableTrack(withMediaType: .audio,
                                                          preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            let cueDuration = try await asset.load(.duration)
            let start = CMTime(seconds: cue.time, preferredTimescale: 600)
            let available = duration - start
            guard available > .zero else { continue }
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: min(cueDuration, available)),
                                      of: source,
                                      at: start)
            let p = AVMutableAudioMixInputParameters(track: track)
            p.setVolume(cue.volume, at: start)
            parameters.append(p)
        }

        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = parameters
        guard let session = AVAssetExportSession(asset: composition,
                                                 presetName: AVAssetExportPresetHighestQuality) else {
            throw ExportError.exportSession
        }
        session.outputURL = outputURL
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        session.audioMix = audioMix
        await withCheckedContinuation { continuation in
            session.exportAsynchronously { continuation.resume() }
        }
        guard session.status == .completed else { throw session.error ?? ExportError.audioMix }
    }

    static func exportRoot() throws -> URL {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw ExportError.documentsDirectory
        }
        let folder = TrailerRuntime.isStillExporting ? "AppStoreStills" : "AppStoreTeaser"
        return documents.appendingPathComponent(folder, isDirectory: true)
    }

    static func writeFailure(_ error: Error) throws {
        let root = try exportRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(error.localizedDescription.utf8)
            .write(to: root.appendingPathComponent("export-failed.txt"), options: .atomic)
    }

    private enum ExportError: LocalizedError {
        case writerInput, writerStart, writerFinish, appendFrame(Int), renderFrame(Double)
        case renderStill(String), pngData(String)
        case missingCGImage, pixelBuffer(CVReturn), bitmapContext, videoTrack
        case exportSession, audioMix, documentsDirectory

        var errorDescription: String? {
            switch self {
            case .writerInput: return "The H.264 writer rejected its input."
            case .writerStart: return "The H.264 writer could not start."
            case .writerFinish: return "The H.264 writer could not finish."
            case .appendFrame(let frame): return "Could not append video frame \(frame)."
            case .renderFrame(let time): return "Could not render the frame at \(time) seconds."
            case .renderStill(let kind): return "Could not render the \(kind) App Store still."
            case .pngData(let filename): return "Could not encode \(filename) as PNG."
            case .missingCGImage: return "A rendered frame had no CGImage."
            case .pixelBuffer(let status): return "Could not allocate a pixel buffer (\(status))."
            case .bitmapContext: return "Could not create the pixel-buffer drawing context."
            case .videoTrack: return "The silent master did not contain a readable video track."
            case .exportSession: return "Could not create the final media export session."
            case .audioMix: return "Could not mux the game audio into the video."
            case .documentsDirectory: return "The export Documents directory was unavailable."
            }
        }
    }
}
#else
struct TrailerExportHost: View {
    var body: some View { Text("Trailer export is available on iOS.") }
}
#endif
