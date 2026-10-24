import SwiftUI

/// The renderer and steering simulation share a single distance clock. The
/// existing session engine remains authoritative for questions and rewards.
struct HoneySlidePlayfield: View {
    @ObservedObject var model: GameViewModel
    let running: Bool
    let onPause: () -> Void
    let onCompletion: () -> Void
    @State private var simulation = HoneySlideSimulation()
    @State private var lastTick: TimeInterval?
    @State private var completionReported = false
    @State private var lastPrompt: String?
    @State private var artworkTexts: [String] = []
    @State private var collectionTexts: [String] = []
    #if DEBUG
    @State private var visualCheckPrepared = false
    private var visualCheck: (correct: Bool, age: Double)? {
        guard let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--honey-visual-check=") }) else { return nil }
        let fields = argument.dropFirst("--honey-visual-check=".count).split(separator: ":")
        guard fields.count == 2, let age = Double(fields[1]), age >= 0, age <= 2 else { return nil }
        return (fields[0] == "correct", age)
    }
    #endif
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var distance: Double { simulation.elapsed }

    var body: some View {
        GeometryReader { proxy in
            let scale = min(proxy.size.width / 1600, proxy.size.height / 900)
            let sideMargin = max(12, 22 * scale)
            // The safe area already supplies the device's edge clearance.
            // Use our small margin as a floor instead of adding it again.
            let leadingInset = max(proxy.safeAreaInsets.leading, sideMargin)
            let trailingInset = max(proxy.safeAreaInsets.trailing, sideMargin)
            ZStack {
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        guard running, !simulation.hasFinishStarted else { return }
                        let point = CGPoint(x: value.location.x / proxy.size.width * 1600,
                                            y: value.location.y / proxy.size.height * 900 - simulation.jumpCameraOffset)
                        if let target = HoneySlideRules.steeringTarget(at: point, elapsed: simulation.travelTime, course: simulation.course,
                            widthProfile: simulation.widthProfile, cameraZoom: simulation.cameraZoom, cameraOffset: simulation.cameraOffset) {
                            simulation.steer(to: target)
                        }
                    }.onEnded { _ in simulation.release() })
                HoneyAnswerAccessibility(options: simulation.activeCheckpoint?.revealedAt != nil ? simulation.activeCheckpoint?.options ?? [] : [], enabled: running && !simulation.hasFinishStarted) { index in
                    if let row = simulation.activeCheckpoint {
                        simulation.targetLateral = row.lateralPosition(at: index, elapsed: simulation.elapsed)
                    }
                }
                .equatable()
                .allowsHitTesting(false)
                VStack {
                    hud(scale: scale, width: proxy.size.width - leadingInset - trailingInset)
                        .opacity(simulation.hasFinishLaunched ? max(0, 1 - simulation.finishFlightProgress * 6) : 1)
                    Spacer()
                }
                .foregroundStyle(.white)
                .padding(.leading, leadingInset)
                .padding(.trailing, trailingInset)
                .padding(.top, proxy.safeAreaInsets.top + max(10, 32 * scale))
                .padding(.bottom, max(proxy.safeAreaInsets.bottom, 34 * scale))
            }
            .backgroundPreferenceValue(HoneyScoreAnchor.self) { anchor in
                GeometryReader { background in
                    HoneySlideWorld(simulation: simulation, rider: Image("1_bear"), reduceMotion: reduceMotion,
                                    collectionTarget: anchor.score.map { background[$0] })
                }
            }
            .overlayPreferenceValue(HoneyScoreAnchor.self) { anchor in
                // Keep the effects and numbered textures mounted before a hit.
                // One layer carries the pot all the way above the HUD.
                HoneyImpactEffects(simulation: simulation, rider: Image("1_bear"), reduceMotion: reduceMotion,
                    target: anchor.score.map { proxy[$0] })
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            .contentShape(Rectangle())
            .onAppear { simulation.configureViewport(proxy.size, reduceMotion: reduceMotion) }
            .onChange(of: proxy.size) { _, size in simulation.configureViewport(size, reduceMotion: reduceMotion) }
            .onChange(of: reduceMotion) { _, reduced in simulation.configureViewport(proxy.size, reduceMotion: reduced) }

        }
        .onChange(of: running) { _, _ in lastTick = nil; simulation.release() }
        .onChange(of: model.isGameOver) { _, over in
            if !over { completionReported = false; lastTick = nil }
        }
        .onChange(of: model.visibleRounds) { _, _ in synchronizeCheckpoints() }
        .onChange(of: model.acceptsInput) { _, new in if new { synchronizeCheckpoints() } }
        .onAppear { synchronizeCheckpoints() }
        .task(id: artworkTexts) { @MainActor in
            // Canvas symbols are resolved lazily. Explicitly prepare labels
            // behind the intro card and two questions before they are needed.
            for text in artworkTexts {
                guard !Task.isCancelled else { return }
                _ = HoneyArtworkCache.shared.image(key: "label:\(text)", size: CGSize(width: 172, height: 156),
                    density: 2, content: HoneyPotLabelSymbol(text: text))
                await Task.yield()
            }
        }
        .task(id: collectionTexts) { @MainActor in
            #if canImport(UIKit)
            for text in collectionTexts {
                guard !Task.isCancelled else { return }
                _ = HoneyArtworkCache.shared.collectionImage(text: text)
                await Task.yield()
            }
            #endif
        }
        .onDisappear { lastTick = nil; simulation.release() }
        .background {
            ZStack {
                HoneyDisplayClock(running: running) { timestamp in tick(at: timestamp) }
                HoneyKeyboard { direction, held in
                    guard running else { return }
                    if held { simulation.press(Double(direction)) } else { simulation.release() }
                }
            }
        }
    }

    private func hud(scale: CGFloat, width: CGFloat) -> some View {
        HoneyHUD(scale: scale, width: width, prompt: displayedPrompt,
                 score: displayedHoney,
                 questionNumber: min(model.totalQuestions, max(1, model.round?.number ?? model.visibleRounds.first?.number ?? model.roundNumber)),
                 totalQuestions: model.totalQuestions,
                 canPause: !model.isGameOver,
                 showsFeedback: simulation.feedbackRemaining > 0 && !simulation.lastWasCorrect,
                 missedChallenge: displayedCorrection, onPause: onPause)
            .equatable()
    }

    private var displayedHoney: Int {
        #if DEBUG
        if visualCheckPrepared { return simulation.lastWasCorrect ? 1 - simulation.pendingHoney : 4 }
        #endif
        return max(0, model.cards - simulation.pendingHoney)
    }

    private var displayedPrompt: String {
        if simulation.hasFinishStarted { return L(key: "honey.finish") }
        #if DEBUG
        if visualCheckPrepared, let next = model.visibleRounds.first(where: { $0.id == simulation.activeCheckpoint?.roundID }) {
            return next.question.prompt
        }
        #endif
        return model.round?.question.prompt ?? lastPrompt ?? "…"
    }

    private var displayedCorrection: String {
        #if DEBUG
        if visualCheckPrepared, !simulation.lastWasCorrect, let round = model.round, let answer = round.correctOption {
            return round.question.prompt.replacingOccurrences(of: "?", with: answer.text)
        }
        #endif
        if let missed = model.lastMissedChallenge { return missed }
        // Lay out the first possible correction behind the intro card too.
        // Its first appearance must not prepare a new font/sign during play.
        if let round = model.round ?? model.visibleRounds.first, let answer = round.correctOption {
            return round.question.prompt.replacingOccurrences(of: "?", with: answer.text)
        }
        return ""
    }

    private func synchronizeCheckpoints() {
        #if DEBUG
        if visualCheckPrepared { return }
        #endif
        simulation.synchronize(rounds: model.visibleRounds, stage: model.stageNumber,
                               acceptingInput: model.acceptsInput, completed: model.completedQuestions,
                               streak: model.correctStreak, mistakes: model.mistakeStreak,
                               totalQuestions: model.totalQuestions)
        artworkTexts = Array(Set(simulation.checkpoints.prefix(3).flatMap { $0.options.map(\.text) })).sorted()
        collectionTexts = Array(Set(simulation.checkpoints.prefix(3).map {
            $0.options.first(where: \.isCorrect)?.text ?? ""
        })).sorted()
        #if DEBUG
        // Freeze a real simulation outcome for repeatable animation/layout QA.
        // This path never selects an answer or changes the player's saved score.
        if model.acceptsInput, !visualCheckPrepared, let check = visualCheck, let row = simulation.activeCheckpoint,
           let index = row.options.firstIndex(where: { $0.isCorrect == check.correct }) {
            simulation.steer(to: row.lateralPosition(at: index, elapsed: simulation.elapsed))
            while simulation.crossing(roundID: row.roundID!) == nil { simulation.advance(seconds: 1.0 / 120) }
            simulation.markSelected(checkpointID: row.id, index: index, correct: check.correct)
            simulation.advance(seconds: check.age)
            visualCheckPrepared = true
        }
        #endif
    }

    private func tick(at now: TimeInterval) {
        #if DEBUG
        if visualCheckPrepared { return }
        #endif
        if model.isGameOver, !completionReported, simulation.isFinishComplete {
            completionReported = true
            onCompletion()
        }
        guard running else { return }
        defer { lastTick = now }
        guard let previous = lastTick else { return }
        // Don't discard elapsed time on a slow frame: doing that made the
        // world crawl while the separate session timer continued at full rate.
        var remaining = max(0, now - previous)
        // Resolve each world crossing before moving into another question.
        // A dropped frame can include pickups, boosts and several answers.
        while remaining > 0 {
            let dt = min(1.0 / 60, remaining)
            simulation.advance(seconds: dt)
            if model.acceptsInput, let round = model.round,
               let hit = simulation.crossing(roundID: round.id) {
                lastPrompt = round.question.prompt
                let jumpScores = hit.option == nil && simulation.activeCheckpoint?.correctIsAbsent == true
                let optionID = jumpScores ? model.round?.correctOption?.id : hit.option?.id
                if model.select(optionID: optionID) {
                    simulation.markSelected(checkpointID: hit.checkpointID, index: hit.index,
                                            correct: jumpScores || hit.isCorrect)
                    model.reportCatchOutcome(isCorrect: jumpScores || hit.isCorrect)
                    synchronizeCheckpoints()
                }
            }
            remaining -= dt
        }
        if model.isGameOver, !completionReported, simulation.isFinishComplete {
            completionReported = true
            onCompletion()
        }
    }

}

private struct HoneySlideWorld: View {
    // Immutable snapshot: asynchronous drawing never reads live @State or the
    // scoring model, keeping complex forest rendering off the input/UI path.
    let simulation: HoneySlideSimulation
    let rider: Image?
    let reduceMotion: Bool
    let collectionTarget: CGRect?
    init(simulation: HoneySlideSimulation, rider: Image? = nil, reduceMotion: Bool = false,
         collectionTarget: CGRect? = nil) {
        self.simulation = simulation
        self.rider = rider
        self.reduceMotion = reduceMotion
        self.collectionTarget = collectionTarget
    }
    private var distance: Double { simulation.elapsed }
    var body: some View {
        Canvas(opaque: true, rendersAsynchronously: true) { context, size in
            var c = context
            c.scaleBy(x: size.width / 1600, y: size.height / 900)
            c.translateBy(x: 0, y: simulation.jumpCameraOffset)
            let projection = HoneySlideProjection(elapsed: simulation.travelTime, course: simulation.course, widthProfile: simulation.widthProfile, cameraZoom: simulation.cameraZoom, cameraOffset: simulation.cameraOffset)
            drawWorld(&c, projection: projection, billboardYScale: HoneySlideRules.billboardVerticalScale(viewport: size))
            if rider != nil {
                var riderContext = context
                riderContext.translateBy(x: 0, y: simulation.jumpCameraOffset * size.height / 900)
                HoneyTubeWater.draw(in: riderContext, size: size, simulation: simulation, foreground: false, reduceMotion: reduceMotion)
                HoneyRiderDrawing.draw(in: riderContext, size: size, simulation: simulation, reduceMotion: reduceMotion)
                HoneyTubeWater.draw(in: riderContext, size: size, simulation: simulation, foreground: true, reduceMotion: reduceMotion)
            }
        } symbols: {
            ForEach(0..<4) { variant in
                HoneyBitmapSymbol(key: "tree:\(variant)", size: CGSize(width: 230, height: 300), density: 3,
                    content: HoneyTreeSymbol(variant: variant)).equatable()
                    .tag(variant)
            }
            ForEach(0..<2) { variant in
                HoneyBitmapSymbol(key: "brush:\(variant)", size: CGSize(width: 220, height: 112),
                    content: HoneyUnderbrushSymbol(variant: variant)).equatable()
                    .tag(variant + 4)
            }
            ForEach(0..<2) { variant in
                HoneyBitmapSymbol(key: "cliff:\(variant)", size: CGSize(width: 360, height: 330), density: 3,
                    content: HoneyCliffSymbol(variant: variant)).equatable().tag(8 + variant)
            }
            ForEach(0..<4) { variant in
                HoneyBitmapSymbol(key: "rail-face:\(variant)", size: CGSize(width: 256, height: 96),
                    content: HoneyRailFaceSymbol(variant: variant)).equatable().tag("rail-face:\(variant)")
            }
            HoneyBitmapSymbol(key: "rail-cap", size: CGSize(width: 256, height: 64),
                content: HoneyRailCapSymbol()).equatable().tag("rail-cap")
            ForEach(0..<3) { variant in
                HoneyBitmapSymbol(key: "divider-left:\(variant)", size: CGSize(width: 256, height: 70),
                    content: HoneyDividerFaceSymbol(variant: variant, rightSide: false)).equatable().tag("divider-left:\(variant)")
                HoneyBitmapSymbol(key: "divider-right:\(variant)", size: CGSize(width: 256, height: 70),
                    content: HoneyDividerFaceSymbol(variant: variant, rightSide: true)).equatable().tag("divider-right:\(variant)")
            }
            HoneyBitmapSymbol(key: "closed-pot", size: CGSize(width: 308, height: 332), content: HoneyClosedPotSymbol()).equatable().tag("closed-pot")
            HoneyBitmapSymbol(key: "open-pot", size: CGSize(width: 308, height: 332),
                content: HoneyPotIllustration(text: "")).equatable().tag("open-pot")
            HoneyBitmapSymbol(key: "pot-shutter", size: CGSize(width: 172, height: 156),
                content: HoneyPotShutterSymbol()).equatable().tag("pot-shutter")
            ForEach(potTexts, id: \.self) { text in
                HoneyBitmapSymbol(key: "label:\(text)", size: CGSize(width: 172, height: 156),
                    content: HoneyPotLabelSymbol(text: text)).equatable().tag("label:\(text)")
            }
            ForEach(HoneyTrackItemKind.allCases.filter { $0 != .whirlpool }, id: \.self) { kind in
                HoneyBitmapSymbol(key: "race-prop-v5:\(kind.rawValue)", size: CGSize(width: 420, height: 380),
                    content: HoneyRaceItemSymbol(kind: kind)).equatable().tag("race:\(kind.rawValue)")
            }
            if let rider {
                rider.resizable().scaledToFit().frame(width: 400, height: 400 * HoneyRiderDrawing.artworkAspect).tag("rider")
            }
        }
        .accessibilityHidden(true)
    }

    // The course is sampled in world coordinates. Advancing the camera reveals
    // existing bends; it never regenerates a curve from screen-space phases.
    private var potTexts: [String] {
        // Only the small labels depend on the question. The pot itself shares
        // one bundled texture across every answer, level and collection flight.
        Array(Set(simulation.checkpoints.prefix(3).flatMap { $0.options.map(\.text) })).sorted()
    }

    private func point(_ depth: Double, _ offset: Double, _ projection: HoneySlideProjection) -> CGPoint {
        projection.point(depth: depth, offset: offset)
    }

    private func ridingPoint(_ depth: Double, _ offset: Double) -> CGPoint {
        HoneySlideRules.ridingPoint(depth: depth, lateral: offset, distance: simulation.travelTime, course: simulation.course, cameraZoom: simulation.cameraZoom, cameraOffset: simulation.cameraOffset)
    }

    private func ribbon(_ low: Double, _ high: Double, _ projection: HoneySlideProjection) -> Path {
        var p = Path()
        let samples: [Double]
        if let end = simulation.finish?.roadEnd {
            let endDepth = HoneySlideRules.depth(ahead: end - simulation.distance)
            samples = [endDepth] + HoneySlideRules.trackDepthSamples.filter { $0 > endDepth }
        } else { samples = HoneySlideRules.trackDepthSamples }
        for (i, t) in samples.enumerated() {
            let a = point(t, low, projection)
            if i == 0 { p.move(to: a) } else { p.addLine(to: a) }
        }
        for t in samples.reversed() { p.addLine(to: point(t, high, projection)) }
        p.closeSubpath()
        return p
    }

    private func ellipse(_ c: inout GraphicsContext, _ rect: CGRect, _ colors: [Color]) {
        c.fill(Path(ellipseIn: rect), with: .linearGradient(Gradient(colors: colors), startPoint: rect.origin,
                  endPoint: CGPoint(x: rect.maxX, y: rect.maxY)))
    }
    private func rounded(_ c: inout GraphicsContext, _ rect: CGRect, _ radius: CGFloat, _ color: Color) {
        c.fill(Path(roundedRect: rect, cornerRadius: radius), with: .color(color))
    }
    private func drawWorld(_ c: inout GraphicsContext, projection: HoneySlideProjection, billboardYScale: Double) {
        c.fill(Path(CGRect(x: 0, y: -900, width: 1600, height: 1800)), with: .linearGradient(
            Gradient(colors: [Color(red: 0.20, green: 0.70, blue: 0.96), Color(red: 0.85, green: 0.96, blue: 0.88)]),
            startPoint: .zero, endPoint: CGPoint(x: 0, y: 400)))
        let pan = sin(distance * 0.14) * 24
        for i in 0..<6 {
            let x = Double(i) * 320 - 100 - pan
            ellipse(&c, CGRect(x: x, y: 56 + Double(i % 3) * 28, width: 180, height: 42), [.white.opacity(0.75), .white.opacity(0.18)])
            ellipse(&c, CGRect(x: x + 35, y: 39 + Double(i % 3) * 28, width: 90, height: 54), [.white.opacity(0.85), .white.opacity(0.25)])
        }
        // A hazy sandstone skyline gives the forest a place in the landscape.
        for layer in 0..<2 {
            var ridge = Path()
            ridge.move(to: CGPoint(x: -100, y: 250))
            for i in 0..<9 {
                let x = Double(i) * 215 - 110 - pan * Double(layer + 1) * 0.3
                let y = Double(50 + layer * 29 + i % 3 * 18)
                ridge.addLine(to: CGPoint(x: x, y: y + 58))
                ridge.addQuadCurve(to: CGPoint(x: x + 52, y: y + 4), control: CGPoint(x: x + 38, y: y + 43))
                ridge.addLine(to: CGPoint(x: x + 91, y: y))
                ridge.addQuadCurve(to: CGPoint(x: x + 146, y: y + 65), control: CGPoint(x: x + 118, y: y + 8))
                ridge.addLine(to: CGPoint(x: x + 215, y: y + 84))
            }
            ridge.addLine(to: CGPoint(x: 1800, y: 300)); ridge.closeSubpath()
            c.fill(ridge, with: .linearGradient(Gradient(colors: layer == 0 ? [
                Color(red: 0.66, green: 0.77, blue: 0.77), Color(red: 0.73, green: 0.82, blue: 0.66)] : [
                Color(red: 0.75, green: 0.70, blue: 0.48), Color(red: 0.40, green: 0.60, blue: 0.34)]),
                startPoint: CGPoint(x: 0, y: 45), endPoint: CGPoint(x: 0, y: 230)))
        }
        drawLandscape(&c, projection: projection)
        drawSlide(&c, projection: projection)
        drawDepthObjects(&c, projection: projection, billboardYScale: billboardYScale)
    }

    private func drawLandscape(_ c: inout GraphicsContext, projection: HoneySlideProjection) {
        let horizon = HoneySlideRules.horizonY
        var floor = Path(); floor.move(to: CGPoint(x: -20, y: 900))
        floor.addLine(to: CGPoint(x: -20, y: horizon + 7))
        for i in 0..<25 {
            let x = Double(i) * 70 - 20
            floor.addQuadCurve(to: CGPoint(x: x + 70, y: horizon + 7 + Double(i % 3) * 2),
                control: CGPoint(x: x + 36, y: horizon - 13 - Double(i % 4) * 3))
        }
        floor.addLine(to: CGPoint(x: 1720, y: 900)); floor.closeSubpath()
        c.fill(floor, with: .linearGradient(
            Gradient(colors: [Color(red: 0.39, green: 0.61, blue: 0.36),
                              Color(red: 0.22, green: 0.43, blue: 0.15),
                              Color(red: 0.10, green: 0.27, blue: 0.13)]),
            startPoint: CGPoint(x: 0, y: horizon), endPoint: CGPoint(x: 0, y: 900)))
        for side in [-1.0, 1.0] {
            c.fill(ribbon(side * 1.035, side * 1.28, projection), with: .linearGradient(Gradient(colors: [
                Color(red: 0.66, green: 0.69, blue: 0.31), Color(red: 0.36, green: 0.48, blue: 0.16)]),
                startPoint: CGPoint(x: 0, y: horizon), endPoint: CGPoint(x: 0, y: 900)))
            c.fill(ribbon(side * 1.28, side * 1.75, projection), with: .color(Color(red: 0.24, green: 0.46, blue: 0.15).opacity(0.5)))
        }
    }

    private func drawSlide(_ c: inout GraphicsContext, projection: HoneySlideProjection) {
        let gold = Color(red: 1.0, green: 0.68, blue: 0.025)
        c.fill(ribbon(-1.055, 1.055, projection), with: .color(Color(red: 0.30, green: 0.16, blue: 0.035)))
        c.fill(ribbon(-1, 1, projection), with: .linearGradient(Gradient(colors: [
            Color(red: 0.86, green: 0.48, blue: 0.02), gold,
            Color(red: 1, green: 0.82, blue: 0.20), gold]),
            startPoint: CGPoint(x: 100, y: HoneySlideRules.horizonY), endPoint: CGPoint(x: 1420, y: 920)))
        var flow = c
        if let end = simulation.finish?.roadEnd, end - simulation.distance < 4400 {
            // Ordinary waves already stay between the banks. At the finish
            // only the horizontal end of the surface needs to clip them;
            // a rectangle avoids replaying the entire bank contour per wave.
            let endY = point(HoneySlideRules.depth(ahead: end - simulation.distance), 0, projection).y
            flow.clip(to: Path(CGRect(x: -1600, y: endY, width: 4800, height: 3600)))
        }
        drawChurningHoney(&flow, projection: projection)
        drawWhirlpools(&c, projection: projection)
        c.fill(ribbon(-1, -0.94, projection), with: .color(.brown.opacity(0.19)))
        c.fill(ribbon(0.94, 1, projection), with: .color(.brown.opacity(0.19)))
    }

