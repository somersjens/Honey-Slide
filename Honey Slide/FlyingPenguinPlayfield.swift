import SwiftUI
import Combine
#if canImport(UIKit)
import UIKit
#endif

/// A stable, lifecycle-controlled source for simulation frames. Keeping the
/// publisher itself stable lets SwiftUI always invoke the current `tick`
/// closure, while stopping its upstream timer prevents 60 main-thread wakeups
/// per second behind pause/result cards or while the app is backgrounded.
private final class PlayfieldFrameClock {
    let ticks = PassthroughSubject<Date, Never>()
    private var subscription: AnyCancellable?

    func start() {
        guard subscription == nil else { return }
        let process = ProcessInfo.processInfo
        let usesReducedCadence = process.isLowPowerModeEnabled
            || process.thermalState == .serious
            || process.thermalState == .critical
        let interval = usesReducedCadence ? 1.0 / 30.0 : 1.0 / 60.0
        subscription = Timer.publish(every: interval,
                                     tolerance: interval * 0.08,
                                     on: .main,
                                     in: .common)
            .autoconnect()
            .sink { [weak self] in self?.ticks.send($0) }
    }

    func stop() {
        subscription?.cancel()
        subscription = nil
    }

    deinit { stop() }
}

/// The Flying Penguin interaction. Session rules remain in `MemoryGame`; this
/// view only turns a vertical flight path (or a dive) into one option id.
struct FlyingPenguinPlayfield: View {
    let rounds: [GameRound]
    let maximumRounds: Int
    let character: AnimalCharacter
    let isPad: Bool
    let isLive: Bool
    let isRunning: Bool
    let playsFishEntrance: Bool
    let preparesLevelCompletion: Bool
    let playsLevelCompletion: Bool
    let reduceMotion: Bool
    let topReserve: CGFloat
    let bottomReserve: CGFloat
    /// What the guided run is teaching right now, and which rules it bends.
    /// A default plan is an ordinary session and costs the field nothing.
    var tutorial: TutorialPlan = TutorialPlan()
    var tutorialMessage: String? = nil
    /// How a lesson is answered: the field is the only place that knows how a
    /// passage, a drag or a tap actually ended.
    var onTutorialEvent: (TutorialEvent) -> Void = { _ in }
    /// True while the session's one rescue heart is owed to the next set.
    var isRescueHeartDue: Bool = false
    /// Raised the moment that heart is actually put in the world.
    var onRescueHeartPlaced: () -> Void = {}
    /// The session's rescue heart was flown into, at this point on screen.
    var onLifeHeartCollected: (CGPoint) -> Void = { _ in }
    /// How big a heart is drawn — the lives meter's own size, so the one that
    /// flies up to it neither grows nor shrinks on the way.
    var lifeHeartSize: CGFloat = 22
    let onHit: (UUID, Bool, Bool) -> Bool
    let onSwallow: (Bool) -> Void
    let onDive: () -> Void
    let onFishEntranceComplete: () -> Void
    let onLevelCompletionFinished: () -> Void

    @State private var frameClock = PlayfieldFrameClock()

    @State private var sceneSize: CGSize = .zero
    @State private var penguinY: CGFloat = 0
    @State private var targetPenguinY: CGFloat = 0
    @State private var dragStartY: CGFloat?
    @State private var pressHoldSequence = 0
    @State private var directPressActive = false
    @State private var suppressTapAfterPressHold = false
    /// Which answer button is visually depressed, matching the Nuts & Numbers
    /// grab-cap travel. Cleared automatically after the press settles.
    @State private var pressedOptionID: UUID?
    @State private var penguinX: CGFloat = 0
    @State private var hoopX: CGFloat = 0
    @State private var shownOptions: [AnswerOption] = []
    @State private var shownPrompt = ""
    @State private var previewOptions: [AnswerOption] = []
    @State private var previewPrompt = ""
    @State private var previewRoundID: UUID?
    @State private var previewHasNoCorrectAnswer = false
    @State private var retiringSets: [RetiringHoopSet] = []
    @State private var activeRoundID: UUID?
    @State private var noCorrectAnswer = false
    @State private var resolved = false
    /// A wrong passage reveals the solution in the moving sum and briefly
    /// repeats it at the lower-left edge while flight continues uninterrupted.
    @State private var answerEcho: SolvedAnswerEcho?
    @State private var emphasizesCorrectAnswer = false
    @State private var diveArmed = false
    @State private var divePhase = 0
    @State private var committedLaneIndex: Int?
    @State private var speedRunActive = false
    @State private var speedBonusEligible = false
    @State private var bonusOptionID: UUID?
    /// Feedback follows the player's actual choice. Unchosen distractors stay
    /// neutral instead of turning red after a successful passage.
    @State private var selectedOptionID: UUID?
    @State private var bypassedWrongSet = false
    @State private var worldOffset: CGFloat = 0
    @State private var entranceStage = 0
    @State private var completionActive = false
    @State private var completionProgress: CGFloat = 0
    @State private var completionStart = CGPoint.zero
    /// A small continuation of the last passage during its feedback beat. It
    /// hands the penguin to the loop with forward momentum instead of a pause.
    @State private var completionLeadX: CGFloat = 0
    /// Invalidates a delayed finale callback when a fresh run starts.
    @State private var completionSequence = 0
    @State private var lastTick: Date?
    @State private var launchGlideSpeed: CGFloat = 0
    @State private var launchSpeedHandoffActive = false
    @State private var startMarkerActive = false
    /// The world position the cannon was fired from. Everything standing on the
    /// water during the entrance — platform and start marker — is placed
    /// relative to it, so the launch scenery travels on the same conveyor as
    /// the rings instead of on a camera animation of its own.
    @State private var launchWorldOrigin: CGFloat = 0
    @State private var launchPlatformActive = false
    /// Splashes are fired as events rather than toggled as flags. A boolean
    /// that has to be cleared before it can be set again is exactly what made
    /// a dive occasionally arrive without one; an appended event cannot be
    /// swallowed by whatever the dive state does next.
    @State private var splashes: [SplashEvent] = []
    /// Latches at the surface so one crossing produces one splash, whether the
    /// penguin swam down to it or was placed under it by a resolved round.
    @State private var surfaceSubmerged = false
    @State private var previousPenguinY: CGFloat = 0
    /// The height the current dive started from, which is what the entry
    /// splash is sized by.
    @State private var diveStartY: CGFloat = 0
    @State private var flightClock: Double = 0
    /// The session's single rescue heart. It travels on the same conveyor as
    /// everything else, so it stays exactly where it was placed.
    @State private var lifeHearts: [LifeHeartPickup] = []
    /// Guards the rescue heart against being placed twice in one frame, before
    /// the engine's answer to the first placement has come back.
    @State private var hasPlacedRescueHeart = false
    /// True while the turbo lesson is waiting for the player: the world stands
    /// still with the set and its tap hint in plain view.
    @State private var tutorialHold = false
    /// Set for the length of one set once its right hoop has been tapped. The
    /// lesson only ever waits for a tap that has not happened yet: without this
    /// a set tapped a moment before it reaches the holding point would stop
    /// dead with nothing left to ask for.
    @State private var tutorialTurboTapped = false
    /// Identifies the one set used for the automatic dive demonstration. The
    /// director keeps its flag raised until that passage reports success, so a
    /// round id is the guard that prevents re-arming it every frame.
    @State private var tutorialAutoDiveRoundID: UUID?
    /// Locks out competing touches from the start of the demonstration until
    /// the penguin has climbed back into its normal flight band.
    @State private var tutorialAutoDiveActive = false

    // iPad's squarer playfield already gives the character more visual weight.
    // Retain a small tablet lift without letting it crowd the sum and water.
    private var penguinSize: CGFloat { sceneSize.height * (isPad ? 0.245 : 0.235) }
    /// The rings leave a dedicated header band for the moving sum.
    /// Three touching arcade buttons fill the complete answer column, flush
    /// against the trailing screen edge. Their shared size is derived from the
    /// available height, so there is no gap between neighbours or the rim.
    private var hoopSize: CGFloat {
        let questionBottom = sceneSize.height * 0.141
        let answerBottom = waterline - sceneSize.height * 0.012
        return max(1, (answerBottom - questionBottom) / 3)
    }
    /// Centre X that parks every answer button flush against the trailing
    /// edge. A small inset past half-width compensates for the transparent
    /// margin in the authored canvases without clipping the visible rim away.
    private var answerButtonX: CGFloat {
        sceneSize.width - hoopSize * 0.47
    }
    private var waterline: CGFloat { sceneSize.height * 0.90 }
    private var normalPenguinX: CGFloat { sceneSize.width * 0.25 }
    private var flightMinY: CGFloat {
        // Leave a little headroom above the top answer centre without letting
        // the character collide with the moving question badge.
        max(questionY + penguinSize * 0.46,
            (lanes.first ?? sceneSize.height * 0.27) - hoopSize * 0.22)
    }
    private var flightMaxY: CGFloat { lanes.last ?? sceneSize.height * 0.76 }
    private var diveY: CGFloat { waterline + penguinSize * 0.68 }

    private var lanes: [CGFloat] {
        let first = sceneSize.height * 0.141 + hoopSize * 0.5
        return [first, first + hoopSize, first + hoopSize * 2]
    }

