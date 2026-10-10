import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Decorative motion should never compete with input or the character flight.
/// These cadences are deliberately below display refresh rate; all motion is
/// slow enough to remain fluid while doing substantially less drawing work.
private enum SpaceAnimationBudget {
    static var isConstrained: Bool {
        let process = ProcessInfo.processInfo
        if process.isLowPowerModeEnabled { return true }
        switch process.thermalState {
        case .serious, .critical: return true
        default: return false
        }
    }

    // The lion is the focal moving object, not ambient decoration. Thirty
    // updates per second keeps its slow post-flip settle and weightless drift
    // visually continuous; constrained devices still get a stable 20 fps.
    static var characterInterval: TimeInterval { isConstrained ? 1.0 / 20.0 : 1.0 / 30.0 }
    static var sceneryInterval: TimeInterval { isConstrained ? 1.0 / 5.0 : 1.0 / 8.0 }
    static var glassInterval: TimeInterval { isConstrained ? 1.0 / 3.0 : 1.0 / 6.0 }
    /// The boundary LEDs are only a few dashed strokes, so they can update
    /// smoothly without forcing the much heavier space scenery to do the same.
    // Unlike the slow scenery, a dashed line translating along a hard edge
    // exposes every skipped sample. Keep this cheap, isolated layer at display-
    // smooth cadence; constrained devices still receive a stable 30 fps rather
    // than the visibly stepping 20 fps used previously.
    static var ledInterval: TimeInterval { isConstrained ? 1.0 / 30.0 : 1.0 / 60.0 }
}

private enum LionMotionPhase: Equatable {
    case idle
    case travellingOut
    case contact
    case retractingFinger
    case pushingOff
    case travellingHome
    case settling
}

/// Semantic names for one character's eight-frame sheet. Frame 4 is supplied
/// but unused: it is nearly the pointing pose and carries a detached edge.
/// The lion's frames live in the original `1.1`…`1.8` imagesets; every other
/// animal uses `{name}_01`…`{name}_08` with the same indices.
private enum LionPose: CaseIterable {
    case resting
    case tucked
    case reaching
    case pointing
    case recoveringEarly
    case recoveringMiddle
    case recoveringLate

    var frame: Int {
        switch self {
        case .resting: return 1
        case .tucked: return 2
        case .reaching: return 3
        case .pointing: return 5
        case .recoveringEarly: return 6
        case .recoveringMiddle: return 7
        case .recoveringLate: return 8
        }
    }
}

#if canImport(UIKit)
/// Asset-catalog images are compressed until their first real draw. Preparing
/// every gameplay pose while the menu is idle prevents the first answer from
/// paying a PNG decode in the middle of the lion's flight. The lock only guards
/// a tiny dictionary swap/read; decoding stays entirely on a background queue.
private final class LionPoseImageCache: @unchecked Sendable {
    static let shared = LionPoseImageCache()

    private let lock = NSLock()
    private var images: [String: UIImage] = [:]
    private var requested: Set<String> = []

    func prepare(names: [String]) {
        lock.lock()
        let missing = names.filter { !requested.contains($0) }
        missing.forEach { requested.insert($0) }
        lock.unlock()
        guard !missing.isEmpty else { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var prepared: [String: UIImage] = [:]
            for name in missing {
                autoreleasepool {
                    guard let source = UIImage(named: name) else { return }
                    let format = UIGraphicsImageRendererFormat()
                    format.scale = source.scale
                    format.opaque = false
                    // Rendering at the source size forces decompression now;
                    // later SwiftUI draws only scale an already-backed bitmap.
                    let renderer = UIGraphicsImageRenderer(size: source.size, format: format)
                    prepared[name] = renderer.image { _ in
                        source.draw(in: CGRect(origin: .zero, size: source.size))
                    }
                }
            }
            guard let self else { return }
            self.lock.lock()
            self.images.merge(prepared) { _, new in new }
            self.lock.unlock()
        }
    }

    func image(named name: String) -> UIImage? {
        lock.lock()
        defer { lock.unlock() }
        return images[name]
    }
}
#endif

private struct SpaceAnswerBurstState: Identifiable {
    let id = UUID()
    let point: CGPoint
    let isCorrect: Bool
}

/// Space Lion's complete in-game surface. It deliberately keeps the same
/// boundary as the Flying Penguin field so the surrounding start, pause,
/// result, score and navigation flows remain untouched.
struct SpaceLionPlayfield: View {
    let rounds: [GameRound]
    let character: AnimalCharacter
    let isPad: Bool
    let isLive: Bool
    let isRunning: Bool
    let playsFishEntrance: Bool
    let playsLevelCompletion: Bool
    let destinationStage: Int
    let isTravelling: Bool
    let journeyID: Int
    let reduceMotion: Bool
    let topReserve: CGFloat
    let bottomReserve: CGFloat
    let leftReserve: CGFloat
    let rightReserve: CGFloat
    var tutorial: TutorialPlan = TutorialPlan()
    var tutorialMessage: String? = nil
    var onTutorialEvent: (TutorialEvent) -> Void = { _ in }
    let onHit: (UUID, Bool, Bool) -> Bool
    let onSwallow: (Bool) -> Void
    let onDive: () -> Void
    let onFishEntranceComplete: () -> Void
    let onLevelCompletionFinished: () -> Void

    @State private var motionOffset = CGSize.zero
    @State private var completionOffset = CGSize.zero
    @State private var lionScale: CGFloat = 1
    @State private var lionOpacity = 1.0
    @State private var motionPhase: LionMotionPhase = .idle
    @State private var phaseStarted = Date()
    @State private var actionRotation = 0.0
    @State private var idleRotationOffset = 0.0
    /// Momentum left by a successful somersault. It starts at the flip's final
    /// angular speed, then fades into the normal weightless sway.
    @State private var spinCarryStarted: Date?
    @State private var spinCarryDistance = 0.0
    @State private var driftAmount: CGFloat = 1
    @State private var isMoving = false
    @State private var selectedOptionID: UUID?
    @State private var selectedWasCorrect = false
    @State private var buttonHasContact = false
    @State private var buttonImpactScale: CGFloat = 1
    @State private var feedbackBurst: SpaceAnswerBurstState?
    @State private var actionSequence = 0
    @State private var tutorialSequence = 0
    /// Extra spin layered on the travel pose. A correct answer makes the lion
    /// travel one and a quarter turns, deliberately ending away from upright.
    @State private var celebrationSpin = 0.0
    @State private var travelShakePhase: CGFloat = 0

    /// Called from the menu, before a level is presented, so every pose of the
    /// selected character is decompressed before the flight animation needs it.
    static func prewarmArtwork(for character: AnimalCharacter) {
#if canImport(UIKit)
        let names = LionPose.allCases.map { character.gameplayAsset(frame: $0.frame) }
        LionPoseImageCache.shared.prepare(names: names)
#endif
    }

    private func poseAssetName(_ pose: LionPose) -> String {
        character.gameplayAsset(frame: pose.frame)
    }

    private var round: GameRound? { rounds.first }

    var body: some View {
        GeometryReader { proxy in
            let metrics = Metrics(size: proxy.size,
                                  topReserve: topReserve,
                                  bottomReserve: bottomReserve,
                                  leftReserve: leftReserve,
                                  rightReserve: rightReserve,
                                  isPad: isPad)
            let cockpitFeedbacks = round.map {
                $0.options.prefix(GameConfig.answerBubbleCount).map(feedback(for:))
            } ?? []
            // Background motion stays on one uninterrupted clock. In
            // particular, answering must not freeze the upper and lower LED
            // strips or make their loop restart when the lion lands.
            let runsAmbientMotion = isRunning && !reduceMotion
            ZStack {
                SpaceshipCockpit(layout: metrics.cockpit,
                                 character: character,
                                 isPad: isPad,
                                 isRunning: runsAmbientMotion,
                                 destinationStage: destinationStage,
                                 feedbacks: cockpitFeedbacks)

                if isTravelling {
                    SpaceForwardJourney(window: metrics.cockpit.windowRect,
                                        stage: destinationStage,
                                        journeyID: journeyID,
                                        reduceMotion: reduceMotion)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }

                if let round {
                    let answers = Array(round.options.prefix(GameConfig.answerBubbleCount))
                    ForEach(Array(answers.enumerated()), id: \.element.id) { index, option in
                        answerButton(option,
                                     index: index,
                                     at: metrics.answerPoints[index],
                                     centre: metrics.centre,
                                     size: metrics.answerSize,
                                     lionSize: metrics.lionSize)
                    }
                }

                if let feedbackBurst {
                    SpaceAnswerBurst(burst: feedbackBurst,
                                     size: metrics.answerSize * 1.55,
                                     reduceMotion: reduceMotion)
                        .id(feedbackBurst.id)
                        .position(feedbackBurst.point)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }

                lion(metrics: metrics)

                if playsLevelCompletion {
                    VictoryBloom(size: metrics.cockpit.windowRect.width * 0.55,
                                 reduceMotion: reduceMotion)
                        .position(metrics.centre)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }

                SpaceViewportGlass(window: metrics.cockpit.windowRect,
                                   cut: min(metrics.cockpit.windowRect.width,
                                            metrics.cockpit.windowRect.height) * 0.11,
                                   isRunning: runsAmbientMotion)

                if let tutorialMessage, tutorial.isRunning {
                    Text(tutorialMessage)
                        .font(.system(size: isPad ? 22 : 15, weight: .bold, design: .rounded))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                        .padding(.horizontal, isPad ? 24 : 16)
                        .padding(.vertical, isPad ? 14 : 10)
                        .background(.black.opacity(0.68), in: Capsule())
                        .overlay(Capsule().stroke(.white.opacity(0.35), lineWidth: 1.5))
                        .frame(maxWidth: metrics.size.width * 0.54)
                        .position(x: metrics.centre.x,
                                  y: metrics.size.height * 0.79)
                        .allowsHitTesting(false)
                }
            }
            .modifier(SpaceShakeEffect(progress: travelShakePhase,
                                       distance: reduceMotion ? 0 : (isPad ? 3.5 : 2.2)))
            .clipped()
            .contentShape(Rectangle())
            .onAppear {
                if playsFishEntrance { beginEntrance(metrics: metrics) }
                progressTutorial(tutorial.step)
            }
            .onChange(of: playsFishEntrance) { _, value in
                if value { beginEntrance(metrics: metrics) }
            }
            .onChange(of: playsLevelCompletion) { _, value in
                if value { beginCompletion(width: metrics.size.width) }
            }
            .onChange(of: isTravelling) { _, value in
                if value {
                    withAnimation(.linear(duration: GameConfig.stageTravelDuration)) {
                        travelShakePhase += 5
                    }
                } else {
                    travelShakePhase = 0
                }
            }
            .onChange(of: tutorial.step) { _, step in
                progressTutorial(step)
            }
        }
        .ignoresSafeArea()
    }

    private func answerButton(_ option: AnswerOption,
                              index: Int,
                              at point: CGPoint,
                              centre: CGPoint,
                              size: CGFloat,
                              lionSize: CGFloat) -> some View {
        let isSelected = selectedOptionID == option.id
        let feedback = feedback(for: option)
        // Depress the arcade cap while the lion is pressing into it.
        let isPressed = isSelected && (buttonHasContact || buttonImpactScale < 0.98)
        return Button {
            select(option,
                   at: point,
                   from: centre,
                   lionSize: lionSize)
        } label: {
            SpaceConsoleButton(text: option.text,
                               size: size,
                               accentColor: character.color,
                               feedback: feedback,
                               isPressed: isPressed)
        }
        .buttonStyle(SpaceAnswerPressStyle())
        .hoverEffect(.highlight)
        .position(point)
        .disabled(!isLive || isMoving || tutorial.isRunning || playsLevelCompletion)
        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [])
        .accessibilityLabel(Text(verbatim: option.text))
        .accessibilityHint(Text(verbatim: "Answer \(index + 1)"))
        .accessibilityIdentifier("space-lion-answer-\(option.text)")
        .transition(.opacity.combined(with: .scale(scale: 0.88)))
    }

    private func feedback(for option: AnswerOption) -> HoopFeedback {
        guard selectedOptionID == option.id, buttonHasContact else { return .none }
        return selectedWasCorrect ? .correct : .wrong
    }

    private func lion(metrics: Metrics) -> some View {
        // The flight itself is interpolated by SwiftUI outside this timeline;
        // reading `motionOffset` here drops that interpolation. This clock only
        // swaps poses and supplies the subtle idle drift, so display-link speed
        // needlessly rebuilt the lion (with two shadows and a blur) sixty times
        // per second.
        TimelineView(.animation(minimumInterval: SpaceAnimationBudget.characterInterval,
                                paused: !isRunning || reduceMotion)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let driftX = reduceMotion
                ? 0
                : sin(time * 0.62) * metrics.lionSize * 0.075 * driftAmount
            let driftY = reduceMotion
                ? 0
                : cos(time * 0.78) * metrics.lionSize * 0.062 * driftAmount
            let rotation = (!isMoving || motionPhase == .settling)
                ? idleRotation(at: timeline.date)
                : actionRotation
            let pose = lionPose(at: timeline.date)
            // Fade breathing in with the drift during settling. Switching it
            // on only after `isMoving` became false caused a small scale pop.
            let breathe = reduceMotion
                ? 1
                : (1 + sin(time * 1.35) * 0.022 * driftAmount)

            ZStack {
                Ellipse()
                    .fill(RadialGradient(colors: [Color(red: 0.35, green: 0.75, blue: 1).opacity(0.38),
                                                  .clear],
                                         center: .center,
                                         startRadius: 0,
                                         endRadius: metrics.lionSize * 0.36))
                    .frame(width: metrics.lionSize * 0.78, height: metrics.lionSize * 0.30)
                    .blur(radius: metrics.lionSize * 0.035)
                    .offset(y: metrics.lionSize * 0.30)
                    .allowsHitTesting(false)

                // The old 84%-wide crop hid a tiny detached fragment in frame
                // 1.4, but also cut real boots and hands from the useful poses.
                // Frame 1.4 is now omitted from the sequence, so every active
                // pose can be rendered in full.
                lionImage(pose, size: metrics.lionSize)
                .frame(width: metrics.lionSize, height: metrics.lionSize)
                .offset(poseAnchor(for: pose, size: metrics.lionSize))
                .rotationEffect(.degrees(rotation))
                .scaleEffect(breathe)
            }
            .offset(x: driftX, y: driftY)
        }
        .frame(width: metrics.lionSize, height: metrics.lionSize)
        .rotationEffect(.degrees(celebrationSpin))
        .scaleEffect(lionScale)
        .opacity(lionOpacity)
        .offset(x: motionOffset.width + completionOffset.width,
                y: motionOffset.height + completionOffset.height)
        .shadow(color: Color(red: 0.25, green: 0.70, blue: 1).opacity(0.45), radius: 16)
        .shadow(color: .black.opacity(0.35), radius: 10, y: 8)
        .position(metrics.centre)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func lionImage(_ pose: LionPose, size: CGFloat) -> some View {
        let name = poseAssetName(pose)
#if canImport(UIKit)
        let image = LionPoseImageCache.shared.image(named: name)
            .map(Image.init(uiImage:)) ?? Image(name)
        image
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
#else
        Image(name)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
#endif
    }

    private func lionPose(at date: Date) -> LionPose {
        let elapsed = max(0, date.timeIntervalSince(phaseStarted))
        switch motionPhase {
        case .idle:
            return .resting
        case .travellingOut:
            // Hold one pose for the complete glide. Changing sprite alignment
            // halfway through was the small hitch visible on the old path.
            return .pointing
        case .contact:
            return .pointing
        case .retractingFinger:
            // Frame 1.4 is almost identical to the pointing pose and includes
            // a detached edge fragment. Going directly through 1.3 makes the
            // arm fold readable without spending a frame on visual noise.
            return elapsed < retractFingerDuration * 0.55 ? .reaching : .tucked
        case .pushingOff:
            return selectedWasCorrect ? .tucked : .pointing
        case .travellingHome:
            // A miss keeps pointing all the way back to the centre. Retraction
            // happens only after arrival, so neither side loses a pose in flight.
            return selectedWasCorrect ? .tucked : .pointing
        case .settling:
            if selectedWasCorrect {
                // These three supplied poses were previously unused. Together
                // they bridge the tucked flip silhouette back to the open idle
                // silhouette instead of making that entire change in one cut.
                if elapsed < settleDuration * 0.14 { return .tucked }
                if elapsed < settleDuration * 0.38 { return .recoveringEarly }
                if elapsed < settleDuration * 0.62 { return .recoveringMiddle }
                if elapsed < settleDuration * 0.84 { return .recoveringLate }
                return .resting
            }
            if elapsed < settleDuration * 0.42 { return .reaching }
            if elapsed < settleDuration * 0.72 { return .tucked }
            return .resting
        }
    }

    /// The supplied poses are not drawn on the same body centre. Nudging each
    /// one onto the pointing pose keeps the lion from stepping sideways every
    /// time the artwork changes. Frame 1.5 stays put: the fingertip reach is
    /// measured from that pose.
    private func poseAnchor(for pose: LionPose, size: CGFloat) -> CGSize {
        let fraction: (CGFloat, CGFloat)
        switch pose {
        case .resting: fraction = (0.063, -0.055)
        case .tucked: fraction = (0.101, -0.050)
        case .reaching: fraction = (0.146, -0.069)
        case .pointing: fraction = (0, 0)
        case .recoveringEarly: fraction = (-0.012, 0.001)
        case .recoveringMiddle: fraction = (0.039, -0.003)
        case .recoveringLate: fraction = (0.074, -0.007)
        }
        return CGSize(width: fraction.0 * size, height: fraction.1 * size)
    }

    private func select(_ option: AnswerOption,
                        at target: CGPoint,
                        from centre: CGPoint,
                        lionSize: CGFloat) {
        guard isLive, !isMoving, !tutorial.isRunning, let round,
              round.options.contains(where: { $0.id == option.id }) else { return }
        actionSequence &+= 1
        let token = actionSequence
        let now = Date()
        isMoving = true
        selectedOptionID = option.id
        selectedWasCorrect = option.isCorrect
        buttonHasContact = false
        buttonImpactScale = 1

        let dx = target.x - centre.x
        let dy = target.y - centre.y
        let distance = max(1, hypot(dx, dy))
        let unitX = dx / distance
        let unitY = dy / distance
        // Calibrated against the leading pixel of the index finger in frame
        // 1.5. The source is 512 x 543 and is aspect-fitted into a square, so
        // this is the fingertip's vector from the rendered frame centre.
        let fingerVector = CGSize(width: lionSize * 0.445,
                                  height: lionSize * -0.043)
        let fingerReach = hypot(fingerVector.width, fingerVector.height)
        // Put the fingertip on the button centre, rather than stopping one
        // button radius early and merely touching the near rim.
        let contactDestination = CGSize(width: dx - unitX * fingerReach,
                                        height: dy - unitY * fingerReach)

        // Turn the complete character toward the answer. A left-side answer
        // is reached through rotation, never by mirroring the artwork.
        let fingerAngle = atan2(fingerVector.height, fingerVector.width) * 180 / .pi
        let travelAngle = atan2(dy, dx) * 180 / .pi - fingerAngle
        let currentRotation = idleRotation(at: now)
        actionRotation = currentRotation
        // Freeze any previous residual spin into the action angle. Clearing the
        // carry after sampling it keeps the first action frame continuous.
        spinCarryStarted = nil
        spinCarryDistance = 0
        let outwardAngle = nearestEquivalent(of: travelAngle, to: currentRotation)

        beginOutwardTravel(option,
                           target: target,
                           contactDestination: contactDestination,
                           outwardAngle: outwardAngle,
                           token: token)
    }

    // Keep the response immediate, but leave enough time to read the turn,
    // fingertip contact and return poses. The actual outward and homeward
    // travel get extra room while the turn, button press and feedback stay
    // crisp, so input still feels immediate without the lion darting around.
    private var outwardDuration: Double { reduceMotion ? 0.10 : 0.75 }
    private var pressDuration: Double { reduceMotion ? 0.03 : 0.08 }
    private var retractFingerDuration: Double { reduceMotion ? 0.04 : 0.16 }
    private var pushOffDuration: Double { reduceMotion ? 0.05 : 0.13 }
    private var returnDuration: Double { reduceMotion ? 0.14 : 0.62 }
    private var settleDuration: Double {
        // At 30 fps this gives the correct-answer recovery eleven rendered
        // steps: enough for all five poses without slowing the next question.
        reduceMotion ? 0.05 : (selectedWasCorrect ? 0.36 : 0.34)
    }

    private func beginOutwardTravel(_ option: AnswerOption,
                                     target: CGPoint,
                                     contactDestination: CGSize,
                                     outwardAngle: Double,
                                     token: Int) {
        motionPhase = .travellingOut
        phaseStarted = Date()
        // Turning and travelling begin together, but most of the turn finishes
        // in the first half. The remaining flight then reads as a straight,
        // committed approach instead of one long curved sweep.
        withAnimation(.timingCurve(0.16, 0.00, 0.32, 1.00,
                                   duration: outwardDuration * 0.48)) {
            actionRotation = outwardAngle
            driftAmount = 0
        }
        withAnimation(.timingCurve(0.30, 0.00, 0.50, 1.00,
                                   duration: outwardDuration)) {
            motionOffset = contactDestination
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + outwardDuration) {
            guard actionSequence == token else { return }
            guard isLive, isRunning else {
                cancelAction(token: token)
                return
            }
            reachButton(option,
                        target: target,
                        token: token)
        }
    }

    private func reachButton(_ option: AnswerOption,
                             target: CGPoint,
                             token: Int) {
        motionPhase = .contact
        phaseStarted = Date()
        buttonHasContact = true
        AppAudio.shared.playButtonPress()
        let accepted = onHit(option.id, false, false)
        if accepted {
            onSwallow(option.isCorrect)
            let burst = SpaceAnswerBurstState(point: target, isCorrect: option.isCorrect)
            feedbackBurst = burst
            DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0.28 : 0.76)) {
                guard feedbackBurst?.id == burst.id else { return }
                feedbackBurst = nil
            }
            if !option.isCorrect, !reduceMotion {
                withAnimation(.spring(response: 0.22, dampingFraction: 0.46)) {
                    lionScale = 0.94
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
                    guard actionSequence == token else { return }
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.62)) {
                        lionScale = 1
                    }
                }
            }
        }

        // The glide already ended on the pressed fingertip. Only the button
        // cap moves here, so the lion's path is not retargeted mid-flight.
        withAnimation(.timingCurve(0.20, 0.00, 0.40, 1.00, duration: pressDuration)) {
            buttonImpactScale = 0.92
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + pressDuration) {
            guard actionSequence == token else { return }
            beginPushOff(token: token)
        }
    }

    private func beginPushOff(token: Int) {
        if selectedWasCorrect {
            motionPhase = .retractingFinger
            phaseStarted = Date()
            withAnimation(reduceMotion
                          ? .easeOut(duration: 0.06)
                          : .spring(response: 0.22, dampingFraction: 0.58)) {
                buttonImpactScale = 1
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + retractFingerDuration) {
                guard actionSequence == token else { return }
                beginReturnMotion(token: token, celebrates: !reduceMotion)
            }
            return
        }

        beginReturnMotion(token: token, celebrates: false)
    }

    private func beginReturnMotion(token: Int, celebrates: Bool) {
        motionPhase = .pushingOff
        phaseStarted = Date()
        let homeDuration = pushOffDuration + returnDuration
        // Keep rotating briefly after the positional return has finished. This
        // gives the flip room to decelerate naturally instead of squeezing its
        // final braking into the last few pixels of the return path.
        let spinDuration = reduceMotion ? homeDuration : homeDuration + 0.14
        // One continuous glide home. It leaves with the push and spends the
        // last third of the trip drifting to a stop, instead of arriving with
        // speed and then halting.
        let recoilAnimation: Animation = reduceMotion
            ? .linear(duration: homeDuration)
            : .timingCurve(0.18, 0.35, 0.36, 1.00,
                           duration: homeDuration)
        // Retain some angular velocity at the end. `beginSettling` transfers
        // that velocity to a softer residual spin instead of stopping it dead.
        let spinAnimation: Animation = reduceMotion
            ? .linear(duration: spinDuration)
            : .timingCurve(0.22, 0.30, 0.74, 0.9785,
                           duration: spinDuration)
        let buttonAnimation: Animation = reduceMotion
            ? .easeOut(duration: 0.10)
            : .spring(response: 0.22, dampingFraction: 0.52)
        withAnimation(recoilAnimation) {
            motionOffset = .zero
        } completion: {
            guard actionSequence == token else { return }
            // A correct answer hands off from the spin animation's own
            // completion below. A miss has no spin, so its travel owns arrival.
            if !celebrates { beginSettling(token: token) }
        }
        if celebrates {
            withAnimation(spinAnimation) {
                celebrationSpin += 450
            } completion: {
                guard actionSequence == token else { return }
                beginSettling(token: token)
            }
        }
        withAnimation(buttonAnimation) {
            buttonImpactScale = 1
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + pushOffDuration) {
            guard actionSequence == token else { return }
            beginReturn(token: token)
        }
    }

    private func beginReturn(token: Int) {
        motionPhase = .travellingHome
        phaseStarted = Date()
    }

    private func beginSettling(token: Int) {
        let now = Date()
        let completedSomersault = celebrationSpin
        // The return glide has reached the exact centre. Transfer its angular
        // position immediately. Baking the final angle into the idle layer
        // prevents a snap when the separate somersault layer is cleared.
        let rawRotation = rawIdleRotation(at: now)
        let landingRotation = nearestEquivalent(of: actionRotation + completedSomersault,
                                                to: rawRotation)
        var transfer = Transaction()
        transfer.disablesAnimations = true
        withTransaction(transfer) {
            idleRotationOffset = landingRotation - rawRotation
            celebrationSpin = 0
            motionPhase = .settling
            phaseStarted = now
        }
        if selectedWasCorrect, !reduceMotion, abs(completedSomersault) > 0.001 {
            spinCarryStarted = now
            // About 43 degrees/second at hand-off, matching the end of the
            // bezier above. The smaller finite distance preserves the playful
            // after-spin without dominating the complete next question.
            let direction = completedSomersault < 0 ? -1.0 : 1.0
            spinCarryDistance = direction * 120
        } else {
            spinCarryStarted = nil
            spinCarryDistance = 0
        }
        // Introduce drift and breathing over the recovery poses. The rotation
        // itself is intentionally not normalised: a miss keeps facing its
        // chosen answer, and a success keeps the character of its 450° landing.
        withAnimation(.easeInOut(duration: settleDuration)) {
            driftAmount = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + settleDuration) {
            guard actionSequence == token else { return }
            finishAction()
        }
    }

    private func nearestEquivalent(of angle: Double, to reference: Double) -> Double {
        var difference = (angle - reference).truncatingRemainder(dividingBy: 360)
        if difference > 180 { difference -= 360 }
        if difference < -180 { difference += 360 }
        return reference + difference
    }

    private func rawIdleRotation(at date: Date) -> Double {
        guard !reduceMotion else { return 0 }
        let time = date.timeIntervalSinceReferenceDate
        // A slow weightless sway. The face stays readable; the full turn is
        // reserved for the happy flip after a correct answer.
        return sin(time * 0.42) * 10 + sin(time * 0.17) * 4
    }

    private func idleRotation(at date: Date) -> Double {
        rawIdleRotation(at: date) + idleRotationOffset + spinCarryRotation(at: date)
    }

    /// Integrates an exponentially fading angular velocity. The first derivative
    /// matches the end of the somersault; the finite result lets the lion come
    /// to rest naturally at a playful, not necessarily upright, orientation.
    private func spinCarryRotation(at date: Date) -> Double {
        guard let spinCarryStarted, abs(spinCarryDistance) > 0.001 else { return 0 }
        let elapsed = max(0, date.timeIntervalSince(spinCarryStarted))
        return spinCarryDistance * (1 - exp(-elapsed / 2.8))
    }

    private func finishAction() {
        motionPhase = .idle
        phaseStarted = Date()
        selectedOptionID = nil
        buttonHasContact = false
        buttonImpactScale = 1
        isMoving = false
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) {
            celebrationSpin = 0
        }
        if driftAmount < 1 {
            withAnimation(.easeOut(duration: reduceMotion ? 0.08 : 0.45)) {
                driftAmount = 1
            }
        }
    }

    private func cancelAction(token: Int) {
        guard actionSequence == token else { return }
        let now = Date()
        // Preserve the on-screen angle before switching back to the idle
        // rotation layer, then relax all three motion channels together.
        idleRotationOffset = actionRotation - rawIdleRotation(at: now)
        motionPhase = .settling
        phaseStarted = now
        withAnimation(.easeOut(duration: 0.18)) {
            motionOffset = .zero
            idleRotationOffset = 0
            driftAmount = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            guard actionSequence == token else { return }
            finishAction()
        }
    }

    private func beginEntrance(metrics: Metrics) {
        actionSequence &+= 1
        isMoving = false
        motionPhase = .idle
        phaseStarted = Date()
        driftAmount = 1
        completionOffset = .zero
        spinCarryStarted = nil
        spinCarryDistance = 0

        var setup = Transaction()
        setup.disablesAnimations = true
        withTransaction(setup) {
            // Begin beneath the visible deck, directly behind the circular
            // launch platform. The screen clipping keeps the character hidden
            // until it springs up through the platform into the viewport.
            motionOffset = reduceMotion
                ? .zero
                : CGSize(width: 0,
                         height: metrics.size.height - metrics.centre.y
                             + metrics.lionSize * 0.62)
            lionScale = reduceMotion ? 0.92 : 0.78
            lionOpacity = reduceMotion ? 0 : 1
            celebrationSpin = reduceMotion ? 0 : -10
        }

        withAnimation(.spring(response: reduceMotion ? 0.22 : 1.64,
                              dampingFraction: reduceMotion ? 0.90 : 0.76)) {
            motionOffset = .zero
            lionScale = 1
            lionOpacity = 1
            celebrationSpin = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0.24 : 1.82)) {
            onFishEntranceComplete()
        }
    }

    private func beginCompletion(width: CGFloat) {
        actionSequence &+= 1
        let now = Date()
        isMoving = true
        motionPhase = .travellingOut
        phaseStarted = now
        actionRotation = idleRotation(at: now)
        driftAmount = 0
        withAnimation(.easeIn(duration: reduceMotion ? 0.18 : 0.82)) {
            completionOffset = CGSize(width: width * 0.62, height: -width * 0.16)
            lionScale = 1.12
            if !reduceMotion { celebrationSpin += 220 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0.22 : 0.88)) {
            onLevelCompletionFinished()
        }
    }

    /// The inherited tutorial describes the old flight controls. Let its
    /// existing cards advance as a short, non-blocking introduction while the
    /// new tap controls remain self-evident.
    private func progressTutorial(_ step: TutorialStep?) {
        tutorialSequence &+= 1
        let token = tutorialSequence
        guard let step else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.48) {
            guard tutorialSequence == token else { return }
            switch step {
            case .dragToFly:
                onTutorialEvent(.draggedLow)
                onTutorialEvent(.draggedHigh)
            case .tapToFly:
                onTutorialEvent(.tappedBelow)
                onTutorialEvent(.tappedAbove)
            case .diveUnder:
                onTutorialEvent(.passedUnderSet)
            case .correctHoop:
                onTutorialEvent(.passedCorrectHoop(withTurbo: false))
            case .turbo:
                onTutorialEvent(.passedCorrectHoop(withTurbo: true))
            case .wrongHoop:
                onTutorialEvent(.passedCorrectHoop(withTurbo: false))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    guard tutorialSequence == token else { return }
                    onTutorialEvent(.passedCorrectHoop(withTurbo: false))
                }
            case .goodLuck:
                break
            }
        }
    }
}