    private enum DepthContent {
        case plant(Int, CGPoint, Double)
        case rail(Double, Double, Double, Int)
        case item(Int)
        case divider(Int, Double, Int)
        case pots(Int)
    }
    private struct DepthObject {
        let ahead: Double
        let content: DepthContent
    }

    private func drawDepthObjects(_ c: inout GraphicsContext, projection: HoneySlideProjection, billboardYScale: Double) {
        let world = simulation.distance, step = HoneySlideRules.scenerySpacing
        let first = Int(floor(world / step)) - 2
        let last = Int(ceil((world + HoneySlideRules.drawDistance) / step))
        var objects: [DepthObject] = []
        objects.reserveCapacity(850)
        for index in first...last {
            for band in 0..<3 {
                for side in [-1.0, 1.0] {
                    let seed = abs(index * 17 + band * 13 + (side > 0 ? 19 : 0))
                    let ahead = Double(index) * step + Double(band) * 39 + (side > 0 ? 61 : 0)
                        + Double(seed % 11) * 6 - 30 - world
                    guard ahead > -120, ahead < HoneySlideRules.drawDistance else { continue }
                    let t = HoneySlideRules.depth(ahead: ahead)
                    let offset = side * (1.48 + Double(band) * 0.88 + Double(seed % 7) * 0.055)
                    let p = point(t, offset, projection)
                    let scale = t * (1.16 + Double(seed % 5) * 0.075)
                    let isCliff = band == 1 && seed % 13 == 0
                    let width = isCliff ? 180.0 : 125.0
                    guard p.x + width * scale > 0, p.x - width * scale < 1600,
                          p.y - (isCliff ? 330 : 300) * scale < 920 else { continue }
                    objects.append(DepthObject(ahead: ahead, content: .plant(isCliff ? 8 + seed % 2 : (band == 2 && seed % 4 == 0 ? 4 + seed % 2 : seed % 4), p, scale)))
                }
            }
            for side in [-1.0, 1.0] {
                let ahead = Double(index) * step + 94 - world
                guard ahead > -120, ahead < HoneySlideRules.drawDistance else { continue }
                let t = HoneySlideRules.depth(ahead: ahead)
                let p = point(t, side * (1.19 + Double(abs(index) % 3) * 0.075), projection)
                let scale = t * 1.32
                guard p.x + 110 * scale > 0, p.x - 110 * scale < 1600, p.y - 112 * scale < 920 else { continue }
                objects.append(DepthObject(ahead: ahead, content: .plant(4 + abs(index) % 2, p, scale)))
            }
        }
        // Raised objects share one far-to-near ordering. A nearby canopy can
        // cover a distant bend, while a nearby rail still covers distant roots.
        let blockLength = 72.0
        let firstBlock = Int(floor((world - 88) / blockLength))
        let roadEnd = min(world + HoneySlideRules.drawDistance, simulation.finish?.roadEnd ?? .infinity)
        let lastBlock = Int(ceil(roadEnd / blockLength))
        for index in firstBlock...lastBlock {
            let near = max(-88, Double(index) * blockLength - world)
            let far = min(roadEnd - world, Double(index + 1) * blockLength - world)
            guard near < far else { continue }
            for side in [-1.0, 1.0] {
                objects.append(DepthObject(ahead: (near + far) / 2, content: .rail(near, far, side, index)))
            }
        }
        for (index, row) in simulation.checkpoints.enumerated() {
            let ahead = row.worldPosition - world
            guard ahead + HoneySlideRules.dividerTail > HoneySlideRules.nearClipAhead,
                  ahead < HoneySlideRules.drawDistance, !row.options.isEmpty else { continue }
            for section in 0..<HoneySlideRules.dividerSections {
                let segment = HoneySlideRules.dividerSegment(rowPosition: row.worldPosition, index: section,
                    tail: row.id == simulation.finish?.checkpointID ? 0 : HoneySlideRules.dividerTail)
                guard segment.far - world > HoneySlideRules.nearClipAhead else { continue }
                for boundary in row.dividerBoundaries {
                    objects.append(DepthObject(ahead: (segment.far + segment.near) / 2 - world,
                        content: .divider(index, boundary, section)))
                }
            }
            objects.append(DepthObject(ahead: ahead, content: .pots(index)))
        }
        for (index, item) in simulation.items.enumerated() {
            guard item.kind != .whirlpool else { continue }
            let ahead = item.posed(at: simulation.elapsed).worldPosition - world
            guard ahead > -140, ahead < HoneySlideRules.drawDistance else { continue }
            objects.append(DepthObject(ahead: ahead, content: .item(index)))
        }
        objects.sort { $0.ahead > $1.ahead }
        for object in objects {
            var layer = c
            layer.opacity = HoneySlideRules.distantOpacity(ahead: object.ahead)
            switch object.content {
            case let .plant(id, p, scale):
                guard let symbol = c.resolveSymbol(id: id) else { continue }
                layer.translateBy(x: p.x, y: p.y)
                layer.scaleBy(x: scale, y: scale)
                layer.draw(symbol, at: .zero, anchor: .bottom)
            case let .rail(near, far, side, index):
                drawRailBlock(&layer, near: near, far: far, side: side, index: index, projection: projection)
            case let .divider(index, boundary, section):
                let row = simulation.checkpoints[index]
                dividerWall(&layer, rowPosition: row.worldPosition, lateral: boundary, section: section,
                    tail: row.id == simulation.finish?.checkpointID ? 0 : HoneySlideRules.dividerTail)
            case let .item(index):
                let item = simulation.items[index]
                if item.id == simulation.finish?.rampID {
                    drawFinishRamp(&layer, projection: projection)
                    continue
                }
                if item.kind == .ramp {
                    drawLaunchRamp(&layer, item: item)
                    continue
                }
                let posed = item.posed(at: simulation.elapsed)
                let depth = HoneySlideRules.depth(ahead: posed.worldPosition - world)
                let position = ridingPoint(depth, posed.lateral)
                layer.translateBy(x: position.x, y: position.y)
                layer.scaleBy(x: depth / HoneySlideRules.playerDepth * simulation.cameraZoom,
                              y: depth / HoneySlideRules.playerDepth * billboardYScale * simulation.cameraZoom)
                if item.kind == .log, let symbol = c.resolveSymbol(id: "race:log") {
                    let sinkT = simulation.checkpoints.first { $0.id == posed.checkpointID }
                        .map { posed.sinkProgress(rowPosition: $0.worldPosition) } ?? 0
                    drawLog(&layer, symbol: symbol, progress: sinkT, side: posed.lateral >= 0 ? 1 : -1)
                } else if let symbol = c.resolveSymbol(id: "race:\(item.kind.rawValue)") {
                    if let contact = item.contactedAt, item.kind == .hive {
                        let progress = min(1, max(0, (simulation.elapsed - contact) / 0.65))
                        guard progress < 1 else { continue }
                        let side = item.lateral >= 0 ? 1.0 : -1.0
                        drawImpactSplash(&layer, scale: 0.9, progress: progress, side: side)
                        // Like a missed answer pot, a struck prop tips into
                        // the honey rather than growing through the tube.
                        layer.clip(to: Path(CGRect(x: -260, y: -400, width: 520, height: 400)))
                        layer.translateBy(x: side * 70 * progress * progress,
                                          y: 270 * progress * progress)
                        layer.rotate(by: .degrees(side * 32 * progress))
                    }
                    layer.draw(symbol, at: CGPoint(x: 0, y: 30), anchor: .bottom)
                }
            case let .pots(index):
                drawCheckpoints(&layer, row: simulation.checkpoints[index], billboardYScale: billboardYScale)
            }
        }
    }