    private var questionY: CGFloat { sceneSize.height * 0.090 }
    private var ringSpawnX: CGFloat {
        // The timing gate still approaches from just beyond the answer column
        // so turbo windows and passage resolution keep their familiar runway,
        // while the buttons themselves stay parked on the trailing edge.
        sceneSize.width + hoopSize * 0.55
    }
    private var ringSetSpacing: CGFloat {
        sceneSize.width - normalPenguinX + hoopSize * 0.20
    }
    private var previewX: CGFloat {
        hoopX + ringSetSpacing
    }
    private var cruiseSpeed: CGFloat {
        // A squarer iPad viewport has a little less horizontal reading runway.
        // Give it roughly nine percent more time per set. Every moving world
        // layer reads this speed, so scenery, markers and hoops stay locked.
        let passageDuration: CGFloat = isPad ? 5.45 : 5
        return max(80, (sceneSize.width + hoopSize - normalPenguinX) / passageDuration)
    }
    /// The lane assist is time based as well as size based. Turbo attempts
    /// therefore get more physical runway instead of cutting the correction
    /// window in half when the conveyor doubles its speed.
    private var approachSpeed: CGFloat {
        cruiseSpeed * (speedRunActive && !resolved ? 2 : 1)
    }
    private var laneAssistDistance: CGFloat {
        max(hoopSize * 0.42, approachSpeed * 0.36)
    }
    private var laneCommitDistance: CGFloat {
        max(hoopSize * 0.14, approachSpeed * 0.13)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                polarBackdrop

                movingWorld

                // The deadline buoy belongs to a set. Before the start marker
                // hands the first one over there is nothing to be early for.
                if entranceStage >= 3 && !completionActive && !shownOptions.isEmpty {
                    TurboTimingBuoy(isAvailable: timingMarkerX(for: hoopX) > penguinX)
                        .frame(width: penguinSize * 0.25, height: penguinSize * 0.31)
                        .position(x: timingMarkerX(for: hoopX),
                                  y: waterline - penguinSize * 0.05)
                    if !previewOptions.isEmpty {
                        TurboTimingBuoy(isAvailable: true)
                            .frame(width: penguinSize * 0.25, height: penguinSize * 0.31)
                            .position(x: timingMarkerX(for: previewX),
                                      y: waterline - penguinSize * 0.05)
                    }
                }

                if launchPlatformActive {
                    cannonLaunch
                }

                if startMarkerActive {
                    FloatingStartMarker(size: penguinSize * 0.58,
                                        reduceMotion: reduceMotion)
                        .position(x: startMarkerX,
                                  y: waterline - penguinSize * 0.12)
                        .allowsHitTesting(false)
                }

                ForEach(retiringSets) { set in
                    MovingQuestionBadge(prompt: set.prompt,
                                        character: character,
                                        isPad: isPad)
                        .position(x: set.x, y: questionY)
                    // Spent answer buttons drift inward from the edge column so
                    // the next set can occupy the flush rim without overlap.
                    ForEach(Array(set.options.enumerated()), id: \.element.id) { index, option in
                        AnswerHoop(text: option.text,
                                   tint: character.color,
                                   size: hoopSize,
                                   textScale: answerTextScale(for: set.options),
                                   feedback: set.feedback(for: option.id),
                                   isPressed: false)
                            .position(x: set.x, y: lanes[index])
                            .opacity(0.72)
                    }
                }

                if !previewOptions.isEmpty && entranceStage >= 3 && !completionActive {
                    // Only the upcoming sum peeks in from the conveyor. The
                    // answer buttons themselves always live on the trailing
                    // edge, so a second column would sit off-screen.
                    MovingQuestionBadge(prompt: previewPrompt,
                                        character: character,
                                        isPad: isPad)
                        .position(x: previewX, y: questionY)
                }

                if !shownOptions.isEmpty && entranceStage >= 3 && !completionActive {
                    MovingQuestionBadge(prompt: shownPrompt,
                                        character: character,
                                        isPad: isPad)
                        .position(x: hoopX, y: questionY)
                    ForEach(Array(shownOptions.enumerated()), id: \.element.id) { index, option in
                        AnswerHoop(text: option.text,
                                   tint: character.color,
                                   size: hoopSize,
                                   textScale: answerTextScale(for: shownOptions),
                                   feedback: feedback(for: option.id),
                                   isPressed: pressedOptionID == option.id)
                            .position(x: answerButtonX, y: lanes[index])
                    }
                }

                // A normal session's one rescue heart stands on its own,
                // mid-way between two sets.
                ForEach(lifeHearts) { heart in
                    LifeHeartView(size: lifeHeartSize,
                                  tint: character.deepColor,
                                  reduceMotion: reduceMotion)
                        .position(x: heart.x, y: lanes[min(heart.lane, lanes.count - 1)])
                        .allowsHitTesting(false)
                }

                if speedRunActive && !resolved {
                    TurboSpeedWake(size: penguinSize, phase: flightClock)
                        .position(x: penguinX - penguinSize * 0.58, y: penguinY)
                        .transition(.opacity)
                }

                RiggedPenguin(size: penguinSize,
                              rig: CharacterRig.rig(for: character.id),
                              pose: penguinPose,
                              flightMotion: penguinFlightMotion,
                              reduceMotion: reduceMotion,
                              flightClock: flightClock)
                    .modifier(CompletionFlightEffect(
                        progress: completionActive ? completionProgress : 0,
                        sceneSize: sceneSize,
                        start: completionStart,
                        penguinSize: penguinSize,
                        reduceMotion: reduceMotion
                    ))
                    // The reveal belongs to the muzzle, not to the flight. It
                    // used to inherit the launch curve's own 0.72s, which left
                    // a half-transparent penguin hanging over the whole arc.
                    .opacity(entranceStage < 3 ? 0 : 1)
                    .animation(.easeOut(duration: reduceMotion ? 0.03 : 0.16),
                               value: entranceStage >= 3)
                    .position(x: completionActive ? completionStart.x : displayedPenguinX + completionLeadX,
                              y: completionActive ? completionStart.y : displayedPenguinY)
                    .shadow(color: .black.opacity(0.18), radius: 6, y: 4)
                    .allowsHitTesting(false)

                // A second, near-side half of every hoop sits above the
                // penguin. The complete hoop below plus this arc above makes
                // the character visibly pass through the opening.
                hoopForegrounds

                // In the life lesson the two wrong answers are marked on the
                // near/right rim, so the warning remains visible over both the
                // hoop and the penguin as it passes through. This replaces the
                // full recovery hearts that used to stand behind the set.
                tutorialWrongHoopMarkers

                if launchPlatformActive {
                    cannonForeground
                }

                waterForeground

                if launchPlatformActive {
                    cannonPlatform
                }

                ForEach(splashes) { splash in
                    WaterSplash(direction: splash.direction,
                                strength: splash.strength,
                                reduceMotion: reduceMotion)
                        .frame(width: penguinSize * (1.15 + splash.strength * 0.80),
                               height: penguinSize * (0.78 + splash.strength * 0.62))
                        .position(x: splash.x, y: waterline)
                        .allowsHitTesting(false)
                }

                // Instruction graphics must sit above the near water layer:
                // the dive target deliberately lives below the surface.
                tutorialControlHint

                if let answerEcho, entranceStage >= 5, !completionActive {
                    SolvedAnswerEchoView(prompt: answerEcho.prompt,
                                         character: character,
                                         isPad: isPad)
                        .frame(maxWidth: proxy.size.width * 0.46, alignment: .leading)
                        .position(x: proxy.size.width * 0.25,
                                  y: proxy.size.height - bottomReserve - (isPad ? 88 : 68))
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }

                // The tap hint sits on the edge button it is asking for, so
                // "tap the right answer" has something to point at. It goes out
                // the moment the deadline is missed, because from there the tap
                // is no longer the one being taught.
                if tutorial.highlightsTurbo, !resolved, entranceStage >= 5,
                   let index = correctHoopIndex,
                   timingMarkerX(for: hoopX) > penguinX {
                    TutorialTapPulse(size: hoopSize * 0.86,
                                     tint: character.deepColor,
                                     reduceMotion: reduceMotion)
                        .position(x: answerButtonX, y: lanes[index])
                        .allowsHitTesting(false)
                }

                if let tutorialMessage, let symbol = tutorial.step?.symbolName,
                   entranceStage >= 5 {
                    // Low and only as wide as the sentence needs. The card is
                    // given nearly the whole width to play with so its one line
                    // stays one line; the cap is what the type then shrinks to
                    // fit, and a short lesson still gets a short card.
                    TutorialMessageCard(text: tutorialMessage,
                                        symbolName: symbol,
                                        theme: character,
                                        isPad: isPad)
                        .frame(maxWidth: proxy.size.width * 0.94)
                        .padding(.bottom, bottomReserve + (isPad ? 8 : 5))
                        .frame(maxWidth: .infinity, maxHeight: .infinity,
                               alignment: .bottom)
                        // Every touch belongs to the flight: the lesson must
                        // never swallow the tap it is asking for.
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .gesture(flightGesture)
            .simultaneousGesture(playfieldTapGesture)
            .onAppear {
                updateLayout(proxy.size)
                if playsFishEntrance { beginEntrance() }
                else { resolved = true }
                updateFrameClock(running: isRunning)
            }
            .onChange(of: proxy.size) { _, value in updateLayout(value) }
        }
        .ignoresSafeArea()
        .onReceive(frameClock.ticks, perform: tick)
        .onChange(of: isRunning) { _, running in
            updateFrameClock(running: running)
        }
        .onDisappear {
            frameClock.stop()
            lastTick = nil
        }
        .onChange(of: rounds.first?.id) { _, _ in configureRound(force: true) }
        .onChange(of: isLive) { _, live in
            if live && resolved { configureRound(force: true) }
        }
        .onChange(of: playsFishEntrance) { _, value in if value { beginEntrance() } }
        .onChange(of: preparesLevelCompletion) { _, value in
            guard value, !completionActive else { return }
            withAnimation(.easeOut(duration: reduceMotion ? 0.05 : 0.30)) {
                completionLeadX = sceneSize.width * 0.045
            }
        }
        .onChange(of: playsLevelCompletion) { _, value in if value { beginCompletion() } }
        .onChange(of: tutorial) { _, _ in applyTutorialPlan() }
    }

    private func updateFrameClock(running: Bool) {
        if running {
            // Never fold time spent paused into the next physics step.
            lastTick = nil
            frameClock.start()
        } else {
            frameClock.stop()
            lastTick = nil
        }
    }

    /// A step change rewrites what a set is allowed to be. A lesson hands over
    /// during the beat between one passage and the next sum being installed, so
    /// the set that carries the new rules is the one still waiting off-screen —
    /// nothing changes under the penguin's nose.
    private func applyTutorialPlan() {
        tutorialHold = false
        tutorialTurboTapped = false
        if tutorial.hidesHoops {
            shownOptions = []
            shownPrompt = ""
            previewOptions = []
            previewPrompt = ""
            previewRoundID = nil
            activeRoundID = nil
            resolved = false
            return
        }
        guard entranceStage >= 3, sceneSize.width > 0 else { return }
        guard !shownOptions.isEmpty else {
            // Coming out of the two movement lessons: the first real set is put
            // on the conveyor at the trailing edge and rides in from there.
            configureRound(force: true)
            return
        }
        // The set on its way in is the one the new step gets to shape. It is
        // taken over wholesale when the round turns over, so re-tuning it here
        // is what puts the lesson's rules on the very next hoops the player
        // meets.
        configurePreview()
        // The set already in frame keeps whatever it was dealt: swapping three
        // answers in plain sight is worse than one set of the old shape.
        guard !resolved, hoopX > sceneSize.width, let round = rounds.first else { return }
        let presented = presentation(for: round)
        shownOptions = presented.options
        noCorrectAnswer = presented.hasNoCorrectAnswer
    }

    /// The world this character flies across. Same flight, same cannon, same
    /// rings — a different place to do it in.
    private var scenery: SceneryTheme { SceneryThemes.theme(for: character.id) }

    private var polarBackdrop: some View {
        ZStack {
            PolarSkyLayer(size: sceneSize, worldOffset: worldOffset, theme: scenery)
            SceneryHorizonBand(size: sceneSize,
                               waterline: waterline,
                               worldOffset: worldOffset,
                               theme: scenery)
            PolarWaterBackdrop(size: sceneSize,
                               waterline: waterline,
                               worldOffset: worldOffset,
                               isPad: isPad,
                               theme: scenery)
        }
        .clipped()
        .allowsHitTesting(false)
    }

    /// Everything that floats between the water's two halves. Drawn before the
    /// rings and under the water foreground, so the wash sinks the lower half
    /// of every object for free.
    private var movingWorld: some View {
        DriftingFloaters(size: sceneSize,
                         waterline: waterline,
                         worldOffset: worldOffset,
                         isPad: isPad,
                         depth: .behind,
                         theme: scenery)
    }

    private var waterForeground: some View {
        ZStack {
            PolarWaterForeground(size: sceneSize,
                                 waterline: waterline,
                                 worldOffset: worldOffset,
                                 isPad: isPad,
                                 theme: scenery)
            DriftingFloaters(size: sceneSize,
                             waterline: waterline,
                             worldOffset: worldOffset,
                             isPad: isPad,
                             depth: .front,
                             theme: scenery,
                             // A foreground object directly below a ring stack
                             // reads as a solid obstacle. Keep that gameplay
                             // corridor visually open, including while an old
                             // set is drifting out after an answer.
                             exclusionXs: [foregroundHoopAnchorX],
                             exclusionSpacing: ringSetSpacing)
        }
    }

    /// A virtual first-ring corridor that is attached to the conveyor before
    /// the first set exists. The real set is installed when the start marker
    /// reaches the penguin; at that instant this anchor lands on `ringSpawnX`.
    /// Keeping it alive before then prevents near-water items from blinking as
    /// the launch changes from an empty field to its first set of hoops.
    private var foregroundHoopAnchorX: CGFloat {
        ringSpawnX + launchCameraOffset + startMarkerLead
    }

    private var startMarkerLead: CGFloat {
        sceneSize.width * 0.58 - normalPenguinX
    }

    /// The cannon stands on the pad's deck, so both are placed from the same
    /// number: raise or lower one and the other follows.
    private var cannonWidth: CGFloat { sceneSize.width * 0.269 }
    private var cannonHeight: CGFloat { sceneSize.width * 0.179 }
    private var launchPadHeight: CGFloat {
        // Keep the launch rock as low and wide as the iPhone version. Scaling
        // its width and height from different screen axes made it much taller
        // on iPad's squarer viewport, which lifted the cannon onto a high peak.
        min(sceneSize.height * 0.17, sceneSize.width * 0.0785)
    }

    private var cannonCentreY: CGFloat {
        guard isPad else { return sceneSize.height * 0.735 }
        // `canon.png` has transparent padding below the wheels: the last solid
        // artwork row is 586 in a 683-pixel image. Anchor that visible edge,
        // rather than the frame edge, to the levelled deck. This remains exact
        // at every iPad preview size and avoids another screenshot-based offset.
        let deckY = waterline
            - launchPadHeight * (PolarScene.padWaterline - PolarScene.padDeckFraction)
        let visibleWheelBottom = CGFloat(586) / CGFloat(683)
        let wheelOffsetFromCentre = cannonHeight * (visibleWheelBottom - 0.5)
        let contactOverlap = min(3, launchPadHeight * 0.035)
        return deckY - wheelOffsetFromCentre + contactOverlap
    }

    /// The character and the cannon share one launch origin. Any iPad deck
    /// correction therefore also moves the loaded pose and the first frame of
    /// the flight, keeping the character inside the barrel until departure.
    private var cannonMuzzleY: CGFloat {
        cannonCentreY - cannonHeight * 0.22
    }

    private var cannonLaunch: some View {
        CannonLaunchScene(stage: entranceStage,
                          reduceMotion: reduceMotion,
                          layer: .base)
            .frame(width: cannonWidth, height: cannonHeight)
            .position(x: launchPlatformX, y: cannonCentreY)
            .allowsHitTesting(false)
    }

    private var cannonForeground: some View {
        CannonLaunchScene(stage: entranceStage,
                          reduceMotion: reduceMotion,
                          layer: .barrelForeground)
            .frame(width: cannonWidth, height: cannonHeight)
            .position(x: launchPlatformX, y: cannonCentreY)
            .allowsHitTesting(false)
    }