extension SpaceLionPlayfield {
    struct Metrics {
        let size: CGSize
        let topReserve: CGFloat
        let bottomReserve: CGFloat
        let leftReserve: CGFloat
        let rightReserve: CGFloat
        let isPad: Bool

        /// The answer bank starts immediately below the overhead rail. The
        /// proportional nudge keeps the same visual breathing room on a short
        /// phone instead of relying on one device-sized gap. iPad places the
        /// bank between its own roof and deck, below.
        private var columnTop: CGFloat {
            topReserve + max(8, size.height * 0.018)
        }
        private var columnBottom: CGFloat {
            let safeBottom = size.height - max(bottomReserve, 8)
            // End the answer bank just above the deck. The larger modules sit
            // lower here while the last answer still clears the foreground
            // console instead of floating against the bottom edge.
            return min(safeBottom - size.height * 0.08,
                       size.height * 0.80)
        }
        private var slotHeight: CGFloat {
            max(1, (columnBottom - columnTop) / CGFloat(GameConfig.answerColumnCount))
        }

        /// Roof and deck for a landscape iPad. The phone layout fills a short
        /// canvas from the top, so on a 13-inch iPad the unused height all
        /// becomes floor and the ceiling stays a thin lid. These two bands are
        /// almost the same depth: the roof grows down from the HUD, the deck
        /// stays just deep enough for the launch pad.
        private struct PadRoom {
            /// Glass top. The HUD is centred inside this band.
            let visualCeiling: CGFloat
            let ceilingJointY: CGFloat
            let floorTop: CGFloat
            let answerSize: CGFloat
            let firstRowY: CGFloat
        }

        private var padRoom: PadRoom {
            let count = CGFloat(max(1, GameConfig.answerColumnCount))
            // Roof and deck share one pair of bands, 60/40. The roof is the
            // deeper one because it also carries the instruments.
            let visualCeiling = max(size.height * 0.335 * 0.60, topReserve + 6)
            let visualFloor = visualCeiling * (0.40 / 0.60)
            let header: CGFloat = 26
            let ceilingJointY = visualCeiling - header
            // `bottom` sits one frame-and-sill below this joint, which is the
            // visible floor the player compares with the roof.
            let floorTop = min(size.height - max(bottomReserve, 16),
                               size.height - visualFloor + 27)
            let ledClearance: CGFloat = 32
            let flange: CGFloat = 0.56
            let seam: CGFloat = 1.12
            let divisor = flange * 2 + max(0, count - 1) * seam
            let span = max(1, floorTop - ceilingJointY)
            let fitted = max(1, (span - ledClearance * 2) / max(divisor, 1))
            let answerSize = min(fitted,
                                 size.width * 0.168,
                                 size.height * 0.230)
            let slack = max(0, span - ledClearance * 2 - answerSize * divisor)
            let firstRowY = ceilingJointY + ledClearance + slack * 0.5 + answerSize * flange
            return PadRoom(visualCeiling: visualCeiling,
                           ceilingJointY: ceilingJointY,
                           floorTop: floorTop,
                           answerSize: answerSize,
                           firstRowY: firstRowY)
        }

        /// Height of the roof band the HUD is centred in. Phone uses the
        /// reserved instrument strip under the status bar.
        var ceilingBand: CGFloat {
            isPad ? padRoom.visualCeiling : topReserve + 10
        }

        var answerSize: CGFloat {
            if isPad { return padRoom.answerSize }
            // `size` is the complete mechanical module; the illuminated stone
            // inside remains comfortably above the 44 pt touch minimum.
            return min(max(slotHeight * 1.09, 80),
                       132,
                       size.width * 0.194)
        }
        /// Physical cabinet visible outside the answer modules. Keeping this
        /// proportional (and capped by the module size) leaves enough room for
        /// a readable side face on phones without swallowing the play window
        /// on an iPad.
        private var cabinetDepth: CGFloat {
            min(size.width * 0.04, answerSize * 0.34)
        }
        private var sideMargin: CGFloat { isPad ? 44 : 8 }
        private var leftX: CGFloat {
            max(leftReserve, sideMargin) + cabinetDepth + answerSize * 0.56
        }
        private var rightX: CGFloat {
            size.width - max(rightReserve, sideMargin) - cabinetDepth - answerSize * 0.56
        }

        /// Three controls in each side column, read top to bottom: the lowest
        /// values on the left wall, the highest on the right wall. These are
        /// deliberately on one vertical axis: perspective belongs to the room
        /// around the controls, never to the control alignment itself.
        var answerPoints: [CGPoint] {
            // The fixed mounting flange painted behind each interactive module
            // is 112% of the button size, so that complete visible housing—not
            // merely the tappable face—defines the pitch. Adjacent housings
            // meet at one clean seam without either one hanging over the next.
            let firstRowY: CGFloat
            let housingPitch: CGFloat
            if isPad {
                let room = padRoom
                firstRowY = room.firstRowY
                housingPitch = room.answerSize * 1.12
            } else {
                firstRowY = columnTop + slotHeight * 0.5
                housingPitch = answerSize * 1.12
            }
            let rows = (0..<GameConfig.answerColumnCount).map {
                firstRowY + housingPitch * CGFloat($0)
            }
            return rows.map { CGPoint(x: leftX, y: $0) }
                + rows.map { CGPoint(x: rightX, y: $0) }
        }

        fileprivate var cockpit: CockpitLayout {
            let frameWidth: CGFloat = isPad ? 26 : 18
            // The rack ends at the mounting flange, rather than carrying an
            // extra strip of empty cabinet between the controls and glass.
            let leftEdge = leftX + answerSize * 0.56
            let rightEdge = rightX - answerSize * 0.56
            // Align the outside edge of the yellow window rail with the answer
            // flange. The rail lives 0.34 frame widths outside the glass and
            // its own stroke adds this final half-width.
            let yellowRailHalfWidth: CGFloat = (isPad ? 3.4 : 2.4) * 0.5
            let frameOuterReach = frameWidth * 0.34 + yellowRailHalfWidth
            // Keep the ceiling joint where it already clears the HUD, but let
            // the actual glass begin lower. The space between both becomes a
            // deliberate instrument header instead of an accidental dark rim.
            // On iPad the joint and the deck come from one shared room, so a
            // taller canvas cannot leave the floor twice as deep as the roof.
            let ceilingJointY: CGFloat
            let top: CGFloat
            let floorTop: CGFloat
            if isPad {
                let room = padRoom
                ceilingJointY = room.ceilingJointY
                top = room.visualCeiling
                floorTop = room.floorTop
            } else {
                ceilingJointY = topReserve - frameWidth * 0.5
                top = topReserve + 10
                let rows = answerPoints.prefix(GameConfig.answerColumnCount)
                let lastAnswerY = rows.last?.y ?? columnBottom
                // One shared horizon for the whole room. The answer rack, the
                // screen sill and the side walls all meet the floor here.
                floorTop = min(size.height - max(bottomReserve, 8),
                               lastAnswerY + answerSize * 0.64)
            }
            let sillDepth: CGFloat = isPad ? 14 : 9
            // Let the outside view continue down until only the physical lower
            // frame and its shallow sill remain above the shared floor line.
            let bottom = max(top + 60,
                             floorTop - frameWidth * 0.5 - sillDepth)
            // On iPad the larger stones already narrow the glass. A further
            // inset keeps the viewport from simply growing taller when the
            // roof and deck give up that space.
            let glassInsetX: CGFloat = isPad ? 28 : 0
            return CockpitLayout(
                windowRect: CGRect(x: leftEdge + frameOuterReach + glassInsetX,
                                   y: top,
                                   width: max(60, rightEdge - leftEdge - frameOuterReach * 2 - glassInsetX * 2),
                                   height: bottom - top),
                ceilingJointY: ceilingJointY,
                floorTop: floorTop,
                canvasHeight: size.height,
                leftEdge: leftEdge,
                rightEdge: rightEdge,
                buttonPoints: answerPoints,
                buttonSize: answerSize)
        }

        /// Phone: the pause control is centred over the left answer column and
        /// the score panel mirrors that offset beside the right column.
        /// iPad: the rail runs from the outer face of the left answer stone to
        /// the outer face of the right one, so the instruments share the
        /// cabinet width instead of floating in a narrower strip.
        func hudInsets(pauseWidth: CGFloat) -> (leading: CGFloat, trailing: CGFloat) {
            if isPad {
                let leading = max(leftReserve, leftX - answerSize * 0.5)
                let trailing = max(rightReserve, size.width - rightX - answerSize * 0.5)
                return (leading, trailing)
            }
            let leading = max(0, leftX - pauseWidth / 2)
            let trailing = max(0, size.width - (rightX + pauseWidth / 2))
            return (leading, trailing)
        }

        var centre: CGPoint {
            let window = cockpit.windowRect
            return CGPoint(x: window.midX, y: window.midY)
        }

        var lionSize: CGFloat {
            // 135% of the original rig: ten percent smaller than the previous
            // 150% treatment while remaining the focus of the cockpit.
            min(size.width * 0.23,
                size.height * (isPad ? 0.35 : 0.38),
                cockpit.windowRect.height * 0.74) * 1.35
        }
    }
}

private func cockpitWrap(_ value: Double) -> Double {
    let remainder = value.truncatingRemainder(dividingBy: 1)
    return remainder < 0 ? remainder + 1 : remainder
}

/// Where the cockpit's fixed structure sits, so the painted bays line up
/// exactly with the interactive buttons laid over them.
private struct CockpitLayout {
    let windowRect: CGRect
    let ceilingJointY: CGFloat
    let floorTop: CGFloat
    let canvasHeight: CGFloat
    let leftEdge: CGFloat
    let rightEdge: CGFloat
    let buttonPoints: [CGPoint]
    let buttonSize: CGFloat
}

/// The interactive part of a wall control: a glossy answer cap sitting in the
/// cockpit's recessed well. The shared cockpit canvas paints the lamp ring.
private struct SpaceConsoleButton: View {
    let text: String
    let size: CGFloat
    let accentColor: Color
    let feedback: HoopFeedback
    let isPressed: Bool
    @State private var shakePhase: CGFloat = 0

    private struct Palette {
        let glow: Color
        let highlight: Color
        let deep: Color
        let ink: Color
    }

    private var palette: Palette {
        switch feedback {
        case .correct, .revealedCorrect, .bonus:
            return Palette(glow: Color(red: 0.20, green: 0.95, blue: 0.50),
                           highlight: Color(red: 0.86, green: 1.00, blue: 0.90),
                           deep: Color(red: 0.00, green: 0.45, blue: 0.22),
                           ink: Color(red: 0.00, green: 0.22, blue: 0.10))
        case .wrong:
            return Palette(glow: Color(red: 1.00, green: 0.48, blue: 0.22),
                           highlight: Color(red: 1.00, green: 0.90, blue: 0.78),
                           deep: Color(red: 0.55, green: 0.16, blue: 0.04),
                           ink: Color(red: 0.32, green: 0.08, blue: 0.02))
        case .none, .inactive, .bypassed:
            return Palette(glow: Color(red: 0.16, green: 0.76, blue: 1.00),
                           highlight: Color(red: 0.84, green: 0.97, blue: 1.00),
                           deep: Color(red: 0.03, green: 0.24, blue: 0.78),
                           ink: Color(red: 0.00, green: 0.08, blue: 0.32))
        }
    }

    private var glowStrength: Double {
        switch feedback {
        case .correct, .revealedCorrect, .bonus, .wrong:
            return 0.88
        case .none, .inactive, .bypassed:
            return 0.46
        }
    }

    var body: some View {
        let colors = palette
        ZStack {
            // One self-contained control module. The plate, socket, rails and
            // cap scale together, so this button remains part of the cabinet
            // instead of looking like a circle laid over a background image.
            SpaceModuleShape(cut: size * 0.23)
                .fill(LinearGradient(
                    colors: [Color(red: 0.28, green: 0.36, blue: 0.54),
                             Color(red: 0.08, green: 0.12, blue: 0.24),
                             Color(red: 0.025, green: 0.035, blue: 0.09)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
                .overlay {
                    SpaceModuleShape(cut: size * 0.23)
                        .stroke(LinearGradient(colors: [.white.opacity(0.46),
                                                        .white.opacity(0.05),
                                                        .black.opacity(0.88)],
                                               startPoint: .top,
                                               endPoint: .bottom),
                                lineWidth: max(1, size * 0.025))
                }
                .shadow(color: .black.opacity(0.75), radius: size * 0.055,
                        y: size * 0.035)

            SpaceModuleShape(cut: size * 0.18)
                .fill(Color(red: 0.025, green: 0.04, blue: 0.10))
                .overlay {
                    SpaceModuleShape(cut: size * 0.18)
                        .stroke(colors.glow.opacity(0.34),
                                lineWidth: max(1, size * 0.012))
                }
                .padding(size * 0.075)

            // Recessed vertical service channels visually lock the module into
            // the continuous console bank painted behind it.
            HStack(spacing: size * 0.68) {
                ForEach(0..<2, id: \.self) { side in
                    ZStack {
                        Capsule()
                            .fill(.black.opacity(0.72))
                            .frame(width: size * 0.075, height: size * 0.43)
                        Capsule()
                            .fill(LinearGradient(colors: [colors.glow.opacity(0.95),
                                                          colors.glow.opacity(0.18)],
                                                 startPoint: .top,
                                                 endPoint: .bottom))
                            .frame(width: size * 0.025, height: size * 0.31)
                            .shadow(color: colors.glow.opacity(0.72),
                                    radius: size * 0.035)
                        if side == 0 {
                            ForEach(0..<3, id: \.self) { index in
                                Capsule()
                                    .fill(.white.opacity(0.22))
                                    .frame(width: size * 0.035, height: size * 0.008)
                                    .offset(y: (CGFloat(index) - 1) * size * 0.095)
                            }
                        }
                    }
                }
            }

            // Mechanical corner fasteners and short amber power brackets.
            ForEach(0..<4, id: \.self) { index in
                let x: CGFloat = index.isMultiple(of: 2) ? -1 : 1
                let y: CGFloat = index < 2 ? -1 : 1
                ZStack {
                    Circle()
                        .fill(RadialGradient(colors: [.white.opacity(0.78),
                                                      Color(red: 0.34, green: 0.43, blue: 0.58),
                                                      .black],
                                             center: UnitPoint(x: 0.35, y: 0.30),
                                             startRadius: 0,
                                             endRadius: size * 0.035))
                        .frame(width: size * 0.07, height: size * 0.07)
                    Capsule()
                        .fill(accentColor)
                        .frame(width: size * 0.11, height: size * 0.025)
                        .offset(x: -x * size * 0.075)
                        .shadow(color: accentColor.opacity(0.90),
                                radius: size * 0.025)
                }
                .offset(x: x * size * 0.35, y: y * size * 0.35)
            }

            Circle()
                .fill(LinearGradient(colors: [Color(red: 0.28, green: 0.36, blue: 0.52),
                                              Color(red: 0.08, green: 0.11, blue: 0.20),
                                              Color(red: 0.02, green: 0.03, blue: 0.07)],
                                     startPoint: .top,
                                     endPoint: .bottom))
                .overlay(
                    Circle().stroke(LinearGradient(colors: [.white.opacity(0.50),
                                                            .white.opacity(0.05),
                                                            .black.opacity(0.75)],
                                                   startPoint: .top,
                                                   endPoint: .bottom),
                                    lineWidth: size * 0.014)
                )
                .padding(size * 0.145)
                .shadow(color: .black.opacity(0.55), radius: size * 0.045, y: size * 0.025)

            Circle()
                .stroke(colors.glow.opacity(0.28), lineWidth: size * 0.010)
                .padding(size * 0.168)
            Circle()
                .stroke(colors.glow.opacity(glowStrength), lineWidth: size * 0.034)
                .blur(radius: size * 0.018)
                .padding(size * 0.198)
            Circle()
                .stroke(colors.glow.opacity(0.95), lineWidth: size * 0.012)
                .padding(size * 0.198)
            Circle()
                .stroke(.white.opacity(0.70), lineWidth: max(1, size * 0.008))
                .padding(size * 0.214)

            cap(colors, diameter: size * 0.54)
        }
        .frame(width: size, height: size)
        .modifier(SpaceShakeEffect(progress: shakePhase, distance: size * 0.045))
        .opacity(feedback == .inactive ? 0.55 : 1)
        .animation(.spring(response: 0.22, dampingFraction: 0.68), value: isPressed)
        .animation(.easeInOut(duration: 0.24), value: feedback)
        .onChange(of: feedback) { _, value in
            guard value == .wrong else { return }
            withAnimation(.linear(duration: 0.34)) { shakePhase += 1 }
        }
        .contentShape(SpaceModuleShape(cut: size * 0.24))
    }

    private func cap(_ colors: Palette, diameter: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [colors.highlight, colors.glow, colors.deep, .black.opacity(0.35)],
                                     center: UnitPoint(x: 0.38, y: 0.28),
                                     startRadius: 0,
                                     endRadius: diameter * 0.72))
            Circle()
                .strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.75), colors.deep.opacity(0.2), .black.opacity(0.55)],
                                   startPoint: .top,
                                   endPoint: .bottom),
                    lineWidth: diameter * 0.045
                )
            Circle()
                .stroke(colors.glow.opacity(0.55), lineWidth: diameter * 0.02)
                .padding(diameter * 0.08)
            Ellipse()
                .fill(LinearGradient(colors: [.white.opacity(0.78), .white.opacity(0)],
                                     startPoint: .top,
                                     endPoint: .bottom))
                .frame(width: diameter * 0.62, height: diameter * 0.30)
                .offset(y: -diameter * 0.24)
            Ellipse()
                .fill(.white.opacity(0.22))
                .frame(width: diameter * 0.18, height: diameter * 0.10)
                .offset(x: -diameter * 0.16, y: -diameter * 0.22)

            Text(verbatim: text)
                .font(.system(size: diameter * 0.50, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.36)
                .frame(width: diameter * 0.82)
                .shadow(color: colors.ink, radius: 0, y: diameter * 0.03)
                .shadow(color: colors.ink.opacity(0.9), radius: diameter * 0.04)
                .shadow(color: .black.opacity(0.35), radius: diameter * 0.02, y: diameter * 0.02)
        }
        .frame(width: diameter, height: diameter)
        .scaleEffect(isPressed ? 0.90 : 1)
        .offset(y: isPressed ? diameter * 0.035 : 0)
        .brightness(isPressed ? 0.08 : 0)
        .shadow(color: colors.glow.opacity(isPressed ? 1 : glowStrength * 0.9),
                radius: size * (isPressed ? 0.14 : 0.07))
    }
}