    private func drawLog(_ c: inout GraphicsContext, symbol: GraphicsContext.ResolvedSymbol,
                         progress: Double, side: Double) {
        guard progress < 1 else { return }
        let waterline = HoneyLogGeometry.waterline
        let swell = sin(progress * .pi)
        let gold = Color(red: 1, green: 0.75, blue: 0.08)
        let cream = Color(red: 1, green: 0.94, blue: 0.58)
        let amber = Color(red: 0.65, green: 0.30, blue: 0.02)
        var shade = c
        shade.opacity *= 1 - progress
        shade.fill(Path(ellipseIn: CGRect(x: -150, y: 8, width: 300, height: 28)),
            with: .radialGradient(Gradient(colors: [amber.opacity(0.45), amber.opacity(0)]),
                center: CGPoint(x: 0, y: 18), startRadius: 4, endRadius: 150))

        // The solid bark moves through a fixed honey surface. Only the part
        // above the waterline is painted; the wood itself stays fully opaque.
        var sunk = c
        sunk.clip(to: Path(CGRect(x: -420, y: -560, width: 840, height: 560 + waterline)))
        sunk.translateBy(x: 0, y: HoneyLogGeometry.submergedHalf + 22 + HoneyLogGeometry.sinkDistance * progress)
        sunk.rotate(by: .degrees(side * swell * 2.5))
        sunk.draw(symbol, at: CGPoint(x: 0, y: waterline), anchor: .bottom)

        // A low fold clings to the exposed bark, then closes over its last
        // edge. Broad, flat ripples let the displaced honey settle afterwards.
        let closing = min(1, max(0, (progress - 0.5) / 0.5))
        let width = 354 * (1 - closing * closing * (3 - 2 * closing))
        let half = width * 0.5
        var lip = Path()
        lip.move(to: CGPoint(x: -half, y: waterline))
        lip.addCurve(to: CGPoint(x: half, y: waterline - 1),
            control1: CGPoint(x: -half * 0.45, y: waterline - 3 - 4 * swell),
            control2: CGPoint(x: half * 0.48, y: waterline + 3 + 2 * swell))
        lip.addQuadCurve(to: CGPoint(x: -half, y: waterline),
            control: CGPoint(x: 0, y: waterline + 7 + 5 * swell))
        lip.closeSubpath()
        c.fill(lip, with: .linearGradient(Gradient(colors: [cream, gold, amber.opacity(0.35)]),
            startPoint: CGPoint(x: 0, y: waterline - 4), endPoint: CGPoint(x: 0, y: waterline + 9)))
        if progress > 0 {
            let rippleWidth = 380 + 65 * progress
            c.stroke(Path(ellipseIn: CGRect(x: -rippleWidth / 2, y: waterline - 7 - 5 * progress,
                width: rippleWidth, height: 17 + 10 * progress)), with: .color(cream.opacity(0.36 * swell)),
                style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
        }
    }

    /// A straight plank on the divider's centerline. Its edges use the same
    /// road projection as the answer stones, so a heading change cannot bend it.
    private func drawLaunchRamp(_ c: inout GraphicsContext, item: HoneyTrackItem) {
        guard let row = simulation.checkpoints.first(where: { $0.id == item.checkpointID }) else { return }
        let nearWorld = row.worldPosition - HoneySlideRules.launchDeckLead
        let farWorld = row.worldPosition - HoneySlideRules.dividerLead
        let half = 0.125
        let steps = 18
        func surface(_ world: Double, _ across: Double, _ rise: Double) -> CGPoint {
            let depth = HoneySlideRules.depth(ahead: world - simulation.distance)
            let p = ridingPoint(depth, item.lateral + across)
            return CGPoint(x: p.x, y: p.y - rise)
        }
        func sample(_ step: Int, _ across: Double) -> CGPoint {
            let t = Double(step) / Double(steps)
            let world = nearWorld + (farWorld - nearWorld) * t
            let kick = max(0, (t - 0.72) / 0.28)
            let rise = kick * kick * HoneySlideRules.railHeight * HoneySlideRules.depth(ahead: world - simulation.distance) * 0.85
            return surface(world, across * half, rise)
        }
        var deck = Path()
        deck.move(to: sample(0, -1))
        for step in 1...steps { deck.addLine(to: sample(step, -1)) }
        for step in stride(from: steps, through: 0, by: -1) { deck.addLine(to: sample(step, 1)) }
        deck.closeSubpath()
        c.fill(deck, with: .linearGradient(Gradient(colors: [
            Color(red: 0.91, green: 0.65, blue: 0.31), Color(red: 0.78, green: 0.44, blue: 0.15),
            Color(red: 0.53, green: 0.27, blue: 0.07)]),
            startPoint: sample(steps, 0), endPoint: sample(0, 0)))
        c.stroke(deck, with: .color(Color(red: 0.29, green: 0.12, blue: 0.025).opacity(0.65)), lineWidth: 1.4)
        for step in 1..<7 {
            let index = step * steps / 7
            var seam = Path()
            seam.move(to: sample(index, -1))
            seam.addLine(to: sample(index, 1))
            c.stroke(seam, with: .color(.brown.opacity(0.38)), lineWidth: 1.6)
        }
        for t in [0.78, 0.88, 0.97] {
            let step = Int((t * Double(steps)).rounded())
            let next = min(steps, step + 2)
            var arrow = Path()
            arrow.move(to: sample(step, -0.42))
            arrow.addLine(to: sample(next, 0))
            arrow.addLine(to: sample(step, 0.42))
            arrow.addLine(to: sample(max(0, step - 1), 0.42))
            arrow.addLine(to: sample(min(steps, next - 1), 0))
            arrow.addLine(to: sample(max(0, step - 1), -0.42))
            arrow.closeSubpath()
            c.fill(arrow, with: .linearGradient(Gradient(colors: [
                Color(red: 1, green: 0.35, blue: 0.08), Color(red: 0.88, green: 0.15, blue: 0.045),
                Color(red: 0.64, green: 0.08, blue: 0.025)]),
                startPoint: sample(next, 0), endPoint: sample(step, 0)))
        }
        var lip = Path()
        lip.move(to: sample(0, -1.05))
        lip.addLine(to: sample(0, 1.05))
        let depth = HoneySlideRules.depth(ahead: nearWorld - simulation.distance)
        c.stroke(lip, with: .color(Color(red: 1, green: 0.82, blue: 0.20).opacity(0.9)),
            style: StrokeStyle(lineWidth: max(1.5, 7 * depth), lineCap: .round))
    }

    private func drawFinishRamp(_ c: inout GraphicsContext, projection: HoneySlideProjection) {
        guard let finish = simulation.finish else { return }
        let tn = HoneySlideRules.depth(ahead: finish.rampNearPosition - simulation.distance)
        let nearL = point(tn, -1, projection), nearR = point(tn, 1, projection)
        func surface(_ t: Double, _ across: Double) -> CGPoint {
            let world = finish.rampNearPosition + (finish.roadEnd - finish.rampNearPosition) * t
            let depth = HoneySlideRules.depth(ahead: world - simulation.distance)
            let p = point(depth, across, projection)
            return CGPoint(x: p.x, y: p.y - t * HoneySlideRules.railHeight * depth)
        }
        var deck = Path()
        deck.move(to: nearL)
        for step in 1...24 { deck.addLine(to: surface(Double(step) / 24, -1)) }
        for step in stride(from: 24, through: 0, by: -1) { deck.addLine(to: surface(Double(step) / 24, 1)) }
        deck.closeSubpath()
        c.fill(deck, with: .linearGradient(Gradient(colors: [
            Color(red: 0.91, green: 0.65, blue: 0.31), Color(red: 0.78, green: 0.44, blue: 0.15),
            Color(red: 0.53, green: 0.27, blue: 0.07)]),
            startPoint: surface(1, -0.8), endPoint: surface(0, 0.8)))
        c.stroke(deck, with: .color(Color(red: 0.29, green: 0.12, blue: 0.025).opacity(0.65)), lineWidth: 1.5)
        for index in 1..<7 {
            let t = Double(index) / 7
            var seam = Path(); seam.move(to: surface(t, -1)); seam.addLine(to: surface(t, 1))
            c.stroke(seam, with: .color(.brown.opacity(0.4)), lineWidth: 2)
            c.stroke(seam.offsetBy(dx: 0, dy: -2), with: .color(Color(red: 1, green: 0.96, blue: 0.76).opacity(0.25)), lineWidth: 1)
        }
        for t in [0.20, 0.48, 0.76] {
            var arrow = Path()
            arrow.addLines([surface(t - 0.055, -0.32), surface(t + 0.10, 0), surface(t - 0.055, 0.32),
                surface(t - 0.14, 0.32), surface(t, 0), surface(t - 0.14, -0.32)])
            arrow.closeSubpath()
            c.fill(arrow, with: .linearGradient(Gradient(colors: [
                Color(red: 1, green: 0.35, blue: 0.08), Color(red: 0.88, green: 0.15, blue: 0.045),
                Color(red: 0.64, green: 0.08, blue: 0.025)]), startPoint: surface(t + 0.1, 0), endPoint: surface(t - 0.14, 0)))
        }
        var lip = Path(); lip.move(to: nearL); lip.addLine(to: nearR)
        c.stroke(lip, with: .color(Color(red: 1, green: 0.82, blue: 0.20)),
            style: StrokeStyle(lineWidth: 6 * tn, lineCap: .round))
    }

    private func drawRailBlock(_ c: inout GraphicsContext, near: Double, far: Double, side: Double,
                               index: Int, projection: HoneySlideProjection) {
        let depths = [far, (far + near) / 2, near].map { HoneySlideRules.depth(ahead: $0) }
        let inside = depths.map { point($0, side, projection) }
        let outside = depths.map { point($0, side * 1.055, projection) }
        let innerTop = zip(inside, depths).map { CGPoint(x: $0.0.x, y: $0.0.y - HoneySlideRules.railHeight * $0.1) }
        let outerTop = zip(outside, depths).map { CGPoint(x: $0.0.x, y: $0.0.y - HoneySlideRules.railHeight * $0.1) }
        guard max(inside.map(\.x).max()!, outside.map(\.x).max()!) > -60,
              min(inside.map(\.x).min()!, outside.map(\.x).min()!) < 1660 else { return }
        func face(_ points: [CGPoint]) -> Path { var path = Path(); path.addLines(points); path.closeSubpath(); return path }
        let t = depths[1], warm = Double(abs(index) % 4) * 0.025
        let curveError = hypot(innerTop[1].x - (innerTop[0].x + innerTop[2].x) / 2,
                               innerTop[1].y - (innerTop[0].y + innerTop[2].y) / 2)
        let perspectiveError = 96 * max(abs(t - depths[0]), abs(t - depths[2]))
        let capError = abs((outerTop[0].x - innerTop[0].x) - (outerTop[2].x - innerTop[2].x)) / 2
        if t < 0.16, curveError + perspectiveError + capError < 0.5,
           let sideImage = c.resolveSymbol(id: "rail-face:\(abs(index) % 4)"),
           let capImage = c.resolveSymbol(id: "rail-cap") {
            // In the distance the change of perspective across one 72-unit
            // block is subpixel. Map the baked face and cap onto its projected
            // edges, avoiding separate gradient and stroke render passes.
            c.fill(face(outside + outerTop.reversed()), with: .color(Color(red: 0.35 + warm, green: 0.22, blue: 0.11)))
            let along = CGPoint(x: innerTop[2].x - innerTop[0].x, y: innerTop[2].y - innerTop[0].y)
            let across = ((outerTop[0].x - innerTop[0].x) + (outerTop[2].x - innerTop[2].x)) / 2
            var cap = c
            cap.concatenate(CGAffineTransform(a: along.x, b: along.y, c: across, d: 0,
                tx: innerTop[0].x, ty: innerTop[0].y))
            cap.draw(capImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            var sideFace = c
            sideFace.concatenate(CGAffineTransform(a: along.x, b: along.y, c: 0, d: 96 * t,
                tx: innerTop[0].x, ty: innerTop[0].y - 6 * t))
            sideFace.draw(sideImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            let blend = max(0, min(1, (t - 0.12) / 0.04))
            guard blend > 0 else { return }
            c.opacity *= blend * blend * (3 - 2 * blend)
        }
        let inner = face(inside + innerTop.reversed())
        c.fill(face(outside + outerTop.reversed()), with: .color(Color(red: 0.35 + warm, green: 0.22, blue: 0.11)))
        c.fill(inner, with: .linearGradient(Gradient(colors: [
            Color(red: 0.76 + warm, green: 0.48 + warm, blue: 0.22),
            Color(red: 0.43 + warm, green: 0.23, blue: 0.10)]),
            startPoint: innerTop[1], endPoint: inside[1]))
        c.fill(face(innerTop + outerTop.reversed()), with: .linearGradient(Gradient(colors: [
            Color(red: 0.98, green: 0.80, blue: 0.38), Color(red: 0.87, green: 0.59, blue: 0.25)]),
            startPoint: outerTop[1], endPoint: innerTop[1]))
        // The cap is a real projected top surface, with an amber lip and gloss.
        var lip = Path(); lip.addLines(innerTop)
        c.stroke(lip, with: .color(Color(red: 0.99, green: 0.62, blue: 0.02)), style: StrokeStyle(lineWidth: 8 * t, lineCap: .round))
        c.stroke(lip.offsetBy(dx: side * 2 * t, dy: -2 * t), with: .color(Color(red: 1, green: 0.94, blue: 0.62)),
                 style: StrokeStyle(lineWidth: 2.5 * t, lineCap: .round))
        var joint = Path(); joint.move(to: outside[2]); joint.addLine(to: outerTop[2]); joint.addLine(to: innerTop[2]); joint.addLine(to: inside[2])
        c.stroke(joint, with: .color(Color(red: 0.27, green: 0.15, blue: 0.065).opacity(0.65)), lineWidth: max(0.3, 2.8 * depths[2]))
        if t > 0.15 {
            var grain = Path()
            for fraction in [0.30, 0.68] {
                grain.move(to: CGPoint(x: inside[0].x, y: inside[0].y - HoneySlideRules.railHeight * depths[0] * fraction))
                grain.addQuadCurve(to: CGPoint(x: inside[2].x, y: inside[2].y - HoneySlideRules.railHeight * depths[2] * fraction),
                    control: CGPoint(x: inside[1].x, y: inside[1].y - HoneySlideRules.railHeight * t * (fraction + 0.04)))
            }
            c.stroke(grain, with: .color(Color(red: 0.96, green: 0.73, blue: 0.39).opacity(0.28)), lineWidth: 1.3 * t)
        }
        if abs(index) % 3 == 0 {
            let top = innerTop[1], length = Double(25 + abs(index) % 4 * 7) * t
            var drip = Path(); drip.move(to: top)
            drip.addCurve(to: CGPoint(x: top.x - side * 8 * t, y: top.y + length),
                control1: CGPoint(x: top.x - side * 12 * t, y: top.y + 3 * t),
                control2: CGPoint(x: top.x - side * 3 * t, y: top.y + length * 0.75))
            c.stroke(drip, with: .color(Color(red: 0.89, green: 0.40, blue: 0.01)), style: StrokeStyle(lineWidth: 15 * t, lineCap: .round))
            c.stroke(drip, with: .color(Color(red: 1, green: 0.76, blue: 0.035)), style: StrokeStyle(lineWidth: 11 * t, lineCap: .round))
            c.stroke(drip.offsetBy(dx: -2 * t, dy: -2 * t), with: .color(Color(red: 1, green: 0.98, blue: 0.77).opacity(0.8)),
                     style: StrokeStyle(lineWidth: 2 * t, lineCap: .round))
        }
    }

    private func drawWhirlpools(_ c: inout GraphicsContext, projection: HoneySlideProjection) {
        let pools = simulation.items.filter {
            $0.kind == .whirlpool && $0.worldPosition - simulation.distance > -180
                && $0.worldPosition - simulation.distance < HoneySlideRules.drawDistance
        }.sorted { $0.worldPosition > $1.worldPosition }
        for pool in pools {
            let ahead = pool.worldPosition - simulation.distance
            let depth = HoneySlideRules.depth(ahead: ahead)
            var water = c
            water.opacity *= HoneySlideRules.distantOpacity(ahead: ahead)
            // Only this small surface patch can contain the pool. Clipping
            // every fold against the entire 10,000-unit road made the path
            // renderer process hundreds of unrelated bank segments per fill.
            let far = HoneySlideRules.depth(ahead: ahead + HoneyWhirlpoolFlow.radiusZ + 180)
            let near = HoneySlideRules.depth(ahead: ahead - HoneyWhirlpoolFlow.radiusZ - 180)
            let samples = [far] + HoneySlideRules.trackDepthSamples.filter { $0 > far && $0 < near } + [near]
            var patch = Path()
            for (index, t) in samples.enumerated() {
                let p = point(t, -1, projection)
                if index == 0 { patch.move(to: p) } else { patch.addLine(to: p) }
            }
            for t in samples.reversed() { patch.addLine(to: point(t, 1, projection)) }
            patch.closeSubpath()
            water.clip(to: patch)
            // Every contour point sits on the actual course, including bends,
            // the changing road width and the much flatter distant surface.
            HoneyWhirlpoolArtwork.draw(in: &water, phase: simulation.elapsed,
                reduceMotion: reduceMotion, detailed: depth > 0.16) { x, z, drop in
                let worldZ = pool.worldPosition + z
                let t = HoneySlideRules.depth(ahead: worldZ - simulation.distance)
                let worldX = pool.lateral * HoneySlideRules.lateralWorldScale + x
                let offset = worldX / (HoneySlideRules.trackWorldHalfWidth * simulation.widthProfile.scale(at: worldZ))
                let p = point(t, offset, projection)
                return CGPoint(x: p.x, y: p.y + drop * t)
            }
        }
    }

    /// Raised, filled waves and rotating eddies share the course projection.
    /// Flow advects through the world independently of the stationary banks.
    private func drawChurningHoney(_ c: inout GraphicsContext, projection: HoneySlideProjection) {
        let flow = simulation.distance / 220 * 58
        let first = Int(floor((simulation.distance + flow) / 155)) - 2
        let end = min(simulation.distance + 4200, simulation.finish?.roadEnd ?? .infinity)
        let last = Int(ceil((end + flow) / 155))
        let cream = Color(red: 1, green: 0.98, blue: 0.78)
        let amber = Color(red: 0.94, green: 0.43, blue: 0.01)
        var distantCrests = Path()
        let whirlpools = simulation.items.filter {
            $0.kind == .whirlpool && $0.worldPosition - simulation.distance > -180
                && $0.worldPosition - simulation.distance < 4400
        }
        func waveVisibility(_ z: Double, _ lane: Double) -> Double {
            var visibility = 1.0
            for pool in whirlpools where abs(z - pool.worldPosition) < HoneyWhirlpoolFlow.radiusZ * 1.2 {
                let x = lane * HoneySlideRules.trackWorldHalfWidth * simulation.widthProfile.scale(at: z)
                    - pool.lateral * HoneySlideRules.lateralWorldScale
                let weight = HoneyWhirlpoolFlow.influence(x: x / 1.12, z: (z - pool.worldPosition) / 1.12)
                visibility = min(visibility, max(0, 1 - 4 * weight))
            }
            return visibility
        }
        func surface(_ z: Double, _ lane: Double, _ lift: Double = 0) -> CGPoint {
            var worldZ = z, offset = lane, height = lift
            for pool in whirlpools where abs(z - pool.worldPosition) < HoneyWhirlpoolFlow.radiusZ {
                let width = HoneySlideRules.trackWorldHalfWidth * simulation.widthProfile.scale(at: worldZ)
                let centerX = pool.lateral * HoneySlideRules.lateralWorldScale
                let localX = offset * width - centerX
                guard abs(localX) < HoneyWhirlpoolFlow.radiusX else { continue }
                let sample = HoneyWhirlpoolFlow.deform(x: localX, z: worldZ - pool.worldPosition, phase: reduceMotion ? 0 : simulation.elapsed)
                worldZ = pool.worldPosition + sample.z
                offset = (centerX + sample.x) / (HoneySlideRules.trackWorldHalfWidth * simulation.widthProfile.scale(at: worldZ))
                height = height * sample.calm - sample.drop
            }
            let depth = HoneySlideRules.depth(ahead: worldZ - simulation.distance)
            let p = point(depth, offset, projection)
            return CGPoint(x: p.x, y: p.y - height * depth)
        }
        for index in stride(from: last, through: first, by: -1) {
            let z = Double(index) * 155 - flow
            let ahead = z - simulation.distance
            guard ahead > -100 else { continue }
            let t = HoneySlideRules.depth(ahead: ahead)
            let phase = Double(index) * 1.73 + distance * 2.4
            // At the horizon a trough is subpixel high. Keep every crest in
            // its world position, but fade in its volume as it becomes visible.
            // No objects or wave rows are spawned at a detail boundary.
            let detail = max(0, min(1, (t - 0.12) / 0.06))
            // Each wave has a rolling shoulder, shaded trough and broken gloss.
            // Its silhouette changes over time, instead of translating a stripe.
            for band in 0..<4 {
                let lane = Double(band) * 0.48 - 0.72
                let bandPhase = phase + Double(band) * 2.4
                let offset = sin(Double(index) * 1.91 + Double(band) * 2.2) * 57
                var ridge: [CGPoint] = [], back: [CGPoint] = [], front: [CGPoint] = []
                var shineTop: [CGPoint] = [], shineBottom: [CGPoint] = []
                let steps = t < 0.15 ? 6 : 12
                var visibility = 1.0
                ridge.reserveCapacity(steps + 1); back.reserveCapacity(steps + 1); front.reserveCapacity(steps + 1)
                shineTop.reserveCapacity(steps + 1); shineBottom.reserveCapacity(steps + 1)
                for step in 0...steps {
                    let u = Double(step) / Double(steps)
                    let x = lane + (u - 0.5) * 0.42
                    let roll = sin(u * .pi)
                    let wobble = sin(u * 8 + bandPhase)
                    let zz = z + offset + sin(x * 6 + bandPhase) * 33 + wobble * 12
                    let height = roll * (17 + 7 * sin(bandPhase + u * 5))
                    visibility = min(visibility, waveVisibility(zz, x))
                    if detail > 0 {
                        ridge.append(surface(zz, x, height))
                        back.append(surface(zz + (51 + 12 * roll) * roll, x, 0))
                        front.append(surface(zz - (30 + 12 * roll) * roll, x, 0))
                    }
                    shineTop.append(surface(zz + 4 * roll, x, height + roll))
                    shineBottom.append(surface(zz - (7 + 8 * roll) * roll, x, height * 0.38))
                }
                let crest = HoneyFluidContour.closed(shineTop + shineBottom.reversed())
                let center = surface(z + offset, lane)
                var wave = c
                wave.opacity *= visibility
                if detail > 0 {
                    let shoulder = HoneyFluidContour.closed(back + ridge.reversed())
                    let trough = HoneyFluidContour.closed(ridge + front.reversed())
                    var volume = wave
                    volume.opacity *= detail
                    volume.fill(shoulder, with: .linearGradient(Gradient(colors: [
                    Color(red: 1, green: 0.80, blue: 0.07).opacity(0.06),
                    Color(red: 1, green: 0.89, blue: 0.28).opacity(0.8)]),
                    startPoint: CGPoint(x: center.x, y: center.y - 50 * t), endPoint: center))
                    volume.fill(trough, with: .linearGradient(Gradient(colors: [amber.opacity(0.30), .orange.opacity(0)]),
                    startPoint: CGPoint(x: center.x, y: center.y - 10 * t),
                    endPoint: CGPoint(x: center.x, y: center.y + 58 * t)))
                    if t > 0.18 {
                        volume.fill(shoulder, with: .radialGradient(Gradient(colors: [cream.opacity(0.34), .yellow.opacity(0)]),
                        center: surface(z + offset + 19, lane - 0.05, 5), startRadius: 0, endRadius: 85 * t))
                    }
                }
                if t < 0.12, visibility >= 0.999 {
                    // These crests are less than a pixel high on the phone.
                    // Keep every moving contour, sharing one fill instead of
                    // a separate gradient render pass for each distant wave.
                    distantCrests.addPath(crest)
                } else {
                    wave.fill(crest, with: .linearGradient(Gradient(colors: [cream.opacity(min(0.83, t * 1.3)),
                        Color.yellow.opacity(0.18)]), startPoint: CGPoint(x: center.x, y: center.y - 18 * t),
                        endPoint: CGPoint(x: center.x, y: center.y + 18 * t)))
                }
            }
            // Eddies curl around one another with a thick honey meniscus.
            for band in 0..<3 where t > 0.12 {
                let lane = Double(band - 1) * 0.60 + sin(Double(index) * 2.1 + Double(band)) * 0.12
                let zz = z + 82 + Double(band) * 17
                var eddy = c
                eddy.opacity *= waveVisibility(zz, lane)
                for lobe in 0..<2 {
                    var outer: [CGPoint] = [], inner: [CGPoint] = []
                    outer.reserveCapacity(15); inner.reserveCapacity(15)
                    for step in 0...14 {
                        let u = Double(step) / 14
                        let angle = u * .pi * 1.5 + phase * 0.35 + Double(lobe) * .pi
                        let radius = 0.075 * (0.65 + u * 0.65)
                        let x = lane + cos(angle) * radius
                        let dz = sin(angle) * (27 + u * 20)
                        let lift = sin(u * .pi) * 10
                        outer.append(surface(zz + dz, x, lift))
                        inner.append(surface(zz + dz + 6 * sin(u * .pi), x + cos(angle) * 0.023 * sin(u * .pi), 0))
                    }
                    let swirl = HoneyFluidContour.closed(outer + inner.reversed())
                    let center = surface(zz, lane)
                    eddy.fill(swirl, with: .linearGradient(Gradient(colors: [
                        cream.opacity(min(0.7, t)), Color(red: 1, green: 0.84, blue: 0.12).opacity(0.32)]),
                        startPoint: CGPoint(x: center.x - 35 * t, y: center.y - 16 * t),
                        endPoint: CGPoint(x: center.x + 30 * t, y: center.y + 28 * t)))
                }
                if t > 0.20 {
                    let p = surface(zz - 7, lane + 0.055, 3)
                    ellipse(&eddy, CGRect(x: p.x, y: p.y, width: 10 * t, height: 5 * t),
                            [cream.opacity(0.8), .yellow.opacity(0.1)])
                }
            }
        }
        c.fill(distantCrests, with: .color(Color(red: 1, green: 0.99, blue: 0.42).opacity(0.15)))
    }

    private func drawCheckpoints(_ c: inout GraphicsContext, row: HoneyCheckpoint, billboardYScale: Double) {
        let ahead = row.worldPosition - simulation.distance
        guard ahead + HoneySlideRules.dividerTail > HoneySlideRules.nearClipAhead,
              ahead < HoneySlideRules.drawDistance, !row.options.isEmpty else { return }
        let rowContext = c
        let t = HoneySlideRules.depth(ahead: ahead)
        let s = HoneySlideRules.answerScale(depth: t) * row.potSize * simulation.cameraZoom
        guard ahead > HoneySlideRules.nearClipAhead else { return }
        for i in row.options.indices {
            let lane = row.lateralPosition(at: i, elapsed: distance)
            let selected = row.selectedIndex == i
            if selected && row.wasCorrect && collectionTarget != nil { continue }
            let tumble = selected ? min(1, (distance - (row.impactAt ?? distance)) / HoneySlideRules.tumbleDuration) : 0
            if selected && tumble >= 1 { continue }
            let bounds = HoneySlideRules.potBounds(depth: t, lateral: lane,
                elapsed: simulation.travelTime, billboardYScale: billboardYScale, course: simulation.course, sizeFactor: row.potSize, cameraZoom: simulation.cameraZoom, cameraOffset: simulation.cameraOffset)
            guard bounds.insetBy(dx: selected ? -150 * s : 0, dy: selected ? -70 * s : 0)
                .intersects(CGRect(x: 0, y: 0, width: 1600, height: 900)) else { continue }
            let p = ridingPoint(t, lane)
            var potContext = rowContext
            potContext.translateBy(x: p.x, y: p.y)
            potContext.scaleBy(x: 1, y: billboardYScale)
            if selected && !row.wasCorrect {
                let side = i == 0 ? -1.0 : 1.0
                drawImpactSplash(&potContext, scale: s, progress: tumble, side: side)
                drawSinkingPot(&potContext, scale: s, progress: tumble, side: side, text: row.options[i].text)
                continue
            }
            barrel(&potContext, scale: s, text: row.options[i].text, opening: row.shutterProgress(at: distance))
        }
    }

    private func drawSinkingPot(_ c: inout GraphicsContext, scale s: Double, progress: Double, side: Double, text: String) {
        // The surface occludes the solid pot as it tips and sinks. Its image
        // never fades; honey folds close over the last exposed part.
        var sinking = c
        sinking.clip(to: Path(CGRect(x: -240 * s, y: -240 * s, width: 480 * s, height: 262 * s)))
        let tip = 1 - pow(1 - min(1, progress / 0.65), 3)
        sinking.translateBy(x: side * 12 * s * sin(progress * .pi), y: 205 * s * progress * progress)
        sinking.rotate(by: .degrees(side * tip * 38))
        sinking.scaleBy(x: 1, y: 1 - progress * 0.18)
        barrel(&sinking, scale: s, text: text, opening: 1)

        let swell = sin(progress * .pi)
        let radius = (42 + progress * 39) * s
        let y = 21 * s
        var lip = Path()
        lip.move(to: CGPoint(x: -radius, y: y))
        lip.addCurve(to: CGPoint(x: radius, y: y),
            control1: CGPoint(x: -radius * 0.55, y: y - 36 * s * swell),
            control2: CGPoint(x: radius * 0.52, y: y - 29 * s * swell))
        lip.addQuadCurve(to: CGPoint(x: -radius, y: y), control: CGPoint(x: 0, y: y + 21 * s * swell))
        c.fill(lip, with: .linearGradient(Gradient(colors: [.yellow, Color(red: 1, green: 0.65, blue: 0.015)]),
            startPoint: CGPoint(x: 0, y: y - 28 * s), endPoint: CGPoint(x: 0, y: y + 14 * s)))
        var gloss = Path()
        gloss.move(to: CGPoint(x: -radius * 0.70, y: y - 4 * s * swell))
        gloss.addQuadCurve(to: CGPoint(x: radius * 0.65, y: y - 5 * s * swell),
            control: CGPoint(x: 0, y: y - 28 * s * swell))
        c.stroke(gloss, with: .color(.white.opacity(0.7 * swell)), style: StrokeStyle(lineWidth: 3 * s, lineCap: .round))
    }

    private func drawImpactSplash(_ c: inout GraphicsContext, scale s: Double, progress: Double, side: Double) {
        let radius = (30 + progress * 100) * s
        let center = CGPoint(x: side * progress * 58 * s, y: 8 * s)
        var splash = c
        splash.opacity *= sin(progress * .pi)
        ellipse(&splash, CGRect(x: center.x - radius, y: center.y - radius * 0.13,
                               width: radius * 2, height: radius * 0.30), [.orange.opacity(0.65), .yellow.opacity(0.03)])
        for i in 0..<13 {
            let angle = Double(i) / 13 * .pi * 2
            let x = center.x + cos(angle) * radius
            let y = center.y + sin(angle) * radius * 0.28 - sin(progress * .pi) * (20 + Double(i % 4) * 8) * s
            ellipse(&splash, CGRect(x: x, y: y, width: 4 * s, height: (7 + Double(i % 3) * 3) * s),
                    [.white.opacity(0.9), .yellow])
        }
    }

    private func dividerWall(_ c: inout GraphicsContext, rowPosition: Double, lateral: Double, section: Int,
                             tail: Double = HoneySlideRules.dividerTail) {
        let segment = HoneySlideRules.dividerSegment(rowPosition: rowPosition, index: section, tail: tail)
        let far = segment.far - simulation.distance
        guard far > HoneySlideRules.nearClipAhead else { return }
        let near = max(HoneySlideRules.nearClipAhead, segment.near - simulation.distance)
        let tf = HoneySlideRules.depth(ahead: far), tn = HoneySlideRules.depth(ahead: near)
        let half = HoneySlideRules.dividerHalfWidth
        let fl = ridingPoint(tf, lateral - half), fr = ridingPoint(tf, lateral + half)
        let nl = ridingPoint(tn, lateral - half), nr = ridingPoint(tn, lateral + half)
        let hf = HoneySlideRules.dividerHeight * tf * simulation.cameraZoom, hn = HoneySlideRules.dividerHeight * tn * simulation.cameraZoom
        let topFL = CGPoint(x: fl.x, y: fl.y - hf), topFR = CGPoint(x: fr.x, y: fr.y - hf)
        let topNL = CGPoint(x: nl.x, y: nl.y - hn), topNR = CGPoint(x: nr.x, y: nr.y - hn)
        guard topFL.y < 920, max(fr.x, nr.x) > -80, min(fl.x, nl.x) < 1680 else { return }
        func face(_ points: [CGPoint]) -> Path { var path = Path(); path.addLines(points); path.closeSubpath(); return path }
        let warmth = Double(section % 3) * 0.025
        let depth = (tf + tn) / 2
        var drewShadow = false
        if depth < 0.30, section < HoneySlideRules.dividerSections - 1,
           35 * simulation.cameraZoom * abs(tn - tf) < 0.5,
           let leftImage = c.resolveSymbol(id: "divider-left:\(section % 3)"),
           let rightImage = c.resolveSymbol(id: "divider-right:\(section % 3)") {
            // Preserve the individual physical blocks and their depth order.
            // Only their small distant side faces share rasterized artwork.
            c.fill(face([fl, fr, nr, nl]).offsetBy(dx: 6 * tn, dy: 7 * tn), with: .color(.brown.opacity(0.24)))
            drewShadow = true
            c.fill(face([topFL, topFR, topNR, topNL]), with: .linearGradient(Gradient(colors: [
                Color(red: 1, green: 0.88, blue: 0.43), Color(red: 0.95, green: 0.65, blue: 0.19)]),
                startPoint: topFL, endPoint: topNR))
            func drawSide(_ image: GraphicsContext.ResolvedSymbol, far: CGPoint, near: CGPoint) {
                var side = c
                side.concatenate(CGAffineTransform(a: near.x - far.x, b: near.y - far.y,
                    c: 0, d: 70 * depth * simulation.cameraZoom,
                    tx: far.x, ty: far.y - 6 * depth * simulation.cameraZoom))
                side.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            drawSide(rightImage, far: topFR, near: topNR)
            drawSide(leftImage, far: topFL, near: topNL)
            let blend = max(0, min(1, (depth - 0.24) / 0.06))
            guard blend > 0 else { return }
            c.opacity *= blend * blend * (3 - 2 * blend)
        }
        if !drewShadow {
            c.fill(face([fl, fr, nr, nl]).offsetBy(dx: 6 * tn, dy: 7 * tn), with: .color(.brown.opacity(0.24)))
        }
        c.fill(face([fl, topFL, topNL, nl]), with: .linearGradient(Gradient(colors: [
            Color(red: 0.77 + warmth, green: 0.49, blue: 0.23), Color(red: 0.39 + warmth, green: 0.22, blue: 0.10)]),
            startPoint: topNL, endPoint: nl))
        c.fill(face([fr, topFR, topNR, nr]), with: .linearGradient(Gradient(colors: [
            Color(red: 0.87, green: 0.61 + warmth, blue: 0.29), Color(red: 0.48, green: 0.27, blue: 0.12)]),
            startPoint: topNR, endPoint: nr))
        c.fill(face([topFL, topFR, topNR, topNL]), with: .linearGradient(Gradient(colors: [
            Color(red: 1, green: 0.88, blue: 0.43), Color(red: 0.95, green: 0.65, blue: 0.19)]),
            startPoint: topFL, endPoint: topNR))
        var lip = Path(); lip.move(to: topFL); lip.addLine(to: topNL)
        c.stroke(lip, with: .color(Color(red: 1, green: 0.66, blue: 0.035)), style: StrokeStyle(lineWidth: 7 * tf, lineCap: .round))
        c.stroke(lip.offsetBy(dx: -tf, dy: -tf), with: .color(Color(red: 1, green: 0.97, blue: 0.72)),
            style: StrokeStyle(lineWidth: 2 * tf, lineCap: .round))
        var joint = Path(); joint.move(to: topNL); joint.addLine(to: topNR); joint.addLine(to: nr)
        c.stroke(joint, with: .color(Color(red: 0.31, green: 0.18, blue: 0.08).opacity(0.6)), lineWidth: 2 * tn)
        if tn > 0.15 {
            var grain = Path()
            for fraction in [0.35, 0.72] {
                grain.move(to: CGPoint(x: fr.x, y: fr.y - hf * fraction))
                grain.addLine(to: CGPoint(x: nr.x, y: nr.y - hn * fraction))
            }
            c.stroke(grain, with: .color(Color(red: 1, green: 0.84, blue: 0.49).opacity(0.25)), lineWidth: 1.2 * tn)
        }
        if section % 3 == 1 {
            var drip = Path(); drip.move(to: topFR)
            drip.addCurve(to: CGPoint(x: topFR.x + 2 * tf, y: topFR.y + 22 * tf),
                control1: CGPoint(x: topFR.x + 10 * tf, y: topFR.y + 2 * tf),
                control2: CGPoint(x: topFR.x + 2 * tf, y: topFR.y + 12 * tf))
            c.stroke(drip, with: .color(Color(red: 0.94, green: 0.49, blue: 0.01)), style: StrokeStyle(lineWidth: 9 * tf, lineCap: .round))
            c.stroke(drip, with: .color(Color(red: 1, green: 0.81, blue: 0.16)), style: StrokeStyle(lineWidth: 5 * tf, lineCap: .round))
        }
        if section == HoneySlideRules.dividerSections - 1 {
            let width = nr.x - nl.x
            let rect = CGRect(x: nl.x, y: nl.y - hn, width: width, height: hn + 3 * tn)
            c.fill(Path(roundedRect: rect, cornerRadius: width * 0.35), with: .linearGradient(Gradient(colors: [
                Color(red: 0.86, green: 0.59, blue: 0.29), Color(red: 0.40, green: 0.23, blue: 0.11)]),
                startPoint: rect.origin, endPoint: CGPoint(x: rect.maxX, y: rect.maxY)))
            ellipse(&c, CGRect(x: nl.x - 2 * tn, y: nl.y - hn - width * 0.18, width: width + 4 * tn, height: width * 0.47),
                [Color(red: 1, green: 0.96, blue: 0.59), Color(red: 1, green: 0.72, blue: 0.04), Color(red: 0.96, green: 0.50, blue: 0.01)])
            rounded(&c, CGRect(x: nl.x + width * 0.22, y: nl.y - hn, width: width * 0.15, height: hn * 0.56), width * 0.075,
                Color(red: 1, green: 0.82, blue: 0.22))
            // The nose sits in honey; its small wake is drawn in ground space.
            ellipse(&c, CGRect(x: nl.x - 9 * tn, y: nl.y - 1 * tn, width: width + 18 * tn, height: 8 * tn),
                [Color(red: 1, green: 0.94, blue: 0.53).opacity(0.8), .yellow.opacity(0)])
        }
    }

    private func barrel(_ c: inout GraphicsContext, scale s: Double, text: String, opening: Double) {
        // The fixed pot and its small label stay separate, so new questions
        // never rasterize the complete illustration during a running frame.
        let id = opening <= 0 ? "closed-pot" : "open-pot"
        guard let image = c.resolveSymbol(id: id) else { return }
        var pot = c
        pot.scaleBy(x: s / 2, y: s / 2)
        pot.draw(image, at: .zero, anchor: UnitPoint(x: 0.5, y: 144.0 / 166))
        guard opening > 0 else { return }
        if let label = c.resolveSymbol(id: "label:\(text)") {
            pot.draw(label, at: CGPoint(x: 0, y: -106))
        }
        if opening < 1, let shutter = c.resolveSymbol(id: "pot-shutter") {
            // Slide an existing texture over the cached label. Opening the
            // first row no longer reshapes text and wooden artwork each frame.
            pot.clip(to: Path(roundedRect: CGRect(x: -86, y: -184, width: 172, height: 156), cornerRadius: 22))
            pot.translateBy(x: 0, y: -opening * 164)
            pot.draw(shutter, at: CGPoint(x: 0, y: -106))
        }
    }


}

private enum HoneyRiderDrawing {
    static let artworkAspect = 1312.0 / 1247
    struct Pose {
        let center: CGPoint
        let width: Double
        let rotation: Double
        var bounds: CGRect {
            let angle = rotation * .pi / 180
            let height = width * HoneyRiderDrawing.artworkAspect
            let w = abs(cos(angle)) * width + abs(sin(angle)) * height
            let h = abs(sin(angle)) * width + abs(cos(angle)) * height
            return CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h).insetBy(dx: -2, dy: -2)
        }
    }
    static func draw(in context: GraphicsContext, size: CGSize, simulation: HoneySlideSimulation, reduceMotion: Bool) {
        guard !simulation.isFinishComplete, let bear = context.resolveSymbol(id: "rider") else { return }
        let pose = pose(size: size, simulation: simulation, reduceMotion: reduceMotion)
        var sprite = context
        sprite.translateBy(x: pose.center.x, y: pose.center.y)
        sprite.rotate(by: .degrees(pose.rotation))
        sprite.scaleBy(x: pose.width / 400, y: pose.width / 400)
        sprite.draw(bear, at: .zero)
    }
    static func bounds(size: CGSize, simulation: HoneySlideSimulation, reduceMotion: Bool) -> CGRect {
        guard !simulation.isFinishComplete else { return .null }
        return pose(size: size, simulation: simulation, reduceMotion: reduceMotion).bounds
    }
    static func pose(size: CGSize, simulation: HoneySlideSimulation, reduceMotion: Bool) -> Pose {
        let originalWidth = HoneyTubeGeometry.spriteWidth(in: size)
        let width = originalWidth * simulation.cameraZoom
        let player = HoneySlideRules.ridingPoint(depth: HoneySlideRules.playerDepth,
            lateral: simulation.lateral, distance: simulation.travelTime, course: simulation.course, cameraZoom: simulation.cameraZoom, cameraOffset: simulation.cameraOffset)
        let bobScale = 1 - min(1, simulation.jumpHeight / 0.2)
        let bob = HoneyTubeGeometry.bob(in: size, elapsed: simulation.elapsed, reduceMotion: reduceMotion) * bobScale
        let center = CGPoint(x: player.x / 1600 * size.width, y: size.height * 0.735 + bob
            + (originalWidth - width) * HoneyTubeGeometry.imageAspect * 0.212 - simulation.riderLift * size.height)
        let launchTilt = simulation.hasFinishLaunched ? -28 * (1 - simulation.finishFlightProgress) : 0
        let pitch = reduceMotion ? 0 : simulation.jumpPitch
        return Pose(center: center, width: width, rotation: reduceMotion ? 0 : simulation.tubeHeading + launchTilt + pitch)
    }
}

private enum HoneyFinishLaunchDrawing {
    static func draw(in context: GraphicsContext, size: CGSize, simulation: HoneySlideSimulation,
                     ground: CGPoint, spriteWidth: Double) {
        let p = simulation.finishFlightProgress
        guard p > 0, p < 0.9 else { return }
        let cream = Color(red: 1, green: 0.98, blue: 0.78)
        let gold = Color(red: 1, green: 0.77, blue: 0.06)
        let amber = Color(red: 0.95, green: 0.46, blue: 0.015)
        let expansion = 1 - pow(1 - min(1, p / 0.55), 3)
        let fade = pow(1 - p, 2)
        var burst = context
        burst.translateBy(x: ground.x, y: ground.y)
        for ring in 0..<3 {
            let radius = spriteWidth * (0.35 + expansion * (0.65 + Double(ring) * 0.25))
            burst.stroke(Path(ellipseIn: CGRect(x: -radius, y: -radius * 0.12,
                width: radius * 2, height: radius * 0.24)),
                with: .color((ring == 1 ? gold : cream).opacity(fade * (0.75 - Double(ring) * 0.15))),
                style: StrokeStyle(lineWidth: max(1, spriteWidth * 0.028 * fade), lineCap: .round))
        }
        for index in 0..<24 {
            let angle = Double(index) / 24 * .pi * 2
            let radius = spriteWidth * (0.42 + Double(index % 5) * 0.14) * expansion
            let height = spriteWidth * (0.20 + Double(index % 4) * 0.075) * sin(min(1, p / 0.9) * .pi)
            let x = cos(angle) * radius, y = sin(angle) * radius * 0.19 - height
            let dropSize = max(1, spriteWidth * (0.018 + Double(index % 3) * 0.007) * fade)
            let drop = CGRect(x: x - dropSize / 2, y: y - dropSize, width: dropSize, height: dropSize * 1.7)
            burst.fill(Path(ellipseIn: drop), with: .linearGradient(
                Gradient(colors: [cream.opacity(fade), gold.opacity(fade), amber.opacity(fade * 0.7)]),
                startPoint: drop.origin, endPoint: CGPoint(x: drop.maxX, y: drop.maxY)))
        }
        // Tapered honey jets trail the fast lift, rather than a neon effect.
        let top = -simulation.riderLift * size.height + spriteWidth * 0.12
        let bottom = top * 0.35
        for index in 0..<5 {
            let x = (Double(index) - 2) * spriteWidth * 0.16
            let thickness = spriteWidth * 0.018 * fade
            var jet = Path()
            jet.move(to: CGPoint(x: x - thickness, y: bottom))
            jet.addQuadCurve(to: CGPoint(x: x * 0.7, y: top), control: CGPoint(x: x * 1.25, y: top * 0.58))
            jet.addQuadCurve(to: CGPoint(x: x + thickness, y: bottom), control: CGPoint(x: x * 1.25 + thickness, y: top * 0.58))
            jet.closeSubpath()
            burst.fill(jet, with: .linearGradient(Gradient(colors: [cream.opacity(fade * 0.8), gold.opacity(0)]),
                startPoint: CGPoint(x: x, y: top), endPoint: CGPoint(x: x, y: bottom)))
        }
    }
}

/// Displaced honey follows both the tube's footprint and its steering angle.
/// Filled rolling shoulders, curled wakes and ballistic spray replace rings.
private struct HoneyTubeWater: View {
    let simulation: HoneySlideSimulation
    let foreground: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            Self.draw(in: context, size: size, simulation: simulation, foreground: foreground, reduceMotion: reduceMotion)
        }
    }

    static func draw(in context: GraphicsContext, size: CGSize, simulation: HoneySlideSimulation,
                     foreground: Bool, reduceMotion: Bool) {
        let originalWidth = HoneyTubeGeometry.spriteWidth(in: size)
        let spriteWidth = originalWidth * simulation.cameraZoom
        let spriteHeight = spriteWidth * HoneyTubeGeometry.imageAspect
        let player = HoneySlideRules.ridingPoint(depth: HoneySlideRules.playerDepth,
            lateral: simulation.lateral, distance: simulation.travelTime, course: simulation.course, cameraZoom: simulation.cameraZoom, cameraOffset: simulation.cameraOffset)
        if simulation.isAirborne {
            guard !foreground else { return }
            let ground = CGPoint(x: player.x / 1600 * size.width,
                y: size.height * 0.735 + originalWidth * HoneyTubeGeometry.imageAspect * 0.212)
            if simulation.hasFinishLaunched, !reduceMotion {
                HoneyFinishLaunchDrawing.draw(in: context, size: size, simulation: simulation,
                    ground: ground, spriteWidth: spriteWidth)
            }
            let width = spriteWidth * (0.86 - simulation.jumpHeight * 0.25)
            context.fill(Path(ellipseIn: CGRect(x: ground.x - width / 2, y: ground.y - width * 0.08,
                width: width, height: width * 0.21)), with: .color(Color.brown.opacity(
                    (0.26 - simulation.jumpHeight * 0.08) * (1 - simulation.finishFlightProgress))))
            return
        }
        let angle = reduceMotion ? 0 : simulation.tubeHeading * .pi / 180
        let bob = HoneyTubeGeometry.bob(in: size, elapsed: simulation.elapsed, reduceMotion: reduceMotion)
        var c = context
        c.translateBy(x: player.x / 1600 * size.width - sin(angle) * spriteHeight * 0.28,
                      y: size.height * 0.735 + cos(angle) * spriteHeight * 0.28 + bob
                        + (originalWidth - spriteWidth) * HoneyTubeGeometry.imageAspect * 0.212)
        c.rotate(by: .radians(angle))
        c.scaleBy(x: spriteWidth / 400, y: spriteWidth / 400)
        let time = simulation.elapsed
        let steering = max(-1, min(1, simulation.steeringVelocity))
        let cream = Color(red: 1, green: 0.98, blue: 0.81)
        let amber = Color(red: 0.89, green: 0.45, blue: 0.025)
        if !foreground {
            c.fill(Path(ellipseIn: CGRect(x: -212, y: -31, width: 424, height: 135)),
                   with: .radialGradient(Gradient(colors: [amber.opacity(0.42), .orange.opacity(0)]),
                        center: CGPoint(x: 0, y: 22), startRadius: 60, endRadius: 220))
            for side in [-1.0, 1.0] {
                let push = 1 + side * steering * 0.35
                var surge = Path()
                surge.move(to: CGPoint(x: side * 154, y: 17))
                surge.addCurve(to: CGPoint(x: side * (227 + 10 * push), y: 86),
                    control1: CGPoint(x: side * 199, y: -34 - push * 9 + sin(time * 8) * 5),
                    control2: CGPoint(x: side * 251, y: 15))
                surge.addCurve(to: CGPoint(x: side * 171, y: 106),
                    control1: CGPoint(x: side * 215, y: 132), control2: CGPoint(x: side * 182, y: 101))
                surge.closeSubpath()
                c.fill(surge, with: .linearGradient(Gradient(colors: [cream.opacity(0.95),
                    .yellow.opacity(0.8), .orange.opacity(0.02)]),
                    startPoint: CGPoint(x: side * 179, y: 0), endPoint: CGPoint(x: side * 213, y: 113)))
                for band in 0..<3 {
                    var outer: [CGPoint] = [], inner: [CGPoint] = []
                    for step in 0...20 {
                        let u = Double(step) / 20
                        let wave = sin(u * 12 - time * 8 + Double(band))
                        let x = side * (170 + u * (103 + Double(band) * 40) + wave * (5 + u * 9))
                            - steering * u * u * 85
                        let y = 5 + u * 275 + Double(band) * 8
                        let thickness = (17 - Double(band) * 3) * sin((u * 0.88 + 0.08) * .pi)
                        outer.append(CGPoint(x: x + side * thickness, y: y))
                        inner.append(CGPoint(x: x - side * thickness * 0.5, y: y + 10))
                    }
                    let wake = HoneyFluidContour.closed(outer + inner.reversed())
                    c.fill(wake, with: .linearGradient(Gradient(colors: [cream.opacity(0.82),
                        .yellow.opacity(0.45), .orange.opacity(0)]),
                        startPoint: CGPoint(x: side * 180, y: 15), endPoint: CGPoint(x: side * 320, y: 290)))
                }
            }
        } else {
            // Three overlapping, irregular shoulders roll past the bow.
            // Each is a filled surface with a shaded front and broken gloss.
            for band in (0..<3).reversed() {
                let phase = (time * 1.6 + Double(band) / 3).truncatingRemainder(dividingBy: 1)
                let swell = sin(phase * .pi)
                var upper: [CGPoint] = [], lower: [CGPoint] = []
                for step in 0...28 {
                    let a = .pi * Double(step) / 28
                    let ripple = sin(a * 13 - time * 9 + Double(band))
                    let x = cos(a) * (175 + phase * 34)
                    let y = 11 + sin(a) * (43 + phase * 39) + ripple * 5 * sin(a)
                    let height = (8 + swell * 9) * sin(a) + 2 * pow(sin(a), 2)
                    upper.append(CGPoint(x: x, y: y - height))
                    lower.append(CGPoint(x: x, y: y + (10 + swell * 6) * sin(a)))
                }
                let shoulder = HoneyFluidContour.closed(upper + lower.reversed())
                c.fill(shoulder, with: .linearGradient(Gradient(colors: [
                    Color(red: 1, green: 0.92, blue: 0.34).opacity(0.90 * swell),
                    Color(red: 1, green: 0.66, blue: 0.02).opacity(0.72 * swell), amber.opacity(0)]),
                    startPoint: CGPoint(x: 0, y: 32 + phase * 20), endPoint: CGPoint(x: 0, y: 96 + phase * 25)))
                for section in 0..<4 {
                    var top: [CGPoint] = [], bottom: [CGPoint] = []
                    for step in 0...8 {
                        let u = Double(step) / 8
                        let a = (Double(section) + u * 0.82 + 0.07) / 4 * .pi
                        let x = cos(a) * (175 + phase * 34)
                        let y = 11 + sin(a) * (43 + phase * 39)
                            + sin(a * 13 - time * 9 + Double(band)) * 5 * sin(a)
                        top.append(CGPoint(x: x, y: y - 4 * sin(a) - (3 + swell * 9) * sin(a) * sin(u * .pi)))
                        bottom.append(CGPoint(x: x, y: y - 4 * sin(a) + sin(u * .pi) * 3))
                    }
                    let gloss = HoneyFluidContour.closed(top + bottom.reversed())
                    c.fill(gloss, with: .color(cream.opacity(swell * 0.77)))
                }
            }
        }
        // Steering throws a stronger jet on the outside of the turn.
        for i in 0..<44 {
            let phase = (time * 1.9 + Double(i) / 44).truncatingRemainder(dividingBy: 1)
            let side = i % 2 == 0 ? -1.0 : 1.0
            let strength = 1 + side * steering * 0.45
            let spread = Double(i % 7) * 7
            let x = side * (165 + phase * (65 + spread) * strength) - steering * phase * 35
            let y = 9 + phase * 140 - sin(phase * .pi) * (72 + spread) * strength
            guard (y > 20) == foreground else { continue }
            let opacity = min(1, phase * 12) * pow(1 - phase, 0.8)
            let width = 3 + Double(i % 4) * 1.4
            let rect = CGRect(x: x, y: y, width: width, height: width * (1.1 + sin(phase * .pi)))
            c.fill(Path(ellipseIn: rect), with: .linearGradient(
                Gradient(colors: [cream.opacity(opacity), .yellow.opacity(opacity * 0.75)]),
                startPoint: rect.origin, endPoint: CGPoint(x: rect.maxX, y: rect.maxY)))
            if i % 4 == 0 {
                var tongue = Path(); tongue.move(to: CGPoint(x: side * 168, y: 10))
                tongue.addQuadCurve(to: CGPoint(x: x, y: y), control: CGPoint(x: x, y: y - 21))
                c.stroke(tongue, with: .color(.yellow.opacity(opacity * 0.6)),
                         style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            }
        }
        for i in 0..<20 {
            let phase = (time * 2.5 + Double(i) / 20).truncatingRemainder(dividingBy: 1)
            let side = i % 2 == 0 ? -1.0 : 1.0
            let y = 18 + phase * 164
            guard (y > 58) == foreground else { continue }
            let x = side * (177 + phase * 84 + sin(Double(i) * 1.9 + time) * 12) - steering * phase * 50
            let rect = CGRect(x: x, y: y, width: 7 + phase * 10, height: 3 + phase * 5)
            c.fill(Path(ellipseIn: rect), with: .radialGradient(Gradient(colors: [
                cream.opacity(sin(phase * .pi) * 0.8), .yellow.opacity(0)]),
                center: CGPoint(x: rect.midX, y: rect.midY), startRadius: 0, endRadius: rect.width / 2))
        }
    }
}

/// Quadratic shoulders remove polygonal edges from every filled fluid patch.
private enum HoneyFluidContour {
    static func closed(_ points: [CGPoint]) -> Path {
        guard let first = points.first, let last = points.last else { return Path() }
        func middle(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
            CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        }
        let path = CGMutablePath()
        path.move(to: middle(last, first))
        for i in points.indices {
            let next = points[(i + 1) % points.count]
            path.addQuadCurve(to: middle(points[i], next), control: points[i])
        }
        path.closeSubpath()
        return Path(path)
    }
}

enum HoneyPotArtwork {
    static let darkWood = Color(red: 0.29, green: 0.12, blue: 0.025)
    static let warmWood = Color(red: 0.77, green: 0.40, blue: 0.10)

    static func base(_ c: inout GraphicsContext, showsShadow: Bool = true) {
        if showsShadow {
            ellipse(&c, CGRect(x: -77, y: -3, width: 154, height: 25),
                    [darkWood.opacity(0.38), .orange.opacity(0)])
        }
        ellipse(&c, CGRect(x: -58, y: -16, width: 116, height: 29), [warmWood, darkWood])
        // Bulging staves, elliptical hoops and a recessed face give the pot
        // volume. The bright left shoulder and dark right side stay consistent.
        var body = Path()
        body.move(to: CGPoint(x: -58, y: -113))
        body.addCurve(to: CGPoint(x: -53, y: -2), control1: CGPoint(x: -80, y: -92),
                      control2: CGPoint(x: -75, y: -23))
        body.addQuadCurve(to: CGPoint(x: 53, y: -2), control: CGPoint(x: 0, y: 19))
        body.addCurve(to: CGPoint(x: 58, y: -113), control1: CGPoint(x: 75, y: -23),
                      control2: CGPoint(x: 80, y: -92))
        body.addQuadCurve(to: CGPoint(x: -58, y: -113), control: CGPoint(x: 0, y: -135))
        body.closeSubpath()
        c.fill(body, with: .radialGradient(Gradient(colors: [Color(red: 0.92, green: 0.57, blue: 0.22),
            warmWood, Color(red: 0.39, green: 0.17, blue: 0.035), darkWood]),
            center: CGPoint(x: -27, y: -75), startRadius: 0, endRadius: 114))
        c.stroke(body, with: .color(darkWood), lineWidth: 3)
        for x in [-60.0, -49, -31, 31, 49, 60] {
            var seam = Path()
            seam.move(to: CGPoint(x: x * 0.88, y: -114))
            seam.addCurve(to: CGPoint(x: x * 0.86, y: -3), control1: CGPoint(x: x * 1.10, y: -93),
                          control2: CGPoint(x: x * 1.10, y: -30))
            c.stroke(seam, with: .color(darkWood.opacity(0.70)), lineWidth: 2)
            c.stroke(seam.offsetBy(dx: 2, dy: 0), with: .color(.orange.opacity(0.32)), lineWidth: 1)
        }
        for y in [-98.0, -14] {
            var hoop = Path()
            hoop.move(to: CGPoint(x: -64, y: y))
            hoop.addQuadCurve(to: CGPoint(x: 64, y: y), control: CGPoint(x: 0, y: y + 22))
            c.stroke(hoop, with: .color(darkWood), style: StrokeStyle(lineWidth: 8, lineCap: .round))
            c.stroke(hoop.offsetBy(dx: 0, dy: -2), with: .color(Color(red: 0.92, green: 0.63, blue: 0.26)),
                     style: StrokeStyle(lineWidth: 3, lineCap: .round))
            for side in [-1.0, 1.0] {
                ellipse(&c, CGRect(x: side * 59 - 2, y: y + 1, width: 4, height: 5), [.yellow, darkWood])
            }
        }
        var shoulder = Path()
        shoulder.move(to: CGPoint(x: -57, y: -84))
        shoulder.addQuadCurve(to: CGPoint(x: -56, y: -34), control: CGPoint(x: -64, y: -58))
        c.stroke(shoulder, with: .color(Color(red: 1, green: 0.77, blue: 0.39).opacity(0.58)),
                 style: StrokeStyle(lineWidth: 3, lineCap: .round))
        let window = CGRect(x: -43, y: -92, width: 86, height: 78)
        let windowPath = Path(roundedRect: window, cornerRadius: 11)
        c.stroke(windowPath, with: .color(darkWood.opacity(0.8)), lineWidth: 7)
        c.fill(windowPath, with: .linearGradient(Gradient(colors: [
            Color(red: 0.23, green: 0.09, blue: 0.02), Color(red: 0.57, green: 0.29, blue: 0.08)]),
            startPoint: window.origin, endPoint: CGPoint(x: 20, y: -14)))
        for side in [-1.0, 1.0] {
            rounded(&c, CGRect(x: side * 47 - 3, y: -95, width: 6, height: 86), 3,
                    Color(red: 0.94, green: 0.61, blue: 0.18))
            rounded(&c, CGRect(x: side * 47, y: -94, width: 2, height: 83), 1, darkWood.opacity(0.6))
        }
    }

    static func face(_ c: inout GraphicsContext, text: String?, opening: Double = 1, clipsToWindow: Bool = true) {
        let window = CGRect(x: -43, y: -92, width: 86, height: 78)
        var face = c
        if clipsToWindow { face.clip(to: Path(roundedRect: window, cornerRadius: 11)) }
        if let text {
            if opening > 0 {
                let fontSize = text.count > 3 ? 36.0 : text.count > 2 ? 46.0 : 59.0
                let label = Text(text).font(.system(size: fontSize, weight: .black, design: .rounded))
                face.draw(label.foregroundColor(darkWood), at: CGPoint(x: 2, y: -49))
                face.draw(label.foregroundColor(Color(red: 1, green: 0.96, blue: 0.79)), at: CGPoint(x: 0, y: -52))
            }
            if opening < 1 {
                let shutter = window.offsetBy(dx: 0, dy: -opening * 82)
                face.fill(Path(shutter), with: .linearGradient(Gradient(colors: [warmWood,
                    Color(red: 0.58, green: 0.27, blue: 0.055), warmWood]),
                    startPoint: shutter.origin, endPoint: CGPoint(x: shutter.maxX, y: shutter.minY)))
                for j in 1...3 {
                    let y = shutter.minY + Double(j) * 19
                    var seam = Path(); seam.move(to: CGPoint(x: shutter.minX, y: y)); seam.addLine(to: CGPoint(x: shutter.maxX, y: y))
                    face.stroke(seam, with: .color(darkWood.opacity(0.65)), lineWidth: 1.5)
                }
                rounded(&face, CGRect(x: -17, y: shutter.maxY - 18, width: 34, height: 7), 3, darkWood)
                rounded(&face, CGRect(x: -16, y: shutter.maxY - 18, width: 32, height: 2), 1, .orange)
            }
        } else {
            // Currency keeps the same pot and shows a small embossed honey drop.
            var drop = Path()
            drop.move(to: CGPoint(x: 0, y: -83))
            drop.addCurve(to: CGPoint(x: 0, y: -29), control1: CGPoint(x: -39, y: -47), control2: CGPoint(x: -21, y: -29))
            drop.addCurve(to: CGPoint(x: 0, y: -83), control1: CGPoint(x: 30, y: -28), control2: CGPoint(x: 33, y: -47))
            face.fill(drop, with: .linearGradient(Gradient(colors: [.yellow, .orange]),
                startPoint: CGPoint(x: -12, y: -75), endPoint: CGPoint(x: 19, y: -29)))
            ellipse(&face, CGRect(x: -12, y: -56, width: 7, height: 16), [.white.opacity(0.85), .yellow.opacity(0)])
        }
    }
    static func crown(_ c: inout GraphicsContext) {
        let p = CGPoint.zero, s = 1.0
        let darkWood = Color(red: 0.29, green: 0.12, blue: 0.025)
        let warmWood = Color(red: 0.77, green: 0.40, blue: 0.10)
        // A raised wooden rim carries a pooled, glossy honey crown. Uneven
        // drips and small flowers give the top the same lush look as the bank.
        ellipse(&c, CGRect(x: p.x - 65 * s, y: p.y - 122 * s, width: 130 * s, height: 32 * s),
                [warmWood, darkWood])
        let pool = CGRect(x: -63, y: -131, width: 126, height: 37)
        ellipse(&c, pool, [Color(red: 1, green: 0.79, blue: 0.12),
                          Color(red: 1, green: 0.96, blue: 0.47), Color(red: 1, green: 0.57, blue: 0.015)])
        c.stroke(Path(ellipseIn: pool), with: .color(Color(red: 0.91, green: 0.46, blue: 0.025)), lineWidth: 1.5)
        ellipse(&c, CGRect(x: -52, y: -126, width: 105, height: 23),
                [Color(red: 1, green: 0.64, blue: 0.035), Color(red: 1, green: 0.91, blue: 0.31)])
        var poolShine = Path()
        poolShine.move(to: CGPoint(x: -47, y: -118))
        poolShine.addCurve(to: CGPoint(x: 17, y: -121), control1: CGPoint(x: -33, y: -131),
                           control2: CGPoint(x: 5, y: -126))
        c.stroke(poolShine, with: .color(.white.opacity(0.90)),
                 style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
        var lip = Path()
        lip.move(to: CGPoint(x: p.x - 61 * s, y: p.y - 112 * s))
        lip.addCurve(to: CGPoint(x: p.x + 61 * s, y: p.y - 112 * s),
                     control1: CGPoint(x: p.x - 30 * s, y: p.y - 98 * s),
                     control2: CGPoint(x: p.x + 25 * s, y: p.y - 101 * s))
        lip.addQuadCurve(to: CGPoint(x: p.x + 57 * s, y: p.y - 98 * s),
                         control: CGPoint(x: p.x + 67 * s, y: p.y - 99 * s))
        lip.addCurve(to: CGPoint(x: p.x - 57 * s, y: p.y - 98 * s),
                     control1: CGPoint(x: p.x + 26 * s, y: p.y - 89 * s),
                     control2: CGPoint(x: p.x - 30 * s, y: p.y - 92 * s))
        lip.addQuadCurve(to: CGPoint(x: p.x - 61 * s, y: p.y - 112 * s),
                         control: CGPoint(x: p.x - 67 * s, y: p.y - 100 * s))
        lip.closeSubpath()
        c.fill(lip, with: .linearGradient(Gradient(colors: [.yellow, Color(red: 1, green: 0.66, blue: 0.06)]),
                startPoint: CGPoint(x: p.x, y: p.y - 112 * s), endPoint: CGPoint(x: p.x, y: p.y - 91 * s)))
        for (x, width, length) in [(-53.0, 12.0, 17.0), (-30, 10, 25), (-8, 11, 11), (19, 13, 22), (43, 9, 14)] {
            let drip = CGRect(x: p.x + x * s, y: p.y - 105 * s, width: width * s, height: length * s)
            var tongue = Path()
            tongue.move(to: CGPoint(x: drip.minX - 3, y: drip.minY))
            tongue.addCurve(to: CGPoint(x: drip.minX + 1, y: drip.maxY - width / 2),
                            control1: CGPoint(x: drip.minX + 3, y: drip.minY + 4),
                            control2: CGPoint(x: drip.minX, y: drip.maxY - width))
            tongue.addQuadCurve(to: CGPoint(x: drip.maxX, y: drip.maxY - width / 2),
                                control: CGPoint(x: drip.midX, y: drip.maxY + 4))
            tongue.addCurve(to: CGPoint(x: drip.maxX + 3, y: drip.minY),
                            control1: CGPoint(x: drip.maxX + 2, y: drip.maxY - width),
                            control2: CGPoint(x: drip.maxX - 3, y: drip.minY + 4))
            tongue.closeSubpath()
            c.fill(tongue, with: .linearGradient(
                Gradient(colors: [Color(red: 1, green: 0.92, blue: 0.25), Color(red: 1, green: 0.59, blue: 0.015)]),
                startPoint: drip.origin, endPoint: CGPoint(x: drip.maxX, y: drip.maxY)))
            c.stroke(tongue, with: .color(.orange.opacity(0.50)), lineWidth: 0.8)
            rounded(&c, CGRect(x: drip.minX + 2 * s, y: drip.minY + 3 * s,
                              width: 2 * s, height: max(3, length - 10) * s), s, .yellow.opacity(0.85))
        }
        ellipse(&c, CGRect(x: p.x + 25 * s, y: p.y - 121 * s, width: 15 * s, height: 5 * s),
                [.white.opacity(0.85), .yellow.opacity(0.15)])
        ellipse(&c, CGRect(x: -6, y: -110, width: 19, height: 4), [.white.opacity(0.78), .yellow.opacity(0.2)])
        for side in [-1.0, 1.0] {
            for j in 0..<2 {
                var sprig = c
                sprig.translateBy(x: p.x + side * (43 + Double(j) * 7) * s,
                                  y: p.y - (125 + Double(j) * 7) * s)
                sprig.rotate(by: .degrees(side * (25 + Double(j) * 45)))
                ellipse(&sprig, CGRect(x: -12 * s, y: -5 * s, width: 24 * s, height: 10 * s),
                        [Color(red: 0.57, green: 0.78, blue: 0.15), Color(red: 0.13, green: 0.43, blue: 0.09)])
            }
        }
        let flower = CGPoint(x: p.x + 34 * s, y: p.y - 132 * s)
        for j in 0..<5 {
            let angle = Double(j) / 5 * .pi * 2
            ellipse(&c, CGRect(x: flower.x + cos(angle) * 6 * s - 4 * s,
                               y: flower.y + sin(angle) * 6 * s - 4 * s, width: 8 * s, height: 8 * s),
                    [.white, Color(red: 1, green: 0.94, blue: 0.77)])
        }
        ellipse(&c, CGRect(x: flower.x - 3 * s, y: flower.y - 3 * s, width: 6 * s, height: 6 * s), [.yellow, .orange])
    }
    private static func ellipse(_ c: inout GraphicsContext, _ rect: CGRect, _ colors: [Color]) {
        c.fill(Path(ellipseIn: rect), with: .linearGradient(Gradient(colors: colors), startPoint: rect.origin,
                  endPoint: CGPoint(x: rect.maxX, y: rect.maxY)))
    }
    private static func rounded(_ c: inout GraphicsContext, _ rect: CGRect, _ radius: CGFloat, _ color: Color) {
        c.fill(Path(roundedRect: rect, cornerRadius: radius), with: .color(color))
    }
}

private struct HoneyRailFaceSymbol: View, Equatable {
    let variant: Int
    var body: some View {
        Canvas { c, _ in
            let warm = Double(variant) * 0.025
            c.fill(Path(CGRect(x: 0, y: 6, width: 256, height: 84)), with: .linearGradient(Gradient(colors: [
                Color(red: 0.76 + warm, green: 0.48 + warm, blue: 0.22),
                Color(red: 0.43 + warm, green: 0.23, blue: 0.10)]),
                startPoint: CGPoint(x: 128, y: 6), endPoint: CGPoint(x: 128, y: 90)))
            var lip = Path(); lip.move(to: CGPoint(x: 0, y: 6)); lip.addLine(to: CGPoint(x: 256, y: 6))
            c.stroke(lip, with: .color(Color(red: 0.99, green: 0.62, blue: 0.02)), lineWidth: 8)
            c.stroke(lip.offsetBy(dx: 0, dy: -2), with: .color(Color(red: 1, green: 0.94, blue: 0.62)), lineWidth: 2.5)
        }
        .frame(width: 256, height: 96)
    }
}

private struct HoneyRailCapSymbol: View, Equatable {
    var body: some View {
        Canvas { c, _ in
            c.fill(Path(CGRect(x: 0, y: 0, width: 256, height: 64)), with: .linearGradient(Gradient(colors: [
                Color(red: 0.98, green: 0.80, blue: 0.38), Color(red: 0.87, green: 0.59, blue: 0.25)]),
                startPoint: CGPoint(x: 128, y: 64), endPoint: CGPoint(x: 128, y: 0)))
        }
        .frame(width: 256, height: 64)
    }
}

private struct HoneyDividerFaceSymbol: View, Equatable {
    let variant: Int
    let rightSide: Bool
    var body: some View {
        Canvas { c, _ in
            let warm = Double(variant) * 0.025
            let colors = rightSide ? [Color(red: 0.87, green: 0.61 + warm, blue: 0.29), Color(red: 0.48, green: 0.27, blue: 0.12)]
                : [Color(red: 0.77 + warm, green: 0.49, blue: 0.23), Color(red: 0.39 + warm, green: 0.22, blue: 0.10)]
            c.fill(Path(CGRect(x: 0, y: 6, width: 256, height: 58)), with: .linearGradient(Gradient(colors: colors),
                startPoint: CGPoint(x: 128, y: 6), endPoint: CGPoint(x: 128, y: 64)))
            if rightSide {
                var grain = Path()
                for fraction in [0.35, 0.72] {
                    let y = 6 + 58 * (1 - fraction)
                    grain.move(to: CGPoint(x: 0, y: y)); grain.addLine(to: CGPoint(x: 256, y: y))
                }
                c.stroke(grain, with: .color(Color(red: 1, green: 0.84, blue: 0.49).opacity(0.25)), lineWidth: 1.2)
            } else {
                var lip = Path(); lip.move(to: CGPoint(x: 0, y: 6)); lip.addLine(to: CGPoint(x: 256, y: 6))
                c.stroke(lip, with: .color(Color(red: 1, green: 0.66, blue: 0.035)), lineWidth: 7)
                c.stroke(lip.offsetBy(dx: 0, dy: -1), with: .color(Color(red: 1, green: 0.97, blue: 0.72)), lineWidth: 2)
            }
        }
        .frame(width: 256, height: 70)
    }
}

private struct HoneyPotSymbol: View, Equatable {
    let crown: Bool
    var body: some View {
        Canvas { context, _ in
            var c = context
            // Draw cached artwork at double density for crisp near-camera pots.
            c.scaleBy(x: 2, y: 2)
            c.translateBy(x: 77, y: 144)
            if crown { HoneyPotArtwork.crown(&c) } else { HoneyPotArtwork.base(&c) }
        }
        .frame(width: 308, height: 332)
    }
}

/// Reusing a Canvas symbol reuses its view, but can still replay its vector
/// display list for every tree/pot. A real bitmap removes those nested paths,
/// gradients and text from every subsequent frame. Fixed artwork is exported
/// to the asset catalog by Tools/honey_performance.py --export-artwork.
private enum HoneyBundledArtwork {
    static let names: [String: String] = {
        var names = ["pot-shutter": "honey-pot-shutter",
                     "closed-pot": "honey-pot-closed", "open-pot": "honey-pot-open"]
        for variant in 0..<4 { names["tree:\(variant)"] = "honey-tree-\(variant)" }
        for variant in 0..<4 { names["rail-face:\(variant)"] = "honey-rail-face-\(variant)" }
        names["rail-cap"] = "honey-rail-cap"
        for variant in 0..<3 {
            names["divider-left:\(variant)"] = "honey-divider-left-\(variant)"
            names["divider-right:\(variant)"] = "honey-divider-right-\(variant)"
        }
        for variant in 0..<2 {
            names["brush:\(variant)"] = "honey-brush-\(variant)"
            names["cliff:\(variant)"] = "honey-cliff-\(variant)"
        }
        for kind in HoneyTrackItemKind.allCases where kind != .whirlpool {
            names["race-prop-v5:\(kind.rawValue)"] = "honey-prop-\(kind.rawValue)"
        }
        return names
    }()
}

@MainActor
private final class HoneyArtworkCache {
    static let shared = HoneyArtworkCache()
    private let images = NSCache<NSString, CGImage>()
    #if canImport(UIKit)
    private let collectionImages = NSCache<NSString, UIImage>()
    private var maskSource: Image?
    private var riderMask: HoneyRiderAlphaMask?
    #endif
    private init() {
        images.countLimit = 64
        images.totalCostLimit = 12 * 1024 * 1024
        #if canImport(UIKit)
        collectionImages.countLimit = 8
        collectionImages.totalCostLimit = 8 * 1024 * 1024
        #endif
    }
    func image<Content: View>(key: String, size: CGSize, density: CGFloat, content: Content) -> CGImage? {
        let cacheKey = "\(key):\(size.width)x\(size.height)@\(density)" as NSString
        if let image = images.object(forKey: cacheKey) { return image }
        let renderer = ImageRenderer(content: content.frame(width: size.width, height: size.height))
        renderer.scale = density
        guard let image = renderer.cgImage else { return nil }
        images.setObject(image, forKey: cacheKey, cost: image.bytesPerRow * image.height)
        return image
    }
    #if canImport(UIKit)
    func collectionImage(text: String) -> UIImage? {
        if let image = collectionImages.object(forKey: text as NSString) { return image }
        guard let base = UIImage(named: "honey-pot-open")?.cgImage,
              let label = image(key: "label:\(text)", size: CGSize(width: 172, height: 156),
                                density: 2, content: HoneyPotLabelSymbol(text: text)),
              let bitmap = CGContext(data: nil, width: 616, height: 664, bitsPerComponent: 8, bytesPerRow: 0,
                space: base.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)) else { return nil }
        bitmap.draw(base, in: CGRect(x: 0, y: 0, width: 616, height: 664))
        bitmap.draw(label, in: CGRect(x: 136, y: 144, width: 344, height: 312))
        guard let cg = bitmap.makeImage() else { return nil }
        let result = UIImage(cgImage: cg, scale: 2, orientation: .up)
        collectionImages.setObject(result, forKey: text as NSString, cost: cg.bytesPerRow * cg.height)
        return result
    }

    func inverseRiderMask(for rider: Image) -> HoneyRiderAlphaMask? {
        if maskSource == rider, let riderMask { return riderMask }
        let reference = CGSize(width: 1024, height: 1024 * HoneyRiderDrawing.artworkAspect)
        let renderer = ImageRenderer(content: rider.resizable().scaledToFit()
            .frame(width: reference.width, height: reference.height))
        renderer.scale = 1
        guard let bear = renderer.cgImage else { return nil }
        let padding = 32.0
        let width = Int(ceil(reference.width + padding * 2))
        let height = Int(ceil(reference.height + padding * 2))
        guard let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: nil, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.alphaOnly.rawValue)) else { return nil }
        bitmap.setFillColor(gray: 1, alpha: 1)
        bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
        bitmap.setBlendMode(.destinationOut)
        bitmap.draw(bear, in: CGRect(x: (Double(width) - reference.width) / 2,
            y: (Double(height) - reference.height) / 2, width: reference.width, height: reference.height))
        guard let image = bitmap.makeImage() else { return nil }
        let mask = HoneyRiderAlphaMask(image: image, reference: reference, holePadding: padding / 2)
        maskSource = rider
        riderMask = mask
        return mask
    }
    #endif
}