    /// Drawn after the sea, not with the cannon. The launch site is the nearest
    /// thing in the world; behind the water it was hidden by whichever floe
    /// happened to be drifting past — and since both travel at the same speed,
    /// that floe stayed in the way for the whole entrance.
    private var cannonPlatform: some View {
        let height = launchPadHeight
        return CannonLaunchPad(theme: scenery)
            .frame(width: sceneSize.width * 0.25, height: height)
            .position(x: launchPlatformX,
                      y: waterline + height * (0.5 - PolarScene.padWaterline))
            .allowsHitTesting(false)
    }

    /// How far the launch site has travelled since the shot. It is pure world
    /// movement: the platform stands still while the fuse burns, leaves frame at
    /// the muzzle speed, and keeps drifting at exactly the speed of the water
    /// and the rings once the player has control. No stage ever moves it by
    /// itself, so the hand-over cannot produce a jump or a second pace.
    private var launchCameraOffset: CGFloat { worldOffset - launchWorldOrigin }

    private var launchPlatformX: CGFloat {
        sceneSize.width * 0.145 + launchCameraOffset
    }

    private var startMarkerX: CGFloat {
        sceneSize.width * 0.58 + launchCameraOffset
    }

    private var acceptsVerticalControl: Bool {
        let canSurface = (1...4).contains(divePhase)
        return isRunning && entranceStage >= 5 && !completionActive
            && (isLive || canSurface) && (!resolved || canSurface)
            && committedLaneIndex == nil && !tutorialAutoDiveActive
    }

    /// The first three lessons each get a gesture-shaped cue in the world, not
    /// another sentence in the message card. Their placement follows the
    /// penguin, so up/down, tap-above/tap-below and the route under the hoops
    /// remain understandable even when the child does not read the copy.
    @ViewBuilder private var tutorialControlHint: some View {
        if entranceStage >= 5, !completionActive {
            switch tutorial.step {
            case .dragToFly:
                TutorialVerticalDragHint(size: penguinSize,
                                         tint: character.deepColor,
                                         reduceMotion: reduceMotion)
                    .frame(width: penguinSize * 0.52, height: penguinSize * 1.72)
                    .position(x: displayedPenguinX + penguinSize * 0.70,
                              y: min(sceneSize.height - penguinSize * 0.88,
                                     max(penguinSize * 0.88, displayedPenguinY)))
                    .allowsHitTesting(false)

            case .tapToFly:
                TutorialHeightTapHint(penguin: CGPoint(x: displayedPenguinX,
                                                       y: displayedPenguinY),
                                      flightMaxY: flightMaxY,
                                      size: penguinSize,
                                      tint: character.deepColor,
                                      reduceMotion: reduceMotion)
                    .frame(width: sceneSize.width, height: sceneSize.height)
                    .allowsHitTesting(false)

            case .diveUnder:
                TutorialDivePathHint(
                    penguin: CGPoint(x: displayedPenguinX,
                                     y: displayedPenguinY),
                    start: CGPoint(x: displayedPenguinX + penguinSize * 0.38,
                                   y: displayedPenguinY + penguinSize * 0.16),
                    end: CGPoint(x: min(sceneSize.width * 0.62,
                                       max(displayedPenguinX + penguinSize * 1.15,
                                           hoopX - penguinSize * 0.72)),
                                 y: waterline + penguinSize * 0.13),
                    size: penguinSize,
                    tint: character.deepColor,
                    reduceMotion: reduceMotion
                )
                .frame(width: sceneSize.width, height: sceneSize.height)
                .opacity(tutorialAutoDiveActive ? 0.38 : 1)
                .allowsHitTesting(false)

            default:
                EmptyView()
            }
        }
    }

    private var flightGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard acceptsVerticalControl else { return }
                // The choice remains live throughout the assist zone. Only the
                // short commit zone at the hoop itself stops accepting a new
                // lane, so a late drag can still redirect an in-flight penguin.
                if dragStartY == nil {
                    dragStartY = targetPenguinY == 0 ? penguinY : targetPenguinY
                    directPressActive = false
                    beginPressHold(at: value.startLocation)
                }

                let distance = hypot(value.translation.width, value.translation.height)
                if distance > 8, !directPressActive {
                    // The player started dragging before the hold completed.
                    // Invalidate its delayed callback and retain relative drag.
                    pressHoldSequence += 1
                }