/// Gives every answer an immediate, tactile response while the lion begins its
/// longer flight toward the chosen control.
private struct SpaceAnswerPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
            configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .brightness(configuration.isPressed ? 0.10 : 0)
            .offset(y: configuration.isPressed ? 3 : 0)
            .animation(.spring(response: 0.16, dampingFraction: 0.58),
                       value: configuration.isPressed)
    }
}

private struct SpaceShakeEffect: GeometryEffect {
    var progress: CGFloat
    let distance: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let translation = sin(progress * .pi * 6) * distance
        return ProjectionTransform(CGAffineTransform(translationX: translation, y: 0))
    }
}

/// A lightweight GPU-friendly reward bloom. Correct answers throw stars and
/// cool sparks; mistakes keep the same motion but use a soft encouraging amber.
private struct SpaceAnswerBurst: View {
    let burst: SpaceAnswerBurstState
    let size: CGFloat
    let reduceMotion: Bool

    @State private var progress: CGFloat = 0

    private var particleCount: Int { burst.isCorrect ? 14 : 8 }
    private var primary: Color {
        burst.isCorrect
            ? Color(red: 0.28, green: 1.00, blue: 0.55)
            : Color(red: 1.00, green: 0.45, blue: 0.18)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(primary.opacity(0.85), lineWidth: max(2, size * 0.025))
                .scaleEffect(0.35 + progress * 0.85)
                .opacity(Double(1 - progress))
                .shadow(color: primary, radius: size * 0.08)

            ForEach(0..<particleCount, id: \.self) { index in
                let fraction = CGFloat(index) / CGFloat(particleCount)
                let angle = fraction * .pi * 2 + CGFloat(index % 3) * 0.17
                let distance = size * (0.28 + CGFloat((index * 37) % 11) / 40)
                Group {
                    if burst.isCorrect && index.isMultiple(of: 3) {
                        Image(systemName: "star.fill")
                            .font(.system(size: size * (index.isMultiple(of: 2) ? 0.105 : 0.075),
                                          weight: .black))
                    } else {
                        Capsule()
                            .frame(width: size * 0.035, height: size * 0.10)
                    }
                }
                .foregroundStyle(index.isMultiple(of: 2) ? primary : .white)
                .shadow(color: primary, radius: size * 0.04)
                .rotationEffect(.radians(Double(angle + progress * 1.4)))
                .offset(x: cos(angle) * distance * progress,
                        y: sin(angle) * distance * progress)
                .scaleEffect(0.45 + (1 - progress) * 0.65)
                .opacity(Double(1 - progress))
            }
        }
        .frame(width: size, height: size)
        .onAppear {
            progress = 0
            withAnimation(.easeOut(duration: reduceMotion ? 0.22 : 0.70)) {
                progress = 1
            }
        }
    }
}

private struct SpaceModuleShape: Shape {
    let cut: CGFloat

    func path(in rect: CGRect) -> Path {
        let c = min(cut, min(rect.width, rect.height) * 0.28)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + c, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - c, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + c))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - c))
        path.addLine(to: CGPoint(x: rect.maxX - c, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + c, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - c))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + c))
        path.closeSubpath()
        return path
    }
}

/// The glass in front of the viewport: a slow reflection and a soft inner
/// vignette. It never accepts hits, so the answer buttons stay outside it.
private struct SpaceViewportGlass: View {
    let window: CGRect
    let cut: CGFloat
    let isRunning: Bool

    var body: some View {
        // A reflection crossing the glass is deliberately slow. Eight samples
        // per second look continuous while avoiding a full-window gradient and
        // clip pass on every display frame.
        TimelineView(.animation(minimumInterval: SpaceAnimationBudget.glassInterval,
                                paused: !isRunning)) { timeline in
            let travel = isRunning
                ? cockpitWrap(timeline.date.timeIntervalSinceReferenceDate * 0.06)
                : 0.22
            ZStack {
                LinearGradient(colors: [.white.opacity(0.09), .white.opacity(0.02), .clear],
                               startPoint: .top,
                               endPoint: UnitPoint(x: 0.5, y: 0.42))
                LinearGradient(colors: [.clear, .black.opacity(0.14)],
                               startPoint: UnitPoint(x: 0.5, y: 0.78),
                               endPoint: .bottom)
                GeometryReader { proxy in
                    let band = proxy.size.width * 0.18
                    Rectangle()
                        .fill(LinearGradient(colors: [.clear, .white.opacity(0.10), .clear],
                                             startPoint: .leading,
                                             endPoint: .trailing))
                        .frame(width: band)
                        .rotationEffect(.degrees(16))
                        .offset(x: -band + (proxy.size.width + band * 2) * travel,
                                y: -proxy.size.height * 0.08)
                }
            }
            .clipShape(SpaceModuleShape(cut: cut))
        }
        .frame(width: window.width, height: window.height)
        .position(x: window.midX, y: window.midY)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The short forward jump between two ten-question stages. Star points stretch
/// radially from the vanishing point, a bright tunnel closes over the previous
/// view, and then clears to reveal the new destination already waiting behind
/// it. The whole cockpit receives a small synchronized vibration above.
private struct SpaceForwardJourney: View {
    let window: CGRect
    let stage: Int
    let journeyID: Int
    let reduceMotion: Bool

    @State private var progress: CGFloat = 0

    var body: some View {
        let cut = min(window.width, window.height) * 0.11
        Canvas { context, size in
            let centre = CGPoint(x: size.width * 0.50, y: size.height * 0.46)
            let fade = max(0, 1 - progress)
            let tunnel = sin(Double(progress) * .pi)

            context.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .radialGradient(Gradient(stops: [
                            .init(color: .white.opacity(0.18 * tunnel), location: 0),
                            .init(color: Color(red: 0.18, green: 0.64, blue: 1.00)
                                .opacity(0.42 + 0.34 * tunnel), location: 0.24),
                            .init(color: Color(red: 0.08, green: 0.02, blue: 0.25)
                                .opacity(0.72 * fade + 0.18), location: 0.66),
                            .init(color: .black.opacity(0.88 * fade), location: 1)
                         ]), center: centre, startRadius: 0,
                         endRadius: max(size.width, size.height) * 0.72))

            var light = context
            light.blendMode = .plusLighter
            let maximumRadius = hypot(size.width, size.height) * 0.66
            for index in 0..<58 {
                let seed = CGFloat((index * 47 + journeyID * 31) % 101) / 101
                let angle = Double(index) / 58 * .pi * 2 + Double(stage) * 0.37
                let start = maximumRadius * (0.035 + seed * 0.30) * (0.4 + progress)
                let length = maximumRadius * (0.08 + seed * 0.22) * (0.5 + progress * 1.8)
                var streak = Path()
                streak.move(to: CGPoint(x: centre.x + cos(angle) * start,
                                         y: centre.y + sin(angle) * start * 0.58))
                streak.addLine(to: CGPoint(x: centre.x + cos(angle) * (start + length),
                                            y: centre.y + sin(angle) * (start + length) * 0.58))
                let tint = index.isMultiple(of: 4)
                    ? Color(red: 1.00, green: 0.72, blue: 0.34)
                    : Color(red: 0.58, green: 0.90, blue: 1.00)
                light.stroke(streak,
                             with: .color(tint.opacity(0.30 + 0.60 * tunnel)),
                             style: StrokeStyle(lineWidth: 0.8 + seed * 2.6,
                                                lineCap: .round))
            }

            let ringRadius = min(size.width, size.height) * (0.08 + progress * 0.48)
            light.stroke(Path(ellipseIn: CGRect(x: centre.x - ringRadius,
                                                y: centre.y - ringRadius * 0.58,
                                                width: ringRadius * 2,
                                                height: ringRadius * 1.16)),
                         with: .color(.white.opacity(0.72 * fade)),
                         lineWidth: reduceMotion ? 2 : 5)
        }
        .overlay(alignment: .top) {
            HStack(spacing: 7) {
                Image(systemName: "location.fill")
                Text(verbatim: "\(stage)")
                    .monospacedDigit()
            }
            .font(.system(size: window.height * 0.07, weight: .black, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(.black.opacity(0.42), in: Capsule())
            .padding(.top, window.height * 0.09)
            .opacity(Double(sin(Double(progress) * .pi)))
        }
        .frame(width: window.width, height: window.height)
        .clipShape(SpaceModuleShape(cut: cut))
        .position(x: window.midX, y: window.midY)
        .id(journeyID)
        .onAppear {
            progress = 0
            withAnimation(.easeInOut(duration: reduceMotion ? 0.35 : GameConfig.stageTravelDuration)) {
                progress = 1
            }
        }
    }
}

/// Rings and sparks when a board is completed, before the result card.
private struct VictoryBloom: View {
    let size: CGFloat
    let reduceMotion: Bool
    @State private var progress: CGFloat = 0

    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { ring in
                Circle()
                    .stroke(Color(red: 0.45, green: 0.90, blue: 1.00).opacity(0.85),
                            lineWidth: max(2, size * 0.012))
                    .frame(width: size * 0.45, height: size * 0.45)
                    .scaleEffect(0.35 + progress * (0.7 + CGFloat(ring) * 0.38))
                    .opacity(Double(1 - progress) * 0.9)
            }
            ForEach(0..<10, id: \.self) { index in
                let angle = CGFloat(index) / 10 * .pi * 2
                Image(systemName: "star.fill")
                    .font(.system(size: size * 0.045, weight: .black))
                    .foregroundStyle(index.isMultiple(of: 2)
                                     ? Color(red: 1.00, green: 0.78, blue: 0.28)
                                     : .white)
                    .offset(x: cos(angle) * size * 0.42 * progress,
                            y: sin(angle) * size * 0.28 * progress)
                    .opacity(Double(1 - progress))
            }
        }
        .frame(width: size, height: size)
        .onAppear {
            withAnimation(.easeOut(duration: reduceMotion ? 0.2 : 0.78)) {
                progress = 1
            }
        }
        .accessibilityHidden(true)
    }
}

/// The cockpit interior: a roof under the HUD, two button columns, a large
/// chamfered windshield onto a nebula and a planet, and a perspective floor
/// with a teleporter pad. Everything is drawn from paths and gradients.
private struct SpaceshipCockpit: View {
    private struct StarSample {
        let depth: CGFloat
        let x: CGFloat
        let y: CGFloat
        let twinkleRate: Double
    }

    let layout: CockpitLayout
    let character: AnimalCharacter
    let isPad: Bool
    let isRunning: Bool
    let destinationStage: Int
    let feedbacks: [HoopFeedback]

    private let cyan = Color(red: 0.20, green: 0.82, blue: 1.00)
    private let blue = Color(red: 0.08, green: 0.34, blue: 0.95)
    private var orange: Color { character.color }
    private let metalLight = Color(red: 0.55, green: 0.64, blue: 0.82)
    private let metal = Color(red: 0.16, green: 0.22, blue: 0.38)
    private let metalDark = Color(red: 0.035, green: 0.05, blue: 0.11)
    private var destination: Int { (max(1, destinationStage) - 1) % 5 + 1 }

    /// Normalised star data is invariant for the life of the app. Precomputing
    /// it avoids four integer hash sequences per star on every animation frame.
    private static let starSamples: [StarSample] = (0..<120).map { index in
        let depth = seededValue(index, 1)
        return StarSample(depth: depth,
                          x: seededValue(index, 2),
                          y: seededValue(index, 4),
                          twinkleRate: 0.8 + Double(seededValue(index, 5)) * 2.2)
    }