private struct HoneyBitmapSymbol<Content: View>: View, Equatable {
    let key: String
    let size: CGSize
    var density: CGFloat = 2
    let content: Content
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.key == rhs.key && lhs.size == rhs.size && lhs.density == rhs.density }
    var body: some View {
        if let assetName = HoneyBundledArtwork.names[key] {
            Image(assetName).resizable().frame(width: size.width, height: size.height)
        } else if let image = HoneyArtworkCache.shared.image(key: key, size: size, density: density, content: content) {
            Image(decorative: image, scale: density).resizable().frame(width: size.width, height: size.height)
        } else {
            content.frame(width: size.width, height: size.height)
        }
    }
}

/// The label occupies exactly the pot's recessed 86 × 78 face. At the same
/// density it needs about a quarter of a complete numbered pot's memory.
private struct HoneyPotLabelSymbol: View, Equatable {
    let text: String
    var body: some View {
        Canvas { context, _ in
            var c = context
            c.scaleBy(x: 2, y: 2)
            c.translateBy(x: 43, y: 92)
            HoneyPotArtwork.face(&c, text: text)
        }
        .frame(width: 172, height: 156)
    }
}

private struct HoneyPotShutterSymbol: View, Equatable {
    var body: some View {
        Canvas { context, _ in
            var c = context
            c.scaleBy(x: 2, y: 2)
            c.translateBy(x: 43, y: 92)
            HoneyPotArtwork.face(&c, text: "", opening: 0, clipsToWindow: false)
        }
        .frame(width: 172, height: 156)
    }
}