                if directPressActive {
                    movePenguinToward(y: value.location.y)
                } else {
                    // Movement is relative to where the penguin was when the
                    // drag began. A stationary hold deliberately switches to
                    // the absolute finger height after a short delay.
                    let requested = (dragStartY ?? penguinY) + value.translation.height
                    movePenguinToward(y: requested)
                }
                reportDraggedHeight()
            }
            .onEnded { _ in
                let completedPressHold = directPressActive
                pressHoldSequence += 1
                directPressActive = false
                dragStartY = nil
                if completedPressHold {
                    suppressTapAfterPressHold = true
                    DispatchQueue.main.async {
                        suppressTapAfterPressHold = false
                    }
                }
            }
    }

    private func beginPressHold(at location: CGPoint) {
        pressHoldSequence += 1
        let sequence = pressHoldSequence
        guard location.x < answerButtonX - hoopSize * 0.72 else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
            guard pressHoldSequence == sequence, dragStartY != nil,
                  acceptsVerticalControl else { return }
            directPressActive = true
            movePenguinToward(y: location.y)
        }
    }

    private var playfieldTapGesture: some Gesture {
        SpatialTapGesture()
            .onEnded { value in handlePlayfieldTap(at: value.location) }
    }

    private func handlePlayfieldTap(at location: CGPoint) {
        guard !directPressActive, !suppressTapAfterPressHold else { return }
        // Tapping the flush answer column presses a real button and steers the
        // penguin into that lane. Everywhere left of that rim is direct height
        // control. With no set on offer — the two movement lessons — every tap
        // is a height tap.
        if !shownOptions.isEmpty, location.x >= answerButtonX - hoopSize * 0.72 {
            handleRingTap(at: location)
        } else {
            handleHeightTap(at: location)
        }
    }

    /// Depress the arcade cap and play the shared press cue, then let it
    /// spring back on the same schedule as Nuts & Numbers' grab button.
    private func pressAnswerButton(_ optionID: UUID) {
        AppAudio.shared.playButtonPress()
        pressedOptionID = optionID
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
            if pressedOptionID == optionID {
                pressedOptionID = nil
            }
        }
    }

    private func handleHeightTap(at location: CGPoint) {
        guard acceptsVerticalControl else { return }

        dragStartY = nil
        reportTappedHeight(at: location)
        movePenguinToward(y: location.y)
    }

    /// The first lesson asks for a low point and a high point. Which half of
    /// the flight band the penguin has been *sent to* is what counts, so the
    /// step is satisfied by the drag itself rather than by waiting for the
    /// character to finish travelling there.
    private func reportDraggedHeight() {
        guard tutorial.tracksDrag else { return }
        let span = flightMaxY - flightMinY
        guard span > 1 else { return }
        if targetPenguinY >= flightMinY + span * 0.62 {
            onTutorialEvent(.draggedLow)
        } else if targetPenguinY <= flightMinY + span * 0.38 {
            onTutorialEvent(.draggedHigh)
        }
    }

    /// The second lesson is about the penguin, not about the screen: a tap
    /// counts as "under me" or "above me" relative to where it is flying.
    private func reportTappedHeight(at location: CGPoint) {
        guard tutorial.tracksTaps else { return }
        let margin = penguinSize * 0.30
        if location.y > penguinY + margin {
            onTutorialEvent(.tappedBelow)
        } else if location.y < penguinY - margin {
            onTutorialEvent(.tappedAbove)
        }
    }

    private func movePenguinToward(y requestedY: CGFloat) {
        let canSurface = (1...4).contains(divePhase)
        if requestedY >= waterline {
            // While flying itself is being taught the water is off limits: the
            // penguin flattens out along the bottom of the flight band instead
            // of diving out of the lesson.
            guard !tutorial.blocksDiving else {
                diveArmed = false
                divePhase = 0
                targetPenguinY = flightMaxY
                return
            }
            armDive()
            return
        }

        diveArmed = false
        if canSurface {
            if divePhase != 4 { divePhase = 3 }
        } else {
            divePhase = 0
        }
        targetPenguinY = min(max(requestedY, flightMinY), flightMaxY)
    }

    private func handleRingTap(at location: CGPoint) {
        guard isLive, isRunning, entranceStage >= 5, !resolved,
              committedLaneIndex == nil,
              location.x >= answerButtonX - hoopSize * 0.72 else { return }

        if location.y > lanes[2] + hoopSize * 0.46 {
            // The held set is waiting for one specific tap; nothing else — a
            // dive included — may take the lesson off its rails.
            guard !tutorialHold else { return }
            dragStartY = nil
            activateTurbo()
            speedBonusEligible = timingMarkerX(for: hoopX) > penguinX
            guard !tutorial.blocksDiving else { return }
            armDive()
            return
        }

        let lane = lanes.enumerated().min {
            abs($0.element - location.y) < abs($1.element - location.y)
        }?.offset ?? 1
        // While the turbo lesson holds the world still, only the button it is
        // pointing at releases it. Anything else leaves the column standing.
        if lane == correctHoopIndex {
            tutorialTurboTapped = true
            tutorialHold = false
        } else if tutorialHold {
            return
        }

        if lane < shownOptions.count {
            pressAnswerButton(shownOptions[lane].id)
        }

        dragStartY = nil
        activateTurbo()
        speedBonusEligible = timingMarkerX(for: hoopX) > penguinX

        if divePhase == 1 || divePhase == 2 || divePhase == 3 {
            divePhase = 3
        } else if divePhase != 4 {
            divePhase = 0
        }
        diveArmed = false
        targetPenguinY = lanes[lane]
    }

    private func timingMarkerX(for ringX: CGFloat) -> CGFloat {
        ringX - cruiseSpeed * 1.55
    }

    /// A valid early ring tap doubles the conveyor speed for this set. Keep the
    /// sound on the state transition so repeated touches cannot stack it.
    private func activateTurbo() {
        guard !speedRunActive else { return }
        speedRunActive = true
        AppAudio.shared.playTurbo()
    }

    /// Which of the three hoops carries the answer, if any of them does.
    private var correctHoopIndex: Int? {
        shownOptions.firstIndex { $0.isCorrect }
    }

    /// The number on the arcade cap has a fixed safe width. Its font scale is
    /// calculated from the widest option and then shared by all three answers,
    /// so a longer fraction never bursts its face or makes one lane look
    /// arbitrarily smaller than the other two.
    private func answerTextScale(for options: [AnswerOption]) -> CGFloat {
        guard hoopSize > 0, !options.isEmpty else { return 1 }
        let baseSize = hoopSize * 0.28
        let availableWidth = hoopSize * 0.56

#if canImport(UIKit)
        let baseFont = UIFont.systemFont(ofSize: baseSize, weight: .heavy)
        let roundedDescriptor = baseFont.fontDescriptor.withDesign(.rounded)
            ?? baseFont.fontDescriptor
        let roundedFont = UIFont(descriptor: roundedDescriptor, size: baseSize)
        let widest = options.map { option in
            (option.text as NSString).size(withAttributes: [.font: roundedFont]).width
        }.max() ?? 0
        guard widest > availableWidth else { return 1 }
        return max(0.40, min(1, availableWidth / widest))
#else
        // The production target is iOS. This conservative fallback preserves
        // the same grouped behaviour in previews on platforms without UIKit.
        let longest = CGFloat(options.map { $0.text.count }.max() ?? 1)
        return max(0.40, min(1, 3 / longest))
#endif
    }

    /// Where a held timing gate comes to a stop: still comfortably on the near
    /// side of its own deadline, so the tap on the flush edge button that
    /// releases it is the early tap the lesson is asking for.
    private var tutorialHoldX: CGFloat { sceneSize.width * 0.78 }

    private var displayedPenguinX: CGFloat {
        switch entranceStage {
        case 0, 1: return sceneSize.width * 0.22
        case 2: return sceneSize.width * 0.245
        case 3: return normalPenguinX
        case 4: return normalPenguinX
        default: return penguinX
        }
    }

    private var displayedPenguinY: CGFloat {
        switch entranceStage {
        // The muzzle's own height, so the character leaves the barrel rather
        // than appearing beside it. It follows every iPad deck correction.
        case 0, 1, 2: return cannonMuzzleY
        case 3: return lanes[1]
        case 4: return lanes[1]
        default: return penguinY
        }
    }

    private var penguinPose: PenguinPose {
        if completionActive { return .flying }
        if divePhase == 1 { return .diving }
        if divePhase == 2 { return .underwater }
        if divePhase == 3 { return .resurfacing }
        if divePhase == 4 { return .recovering }
        switch entranceStage {
        case 0: return .loaded
        case 1: return .compressed
        case 2, 3: return .launching
        default:
            if abs(hoopX - penguinX) < hoopSize * 0.62 { return .threading }
            return .flying
        }
    }

    /// Solid arcade buttons have no near-side rim to composite over the
    /// character. The flush edge column already reads in front of the water.
    @ViewBuilder private var hoopForegrounds: some View {
        EmptyView()
    }

    /// The warning belongs to the two wrong answers themselves. Keeping it on
    /// the outer rim of the edge buttons makes it legible before a passage.
    @ViewBuilder private var tutorialWrongHoopMarkers: some View {
        if tutorial.marksWrongHoops, entranceStage >= 3, !completionActive {
            if !resolved {
                ForEach(Array(shownOptions.enumerated()), id: \.element.id) { index, option in
                    if !option.isCorrect {
                        BrokenHeartHoopMarker(size: hoopSize * 0.30,
                                              tint: character.deepColor,
                                              reduceMotion: reduceMotion)
                            .position(x: answerButtonX + hoopSize * 0.28,
                                      y: lanes[index])
                    }
                }
            }
        }
    }

    private func hoopOcclusionOpacity(at x: CGFloat) -> Double {
        let fadeStart = hoopSize * 1.15
        let fadeEnd = hoopSize * 0.82
        let distance = abs(x - penguinX)
        return Double(min(1, max(0, (fadeStart - distance) / (fadeStart - fadeEnd))))
    }

    private var penguinFlightMotion: PenguinFlightMotion {
        if completionActive { return .level }
        guard entranceStage >= 5, divePhase == 0 else { return .level }
        let delta = targetPenguinY - penguinY
        if delta < -2 { return .rising }
        if delta > 2 { return .falling }
        return .level
    }

    private func updateLayout(_ size: CGSize) {
        sceneSize = size
        penguinX = normalPenguinX
        if penguinY == 0 {
            penguinY = lanes[1]
            targetPenguinY = penguinY
            previousPenguinY = penguinY
            diveStartY = penguinY
        }
        if hoopX == 0 { hoopX = ringSpawnX }
    }

    private func beginEntrance() {
        completionSequence &+= 1
        completionActive = false
        completionProgress = 0
        completionStart = .zero
        completionLeadX = 0
        entranceStage = 0
        resolved = true
        shownOptions = []
        shownPrompt = ""
        previewOptions = []
        previewPrompt = ""
        previewRoundID = nil
        retiringSets = []
        activeRoundID = nil
        answerEcho = nil
        emphasizesCorrectAnswer = false
        hoopX = ringSpawnX
        penguinX = normalPenguinX
        penguinY = lanes[1]
        targetPenguinY = penguinY
        dragStartY = nil
        noCorrectAnswer = false
        diveArmed = false
        divePhase = 0
        committedLaneIndex = nil
        splashes = []
        surfaceSubmerged = false
        previousPenguinY = penguinY
        diveStartY = penguinY
        lastTick = nil
        flightClock = 0
        speedRunActive = false
        speedBonusEligible = false
        bonusOptionID = nil
        selectedOptionID = nil
        bypassedWrongSet = false
        launchSpeedHandoffActive = false
        launchGlideSpeed = 0
        launchWorldOrigin = worldOffset
        launchPlatformActive = true
        startMarkerActive = true
        lifeHearts = []
        hasPlacedRescueHeart = false
        tutorialHold = false
        tutorialTurboTapped = false
        tutorialAutoDiveRoundID = nil
        tutorialAutoDiveActive = false
        AppAudio.shared.playFireCrackle()
        let fuseDuration = reduceMotion ? 0.12 : 1.45
        let squeezeDuration = reduceMotion ? 0.06 : 0.24
        let flightDuration = reduceMotion ? 0.10 : 0.72
        DispatchQueue.main.asyncAfter(deadline: .now() + fuseDuration * 0.72) {
            withAnimation(.spring(response: squeezeDuration, dampingFraction: 0.58)) { entranceStage = 1 }
        }
        // Schedule just ahead of the visual frame: the trimmed effect keeps a
        // tiny natural attack, so its boom lands on the muzzle flash itself.
        let cannonSoundLead: TimeInterval = 0.035
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, fuseDuration - cannonSoundLead)) {
            AppAudio.shared.playCannonShoot()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + fuseDuration) {
            AppAudio.shared.stopFireCrackle()
            withAnimation(.easeOut(duration: reduceMotion ? 0.03 : 0.10)) { entranceStage = 2 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + fuseDuration + 0.10) {
            // The shot starts the world. From this frame one deceleration curve
            // carries the scenery, the launch platform and the first ring set,
            // straight through the moment the player takes over.
            launchGlideSpeed = sceneSize.width * 1.25
            launchSpeedHandoffActive = true
            withAnimation(.timingCurve(0.12, 0.72, 0.78, 0.88,
                                       duration: flightDuration)) { entranceStage = 3 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + fuseDuration + 0.10 + flightDuration) {
            withAnimation(.easeOut(duration: reduceMotion ? 0.03 : 0.08)) { entranceStage = 5 }
            // A no-op once the start marker has handed the first set over. It
            // only does the work itself when the launch was too short for the
            // marker to be passed, as with reduced motion.
            configureRound(force: false)
            resolved = false
            if reduceMotion {
                // Nothing drifts out of frame on its own here, so the launch
                // site leaves with the entrance it belongs to.
                launchPlatformActive = false
                startMarkerActive = false
            }
            onFishEntranceComplete()
        }
    }

    private func configureRound(force: Bool) {
        // From the shot onwards, so the first set can already be travelling
        // while the penguin is still leaving the barrel.
        guard entranceStage >= 3, let round = rounds.first, sceneSize.width > 0 else { return }
        // The first two lessons are about flying and nothing else: no set is
        // put on the conveyor at all until the hoops are introduced.
        guard !tutorial.hidesHoops else { return }
        guard force || activeRoundID != round.id else { return }
        let promotesPreview = previewRoundID == round.id
        let promotedX = previewX
        if !shownOptions.isEmpty, hoopX > -hoopSize * 0.65 {
            retiringSets.append(makeRetiringSet())
            if retiringSets.count > 1 { retiringSets.removeFirst(retiringSets.count - 1) }
        }
        activeRoundID = round.id
        shownPrompt = round.question.prompt
        if promotesPreview {
            shownOptions = previewOptions
            noCorrectAnswer = previewHasNoCorrectAnswer
            hoopX = promotedX
        } else {
            let presentation = presentation(for: round)
            shownOptions = presentation.options
            noCorrectAnswer = presentation.hasNoCorrectAnswer
            hoopX = ringSpawnX
        }
        configurePreview()
        penguinX = normalPenguinX
        resolved = false
        diveArmed = false
        committedLaneIndex = nil
        speedRunActive = false
        speedBonusEligible = false
        bonusOptionID = nil
        selectedOptionID = nil
        bypassedWrongSet = false
        emphasizesCorrectAnswer = false
        tutorialTurboTapped = false
        placeRescueHeartIfDue()
        // Keep the exact flight height between sets. Only a completed dive
        // changes it as part of its resurfacing sequence.
    }

    /// The session's one rescue heart, placed halfway between the set that is
    /// arriving and the one before it, in the lane the answer is in — so the
    /// line that takes the player to the heart is the same line that takes them
    /// through the right hoop. A set with no right answer has no such lane and
    /// simply waits for the next one.
    private func placeRescueHeartIfDue() {
        guard isRescueHeartDue, !hasPlacedRescueHeart,
              !tutorial.isRunning, !shownOptions.isEmpty,
              let lane = correctHoopIndex else { return }
        hasPlacedRescueHeart = true
        lifeHearts.append(LifeHeartPickup(lane: lane,
                                          x: hoopX - ringSetSpacing * 0.5))
        onRescueHeartPlaced()
    }

    /// A heart is taken when the penguin reaches it in the lane it is sitting
    /// in. Under water it is out of reach, which is the point.
    private func collectLifeHearts() {
        guard !lifeHearts.isEmpty, divePhase != 1, divePhase != 2 else { return }
        let reach = hoopSize * 0.46
        guard let taken = lifeHearts.first(where: { heart in
            guard heart.lane < lanes.count else { return false }
            return abs(heart.x - penguinX) <= reach
                && abs(lanes[heart.lane] - penguinY) <= hoopSize * 0.44
        }) else { return }
        lifeHearts.removeAll { $0.id == taken.id }
        onLifeHeartCollected(CGPoint(x: penguinX, y: lanes[taken.lane]))
    }

    private func configurePreview() {
        guard rounds.count > 1 else {
            previewRoundID = nil
            previewPrompt = ""
            previewOptions = []
            previewHasNoCorrectAnswer = false
            return
        }
        let round = rounds[1]
        let presentation = presentation(for: round)
        previewRoundID = round.id
        previewPrompt = round.question.prompt
        previewOptions = presentation.options
        previewHasNoCorrectAnswer = presentation.hasNoCorrectAnswer
    }

    private func presentation(for round: GameRound) -> (options: [AnswerOption], hasNoCorrectAnswer: Bool) {
        // Stable per generated round, but not tied to a repeating question
        // interval. Independent buckets naturally allow two dive rounds in a
        // row while keeping the overall chance close to one in four.
        let seed = round.id.uuidString.utf8.reduce(UInt64(14_695_981_039_346_656_037)) {
            ($0 ^ UInt64($1)) &* 1_099_511_628_211
        }
        // A lesson decides what its own set has to be: three wrong answers
        // while diving underneath is being taught, one right answer for every
        // step after it. Everything else is left to chance, as in a real run.
        var hasNoCorrectAnswer = seed.isMultiple(of: 4)
        if tutorial.forcesNoCorrectAnswer { hasNoCorrectAnswer = true }
        if tutorial.forcesCorrectAnswer { hasNoCorrectAnswer = false }
        let wrong = round.options.filter { !$0.isCorrect }
        if hasNoCorrectAnswer {
            return (Array(wrong.prefix(3)), true)
        }
        guard let correct = round.correctOption else { return (Array(wrong.prefix(3)), false) }
        let choices = [correct] + Array(wrong.prefix(2))
        // A lesson may ask for the answer in the top hoop; ordinary play rotates
        // it so no lane is ever the safe bet.
        guard !tutorial.putsAnswerOnTop else { return (choices, false) }
        let offset = round.number % choices.count
        return (Array(choices[offset...] + choices[..<offset]), false)
    }

    private func tick(_ now: Date) {
        defer { lastTick = now }
        guard let lastTick else { return }
        guard isRunning else { return }
        let dt = min(0.05, now.timeIntervalSince(lastTick))
        if completionActive {
            // The world has stopped, but the wings keep beating throughout the
            // looping exit so the penguin never turns into a rigid cut-out.
            if !reduceMotion { flightClock += dt }
            // The solved hoops belong to the passage that just happened. Let
            // them finish travelling off-screen instead of deleting or
            // freezing them when the finale takes over the penguin.
            let hoopStep = cruiseSpeed * CGFloat(dt)
            for index in retiringSets.indices { retiringSets[index].x -= hoopStep }
            retiringSets.removeAll { $0.x < -hoopSize * 0.65 }
            return
        }

        // Nothing moves while the fuse burns. From the shot on, one conveyor
        // carries everything that stands in the world — scenery, launch site,
        // start marker and rings — at one shared speed.
        guard entranceStage >= 3 else { return }
        // The turbo lesson stops the conveyor once the player has had their
        // three free sets: the hoops and the tap hint stand still until the
        // right one is tapped. Only the world waits — the penguin keeps flying,
        // and every touch keeps being answered.
        if tutorial.holdsForTurbo, !tutorialHold, !resolved, !tutorialTurboTapped,
           !shownOptions.isEmpty, hoopX <= tutorialHoldX {
            tutorialHold = true
        }
        if !tutorialHold { advanceWorld(dt: CGFloat(dt)) }

        guard entranceStage >= 5 else { return }

        // Two missed dive sets turn the next one into a wordless demonstration.
        // Start early enough for the complete descent to be visible before the
        // rings reach the penguin, and hold user input until it has resurfaced.
        if tutorial.demonstratesDive, !resolved, !shownOptions.isEmpty,
           tutorialAutoDiveRoundID != activeRoundID,
           hoopX <= sceneSize.width * 0.76 {
            tutorialAutoDiveRoundID = activeRoundID
            tutorialAutoDiveActive = true
            dragStartY = nil
            armDive()
        }

        collectLifeHearts()
        if !reduceMotion { flightClock += dt }

        // One critically damped movement path owns vertical control. It reacts
        // quickly to the drag target without stacking SwiftUI spring animations
        // or producing velocity after the finger stops.
        if targetPenguinY != 0 {
            let delta = targetPenguinY - penguinY
            // The wings turn quickly into the streamlined pose, so the actual
            // dive can remain responsive instead of slowing gameplay down.
            let response: CGFloat = divePhase == 1 ? 11 : 13
            let desiredStep = delta * (1 - exp(-response * CGFloat(dt)))
            let maxSpeed = sceneSize.height * (divePhase == 1 ? 1.12 : 1.65)
            let maxStep = maxSpeed * CGFloat(dt)
            penguinY += min(max(desiredStep, -maxStep), maxStep)
            if abs(delta) < 0.2 { penguinY = targetPenguinY }
        }

        // In the final approach, steer toward the player's requested height,
        // not merely the penguin's current height. This is what lets a late
        // switch win even while the character is still travelling between two
        // lanes. The force grows smoothly as the hoop arrives.
        let approachDistance = hoopX - penguinX
        if divePhase == 0, !resolved,
           approachDistance >= 0, approachDistance <= laneAssistDistance {
            let requestedLane = lanes.enumerated().min {
                abs($0.element - targetPenguinY) < abs($1.element - targetPenguinY)
            }?.offset ?? 1

            // Keep re-evaluating intent until there is only a very short,
            // speed-adjusted amount of travel left. From that point one lane
            // owns the passage, avoiding an ambiguous between-hoops result.
            if committedLaneIndex == nil, approachDistance <= laneCommitDistance {
                committedLaneIndex = requestedLane
            }

            let assistedLane = committedLaneIndex ?? requestedLane
            let laneY = lanes[assistedLane]
            let progress = 1 - approachDistance / laneAssistDistance
            var response = 7 + progress * progress * 16

            if committedLaneIndex != nil {
                // Once committed, converge to practically the lane centre by
                // the time the hoop centre reaches the penguin. The final-frame
                // placement removes the last sub-pixel ambiguity without a
                // visible teleport.
                let remainingTime = max(CGFloat(dt), approachDistance / max(1, approachSpeed))
                response = max(response, 4.8 / remainingTime)
                targetPenguinY = laneY
                if approachDistance <= approachSpeed * CGFloat(dt) * 1.05 {
                    penguinY = laneY
                }
            } else if dragStartY == nil {
                // With no finger down, let the same movement controller settle
                // too. A new drag still replaces this target until commitment.
                targetPenguinY = laneY
            }

            penguinY += (laneY - penguinY) * (1 - exp(-response * CGFloat(dt)))
        }

        // The surface itself decides when a splash is thrown, not the dive
        // state machine. Whatever moved the penguin across the line — a drag,
        // a tap, or a round resolving under water — the crossing is what is
        // measured, so a splash can no longer be skipped.
        updateSurfaceCrossing(dt: CGFloat(dt))

        if divePhase == 1, penguinY >= waterline + penguinSize * 0.10 {
            withAnimation(.easeInOut(duration: 0.26)) { divePhase = 2 }
        }

        if divePhase == 3 {
            // Keep the strong exit pose for the complete ascent. Only when
            // the player-selected height is reached do body and wings rotate
            // back into normal flight together.
            let reachedTarget = abs(targetPenguinY - penguinY) <= max(3, penguinSize * 0.018)
            if !surfaceSubmerged && reachedTarget {
                tutorialAutoDiveActive = false
                withAnimation(.easeInOut(duration: 0.30)) { divePhase = 4 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
                    if divePhase == 4 { divePhase = 0 }
                }
            }
        }

        guard isLive, !resolved, !shownOptions.isEmpty else { return }
        // Resolve only once the centres align: the penguin visibly travels
        // through the hoop instead of triggering against its leading edge.
        guard hoopX <= penguinX else { return }
        resolvePassage()
    }

    /// Moves everything that stands in the world on by one frame.
    ///
    /// The muzzle speed decays into the cruise speed along a single curve that
    /// keeps running across the hand-over, so the moment the player takes
    /// control is not a moment the world can be seen changing pace. An early
    /// ring tap accelerates the same conveyor, never the penguin's screen
    /// position.
    private func advanceWorld(dt: CGFloat) {
        let requested = cruiseSpeed * (speedRunActive && !resolved ? 2 : 1)
        var speed = requested
        if launchSpeedHandoffActive {
            launchGlideSpeed += (requested - launchGlideSpeed) * (1 - exp(-3.4 * dt))
            speed = launchGlideSpeed
            if abs(launchGlideSpeed - requested) < 1.5 {
                launchGlideSpeed = requested
                launchSpeedHandoffActive = false
            }
        }
        worldOffset -= speed * dt
        // The start marker is the starting line: the moment the penguin draws
        // level with it, the first set is put on the conveyor at the trailing
        // edge and rides in from there. Spawning it at the shot instead sent it
        // across the screen at the muzzle speed.
        if activeRoundID == nil, startMarkerX <= normalPenguinX {
            configureRound(force: true)
        }
        if launchPlatformActive, launchPlatformX < -sceneSize.width * 0.30 {
            launchPlatformActive = false
        }
        if startMarkerActive, startMarkerX < -penguinSize * 0.45 {
            startMarkerActive = false
        }
        for index in retiringSets.indices { retiringSets[index].x -= speed * dt }
        retiringSets.removeAll { $0.x < -hoopSize * 0.65 }
        // The rescue heart rides the same conveyor as every set.
        if !lifeHearts.isEmpty {
            for index in lifeHearts.indices { lifeHearts[index].x -= speed * dt }
            lifeHearts.removeAll { $0.x < -hoopSize * 0.65 }
        }
        if !shownOptions.isEmpty { hoopX -= speed * dt }
    }

    private func resolvePassage() {
        guard !resolved, let round = rounds.first else { return }
        withAnimation(.easeInOut(duration: 0.24)) { resolved = true }
        let selected: AnswerOption
        let isCorrect: Bool
        let usesSpeedBonus: Bool
        let usesHalfLifePenalty: Bool

        // Treat the visible flight path as authoritative too. During a quick
        // resurfacing the dive phase may already have advanced while the
        // penguin is still physically below the complete hoop stack.
        let isBelowRings = diveArmed || divePhase == 1 || divePhase == 2
            || penguinY > lanes[2] + hoopSize * 0.46
        if isBelowRings, noCorrectAnswer, let correct = round.correctOption {
            selected = correct
            isCorrect = true
            usesHalfLifePenalty = false
            remainUnderwater()
        } else if isBelowRings, let wrong = round.options.first(where: { !$0.isCorrect }) {
            // Diving below a regular set deliberately misses every hoop.
            selected = wrong
            isCorrect = false
            usesHalfLifePenalty = true
            remainUnderwater()
        } else {
            let nearest = committedLaneIndex
                ?? lanes.enumerated().min {
                    abs($0.element - penguinY) < abs($1.element - penguinY)
                }?.offset
                ?? 1
            selected = shownOptions[min(nearest, shownOptions.count - 1)]
            isCorrect = selected.isCorrect
            usesHalfLifePenalty = false
        }

        usesSpeedBonus = speedBonusEligible && isCorrect
        guard onHit(selected.id, usesSpeedBonus, usesHalfLifePenalty) else {
            resolved = false
            return
        }
        // A regular set passed underneath still needs a wrong option for the
        // game engine to apply its penalty, but no hoop was actually touched.
        // Keep that synthetic choice out of the visual feedback so only the
        // revealed correct hoop turns green; red remains reserved for a wrong
        // hoop the penguin really flew through.
        // What the passage was is only knowable here: the engine is told an
        // option, but whether the penguin threaded a hoop or went underneath
        // the lot is the field's own business — and it is the whole difference
        // between the lessons being taught.
        if tutorial.isRunning {
            if isBelowRings {
                onTutorialEvent(.passedUnderSet)
            } else if isCorrect {
                onTutorialEvent(.passedCorrectHoop(withTurbo: usesSpeedBonus))
            } else {
                onTutorialEvent(.passedWrongHoop)
            }
        }

        // The ordinary rule intentionally leaves a player underwater until
        // they choose a new height. The automatic lesson is a demonstration,
        // though, so it also shows the matching climb back into the air.
        if isBelowRings, tutorialAutoDiveRoundID == activeRoundID {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
                guard tutorialAutoDiveActive else { return }
                diveArmed = false
                divePhase = 3
                targetPenguinY = lanes[1]
            }
        }
        selectedOptionID = isBelowRings ? nil : selected.id
        bypassedWrongSet = isBelowRings && noCorrectAnswer && isCorrect
        if !isBelowRings {
            pressAnswerButton(selected.id)
        }
        if usesSpeedBonus {
            withAnimation(.easeInOut(duration: 0.20)) { bonusOptionID = selected.id }
        }
        if !isCorrect {
            let solvedPrompt = round.question.solvedPrompt
            shownPrompt = solvedPrompt
            emphasizesCorrectAnswer = true
            showAnswerEcho(solvedPrompt)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            if noCorrectAnswer && isCorrect { onDive() }
            else { onSwallow(isCorrect) }
        }
    }

    /// Passing a set underwater no longer launches an automatic exit. The
    /// penguin waits just below the surface until the player drags upward.
    private func remainUnderwater() {
        divePhase = 2
        penguinY = diveY
        targetPenguinY = diveY
    }

    /// Keeps the solved sum available after its moving set has passed without
    /// slowing or blocking the next set. A newer mistake replaces the older
    /// echo and owns its dismissal token.
    private func showAnswerEcho(_ prompt: String) {
        let echo = SolvedAnswerEcho(prompt: prompt)
        withAnimation(.easeOut(duration: 0.16)) { answerEcho = echo }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            guard answerEcho?.id == echo.id else { return }
            withAnimation(.easeOut(duration: 0.20)) { answerEcho = nil }
        }
    }

    /// Starts — or keeps — a dive. The height it begins from is recorded here
    /// because that, not the speed on the frame the surface happens to be
    /// crossed, is what the entry splash is sized by. Taking it at the moment
    /// the dive is armed also survives a round that resolves under water and
    /// puts the penguin below the line in a single step.
    private func armDive() {
        if divePhase != 1 && divePhase != 2 { diveStartY = penguinY }
        diveArmed = true
        if divePhase != 2 { divePhase = 1 }
        targetPenguinY = diveY
    }

    /// One splash per surface crossing, in either direction. The latch is on
    /// the penguin's position rather than on the dive state, so however it got
    /// under the line — dragged, tapped, or placed there by a resolved round —
    /// the water is always broken visibly.
    private func updateSurfaceCrossing(dt: CGFloat) {
        let level = waterline - penguinSize * 0.06
        let previous = previousPenguinY
        previousPenguinY = penguinY
        if !surfaceSubmerged, penguinY >= level {
            surfaceSubmerged = true
            AppAudio.shared.playSplash()
            emitSplash(.entering, strength: diveStrength)
        } else if surfaceSubmerged, penguinY <= level - penguinSize * 0.05 {
            surfaceSubmerged = false
            let climb = max(0, previous - penguinY) / max(dt, 1.0 / 240)
            emitSplash(.exiting, strength: climb / max(1, sceneSize.height * 1.5))
        }
    }

    /// How hard the penguin hit the water. A drop from the top of the flight
    /// window arrives at 1 and throws the full crown; a slip in from just above
    /// the surface still splashes, just modestly.
    private var diveStrength: CGFloat {
        let fall = waterline - diveStartY
        let span = max(1, waterline - flightMinY)
        return min(1, max(0.16, fall / span))
    }

    private func emitSplash(_ direction: WaterSplashDirection, strength: CGFloat) {
        let event = SplashEvent(direction: direction,
                                strength: min(1, max(0, strength)),
                                x: penguinX)
        splashes.append(event)
        // A cap, not a queue: rapid dives should overlap, not pile up.
        if splashes.count > 3 { splashes.removeFirst(splashes.count - 3) }
        let life = WaterSplash.life(direction: direction,
                                    strength: event.strength,
                                    reduceMotion: reduceMotion)
        DispatchQueue.main.asyncAfter(deadline: .now() + life + 0.05) {
            splashes.removeAll { $0.id == event.id }
        }
    }

    private func beginCompletion() {
        guard !completionActive else { return }
        completionSequence &+= 1
        let sequence = completionSequence
        completionStart = CGPoint(x: penguinX + completionLeadX, y: penguinY)
        completionActive = true
        completionProgress = 0
        completionLeadX = 0
        resolved = true

        // Preserve the final set as a retiring set before clearing the active
        // question. It can then drift out at conveyor speed throughout the
        // looping flight instead of vanishing on the hand-off frame.
        if !shownOptions.isEmpty, hoopX > -hoopSize * 0.65 {
            retiringSets.append(makeRetiringSet())
        }
        shownOptions = []
        shownPrompt = ""
        previewOptions = []
        previewPrompt = ""
        previewRoundID = nil
        speedRunActive = false
        answerEcho = nil
        emphasizesCorrectAnswer = false
        diveArmed = false
        splashes = []
        surfaceSubmerged = false
        lifeHearts = []
        tutorialHold = false
        tutorialTurboTapped = false
        tutorialAutoDiveRoundID = nil
        tutorialAutoDiveActive = false
        // The world stops for the finale, so anything still drifting out of
        // frame would stand frozen in it.
        launchPlatformActive = false
        startMarkerActive = false

        // Give the exit its own unhurried beat after the loop. At 2.4 seconds
        // the final screen-width was crossed in barely half a second, which
        // made an otherwise soft finale snap away at the end.
        let duration = reduceMotion ? 0.55 : 2.9
        withAnimation(.linear(duration: duration)) {
            completionProgress = 1
        }

        // Reveal the result once the penguin is almost beyond the trailing
        // edge. The remaining tail of the flight keeps running underneath the
        // card, so the animation stays smooth without making the player wait
        // for movement that is effectively already off-screen.
        let resultRevealProgress = 0.88
        DispatchQueue.main.asyncAfter(deadline: .now() + duration * resultRevealProgress) {
            guard completionActive, completionSequence == sequence else { return }
            onLevelCompletionFinished()
        }
    }

    private func feedback(for optionID: UUID) -> HoopFeedback {
        // A set travelling in during the launch is never a resolved set: it has
        // not been played yet, so it must not wear an answer's colours.
        guard entranceStage >= 5 else { return .none }
        if resolved, bypassedWrongSet { return .bypassed }
        if resolved, bonusOptionID == optionID,
           shownOptions.first(where: { $0.id == optionID })?.isCorrect == true {
            return .bonus
        }
        guard resolved,
              let option = shownOptions.first(where: { $0.id == optionID })
        else { return .none }
        if selectedOptionID == optionID {
            return option.isCorrect ? .correct : .wrong
        }
        if option.isCorrect, emphasizesCorrectAnswer { return .revealedCorrect }
        return .inactive
    }

    /// Freeze the resolved visual state before the next set replaces the
    /// active options. This preserves a successful all-wrong dive as neutral
    /// blue instead of recomputing every old option as a mistake.
    private func makeRetiringSet() -> RetiringHoopSet {
        let feedbacks = Dictionary(uniqueKeysWithValues: shownOptions.map {
            ($0.id, feedback(for: $0.id))
        })
        // Retire from the flush edge column so spent buttons drift inward
        // instead of appearing mid-air where the timing gate happens to stand.
        return RetiringHoopSet(options: shownOptions,
                               prompt: shownPrompt,
                               x: answerButtonX,
                               feedbacks: feedbacks)
    }
}