    var body: some View {
        ZStack {
            // The hull, nebula, planet and control sockets do not change from
            // frame to frame. Keeping them in their own canvas prevents the
            // animation clock from rebuilding hundreds of paths and gradients
            // just to move a few small lights.
            Canvas(opaque: true, rendersAsynchronously: true) { context, size in
                drawStatic(in: context, size: size)
            }

            // These lamps only change when answer feedback changes. Keeping
            // them outside the scenery clock avoids rebuilding 64 radial
            // gradients on every decorative animation tick.
            Canvas { context, _ in
                drawFeedbackLights(in: context)
            }

            // The heavier cockpit scenery deliberately stays on a slow clock.
            // The interactive lion and boundary LEDs have their own cheaper
            // animation paths, so neither needs to inherit this low cadence.
            TimelineView(.animation(minimumInterval: SpaceAnimationBudget.sceneryInterval,
                                    paused: !isRunning)) { timeline in
                let time = timeline.date.timeIntervalSinceReferenceDate
                Canvas(rendersAsynchronously: true) { context, size in
                    drawAnimated(in: context, size: size, time: time)
                }
            }

            // Only four dashed strokes and their glow are redrawn here. This
            // dedicated clock keeps the long LED strips fluid while avoiding a
            // 30-fps redraw of the nebula, asteroids and cockpit effects.
            TimelineView(.animation(minimumInterval: SpaceAnimationBudget.ledInterval,
                                    paused: !isRunning)) { timeline in
                let time = timeline.date.timeIntervalSinceReferenceDate
                Canvas { context, size in
                    drawBoundaryLightChains(
                        in: context,
                        size: size,
                        phase: CGFloat(cockpitWrap(time * 0.028))
                    )
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var frameWidth: CGFloat { isPad ? 26 : 18 }
    /// Only the near side of the foreground platform enters the screen. This
    /// keeps its complete upper arc visible while preserving a strip of deck
    /// between that arc and the newly lowered floor joint.
    private var platformVisibleFraction: CGFloat { isPad ? 0.52 : 0.40 }

    /// The launch pad sits on the deck. iPad draws a wider disc so the
    /// shallower floor still reads as occupied rather than as empty plating.
    private func platformDisc(in size: CGSize) -> CGRect {
        let width = isPad
            ? size.width * 0.50
            : min(size.width * 0.40, layout.windowRect.width * 0.62)
        let floorDepth = max(1, size.height - layout.floorTop)
        let height = min(width * 0.30, floorDepth * 1.5)
        return CGRect(x: size.width / 2 - width / 2,
                      y: size.height - height * platformVisibleFraction,
                      width: width,
                      height: height)
    }
    /// How strongly the near edge of each side wall opens toward the viewer.
    /// The wall panels and the wall/floor joint must use this exact same
    /// projection or the cockpit stops reading as one coherent 3D box.
    private var sideWallFrontSpread: CGFloat {
        let preferred: CGFloat = isPad ? 1.34 : 1.40
        let vanishingY = layout.windowRect.midY
        let floorRun = layout.floorTop - vanishingY
        guard floorRun > 1 else { return preferred }

        // A lowered floor used to push the projected outer joint beyond the
        // canvas, where it was clamped and stopped matching the wall above.
        // Fit the complete projection into the available height instead. The
        // same fitted value is used by roof, walls and floor, preserving one
        // coherent vanishing system at every aspect ratio.
        let nearLimit = layout.canvasHeight - (isPad ? 8 : 5)
        let fitted = (nearLimit - vanishingY) / floorRun
        return min(preferred, max(1.08, fitted))
    }

    /// Projects a horizontal line on the rear wall to the visible edge of a
    /// side wall. Both the ceiling and floor use this, so their joints meet
    /// the wall panels at the exact same perspective angle.
    private func sideWallCanvasY(backY: CGFloat,
                                 innerX: CGFloat,
                                 outerX: CGFloat,
                                 canvasX: CGFloat) -> CGFloat {
        let vanishingY = layout.windowRect.midY
        let nearY = vanishingY + (backY - vanishingY) * sideWallFrontSpread
        let run = innerX - outerX
        guard abs(run) > 0.5 else { return backY }
        let progress = (canvasX - outerX) / run
        return nearY + (backY - nearY) * progress
    }

    private func drawStatic(in context: GraphicsContext, size: CGSize) {
        let window = layout.windowRect
        let cut = min(window.width, window.height) * 0.11
        let floorTop = layout.floorTop

        context.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .linearGradient(Gradient(colors: [metal, metalDark, .black]),
                                           startPoint: .zero,
                                           endPoint: CGPoint(x: 0, y: size.height)))
        drawColumn(in: context, size: size,
                   minX: -2, maxX: layout.leftEdge, innerIsTrailing: true,
                   window: window)
        drawColumn(in: context, size: size,
                   minX: layout.rightEdge, maxX: size.width + 2, innerIsTrailing: false,
                   window: window)
        // The ceiling is the upper foreground plane. It masks the near ends
        // of both side walls along the same perspective projection that the
        // floor uses below, rather than letting the wall panels reach the top.
        drawRoof(in: context, size: size, window: window)
        drawUpperWindowHeader(in: context, window: window, cut: cut)
        drawSpace(in: context, window: window, cut: cut, time: 0)
        drawWindowFrame(in: context, window: window, cut: cut)
        drawSill(in: context, window: window, floorTop: floorTop)
        // The deck is the foreground plane of the box. Drawing it last makes
        // it continue over both side walls at exactly the same horizon as the
        // screen sill and the bottom of the answer racks.
        drawFloor(in: context, size: size, top: floorTop, time: 0)
        // Keep the recessed carriers in the static layer; the illuminated
        // segments themselves are added by the shared animation canvas.
        drawBoundaryLightChains(in: context, size: size, phase: nil)
    }

    private func drawAnimated(in context: GraphicsContext, size: CGSize, time: TimeInterval) {
        let window = layout.windowRect
        let cut = min(window.width, window.height) * 0.11

        // Animated scenery is composited above the static cockpit canvas. Give
        // it its own inset pane so a foreground rock can approach the glass,
        // but can never be painted over the inner metal/neon lip. The static
        // star field remains visible below this safety margin, so the inset
        // reads as depth in the window instead of an empty border.
        let sceneryInset = frameWidth * 0.82
        let sceneryWindow = window.insetBy(dx: sceneryInset, dy: sceneryInset)
        let sceneryCut = max(2, cut - sceneryInset * 0.55)

        // Stars are the only moving part behind the glass. The much heavier
        // nebula and planet remain in the static canvas below.
        context.drawLayer { space in
            space.clip(to: chamfered(sceneryWindow, cut: sceneryCut))
            drawStars(in: space, window: sceneryWindow, time: time)
            drawAsteroids(in: space, window: sceneryWindow, time: time)
            drawAtmosphereShimmer(in: space, window: window, time: time)
            drawSpaceDust(in: space, window: sceneryWindow, time: time)
            drawGalaxyShimmer(in: space, window: window, time: time)
        }

        drawConduitAnimations(in: context, window: window, time: time)
        drawHullEnergyFlow(in: context, window: window, time: time)
        drawPlatformPulse(in: context, size: size, time: time)
    }

    /// The fixed part of the two armoured cables from a control to the glass.
    private func drawConduits(in context: GraphicsContext,
                              from startX: CGFloat,
                              to endX: CGFloat,
                              y: CGFloat) {
        let spacing = layout.buttonSize * 0.12
        for cable in 0..<2 {
            let cableY = y + (cable == 0 ? -spacing : spacing)
            var path = Path()
            path.move(to: CGPoint(x: startX, y: cableY))
            path.addLine(to: CGPoint(x: endX, y: cableY))
            context.stroke(path, with: .color(.black.opacity(0.85)), lineWidth: isPad ? 7 : 5)
            context.stroke(path, with: .color(metal), lineWidth: isPad ? 4 : 3)
            context.stroke(path, with: .color(cyan.opacity(0.55)), lineWidth: isPad ? 1.4 : 1)
        }
    }

    private func drawConduitAnimations(in context: GraphicsContext,
                                       window: CGRect,
                                       time: TimeInterval) {
        for (index, point) in layout.buttonPoints.enumerated() {
            let phase = Double(index)
            let isLeft = point.x < window.midX
            let outward: CGFloat = isLeft ? -1 : 1
            let innerX = point.x - outward * layout.buttonSize * 0.58
            let frameX = isLeft
                ? window.minX - frameWidth * 0.5
                : window.maxX + frameWidth * 0.5

            if point.y > window.minY + frameWidth, point.y < window.maxY - frameWidth {
                drawConduitEnergyBars(in: context,
                                      from: innerX,
                                      to: frameX,
                                      y: point.y,
                                      phase: phase,
                                      time: time)
            }

        }
    }

    private func drawFeedbackLights(in context: GraphicsContext) {
        for (index, point) in layout.buttonPoints.enumerated() {
            let feedback = index < feedbacks.count ? feedbacks[index] : .none
            drawControlLights(in: context, at: point, feedback: feedback)
        }
    }

    /// Long, slow energy bars replace the old fast dots. Both rails flow from
    /// each answer bank toward the central window without any frantic chasing.
    private func drawConduitEnergyBars(in context: GraphicsContext,
                                       from startX: CGFloat,
                                       to endX: CGFloat,
                                       y: CGFloat,
                                       phase: Double,
                                       time: TimeInterval) {
        let spacing = layout.buttonSize * 0.12
        for cable in 0..<2 {
            let cableY = y + (cable == 0 ? -spacing : spacing)
            let progress = CGFloat(cockpitWrap(time * 0.16
                                               + phase * 0.11
                                               + Double(cable) * 0.50))
            let span = abs(endX - startX)
            let length = min(span * 0.58, layout.buttonSize * 0.27)
            let thickness: CGFloat = isPad ? 3.0 : 2.0
            let direction: CGFloat = endX >= startX ? 1 : -1
            let travelStart = startX - direction * length * 0.5
            let travelEnd = endX + direction * length * 0.5
            let centre = CGPoint(x: travelStart + (travelEnd - travelStart) * progress,
                                 y: cableY)
            let clipRect = CGRect(x: min(startX, endX),
                                  y: cableY - thickness * 3,
                                  width: span,
                                  height: thickness * 6)

            context.drawLayer { rail in
                rail.clip(to: Path(clipRect))
                drawEnergyBar(in: rail,
                              centre: centre,
                              length: length,
                              thickness: thickness,
                              vertical: false,
                              color: cyan,
                              opacity: 0.78)
            }
        }
    }

    /// The eight lamps are intentionally fixed. Feedback can change their
    /// colour, but neither their position nor their brightness ever chases.
    private func drawControlLights(in context: GraphicsContext,
                                   at centre: CGPoint,
                                   feedback: HoopFeedback) {
        var glow = context
        glow.blendMode = .plusLighter
        let buttonSize = layout.buttonSize
        let excited = feedback != .none && feedback != .inactive && feedback != .bypassed
        let lampColor = controlLampColor(for: feedback)
        let orbit = buttonSize * 0.385
        let radius = buttonSize * 0.032
        let intensity: Double = excited ? 0.84 : 0.40

        let plate = CGRect(x: centre.x - buttonSize * 0.5,
                           y: centre.y - buttonSize * 0.5,
                           width: buttonSize,
                           height: buttonSize)
        glow.stroke(chamfered(plate, cut: buttonSize * 0.24),
                    with: .color(lampColor.opacity(excited ? 0.22 : 0.08)),
                    lineWidth: isPad ? 8 : 5)

        for lampIndex in 0..<8 {
            let fraction = Double(lampIndex) / 8
            let angle = fraction * 2 * .pi - .pi / 2
            let point = CGPoint(x: centre.x + CGFloat(cos(angle)) * orbit,
                                y: centre.y + CGFloat(sin(angle)) * orbit)

            let core = CGRect(x: point.x - radius, y: point.y - radius,
                              width: radius * 2, height: radius * 2)
            glow.fill(Path(ellipseIn: core),
                      with: .color(lampColor.opacity(0.28 + 0.50 * intensity)))
            glow.fill(Path(ellipseIn: core.insetBy(dx: radius * 0.35, dy: radius * 0.35)),
                      with: .color(Color.white.opacity(0.18 + 0.42 * intensity)))
            let halo = core.insetBy(dx: -radius * 2.4, dy: -radius * 2.4)
            glow.fill(Path(ellipseIn: halo),
                      with: .radialGradient(Gradient(colors: [lampColor.opacity(0.30 * intensity),
                                                              lampColor.opacity(0)]),
                                            center: point,
                                            startRadius: 0,
                                            endRadius: halo.width / 2))
        }
    }

    /// Four measured light bars circulate through the reinforced window rails.
    /// Their long travel and deliberately different periods keep the cockpit
    /// alive without turning the frame into a flashing marquee.
    private func drawHullEnergyFlow(in context: GraphicsContext,
                                    window: CGRect,
                                    time: TimeInterval) {
        let horizontalLength = min(window.width * 0.16, isPad ? 150 : 92)
        let verticalLength = min(window.height * 0.18, isPad ? 110 : 66)
        let thickness: CGFloat = isPad ? 3.4 : 2.2
        let topY = window.minY - frameWidth * 0.53
        let bottomY = window.maxY + frameWidth * 0.58
        let leftX = window.minX - frameWidth * 0.55
        let rightX = window.maxX + frameWidth * 0.55

        let topProgress = CGFloat(cockpitWrap(time * 0.090))
        let bottomProgress = CGFloat(cockpitWrap(1 - time * 0.074))
        let leftProgress = CGFloat(cockpitWrap(time * 0.068 + 0.24))
        let rightProgress = CGFloat(cockpitWrap(1 - time * 0.061 + 0.68))

        let horizontalClip = CGRect(x: window.minX,
                                    y: topY - thickness * 4,
                                    width: window.width,
                                    height: bottomY - topY + thickness * 8)
        context.drawLayer { rails in
            rails.clip(to: Path(horizontalClip))

            let topX = window.minX - horizontalLength * 0.5
                + (window.width + horizontalLength) * topProgress
            drawEnergyBar(in: rails,
                          centre: CGPoint(x: topX, y: topY),
                          length: horizontalLength,
                          thickness: thickness,
                          vertical: false,
                          color: cyan,
                          opacity: 0.78)

            let bottomX = window.minX - horizontalLength * 0.5
                + (window.width + horizontalLength) * bottomProgress
            drawEnergyBar(in: rails,
                          centre: CGPoint(x: bottomX, y: bottomY),
                          length: horizontalLength * 0.86,
                          thickness: thickness,
                          vertical: false,
                          color: orange,
                          opacity: 0.72)
        }

        let verticalClip = CGRect(x: leftX - thickness * 4,
                                  y: window.minY,
                                  width: rightX - leftX + thickness * 8,
                                  height: window.height)
        context.drawLayer { rails in
            rails.clip(to: Path(verticalClip))

            let leftY = window.minY - verticalLength * 0.5
                + (window.height + verticalLength) * leftProgress
            drawEnergyBar(in: rails,
                          centre: CGPoint(x: leftX, y: leftY),
                          length: verticalLength,
                          thickness: thickness,
                          vertical: true,
                          color: cyan,
                          opacity: 0.66)

            let rightY = window.minY - verticalLength * 0.5
                + (window.height + verticalLength) * rightProgress
            drawEnergyBar(in: rails,
                          centre: CGPoint(x: rightX, y: rightY),
                          length: verticalLength,
                          thickness: thickness,
                          vertical: true,
                          color: cyan,
                          opacity: 0.66)
        }
    }

    /// Paints one soft-edged power segment with a narrow white-hot centre.
    private func drawEnergyBar(in context: GraphicsContext,
                               centre: CGPoint,
                               length: CGFloat,
                               thickness: CGFloat,
                               vertical: Bool,
                               color: Color,
                               opacity: Double) {
        let rect = CGRect(x: centre.x - (vertical ? thickness : length) * 0.5,
                          y: centre.y - (vertical ? length : thickness) * 0.5,
                          width: vertical ? thickness : length,
                          height: vertical ? length : thickness)
        let glowRect = rect.insetBy(dx: -thickness * 2.2, dy: -thickness * 2.2)
        let start = vertical
            ? CGPoint(x: centre.x, y: rect.minY)
            : CGPoint(x: rect.minX, y: centre.y)
        let end = vertical
            ? CGPoint(x: centre.x, y: rect.maxY)
            : CGPoint(x: rect.maxX, y: centre.y)
        let gradient = Gradient(colors: [color.opacity(0),
                                         color.opacity(opacity * 0.75),
                                         .white.opacity(opacity),
                                         color.opacity(opacity * 0.75),
                                         color.opacity(0)])

        var glow = context
        glow.blendMode = .plusLighter
        glow.fill(Path(roundedRect: glowRect, cornerRadius: thickness * 2.5),
                  with: .color(color.opacity(opacity * 0.12)))
        glow.fill(Path(roundedRect: rect, cornerRadius: thickness * 0.5),
                  with: .linearGradient(gradient, startPoint: start, endPoint: end))
    }

    private func controlLampColor(for feedback: HoopFeedback) -> Color {
        switch feedback {
        case .correct, .revealedCorrect, .bonus:
            return Color(red: 0.20, green: 0.95, blue: 0.50)
        case .wrong:
            return Color(red: 1.00, green: 0.48, blue: 0.22)
        case .none, .inactive, .bypassed:
            return orange
        }
    }

    // MARK: Hull

    private func drawRoof(in context: GraphicsContext, size: CGSize, window: CGRect) {
        let bottom = layout.ceilingJointY
        guard bottom > 0 else { return }
        let leftControlX = layout.buttonPoints.first?.x ?? layout.leftEdge
        let rightControlX = layout.buttonPoints
            .dropFirst(GameConfig.answerColumnCount).first?.x ?? layout.rightEdge
        let leftJoin = leftControlX - layout.buttonSize * 0.58
        let rightJoin = rightControlX + layout.buttonSize * 0.58
        let leftOuterBottom = max(0,
                                  sideWallCanvasY(backY: bottom,
                                                  innerX: leftJoin,
                                                  outerX: -2,
                                                  canvasX: 0))
        let rightOuterBottom = max(0,
                                   sideWallCanvasY(backY: bottom,
                                                   innerX: rightJoin,
                                                   outerX: size.width + 2,
                                                   canvasX: size.width))

        // Mirror of the deck polygon: the rear edge stays level above the
        // windscreen and controls, while both near edges climb toward the top
        // corners. This is the ceiling/wall joint of the cockpit box.
        var ceilingShape = Path()
        ceilingShape.move(to: CGPoint(x: 0, y: leftOuterBottom))
        ceilingShape.addLine(to: CGPoint(x: leftJoin, y: bottom))
        ceilingShape.addLine(to: CGPoint(x: rightJoin, y: bottom))
        ceilingShape.addLine(to: CGPoint(x: size.width, y: rightOuterBottom))
        ceilingShape.addLine(to: CGPoint(x: size.width, y: 0))
        ceilingShape.addLine(to: .zero)
        ceilingShape.closeSubpath()

        var ceiling = context
        ceiling.clip(to: ceilingShape)
        ceiling.fill(ceilingShape,
                     with: .linearGradient(Gradient(colors: [metalDark, metal, metalLight]),
                                           startPoint: .zero,
                                           endPoint: CGPoint(x: 0, y: bottom)))
        for fraction in [0.34, 0.68] as [CGFloat] {
            seam(ceiling,
                 from: CGPoint(x: 0, y: bottom * fraction),
                 to: CGPoint(x: size.width, y: bottom * fraction))
        }
        for fraction in stride(from: CGFloat(0.2), through: 0.8, by: 0.2) {
            seam(ceiling,
                 from: CGPoint(x: size.width * fraction, y: bottom * 0.68),
                 to: CGPoint(x: size.width * fraction, y: bottom))
        }
        var ceilingJoint = Path()
        ceilingJoint.move(to: CGPoint(x: 0, y: leftOuterBottom))
        ceilingJoint.addLine(to: CGPoint(x: leftJoin, y: bottom))
        ceilingJoint.addLine(to: CGPoint(x: rightJoin, y: bottom))
        ceilingJoint.addLine(to: CGPoint(x: size.width, y: rightOuterBottom))
        context.stroke(ceilingJoint, with: .color(.black.opacity(0.92)),
                       lineWidth: isPad ? 10 : 7)
        context.stroke(ceilingJoint, with: .color(metalLight.opacity(0.62)),
                       lineWidth: isPad ? 4 : 2.8)
        context.stroke(ceilingJoint, with: .color(cyan.opacity(0.30)),
                       lineWidth: isPad ? 1.5 : 1)
    }

    /// A shallow equipment header between the ceiling joint and the recessed
    /// glass. It gives the lowered viewport a structural reason to sit there
    /// and replaces the previous featureless black strip with cockpit detail.
    private func drawUpperWindowHeader(in context: GraphicsContext,
                                       window: CGRect,
                                       cut: CGFloat) {
        let top = layout.ceilingJointY
        let bottom = window.minY - frameWidth * 0.5
        guard bottom > top + 1 else { return }

        let shoulder = min(cut * 0.42, window.width * 0.045)
        var header = Path()
        header.move(to: CGPoint(x: layout.leftEdge, y: top))
        header.addLine(to: CGPoint(x: layout.rightEdge, y: top))
        header.addLine(to: CGPoint(x: window.maxX - shoulder, y: bottom))
        header.addLine(to: CGPoint(x: window.minX + shoulder, y: bottom))
        header.closeSubpath()

        context.fill(header,
                     with: .linearGradient(
                        Gradient(colors: [metalLight.opacity(0.78),
                                          metal,
                                          metalDark]),
                        startPoint: CGPoint(x: 0, y: top),
                        endPoint: CGPoint(x: 0, y: bottom)))
        context.stroke(header, with: .color(.black.opacity(0.86)),
                       lineWidth: isPad ? 3.2 : 2.2)

        var highlight = Path()
        highlight.move(to: CGPoint(x: layout.leftEdge, y: top + 0.75))
        highlight.addLine(to: CGPoint(x: layout.rightEdge, y: top + 0.75))
        context.stroke(highlight, with: .color(.white.opacity(0.30)),
                       lineWidth: isPad ? 1.8 : 1.2)

    }

    private func drawVent(_ context: GraphicsContext, rect: CGRect) {
        guard rect.width > 8, rect.height > 8 else { return }
        context.fill(Path(roundedRect: rect, cornerRadius: 3),
                     with: .color(.black.opacity(0.45)))
        let slots = 5
        let gap = rect.height / CGFloat(slots * 2)
        for slot in 0..<slots {
            let y = rect.minY + gap + CGFloat(slot) * gap * 2
            let bar = CGRect(x: rect.minX + 3, y: y, width: rect.width - 6, height: max(1.5, gap * 0.45))
            context.fill(Path(roundedRect: bar, cornerRadius: 1),
                         with: .color(metalLight.opacity(0.35)))
        }
    }

    private func drawColumn(in context: GraphicsContext,
                            size: CGSize,
                            minX: CGFloat,
                            maxX: CGFloat,
                            innerIsTrailing: Bool,
                            window: CGRect) {
        guard maxX > minX else { return }
        let innerX = innerIsTrailing ? maxX : minX
        let outerX = innerIsTrailing ? minX : maxX
        let outward: CGFloat = innerIsTrailing ? -1 : 1
        let towardInner = -outward
        let buttonSize = layout.buttonSize
        let mounts = layout.buttonPoints.enumerated().filter { $0.element.x > minX && $0.element.x < maxX }
        let points = mounts.map(\.element)
        guard let first = points.first else { return }

        // The answer rack is part of the rear wall and therefore stays truly
        // vertical. The room depth lives outside it: lines on the side wall
        // spread toward the viewer (the screen edge) and converge toward the
        // centre of the rear viewport.
        let controlX = first.x
        let outerModuleX = controlX + outward * buttonSize * 0.58
        let innerModuleX = controlX + towardInner * buttonSize * 0.58
        let vanishingY = window.midY
        let frontSpread = sideWallFrontSpread
        let wallTop = layout.ceilingJointY
        let wallBottom = layout.floorTop
        let wallHeight = max(1, wallBottom - wallTop)

        func frontY(for backY: CGFloat) -> CGFloat {
            vanishingY + (backY - vanishingY) * frontSpread
        }

        /// `depth` is zero at the near, cropped screen edge and one at the
        /// rear wall beside the answer rack.
        func wallPoint(backY: CGFloat, depth: CGFloat) -> CGPoint {
            let nearY = frontY(for: backY)
            return CGPoint(x: outerX + (outerModuleX - outerX) * depth,
                           y: nearY + (backY - nearY) * depth)
        }

        // One closed side wall. It reaches beyond the canvas at the near edge
        // so no strip of the star field can read as an accidental side window.
        var sideWall = Path()
        sideWall.move(to: wallPoint(backY: wallTop, depth: 0))
        sideWall.addLine(to: wallPoint(backY: wallTop, depth: 1))
        sideWall.addLine(to: wallPoint(backY: wallBottom, depth: 1))
        sideWall.addLine(to: wallPoint(backY: wallBottom, depth: 0))
        sideWall.closeSubpath()
        context.fill(sideWall,
                     with: .linearGradient(
                        Gradient(colors: innerIsTrailing
                                 ? [Color(red: 0.015, green: 0.025, blue: 0.065),
                                    Color(red: 0.16, green: 0.22, blue: 0.40),
                                    Color(red: 0.035, green: 0.055, blue: 0.14)]
                                 : [Color(red: 0.035, green: 0.055, blue: 0.14),
                                    Color(red: 0.16, green: 0.22, blue: 0.40),
                                    Color(red: 0.015, green: 0.025, blue: 0.065)]),
                        startPoint: CGPoint(x: outerX, y: vanishingY),
                        endPoint: CGPoint(x: outerModuleX, y: vanishingY)))

        // Broad wall facets share the same vanishing point. First paint the
        // complete surface, then lay one continuous recessed power bus over
        // it. Structural ribs are redrawn last, so the bus passes convincingly
        // behind the wall construction instead of colliding with it.
        let facetStops: [CGFloat] = [0, 0.235, 0.50, 0.765, 1]
        for index in 0..<(facetStops.count - 1) {
            let backTop = wallTop + wallHeight * facetStops[index]
            let backBottom = wallTop + wallHeight * facetStops[index + 1]
            var facet = Path()
            facet.move(to: wallPoint(backY: backTop, depth: 0))
            facet.addLine(to: wallPoint(backY: backTop, depth: 1))
            facet.addLine(to: wallPoint(backY: backBottom, depth: 1))
            facet.addLine(to: wallPoint(backY: backBottom, depth: 0))
            facet.closeSubpath()
            context.fill(facet,
                         with: .linearGradient(
                            Gradient(colors: index.isMultiple(of: 2)
                                     ? [Color(red: 0.025, green: 0.045, blue: 0.12),
                                        Color(red: 0.17, green: 0.25, blue: 0.46),
                                        Color(red: 0.045, green: 0.08, blue: 0.20)]
                                     : [Color(red: 0.012, green: 0.025, blue: 0.07),
                                        Color(red: 0.09, green: 0.16, blue: 0.32),
                                        Color(red: 0.020, green: 0.04, blue: 0.105)]),
                            startPoint: wallPoint(backY: backTop, depth: 0.06),
                            endPoint: wallPoint(backY: backBottom, depth: 0.94)))
        }

        let busDepth: CGFloat = 0.50
        let busInset = wallHeight * 0.045
        var powerBus = Path()
        powerBus.move(to: wallPoint(backY: wallTop + busInset, depth: busDepth))
        powerBus.addLine(to: wallPoint(backY: wallBottom - busInset,
                                      depth: busDepth + 0.025))
        context.stroke(powerBus, with: .color(.black.opacity(0.86)),
                       lineWidth: isPad ? 13 : 8)
        context.stroke(powerBus, with: .color(metalLight.opacity(0.34)),
                       lineWidth: isPad ? 7 : 4.5)
        var busGlow = context
        busGlow.blendMode = .plusLighter
        busGlow.stroke(powerBus, with: .color(cyan.opacity(0.24)),
                       lineWidth: isPad ? 4 : 2.5)
        context.stroke(powerBus, with: .color(cyan.opacity(0.72)),
                       lineWidth: isPad ? 1.4 : 0.9)

        for index in 0..<(facetStops.count - 1) {
            let backTop = wallTop + wallHeight * facetStops[index]
            let backBottom = wallTop + wallHeight * facetStops[index + 1]
            let bandHeight = backBottom - backTop
            let circuitTop = backTop + bandHeight * 0.22
            let circuitBottom = backBottom - bandHeight * 0.22
            let circuitColor = index.isMultiple(of: 2) ? cyan : orange

            // Branches and their illuminated terminals are sized from their
            // own facet. They never enter the empty margin beside a rib.
            for branch in 0..<3 {
                let progress = (CGFloat(branch) + 1) / 4
                let branchY = circuitTop + (circuitBottom - circuitTop) * progress
                let start = wallPoint(backY: branchY, depth: busDepth)
                let endDepth: CGFloat = branch == 1 ? 0.20 : 0.27
                let end = wallPoint(backY: branchY, depth: endDepth)
                var trace = Path()
                trace.move(to: start)
                trace.addLine(to: end)
                context.stroke(trace, with: .color(.black.opacity(0.88)),
                               style: StrokeStyle(lineWidth: isPad ? 7 : 4.5,
                                                  lineCap: .round))
                context.stroke(trace,
                               with: .color(circuitColor.opacity(branch == 1 ? 0.92 : 0.62)),
                               style: StrokeStyle(lineWidth: isPad ? 2.2 : 1.4,
                                                  lineCap: .round))

                let nodeRadius: CGFloat = isPad ? 3.2 : 2.1
                let node = Path(ellipseIn: CGRect(x: end.x - nodeRadius,
                                                  y: end.y - nodeRadius,
                                                  width: nodeRadius * 2,
                                                  height: nodeRadius * 2))
                busGlow.fill(node, with: .color(circuitColor.opacity(0.55)))
                context.fill(node, with: .color(.white.opacity(0.76)))
            }

            guard index > 0 else { continue }
            let seamY = backTop
            var rib = Path()
            rib.move(to: wallPoint(backY: seamY, depth: 0))
            rib.addLine(to: wallPoint(backY: seamY, depth: 0.98))
            context.stroke(rib, with: .color(.black.opacity(0.90)),
                           lineWidth: isPad ? 11 : 7)
            context.stroke(rib, with: .color(metalLight.opacity(0.50)),
                           lineWidth: isPad ? 4.2 : 2.8)
            context.stroke(rib.offsetBy(dx: 0, dy: -1.4),
                           with: .color(index == 2 ? cyan.opacity(0.46) : orange.opacity(0.30)),
                           lineWidth: isPad ? 1.8 : 1.1)
        }

        // A compact rear-wall equipment recess carries all three buttons. It
        // ends just beyond the first and last module instead of becoming a
        // floor-to-ceiling bar.
        let bankTop = max(0, first.y - buttonSize * 0.60)
        let bankBottom = wallBottom
        let bayMinX = min(outerModuleX, innerX)
        let bayMaxX = max(outerModuleX, innerX)
        let bayRect = CGRect(x: bayMinX,
                             y: bankTop,
                             width: bayMaxX - bayMinX,
                             height: bankBottom - bankTop)
        let bayCut = min(buttonSize * 0.18, bayRect.width * 0.22)
        let bay = chamfered(bayRect, cut: bayCut)
        context.fill(bay,
                     with: .linearGradient(
                        Gradient(colors: [Color(red: 0.10, green: 0.15, blue: 0.29),
                                          Color(red: 0.018, green: 0.03, blue: 0.085),
                                          Color(red: 0.06, green: 0.09, blue: 0.19)]),
                        startPoint: CGPoint(x: outerModuleX, y: bankTop),
                        endPoint: CGPoint(x: innerX, y: bankBottom)))

        // Short top and bottom returns reveal the thickness of the vertical
        // rack; there are intentionally no full-height side rails.
        let capDepth = min(buttonSize * 0.12, isPad ? 20 : 14)
        for (y, direction) in [(bankTop, CGFloat(1)), (bankBottom, CGFloat(-1))] {
            var cap = Path()
            cap.move(to: CGPoint(x: outerModuleX, y: y))
            cap.addLine(to: CGPoint(x: innerX, y: y))
            cap.addLine(to: CGPoint(x: innerX - towardInner * capDepth * 0.22,
                                    y: y + direction * capDepth))
            cap.addLine(to: CGPoint(x: outerModuleX + towardInner * capDepth * 0.34,
                                    y: y + direction * capDepth))
            cap.closeSubpath()
            context.fill(cap,
                         with: .linearGradient(
                            Gradient(colors: direction > 0
                                     ? [.white.opacity(0.30), metal.opacity(0.70), .black.opacity(0.78)]
                                     : [metal.opacity(0.58), .black.opacity(0.95)]),
                            startPoint: CGPoint(x: 0, y: y),
                            endPoint: CGPoint(x: 0, y: y + direction * capDepth)))
            context.stroke(cap, with: .color(.black.opacity(0.78)),
                           lineWidth: isPad ? 2.5 : 1.6)
        }

        let frameX = innerIsTrailing
            ? window.minX - frameWidth * 0.5
            : window.maxX + frameWidth * 0.5

        for (index, mount) in mounts.enumerated() {
            let point = mount.element

            if point.y > window.minY + frameWidth, point.y < window.maxY - frameWidth {
                drawConduits(in: context, from: innerModuleX, to: frameX,
                             y: point.y)
            }

            drawButtonMount(in: context, at: point, size: buttonSize)

            guard index + 1 < points.count else { continue }
            let between = (point.y + points[index + 1].y) / 2
            let bridgeStart = CGPoint(x: outerModuleX + towardInner * buttonSize * 0.08,
                                      y: between)
            let bridgeEnd = CGPoint(x: innerModuleX, y: between)
            seam(context, from: bridgeStart, to: bridgeEnd)
            let bridgeWidth = abs(bridgeEnd.x - bridgeStart.x)
            lightBar(context,
                     center: CGPoint(x: (bridgeStart.x + bridgeEnd.x) / 2, y: between),
                     length: min(buttonSize * 0.24, bridgeWidth * 0.55),
                     thickness: isPad ? 3.5 : 2.5,
                     color: cyan,
                     vertical: false)
        }
    }

    /// The octagonal plate, fixed lamp groove and recessed well are part of the
    /// wall. The live cap and stationary indicator lamps sit over this socket.
    private func drawButtonMount(in context: GraphicsContext,
                                 at point: CGPoint,
                                 size buttonSize: CGFloat) {
        var glow = context
        glow.blendMode = .plusLighter
        let flange = CGRect(x: point.x - buttonSize * 0.56,
                            y: point.y - buttonSize * 0.56,
                            width: buttonSize * 1.12,
                            height: buttonSize * 1.12)
        let plate = CGRect(x: point.x - buttonSize * 0.5,
                           y: point.y - buttonSize * 0.5,
                           width: buttonSize,
                           height: buttonSize)
        let flangePath = chamfered(flange, cut: buttonSize * 0.28)
        let platePath = chamfered(plate, cut: buttonSize * 0.24)

        context.fill(flangePath,
                     with: .linearGradient(Gradient(colors: [metalDark, metal]),
                                           startPoint: CGPoint(x: 0, y: flange.minY),
                                           endPoint: CGPoint(x: 0, y: flange.maxY)))
        context.stroke(flangePath, with: .color(.black.opacity(0.7)), lineWidth: 2)

        context.fill(platePath,
                     with: .linearGradient(Gradient(colors: [metalLight, metal, metalDark]),
                                           startPoint: CGPoint(x: 0, y: plate.minY),
                                           endPoint: CGPoint(x: 0, y: plate.maxY)))
        context.stroke(platePath, with: .color(.black.opacity(0.75)), lineWidth: 2.2)
        context.stroke(chamfered(plate.insetBy(dx: buttonSize * 0.035, dy: buttonSize * 0.035),
                                 cut: buttonSize * 0.20),
                       with: .linearGradient(Gradient(colors: [.white.opacity(0.28), .white.opacity(0.04)]),
                                             startPoint: CGPoint(x: 0, y: plate.minY),
                                             endPoint: CGPoint(x: 0, y: plate.maxY)),
                       lineWidth: 1)

        glow.stroke(platePath, with: .color(cyan.opacity(0.12)), lineWidth: isPad ? 8 : 5)

        let trackRadius = buttonSize * 0.385
        let track = CGRect(x: point.x - trackRadius, y: point.y - trackRadius,
                           width: trackRadius * 2, height: trackRadius * 2)
        context.stroke(Path(ellipseIn: track),
                       with: .color(.black.opacity(0.78)),
                       lineWidth: buttonSize * 0.09)
        context.stroke(Path(ellipseIn: track),
                       with: .color(Color(red: 0.16, green: 0.10, blue: 0.05)),
                       lineWidth: buttonSize * 0.055)
        glow.stroke(Path(ellipseIn: track),
                    with: .color(orange.opacity(0.55)),
                    lineWidth: buttonSize * 0.028)

        for inset in [0.33, 0.41] as [CGFloat] {
            let ringRadius = buttonSize * inset
            let ring = CGRect(x: point.x - ringRadius, y: point.y - ringRadius,
                              width: ringRadius * 2, height: ringRadius * 2)
            context.stroke(Path(ellipseIn: ring),
                           with: .color(.white.opacity(inset < 0.36 ? 0.20 : 0.10)),
                           lineWidth: 1)
        }

        let wellRadius = buttonSize * 0.30
        let well = CGRect(x: point.x - wellRadius, y: point.y - wellRadius,
                          width: wellRadius * 2, height: wellRadius * 2)
        context.fill(Path(ellipseIn: well.insetBy(dx: -buttonSize * 0.02, dy: -buttonSize * 0.02)),
                     with: .color(.black.opacity(0.55)))
        context.fill(Path(ellipseIn: well),
                     with: .radialGradient(Gradient(colors: [Color(red: 0.01, green: 0.02, blue: 0.06),
                                                             Color(red: 0.05, green: 0.07, blue: 0.14)]),
                                           center: point,
                                           startRadius: 0,
                                           endRadius: wellRadius))
        context.stroke(Path(ellipseIn: well),
                       with: .linearGradient(Gradient(colors: [metalLight, metalDark]),
                                             startPoint: CGPoint(x: 0, y: well.minY),
                                             endPoint: CGPoint(x: 0, y: well.maxY)),
                       lineWidth: isPad ? 3 : 2)

        let boltRadius = max(1.4, buttonSize * 0.028)
        let inset = buttonSize * 0.14
        for boltPoint in [CGPoint(x: plate.minX + inset, y: plate.minY + inset),
                          CGPoint(x: plate.maxX - inset, y: plate.minY + inset),
                          CGPoint(x: plate.minX + inset, y: plate.maxY - inset),
                          CGPoint(x: plate.maxX - inset, y: plate.maxY - inset)] {
            let bolt = Path(ellipseIn: CGRect(x: boltPoint.x - boltRadius,
                                              y: boltPoint.y - boltRadius,
                                              width: boltRadius * 2,
                                              height: boltRadius * 2))
            context.fill(bolt, with: .color(metalLight))
            context.stroke(bolt, with: .color(.black.opacity(0.65)), lineWidth: 0.8)
        }
    }

    /// Repeats the sill's navigation-light rhythm across the complete room
    /// joints, including both perspective shoulders. A nil phase draws only
    /// the recessed structural carriers; a live phase moves their lamps in
    /// opposite directions across the ceiling and floor.
    private func drawBoundaryLightChains(in context: GraphicsContext,
                                         size: CGSize,
                                         phase: CGFloat?) {
        let leftControlX = layout.buttonPoints.first?.x ?? layout.leftEdge
        let rightControlX = layout.buttonPoints
            .dropFirst(GameConfig.answerColumnCount).first?.x ?? layout.rightEdge
        let leftJoin = leftControlX - layout.buttonSize * 0.58
        let rightJoin = rightControlX + layout.buttonSize * 0.58

        let upperBackY = layout.ceilingJointY
        let upperLeftY = sideWallCanvasY(backY: upperBackY,
                                         innerX: leftJoin,
                                         outerX: -2,
                                         canvasX: 0)
        let upperRightY = sideWallCanvasY(backY: upperBackY,
                                          innerX: rightJoin,
                                          outerX: size.width + 2,
                                          canvasX: size.width)
        let upperInset: CGFloat = isPad ? 7 : 4.5
        drawLightChain(in: context,
                       points: [CGPoint(x: 0, y: upperLeftY + upperInset),
                                CGPoint(x: leftJoin, y: upperBackY + upperInset),
                                CGPoint(x: rightJoin, y: upperBackY + upperInset),
                                CGPoint(x: size.width, y: upperRightY + upperInset)],
                       startsWithWarmLight: true,
                       phase: phase)

        let lowerBackY = layout.floorTop
        let lowerLeftY = sideWallCanvasY(backY: lowerBackY,
                                         innerX: leftJoin,
                                         outerX: -2,
                                         canvasX: 0)
        let lowerRightY = sideWallCanvasY(backY: lowerBackY,
                                          innerX: rightJoin,
                                          outerX: size.width + 2,
                                          canvasX: size.width)
        let lowerInset: CGFloat = isPad ? 8 : 5
        drawLightChain(in: context,
                       points: [CGPoint(x: 0, y: lowerLeftY - lowerInset),
                                CGPoint(x: leftJoin, y: lowerBackY - lowerInset),
                                CGPoint(x: rightJoin, y: lowerBackY - lowerInset),
                                CGPoint(x: size.width, y: lowerRightY - lowerInset)],
                       startsWithWarmLight: false,
                       phase: phase.map { -$0 })
    }

    private func drawLightChain(in context: GraphicsContext,
                                points: [CGPoint],
                                startsWithWarmLight: Bool,
                                phase: CGFloat?) {
        guard points.count > 1 else { return }
        let preferredDash: CGFloat = isPad ? 74 : 31
        let preferredGap: CGFloat = isPad ? 44 : 19
        let thickness: CGFloat = isPad ? 5.6 : 2.2
        if let phase {
            drawMovingLightChain(in: context,
                                 points: points,
                                 dashLength: preferredDash,
                                 gapLength: preferredGap,
                                 thickness: thickness,
                                 phase: phase,
                                 startsWithWarmLight: startsWithWarmLight)
            return
        }

        // The lamps sit in one continuous recessed carrier. Even where a pulse
        // passes, this strip keeps the edge mechanically connected.
        var carrier = Path()
        carrier.move(to: points[0])
        for point in points.dropFirst() { carrier.addLine(to: point) }
        let carrierStyle = StrokeStyle(lineWidth: thickness * 3.4,
                                       lineCap: .round,
                                       lineJoin: .round)
        context.stroke(carrier, with: .color(.black.opacity(0.88)),
                       style: carrierStyle)
        context.stroke(carrier, with: .color(metalLight.opacity(0.58)),
                       style: StrokeStyle(lineWidth: thickness * 2.25,
                                          lineCap: .round,
                                          lineJoin: .round))
        context.stroke(carrier, with: .color(metalDark.opacity(0.96)),
                       style: StrokeStyle(lineWidth: thickness * 1.35,
                                          lineCap: .round,
                                          lineJoin: .round))
        var carrierGlow = context
        carrierGlow.blendMode = .plusLighter
        carrierGlow.stroke(carrier, with: .color(cyan.opacity(0.14)),
                           style: StrokeStyle(lineWidth: thickness * 0.70,
                                              lineCap: .round,
                                              lineJoin: .round))
    }

    /// One dashed stroke animates the complete chain. Core Graphics advances
    /// its dash phase along the path itself, which makes every LED move through
    /// both corners while costing only a handful of strokes per frame.
    private func drawMovingLightChain(in context: GraphicsContext,
                                      points: [CGPoint],
                                      dashLength: CGFloat,
                                      gapLength: CGFloat,
                                      thickness: CGFloat,
                                      phase: CGFloat,
                                      startsWithWarmLight: Bool) {
        var rail = Path()
        rail.move(to: points[0])
        for point in points.dropFirst() { rail.addLine(to: point) }

        let totalLength = zip(points, points.dropFirst()).reduce(CGFloat.zero) { total, pair in
            total + hypot(pair.1.x - pair.0.x, pair.1.y - pair.0.y)
        }
        let interval = dashLength + gapLength
        // Both colour patterns repeat after five dash/gap intervals. The
        // animation phase itself wraps from one back to zero, so travelling by
        // an arbitrary path length caused a visible jump at that boundary.
        // Cover approximately the same distance as before, but round it to a
        // whole number of pattern repeats so the first and last frame match.
        let patternLength = interval * 5
        let repeatCount = max(CGFloat(1), (totalLength / patternLength).rounded())
        let seamlessTravelLength = patternLength * repeatCount
        let travel = phase * seamlessTravelLength
        let commonPhase = -travel + (startsWithWarmLight ? interval * 0.5 : 0)

        // Four cool lamps followed by one warm lamp. Both patterns share the
        // exact same phase, so the colour sequence travels as one solid train.
        let coolPattern = [dashLength, gapLength,
                           dashLength, gapLength,
                           dashLength, gapLength,
                           dashLength, gapLength + dashLength + gapLength]
        let warmPattern = [dashLength, interval * 4 + gapLength]
        let coolStyle = StrokeStyle(lineWidth: thickness,
                                    lineCap: .round,
                                    lineJoin: .round,
                                    dash: coolPattern,
                                    dashPhase: commonPhase)
        let warmStyle = StrokeStyle(lineWidth: thickness,
                                    lineCap: .round,
                                    lineJoin: .round,
                                    dash: warmPattern,
                                    dashPhase: commonPhase + interval)

        var glow = context
        glow.blendMode = .plusLighter
        glow.stroke(rail, with: .color(cyan.opacity(0.34)),
                    style: movingDashStyle(from: coolStyle,
                                           lineWidth: thickness * 4.0))
        glow.stroke(rail, with: .color(orange.opacity(0.38)),
                    style: movingDashStyle(from: warmStyle,
                                           lineWidth: thickness * 4.0))
        context.stroke(rail, with: .color(cyan.opacity(0.96)), style: coolStyle)
        context.stroke(rail, with: .color(orange.opacity(0.98)), style: warmStyle)
        context.stroke(rail, with: .color(.white.opacity(0.46)),
                       style: movingDashStyle(from: coolStyle,
                                              lineWidth: max(0.7, thickness * 0.28)))
        context.stroke(rail, with: .color(.white.opacity(0.52)),
                       style: movingDashStyle(from: warmStyle,
                                              lineWidth: max(0.7, thickness * 0.28)))
    }

    private func movingDashStyle(from style: StrokeStyle,
                                 lineWidth: CGFloat) -> StrokeStyle {
        StrokeStyle(lineWidth: lineWidth,
                    lineCap: style.lineCap,
                    lineJoin: style.lineJoin,
                    miterLimit: style.miterLimit,
                    dash: style.dash,
                    dashPhase: style.dashPhase)
    }

    private func drawSill(in context: GraphicsContext, window: CGRect, floorTop: CGFloat) {
        let top = window.maxY + frameWidth * 0.5
        guard floorTop > top, layout.rightEdge > layout.leftEdge else { return }
        let sill = CGRect(x: layout.leftEdge, y: top,
                          width: layout.rightEdge - layout.leftEdge,
                          height: floorTop - top)
        context.fill(Path(sill),
                     with: .linearGradient(Gradient(colors: [metal, metalDark]),
                                           startPoint: CGPoint(x: 0, y: sill.minY),
                                           endPoint: CGPoint(x: 0, y: sill.maxY)))
        seam(context, from: CGPoint(x: sill.minX, y: sill.minY),
             to: CGPoint(x: sill.maxX, y: sill.minY))

        var lip = Path()
        lip.move(to: CGPoint(x: sill.minX, y: sill.maxY - 0.75))
        lip.addLine(to: CGPoint(x: sill.maxX, y: sill.maxY - 0.75))
        var glow = context
        glow.blendMode = .plusLighter
        glow.stroke(lip, with: .color(orange.opacity(0.35)), lineWidth: 5)
        context.stroke(lip, with: .color(orange), lineWidth: 1.5)
    }

    private func drawFloor(in context: GraphicsContext, size: CGSize, top: CGFloat, time: TimeInterval) {
        let bottom = size.height
        guard bottom > top else { return }
        let depth = bottom - top
        let leftControlX = layout.buttonPoints.first?.x ?? layout.leftEdge
        let rightControlX = layout.buttonPoints
            .dropFirst(GameConfig.answerColumnCount).first?.x ?? layout.rightEdge
        let leftJoin = leftControlX - layout.buttonSize * 0.58
        let rightJoin = rightControlX + layout.buttonSize * 0.58
        // Continue the exact perspective projection used by `drawColumn`.
        // Each edge is calculated separately so asymmetric safe-area layouts
        // still meet both side walls pixel-for-pixel.
        let leftOuterTop = min(bottom,
                               sideWallCanvasY(backY: top,
                                               innerX: leftJoin,
                                               outerX: -2,
                                               canvasX: 0))
        let rightOuterTop = min(bottom,
                                sideWallCanvasY(backY: top,
                                                innerX: rightJoin,
                                                outerX: size.width + 2,
                                                canvasX: size.width))

        // The back edge stays level beneath the controls and windscreen. At
        // both sides it advances toward the viewer, producing the two diagonal
        // wall/floor joints that make this a room rather than a flat stripe.
        var floorShape = Path()
        floorShape.move(to: CGPoint(x: 0, y: leftOuterTop))
        floorShape.addLine(to: CGPoint(x: leftJoin, y: top))
        floorShape.addLine(to: CGPoint(x: rightJoin, y: top))
        floorShape.addLine(to: CGPoint(x: size.width, y: rightOuterTop))
        floorShape.addLine(to: CGPoint(x: size.width, y: bottom))
        floorShape.addLine(to: CGPoint(x: 0, y: bottom))
        floorShape.closeSubpath()

        var deck = context
        deck.clip(to: floorShape)
        deck.fill(floorShape,
                  with: .linearGradient(Gradient(colors: [Color(red: 0.16, green: 0.24, blue: 0.46),
                                                          Color(red: 0.07, green: 0.11, blue: 0.25),
                                                          Color(red: 0.02, green: 0.04, blue: 0.11)]),
                                        startPoint: CGPoint(x: 0, y: top),
                                        endPoint: CGPoint(x: 0, y: bottom)))

        var glow = deck
        glow.blendMode = .plusLighter
        let sheen = CGRect(x: size.width * 0.18, y: top - depth * 0.3,
                           width: size.width * 0.64, height: depth * 0.9)
        glow.fill(Path(ellipseIn: sheen),
                  with: .radialGradient(Gradient(colors: [cyan.opacity(0.14), cyan.opacity(0)]),
                                        center: CGPoint(x: sheen.midX, y: sheen.midY),
                                        startRadius: 0,
                                        endRadius: sheen.width * 0.5))

        // Layered shoulder consoles fill the space freed by the lifted answer
        // banks. Their converging edges carry the side cabinets into the floor
        // instead of ending at a flat horizontal strip.
        for side in [-1.0, 1.0] as [CGFloat] {
            let isLeft = side < 0
            let outer = isLeft ? CGFloat(0) : size.width
            let innerTop = size.width * (isLeft ? 0.31 : 0.69)
            let innerBottom = size.width * (isLeft ? 0.22 : 0.78)
            var shoulder = Path()
            shoulder.move(to: CGPoint(x: outer, y: top))
            shoulder.addLine(to: CGPoint(x: innerTop, y: top))
            shoulder.addLine(to: CGPoint(x: innerBottom, y: bottom))
            shoulder.addLine(to: CGPoint(x: outer, y: bottom))
            shoulder.closeSubpath()
            deck.fill(shoulder,
                         with: .linearGradient(
                            Gradient(colors: [metalLight.opacity(0.62),
                                              metal,
                                              metalDark]),
                            startPoint: CGPoint(x: innerTop, y: top),
                            endPoint: CGPoint(x: outer, y: bottom)
                         ))
            deck.stroke(shoulder, with: .color(.black.opacity(0.78)), lineWidth: isPad ? 4 : 2.5)

            let insetX = outer + side * size.width * 0.075
            let ventWidth = size.width * 0.085
            let ventHeight = max(8, depth * 0.13)
            let vent = CGRect(x: isLeft ? insetX : insetX - ventWidth,
                              y: top + depth * 0.43,
                              width: ventWidth,
                              height: ventHeight)
            drawVent(deck, rect: vent)
        }

        // A raised central runway frames the circular launch platform and adds
        // a second depth layer beneath the windscreen sill.
        var runway = Path()
        runway.move(to: CGPoint(x: size.width * 0.42, y: top))
        runway.addLine(to: CGPoint(x: size.width * 0.58, y: top))
        runway.addLine(to: CGPoint(x: size.width * 0.67, y: bottom))
        runway.addLine(to: CGPoint(x: size.width * 0.33, y: bottom))
        runway.closeSubpath()
        deck.fill(runway,
                     with: .linearGradient(
                        Gradient(colors: [Color(red: 0.19, green: 0.29, blue: 0.53),
                                          Color(red: 0.055, green: 0.09, blue: 0.22),
                                          Color(red: 0.02, green: 0.035, blue: 0.10)]),
                        startPoint: CGPoint(x: size.width / 2, y: top),
                        endPoint: CGPoint(x: size.width / 2, y: bottom)
                     ))
        deck.stroke(runway, with: .color(.black.opacity(0.82)), lineWidth: isPad ? 5 : 3)
        var runwayGlow = deck
        runwayGlow.blendMode = .plusLighter
        runwayGlow.stroke(runway, with: .color(cyan.opacity(0.20)), lineWidth: isPad ? 9 : 6)

        let vanishing = CGPoint(x: size.width / 2, y: top - depth * 2.4)
        let topFraction = (top - vanishing.y) / (bottom - vanishing.y)
        for step in -7...7 {
            let x = size.width / 2 + CGFloat(step) * size.width * 0.11
            seam(deck,
                 from: CGPoint(x: vanishing.x + (x - vanishing.x) * topFraction, y: top),
                 to: CGPoint(x: x, y: bottom))
        }
        for fraction in [0.12, 0.32, 0.62] as [CGFloat] {
            let y = top + depth * fraction
            seam(deck, from: CGPoint(x: 0, y: y), to: CGPoint(x: size.width, y: y))
        }

        drawPlatform(in: deck, size: size, time: time)

        var floorJoint = Path()
        floorJoint.move(to: CGPoint(x: 0, y: leftOuterTop))
        floorJoint.addLine(to: CGPoint(x: leftJoin, y: top))
        floorJoint.addLine(to: CGPoint(x: rightJoin, y: top))
        floorJoint.addLine(to: CGPoint(x: size.width, y: rightOuterTop))
        context.stroke(floorJoint, with: .color(.black.opacity(0.92)),
                       lineWidth: isPad ? 10 : 7)
        context.stroke(floorJoint, with: .color(metalLight.opacity(0.62)),
                       lineWidth: isPad ? 4 : 2.8)
        context.stroke(floorJoint, with: .color(cyan.opacity(0.30)),
                       lineWidth: isPad ? 1.5 : 1)
    }

    private func drawPlatform(in context: GraphicsContext, size: CGSize, time: TimeInterval) {
        let pad = platformDisc(in: size)
        let width = pad.width
        let height = pad.height
        let centre = CGPoint(x: pad.midX, y: pad.midY)
        let pulse = 0.75 + 0.25 * sin(time * 1.6)

        context.fill(Path(ellipseIn: pad.insetBy(dx: -width * 0.04, dy: -height * 0.06)),
                     with: .color(.black.opacity(0.45)))
        context.fill(Path(ellipseIn: pad),
                     with: .linearGradient(Gradient(colors: [metalLight, metal, metalDark]),
                                           startPoint: CGPoint(x: 0, y: pad.minY),
                                           endPoint: CGPoint(x: 0, y: pad.maxY)))
        context.stroke(Path(ellipseIn: pad), with: .color(.black.opacity(0.7)), lineWidth: 2)

        for bolt in 0..<18 {
            let angle = Double(bolt) / 18 * 2 * .pi
            let point = CGPoint(x: centre.x + cos(angle) * width * 0.47,
                                y: centre.y + sin(angle) * height * 0.47)
            guard point.y < size.height - 2 else { continue }
            let radius = max(1.2, width * 0.006)
            context.fill(Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius,
                                                width: radius * 2, height: radius * 2)),
                         with: .color(.white.opacity(0.35)))
        }

        let inner = pad.insetBy(dx: width * 0.09, dy: height * 0.09)
        context.fill(Path(ellipseIn: inner), with: .color(metalDark))

        var glow = context
        glow.blendMode = .plusLighter
        let ring = pad.insetBy(dx: width * 0.13, dy: height * 0.13)
        glow.stroke(Path(ellipseIn: ring), with: .color(cyan.opacity(0.35 * pulse)), lineWidth: isPad ? 12 : 8)
        context.stroke(Path(ellipseIn: ring), with: .color(cyan), lineWidth: isPad ? 2.5 : 1.8)

        let core = pad.insetBy(dx: width * 0.19, dy: height * 0.19)
        context.fill(Path(ellipseIn: core),
                     with: .radialGradient(Gradient(colors: [cyan.opacity(0.85 * pulse),
                                                             blue.opacity(0.75),
                                                             Color(red: 0.02, green: 0.05, blue: 0.20)]),
                                           center: centre,
                                           startRadius: 0,
                                           endRadius: core.width * 0.5))
        context.stroke(Path(ellipseIn: pad.insetBy(dx: width * 0.27, dy: height * 0.27)),
                       with: .color(cyan.opacity(0.55)), lineWidth: isPad ? 2 : 1.4)
        context.stroke(Path(ellipseIn: pad.insetBy(dx: width * 0.34, dy: height * 0.34)),
                       with: .color(.white.opacity(0.35)), lineWidth: 1)
    }

    // MARK: Windshield

    private func drawSpace(in context: GraphicsContext, window: CGRect, cut: CGFloat, time: TimeInterval) {
        let glass = chamfered(window, cut: cut)
        context.drawLayer { space in
            space.clip(to: glass)
            let sky: [Color]
            switch destination {
            case 2:
                sky = [Color(red: 0.10, green: 0.012, blue: 0.035),
                       Color(red: 0.25, green: 0.035, blue: 0.055),
                       Color(red: 0.06, green: 0.02, blue: 0.12),
                       Color(red: 0.015, green: 0.01, blue: 0.045)]
            case 3:
                sky = [Color(red: 0.025, green: 0.018, blue: 0.10),
                       Color(red: 0.12, green: 0.075, blue: 0.24),
                       Color(red: 0.20, green: 0.11, blue: 0.22),
                       Color(red: 0.025, green: 0.02, blue: 0.08)]
            case 4:
                sky = [Color(red: 0.005, green: 0.055, blue: 0.11),
                       Color(red: 0.015, green: 0.19, blue: 0.27),
                       Color(red: 0.02, green: 0.10, blue: 0.25),
                       Color(red: 0.005, green: 0.025, blue: 0.08)]
            case 5:
                sky = [Color(red: 0.10, green: 0.008, blue: 0.10),
                       Color(red: 0.30, green: 0.025, blue: 0.16),
                       Color(red: 0.12, green: 0.025, blue: 0.25),
                       Color(red: 0.025, green: 0.008, blue: 0.055)]
            default:
                sky = [Color(red: 0.01, green: 0.01, blue: 0.07),
                       Color(red: 0.02, green: 0.03, blue: 0.16),
                       Color(red: 0.03, green: 0.08, blue: 0.28),
                       Color(red: 0.01, green: 0.04, blue: 0.14)]
            }
            space.fill(Path(window),
                       with: .linearGradient(Gradient(colors: sky),
                                             startPoint: CGPoint(x: window.minX, y: window.minY),
                                             endPoint: CGPoint(x: window.maxX, y: window.maxY)))
            if destination == 1 {
                drawVortex(in: space, window: window)
            } else {
                drawDestinationBeacon(in: space, window: window)
            }
            drawPlanet(in: space, window: window, time: time)

            for (width, opacity) in [(3.0, 0.16), (2.0, 0.20), (1.4, 0.28)] as [(CGFloat, Double)] {
                space.stroke(glass, with: .color(.black.opacity(opacity)), lineWidth: frameWidth * width)
            }

            var glare = Path()
            glare.move(to: CGPoint(x: window.minX + window.width * 0.08, y: window.minY))
            glare.addLine(to: CGPoint(x: window.minX + window.width * 0.26, y: window.minY))
            glare.addLine(to: CGPoint(x: window.minX, y: window.minY + window.height * 0.58))
            glare.addLine(to: CGPoint(x: window.minX, y: window.minY + window.height * 0.28))
            glare.closeSubpath()
            space.fill(glare, with: .color(.white.opacity(0.055)))

            let sheen = CGRect(x: window.minX, y: window.minY,
                               width: window.width, height: window.height * 0.16)
            space.fill(Path(sheen),
                       with: .linearGradient(Gradient(colors: [.white.opacity(0.07), .white.opacity(0)]),
                                             startPoint: CGPoint(x: sheen.minX, y: sheen.minY),
                                             endPoint: CGPoint(x: sheen.minX, y: sheen.maxY)))
        }
    }

    /// A real spiral composition rather than a purple fog bank. Every arm is
    /// a path made from deterministic points, then layered as shadow, gas,
    /// plasma and dust. It stays crisp at every device size and costs nothing
    /// on the animation clock because it lives on the static cockpit canvas.
    private func drawVortex(in context: GraphicsContext, window: CGRect) {
        let centre = CGPoint(x: window.minX + window.width * 0.215,
                             y: window.minY + window.height * 0.285)
        let violet = Color(red: 0.46, green: 0.18, blue: 1.00)
        let electricPurple = Color(red: 0.74, green: 0.38, blue: 1.00)
        let magenta = Color(red: 1.00, green: 0.34, blue: 0.78)
        let rose = Color(red: 1.00, green: 0.64, blue: 0.80)
        let warmWhite = Color(red: 1.00, green: 0.94, blue: 0.84)
        let armCount = 4
        let steps = 84

        func spiralPath(arm: Int, phaseOffset: CGFloat = 0) -> Path {
            var path = Path()
            for step in 0...steps {
                let t = CGFloat(step) / CGFloat(steps)
                let phase = CGFloat(arm) / CGFloat(armCount) * .pi * 2
                let angle = phase + phaseOffset - 0.72 + t * .pi * 3.10
                let radius = window.height * (0.012 + pow(t, 1.20) * 0.235)
                // A shallow ellipse tilts the vortex into the scene, while a
                // slight ripple keeps the arms from looking CAD-perfect.
                let ripple = 1 + sin(t * .pi * 7 + CGFloat(arm)) * 0.018
                let point = CGPoint(
                    x: centre.x + cos(angle) * radius * 1.22 * ripple,
                    y: centre.y + sin(angle) * radius * 0.64 * ripple
                )
                step == 0 ? path.move(to: point) : path.addLine(to: point)
            }
            return path
        }

        // Large, low-opacity gas envelope behind the structured arms.
        var envelope = context
        envelope.blendMode = .plusLighter
        envelope.fill(Path(ellipseIn: CGRect(x: centre.x - window.height * 0.245,
                                              y: centre.y - window.height * 0.155,
                                              width: window.height * 0.49,
                                              height: window.height * 0.31)),
                      with: .radialGradient(Gradient(stops: [
                        .init(color: magenta.opacity(0.13), location: 0),
                        .init(color: violet.opacity(0.13), location: 0.46),
                        .init(color: electricPurple.opacity(0.05), location: 0.74),
                        .init(color: .clear, location: 1)
                      ]), center: centre, startRadius: 0,
                      endRadius: window.height * 0.26))

        // Dark lanes run just beside the light paths. They separate each arm
        // and create the curled, tunnel-like depth missing from the old haze.
        var lanes = context
        lanes.blendMode = .multiply
        for arm in 0..<armCount {
            lanes.stroke(spiralPath(arm: arm, phaseOffset: 0.10),
                         with: .color(Color(red: 0.01, green: 0.005, blue: 0.055).opacity(0.52)),
                         style: StrokeStyle(lineWidth: window.height * 0.016,
                                            lineCap: .round,
                                            lineJoin: .round))
        }

        for arm in 0..<armCount {
            let path = spiralPath(arm: arm)
            let armColor = arm.isMultiple(of: 2) ? magenta : electricPurple

            context.drawLayer { gas in
                gas.blendMode = .plusLighter
                gas.addFilter(.blur(radius: window.height * 0.022))
                gas.stroke(path,
                           with: .color(armColor.opacity(0.24)),
                           style: StrokeStyle(lineWidth: window.height * 0.048,
                                              lineCap: .round,
                                              lineJoin: .round))
            }

            context.drawLayer { plasma in
                plasma.blendMode = .plusLighter
                plasma.addFilter(.blur(radius: window.height * 0.006))
                plasma.stroke(path,
                              with: .linearGradient(Gradient(stops: [
                                .init(color: warmWhite.opacity(0.78), location: 0),
                                .init(color: rose.opacity(0.64), location: 0.18),
                                .init(color: armColor.opacity(0.48), location: 0.55),
                                .init(color: violet.opacity(0.07), location: 1)
                              ]), startPoint: centre,
                              endPoint: CGPoint(x: window.minX,
                                                y: window.maxY)),
                              style: StrokeStyle(lineWidth: window.height * 0.011,
                                                 lineCap: .round,
                                                 lineJoin: .round))
            }

            var filament = context
            filament.blendMode = .plusLighter
            filament.stroke(path,
                            with: .linearGradient(Gradient(stops: [
                                .init(color: .white.opacity(0.82), location: 0),
                                .init(color: rose.opacity(0.64), location: 0.22),
                                .init(color: electricPurple.opacity(0.36), location: 0.66),
                                .init(color: .clear, location: 1)
                            ]), startPoint: centre,
                            endPoint: CGPoint(x: window.minX,
                                              y: window.maxY)),
                            style: StrokeStyle(lineWidth: max(0.9, window.height * 0.0032),
                                               lineCap: .round,
                                               lineJoin: .round))
        }

        // Dense dust follows the same spiral equation, so the grains reinforce
        // the motion rather than reading as generic random stars.
        var dust = context
        dust.blendMode = .plusLighter
        for index in 0..<170 {
            let arm = index % armCount
            let t = 0.08 + random(index, 111) * 0.92
            let phase = CGFloat(arm) / CGFloat(armCount) * .pi * 2
            let angle = phase - 0.72 + t * .pi * 3.10
            let baseRadius = window.height * (0.012 + pow(t, 1.20) * 0.235)
            let scatter = (random(index, 112) - 0.5) * window.height * (0.010 + t * 0.017)
            let radius = baseRadius + scatter
            let point = CGPoint(x: centre.x + cos(angle) * radius * 1.22,
                                y: centre.y + sin(angle) * radius * 0.64)
            let dot = 0.45 + random(index, 113) * (isPad ? 1.75 : 1.20)
            let color = index.isMultiple(of: 7) ? warmWhite
                : (index.isMultiple(of: 3) ? rose : electricPurple)
            dust.fill(Path(ellipseIn: CGRect(x: point.x - dot * 0.5,
                                              y: point.y - dot * 0.5,
                                              width: dot, height: dot)),
                      with: .color(color.opacity(0.24 + Double(random(index, 114)) * 0.40)))
        }

        // Layered hot core and a small dark centre make the vortex feel like a
        // deep funnel while retaining the friendly, luminous reference mood.
        var core = context
        core.blendMode = .plusLighter
        let coreRadius = window.height * 0.064
        core.fill(Path(ellipseIn: CGRect(x: centre.x - coreRadius * 1.30,
                                         y: centre.y - coreRadius * 0.72,
                                         width: coreRadius * 2.60,
                                         height: coreRadius * 1.44)),
                  with: .radialGradient(Gradient(stops: [
                    .init(color: .white.opacity(0.90), location: 0),
                    .init(color: warmWhite.opacity(0.74), location: 0.18),
                    .init(color: rose.opacity(0.42), location: 0.43),
                    .init(color: magenta.opacity(0.16), location: 0.70),
                    .init(color: .clear, location: 1)
                  ]), center: centre, startRadius: 0,
                  endRadius: coreRadius * 1.30))
        context.fill(Path(ellipseIn: CGRect(x: centre.x - coreRadius * 0.18,
                                            y: centre.y - coreRadius * 0.10,
                                            width: coreRadius * 0.36,
                                            height: coreRadius * 0.20)),
                     with: .color(Color(red: 0.12, green: 0.025, blue: 0.22).opacity(0.62)))
    }

    /// Each later sector gets a different distant light source as well as a
    /// different planet, so the full view changes rather than merely recolours.
    private func drawDestinationBeacon(in context: GraphicsContext, window: CGRect) {
        let centre: CGPoint
        let color: Color
        switch destination {
        case 2:
            centre = CGPoint(x: window.minX + window.width * 0.18,
                             y: window.minY + window.height * 0.24)
            color = Color(red: 1.00, green: 0.32, blue: 0.16)
        case 3:
            centre = CGPoint(x: window.minX + window.width * 0.26,
                             y: window.minY + window.height * 0.62)
            color = Color(red: 1.00, green: 0.76, blue: 0.32)
        case 4:
            centre = CGPoint(x: window.minX + window.width * 0.20,
                             y: window.minY + window.height * 0.30)
            color = Color(red: 0.38, green: 1.00, blue: 0.94)
        default:
            centre = CGPoint(x: window.minX + window.width * 0.25,
                             y: window.minY + window.height * 0.22)
            color = Color(red: 1.00, green: 0.22, blue: 0.68)
        }
        let radius = window.height * (destination == 3 ? 0.065 : 0.045)
        var glow = context
        glow.blendMode = .plusLighter
        glow.fill(Path(ellipseIn: CGRect(x: centre.x - radius * 4,
                                         y: centre.y - radius * 4,
                                         width: radius * 8,
                                         height: radius * 8)),
                  with: .radialGradient(Gradient(colors: [color.opacity(0.56),
                                                          color.opacity(0.13),
                                                          .clear]),
                                        center: centre,
                                        startRadius: 0,
                                        endRadius: radius * 4))
        glow.fill(Path(ellipseIn: CGRect(x: centre.x - radius,
                                         y: centre.y - radius,
                                         width: radius * 2,
                                         height: radius * 2)),
                  with: .radialGradient(Gradient(colors: [.white, color]),
                                        center: centre,
                                        startRadius: 0,
                                        endRadius: radius))

        if destination == 4 {
            for band in 0..<3 {
                var aurora = Path()
                let y = window.minY + window.height * (0.18 + CGFloat(band) * 0.12)
                aurora.move(to: CGPoint(x: window.minX, y: y))
                aurora.addCurve(to: CGPoint(x: window.maxX, y: y + window.height * 0.08),
                                control1: CGPoint(x: window.minX + window.width * 0.35,
                                                  y: y + window.height * 0.15),
                                control2: CGPoint(x: window.minX + window.width * 0.68,
                                                  y: y - window.height * 0.10))
                glow.stroke(aurora,
                            with: .color(color.opacity(0.16 - Double(band) * 0.03)),
                            style: StrokeStyle(lineWidth: window.height * 0.035,
                                               lineCap: .round))
            }
        }
    }

    private func drawNebula(in context: GraphicsContext, window: CGRect) {
        let violet = Color(red: 0.48, green: 0.20, blue: 0.98)
        let fuchsia = Color(red: 0.92, green: 0.24, blue: 0.78)
        let ice = Color(red: 0.70, green: 0.82, blue: 1.00)
        let origin = CGPoint(x: window.minX + window.width * 0.27,
                             y: window.minY + window.height * 0.37)

        // The nebula is built from long, blurred ribbons instead of a cloud of
        // circles. That gives it a recognisable current and keeps it from
        // reading as one undefined purple object behind the gameplay.
        var upperRibbon = Path()
        upperRibbon.move(to: CGPoint(x: window.minX - window.width * 0.08,
                                     y: window.minY + window.height * 0.61))
        upperRibbon.addCurve(to: CGPoint(x: window.minX + window.width * 0.42,
                                         y: window.minY + window.height * 0.28),
                             control1: CGPoint(x: window.minX + window.width * 0.08,
                                               y: window.minY + window.height * 0.60),
                             control2: CGPoint(x: window.minX + window.width * 0.19,
                                               y: window.minY + window.height * 0.22))
        upperRibbon.addCurve(to: CGPoint(x: window.minX + window.width * 0.78,
                                         y: window.minY + window.height * 0.16),
                             control1: CGPoint(x: window.minX + window.width * 0.56,
                                               y: window.minY + window.height * 0.34),
                             control2: CGPoint(x: window.minX + window.width * 0.66,
                                               y: window.minY + window.height * 0.12))

        var lowerRibbon = Path()
        lowerRibbon.move(to: CGPoint(x: window.minX - window.width * 0.10,
                                     y: window.minY + window.height * 0.78))
        lowerRibbon.addCurve(to: CGPoint(x: window.minX + window.width * 0.36,
                                         y: window.minY + window.height * 0.43),
                             control1: CGPoint(x: window.minX + window.width * 0.08,
                                               y: window.minY + window.height * 0.72),
                             control2: CGPoint(x: window.minX + window.width * 0.14,
                                               y: window.minY + window.height * 0.36))
        lowerRibbon.addCurve(to: CGPoint(x: window.minX + window.width * 0.72,
                                         y: window.minY + window.height * 0.34),
                             control1: CGPoint(x: window.minX + window.width * 0.50,
                                               y: window.minY + window.height * 0.55),
                             control2: CGPoint(x: window.minX + window.width * 0.61,
                                               y: window.minY + window.height * 0.27))

        context.drawLayer { haze in
            haze.blendMode = .plusLighter
            haze.addFilter(.blur(radius: window.height * 0.035))
            haze.stroke(upperRibbon,
                        with: .linearGradient(Gradient(colors: [violet.opacity(0),
                                                                 violet.opacity(0.34),
                                                                 fuchsia.opacity(0.25),
                                                                 ice.opacity(0)]),
                                              startPoint: CGPoint(x: window.minX, y: origin.y),
                                              endPoint: CGPoint(x: window.maxX, y: origin.y)),
                        style: StrokeStyle(lineWidth: window.height * 0.18,
                                           lineCap: .round,
                                           lineJoin: .round))
            haze.stroke(lowerRibbon,
                        with: .linearGradient(Gradient(colors: [fuchsia.opacity(0),
                                                                 fuchsia.opacity(0.24),
                                                                 violet.opacity(0.28),
                                                                 violet.opacity(0)]),
                                              startPoint: CGPoint(x: window.minX, y: origin.y),
                                              endPoint: CGPoint(x: window.maxX, y: origin.y)),
                        style: StrokeStyle(lineWidth: window.height * 0.13,
                                           lineCap: .round,
                                           lineJoin: .round))
        }

        context.drawLayer { filaments in
            filaments.blendMode = .plusLighter
            filaments.addFilter(.blur(radius: window.height * 0.010))
            filaments.stroke(upperRibbon,
                             with: .linearGradient(Gradient(colors: [violet.opacity(0),
                                                                      ice.opacity(0.22),
                                                                      fuchsia.opacity(0.34),
                                                                      violet.opacity(0)]),
                                                   startPoint: CGPoint(x: window.minX, y: origin.y),
                                                   endPoint: CGPoint(x: window.maxX, y: origin.y)),
                             style: StrokeStyle(lineWidth: window.height * 0.032,
                                                lineCap: .round,
                                                lineJoin: .round))
            filaments.stroke(lowerRibbon,
                             with: .color(violet.opacity(0.23)),
                             style: StrokeStyle(lineWidth: window.height * 0.022,
                                                lineCap: .round,
                                                lineJoin: .round))
        }

        // A dark seam provides contrast and makes the coloured gas feel
        // layered instead of uniformly luminous.
        var dustLane = context
        dustLane.blendMode = .multiply
        dustLane.stroke(upperRibbon,
                        with: .color(Color(red: 0.02, green: 0.01, blue: 0.10).opacity(0.46)),
                        style: StrokeStyle(lineWidth: window.height * 0.018,
                                           lineCap: .round,
                                           lineJoin: .round))

        var core = context
        core.blendMode = .plusLighter
        let coreRadius = window.height * 0.15
        core.fill(Path(ellipseIn: CGRect(x: origin.x - coreRadius,
                                         y: origin.y - coreRadius * 0.62,
                                         width: coreRadius * 2,
                                         height: coreRadius * 1.24)),
                  with: .radialGradient(Gradient(stops: [
                    .init(color: .white.opacity(0.62), location: 0),
                    .init(color: ice.opacity(0.26), location: 0.20),
                    .init(color: fuchsia.opacity(0.20), location: 0.48),
                    .init(color: violet.opacity(0), location: 1)
                  ]),
                  center: origin,
                  startRadius: 0,
                  endRadius: coreRadius))

        // Dust follows the same two currents, with dense grains near the core
        // and sparse blue-violet grains at the tips.
        let dust = Color(red: 0.91, green: 0.92, blue: 1.00)
        for index in 0..<190 {
            let t = random(index, 11)
            let branch = index.isMultiple(of: 2) ? -1.0 : 1.0
            let x = window.minX + window.width * (-0.04 + t * 0.80)
            let wave = sin(Double(t) * .pi * 2.15 + branch * 0.55)
            let centreY = window.minY + window.height * (0.50 - t * 0.34 + CGFloat(wave) * 0.10)
            let spread = (random(index, 12) - 0.5) * window.height * (0.05 + t * 0.08)
            let y = centreY + spread * CGFloat(branch)
            let dot = 0.35 + random(index, 14) * (isPad ? 1.45 : 1.05)
            let tint = index.isMultiple(of: 6) ? ice : dust
            core.fill(Path(ellipseIn: CGRect(x: x - dot / 2, y: y - dot / 2,
                                             width: dot, height: dot)),
                      with: .color(tint.opacity(0.20 + Double(random(index, 15)) * 0.58)))
        }
    }

    private func drawStars(in context: GraphicsContext, window: CGRect, time: TimeInterval) {
        var glow = context
        glow.blendMode = .plusLighter
        let count = min(Self.starSamples.count,
                        Int(window.width * window.height / 2_000))
        for index in 0..<count {
            let sample = Self.starSamples[index]
            let depth = sample.depth
            let speed = 0.002 + depth * 0.006
            let x = window.minX + wrap(sample.x - CGFloat(time) * speed) * window.width
            let y = window.minY + sample.y * window.height
            let radius = 0.35 + depth * depth * (isPad ? 1.9 : 1.4)
            let twinkle = 0.55 + 0.45 * sin(time * sample.twinkleRate + Double(index))
            let tint = index.isMultiple(of: 7) ? Color(red: 0.70, green: 0.85, blue: 1.00) : .white
            glow.fill(Path(ellipseIn: CGRect(x: x - radius, y: y - radius,
                                             width: radius * 2, height: radius * 2)),
                      with: .color(tint.opacity(twinkle * (0.4 + Double(depth) * 0.6))))

            guard depth > 0.93 else { continue }
            let arm = radius * 4.5
            var sparkle = Path()
            sparkle.move(to: CGPoint(x: x - arm, y: y))
            sparkle.addLine(to: CGPoint(x: x + arm, y: y))
            sparkle.move(to: CGPoint(x: x, y: y - arm))
            sparkle.addLine(to: CGPoint(x: x, y: y + arm))
            glow.stroke(sparkle, with: .color(tint.opacity(0.55 * twinkle)), lineWidth: 0.7)
            glow.fill(Path(ellipseIn: CGRect(x: x - arm, y: y - arm, width: arm * 2, height: arm * 2)),
                      with: .radialGradient(Gradient(colors: [tint.opacity(0.30 * twinkle), tint.opacity(0)]),
                                            center: CGPoint(x: x, y: y),
                                            startRadius: 0,
                                            endRadius: arm))
        }
    }

    /// Three loose asteroid families drift together. A larger leader and a
    /// trail of differently sized companions makes every pass read as a small
    /// field rather than a row of evenly spaced decorative rocks.
    private func drawAsteroids(in context: GraphicsContext,
                               window: CGRect,
                               time: TimeInterval) {
        // Six varied rocks retain the three drifting families without
        // rebuilding a dense set of multi-path objects every scenery tick.
        let groupSizes = [2, 2, 2]
        let groupLanes: [CGFloat] = [0.22, 0.72, 0.45]
        var index = 0

        for group in groupSizes.indices {
            let direction: CGFloat = group == 1 ? -1 : 1
            let groupDepth = 0.55 + random(group, 71) * 0.34
            let travel = CGFloat(time) * (0.0048 + groupDepth * 0.0078) * direction
            let groupX = random(group, 72) + travel

            for member in 0..<groupSizes[group] {
                let isLeader = member == 0
                let memberOffsetX: CGFloat = isLeader
                    ? 0
                    : (random(index, 73) - 0.5) * 0.13 - direction * CGFloat(member) * 0.018
                let x = window.minX + wrap(groupX + memberOffsetX) * window.width
                let laneJitter: CGFloat = isLeader
                    ? 0
                    : (random(index, 74) - 0.5) * 0.15
                let baseY = window.minY + (groupLanes[group] + laneJitter) * window.height
                let depth = min(1, max(0.32,
                    groupDepth + (random(index, 75) - 0.5) * 0.20))
                let y = baseY + sin(time * (0.22 + Double(depth) * 0.16)
                                    + Double(group * 2 + member)) * window.height * 0.009
                let radius = window.height * (isLeader
                    ? 0.038 + groupDepth * 0.020
                    : 0.010 + random(index, 76) * 0.023)
            let rotationDirection: CGFloat = index.isMultiple(of: 2) ? -1 : 1
                let rotation = CGFloat(time) * (0.050 + random(index, 77) * 0.090) * rotationDirection
                let squash = 0.76 + random(index, 78) * 0.34

            var points: [CGPoint] = []
                let vertexCount = radius > window.height * 0.027 ? 9 : 7
                for vertex in 0..<vertexCount {
                let angle = CGFloat(vertex) / CGFloat(vertexCount) * .pi * 2 + rotation
                    let variance = 0.72 + random(index * 12 + vertex, 79) * 0.38
                points.append(CGPoint(x: x + cos(angle) * radius * variance,
                                      y: y + sin(angle) * radius * variance * squash))
            }

            var rock = Path()
            for (vertex, point) in points.enumerated() {
                vertex == 0 ? rock.move(to: point) : rock.addLine(to: point)
            }
            rock.closeSubpath()

            let edgeTint = x < window.midX
                ? Color(red: 0.92, green: 0.32, blue: 0.86)
                : Color(red: 0.28, green: 0.80, blue: 1.00)

            // The closest rocks carry a short, soft parallax wake. It makes
            // their horizontal flight clear without resorting to long speed
            // lines that would compete with the question and character.
                if isLeader && depth > 0.66 {
                var wakeContext = context
                wakeContext.blendMode = .plusLighter
                var wake = Path()
                wake.move(to: CGPoint(x: x - direction * radius * 3.2, y: y))
                wake.addLine(to: CGPoint(x: x - direction * radius * 0.75, y: y))
                wakeContext.stroke(wake,
                                   with: .linearGradient(Gradient(colors: [
                                    edgeTint.opacity(0), edgeTint.opacity(0.22)
                                   ]),
                                   startPoint: CGPoint(x: x - direction * radius * 3.2, y: y),
                                   endPoint: CGPoint(x: x - direction * radius * 0.75, y: y)),
                                   style: StrokeStyle(lineWidth: radius * 0.46,
                                                      lineCap: .round))
            }

                if depth > 0.72 {
                var halo = context
                halo.blendMode = .plusLighter
                halo.stroke(rock, with: .color(edgeTint.opacity(0.11)), lineWidth: radius * 0.34)
            }

            context.fill(rock,
                         with: .linearGradient(Gradient(stops: [
                            .init(color: Color(red: 0.72, green: 0.66, blue: 0.64), location: 0),
                            .init(color: Color(red: 0.34, green: 0.29, blue: 0.32), location: 0.38),
                            .init(color: Color(red: 0.12, green: 0.09, blue: 0.14), location: 0.72),
                            .init(color: Color(red: 0.025, green: 0.02, blue: 0.055), location: 1)
                         ]),
                         startPoint: CGPoint(x: x - radius * 0.75, y: y - radius),
                         endPoint: CGPoint(x: x + radius, y: y + radius)))

            // Broad mineral facets break up the computer-perfect polygon and
            // stay legible even on the smaller iPhone playfield.
                let facetCount = radius > window.height * 0.027 ? 4 : 2
                for facet in 0..<facetCount {
                let first = (facet * 2 + index) % points.count
                let second = (first + 1 + facet % 2) % points.count
                var face = Path()
                face.move(to: CGPoint(x: x + (random(index + facet, 90) - 0.5) * radius * 0.20,
                                      y: y + (random(index + facet, 91) - 0.5) * radius * 0.16))
                face.addLine(to: points[first])
                face.addLine(to: points[second])
                face.closeSubpath()
                let facetColor = facet.isMultiple(of: 2)
                    ? edgeTint.opacity(0.055 + Double(depth) * 0.055)
                    : Color(red: 0.13, green: 0.08, blue: 0.18).opacity(0.34)
                context.fill(face, with: .color(facetColor))
            }

            var litRim = Path()
                let rimStart = max(0, points.count - 4)
                litRim.move(to: points[rimStart])
                for vertex in (rimStart + 1)..<points.count { litRim.addLine(to: points[vertex]) }
            litRim.addLine(to: points[0])
            context.stroke(litRim,
                           with: .color(edgeTint.opacity(0.34 + Double(depth) * 0.30)),
                           lineWidth: depth > 0.7 ? 1.35 : 0.75)
            context.stroke(rock, with: .color(.black.opacity(0.55)), lineWidth: depth > 0.7 ? 1.1 : 0.65)

                let relativeSize = radius / window.height
                let craterCount = relativeSize > 0.040 ? 3 : (relativeSize > 0.024 ? 2 : 1)
                for crater in 0..<craterCount {
                let craterRadius = radius * (0.11 + random(index * 5 + crater, 82) * 0.14)
                let craterPoint = CGPoint(x: x + (random(index * 7 + crater, 83) - 0.54) * radius * 0.68,
                                          y: y + (random(index * 9 + crater, 84) - 0.52) * radius * 0.48)
                let craterRect = CGRect(x: craterPoint.x - craterRadius,
                                        y: craterPoint.y - craterRadius * 0.66,
                                        width: craterRadius * 2,
                                        height: craterRadius * 1.32)
                context.fill(Path(ellipseIn: craterRect),
                             with: .radialGradient(Gradient(colors: [Color.black.opacity(0.48),
                                                                      Color.black.opacity(0.12)]),
                                                   center: CGPoint(x: craterPoint.x + craterRadius * 0.18,
                                                                   y: craterPoint.y + craterRadius * 0.12),
                                                   startRadius: 0,
                                                   endRadius: craterRadius))
                    context.stroke(Path(ellipseIn: craterRect),
                                   with: .color(.black.opacity(0.48)),
                                   lineWidth: max(0.55, radius * 0.055))
                    let craterHighlight = Path(ellipseIn: craterRect.offsetBy(dx: -craterRadius * 0.10,
                                                                              dy: -craterRadius * 0.10))
                    context.stroke(craterHighlight,
                                   with: .color(edgeTint.opacity(0.16 + Double(depth) * 0.10)),
                                   lineWidth: max(0.45, radius * 0.035))
            }

            // Close foreground rocks shed a few tiny fragments in the opposite
            // direction of travel, reinforcing speed without adding streaks.
                if isLeader && depth > 0.70 {
                for fragment in 0..<3 {
                    let gap = radius * (1.30 + CGFloat(fragment) * 0.42)
                    let fx = x - gap * direction
                    let fy = y + (random(index * 3 + fragment, 96) - 0.5) * radius
                    let dot = radius * (0.055 + random(fragment, 97) * 0.045)
                    context.fill(Path(ellipseIn: CGRect(x: fx - dot, y: fy - dot,
                                                        width: dot * 2, height: dot * 2)),
                                 with: .color(Color(red: 0.55, green: 0.57, blue: 0.66)
                                    .opacity(0.25 + Double(depth) * 0.25)))
                }
            }
                index += 1
            }
        }
    }

    private func planetGeometry(in window: CGRect) -> (centre: CGPoint, radius: CGFloat) {
        let radiusScale: CGFloat
        let x: CGFloat
        let y: CGFloat
        switch destination {
        case 2: (radiusScale, x, y) = (0.70, 0.88, 0.83)
        case 3: (radiusScale, x, y) = (0.60, 0.78, 0.58)
        case 4: (radiusScale, x, y) = (0.69, 0.87, 0.77)
        case 5: (radiusScale, x, y) = (0.76, 0.86, 0.86)
        default: (radiusScale, x, y) = (0.84, 0.94, 1.30)
        }
        let radius = min(window.height * radiusScale, window.width * 0.44)
        return (CGPoint(x: window.minX + window.width * x,
                        y: window.minY + window.height * y), radius)
    }

    /// A very faint animated rim over the planet suggests slow atmospheric
    /// rotation while keeping the expensive planet texture on the static layer.
    private func drawAtmosphereShimmer(in context: GraphicsContext,
                                       window: CGRect,
                                       time: TimeInterval) {
        let geometry = planetGeometry(in: window)
        let radius = geometry.radius
        let centre = geometry.centre
        let disc = CGRect(x: centre.x - radius, y: centre.y - radius,
                          width: radius * 2, height: radius * 2)
        var glow = context
        glow.blendMode = .plusLighter
        let start = Angle.radians(time * 0.05)
        let end = Angle.radians(time * 0.05 + 1.15)
        let arc = Path { path in
            path.addArc(center: centre,
                        radius: radius * 1.008,
                        startAngle: start,
                        endAngle: end,
                        clockwise: false)
        }
        glow.stroke(arc, with: .color(.white.opacity(0.32)), lineWidth: isPad ? 3 : 2)
        glow.stroke(Path(ellipseIn: disc.insetBy(dx: -radius * 0.025, dy: -radius * 0.025)),
                    with: .color(cyan.opacity(0.07 + 0.04 * sin(time * 1.3))),
                    lineWidth: isPad ? 10 : 7)

        // Warm lights are grouped around the visible land masses. A slow,
        // offset pulse makes them feel like living places rather than a dotted
        // decorative ring pasted over the planet.
        guard destination == 1 else { return }
        let hubs = [CGPoint(x: -0.42, y: -0.46),
                    CGPoint(x: -0.18, y: -0.57),
                    CGPoint(x: 0.02, y: -0.44),
                    CGPoint(x: -0.20, y: -0.18),
                    CGPoint(x: -0.53, y: 0.05)]
        context.drawLayer { lights in
            lights.clip(to: Path(ellipseIn: disc))
            lights.blendMode = .plusLighter
            for index in 0..<20 {
                let hub = hubs[index % hubs.count]
                let px = centre.x + (hub.x + (random(index, 101) - 0.5) * 0.20) * radius
                let py = centre.y + (hub.y + (random(index, 102) - 0.5) * 0.13) * radius
                let pulse = 0.38 + 0.34 * (0.5 + 0.5 * sin(time * (0.75 + Double(random(index, 103))) + Double(index)))
                let dot = (isPad ? 1.05 : 0.75) + random(index, 104) * (isPad ? 1.25 : 0.90)
                let lightColor = index.isMultiple(of: 5)
                    ? Color(red: 1.00, green: 0.93, blue: 0.72)
                    : Color(red: 1.00, green: 0.64, blue: 0.25)
                lights.fill(Path(ellipseIn: CGRect(x: px - dot / 2, y: py - dot / 2,
                                                   width: dot, height: dot)),
                            with: .color(lightColor.opacity(pulse)))
            }
        }
    }

    private func drawPlatformPulse(in context: GraphicsContext,
                                   size: CGSize,
                                   time: TimeInterval) {
        let pad = platformDisc(in: size)
        let width = pad.width
        let height = pad.height
        let ring = pad.insetBy(dx: width * 0.13, dy: height * 0.13)
        let pulse = 0.45 + 0.35 * (0.5 + 0.5 * sin(time * 1.8))
        var glow = context
        glow.blendMode = .plusLighter
        glow.stroke(Path(ellipseIn: ring),
                    with: .color(cyan.opacity(pulse)),
                    lineWidth: isPad ? 8 : 6)
        let scanner = ring.insetBy(dx: width * CGFloat(cockpitWrap(time * 0.22)) * 0.14,
                                   dy: height * CGFloat(cockpitWrap(time * 0.22)) * 0.14)
        glow.stroke(Path(ellipseIn: scanner),
                    with: .color(.white.opacity(0.18 * (1 - cockpitWrap(time * 0.22)))),
                    lineWidth: isPad ? 2 : 1.2)
    }

    private func drawPlanet(in context: GraphicsContext, window: CGRect, time: TimeInterval) {
        if destination == 1 {
            drawEarthPlanet(in: context, window: window, time: time)
        } else {
            drawStylisedPlanet(in: context, window: window)
        }
    }

    private func drawEarthPlanet(in context: GraphicsContext, window: CGRect, time: TimeInterval) {
        let geometry = planetGeometry(in: window)
        let radius = geometry.radius
        let centre = geometry.centre
        let disc = CGRect(x: centre.x - radius, y: centre.y - radius,
                          width: radius * 2, height: radius * 2)
        let planet = Path(ellipseIn: disc)

        var glow = context
        glow.blendMode = .plusLighter
        glow.fill(Path(ellipseIn: disc.insetBy(dx: -radius * 0.25, dy: -radius * 0.25)),
                  with: .radialGradient(Gradient(stops: [
                    .init(color: cyan.opacity(0), location: 0.68),
                    .init(color: Color(red: 0.35, green: 0.90, blue: 1.00).opacity(0.58), location: 0.79),
                    .init(color: blue.opacity(0.24), location: 0.89),
                    .init(color: blue.opacity(0), location: 1)
                  ]),
                  center: centre,
                  startRadius: 0,
                  endRadius: radius * 1.25))

        context.fill(planet,
                     with: .radialGradient(Gradient(stops: [
                        .init(color: Color(red: 0.33, green: 0.78, blue: 1.00), location: 0),
                        .init(color: Color(red: 0.03, green: 0.42, blue: 0.78), location: 0.34),
                        .init(color: Color(red: 0.012, green: 0.19, blue: 0.48), location: 0.67),
                        .init(color: Color(red: 0.003, green: 0.025, blue: 0.11), location: 1)
                     ]),
                                           center: CGPoint(x: centre.x - radius * 0.45,
                                                           y: centre.y - radius * 0.55),
                                           startRadius: 0,
                                           endRadius: radius * 1.7))

        context.drawLayer { surface in
            surface.clip(to: planet)

            func earthPoint(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: centre.x + x * radius, y: centre.y + y * radius)
            }

            // Fine ocean currents follow the curvature of the sphere. Their
            // low contrast gives the water scale and texture without turning
            // it into the flat blue disc from the earlier version.
            var oceanDetails = surface
            oceanDetails.blendMode = .plusLighter
            for index in 0..<14 {
                let y = -0.78 + CGFloat(index) * 0.105
                var current = Path()
                current.move(to: earthPoint(-0.92, y))
                current.addCurve(to: earthPoint(0.82, y + (random(index, 121) - 0.5) * 0.10),
                                 control1: earthPoint(-0.42, y - 0.10),
                                 control2: earthPoint(0.28, y + 0.12))
                oceanDetails.stroke(current,
                                    with: .color(Color(red: 0.30, green: 0.78, blue: 0.94)
                                        .opacity(0.035 + Double(random(index, 122)) * 0.045)),
                                    lineWidth: max(0.45, radius * 0.004))
            }

            // Stylised but coherent coastlines. Large, joined masses read as a
            // planet at a glance; the old collection of random ellipses looked
            // like spots sitting on top of a blue ball.
            var north = Path()
            north.move(to: earthPoint(-0.93, -0.63))
            north.addCurve(to: earthPoint(-0.62, -0.83),
                           control1: earthPoint(-0.86, -0.79),
                           control2: earthPoint(-0.73, -0.88))
            north.addCurve(to: earthPoint(-0.33, -0.73),
                           control1: earthPoint(-0.52, -0.80),
                           control2: earthPoint(-0.43, -0.69))
            north.addLine(to: earthPoint(-0.17, -0.56))
            north.addLine(to: earthPoint(-0.26, -0.42))
            north.addLine(to: earthPoint(-0.45, -0.39))
            north.addLine(to: earthPoint(-0.52, -0.22))
            north.addLine(to: earthPoint(-0.72, -0.30))
            north.addLine(to: earthPoint(-0.82, -0.45))
            north.closeSubpath()

            var europeAfrica = Path()
            europeAfrica.move(to: earthPoint(-0.36, -0.64))
            europeAfrica.addCurve(to: earthPoint(0.02, -0.71),
                                  control1: earthPoint(-0.23, -0.76),
                                  control2: earthPoint(-0.08, -0.65))
            europeAfrica.addLine(to: earthPoint(0.25, -0.55))
            europeAfrica.addLine(to: earthPoint(0.18, -0.40))
            europeAfrica.addLine(to: earthPoint(0.05, -0.34))
            europeAfrica.addCurve(to: earthPoint(-0.03, 0.20),
                                  control1: earthPoint(0.16, -0.08),
                                  control2: earthPoint(0.10, 0.10))
            europeAfrica.addLine(to: earthPoint(-0.22, 0.47))
            europeAfrica.addLine(to: earthPoint(-0.35, 0.19))
            europeAfrica.addLine(to: earthPoint(-0.43, -0.10))
            europeAfrica.addLine(to: earthPoint(-0.56, -0.27))
            europeAfrica.addLine(to: earthPoint(-0.45, -0.43))
            europeAfrica.closeSubpath()

            var south = Path()
            south.move(to: earthPoint(-0.70, -0.20))
            south.addCurve(to: earthPoint(-0.46, -0.12),
                           control1: earthPoint(-0.62, -0.28),
                           control2: earthPoint(-0.52, -0.23))
            south.addLine(to: earthPoint(-0.38, 0.06))
            south.addLine(to: earthPoint(-0.47, 0.30))
            south.addLine(to: earthPoint(-0.54, 0.61))
            south.addLine(to: earthPoint(-0.68, 0.74))
            south.addLine(to: earthPoint(-0.72, 0.44))
            south.addLine(to: earthPoint(-0.81, 0.19))
            south.addLine(to: earthPoint(-0.84, -0.03))
            south.closeSubpath()

            var asia = Path()
            asia.move(to: earthPoint(0.02, -0.72))
            asia.addCurve(to: earthPoint(0.72, -0.58),
                          control1: earthPoint(0.26, -0.84),
                          control2: earthPoint(0.53, -0.72))
            asia.addLine(to: earthPoint(0.86, -0.39))
            asia.addLine(to: earthPoint(0.64, -0.25))
            asia.addLine(to: earthPoint(0.44, -0.34))
            asia.addLine(to: earthPoint(0.30, -0.18))
            asia.addLine(to: earthPoint(0.15, -0.38))
            asia.addLine(to: earthPoint(-0.02, -0.47))
            asia.closeSubpath()

            let landMasses = [north, europeAfrica, south, asia]
            let landLight = Color(red: 0.48, green: 0.63, blue: 0.36)
            let landMid = Color(red: 0.25, green: 0.42, blue: 0.24)
            let landDark = Color(red: 0.075, green: 0.19, blue: 0.17)
            for (index, land) in landMasses.enumerated() {
                surface.fill(land,
                             with: .linearGradient(Gradient(colors: [landLight.opacity(index == 0 ? 0.92 : 0.82),
                                                                      landMid.opacity(0.94),
                                                                      landDark.opacity(0.98)]),
                                                   startPoint: earthPoint(-0.65, -0.82),
                                                   endPoint: earthPoint(0.50, 0.55)))
                surface.stroke(land,
                               with: .color(Color(red: 0.17, green: 0.72, blue: 0.76).opacity(0.16)),
                               lineWidth: max(1.4, radius * 0.018))
                surface.stroke(land,
                               with: .color(Color(red: 0.58, green: 0.88, blue: 0.71).opacity(0.34)),
                               lineWidth: max(0.8, radius * 0.007))

                // Deterministic micro terrain breaks up the broad gradients
                // into forests, plateaus and dry ground while staying inside
                // the actual coastline path.
                for fleck in 0..<58 {
                    let point = earthPoint(-0.95 + random(index * 70 + fleck, 123) * 1.90,
                                           -0.88 + random(index * 70 + fleck, 124) * 1.70)
                    guard land.contains(point) else { continue }
                    let fleckSize = radius * (0.008 + random(fleck, 125) * 0.020)
                    let fleckColor = fleck.isMultiple(of: 3)
                        ? Color(red: 0.70, green: 0.53, blue: 0.28).opacity(0.27)
                        : Color(red: 0.08, green: 0.27, blue: 0.14).opacity(0.32)
                    surface.fill(Path(ellipseIn: CGRect(x: point.x - fleckSize,
                                                        y: point.y - fleckSize * 0.45,
                                                        width: fleckSize * 2,
                                                        height: fleckSize * 0.90)),
                                 with: .color(fleckColor))
                }
            }

            // Mountain and desert colour variation remains clipped inside the
            // coastlines so it enriches the land without creating new blobs.
            surface.drawLayer { terrain in
                terrain.clip(to: europeAfrica)
                terrain.fill(Path(ellipseIn: CGRect(x: earthPoint(-0.27, -0.11).x - radius * 0.18,
                                                     y: earthPoint(-0.27, -0.11).y - radius * 0.09,
                                                     width: radius * 0.36,
                                                     height: radius * 0.18)),
                             with: .color(Color(red: 0.76, green: 0.56, blue: 0.28).opacity(0.44)))
                var ridge = Path()
                ridge.move(to: earthPoint(-0.40, -0.48))
                ridge.addCurve(to: earthPoint(-0.03, -0.40),
                               control1: earthPoint(-0.27, -0.57),
                               control2: earthPoint(-0.15, -0.35))
                terrain.stroke(ridge,
                               with: .color(Color(red: 0.79, green: 0.76, blue: 0.62).opacity(0.38)),
                               lineWidth: radius * 0.025)
            }

            // Ice cap follows the sunlit northern limb instead of appearing as
            // a generic white band pasted over the globe.
            var polarCap = Path()
            polarCap.move(to: earthPoint(-0.86, -0.72))
            polarCap.addCurve(to: earthPoint(0.62, -0.76),
                              control1: earthPoint(-0.44, -0.96),
                              control2: earthPoint(0.26, -0.88))
            polarCap.addCurve(to: earthPoint(-0.86, -0.72),
                              control1: earthPoint(0.18, -0.69),
                              control2: earthPoint(-0.42, -0.66))
            polarCap.closeSubpath()
            surface.fill(polarCap,
                         with: .linearGradient(Gradient(colors: [
                            .white.opacity(0.68),
                            Color(red: 0.62, green: 0.87, blue: 1.00).opacity(0.18)
                         ]), startPoint: earthPoint(-0.40, -0.94),
                         endPoint: earthPoint(-0.18, -0.64)))

            surface.drawLayer { terrain in
                terrain.clip(to: south)
                var ridge = Path()
                ridge.move(to: earthPoint(-0.71, -0.05))
                ridge.addCurve(to: earthPoint(-0.61, 0.61),
                               control1: earthPoint(-0.64, 0.15),
                               control2: earthPoint(-0.67, 0.43))
                terrain.stroke(ridge,
                               with: .color(Color(red: 0.68, green: 0.62, blue: 0.44).opacity(0.42)),
                               lineWidth: radius * 0.022)
            }

            // A single directional terminator makes the sphere dimensional.
            // It is laid over the terrain but under clouds and city lights.
            surface.fill(planet,
                         with: .radialGradient(Gradient(stops: [
                            .init(color: .clear, location: 0.38),
                            .init(color: .black.opacity(0.18), location: 0.67),
                            .init(color: .black.opacity(0.72), location: 1)
                         ]),
                         center: CGPoint(x: centre.x - radius * 0.35, y: centre.y - radius * 0.45),
                         startRadius: 0,
                         endRadius: radius * 1.6))

            // Cloud bands follow curved weather systems rather than sitting on
            // the globe as identical horizontal capsules.
            surface.drawLayer { clouds in
                clouds.blendMode = .plusLighter
                clouds.addFilter(.blur(radius: max(0.8, radius * 0.009)))
                for index in 0..<12 {
                    let t = CGFloat(index) / 11
                    let bandY = -0.70 + t * 1.22
                    let startX = -0.86 + random(index, 31) * 0.20
                    let endX = 0.72 - random(index, 32) * 0.18
                    var band = Path()
                    band.move(to: earthPoint(startX, bandY))
                    band.addCurve(to: earthPoint(endX, bandY + (random(index, 33) - 0.5) * 0.16),
                                  control1: earthPoint(-0.38, bandY - 0.13 + random(index, 34) * 0.10),
                                  control2: earthPoint(0.18, bandY + 0.12 - random(index, 35) * 0.10))
                    clouds.stroke(band,
                                  with: .color(.white.opacity(0.12 + Double(random(index, 36)) * 0.13)),
                                  style: StrokeStyle(lineWidth: radius * (0.016 + random(index, 37) * 0.024),
                                                     lineCap: .round))
                }

                // Broken cloud cells keep the weather layer from reading as
                // translucent stripes. Their soft ellipses bunch into fronts
                // and leave enough gaps to see coast and terrain underneath.
                for index in 0..<38 {
                    let x = -0.90 + random(index, 131) * 1.78
                    let y = -0.82 + random(index, 132) * 1.45
                    let width = radius * (0.055 + random(index, 133) * 0.15)
                    let height = width * (0.20 + random(index, 134) * 0.18)
                    let point = earthPoint(x, y)
                    clouds.fill(Path(ellipseIn: CGRect(x: point.x - width * 0.5,
                                                       y: point.y - height * 0.5,
                                                       width: width,
                                                       height: height)),
                                with: .radialGradient(Gradient(colors: [
                                    .white.opacity(0.19 + Double(random(index, 135)) * 0.13),
                                    .white.opacity(0.03)
                                ]), center: point, startRadius: 0,
                                endRadius: width * 0.52))
                }

                // One recognisable cyclonic weather system adds a natural
                // focal detail and helps the globe read as Earth at a glance.
                let stormCentre = earthPoint(0.44, -0.12)
                for ring in 0..<4 {
                    let stormRadius = radius * (0.045 + CGFloat(ring) * 0.032)
                    var spiral = Path()
                    spiral.addArc(center: stormCentre,
                                  radius: stormRadius,
                                  startAngle: .degrees(Double(35 + ring * 22)),
                                  endAngle: .degrees(Double(295 + ring * 34)),
                                  clockwise: false)
                    clouds.stroke(spiral,
                                  with: .color(.white.opacity(0.20 - Double(ring) * 0.025)),
                                  style: StrokeStyle(lineWidth: max(0.8, radius * 0.013),
                                                     lineCap: .round))
                }
            }

            let cityHubs = [CGPoint(x: -0.43, y: -0.47),
                            CGPoint(x: -0.17, y: -0.57),
                            CGPoint(x: 0.02, y: -0.45),
                            CGPoint(x: -0.20, y: -0.17),
                            CGPoint(x: -0.54, y: 0.04)]
            var cityGlow = surface
            cityGlow.blendMode = .plusLighter
            for index in 0..<74 {
                let hub = cityHubs[index % cityHubs.count]
                let x = centre.x + (hub.x + (random(index, 41) - 0.5) * 0.22) * radius
                let y = centre.y + (hub.y + (random(index, 42) - 0.5) * 0.14) * radius
                let dot = 0.55 + random(index, 43) * (isPad ? 1.45 : 1.05)
                let color = index.isMultiple(of: 6)
                    ? Color(red: 1.00, green: 0.94, blue: 0.76)
                    : Color(red: 1.00, green: 0.66, blue: 0.28)
                cityGlow.fill(Path(ellipseIn: CGRect(x: x - dot / 2, y: y - dot / 2,
                                                     width: dot, height: dot)),
                              with: .color(color.opacity(0.30 + Double(random(index, 45)) * 0.46)))
            }
        }

        glow.stroke(Path(ellipseIn: disc), with: .color(cyan.opacity(0.36)), lineWidth: isPad ? 13 : 9)
        glow.stroke(Path(ellipseIn: disc.insetBy(dx: 1, dy: 1)),
                    with: .color(Color(red: 0.63, green: 0.93, blue: 1.00).opacity(0.82)),
                    lineWidth: isPad ? 3 : 2)
    }