private struct HoneyClosedPotSymbol: View, Equatable {
    var body: some View {
        Canvas { context, _ in
            var c = context
            c.scaleBy(x: 2, y: 2)
            c.translateBy(x: 77, y: 144)
            HoneyPotArtwork.base(&c)
            HoneyPotArtwork.face(&c, text: "", opening: 0)
            HoneyPotArtwork.crown(&c)
        }
        .frame(width: 308, height: 332)
    }
}

/// Shared pot artwork for the playfield, score counter and currency silhouette.
struct HoneyPotIllustration: View, Equatable {
    var text: String? = nil
    var showsShadow = true
    var body: some View {
        Canvas { context, size in
            var c = context
            let scale = min(size.width / 154, size.height / 166)
            c.translateBy(x: size.width / 2, y: (size.height - 166 * scale) / 2 + 144 * scale)
            c.scaleBy(x: scale, y: scale)
            HoneyPotArtwork.base(&c, showsShadow: showsShadow)
            HoneyPotArtwork.face(&c, text: text)
            HoneyPotArtwork.crown(&c)
        }
    }
}

private struct HoneyHUDAnchors {
    var score: Anchor<CGRect>?
}

private struct HoneyScoreAnchor: PreferenceKey {
    static var defaultValue: HoneyHUDAnchors { HoneyHUDAnchors() }
    static func reduce(value: inout HoneyHUDAnchors, nextValue: () -> HoneyHUDAnchors) {
        let next = nextValue()
        if let score = next.score { value.score = score }
    }
}

/// Permanently mounted effects above the HUD reuse the world's pot and label.
private struct HoneyImpactEffects: View {
    let simulation: HoneySlideSimulation
    let rider: Image
    let reduceMotion: Bool
    let target: CGRect?
    private var potTexts: [String] {
        Array(Set(simulation.impacts.filter(\.correct).map(\.text))).sorted()
    }
    var body: some View {
        #if canImport(UIKit)
        GeometryReader { proxy in
            HoneyNativeImpactLayer(simulation: simulation, rider: rider, reduceMotion: reduceMotion,
                                   target: target, size: proxy.size)
        }
        #else
        GeometryReader { proxy in
            let size = proxy.size
            let bounds = effectBounds(size: size)
            Canvas(rendersAsynchronously: true) { context, _ in
                var local = context
                local.translateBy(x: -bounds.minX, y: -bounds.minY)
                drawCollection(in: local, size: size)
            } symbols: {
                HoneyBitmapSymbol(key: "open-pot", size: CGSize(width: 308, height: 332),
                    content: HoneyPotIllustration(text: "")).equatable().tag("open-pot")
                ForEach(potTexts, id: \.self) { text in
                    HoneyBitmapSymbol(key: "label:\(text)", size: CGSize(width: 172, height: 156),
                        content: HoneyPotLabelSymbol(text: text)).equatable().tag("label:\(text)")
                }
                rider.resizable().scaledToFit().frame(width: 400, height: 400 * HoneyRiderDrawing.artworkAspect).tag("rider")
            }
            .frame(width: bounds.width, height: bounds.height)
            .position(x: bounds.midX, y: bounds.midY)
        }
        #endif
    }