/// Carries the penguin through one full loop and then beyond the trailing edge.
/// Keeping the path inside an animatable modifier makes every intermediate
/// frame follow the curve instead of interpolating in a straight line between
/// a handful of state changes.
struct CompletionFlightEffect: AnimatableModifier {
    var progress: CGFloat
    let sceneSize: CGSize
    let start: CGPoint
    let penguinSize: CGFloat
    let reduceMotion: Bool

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let sample = flightSample
        content
            .rotationEffect(.degrees(sample.rotation))
            .offset(sample.offset)
    }

    private var flightSample: (offset: CGSize, rotation: Double) {
        let p = min(1, max(0, progress))
        let exitX = sceneSize.width + penguinSize * 1.3 - start.x

        if reduceMotion {
            return (CGSize(width: exitX * smoothstep(p), height: 0), 0)
        }

        let leadEnd: CGFloat = 0.14
        // Reserve almost a third of the complete animation for the flight out
        // of frame. Combined with smoothstep this keeps both the hand-off from
        // the loop and the final disappearance calm and continuous.
        let loopEnd: CGFloat = 0.70
        let leadX = sceneSize.width * 0.06
        let radius = min(sceneSize.width * 0.13, sceneSize.height * 0.14)
        // Pull an underwater final answer back into clear sky before the loop,
        // while keeping an already-flying answer at a familiar height.
        let loopY = max(sceneSize.height * 0.38,
                        min(start.y, sceneSize.height * 0.70))
        let leadY = loopY - start.y

        if p < leadEnd {
            let t = smoothstep(p / leadEnd)
            let tilt = leadY < -1 ? -18 * Double(sin(t * .pi)) : 0
            return (CGSize(width: leadX * t, height: leadY * t), tilt)
        }

        if p < loopEnd {
            let t = (p - leadEnd) / (loopEnd - leadEnd)
            let angle = t * .pi * 2
            return (
                CGSize(width: leadX + radius * sin(angle),
                       height: leadY - radius * (1 - cos(angle))),
                -360 * Double(t)
            )
        }

        let t = smoothstep((p - loopEnd) / (1 - loopEnd))
        return (
            CGSize(width: leadX + (exitX - leadX) * t,
                   height: leadY - sceneSize.height * 0.035 * sin(t * .pi)),
            -360
        )
    }

    private func smoothstep(_ value: CGFloat) -> CGFloat {
        let t = min(1, max(0, value))
        return t * t * (3 - 2 * t)
    }
}