    /// Four deliberately different worlds after Earth: a cratered rust moon,
    /// a banded ring giant, a cracked ice world and a volcanic final planet.
    private func drawStylisedPlanet(in context: GraphicsContext, window: CGRect) {
        let geometry = planetGeometry(in: window)
        let centre = geometry.centre
        let radius = geometry.radius
        let disc = CGRect(x: centre.x - radius, y: centre.y - radius,
                          width: radius * 2, height: radius * 2)
        let planet = Path(ellipseIn: disc)

        let light: Color
        let middle: Color
        let dark: Color
        let aura: Color
        switch destination {
        case 2:
            light = Color(red: 1.00, green: 0.50, blue: 0.24)
            middle = Color(red: 0.66, green: 0.16, blue: 0.08)
            dark = Color(red: 0.18, green: 0.025, blue: 0.025)
            aura = Color(red: 1.00, green: 0.25, blue: 0.10)
        case 3:
            light = Color(red: 1.00, green: 0.88, blue: 0.52)
            middle = Color(red: 0.78, green: 0.45, blue: 0.25)
            dark = Color(red: 0.24, green: 0.10, blue: 0.18)
            aura = Color(red: 1.00, green: 0.68, blue: 0.30)
        case 4:
            light = Color(red: 0.76, green: 1.00, blue: 0.98)
            middle = Color(red: 0.12, green: 0.68, blue: 0.78)
            dark = Color(red: 0.015, green: 0.12, blue: 0.28)
            aura = Color(red: 0.30, green: 1.00, blue: 0.92)
        default:
            light = Color(red: 0.98, green: 0.36, blue: 0.62)
            middle = Color(red: 0.45, green: 0.045, blue: 0.18)
            dark = Color(red: 0.10, green: 0.008, blue: 0.055)
            aura = Color(red: 1.00, green: 0.20, blue: 0.58)
        }

        if destination == 3 {
            var rings = context
            rings.blendMode = .plusLighter
            for index in 0..<5 {
                let inset = CGFloat(index) * radius * 0.11
                let ring = CGRect(x: centre.x - radius * 1.72 + inset,
                                  y: centre.y - radius * 0.42 + inset * 0.16,
                                  width: radius * 3.44 - inset * 2,
                                  height: radius * 0.84 - inset * 0.32)
                rings.stroke(Path(ellipseIn: ring),
                             with: .color((index.isMultiple(of: 2) ? light : aura)
                                .opacity(0.34 + Double(index) * 0.055)),
                             lineWidth: max(1.5, radius * 0.032))
            }
        }

        var glow = context
        glow.blendMode = .plusLighter
        glow.fill(Path(ellipseIn: disc.insetBy(dx: -radius * 0.22,
                                               dy: -radius * 0.22)),
                  with: .radialGradient(Gradient(stops: [
                    .init(color: .clear, location: 0.64),
                    .init(color: aura.opacity(0.50), location: 0.82),
                    .init(color: .clear, location: 1)
                  ]), center: centre, startRadius: 0, endRadius: radius * 1.22))

        context.fill(planet,
                     with: .radialGradient(Gradient(colors: [light, middle, dark]),
                                           center: CGPoint(x: centre.x - radius * 0.42,
                                                           y: centre.y - radius * 0.50),
                                           startRadius: 0,
                                           endRadius: radius * 1.65))

        context.drawLayer { surface in
            surface.clip(to: planet)
            switch destination {
            case 2:
                for index in 0..<24 {
                    let angle = random(index, 201) * .pi * 2
                    let distance = sqrt(random(index, 202)) * radius * 0.82
                    let point = CGPoint(x: centre.x + cos(angle) * distance,
                                        y: centre.y + sin(angle) * distance)
                    let size = radius * (0.025 + random(index, 203) * 0.105)
                    let crater = CGRect(x: point.x - size,
                                        y: point.y - size * 0.58,
                                        width: size * 2,
                                        height: size * 1.16)
                    surface.fill(Path(ellipseIn: crater),
                                 with: .radialGradient(Gradient(colors: [dark.opacity(0.72),
                                                                         middle.opacity(0.12)]),
                                                       center: CGPoint(x: point.x + size * 0.20,
                                                                       y: point.y + size * 0.12),
                                                       startRadius: 0,
                                                       endRadius: size))
                    surface.stroke(Path(ellipseIn: crater.offsetBy(dx: -size * 0.08,
                                                                   dy: -size * 0.10)),
                                   with: .color(light.opacity(0.24)),
                                   lineWidth: max(0.7, radius * 0.008))
                }
            case 3:
                for index in 0..<15 {
                    let y = disc.minY + disc.height * (CGFloat(index) + 0.5) / 15
                    let thickness = radius * (0.035 + random(index, 211) * 0.055)
                    let tint = index.isMultiple(of: 3) ? dark : light
                    surface.fill(Path(CGRect(x: disc.minX, y: y,
                                             width: disc.width, height: thickness)),
                                 with: .color(tint.opacity(index.isMultiple(of: 3) ? 0.20 : 0.13)))
                }
                let storm = CGRect(x: centre.x - radius * 0.58,
                                   y: centre.y + radius * 0.08,
                                   width: radius * 0.54,
                                   height: radius * 0.22)
                surface.fill(Path(ellipseIn: storm),
                             with: .radialGradient(Gradient(colors: [light.opacity(0.62),
                                                                     aura.opacity(0.08)]),
                                                   center: CGPoint(x: storm.midX, y: storm.midY),
                                                   startRadius: 0,
                                                   endRadius: storm.width * 0.5))
            case 4:
                for index in 0..<18 {
                    let angle = Double(index) / 18 * .pi * 2 + Double(random(index, 221))
                    let start = CGPoint(x: centre.x + cos(angle) * radius * 0.12,
                                        y: centre.y + sin(angle) * radius * 0.12)
                    let end = CGPoint(x: centre.x + cos(angle + 0.22) * radius * 0.94,
                                      y: centre.y + sin(angle + 0.22) * radius * 0.94)
                    var crack = Path()
                    crack.move(to: start)
                    crack.addLine(to: CGPoint(x: (start.x + end.x) * 0.53 + radius * 0.06,
                                              y: (start.y + end.y) * 0.47))
                    crack.addLine(to: end)
                    surface.stroke(crack,
                                   with: .color(.white.opacity(index.isMultiple(of: 3) ? 0.62 : 0.30)),
                                   lineWidth: max(0.7, radius * 0.009))
                }
            default:
                var lavaGlow = surface
                lavaGlow.blendMode = .plusLighter
                for index in 0..<16 {
                    let angle = Double(index) / 16 * .pi * 2 + Double(random(index, 231)) * 0.4
                    var fissure = Path()
                    fissure.move(to: CGPoint(x: centre.x + cos(angle) * radius * 0.08,
                                             y: centre.y + sin(angle) * radius * 0.08))
                    fissure.addLine(to: CGPoint(x: centre.x + cos(angle + 0.18) * radius * 0.50,
                                                y: centre.y + sin(angle + 0.18) * radius * 0.50))
                    fissure.addLine(to: CGPoint(x: centre.x + cos(angle - 0.08) * radius * 0.95,
                                                y: centre.y + sin(angle - 0.08) * radius * 0.95))
                    surface.stroke(fissure,
                                   with: .color(Color(red: 1.00, green: 0.52, blue: 0.12)
                                    .opacity(0.70)),
                                   lineWidth: max(1.2, radius * 0.018))
                    lavaGlow.stroke(fissure,
                                    with: .color(aura.opacity(0.40)),
                                    lineWidth: max(4, radius * 0.055))
                }
            }

            surface.fill(planet,
                         with: .radialGradient(Gradient(stops: [
                            .init(color: .clear, location: 0.40),
                            .init(color: .black.opacity(0.16), location: 0.68),
                            .init(color: .black.opacity(0.76), location: 1)
                         ]),
                         center: CGPoint(x: centre.x - radius * 0.42,
                                         y: centre.y - radius * 0.46),
                         startRadius: 0,
                         endRadius: radius * 1.58))
        }

        glow.stroke(planet, with: .color(aura.opacity(0.42)),
                    lineWidth: isPad ? 10 : 7)
        context.stroke(planet, with: .color(light.opacity(0.70)),
                       lineWidth: isPad ? 2.5 : 1.7)
    }