    struct Flight {
        let origin: CGPoint
        let target: CGPoint
        let initialScale: Double
        let finalScale: Double
        func motion(at progress: Double) -> HoneyCollectionMotion {
            HoneyCollectionMotion(progress: progress, origin: origin, target: target,
                                  initialScale: initialScale, finalScale: finalScale)
        }
        func bounds(at progress: Double) -> CGRect {
            let motion = motion(at: progress)
            let angle = motion.rotation * .pi / 180
            let w = (abs(cos(angle)) * 308 + abs(sin(angle)) * 332) * motion.scale
            let h = (abs(sin(angle)) * 308 + abs(cos(angle)) * 332) * motion.scale
            return CGRect(x: motion.center.x - w / 2, y: motion.center.y - h / 2, width: w, height: h)
        }
    }

    static func flight(for impact: HoneyPotImpact, size: CGSize, target: CGRect) -> Flight {
        Flight(origin: CGPoint(x: impact.origin.x / 1600 * size.width,
                               y: impact.origin.y / 900 * size.height - 61 * impact.scale * size.width / 1600),
               target: CGPoint(x: target.midX, y: target.midY),
               initialScale: impact.scale * size.width / 1600 / 2,
               finalScale: min(target.width / 308, target.height / 332))
    }

    private func effectBounds(size: CGSize) -> CGRect {
        guard let target else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        var bounds = CGRect.null
        for impact in simulation.impacts where impact.correct {
            let progress = impact.progress(at: simulation.elapsed)
            guard progress < 1 else { continue }
            let flight = Self.flight(for: impact, size: size, target: target)
            bounds = bounds.union(flight.bounds(at: progress))
            if progress < 0.5 {
                bounds = bounds.union(HoneyRiderDrawing.bounds(size: size, simulation: simulation, reduceMotion: reduceMotion))
            }
            for i in 1...4 {
                let trail = flight.motion(at: max(0, progress - Double(i) * 0.035))
                bounds = bounds.union(CGRect(x: trail.center.x - 10, y: trail.center.y - 10, width: 20, height: 20))
            }
        }
        guard !bounds.isNull else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        // Keep the texture on the same pixel grid as the full playfield, with
        // room for antialiasing. The overlay no longer allocates/blends a
        // screen-sized transparent surface for a small pot and its trail.
        let visible = bounds.insetBy(dx: -4, dy: -4).integral
            .intersection(CGRect(origin: .zero, size: size))
        return visible.isEmpty ? CGRect(x: 0, y: 0, width: 1, height: 1) : visible
    }

    private func drawCollection(in context: GraphicsContext, size: CGSize) {
        guard let target = target else { return }
        for impact in simulation.impacts where impact.correct {
            let progress = impact.progress(at: simulation.elapsed)
            guard progress < 1, let pot = context.resolveSymbol(id: "open-pot") else { continue }
            // Convert the same ground anchor, center offset and uniform scale
            // used by barrel. At contact this is exactly the pot's last pose.
            let flight = Self.flight(for: impact, size: size, target: target)
            let motion = flight.motion(at: progress)
            // Small droplets follow the path; the pot itself stays opaque.
            if progress > 0.04 && progress < 0.92 {
                for i in 1...4 {
                    let trail = flight.motion(at: max(0, progress - Double(i) * 0.035))
                    let radius = max(2, 8 * motion.scale) * (1 - Double(i) / 6)
                    context.fill(Path(ellipseIn: CGRect(x: trail.center.x - radius, y: trail.center.y - radius,
                        width: radius * 2, height: radius * 2)),
                        with: .color(.yellow.opacity(0.40 - Double(i) * 0.065)))
                }
            }
            func drawPot(_ context: GraphicsContext) {
                var flying = context
                flying.translateBy(x: motion.center.x, y: motion.center.y)
                flying.rotate(by: .degrees(motion.rotation))
                flying.scaleBy(x: motion.scale, y: motion.scale)
                flying.draw(pot, at: .zero)
                if let label = context.resolveSymbol(id: "label:\(impact.text)") {
                    flying.draw(label, at: CGPoint(x: 0, y: 16))
                }
            }
            if progress < 0.5 {
                // Erase only the rider's actual alpha silhouette from the
                // flight. The world already contains that same bear pose.
                // No image handoff, fade or z-order jump is needed later.
                context.drawLayer { behind in
                    drawPot(behind)
                    behind.blendMode = .destinationOut
                    HoneyRiderDrawing.draw(in: behind, size: size, simulation: simulation, reduceMotion: reduceMotion)
                }
            } else {
                drawPot(context)
            }
        }
    }

}

#if canImport(UIKit)
private struct HoneyRiderAlphaMask {
    let image: CGImage
    let reference: CGSize
    let holePadding: CGFloat
}

/// Animate existing textures with Core Animation. A second changing Canvas
/// forced an extra render pass during every collection flight.
private struct HoneyNativeImpactLayer: UIViewRepresentable {
    let simulation: HoneySlideSimulation
    let rider: Image
    let reduceMotion: Bool
    let target: CGRect?
    let size: CGSize

    func makeUIView(context: Context) -> HoneyImpactView { HoneyImpactView() }
    func updateUIView(_ view: HoneyImpactView, context: Context) {
        view.update(simulation: simulation, rider: rider, reduceMotion: reduceMotion, target: target, size: size)
    }
}

private final class HoneyImpactView: UIView {
    private var flights: [Int: HoneyPotFlightView] = [:]
    init() {
        super.init(frame: .zero)
        isOpaque = false
        isUserInteractionEnabled = false
        clipsToBounds = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(simulation: HoneySlideSimulation, rider: Image, reduceMotion: Bool, target: CGRect?, size: CGSize) {
        // Prepare the silhouette while the intro is visible, before contact.
        let mask = HoneyArtworkCache.shared.inverseRiderMask(for: rider)
        let active = simulation.impacts.filter { $0.correct && $0.progress(at: simulation.elapsed) < 1 && target != nil }
        let ids = Set(active.map(\.id))
        for id in Array(flights.keys) where !ids.contains(id) {
            flights.removeValue(forKey: id)?.removeFromSuperview()
        }
        guard let target else { return }
        let pose = HoneyRiderDrawing.pose(size: size, simulation: simulation, reduceMotion: reduceMotion)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for impact in active {
            let view: HoneyPotFlightView
            if let existing = flights[impact.id] { view = existing }
            else {
                view = HoneyPotFlightView(image: HoneyArtworkCache.shared.collectionImage(text: impact.text))
                flights[impact.id] = view
                addSubview(view)
            }
            view.frame = CGRect(origin: .zero, size: size)
            view.update(flight: HoneyImpactEffects.flight(for: impact, size: size, target: target),
                        progress: impact.progress(at: simulation.elapsed), rider: pose,
                        mask: simulation.isFinishComplete ? nil : mask)
        }
        CATransaction.commit()
    }
}

private final class HoneyPotFlightView: UIView {
    private let pot = UIImageView()
    private let trails = (0..<4).map { _ in UIView() }
    private let silhouette = CALayer()
    private let outside = CAShapeLayer()
    private let inverse = CALayer()

    init(image: UIImage?) {
        super.init(frame: .zero)
        isOpaque = false
        isUserInteractionEnabled = false
        for (index, trail) in trails.enumerated() {
            trail.backgroundColor = UIColor(Color.yellow).withAlphaComponent(0.40 - Double(index + 1) * 0.065)
            addSubview(trail)
        }
        pot.image = image
        pot.bounds = CGRect(x: 0, y: 0, width: 308, height: 332)
        addSubview(pot)
        silhouette.frame = pot.bounds
        silhouette.masksToBounds = true
        outside.fillColor = UIColor.white.cgColor
        outside.fillRule = .evenOdd
        silhouette.addSublayer(outside)
        silhouette.addSublayer(inverse)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(flight: HoneyImpactEffects.Flight, progress: Double, rider: HoneyRiderDrawing.Pose,
                mask: HoneyRiderAlphaMask?) {
        let motion = flight.motion(at: progress)
        pot.center = motion.center
        pot.transform = CGAffineTransform(rotationAngle: motion.rotation * .pi / 180)
            .scaledBy(x: motion.scale, y: motion.scale)
        for (index, trail) in trails.enumerated() {
            trail.isHidden = progress <= 0.04 || progress >= 0.92
            let radius = max(2, 8 * motion.scale) * (1 - Double(index + 1) / 6)
            trail.bounds = CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2)
            trail.layer.cornerRadius = radius
            trail.center = flight.motion(at: max(0, progress - Double(index + 1) * 0.035)).center
        }
        guard progress < 0.5, let mask else { pot.layer.mask = nil; return }
        let center = pot.convert(rider.center, from: self)
        let scale = rider.width / mask.reference.width / motion.scale
        let angle = (rider.rotation - motion.rotation) * .pi / 180
        let transform = CGAffineTransform(rotationAngle: angle).scaledBy(x: scale, y: scale)
        inverse.contents = mask.image
        inverse.bounds = CGRect(x: 0, y: 0, width: mask.image.width, height: mask.image.height)
        inverse.position = center
        inverse.setAffineTransform(transform)
        // The small inverse-alpha image overlaps an opaque outside region.
        // Its white padding prevents seams without a screen-sized mask.
        let path = CGMutablePath()
        path.addRect(pot.bounds)
        let hole = CGRect(x: -mask.reference.width / 2, y: -mask.reference.height / 2,
                          width: mask.reference.width, height: mask.reference.height)
            .insetBy(dx: -mask.holePadding, dy: -mask.holePadding)
        var placed = transform
        placed.tx = center.x
        placed.ty = center.y
        path.addRect(hole, transform: placed)
        outside.path = path
        pot.layer.mask = silhouette
    }
}

/// Keep feedback visibility out of the world's Canvas display-list commit.
/// The same native layers stay allocated when the correction disappears.
private struct HoneyNativeFeedbackSign: UIViewRepresentable {
    let text: String
    let scale: CGFloat
    let density: CGFloat
    let visible: Bool
    func makeUIView(context: Context) -> HoneyFeedbackView { HoneyFeedbackView() }
    func updateUIView(_ view: HoneyFeedbackView, context: Context) {
        view.configure(text: text, scale: scale, density: density, visible: visible)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: HoneyFeedbackView, context: Context) -> CGSize? {
        uiView.intrinsicContentSize
    }
}

private final class HoneyFeedbackView: UIView {
    private let background = UIImageView()
    private let label = UILabel()
    private var padding = CGSize.zero
    private var measured = CGSize.zero
    init() {
        super.init(frame: .zero)
        isOpaque = false
        isUserInteractionEnabled = false
        label.textColor = UIColor(Color.brown)
        label.textAlignment = .center
        addSubview(background)
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var intrinsicContentSize: CGSize { measured }
    override func layoutSubviews() {
        super.layoutSubviews()
        background.frame = bounds
        label.frame = bounds.insetBy(dx: padding.width, dy: padding.height)
    }
    func configure(text: String, scale: CGFloat, density: CGFloat, visible: Bool) {
        let font = UIFont.systemFont(ofSize: 28 * scale, weight: .bold)
        label.font = UIFont(descriptor: font.fontDescriptor.withDesign(.rounded) ?? font.fontDescriptor, size: font.pointSize)
        label.text = text.isEmpty ? " " : text
        padding = CGSize(width: 18 * scale, height: 9 * scale)
        let content = label.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        // UILabel truncates when its fractional fitting width is rounded down
        // by the SwiftUI layout. Reserve the complete final display pixel.
        let size = CGSize(width: ceil(content.width * density) / density + 1 / density + padding.width * 2,
                          height: ceil(content.height * density) / density + padding.height * 2)
        if measured != size {
            measured = size
            invalidateIntrinsicContentSize()
            setNeedsLayout()
        }
        if let image = HoneyArtworkCache.shared.image(key: "sign:0.5:false", size: size, density: density,
            content: HoneyQuestionSignArtwork(showsHoney: false)) {
            background.image = UIImage(cgImage: image, scale: density, orientation: .up)
        }
        layer.shadowColor = UIColor(Color.brown).cgColor
        layer.shadowOpacity = 0.2
        layer.shadowRadius = 0
        layer.shadowOffset = CGSize(width: 0, height: 3 * scale)
        layer.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: size),
                                 cornerWidth: size.height / 2, cornerHeight: size.height / 2, transform: nil)
        alpha = visible && !text.isEmpty ? 1 : 0
        isAccessibilityElement = visible && !text.isEmpty
        accessibilityLabel = text
    }
}
#endif

private struct HoneyHUD: View, Equatable {
    let scale: CGFloat
    let width: CGFloat
    let prompt: String
    let score: Int
    let questionNumber: Int
    let totalQuestions: Int
    let canPause: Bool
    let showsFeedback: Bool
    let missedChallenge: String
    let onPause: () -> Void
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var buttonSide: CGFloat { 120 * scale }
    private var scorePotScale: CGFloat { 104 * scale / 154 }
    private var progressWidth: CGFloat { 174 * scale }
    private var scorePanelWidth: CGFloat { 104 * scale + 12 * scale + progressWidth + 56 * scale }
    private var questionProgress: CGFloat {
        min(1, max(0, CGFloat(questionNumber) / CGFloat(max(1, totalQuestions))))
    }
    private var questionPanelWidth: CGFloat {
        min(760 * scale, width * 0.50, max(0, width - 2 * (scorePanelWidth + 20 * scale)))
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.scale == rhs.scale && lhs.width == rhs.width && lhs.prompt == rhs.prompt && lhs.score == rhs.score && lhs.canPause == rhs.canPause
            && lhs.questionNumber == rhs.questionNumber && lhs.totalQuestions == rhs.totalQuestions
            && lhs.showsFeedback == rhs.showsFeedback
            && lhs.missedChallenge == rhs.missedChallenge
    }

    var body: some View {
        ZStack(alignment: .top) {
            HStack(alignment: .top) {
                Button(action: onPause) {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 44 * scale, weight: .black))
                        .frame(width: buttonSide, height: buttonSide)
                        .foregroundStyle(Color(red: 0.25, green: 0.10, blue: 0.03))
                        .background(HoneyQuestionSign(showsHoney: false).equatable())
                        .shadow(color: .brown.opacity(0.35), radius: 0, y: 6 * scale)
                }
                .buttonStyle(.plain)
                .disabled(!canPause)
                .accessibilityLabel(L(key: "honey.pause"))
                Spacer()
                scorePanel
            }
            VStack(spacing: 9 * scale) {
                Text(prompt)
                    .font(.system(size: 68 * scale, weight: .black, design: .rounded))
                    .minimumScaleFactor(0.45).lineLimit(1)
                    .foregroundStyle(Color(red: 0.25, green: 0.10, blue: 0.03))
                    .padding(.horizontal, 38 * scale)
                    .frame(width: questionPanelWidth, height: buttonSide)
                    .background(HoneyQuestionSign().equatable())
                    .shadow(color: .brown.opacity(0.25), radius: 0, y: 6 * scale)
                #if canImport(UIKit)
                HoneyNativeFeedbackSign(text: missedChallenge, scale: scale, density: displayScale, visible: showsFeedback)
                #else
                Text(missedChallenge.isEmpty ? " " : missedChallenge)
                        .font(.system(size: 28 * scale, weight: .bold, design: .rounded))
                        .foregroundStyle(.brown)
                        .padding(.horizontal, 18 * scale).padding(.vertical, 9 * scale)
                        .background(HoneyQuestionSign(showsHoney: false).equatable())
                        .shadow(color: .brown.opacity(0.2), radius: 0, y: 3 * scale)
                        .opacity(showsFeedback && !missedChallenge.isEmpty ? 1 : 0)
                        .accessibilityHidden(!showsFeedback || missedChallenge.isEmpty)
                #endif
            }
        }
        .task(id: score) { @MainActor in
            // Prepare the next score before the flying pot reaches the HUD.
            // Changing the number then swaps an image, not a vector Canvas.
            for value in score...(score + 2) {
                guard !Task.isCancelled else { return }
                _ = HoneyArtworkCache.shared.image(key: "score-pot:\(value)", size: CGSize(width: 308, height: 332),
                    density: 2, content: HoneyPotIllustration(text: "\(value)", showsShadow: false))
                await Task.yield()
            }
        }
    }

    private var scorePanel: some View {
        HStack(spacing: 12 * scale) {
            HoneyBitmapSymbol(key: "score-pot:\(score)", size: CGSize(width: 308, height: 332),
                content: HoneyPotIllustration(text: "\(score)", showsShadow: false)).equatable()
                .scaleEffect(scorePotScale / 2)
                .frame(width: 154 * scorePotScale, height: 166 * scorePotScale)
                .anchorPreference(key: HoneyScoreAnchor.self, value: .bounds) { HoneyHUDAnchors(score: $0) }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(Currency.name) \(score)")
                .accessibilityIdentifier("honey-score")

            progressIndicator
        }
        .padding(.horizontal, 28 * scale)
        .frame(width: scorePanelWidth, height: buttonSide)
        .background(HoneyQuestionSign(showsHoney: false).equatable())
        .environment(\.layoutDirection, .leftToRight)
    }

    private var progressIndicator: some View {
        VStack(spacing: 7 * scale) {
            Text(verbatim: "\(questionNumber) / \(totalQuestions)")
                .font(.system(size: 46 * scale, weight: .black, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .foregroundStyle(Color(red: 0.25, green: 0.10, blue: 0.03))

            Capsule()
                .fill(LinearGradient(colors: [
                    Color(red: 0.55, green: 0.32, blue: 0.10).opacity(0.50),
                    Color(red: 0.74, green: 0.53, blue: 0.22).opacity(0.35)
                ], startPoint: .top, endPoint: .bottom))
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(LinearGradient(colors: [
                            Color(red: 1, green: 0.94, blue: 0.36),
                            Color(red: 1, green: 0.72, blue: 0.015),
                            Color(red: 0.95, green: 0.48, blue: 0.01)
                        ], startPoint: .top, endPoint: .bottom))
                        .overlay {
                            Capsule().strokeBorder(.white.opacity(0.55), lineWidth: 1 * scale)
                        }
                        .frame(width: progressWidth * questionProgress)
                }
                .overlay {
                    Capsule().strokeBorder(Color.brown.opacity(0.30), lineWidth: 1.5 * scale)
                }
                .frame(height: 18 * scale)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: questionProgress)
        }
        .frame(width: progressWidth, height: 82 * scale)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("honey.progress \(questionNumber) \(totalQuestions)"))
        .accessibilityIdentifier("honey-progress")
    }
}

private struct HoneyAnswerAccessibility: View, Equatable {
    let options: [AnswerOption]
    let enabled: Bool
    let onSelect: (Int) -> Void
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.options == rhs.options && lhs.enabled == rhs.enabled
    }
    var body: some View {
        // Keep the accessibility tree off the animated Canvas. Redrawing a
        // frame must not continually rebuild the VoiceOver controls.
        Color.clear.accessibilityRepresentation {
            HStack {
                ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                    Button("\(L(key: "honey.answer")) \(option.text)") { onSelect(index) }
                        .disabled(!enabled)
                        .accessibilityIdentifier("honey-answer-\(index)")
                }
            }
        }
    }
}

/// Warm wood, amber glaze and softly shaded silhouettes match the existing
/// pots, banks and forest. Every prop has a grounded contact shadow.
/// Honey folds, rather than a rotating icon. The projection is supplied by
/// the road; the small standalone preview uses this exact same artwork.
private enum HoneyWhirlpoolArtwork {
    static func draw(in c: inout GraphicsContext, phase: Double, reduceMotion: Bool = false,
                     detailed: Bool = true, project: (Double, Double, Double) -> CGPoint) {
        let time = reduceMotion ? 0 : phase
        let cream = Color(red: 1, green: 0.98, blue: 0.78)
        let gold = Color(red: 1, green: 0.77, blue: 0.07)
        let amber = Color(red: 0.91, green: 0.40, blue: 0.012)
        let deepHoney = Color(red: 0.63, green: 0.26, blue: 0.015)
        let steps = detailed ? 56 : 28
        func surface(_ radius: Double, _ angle: Double, _ lift: Double = 0) -> CGPoint {
            let organic = 1 + 0.016 * sin(angle * 3 + time * 0.47) * radius
                + 0.008 * cos(angle * 5 - time * 0.31) * radius
            return project(cos(angle) * radius * organic * HoneyWhirlpoolFlow.radiusX,
                           sin(angle) * radius * organic * HoneyWhirlpoolFlow.radiusZ,
                           HoneyWhirlpoolFlow.depression(radius: radius) - lift)
        }
        func contour(_ radius: Double) -> Path {
            HoneyFluidContour.closed((0..<steps).map {
                surface(radius, Double($0) / Double(steps) * .pi * 2)
            })
        }
        let light = surface(0.85, -.pi * 0.72)
        let shade = surface(0.85, .pi * 0.22)

        // Many low-opacity contours soften into the existing gold instead of
        // hiding the road beneath an opaque, sharply bounded brown ellipse.
        let rings = detailed ? 32 : 18
        for ring in stride(from: rings, through: 1, by: -1) {
            let radius = Double(ring) / Double(rings)
            c.fill(contour(radius), with: .linearGradient(Gradient(colors: [
                gold.opacity(0.008), amber.opacity(0.022), deepHoney.opacity(0.023)
            ]), startPoint: light, endPoint: shade))
        }

        // Two unequal folds leave broad quiet honey between them. Both their
        // width and height taper into the surface, including at the centre.
        for fold in 0..<2 {
            var shadowOuter: [CGPoint] = [], shadowInner: [CGPoint] = []
            var crestOuter: [CGPoint] = [], crestInner: [CGPoint] = []
            var glossOuter: [CGPoint] = [], glossInner: [CGPoint] = []
            let count = detailed ? 76 : 40
            for sample in 0...count {
                let u = Double(sample) / Double(count)
                let radius = (fold == 0 ? 0.98 : 0.88) - u * (fold == 0 ? 0.88 : 0.72)
                let angle = time * 2.05 + Double(fold) * 2.72 - u * (fold == 0 ? 7.2 : 5.4)
                    + 0.08 * sin(u * 8 + time * 0.8)
                let taper = pow(sin(u * .pi), 1.3)
                let width = (fold == 0 ? 0.080 : 0.060) * taper
                let lift = 7 * taper * radius
                shadowOuter.append(surface(radius + width * 1.4, angle, -2 * taper))
                shadowInner.append(surface(radius - width * 0.45, angle, -3 * taper))
                crestOuter.append(surface(radius + width * 0.20, angle, lift))
                crestInner.append(surface(radius - width, angle, 0))
                glossOuter.append(surface(radius + width * 0.24, angle, lift + taper))
                glossInner.append(surface(radius - width * 0.10, angle, lift))
            }
            c.fill(HoneyFluidContour.closed(shadowOuter + shadowInner.reversed()),
                with: .linearGradient(Gradient(colors: [amber.opacity(0.20), amber.opacity(0.58), deepHoney.opacity(0.40)]),
                    startPoint: light, endPoint: shade))
            c.fill(HoneyFluidContour.closed(crestOuter + crestInner.reversed()),
                with: .linearGradient(Gradient(colors: [cream.opacity(0.88), gold.opacity(0.60), gold.opacity(0.16)]),
                    startPoint: light, endPoint: shade))
            c.fill(HoneyFluidContour.closed(glossOuter + glossInner.reversed()),
                with: .linearGradient(Gradient(colors: [cream, cream.opacity(0.65), gold.opacity(0.10)]),
                    startPoint: light, endPoint: shade))
        }

        // A honey-coloured dimple has depth without turning into a black hole.
        c.fill(contour(0.14), with: .linearGradient(Gradient(colors: [
            deepHoney.opacity(0.46), amber.opacity(0.12), gold.opacity(0)
        ]), startPoint: surface(0.14, -.pi / 2), endPoint: surface(0.14, .pi / 2)))

        // Short reflections travel inward at different radii. Their ends fade
        // before restarting, so the animation has no visible pop or starburst.
        for index in 0..<(detailed ? 5 : 2) {
            let age = (time * 0.23 + Double(index) * 0.213).truncatingRemainder(dividingBy: 1)
            let radius = 0.93 - age * 0.74
            let angle = Double(index) * 2.39 + time * 2.05 - age * 3.7
            let strength = pow(sin(age * .pi), 2)
            var outside: [CGPoint] = [], inside: [CGPoint] = []
            for sample in 0...12 {
                let u = Double(sample) / 12
                let theta = angle + u * 0.34
                let r = radius - u * 0.024
                let width = 0.009 * sin(u * .pi)
                outside.append(surface(r + width, theta, 1))
                inside.append(surface(r - width, theta, 1))
            }
            c.fill(HoneyFluidContour.closed(outside + inside.reversed()), with: .color(cream.opacity(0.85 * strength)))
        }
    }
}