enum PenguinPose: Equatable {
    case loaded
    case compressed
    case standing
    case launching
    case threading
    case flying
    case diving
    case underwater
    case resurfacing
    case recovering
}

enum PenguinFlightMotion: Equatable { case rising, level, falling }

/// The three source canvases share exactly the same geometry. Keeping every
/// layer full-size preserves the artist's alignment; only each arm rotates
/// around its own fixed shoulder point.
struct RiggedPenguin: View {
    let size: CGFloat
    let rig: CharacterRig
    let pose: PenguinPose
    let flightMotion: PenguinFlightMotion
    let reduceMotion: Bool
    let flightClock: Double

    var body: some View {
        let phase = flapPhase
        let transitionDuration: Double = pose == .diving ? 0.11 : (pose == .recovering ? 0.30 : 0.26)
        ZStack {
            rigImage(rig.backArmImage)
                .rotationEffect(.degrees(backArmAngle(phase: phase)),
                                anchor: rig.backShoulder)
                .animation(.easeInOut(duration: transitionDuration), value: pose)

            rigImage(rig.bodyImage)

            rigImage(rig.frontArmImage)
                .rotationEffect(.degrees(frontArmAngle(phase: phase)),
                                anchor: rig.frontShoulder)
                .animation(.easeInOut(duration: transitionDuration), value: pose)
        }
        .frame(width: size * 1.5, height: size)
        // Normalise the drawing before the pose is applied, so every rotation
        // below still turns around the body rather than around the canvas.
        .scaleEffect(rig.artScale)
        .offset(x: size * 1.5 * rig.artOffset.width, y: size * rig.artOffset.height)
        .rotationEffect(.degrees(wholeBodyAngle))
        .scaleEffect(x: bodyScaleX, y: bodyScaleY)
        .allowsHitTesting(false)
    }

    private func rigImage(_ name: String) -> some View {
        Image(name)
            .resizable()
            .aspectRatio(3.0 / 2.0, contentMode: .fit)
            .frame(width: size * 1.5, height: size)
    }

    private var flapPhase: Double {
        guard !reduceMotion, pose == .flying else { return 0 }
        let cyclesPerSecond: Double
        switch flightMotion {
        case .rising: cyclesPerSecond = 4
        case .level: cyclesPerSecond = 2.2
        case .falling: return 0
        }
        return sin(flightClock * .pi * 2 * cyclesPerSecond)
    }

    private var wholeBodyAngle: Double {
        switch pose {
        case .loaded, .compressed, .standing, .recovering: return 0
        case .launching: return -11
        case .threading: return 0
        case .diving: return 31
        case .underwater: return 5
        case .resurfacing: return -28
        case .flying:
            switch flightMotion {
            case .rising: return -11
            case .level: return 0
            case .falling: return 7
            }
        }
    }

    private var bodyScaleX: CGFloat {
        switch pose {
        case .loaded: return 0.84
        case .compressed: return 0.68
        default: return 1
        }
    }

    private var bodyScaleY: CGFloat { pose == .compressed ? 1.10 : 1 }

    private func backArmAngle(phase: Double) -> Double {
        switch pose {
        // The far wing points forward in the source artwork. A clockwise
        // rotation of roughly 210 degrees folds it toward the tail.
        case .launching: return 210
        case .threading: return 205
        case .compressed: return 190
        case .resurfacing: return 210
        case .recovering: return 0
        case .diving: return 4
        case .underwater: return 210
        case .loaded, .standing: return 0
        case .flying:
            switch flightMotion {
            case .rising: return phase * 34
            case .level: return phase * 14
            case .falling: return -7
            }
        }
    }

    private func frontArmAngle(phase: Double) -> Double {
        switch pose {
        // The near wing points backward in the source artwork, so neutral is
        // the tucked launch direction and +140 degrees reaches forward.
        case .launching: return -4
        case .threading: return -8
        case .compressed: return 8
        case .resurfacing: return -4
        case .recovering: return 0
        case .diving: return 140
        case .underwater: return -4
        case .loaded, .standing: return 0
        case .flying:
            switch flightMotion {
            case .rising: return -phase * 38
            case .level: return -phase * 16
            case .falling: return 8
            }
        }
    }
}

enum CannonLaunchLayer: Equatable { case base, barrelForeground }

/// Normalized coordinates keep the fuse, flame, floe, and muzzle flash tied to
/// the cannon artwork even when its source texture is resized. The foreground
/// pass has a real opening cut from its mask, keeping the penguin behind the
/// barrel until it crosses the muzzle.
struct CannonLaunchScene: View {
    let stage: Int
    let reduceMotion: Bool
    let layer: CannonLaunchLayer
    /// Offscreen promo rendering can drive the production fuse at an exact
    /// point in its 1.45-second burn. Normal gameplay leaves this nil.
    var deterministicFuseProgress: CGFloat? = nil
    @State private var burnProgress: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let fuseProgress = min(0.58, max(0, deterministicFuseProgress ?? burnProgress))
            ZStack {
                if layer == .base {
                    cannonArtwork(width: width, height: height)

                    CannonFusePath()
                        .trim(from: fuseProgress, to: 0.58)
                        .stroke(Color(red: 0.22, green: 0.10, blue: 0.035),
                                style: StrokeStyle(lineWidth: width * 0.026, lineCap: .round))

                    if stage < 2 {
                        FuseFlame(reduceMotion: reduceMotion)
                            .frame(width: width * 0.13, height: width * 0.16)
                            .scaleEffect(max(0.38, 1 - fuseProgress * 0.72))
                            .position(fusePoint(progress: fuseProgress, in: proxy.size))
                    }

                    if stage == 2 {
                        MuzzleFlash()
                            .frame(width: width * 0.29, height: width * 0.29)
                            .position(x: width * 0.88, y: height * 0.29)
                            .transition(.scale.combined(with: .opacity))
                    }
                } else {
                    cannonArtwork(width: width, height: height)
                        .mask(CannonBarrelMask().fill(.white,
                                                     style: FillStyle(eoFill: true)))
                }
            }
        }
        .onAppear {
            if deterministicFuseProgress == nil {
                burnProgress = 0
                withAnimation(.linear(duration: reduceMotion ? 0.12 : 1.45)) {
                    burnProgress = 0.58
                }
            }
        }
    }

    private func cannonArtwork(width: CGFloat, height: CGFloat) -> some View {
        Image("canon")
            .resizable()
            .aspectRatio(3.0 / 2.0, contentMode: .fit)
            .frame(width: width, height: height)
            .overlay {
                CannonFusePath()
                    .trim(from: 0, to: 0.60)
                    .stroke(.black,
                            style: StrokeStyle(lineWidth: width * 0.046,
                                               lineCap: .round))
                    .blendMode(.destinationOut)
                    .frame(width: width, height: height)
            }
            .compositingGroup()
            .scaleEffect(x: cannonScaleX, y: cannonScaleY, anchor: .bottomLeading)
    }

    private var cannonScaleX: CGFloat {
        if stage == 1 { return 0.86 }
        if stage == 2 { return 1.055 }
        return 1
    }

    private var cannonScaleY: CGFloat {
        if stage == 1 { return 1.06 }
        if stage == 2 { return 0.97 }
        return 1
    }

    private func fusePoint(progress: CGFloat, in size: CGSize) -> CGPoint {
        let start = CGPoint(x: size.width * 0.205, y: size.height * 0.255)
        let control = CGPoint(x: size.width * 0.225, y: size.height * 0.38)
        let end = CGPoint(x: size.width * 0.342, y: size.height * 0.375)
        let inverse = 1 - progress
        return CGPoint(x: inverse * inverse * start.x + 2 * inverse * progress * control.x + progress * progress * end.x,
                       y: inverse * inverse * start.y + 2 * inverse * progress * control.y + progress * progress * end.y)
    }
}

private struct CannonBarrelMask: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.addRect(CGRect(x: rect.width * 0.58,
                                y: rect.minY,
                                width: rect.width * 0.42,
                                height: rect.height))
            path.addEllipse(in: CGRect(x: rect.width * 0.755,
                                       y: rect.height * 0.165,
                                       width: rect.width * 0.145,
                                       height: rect.height * 0.25))
        }
    }
}

private struct CannonFusePath: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.width * 0.205, y: rect.height * 0.255))
            path.addQuadCurve(to: CGPoint(x: rect.width * 0.342, y: rect.height * 0.375),
                              control: CGPoint(x: rect.width * 0.225, y: rect.height * 0.38))
        }
    }
}

private struct FuseFlame: View {
    let reduceMotion: Bool
    @State private var flickers = false