    private func drawWindowFrame(in context: GraphicsContext, window: CGRect, cut: CGFloat) {
        let width = frameWidth
        let frame = chamfered(window, cut: cut)
        // Outer shadow well, so the glass reads as recessed into the cabinet.
        context.stroke(chamfered(window, cut: cut, outset: width * 1.15),
                       with: .color(.black.opacity(0.55)),
                       lineWidth: width * 0.9)
        context.stroke(frame, with: .color(.black.opacity(0.85)), lineWidth: width + 14)
        context.stroke(frame,
                       with: .linearGradient(Gradient(colors: [metalLight, metal, metalDark, Color(red: 0.10, green: 0.13, blue: 0.22)]),
                                             startPoint: CGPoint(x: 0, y: window.minY - width),
                                             endPoint: CGPoint(x: 0, y: window.maxY + width)),
                       lineWidth: width)
        context.stroke(chamfered(window, cut: cut, outset: width * 0.55),
                       with: .color(.white.opacity(0.28)), lineWidth: 1.2)
        context.stroke(chamfered(window, cut: cut, outset: -width * 0.45),
                       with: .color(.black.opacity(0.9)), lineWidth: width * 0.35)

        var glow = context
        glow.blendMode = .plusLighter
        let rail = chamfered(window, cut: cut, outset: width * 0.34)
        glow.stroke(rail, with: .color(orange.opacity(0.50)), lineWidth: isPad ? 12 : 8)
        context.stroke(rail, with: .color(orange), lineWidth: isPad ? 3.4 : 2.4)
        context.stroke(chamfered(window, cut: cut, outset: width * 0.34),
                       with: .color(.white.opacity(0.55)),
                       lineWidth: 1)

        let neon = chamfered(window, cut: cut, outset: -width * 0.18)
        glow.stroke(neon, with: .color(cyan.opacity(0.55)), lineWidth: isPad ? 12 : 8)
        context.stroke(neon, with: .color(Color(red: 0.70, green: 0.95, blue: 1.00)),
                       lineWidth: isPad ? 2.8 : 1.8)

        for fraction in [0.22, 0.50, 0.78] as [CGFloat] {
            lightBar(context,
                     center: CGPoint(x: window.minX + window.width * fraction,
                                     y: window.minY - width * 0.02),
                     length: window.width * 0.10,
                     thickness: isPad ? 3.5 : 2.5,
                     color: cyan)
        }

        let boltRadius = width * 0.14
        for corner in [CGPoint(x: window.minX + cut * 0.45, y: window.minY + cut * 0.45),
                       CGPoint(x: window.maxX - cut * 0.45, y: window.minY + cut * 0.45),
                       CGPoint(x: window.minX + cut * 0.45, y: window.maxY - cut * 0.45),
                       CGPoint(x: window.maxX - cut * 0.45, y: window.maxY - cut * 0.45)] {
            let bolt = Path(ellipseIn: CGRect(x: corner.x - boltRadius, y: corner.y - boltRadius,
                                              width: boltRadius * 2, height: boltRadius * 2))
            context.fill(bolt,
                         with: .radialGradient(Gradient(colors: [.white.opacity(0.8), metalLight, metalDark]),
                                               center: CGPoint(x: corner.x - boltRadius * 0.3,
                                                               y: corner.y - boltRadius * 0.3),
                                               startRadius: 0,
                                               endRadius: boltRadius))
            context.stroke(bolt, with: .color(.black.opacity(0.7)), lineWidth: 1)
        }
    }