private enum HoneyRaceArtwork {
    private static let cocoa = Color(red: 0.29, green: 0.12, blue: 0.025)
    private static let bark = Color(red: 0.53, green: 0.27, blue: 0.07)
    private static let wood = Color(red: 0.78, green: 0.44, blue: 0.15)
    private static let cream = Color(red: 1, green: 0.96, blue: 0.76)
    private static let gold = Color(red: 1, green: 0.76, blue: 0.09)
    private static let amber = Color(red: 0.95, green: 0.49, blue: 0.015)

    static func draw(_ kind: HoneyTrackItemKind, in c: inout GraphicsContext, phase: Double = 0) {
        switch kind {
        case .boost: boost(&c)
        case .whirlpool: whirlpool(&c, phase: phase)
        case .ramp: ramp(&c)
        case .hive: hive(&c)
        case .log: log(&c)

        }
    }

    private static func fill(_ c: inout GraphicsContext, _ path: Path, colors: [Color], from: CGPoint, to: CGPoint) {
        c.fill(path, with: .linearGradient(Gradient(colors: colors), startPoint: from, endPoint: to))
    }
    private static func oval(_ c: inout GraphicsContext, _ rect: CGRect, colors: [Color]) {
        HoneyForestArtwork.oval(&c, rect, colors)
    }
    private static func shadow(_ c: inout GraphicsContext, width: Double, height: Double = 30) {
        c.fill(Path(ellipseIn: CGRect(x: -width * 0.52, y: -height * 0.15, width: width * 1.04, height: height)),
            with: .radialGradient(Gradient(colors: [cocoa.opacity(0.32), cocoa.opacity(0)]),
                center: CGPoint(x: 0, y: height * 0.32), startRadius: 8, endRadius: width * 0.53))
    }
    private static func line(_ c: inout GraphicsContext, _ points: [CGPoint], color: Color, width: Double) {
        var path = Path(); path.addLines(points)
        c.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
    }
    private static func boost(_ c: inout GraphicsContext) {
        shadow(&c, width: 85, height: 13)
        var bolt = Path()
        bolt.move(to: CGPoint(x: 22, y: -177))
        for p in [CGPoint(x: -48, y: -91), CGPoint(x: -3, y: -94), CGPoint(x: -28, y: -30),
                  CGPoint(x: 57, y: -119), CGPoint(x: 13, y: -116)] { bolt.addLine(to: p) }
        bolt.closeSubpath()
        fill(&c, bolt.offsetBy(dx: 6, dy: 5), colors: [bark, cocoa], from: CGPoint(x: 0, y: -175), to: .zero)
        fill(&c, bolt, colors: [cream, gold, amber], from: CGPoint(x: -28, y: -161), to: CGPoint(x: 45, y: -28))
        c.stroke(bolt, with: .color(Color(red: 0.67, green: 0.33, blue: 0.025)),
            style: StrokeStyle(lineWidth: 3.5, lineJoin: .round))
        line(&c, [CGPoint(x: 13, y: -159), CGPoint(x: -34, y: -99), CGPoint(x: -9, y: -100)], color: cream.opacity(0.9), width: 3)
        for (x, y) in [(-77.0, -107.0), (77, -87), (58, -162)] {
            oval(&c, CGRect(x: x, y: y, width: 8, height: 8), colors: [cream, gold])
        }
    }

    private static func whirlpool(_ context: inout GraphicsContext, phase: Double) {
        HoneyWhirlpoolArtwork.draw(in: &context, phase: phase) { x, z, drop in
            CGPoint(x: x * 0.94, y: z * 0.72 + drop * 0.84 - 3)
        }
    }

    private static func ramp(_ c: inout GraphicsContext) {
        shadow(&c, width: 265, height: 24)
        // The near edge is almost submerged; the far lip rises into a launch.
        for side in [-1.0, 1.0] {
            var edge = Path()
            edge.addLines([CGPoint(x: side * 128, y: 5), CGPoint(x: side * 102, y: -135),
                CGPoint(x: side * 102, y: -67), CGPoint(x: side * 128, y: 9)])
            edge.closeSubpath()
            fill(&c, edge, colors: [wood, bark, cocoa],
                from: CGPoint(x: 0, y: -125), to: CGPoint(x: 0, y: 8))
        }
        var top = Path()
        top.addLines([CGPoint(x: -102, y: -135), CGPoint(x: 102, y: -135),
            CGPoint(x: 128, y: 5), CGPoint(x: -128, y: 5)])
        top.closeSubpath()
        fill(&c, top, colors: [Color(red: 0.91, green: 0.65, blue: 0.31), wood, bark],
            from: CGPoint(x: -94, y: -130), to: CGPoint(x: 114, y: 9))
        c.stroke(top, with: .color(cocoa.opacity(0.65)), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
        for i in 0..<6 {
            let y = -120.0 + Double(i) * 23, half = 105 + Double(i) * 4
            line(&c, [CGPoint(x: -half, y: y), CGPoint(x: half, y: y)], color: cocoa.opacity(0.32), width: 2)
            line(&c, [CGPoint(x: -half + 2, y: y + 2), CGPoint(x: half - 2, y: y + 2)], color: cream.opacity(0.22), width: 1.2)
        }
        let red = Color(red: 0.88, green: 0.15, blue: 0.045)
        for (index, y) in [-99.0, -62, -23].enumerated() {
            let half = 38.0 + Double(index) * 5
            var arrow = Path()
            arrow.addLines([CGPoint(x: -half, y: y + 16), CGPoint(x: 0, y: y - 7),
                CGPoint(x: half, y: y + 16), CGPoint(x: half, y: y + 29),
                CGPoint(x: 0, y: y + 7), CGPoint(x: -half, y: y + 29)])
            arrow.closeSubpath()
            fill(&c, arrow, colors: [Color(red: 1, green: 0.35, blue: 0.08), red, Color(red: 0.64, green: 0.08, blue: 0.025)],
                from: CGPoint(x: 0, y: y - 7), to: CGPoint(x: 0, y: y + 29))
            c.stroke(arrow, with: .color(cocoa.opacity(0.3)), lineWidth: 1.2)
        }
        for side in [-1.0, 1.0] {
            line(&c, [CGPoint(x: side * 101, y: -133), CGPoint(x: side * 126, y: 3)], color: cream.opacity(0.55), width: 3)
            oval(&c, CGRect(x: side * 92 - 3, y: -125, width: 6, height: 6), colors: [cream, wood, cocoa])
        }
        let honey = Path(ellipseIn: CGRect(x: -139, y: 0, width: 278, height: 15))
        fill(&c, honey, colors: [cream.opacity(0.75), gold.opacity(0.95), gold.opacity(0)],
            from: CGPoint(x: 0, y: 0), to: CGPoint(x: 0, y: 16))
    }

    private static func hive(_ c: inout GraphicsContext) {
        shadow(&c, width: 255, height: 40)
        var dome = Path()
        dome.move(to: CGPoint(x: -111, y: -14))
        dome.addCurve(to: CGPoint(x: -38, y: -235), control1: CGPoint(x: -136, y: -73), control2: CGPoint(x: -78, y: -230))
        dome.addQuadCurve(to: CGPoint(x: 38, y: -235), control: CGPoint(x: 0, y: -272))
        dome.addCurve(to: CGPoint(x: 111, y: -14), control1: CGPoint(x: 78, y: -230), control2: CGPoint(x: 136, y: -73))
        dome.addQuadCurve(to: CGPoint(x: -111, y: -14), control: CGPoint(x: 0, y: 30))
        dome.closeSubpath()
        fill(&c, dome, colors: [cream, gold, Color(red: 0.83, green: 0.44, blue: 0.08), bark],
            from: CGPoint(x: -88, y: -205), to: CGPoint(x: 118, y: -8))
        var straw = c; straw.clip(to: dome)
        for i in 0..<6 {
            let y = -28.0 - Double(i) * 37
            var seam = Path()
            seam.move(to: CGPoint(x: -132, y: y - 15))
            seam.addQuadCurve(to: CGPoint(x: 132, y: y - 15), control: CGPoint(x: 0, y: y + 22))
            straw.stroke(seam, with: .color(bark.opacity(0.65)), style: StrokeStyle(lineWidth: 5, lineCap: .round))
            straw.stroke(seam.offsetBy(dx: 0, dy: -4), with: .color(cream.opacity(0.55)), lineWidth: 2.5)
            for j in 0..<13 {
                let x = -109.0 + Double(j) * 18
                line(&straw, [CGPoint(x: x, y: y - 10), CGPoint(x: x + 4, y: y - 17)], color: bark.opacity(0.16), width: 1.5)
            }
        }
        c.stroke(dome, with: .color(bark.opacity(0.55)), lineWidth: 2.5)
        oval(&c, CGRect(x: -31, y: -88, width: 62, height: 66), colors: [amber, cream, bark])
        oval(&c, CGRect(x: -24, y: -85, width: 48, height: 58), colors: [cocoa, Color(red: 0.41, green: 0.20, blue: 0.045)])
        oval(&c, CGRect(x: -31, y: -32, width: 63, height: 12), colors: [gold, wood, bark])
        HoneyForestArtwork.leaf(&c, at: CGPoint(x: -110, y: -4), length: 30, angle: -0.8, light: true)
        HoneyForestArtwork.leaf(&c, at: CGPoint(x: -94, y: -2), length: 24, angle: -0.25, light: false)
        bee(&c, at: CGPoint(x: -83, y: -239), angle: -0.22)
        bee(&c, at: CGPoint(x: 79, y: -186), angle: 0.2)
    }

    private static func bee(_ c: inout GraphicsContext, at point: CGPoint, angle: Double) {
        var bee = c; bee.translateBy(x: point.x, y: point.y); bee.rotate(by: .radians(angle))
        oval(&bee, CGRect(x: -12, y: -22, width: 15, height: 23), colors: [.white.opacity(0.9), cream.opacity(0.5)])
        oval(&bee, CGRect(x: 0, y: -21, width: 14, height: 21), colors: [.white.opacity(0.9), cream.opacity(0.5)])
        oval(&bee, CGRect(x: -20, y: -6, width: 39, height: 22), colors: [cream, gold, amber])
        var stripes = bee; stripes.clip(to: Path(ellipseIn: CGRect(x: -20, y: -6, width: 39, height: 22)))
        line(&stripes, [CGPoint(x: -9, y: -7), CGPoint(x: -5, y: 16)], color: cocoa, width: 6)
        line(&stripes, [CGPoint(x: 3, y: -7), CGPoint(x: 7, y: 16)], color: cocoa, width: 5)
        oval(&bee, CGRect(x: 12, y: -1, width: 5, height: 5), colors: [cocoa, cocoa])
    }

    private static func log(_ c: inout GraphicsContext) {
        // A wide honey shadow grounds the trunk, darker in the middle where it sits deepest.
        c.fill(Path(ellipseIn: CGRect(x: -190, y: -8, width: 390, height: 36)),
            with: .radialGradient(Gradient(colors: [
                Color(red: 0.45, green: 0.18, blue: 0.02).opacity(0.55),
                Color(red: 1, green: 0.55, blue: 0.02).opacity(0.18),
                Color(red: 1, green: 0.75, blue: 0.1).opacity(0)
            ]), center: CGPoint(x: 0, y: 8), startRadius: 8, endRadius: 190))
        shadow(&c, width: 300, height: 28)
        // One opaque bark surface wraps around the far end. Painting another
        // ellipse over it made the rear cap look visible through the trunk.
        let back = HoneyLogGeometry.backCenter, front = HoneyLogGeometry.frontCenter
        let top = HoneyLogGeometry.minY, bottom = HoneyLogGeometry.maxY
        let left = back - HoneyLogGeometry.backRadius, middle = HoneyLogGeometry.centerY
        var body = Path()
        body.move(to: CGPoint(x: back, y: top))
        body.addLines([CGPoint(x: front, y: top), CGPoint(x: front, y: bottom), CGPoint(x: back, y: bottom)])
        body.addCurve(to: CGPoint(x: left, y: middle),
            control1: CGPoint(x: back - 16.57, y: bottom), control2: CGPoint(x: left, y: middle + 34.52))
        body.addCurve(to: CGPoint(x: back, y: top),
            control1: CGPoint(x: left, y: middle - 34.52), control2: CGPoint(x: back - 16.57, y: top))
        body.closeSubpath()
        fill(&c, body, colors: [
            Color(red: 0.93, green: 0.62, blue: 0.28), wood, bark, cocoa
        ], from: CGPoint(x: -40, y: -120), to: CGPoint(x: 40, y: 18))
        // A soft upper ridge gives the cylinder a round, lit top.
        var crown = Path()
        crown.move(to: CGPoint(x: -130, y: -96))
        crown.addQuadCurve(to: CGPoint(x: 140, y: -88), control: CGPoint(x: 10, y: -132))
        crown.addQuadCurve(to: CGPoint(x: -130, y: -96), control: CGPoint(x: 0, y: -78))
        var lit = c
        lit.clip(to: body)
        lit.fill(crown, with: .linearGradient(Gradient(colors: [
            Color(red: 1, green: 0.9, blue: 0.55).opacity(0.85),
            Color(red: 0.95, green: 0.6, blue: 0.18).opacity(0.15)
        ]), startPoint: CGPoint(x: 0, y: -130), endPoint: CGPoint(x: 0, y: -70)))
        var volume = c
        volume.clip(to: body)
        volume.fill(Path(CGRect(x: -200, y: -70, width: 400, height: 90)), with: .linearGradient(
            Gradient(colors: [cocoa.opacity(0), cocoa.opacity(0.55)]),
            startPoint: CGPoint(x: 0, y: -70), endPoint: CGPoint(x: 0, y: 16)))
        var gloss = Path()
        gloss.move(to: CGPoint(x: -120, y: -108))
        gloss.addQuadCurve(to: CGPoint(x: 130, y: -96), control: CGPoint(x: 10, y: -124))
        volume.stroke(gloss, with: .color(Color(red: 1, green: 0.86, blue: 0.45).opacity(0.55)),
            style: StrokeStyle(lineWidth: 7, lineCap: .round))
        var honeyLine = Path()
        honeyLine.move(to: CGPoint(x: -150, y: -58))
        honeyLine.addQuadCurve(to: CGPoint(x: 155, y: -48), control: CGPoint(x: 0, y: -36))
        volume.stroke(honeyLine, with: .color(Color(red: 1, green: 0.72, blue: 0.08).opacity(0.8)),
            style: StrokeStyle(lineWidth: 8, lineCap: .round))
        volume.stroke(honeyLine, with: .color(Color(red: 1, green: 0.94, blue: 0.55).opacity(0.7)),
            style: StrokeStyle(lineWidth: 3, lineCap: .round))
        var grain = c; grain.clip(to: body)
        for i in 0..<6 {
            let y = -102.0 + Double(i) * 20
            var line = Path(); line.move(to: CGPoint(x: -137, y: y))
            line.addCurve(to: CGPoint(x: 145, y: y + 6), control1: CGPoint(x: -41, y: y + 13), control2: CGPoint(x: 57, y: y - 14))
            grain.stroke(line, with: .color(cocoa.opacity(i.isMultiple(of: 2) ? 0.38 : 0.55)), lineWidth: i.isMultiple(of: 2) ? 3 : 5)
            grain.stroke(line.offsetBy(dx: 0, dy: -3), with: .color(cream.opacity(0.15)), lineWidth: 1.4)
        }
        oval(&grain, CGRect(x: -71, y: -85, width: 49, height: 21), colors: [wood, cocoa.opacity(0.7), bark])
        oval(&grain, CGRect(x: -61, y: -80, width: 25, height: 10), colors: [cocoa, bark])
        let end = CGRect(x: front - HoneyLogGeometry.frontRadius, y: top,
            width: HoneyLogGeometry.frontRadius * 2, height: HoneyLogGeometry.halfHeight * 2)
        oval(&c, end, colors: [cream, Color(red: 0.89, green: 0.65, blue: 0.30), wood])
        c.stroke(Path(ellipseIn: end), with: .color(cocoa.opacity(0.65)), lineWidth: 5)
        for inset in [12.0, 25, 38] {
            let ring = end.insetBy(dx: inset * 0.45, dy: inset * 0.75)
            c.stroke(Path(ellipseIn: ring), with: .color(bark.opacity(0.65)), lineWidth: 2)
        }
        line(&c, [CGPoint(x: 150, y: -110), CGPoint(x: 135, y: -76), CGPoint(x: 143, y: -56)], color: bark.opacity(0.65), width: 2)
        line(&c, [CGPoint(x: 110, y: -18), CGPoint(x: 133, y: -40)], color: bark.opacity(0.5), width: 2)
        HoneyForestArtwork.leaf(&c, at: CGPoint(x: -130, y: -112), length: 33, angle: -0.55, light: true)
        HoneyForestArtwork.leaf(&c, at: CGPoint(x: -109, y: -108), length: 28, angle: 0.35, light: false)
    }


}

private struct HoneyRaceItemSymbol: View, Equatable {
    let kind: HoneyTrackItemKind
    var body: some View {
        Canvas { context, _ in
            var c = context
            c.translateBy(x: 210, y: 350)
            HoneyRaceArtwork.draw(kind, in: &c)
        }
        .frame(width: 420, height: 380)
    }
}

private enum HoneyForestArtwork {
    static func oval(_ c: inout GraphicsContext, _ rect: CGRect, _ colors: [Color]) {
        c.fill(Path(ellipseIn: rect), with: .linearGradient(Gradient(colors: colors),
            startPoint: rect.origin, endPoint: CGPoint(x: rect.maxX, y: rect.maxY)))
    }
    static func leaf(_ c: inout GraphicsContext, at p: CGPoint, length: Double, angle: Double, light: Bool) {
        var context = c
        context.translateBy(x: p.x, y: p.y); context.rotate(by: .radians(angle))
        var shape = Path(); shape.move(to: .zero)
        shape.addQuadCurve(to: CGPoint(x: 0, y: -length), control: CGPoint(x: -length * 0.52, y: -length * 0.68))
        shape.addQuadCurve(to: .zero, control: CGPoint(x: length * 0.48, y: -length * 0.35))
        context.fill(shape, with: .linearGradient(Gradient(colors: light ? [
            Color(red: 0.68, green: 0.80, blue: 0.21), Color(red: 0.28, green: 0.56, blue: 0.12)] : [
            Color(red: 0.37, green: 0.66, blue: 0.18), Color(red: 0.10, green: 0.37, blue: 0.15)]),
            startPoint: CGPoint(x: -5, y: -length), endPoint: .zero))
        var vein = Path(); vein.move(to: .zero); vein.addLine(to: CGPoint(x: 0, y: -length * 0.8))
        context.stroke(vein, with: .color(Color(red: 0.79, green: 0.85, blue: 0.40).opacity(0.35)), lineWidth: max(0.7, length * 0.04))
    }
    static func flower(_ c: inout GraphicsContext, at p: CGPoint, radius: Double) {
        oval(&c, CGRect(x: p.x - radius, y: p.y - radius * 0.5, width: radius * 2.2, height: radius * 1.6),
             [Color(red: 0.07, green: 0.29, blue: 0.10).opacity(0.45), .clear])
        for i in 0..<6 {
            let angle = Double(i) / 6 * .pi * 2
            var petal = c
            petal.translateBy(x: p.x + cos(angle) * radius * 0.50, y: p.y + sin(angle) * radius * 0.50)
            petal.rotate(by: .radians(angle))
            oval(&petal, CGRect(x: -radius * 0.24, y: -radius * 0.28, width: radius * 0.82, height: radius * 0.56),
                [Color(red: 1, green: 0.99, blue: 0.91), Color(red: 0.88, green: 0.90, blue: 0.69)])
        }
        oval(&c, CGRect(x: p.x - radius * 0.25, y: p.y - radius * 0.25, width: radius * 0.5, height: radius * 0.5),
            [Color(red: 1, green: 0.84, blue: 0.14), Color(red: 0.91, green: 0.49, blue: 0.02)])
    }
    static func stone(_ c: inout GraphicsContext, _ rect: CGRect, variant: Int) {
        var rock = Path()
        rock.move(to: CGPoint(x: rect.minX + rect.width * 0.13, y: rect.maxY - rect.height * 0.06))
        rock.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.35),
            control: CGPoint(x: rect.minX - rect.width * 0.04, y: rect.maxY - rect.height * 0.25))
        rock.addQuadCurve(to: CGPoint(x: rect.minX + rect.width * 0.20, y: rect.minY + rect.height * 0.04),
            control: CGPoint(x: rect.minX + rect.width * 0.02, y: rect.minY))
        rock.addLine(to: CGPoint(x: rect.minX + rect.width * 0.75, y: rect.minY))
        rock.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.22),
            control: CGPoint(x: rect.maxX - rect.width * 0.04, y: rect.minY - rect.height * 0.025))
        rock.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.02, y: rect.maxY - rect.height * 0.17))
        rock.addQuadCurve(to: CGPoint(x: rect.minX + rect.width * 0.76, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY))
        rock.closeSubpath()
        let shift = Double(variant % 3) * 0.035
        c.fill(rock, with: .linearGradient(Gradient(colors: [
            Color(red: 0.80 + shift, green: 0.73 + shift, blue: 0.53 + shift),
            Color(red: 0.53 + shift, green: 0.44 + shift, blue: 0.30),
            Color(red: 0.36, green: 0.31, blue: 0.22)]),
            startPoint: rect.origin, endPoint: CGPoint(x: rect.maxX, y: rect.maxY)))
        var bevel = Path()
        bevel.move(to: CGPoint(x: rect.minX + rect.width * 0.04, y: rect.minY + rect.height * 0.38))
        bevel.addQuadCurve(to: CGPoint(x: rect.minX + rect.width * 0.22, y: rect.minY + rect.height * 0.07),
            control: CGPoint(x: rect.minX + rect.width * 0.06, y: rect.minY + rect.height * 0.06))
        bevel.addLine(to: CGPoint(x: rect.minX + rect.width * 0.70, y: rect.minY + rect.height * 0.05))
        c.stroke(bevel, with: .color(Color(red: 0.98, green: 0.88, blue: 0.65).opacity(0.6)),
            style: StrokeStyle(lineWidth: max(1, rect.height * 0.045), lineCap: .round))
        var crack = Path()
        crack.move(to: CGPoint(x: rect.minX + rect.width * 0.72, y: rect.minY + rect.height * 0.25))
        crack.addLine(to: CGPoint(x: rect.minX + rect.width * 0.64, y: rect.minY + rect.height * 0.43))
        crack.addLine(to: CGPoint(x: rect.minX + rect.width * 0.71, y: rect.minY + rect.height * 0.65))
        c.stroke(crack, with: .color(Color(red: 0.25, green: 0.24, blue: 0.16).opacity(0.28)), lineWidth: max(0.8, rect.width * 0.012))
    }
}