    var body: some View {
        ZStack {
            Image(systemName: "flame.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.red)
                .shadow(color: .orange, radius: 9)
            Image(systemName: "flame.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.yellow)
                .scaleEffect(0.62)
                .offset(y: 4)
            Circle()
                .fill(.white.opacity(0.92))
                .frame(width: 9, height: 9)
                .offset(y: 8)
        }
        .rotationEffect(.degrees(flickers ? 8 : -8))
        .scaleEffect(x: flickers ? 0.88 : 1.08, y: flickers ? 1.12 : 0.92)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.11).repeatForever(autoreverses: true),
                   value: flickers)
        .onAppear { flickers = true }
    }
}

private struct MuzzleFlash: View {
    var body: some View {
        ZStack {
            ForEach(0..<8, id: \.self) { index in
                Capsule()
                    .fill(index.isMultiple(of: 2) ? Color.yellow : Color.orange)
                    .frame(width: 10, height: 54)
                    .offset(y: -25)
                    .rotationEffect(.degrees(Double(index) * 45))
            }
            Circle().fill(.white).padding(18)
            Circle().stroke(.yellow.opacity(0.8), lineWidth: 8).padding(7)
        }
        .shadow(color: .orange, radius: 12)
    }
}

/// A small world-space reference that makes the camera follow readable. It
/// starts beside the cannon, floats on the surface, and leaves frame together
/// with the launch platform while the penguin settles at screen centre.
private struct FloatingStartMarker: View {
    let size: CGFloat
    let reduceMotion: Bool

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let phase = reduceMotion ? 0
                : sin(context.date.timeIntervalSinceReferenceDate * .pi * 1.7)
            ZStack(alignment: .bottom) {
                Ellipse()
                    .fill(LinearGradient(colors: [.white,
                                                  Color(red: 0.56, green: 0.88, blue: 0.97)],
                                         startPoint: .top,
                                         endPoint: .bottom))
                    .overlay(Ellipse().stroke(.white.opacity(0.95), lineWidth: 2))
                    .frame(width: size, height: size * 0.30)
                    .shadow(color: .blue.opacity(0.25), radius: 4, y: 3)

                RoundedRectangle(cornerRadius: size * 0.025)
                    .fill(LinearGradient(colors: [.white, Color(red: 0.72, green: 0.84, blue: 0.91)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: size * 0.09, height: size * 1.12)
                    .offset(y: -size * 0.12)

                Image(systemName: "flag.checkered")
                    .resizable()
                    .scaledToFit()
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color(red: 0.04, green: 0.24, blue: 0.52))
                    .frame(width: size * 0.58, height: size * 0.48)
                    .offset(x: size * 0.27, y: -size * 0.72)

                Circle()
                    .fill(.yellow)
                    .overlay(Circle().stroke(.orange, lineWidth: 2))
                    .frame(width: size * 0.17, height: size * 0.17)
                    .offset(y: -size * 1.13)
            }
            .frame(width: size * 1.35, height: size * 1.55)
            .rotationEffect(.degrees(phase * 2.2), anchor: .bottom)
            .offset(y: phase * size * 0.025)
        }
        .frame(width: size * 1.35, height: size * 1.55)
    }
}

/// World-space deadline for the optional 2× approach. Tap while this buoy is
/// still to the right of the penguin to earn the accelerated golden attempt.
private struct TurboTimingBuoy: View {
    let isAvailable: Bool

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            ZStack(alignment: .bottom) {
                Ellipse()
                    .fill(isAvailable ? Color.yellow : Color.white.opacity(0.55))
                    .overlay(Ellipse().stroke(.white.opacity(0.95), lineWidth: 2))
                    .frame(width: width, height: height * 0.30)

                Capsule()
                    .fill(isAvailable ? Color.orange : Color.gray.opacity(0.65))
                    .frame(width: width * 0.10, height: height * 0.78)
                    .offset(y: -height * 0.10)

                Image(systemName: "bolt.fill")
                    .font(.system(size: width * 0.35, weight: .black))
                    .foregroundStyle(isAvailable ? .yellow : .white.opacity(0.7))
                    .padding(width * 0.10)
                    .background(isAvailable ? Color.orange : Color.gray, in: Circle())
                    .offset(x: width * 0.28, y: -height * 0.47)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct TurboSpeedWake: View {
    let size: CGFloat
    let phase: Double

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            ZStack {
                // Soft, filled wind ribbons taper into the slipstream. Their
                // translucent area reads as moving air rather than speed bars.
                ForEach(0..<2, id: \.self) { index in
                    let lane = CGFloat(index)
                    Path { path in
                        let centreY = height * (0.35 + lane * 0.30)
                        let thickness = height * (index == 0 ? 0.14 : 0.11)
                        let tailY = centreY + (lane == 0 ? -height * 0.12 : height * 0.10)
                        path.move(to: CGPoint(x: width * 0.98, y: centreY - thickness * 0.30))
                        path.addCurve(
                            to: CGPoint(x: width * (0.04 + lane * 0.06), y: tailY),
                            control1: CGPoint(x: width * 0.70, y: centreY - thickness),
                            control2: CGPoint(x: width * 0.30, y: tailY - thickness * 0.55)
                        )
                        path.addCurve(
                            to: CGPoint(x: width * 0.98, y: centreY + thickness * 0.30),
                            control1: CGPoint(x: width * 0.32, y: tailY + thickness * 0.40),
                            control2: CGPoint(x: width * 0.72, y: centreY + thickness)
                        )
                        path.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [
                        Color.white.opacity(0.04),
                        Color.cyan.opacity(0.18),
                        Color.mint.opacity(index == 0 ? 0.44 : 0.30),
                        Color.white.opacity(0.58)
                    ], startPoint: .leading, endPoint: .trailing))
                }

                // Larger sparkles replace the tiny pressure droplets. They use
                // the playfield clock, so turbo adds no timer or blur pass.
                ForEach(0..<5, id: \.self) { index in
                    let travel = CGFloat((phase * (0.60 + Double(index) * 0.055)
                                          + Double(index) * 0.19)
                        .truncatingRemainder(dividingBy: 1))
                    let sparkleSize = max(7, size * (0.058 + CGFloat(index % 3) * 0.014))
                    let sparkleX = width * (0.90 - travel * 0.82)
                    let wave = sin(CGFloat(phase * 4.2) + CGFloat(index) * 1.7) * height * 0.055
                    let sparkleY = height * (0.22 + CGFloat(index) * 0.145) + wave
                    let sparkleOpacity = Double(1 - travel) * 0.72 + 0.22
                    Image(systemName: index.isMultiple(of: 2) ? "sparkle" : "star.fill")
                        .font(.system(size: sparkleSize, weight: .bold))
                        .foregroundStyle(index == 1 ? Color.yellow.opacity(0.92)
                                                    : Color.white.opacity(0.90))
                        .rotationEffect(.degrees(Double(index * 29) + phase * 42))
                        .scaleEffect(0.82 + 0.18 * sin(CGFloat(phase * 6) + CGFloat(index)))
                        .position(x: sparkleX, y: sparkleY)
                        .opacity(sparkleOpacity)
                }
            }
        }
        .frame(width: size * 1.55, height: size * 0.82)
        .allowsHitTesting(false)
    }
}

/// One splash, alive only for as long as it plays. Handing the renderer a list
/// of events rather than a pair of booleans is what guarantees a dive always
/// gets its splash: nothing later in the dive can clear a flag it needs.
private struct SplashEvent: Identifiable {
    let id = UUID()
    let direction: WaterSplashDirection
    /// 0…1, from the height the dive started at.
    let strength: CGFloat
    let x: CGFloat
}

private struct SolvedAnswerEcho: Identifiable {
    let id = UUID()
    let prompt: String
}

/// The rescue heart standing in the gap between two sets. It carries its own
/// position rather than an offset from a set, so the next set arriving cannot
/// drag it along with it.
private struct LifeHeartPickup: Identifiable {
    let id = UUID()
    let lane: Int
    var x: CGFloat
}

/// A life waiting in the flight path. Deliberately the very same heart the
/// lives meter is drawn with — the character's deep colour behind a soft white
/// outline — so what it gives back needs no explaining.
private struct LifeHeartView: View {
    let size: CGFloat
    let tint: Color
    let reduceMotion: Bool

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let phase = reduceMotion ? 0
                : sin(context.date.timeIntervalSinceReferenceDate * .pi * 2.4)
            LifeHeartGlyph(size: size, tint: tint)
                .scaleEffect(1 + phase * 0.08)
                .shadow(color: .black.opacity(0.20), radius: 5, y: 3)
        }
        .frame(width: size, height: size)
    }
}

/// A compact loss marker pinned to the right rim of each wrong tutorial hoop.
private struct BrokenHeartHoopMarker: View {
    let size: CGFloat
    let tint: Color
    let reduceMotion: Bool

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let pulse = reduceMotion ? CGFloat.zero
                : CGFloat(sin(context.date.timeIntervalSinceReferenceDate * .pi * 2.2))
            ZStack {
                Circle()
                    .fill(.white.opacity(0.96))
                    .overlay(Circle().stroke(tint.opacity(0.30), lineWidth: 1.5))

                Image(systemName: "heart.slash.fill")
                    .font(.system(size: size * 0.63, weight: .black))
                    .foregroundStyle(tint)
            }
            .scaleEffect(1 + pulse * 0.055)
            .shadow(color: .black.opacity(0.20), radius: 3, y: 2)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

/// A light touch trace gliding along a narrow rail. The moving contact point is
/// the gesture; small open chevrons show its range without turning the hint into
/// another piece of game UI.
private struct TutorialVerticalDragHint: View {
    let size: CGFloat
    let tint: Color
    let reduceMotion: Bool

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let clock = context.date.timeIntervalSinceReferenceDate
            let travel = reduceMotion ? CGFloat.zero : CGFloat(sin(clock * 2.15))
            GeometryReader { proxy in
                let centreX = proxy.size.width * 0.5
                let topY = proxy.size.height * 0.14
                let bottomY = proxy.size.height * 0.86
                let touchY = proxy.size.height * 0.5 + travel * proxy.size.height * 0.27
                let ripple = reduceMotion ? CGFloat(0.55)
                    : CGFloat((clock * 0.82).truncatingRemainder(dividingBy: 1))

                ZStack {
                    Path { path in
                        path.move(to: CGPoint(x: centreX, y: topY))
                        path.addLine(to: CGPoint(x: centreX, y: bottomY))
                    }
                    .stroke(.white.opacity(0.72),
                            style: StrokeStyle(lineWidth: max(4, size * 0.040),
                                               lineCap: .round))

                    Capsule()
                        .fill(tint.opacity(0.34))
                        .frame(width: max(2, size * 0.018),
                               height: bottomY - topY)
                        .position(x: centreX, y: (topY + bottomY) * 0.5)

                    directionMark("chevron.up", at: CGPoint(x: centreX, y: topY))
                    directionMark("chevron.down", at: CGPoint(x: centreX, y: bottomY))

                    Circle()
                        .stroke(tint.opacity(Double(1 - ripple) * 0.34),
                                lineWidth: max(1.5, size * 0.014))
                        .frame(width: size * (0.20 + ripple * 0.18),
                               height: size * (0.20 + ripple * 0.18))
                        .position(x: centreX, y: touchY)

                    Circle()
                        .fill(.white.opacity(0.94))
                        .frame(width: size * 0.18, height: size * 0.18)
                        .overlay(Circle().stroke(tint.opacity(0.70), lineWidth: 2))
                        .overlay(Circle().fill(tint).frame(width: size * 0.055,
                                                          height: size * 0.055))
                        .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                        .position(x: centreX, y: touchY)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func directionMark(_ symbol: String, at point: CGPoint) -> some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.13, weight: .bold))
            .foregroundStyle(tint.opacity(0.78))
            .shadow(color: .white.opacity(0.95), radius: 1.5)
            .position(point)
    }
}