    private func drawSpaceDust(in context: GraphicsContext, window: CGRect, time: TimeInterval) {
        var glow = context
        glow.blendMode = .plusLighter
        for index in 0..<24 {
            let depth = random(index, 81)
            let speed: CGFloat = 0.008 + depth * 0.02
            let x = window.minX + wrap(random(index, 82) - CGFloat(time) * speed) * window.width
            let y = window.minY + wrap(random(index, 83) + CGFloat(time) * speed * 0.15) * window.height
            let radius: CGFloat = 0.4 + depth * (isPad ? 1.6 : 1.1)
            let tint = index.isMultiple(of: 5) ? cyan : Color.white
            glow.fill(Path(ellipseIn: CGRect(x: x, y: y, width: radius, height: radius)),
                      with: .color(tint.opacity(0.25 + Double(depth) * 0.45)))
        }
    }

    private func drawGalaxyShimmer(in context: GraphicsContext, window: CGRect, time: TimeInterval) {
        guard destination == 1 else { return }
        var glow = context
        glow.blendMode = .plusLighter
        let origin = CGPoint(x: window.minX + window.width * 0.215,
                             y: window.minY + window.height * 0.285)
        let breathe = 0.055 + 0.028 * sin(time * 0.7)
        let radius = window.height * 0.17
        glow.fill(Path(ellipseIn: CGRect(x: origin.x - radius, y: origin.y - radius * 0.65,
                                         width: radius * 2, height: radius * 1.3)),
                  with: .radialGradient(Gradient(colors: [Color(red: 0.85, green: 0.55, blue: 1).opacity(breathe),
                                                          .clear]),
                                        center: origin,
                                        startRadius: 0,
                                        endRadius: radius))
    }