private struct HoneyTreeSymbol: View, Equatable {
    let variant: Int
    var body: some View {
        Canvas { c, _ in
            var context = c
            let lean = Double(variant - 1) * 5
            HoneyForestArtwork.oval(&context, CGRect(x: 27, y: 278, width: 180, height: 20),
                [Color(red: 0.04, green: 0.19, blue: 0.08).opacity(0.65), .clear])
            var trunk = Path()
            trunk.move(to: CGPoint(x: 94, y: 290)); trunk.addLine(to: CGPoint(x: 111 + lean, y: 177))
            trunk.addLine(to: CGPoint(x: 81, y: 135)); trunk.addLine(to: CGPoint(x: 93, y: 132))
            trunk.addLine(to: CGPoint(x: 120 + lean, y: 156)); trunk.addLine(to: CGPoint(x: 143, y: 108))
            trunk.addLine(to: CGPoint(x: 154, y: 108)); trunk.addLine(to: CGPoint(x: 130 + lean, y: 179))
            trunk.addQuadCurve(to: CGPoint(x: 147, y: 291), control: CGPoint(x: 127, y: 262)); trunk.closeSubpath()
            context.fill(trunk, with: .linearGradient(Gradient(colors: [
                Color(red: 0.69, green: 0.44, blue: 0.20), Color(red: 0.37, green: 0.22, blue: 0.11),
                Color(red: 0.25, green: 0.17, blue: 0.09)]),
                startPoint: CGPoint(x: 95, y: 200), endPoint: CGPoint(x: 146, y: 235)))
            var bark = Path()
            bark.move(to: CGPoint(x: 107, y: 277)); bark.addQuadCurve(to: CGPoint(x: 120 + lean, y: 178), control: CGPoint(x: 119, y: 233))
            context.stroke(bark, with: .color(Color(red: 0.85, green: 0.60, blue: 0.30).opacity(0.6)), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            let clusters: [(Double, Double, Double)] = [
                (59,119,49), (172,120,48), (111,153,52), (36,93,31), (194,85,31),
                (71,63,48), (143,51,48), (117,27,26), (115,86,57), (55,126,34),
                (164,107,42), (92,118,42), (83,67,35), (143,69,35)]
            for (i, cluster) in clusters.enumerated() {
                let (x, y, r) = cluster
                let rect = CGRect(x: x - r, y: y - r * 0.75, width: r * 2, height: r * 1.65)
                HoneyForestArtwork.oval(&context, rect, [
                    Color(red: 0.43 + Double((i + variant) % 3) * 0.04, green: 0.64 + Double(variant) * 0.025, blue: 0.16),
                    Color(red: 0.16, green: 0.43 + Double(variant) * 0.02, blue: 0.14),
                    Color(red: 0.06, green: 0.29, blue: 0.13)])
                for j in 0..<6 {
                    let angle = Double(j) * 2.4 + Double(i + variant)
                    let radius = r * (0.28 + Double(j % 3) * 0.17)
                    let p = CGPoint(x: x + cos(angle) * radius, y: y + sin(angle) * radius * 0.55)
                    HoneyForestArtwork.leaf(&context, at: p, length: 9 + Double(j % 3) * 3, angle: angle, light: j % 3 == 0)
                }
            }
            for i in 0..<9 {
                let p = CGPoint(x: 81 + Double(i) * 9, y: 290 + Double(i % 2) * 4)
                HoneyForestArtwork.leaf(&context, at: p, length: 22 + Double(i % 3) * 5, angle: Double(i - 4) * 0.24, light: i % 3 == 0)
            }
            HoneyForestArtwork.flower(&context, at: CGPoint(x: 94, y: 282), radius: 7)
            HoneyForestArtwork.flower(&context, at: CGPoint(x: 146, y: 287), radius: 5)
        }
        .frame(width: 230, height: 300)
    }
}

private struct HoneyUnderbrushSymbol: View, Equatable {
    let variant: Int
    var body: some View {
        Canvas { c, _ in
            var context = c
            HoneyForestArtwork.oval(&context, CGRect(x: 4, y: 87, width: 212, height: 24),
                [Color(red: 0.03, green: 0.21, blue: 0.08).opacity(0.65), .clear])
            for i in 0..<7 {
                let rect = CGRect(x: 5 + Double(i) * 27, y: 52 + Double(i % 3) * 11, width: 52, height: 43)
                HoneyForestArtwork.oval(&context, rect, [Color(red: 0.28, green: 0.51, blue: 0.13), Color(red: 0.07, green: 0.30, blue: 0.12)])
            }
            HoneyForestArtwork.stone(&context, CGRect(x: variant == 0 ? 136 : 66, y: 69, width: 51, height: 34), variant: variant)
            for i in 0..<24 {
                let x = 19 + Double((i * 37 + variant * 19) % 181)
                let y = 72 + Double((i * 17) % 31)
                HoneyForestArtwork.leaf(&context, at: CGPoint(x: x, y: y), length: 20 + Double(i % 4) * 5,
                    angle: Double(i % 7 - 3) * 0.30, light: i % 4 == 0)
            }
            for i in 0..<4 {
                let x = 33 + Double(i) * 44 + Double(variant) * 4
                let y = 64 + Double((i + variant) % 3) * 12
                HoneyForestArtwork.flower(&context, at: CGPoint(x: x, y: y), radius: 10 + Double(i % 2) * 2)
            }
        }
        .frame(width: 220, height: 112)
    }
}

private struct HoneyCliffSymbol: View, Equatable {
    let variant: Int
    var body: some View {
        Canvas { c, _ in
            var context = c
            HoneyForestArtwork.oval(&context, CGRect(x: 15, y: 301, width: 330, height: 28),
                [Color(red: 0.02, green: 0.18, blue: 0.09).opacity(0.7), .clear])
            // An irregular stepped outcrop, with visible stone joints and moss.
            let stones: [CGRect] = [
                CGRect(x: 22, y: 241, width: 125, height: 77), CGRect(x: 134, y: 246, width: 135, height: 72),
                CGRect(x: 253, y: 244, width: 79, height: 66), CGRect(x: 35, y: 168, width: 108, height: 83),
                CGRect(x: 135, y: 164, width: 113, height: 88), CGRect(x: 236, y: 173, width: 78, height: 82),
                CGRect(x: 61, y: 91, width: 117, height: 87), CGRect(x: 168, y: 83, width: 115, height: 92),
                CGRect(x: 94, y: 32, width: 91, height: 64), CGRect(x: 174, y: 22, width: 83, height: 69)]
            for (i, rect) in stones.enumerated() { HoneyForestArtwork.stone(&context, rect, variant: i + variant) }
            for i in 0..<26 {
                let x = 38 + Double((i * 43 + variant * 23) % 277)
                let y = i < 12 ? 313.0 : 177 + Double((i * 19) % 110)
                HoneyForestArtwork.leaf(&context, at: CGPoint(x: x, y: y), length: 16 + Double(i % 3) * 8,
                    angle: Double(i % 5 - 2) * 0.42, light: i % 3 == 0)
            }
            if variant == 0 {
                // A broad fall is fed by a honey-covered ledge, rather than
                // isolated tubes with floating circular caps.
                var cascade = Path()
                cascade.move(to: CGPoint(x: 150, y: 46))
                cascade.addCurve(to: CGPoint(x: 155, y: 166), control1: CGPoint(x: 142, y: 82), control2: CGPoint(x: 164, y: 117))
                cascade.addCurve(to: CGPoint(x: 159, y: 293), control1: CGPoint(x: 146, y: 222), control2: CGPoint(x: 174, y: 257))
                cascade.addQuadCurve(to: CGPoint(x: 223, y: 300), control: CGPoint(x: 182, y: 312))
                cascade.addCurve(to: CGPoint(x: 213, y: 169), control1: CGPoint(x: 209, y: 267), control2: CGPoint(x: 224, y: 218))
                cascade.addCurve(to: CGPoint(x: 220, y: 42), control1: CGPoint(x: 201, y: 111), control2: CGPoint(x: 226, y: 75))
                cascade.closeSubpath()
                context.fill(cascade.offsetBy(dx: 6, dy: 4), with: .color(Color(red: 0.35, green: 0.23, blue: 0.08).opacity(0.5)))
                context.fill(cascade, with: .linearGradient(Gradient(colors: [
                    Color(red: 1, green: 0.95, blue: 0.49), Color(red: 1, green: 0.77, blue: 0.05),
                    Color(red: 0.95, green: 0.53, blue: 0.01)]),
                    startPoint: CGPoint(x: 150, y: 150), endPoint: CGPoint(x: 223, y: 185)))
                for i in 0..<4 {
                    let x = 162 + Double(i) * 13
                    var streak = Path(); streak.move(to: CGPoint(x: x, y: 55 + Double(i % 2) * 21))
                    streak.addCurve(to: CGPoint(x: x + 3, y: 291 - Double(i % 3) * 13),
                        control1: CGPoint(x: x - 9, y: 134), control2: CGPoint(x: x + 12, y: 224))
                    context.stroke(streak, with: .color(Color(red: 1, green: 0.98, blue: 0.76).opacity(i % 2 == 0 ? 0.85 : 0.4)),
                        style: StrokeStyle(lineWidth: i == 0 ? 5 : 2.5, lineCap: .round))
                }
                var ledge = Path(); ledge.move(to: CGPoint(x: 100, y: 32))
                ledge.addCurve(to: CGPoint(x: 253, y: 34), control1: CGPoint(x: 125, y: 21), control2: CGPoint(x: 220, y: 25))
                ledge.addQuadCurve(to: CGPoint(x: 245, y: 56), control: CGPoint(x: 266, y: 48))
                ledge.addCurve(to: CGPoint(x: 104, y: 52), control1: CGPoint(x: 209, y: 44), control2: CGPoint(x: 135, y: 66))
                ledge.addQuadCurve(to: CGPoint(x: 100, y: 32), control: CGPoint(x: 85, y: 45)); ledge.closeSubpath()
                context.fill(ledge, with: .linearGradient(Gradient(colors: [.yellow, Color(red: 1, green: 0.66, blue: 0.02)]),
                    startPoint: CGPoint(x: 100, y: 27), endPoint: CGPoint(x: 130, y: 61)))
                var gloss = Path(); gloss.move(to: CGPoint(x: 113, y: 33))
                gloss.addQuadCurve(to: CGPoint(x: 236, y: 35), control: CGPoint(x: 180, y: 26))
                context.stroke(gloss, with: .color(.white.opacity(0.85)), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                HoneyForestArtwork.oval(&context, CGRect(x: 121, y: 291, width: 143, height: 25), [Color(red: 1, green: 0.84, blue: 0.14), Color(red: 0.97, green: 0.57, blue: 0.035)])
                for i in 0..<7 {
                    HoneyForestArtwork.oval(&context, CGRect(x: 136 + Double(i) * 16, y: 295 + Double(i % 2) * 6, width: 18, height: 3), [.white.opacity(0.85), .yellow.opacity(0.1)])
                }
            } else {
                for i in 0..<18 {
                    let p = CGPoint(x: 82 + Double(i * 31 % 196), y: 94 + Double(i * 17 % 155))
                    HoneyForestArtwork.leaf(&context, at: p, length: 24 + Double(i % 3) * 7,
                        angle: Double(i % 5 - 2) * 0.36, light: i % 4 == 0)
                }
            }
            for i in 0..<13 {
                let x = 107 + Double(i) * 11
                HoneyForestArtwork.leaf(&context, at: CGPoint(x: x, y: 30 + Double(i % 3) * 5), length: 23 + Double(i % 3) * 6,
                    angle: Double(i % 5 - 2) * 0.36, light: i % 3 == 0)
            }
            for p in [CGPoint(x: 58, y: 281), CGPoint(x: 279, y: 291), CGPoint(x: 177, y: 20)] {
                HoneyForestArtwork.flower(&context, at: p, radius: 9)
            }
        }
        .frame(width: 360, height: 330)
    }
}

private struct HoneyQuestionSign: View, Equatable {
    var cornerRatio: Double = 0.5
    var showsHoney = true
    @Environment(\.displayScale) private var displayScale
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.cornerRatio == rhs.cornerRatio && lhs.showsHoney == rhs.showsHoney && lhs.displayScale == rhs.displayScale
    }
    var body: some View {
        GeometryReader { proxy in
            HoneyBitmapSymbol(key: "sign:\(cornerRatio):\(showsHoney)", size: proxy.size, density: displayScale,
                content: HoneyQuestionSignArtwork(cornerRatio: cornerRatio, showsHoney: showsHoney)).equatable()
        }
    }
}

private struct HoneyQuestionSignArtwork: View {
    var cornerRatio: Double = 0.5
    var showsHoney = true
    var body: some View {
        Canvas { c, size in
            let rect = CGRect(origin: .zero, size: size)
            let radius = min(size.width, size.height) * cornerRatio
            let border = max(2, size.height * 0.042)
            let outline = Path(roundedRect: rect, cornerRadius: radius)
            c.clip(to: outline)
            c.fill(outline, with: .linearGradient(
                Gradient(colors: [Color(red: 0.62, green: 0.33, blue: 0.11), Color(red: 0.35, green: 0.14, blue: 0.035)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            let inset = rect.insetBy(dx: border, dy: border)
            c.fill(Path(roundedRect: inset, cornerRadius: max(1, radius - border)), with: .linearGradient(
                Gradient(colors: [Color(red: 1, green: 0.95, blue: 0.78), Color(red: 1, green: 0.87, blue: 0.53)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            c.stroke(Path(roundedRect: inset, cornerRadius: max(1, radius - border)), with: .color(.orange.opacity(0.8)), lineWidth: max(1, border * 0.4))
            if showsHoney {
                // A gathered ribbon stops before the capsule's round ends.
                // Broad, irregular folds and short gloss marks give it volume.
                let left = radius * 1.12, right = size.width - left
                let span = right - left
                var rim = Path()
                rim.move(to: CGPoint(x: left, y: border * 0.8))
                rim.addCurve(to: CGPoint(x: right, y: border * 0.8),
                    control1: CGPoint(x: left + span * 0.28, y: border * 0.05),
                    control2: CGPoint(x: left + span * 0.74, y: border * 0.25))
                rim.addQuadCurve(to: CGPoint(x: right - span * 0.045, y: border * 2.6),
                    control: CGPoint(x: right + border, y: border * 3.6))
                let folds: [(Double, Double)] = [(0.89, 2.1), (0.78, 3.3), (0.66, 2.3),
                    (0.53, 3.8), (0.40, 2.8), (0.29, 3.5), (0.17, 2.4), (0.055, 3.0)]
                var previous = 0.955
                for (fraction, height) in folds {
                    rim.addCurve(to: CGPoint(x: left + span * fraction, y: border * height),
                        control1: CGPoint(x: left + span * (previous - 0.025), y: border * (height + 1.0)),
                        control2: CGPoint(x: left + span * (fraction + 0.025), y: border * (height + 0.4)))
                    previous = fraction
                }
                rim.addQuadCurve(to: CGPoint(x: left, y: border * 0.8),
                    control: CGPoint(x: left - border, y: border * 3.5))
                c.fill(rim, with: .linearGradient(Gradient(colors: [
                    Color(red: 1, green: 0.96, blue: 0.47), Color(red: 1, green: 0.69, blue: 0.035),
                    Color(red: 0.95, green: 0.49, blue: 0.01)]),
                    startPoint: .zero, endPoint: CGPoint(x: 0, y: border * 4.5)))
                c.stroke(rim, with: .color(.orange.opacity(0.65)), lineWidth: border * 0.22)
                for (fraction, length, width) in [(0.09, 0.21, 1.6), (0.14, 0.12, 1.2), (0.85, 0.17, 1.45)] {
                    let drip = CGRect(x: left + span * fraction, y: border * 2,
                                      width: border * width, height: size.height * length)
                    c.fill(Path(roundedRect: drip, cornerRadius: drip.width / 2), with: .linearGradient(
                        Gradient(colors: [.yellow, Color(red: 1, green: 0.66, blue: 0.025)]),
                        startPoint: drip.origin, endPoint: CGPoint(x: drip.midX, y: drip.maxY)))
                    let shine = drip.insetBy(dx: drip.width * 0.3, dy: border * 0.6)
                    c.fill(Path(roundedRect: shine, cornerRadius: shine.width / 2), with: .color(.white.opacity(0.65)))
                }
                for (start, end) in [(0.04, 0.25), (0.32, 0.58), (0.69, 0.90)] {
                    var gloss = Path()
                    gloss.move(to: CGPoint(x: left + span * start, y: border * 1.25))
                    gloss.addQuadCurve(to: CGPoint(x: left + span * end, y: border * 1.35),
                        control: CGPoint(x: left + span * (start + end) / 2, y: border * 0.6))
                    c.stroke(gloss, with: .color(.white.opacity(0.85)),
                             style: StrokeStyle(lineWidth: border * 0.4, lineCap: .round))
                }
            }
        }
        .shadow(color: .brown.opacity(0.35), radius: 0, y: 4)
    }
}

#if canImport(UIKit)
import UIKit

/// Deliver exactly one update per 60-Hz display frame, including ProMotion
/// displays. Pausing removes the link rather than leaving a timer firing.
private struct HoneyDisplayClock: UIViewRepresentable {
    let running: Bool
    let onFrame: (TimeInterval) -> Void
    func makeUIView(context: Context) -> ClockView { ClockView() }
    func updateUIView(_ view: ClockView, context: Context) {
        view.onFrame = onFrame
        view.setRunning(running)
    }
    static func dismantleUIView(_ view: ClockView, coordinator: ()) { view.stop() }

    final class ClockView: UIView {
        var onFrame: ((TimeInterval) -> Void)?
        private var link: CADisplayLink?
        private var running = false
        // CADisplayLink retains its target. A weak trampoline avoids a view /
        // display-link cycle if a game leaves the navigation stack.
        private final class Target: NSObject {
            weak var view: ClockView?
            @objc func update(_ link: CADisplayLink) { view?.onFrame?(link.targetTimestamp) }
        }
        func setRunning(_ running: Bool) {
            self.running = running
            if running && window != nil && link == nil {
                let target = Target(); target.view = self
                let link = CADisplayLink(target: target, selector: #selector(Target.update(_:)))
                link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
                link.add(to: .main, forMode: .common)
                self.link = link
            } else if !running { stop() }
        }
        func stop() { link?.invalidate(); link = nil }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { stop() } else { setRunning(running) }
        }
    }
}
private struct HoneyKeyboard: UIViewRepresentable {
    let onKey: (Int, Bool) -> Void
    func makeUIView(context: Context) -> HoneyKeyView { let v = HoneyKeyView(); v.onKey = onKey; return v }
    func updateUIView(_ view: HoneyKeyView, context: Context) { view.onKey = onKey; if view.window != nil && !view.isFirstResponder { view.becomeFirstResponder() } }
    final class HoneyKeyView: UIView {
        var onKey: ((Int, Bool) -> Void)?
        override var canBecomeFirstResponder: Bool { true }
        override func didMoveToWindow() { super.didMoveToWindow(); if window != nil { becomeFirstResponder() } }
        private func handle(_ presses: Set<UIPress>, held: Bool) {
            for press in presses {
                guard let key = press.key else { continue }
                if key.keyCode == .keyboardLeftArrow || key.charactersIgnoringModifiers.lowercased() == "a" { onKey?(-1, held) }
                if key.keyCode == .keyboardRightArrow || key.charactersIgnoringModifiers.lowercased() == "d" { onKey?(1, held) }
            }
        }
        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) { handle(presses, held: true) }
        override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) { handle(presses, held: false) }
        override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) { handle(presses, held: false) }
    }
}
#else
private struct HoneyDisplayClock: View {
    let running: Bool
    let onFrame: (TimeInterval) -> Void
    var body: some View { EmptyView() }
}
private struct HoneyKeyboard: View {
    let onKey: (Int, Bool) -> Void
    var body: some View { EmptyView() }
}
#endif