/// Two fingerprint-like touch points alternate above and below the penguin.
/// Their broken outer ring and little tapping finger make each point read as a
/// place on the playfield to touch, rather than as another game button.
private struct TutorialHeightTapHint: View {
    let penguin: CGPoint
    let flightMaxY: CGFloat
    let size: CGFloat
    let tint: Color
    let reduceMotion: Bool

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let clock = context.date.timeIntervalSinceReferenceDate
            // The targets must remain geometrically above and below even when
            // the penguin itself has reached an edge of the normal flight band.
            // A tap outside that band still counts, then clamps movement safely.
            let upperY = max(size * 0.24, penguin.y - size * 1.44)
            let lowerY = min(flightMaxY + size * 0.46, penguin.y + size * 1.44)
            let spin = reduceMotion ? CGFloat.zero
                : CGFloat((clock * 0.12).truncatingRemainder(dividingBy: 1))
            ZStack {
                tapTarget(phase: pulse(clock, offset: 0),
                          spin: spin,
                          point: CGPoint(x: penguin.x, y: upperY))
                tapTarget(phase: pulse(clock, offset: .pi),
                          spin: -spin,
                          point: CGPoint(x: penguin.x, y: lowerY))
            }
        }
        .accessibilityHidden(true)
    }

    private func pulse(_ clock: Double, offset: Double) -> CGFloat {
        guard !reduceMotion else { return 0.55 }
        return CGFloat((sin(clock * 2.8 + offset) + 1) * 0.5)
    }

    private func tapTarget(phase: CGFloat,
                           spin: CGFloat,
                           point: CGPoint) -> some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.88),
                        style: StrokeStyle(lineWidth: max(5, size * 0.050),
                                           lineCap: .butt,
                                           dash: [size * 0.105, size * 0.070]))
                .frame(width: size * (0.50 + phase * 0.055),
                       height: size * (0.50 + phase * 0.055))
                .rotationEffect(.degrees(Double(spin) * 360))

            Circle()
                .stroke(tint.opacity(0.88),
                        style: StrokeStyle(lineWidth: max(3, size * 0.030),
                                           lineCap: .butt,
                                           dash: [size * 0.105, size * 0.070]))
                .frame(width: size * (0.50 + phase * 0.055),
                       height: size * (0.50 + phase * 0.055))
                .rotationEffect(.degrees(Double(spin) * 360))

            Circle()
                .stroke(.white.opacity(0.90), lineWidth: max(5, size * 0.050))
                .frame(width: size * 0.36, height: size * 0.36)

            Circle()
                .stroke(tint.opacity(0.92), lineWidth: max(3, size * 0.030))
                .frame(width: size * 0.36, height: size * 0.36)

            Circle()
                .fill(.white.opacity(0.96))
                .frame(width: size * 0.23, height: size * 0.23)
                .overlay(Circle().stroke(tint.opacity(0.88),
                                         lineWidth: max(3, size * 0.026)))

            Circle()
                .fill(tint.opacity(0.92))
                .frame(width: size * 0.085, height: size * 0.085)

            Image(systemName: "hand.tap.fill")
                .font(.system(size: size * 0.20, weight: .black))
                .foregroundStyle(tint)
                .padding(size * 0.045)
                .background(.white.opacity(0.97), in: Circle())
                .overlay(Circle().stroke(tint.opacity(0.20), lineWidth: 1))
                .shadow(color: .black.opacity(0.18), radius: 3, y: 2)
                .offset(x: size * 0.25,
                        y: size * (0.18 - phase * 0.035))
        }
        .shadow(color: .black.opacity(0.10), radius: 2, y: 1)
        .opacity(0.70 + Double(phase) * 0.30)
        .position(point)
    }
}

/// A dashed route leaves the penguin and curves beneath the hoop stack. The
/// down arrow stays directly below the character; nothing instructional is
/// parked underwater where contrast is poor.
private struct TutorialDivePathHint: View {
    let penguin: CGPoint
    let start: CGPoint
    let end: CGPoint
    let size: CGFloat
    let tint: Color
    let reduceMotion: Bool

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let clock = context.date.timeIntervalSinceReferenceDate
            let cycle = reduceMotion ? CGFloat(0.45)
                : CGFloat((clock * 0.75).truncatingRemainder(dividingBy: 1))
            let control1 = CGPoint(x: start.x + size * 0.62,
                                   y: start.y + size * 0.20)
            let control2 = CGPoint(x: end.x - size * 0.72,
                                   y: end.y - size * 0.20)

            ZStack {
                divePath(control1: control1, control2: control2)
                    .stroke(.white.opacity(0.94),
                            style: StrokeStyle(lineWidth: max(8, size * 0.080),
                                               lineCap: .round))

                divePath(control1: control1, control2: control2)
                    .stroke(tint.opacity(0.90),
                            style: StrokeStyle(lineWidth: max(3, size * 0.035),
                                               lineCap: .round,
                                               dash: [size * 0.12, size * 0.09],
                                               dashPhase: -cycle * size * 0.42))

                Image(systemName: "arrow.down")
                    .font(.system(size: size * 0.28, weight: .black))
                    .foregroundStyle(tint)
                    .padding(size * 0.055)
                    .background(.white.opacity(0.96), in: Circle())
                    .overlay(Circle().stroke(tint.opacity(0.28), lineWidth: 2))
                    .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
                    .offset(y: reduceMotion ? 0 : cycle * size * 0.10)
                    .position(x: penguin.x,
                              y: penguin.y + size * 0.66)

            }
        }
        .accessibilityHidden(true)
    }

    private func divePath(control1: CGPoint, control2: CGPoint) -> Path {
        Path { path in
            path.move(to: start)
            path.addCurve(to: end, control1: control1, control2: control2)
        }
    }
}

/// Asks for a tap, on the one hoop the turbo lesson is about. Rings leave the
/// rim while a hand stands off to the right, pointing back at it — off to the
/// side deliberately, because a hand in the middle of the hoop covers the one
/// thing the player has to read: the answer.
private struct TutorialTapPulse: View {
    let size: CGFloat
    let tint: Color
    let reduceMotion: Bool

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let clock = context.date.timeIntervalSinceReferenceDate
            let nudge = reduceMotion ? 0 : CGFloat(sin(clock * .pi * 2.4))
            ZStack {
                ForEach(0..<2, id: \.self) { index in
                    let progress = reduceMotion ? 0.45
                        : CGFloat((clock * 0.9 + Double(index) * 0.5)
                            .truncatingRemainder(dividingBy: 1))
                    Circle()
                        .stroke(tint.opacity(Double(1 - progress) * 0.75),
                                lineWidth: size * 0.07)
                        .scaleEffect(0.42 + progress * 0.72)
                }

                // The hand taps toward the rim: it sits just outside the hoop's
                // right edge and leans into it, so the eye is led from the hand
                // to the ring rather than away from it.
                Image(systemName: "hand.point.left.fill")
                    .font(.system(size: size * 0.34, weight: .black))
                    .foregroundStyle(tint)
                    .padding(size * 0.09)
                    .background(.white.opacity(0.94), in: Circle())
                    .shadow(color: .black.opacity(0.18), radius: 3, y: 2)
                    .offset(x: size * (0.66 - 0.05 * nudge))
            }
            .frame(width: size, height: size)
        }
        .frame(width: size, height: size)
    }
}

private struct RetiringHoopSet: Identifiable {
    let id = UUID()
    let options: [AnswerOption]
    let prompt: String
    var x: CGFloat
    let feedbacks: [UUID: HoopFeedback]

    func feedback(for optionID: UUID) -> HoopFeedback {
        feedbacks[optionID] ?? .none
    }
}

enum HoopFeedback: Equatable {
    case none, inactive, correct, revealedCorrect, wrong, bonus, bypassed
}

struct MovingQuestionBadge: View {
    let prompt: String
    let character: AnimalCharacter
    let isPad: Bool

    var body: some View {
        Text(prompt)
            .font(.system(size: isPad ? 36 : 23, weight: .black, design: .rounded))
            .foregroundStyle(character.deepColor)
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .padding(.horizontal, isPad ? 25 : 17)
            .padding(.vertical, isPad ? 11 : 8)
            .background(.white.opacity(0.95), in: Capsule())
            .overlay(Capsule().stroke(character.color.opacity(0.42), lineWidth: 2))
            .shadow(color: .black.opacity(0.10), radius: 4, y: 2)
    }
}

private struct SolvedAnswerEchoView: View {
    let prompt: String
    let character: AnimalCharacter
    let isPad: Bool

    var body: some View {
        Text(prompt)
            .font(.system(size: isPad ? 25 : 18, weight: .black, design: .rounded))
            .foregroundStyle(character.deepColor)
            .lineLimit(1)
            .minimumScaleFactor(0.62)
            .padding(.horizontal, isPad ? 17 : 13)
            .padding(.vertical, isPad ? 8 : 6)
            .background(.white.opacity(0.90), in: Capsule())
            .overlay(Capsule().stroke(character.color.opacity(0.38), lineWidth: 1.5))
            .shadow(color: .black.opacity(0.08), radius: 3, y: 2)
    }
}

/// Physical arcade answer button — same layered housing / cap / lip press as
/// the Nuts & Numbers grab control, with the answer number centred on the face
/// instead of a word.
struct AnswerHoop: View {
    let text: String
    let tint: Color
    let size: CGFloat
    let textScale: CGFloat
    let feedback: HoopFeedback
    var isPressed: Bool = false
    /// Rotates the physical housing to match the panel it is mounted on. The
    /// label is counter-rotated below so answer values always stay upright.
    var orientationDegrees: Double = 0

    private enum Art {
        static let canvas: CGFloat = 1254
        /// Cap travel into the housing, in canvas pixels.
        static let pressTravel: CGFloat = 88
        /// Optical centre of the red top face on the perspective canvas. Matches
        /// the Nuts & Numbers grab label seam so a digit reads as sitting in
        /// the middle of the button, not low in the housing.
        static let labelCenterY: CGFloat = 470 / 1254
    }

    private var travel: CGFloat { size * (Art.pressTravel / Art.canvas) }
    private var faceOffset: CGFloat { size * (Art.labelCenterY - 0.5) }

    private var feedbackTint: Color? {
        switch feedback {
        case .correct, .revealedCorrect, .bonus:
            return Color(red: 0.12, green: 0.78, blue: 0.36)
        case .wrong:
            return Color(red: 0.96, green: 0.22, blue: 0.30)
        case .bypassed:
            return Color.cyan.opacity(0.85)
        case .none, .inactive:
            return nil
        }
    }

    var body: some View {
        let accent = feedbackTint ?? tint
        ZStack {
            ZStack {
                Image("button3")
                    .resizable()
                    .interpolation(.high)
                Image("button3")
                    .renderingMode(.template)
                    .resizable()
                    .interpolation(.high)
                    .foregroundStyle(accent.opacity(feedback == .inactive ? 0.18 : 0.38))
                    .blendMode(.color)
            }
            .compositingGroup()
            .opacity(feedback == .inactive ? 0.55 : 1)
            .shadow(color: accent.opacity(0.34), radius: size * 0.06)

            ZStack {
                Image("button2")
                    .resizable()
                    .interpolation(.high)
                if let feedbackTint {
                    Image("button2")
                        .renderingMode(.template)
                        .resizable()
                        .interpolation(.high)
                        .foregroundStyle(feedbackTint.opacity(0.55))
                        .blendMode(.color)
                }
                Text(text)
                    .font(.system(size: size * 0.28 * textScale,
                                  weight: .black,
                                  design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.45), radius: 1, y: 1)
                    .lineLimit(1)
                    .minimumScaleFactor(0.32)
                    .allowsTightening(true)
                    .multilineTextAlignment(.center)
                    .frame(width: size * 0.56, height: size * 0.34, alignment: .center)
                    // Sit on the red top-face centre (perspective art), not the
                    // square canvas mid-point — that mid-point reads too low.
                    .offset(y: faceOffset)
                    .rotationEffect(.degrees(-orientationDegrees))
                if feedback == .bonus {
                    BonusStarBurst(size: size * 0.85)
                        .offset(y: faceOffset)
                        .rotationEffect(.degrees(-orientationDegrees))
                }
            }
            .offset(y: isPressed ? travel : 0)

            ZStack {
                Image("button1")
                    .resizable()
                    .interpolation(.high)
                Image("button1")
                    .renderingMode(.template)
                    .resizable()
                    .interpolation(.high)
                    .foregroundStyle(accent.opacity(feedback == .inactive ? 0.14 : 0.30))
                    .blendMode(.color)
            }
            .compositingGroup()
            .opacity(feedback == .inactive ? 0.55 : 1)
        }
        .frame(width: size, height: size)
        .rotationEffect(.degrees(orientationDegrees))
        .contentShape(Circle())
        .animation(isPressed ? .easeIn(duration: 0.08) : .easeOut(duration: 0.24),
                   value: isPressed)
        .animation(.easeInOut(duration: 0.28), value: feedback)
    }
}

/// The turbo reward stays green like a normal correct answer, then adds one
/// small outward star pop so the bonus is unmistakable without a gold rim.
private struct BonusStarBurst: View {
    let size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress: CGFloat = 0

    var body: some View {
        ZStack {
            ForEach(0..<8, id: \.self) { index in
                let angle = Double(index) * 45 - 90
                Image(systemName: index.isMultiple(of: 2) ? "star.fill" : "sparkle")
                    .font(.system(size: size * (index.isMultiple(of: 2) ? 0.105 : 0.085),
                                  weight: .bold))
                    .foregroundStyle(index.isMultiple(of: 3) ? Color.yellow : Color.white)
                    .shadow(color: Color.green.opacity(0.30), radius: 2)
                    .offset(y: -size * (0.38 + progress * 0.22))
                    .rotationEffect(.degrees(angle))
                    .opacity(Double(1 - progress * 0.82))
                    .scaleEffect(0.62 + progress * 0.46)
            }
        }
        .onAppear {
            progress = reduceMotion ? 0.55 : 0
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 0.48)) { progress = 1 }
        }
        .allowsHitTesting(false)
    }
}