    private func drawCabinetPulse(in context: GraphicsContext, window: CGRect, time: TimeInterval) {
        let pulse = 0.18 + 0.16 * (0.5 + 0.5 * sin(time * 1.4))
        var glow = context
        glow.blendMode = .plusLighter
        let rail = chamfered(window, cut: min(window.width, window.height) * 0.11,
                             outset: frameWidth * 0.34)
        glow.stroke(rail, with: .color(orange.opacity(pulse)), lineWidth: isPad ? 7 : 5)
        let neon = chamfered(window, cut: min(window.width, window.height) * 0.11,
                             outset: -frameWidth * 0.18)
        glow.stroke(neon, with: .color(cyan.opacity(pulse * 0.7)), lineWidth: isPad ? 6 : 4)
    }

    /// A bespoke vector hologram for every selectable character. Nothing here
    /// is an image asset: the seal is assembled from paths, ellipses and light
    /// strokes, so it remains crisp when the cockpit scales to another device.
    private func drawCharacterMark(in context: GraphicsContext,
                                   centre: CGPoint,
                                   radius: CGFloat,
                                   alpha: Double) {
        var glow = context
        glow.blendMode = .plusLighter
        let accent = character.color
        let line = max(1.0, radius * 0.085)

        // Character identity sits inside an orbital badge shared by the fleet.
        let orbitWide = CGRect(x: centre.x - radius * 1.22,
                               y: centre.y - radius * 0.58,
                               width: radius * 2.44,
                               height: radius * 1.16)
        let orbitTall = CGRect(x: centre.x - radius * 0.84,
                               y: centre.y - radius * 0.92,
                               width: radius * 1.68,
                               height: radius * 1.84)
        glow.stroke(Path(ellipseIn: orbitWide),
                    with: .color(cyan.opacity(0.42 * alpha)),
                    lineWidth: line * 0.45)
        glow.stroke(Path(ellipseIn: orbitTall),
                    with: .color(accent.opacity(0.35 * alpha)),
                    lineWidth: line * 0.36)
        for index in 0..<5 {
            let angle = Double(index) / 5 * .pi * 2 - .pi / 2
            let star = CGPoint(x: centre.x + cos(angle) * radius * 1.10,
                               y: centre.y + sin(angle) * radius * 0.52)
            let dot = max(1.2, radius * (index == 0 ? 0.075 : 0.045))
            glow.fill(Path(ellipseIn: CGRect(x: star.x - dot, y: star.y - dot,
                                             width: dot * 2, height: dot * 2)),
                      with: .color((index.isMultiple(of: 2) ? accent : cyan)
                        .opacity(0.88 * alpha)))
        }

        func ellipse(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> Path {
            Path(ellipseIn: CGRect(x: centre.x + x * radius,
                                   y: centre.y + y * radius,
                                   width: width * radius,
                                   height: height * radius))
        }
        func stroke(_ path: Path, color: Color = cyan, width: CGFloat = 1) {
            glow.stroke(path,
                        with: .color(color.opacity(0.92 * alpha)),
                        style: StrokeStyle(lineWidth: line * width,
                                           lineCap: .round,
                                           lineJoin: .round))
        }
        func fill(_ path: Path, color: Color = cyan, opacity: Double = 0.30) {
            glow.fill(path, with: .color(color.opacity(opacity * alpha)))
        }

        var face = Path()
        switch character.id {
        case "flying_penguin":
            face = ellipse(-0.58, -0.63, 1.16, 1.30)
            stroke(face, color: accent, width: 1.05)
            var mask = Path()
            mask.move(to: CGPoint(x: centre.x, y: centre.y - radius * 0.34))
            mask.addCurve(to: CGPoint(x: centre.x - radius * 0.39, y: centre.y + radius * 0.20),
                          control1: CGPoint(x: centre.x - radius * 0.10, y: centre.y - radius * 0.62),
                          control2: CGPoint(x: centre.x - radius * 0.50, y: centre.y - radius * 0.13))
            mask.move(to: CGPoint(x: centre.x, y: centre.y - radius * 0.34))
            mask.addCurve(to: CGPoint(x: centre.x + radius * 0.39, y: centre.y + radius * 0.20),
                          control1: CGPoint(x: centre.x + radius * 0.10, y: centre.y - radius * 0.62),
                          control2: CGPoint(x: centre.x + radius * 0.50, y: centre.y - radius * 0.13))
            stroke(mask, width: 0.68)
            var beak = Path()
            beak.move(to: CGPoint(x: centre.x, y: centre.y + radius * 0.04))
            beak.addLine(to: CGPoint(x: centre.x + radius * 0.22, y: centre.y + radius * 0.17))
            beak.addLine(to: CGPoint(x: centre.x, y: centre.y + radius * 0.27))
            beak.addLine(to: CGPoint(x: centre.x - radius * 0.22, y: centre.y + radius * 0.17))
            beak.closeSubpath()
            fill(beak, color: accent, opacity: 0.72)
            stroke(beak, color: accent, width: 0.55)

        case "bunny":
            let leftEar = ellipse(-0.49, -1.10, 0.36, 0.92)
            let rightEar = ellipse(0.13, -1.10, 0.36, 0.92)
            fill(leftEar, color: accent, opacity: 0.20)
            fill(rightEar, color: accent, opacity: 0.20)
            stroke(leftEar, color: accent)
            stroke(rightEar, color: accent)
            face = ellipse(-0.62, -0.54, 1.24, 1.18)
            stroke(face, width: 1.05)

        case "dog":
            face = ellipse(-0.60, -0.58, 1.20, 1.18)
            stroke(face, color: accent, width: 1.05)
            var ears = Path()
            ears.move(to: CGPoint(x: centre.x - radius * 0.42, y: centre.y - radius * 0.45))
            ears.addQuadCurve(to: CGPoint(x: centre.x - radius * 0.82, y: centre.y + radius * 0.08),
                              control: CGPoint(x: centre.x - radius * 0.90, y: centre.y - radius * 0.50))
            ears.addQuadCurve(to: CGPoint(x: centre.x - radius * 0.50, y: centre.y + radius * 0.23),
                              control: CGPoint(x: centre.x - radius * 0.66, y: centre.y + radius * 0.31))
            ears.move(to: CGPoint(x: centre.x + radius * 0.42, y: centre.y - radius * 0.45))
            ears.addQuadCurve(to: CGPoint(x: centre.x + radius * 0.82, y: centre.y + radius * 0.08),
                              control: CGPoint(x: centre.x + radius * 0.90, y: centre.y - radius * 0.50))
            ears.addQuadCurve(to: CGPoint(x: centre.x + radius * 0.50, y: centre.y + radius * 0.23),
                              control: CGPoint(x: centre.x + radius * 0.66, y: centre.y + radius * 0.31))
            stroke(ears, color: accent, width: 1.08)
            stroke(ellipse(-0.34, 0.02, 0.68, 0.52), width: 0.55)

        case "lion":
            var mane = Path()
            let points = 18
            for index in 0...points {
                let angle = Double(index) / Double(points) * .pi * 2 - .pi / 2
                let spoke = index.isMultiple(of: 2) ? radius * 0.98 : radius * 0.76
                let point = CGPoint(x: centre.x + cos(angle) * spoke,
                                    y: centre.y + sin(angle) * spoke)
                if index == 0 {
                    mane.move(to: point)
                } else {
                    mane.addLine(to: point)
                }
            }
            mane.closeSubpath()
            fill(mane, color: accent, opacity: 0.20)
            stroke(mane, color: accent, width: 0.88)
            face = ellipse(-0.57, -0.54, 1.14, 1.20)
            fill(face, color: cyan, opacity: 0.10)
            stroke(face, width: 1.06)
            stroke(ellipse(-0.52, -0.66, 0.36, 0.34), color: accent, width: 0.65)
            stroke(ellipse(0.16, -0.66, 0.36, 0.34), color: accent, width: 0.65)

        case "octopus":
            var dome = Path()
            dome.move(to: CGPoint(x: centre.x - radius * 0.64, y: centre.y + radius * 0.05))
            dome.addQuadCurve(to: CGPoint(x: centre.x + radius * 0.64, y: centre.y + radius * 0.05),
                              control: CGPoint(x: centre.x, y: centre.y - radius * 0.98))
            stroke(dome, color: accent, width: 1.10)
            for index in 0..<5 {
                let x = (CGFloat(index) - 2) * radius * 0.27
                var tentacle = Path()
                tentacle.move(to: CGPoint(x: centre.x + x, y: centre.y + radius * 0.02))
                tentacle.addCurve(to: CGPoint(x: centre.x + x + (index.isMultiple(of: 2) ? -1 : 1) * radius * 0.13,
                                               y: centre.y + radius * 0.61),
                                  control1: CGPoint(x: centre.x + x - radius * 0.11, y: centre.y + radius * 0.24),
                                  control2: CGPoint(x: centre.x + x + radius * 0.14, y: centre.y + radius * 0.43))
                stroke(tentacle, color: index.isMultiple(of: 2) ? accent : cyan, width: 0.78)
            }

        case "crab":
            face = ellipse(-0.64, -0.38, 1.28, 0.86)
            stroke(face, color: accent, width: 1.08)
            for side in [-1.0, 1.0] as [CGFloat] {
                var claw = Path()
                claw.move(to: CGPoint(x: centre.x + side * radius * 0.55, y: centre.y - radius * 0.02))
                claw.addQuadCurve(to: CGPoint(x: centre.x + side * radius * 0.98, y: centre.y - radius * 0.35),
                                  control: CGPoint(x: centre.x + side * radius * 0.90, y: centre.y + radius * 0.10))
                claw.addQuadCurve(to: CGPoint(x: centre.x + side * radius * 0.72, y: centre.y - radius * 0.56),
                                  control: CGPoint(x: centre.x + side * radius * 1.02, y: centre.y - radius * 0.70))
                stroke(claw, color: accent, width: 0.95)
                stroke(ellipse(side < 0 ? -0.42 : 0.26, -0.64, 0.16, 0.30), width: 0.55)
            }

        case "elephant":
            face = ellipse(-0.52, -0.62, 1.04, 1.13)
            stroke(face, width: 1.05)
            let leftEar = ellipse(-0.91, -0.48, 0.70, 0.91)
            let rightEar = ellipse(0.21, -0.48, 0.70, 0.91)
            fill(leftEar, color: accent, opacity: 0.19)
            fill(rightEar, color: accent, opacity: 0.19)
            stroke(leftEar, color: accent, width: 0.86)
            stroke(rightEar, color: accent, width: 0.86)
            var trunk = Path()
            trunk.move(to: CGPoint(x: centre.x, y: centre.y + radius * 0.03))
            trunk.addCurve(to: CGPoint(x: centre.x + radius * 0.22, y: centre.y + radius * 0.70),
                           control1: CGPoint(x: centre.x - radius * 0.12, y: centre.y + radius * 0.34),
                           control2: CGPoint(x: centre.x - radius * 0.08, y: centre.y + radius * 0.66))
            stroke(trunk, color: accent, width: 1.0)

        case "bear":
            stroke(ellipse(-0.68, -0.76, 0.48, 0.48), color: accent, width: 0.85)
            stroke(ellipse(0.20, -0.76, 0.48, 0.48), color: accent, width: 0.85)
            face = ellipse(-0.64, -0.60, 1.28, 1.25)
            stroke(face, width: 1.08)
            stroke(ellipse(-0.34, 0.02, 0.68, 0.52), color: accent, width: 0.62)

        case "fox":
            var fox = Path()
            fox.move(to: CGPoint(x: centre.x - radius * 0.72, y: centre.y - radius * 0.82))
            fox.addLine(to: CGPoint(x: centre.x - radius * 0.52, y: centre.y + radius * 0.16))
            fox.addQuadCurve(to: CGPoint(x: centre.x, y: centre.y + radius * 0.65),
                             control: CGPoint(x: centre.x - radius * 0.34, y: centre.y + radius * 0.56))
            fox.addQuadCurve(to: CGPoint(x: centre.x + radius * 0.52, y: centre.y + radius * 0.16),
                             control: CGPoint(x: centre.x + radius * 0.34, y: centre.y + radius * 0.56))
            fox.addLine(to: CGPoint(x: centre.x + radius * 0.72, y: centre.y - radius * 0.82))
            fox.addLine(to: CGPoint(x: centre.x, y: centre.y - radius * 0.50))
            fox.closeSubpath()
            fill(fox, color: accent, opacity: 0.18)
            stroke(fox, color: accent, width: 1.03)

        default: // frog
            face = ellipse(-0.72, -0.46, 1.44, 1.02)
            stroke(face, color: accent, width: 1.05)
            stroke(ellipse(-0.62, -0.78, 0.52, 0.52), color: accent, width: 0.90)
            stroke(ellipse(0.10, -0.78, 0.52, 0.52), color: accent, width: 0.90)
            var smile = Path()
            smile.move(to: CGPoint(x: centre.x - radius * 0.40, y: centre.y + radius * 0.17))
            smile.addQuadCurve(to: CGPoint(x: centre.x + radius * 0.40, y: centre.y + radius * 0.17),
                               control: CGPoint(x: centre.x, y: centre.y + radius * 0.52))
            stroke(smile, width: 0.62)
        }

        // Consistent luminous facial anchors keep even the more abstract marks
        // friendly and legible at phone scale.
        if character.id != "crab" {
            for side in [-1.0, 1.0] as [CGFloat] {
                let eye = ellipse(side < 0 ? -0.31 : 0.19, -0.17, 0.12, 0.12)
                fill(eye, color: .white, opacity: 0.92)
            }
        }
        if !["flying_penguin", "octopus", "crab", "elephant", "frog"].contains(character.id) {
            var nose = Path()
            nose.move(to: CGPoint(x: centre.x, y: centre.y + radius * 0.05))
            nose.addLine(to: CGPoint(x: centre.x - radius * 0.10, y: centre.y + radius * 0.19))
            nose.addLine(to: CGPoint(x: centre.x + radius * 0.10, y: centre.y + radius * 0.19))
            nose.closeSubpath()
            fill(nose, color: accent, opacity: 0.88)
        }
    }

    // MARK: Helpers

    private func chamfered(_ rect: CGRect, cut: CGFloat, outset: CGFloat = 0) -> Path {
        let r = rect.insetBy(dx: -outset, dy: -outset)
        // Offsetting a 45° chamfer by d moves its axis cut by d · (2 − √2).
        let c = max(0, min(cut + outset * 0.586, min(r.width, r.height) * 0.5))
        var path = Path()
        path.move(to: CGPoint(x: r.minX + c, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX - c, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX, y: r.minY + c))
        path.addLine(to: CGPoint(x: r.maxX, y: r.maxY - c))
        path.addLine(to: CGPoint(x: r.maxX - c, y: r.maxY))
        path.addLine(to: CGPoint(x: r.minX + c, y: r.maxY))
        path.addLine(to: CGPoint(x: r.minX, y: r.maxY - c))
        path.addLine(to: CGPoint(x: r.minX, y: r.minY + c))
        path.closeSubpath()
        return path
    }

    private func seam(_ context: GraphicsContext, from start: CGPoint, to end: CGPoint) {
        var path = Path()
        path.move(to: start)
        path.addLine(to: end)
        context.stroke(path, with: .color(.black.opacity(0.55)), lineWidth: 1.6)
        context.stroke(path.offsetBy(dx: 0.8, dy: 0.8), with: .color(.white.opacity(0.07)), lineWidth: 0.8)
    }

    private func lightBar(_ context: GraphicsContext,
                          center: CGPoint,
                          length: CGFloat,
                          thickness: CGFloat,
                          color: Color,
                          vertical: Bool = false) {
        let width = vertical ? thickness : length
        let height = vertical ? length : thickness
        let bar = CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
        var glow = context
        glow.blendMode = .plusLighter
        glow.fill(Path(roundedRect: bar.insetBy(dx: -thickness * 1.4, dy: -thickness * 1.4),
                       cornerRadius: thickness * 2),
                  with: .color(color.opacity(0.22)))
        context.fill(Path(roundedRect: bar, cornerRadius: thickness / 2), with: .color(color))
        context.fill(Path(roundedRect: bar.insetBy(dx: thickness * 0.3, dy: thickness * 0.3),
                          cornerRadius: thickness / 2),
                     with: .color(.white.opacity(0.55)))
    }

    /// A stable pseudo-random value in 0..<1, so the star field and planet
    /// surface are identical on every frame.
    private func random(_ index: Int, _ salt: Int) -> CGFloat {
        Self.seededValue(index, salt)
    }

    private static func seededValue(_ index: Int, _ salt: Int) -> CGFloat {
        var x = UInt64(truncatingIfNeeded: index &* 7919 &+ salt &* 104_729 &+ 1)
        x ^= x >> 33
        x &*= 0xff51afd7ed558ccd
        x ^= x >> 33
        x &*= 0xc4ceb9fe1a85ec53
        x ^= x >> 33
        return CGFloat(x % 10_000) / 10_000
    }

    private func wrap(_ value: CGFloat) -> CGFloat {
        let remainder = value.truncatingRemainder(dividingBy: 1)
        return remainder < 0 ? remainder + 1 : remainder
    }
}
