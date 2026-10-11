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
            ZStack {
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        guard running else { return }
                        let point = CGPoint(x: value.location.x / proxy.size.width * 1600,
                                            y: value.location.y / proxy.size.height * 900)
                        if let target = HoneySlideRules.steeringTarget(at: point, elapsed: distance, course: simulation.course) {
                            simulation.steer(to: target)
                        }
                    }.onEnded { _ in simulation.release() })
                HoneyAnswerAccessibility(options: simulation.activeCheckpoint?.options ?? [], enabled: running) { index in
                    simulation.targetLateral = Double(index - 1) * 0.66
                }
                .equatable()
                .allowsHitTesting(false)
                VStack {
                    hud(scale: scale, width: proxy.size.width)
                    Spacer()
                }
                .foregroundStyle(.white)
                .padding(.leading, max(proxy.safeAreaInsets.leading, max(12, 22 * scale)))
                .padding(.trailing, max(proxy.safeAreaInsets.trailing, max(12, 22 * scale)))
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
                    target: anchor.score.map { proxy[$0] }, penaltyTarget: anchor.penalty.map { proxy[$0] })
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            .contentShape(Rectangle())
            .onAppear { simulation.configureViewport(proxy.size) }
            .onChange(of: proxy.size) { _, size in simulation.configureViewport(size) }

        }
        .onChange(of: running) { _, _ in lastTick = nil; simulation.release() }
        .onChange(of: model.visibleRounds) { _, _ in synchronizeCheckpoints() }
        .onChange(of: model.acceptsInput) { _, new in if new { synchronizeCheckpoints() } }
        .onAppear { synchronizeCheckpoints() }
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
                 penaltyProgress: simulation.penaltyProgress.map { _ in 0 },
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
        return model.lastMissedChallenge ?? ""
    }

    private func synchronizeCheckpoints() {
        #if DEBUG
        if visualCheckPrepared { return }
        #endif
        simulation.synchronize(rounds: model.visibleRounds, stage: model.stageNumber,
                               acceptingInput: model.acceptsInput)
        #if DEBUG
        // Freeze a real simulation outcome for repeatable animation/layout QA.
        // This path never selects an answer or changes the player's saved score.
        if model.acceptsInput, !visualCheckPrepared, let check = visualCheck, let row = simulation.activeCheckpoint,
           let index = row.options.firstIndex(where: { $0.isCorrect == check.correct }) {
            simulation.steer(to: Double(index - 1) * HoneySlideRules.laneSpacing)
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
        guard running else { return }
        defer { lastTick = now }
        guard let previous = lastTick else { return }
        // Don't discard elapsed time on a slow frame: doing that made the
        // world crawl while the separate session timer continued at full rate.
        simulation.advance(seconds: max(0, now - previous))
        if model.isGameOver, !completionReported, simulation.visualOutcomeSettled {
            completionReported = true
            onCompletion()
        }
        guard model.acceptsInput, let round = model.round,
              let hit = simulation.crossing(roundID: round.id) else { return }
        lastPrompt = round.question.prompt
        if model.select(optionID: hit.option.id) {
            simulation.markSelected(checkpointID: hit.checkpointID, index: hit.index,
                                    correct: hit.option.isCorrect)
            model.reportCatchOutcome(isCorrect: hit.option.isCorrect)
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
            let projection = HoneySlideProjection(elapsed: simulation.elapsed, course: simulation.course)
            drawWorld(&c, projection: projection, billboardYScale: HoneySlideRules.billboardVerticalScale(viewport: size))
            if rider != nil {
                HoneyTubeWater.draw(in: context, size: size, simulation: simulation, foreground: false, reduceMotion: reduceMotion)
                HoneyRiderDrawing.draw(in: context, size: size, simulation: simulation, reduceMotion: reduceMotion)
                HoneyTubeWater.draw(in: context, size: size, simulation: simulation, foreground: true, reduceMotion: reduceMotion)
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
            HoneyBitmapSymbol(key: "pot-base", size: CGSize(width: 308, height: 332), content: HoneyPotSymbol(crown: false)).equatable().tag(6)
            HoneyBitmapSymbol(key: "pot-crown", size: CGSize(width: 308, height: 332), content: HoneyPotSymbol(crown: true)).equatable().tag(7)
            HoneyBitmapSymbol(key: "closed-pot", size: CGSize(width: 308, height: 332), content: HoneyClosedPotSymbol()).equatable().tag("closed-pot")
            ForEach(potTexts, id: \.self) { text in
                HoneyBitmapSymbol(key: "pot:\(text)", size: CGSize(width: 308, height: 332),
                    content: HoneyPotIllustration(text: text)).equatable().tag("pot:\(text)")
            }
            if let rider {
                rider.resizable().scaledToFit().frame(width: 400, height: 400 * 1312 / 1247).tag("rider")
            }
        }
        .accessibilityHidden(true)
    }

    // The course is sampled in world coordinates. Advancing the camera reveals
    // existing bends; it never regenerates a curve from screen-space phases.
    private var potTexts: [String] {
        // Stable symbol identities keep complete numbered pots cached across
        // frame changes and question promotion. Closed future pots share one.
        // Warm two future questions before contact. The remaining closed rows
        // need no numbered texture; keep the working set small and bounded.
        Array(Set(simulation.checkpoints.prefix(4).flatMap { $0.options.map(\.text) })).sorted()
    }

    private func point(_ depth: Double, _ offset: Double, _ projection: HoneySlideProjection) -> CGPoint {
        projection.point(depth: depth, offset: offset)
    }

    private func ridingPoint(_ depth: Double, _ offset: Double) -> CGPoint {
        HoneySlideRules.ridingPoint(depth: depth, lateral: offset, distance: distance, course: simulation.course)
    }

    private func ribbon(_ low: Double, _ high: Double, _ projection: HoneySlideProjection) -> Path {
        var p = Path()
        let samples = HoneySlideRules.trackDepthSamples
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
        c.fill(Path(CGRect(x: 0, y: 0, width: 1600, height: 900)), with: .linearGradient(
            Gradient(colors: [Color(red: 0.22, green: 0.71, blue: 0.95), Color(red: 0.79, green: 0.94, blue: 0.77)]),
            startPoint: .zero, endPoint: CGPoint(x: 0, y: 650)))
        let pan = sin(distance * 0.14) * 24
        for i in 0..<6 {
            let x = Double(i) * 320 - 100 - pan
            ellipse(&c, CGRect(x: x, y: 56 + Double(i % 3) * 28, width: 180, height: 42), [.white.opacity(0.75), .white.opacity(0.18)])
            ellipse(&c, CGRect(x: x + 35, y: 39 + Double(i % 3) * 28, width: 90, height: 54), [.white.opacity(0.85), .white.opacity(0.25)])
        }
        // The distant skyline sits behind a continuous projected forest floor.
        for layer in 0..<3 {
            var ridge = Path(); ridge.move(to: CGPoint(x: -100, y: 900))
            ridge.addLine(to: CGPoint(x: -100, y: 166 + layer * 12))
            for i in 0..<7 {
                let x = Double(i) * 290 - 100 - pan * Double(layer + 1) * 0.4
                ridge.addQuadCurve(to: CGPoint(x: x + 290, y: Double(166 + layer * 12)),
                                   control: CGPoint(x: x + 135, y: Double(75 + layer * 27 + i % 2 * 22)))
            }
            ridge.addLine(to: CGPoint(x: 1800, y: 900)); ridge.closeSubpath()
            c.fill(ridge, with: .color([
                Color(red: 0.49, green: 0.69, blue: 0.61),
                Color(red: 0.34, green: 0.62, blue: 0.41),
                Color(red: 0.20, green: 0.49, blue: 0.27)][layer]))
        }
        drawLandscape(&c, projection: projection)
        drawSlide(&c, projection: projection)
        drawCheckpoints(&c, billboardYScale: billboardYScale)
    }

    private func drawLandscape(_ c: inout GraphicsContext, projection: HoneySlideProjection) {
        // Every root and shadow lies on this same ground plane. The forest
        // extends right to the course horizon, rather than starting at a row
        // of trees floating above a static background hill.
        c.fill(Path(CGRect(x: 0, y: 155, width: 1600, height: 745)), with: .linearGradient(
            Gradient(colors: [Color(red: 0.37, green: 0.63, blue: 0.44),
                              Color(red: 0.20, green: 0.48, blue: 0.16),
                              Color(red: 0.11, green: 0.35, blue: 0.13)]),
            startPoint: CGPoint(x: 0, y: 155), endPoint: CGPoint(x: 0, y: 900)))
        for side in [-1.0, 1.0] {
            c.fill(ribbon(side * 1.03, side * 1.30, projection), with: .color(Color(red: 0.56, green: 0.66, blue: 0.24)))
            c.fill(ribbon(side * 1.30, side * 1.70, projection), with: .color(Color(red: 0.29, green: 0.55, blue: 0.18)))
            c.fill(ribbon(side * 1.70, side * 2.50, projection), with: .color(.green.opacity(0.12)))
        }
        let world = simulation.distance
        let step = HoneySlideRules.scenerySpacing
        let first = Int(floor(world / step)) - 1
        let last = Int(ceil((world + HoneySlideRules.drawDistance) / step))
        // Three staggered bands fill the banks. All positions are fixed world
        // positions; objects only enter at the tiny, fading horizon or offscreen.
        for index in stride(from: last, through: first, by: -1) {
            for band in (0..<3).reversed() {
                for side in [-1.0, 1.0] {
                    let seed = abs(index * 17 + band * 13 + (side > 0 ? 19 : 0))
                    let ahead = Double(index) * step + Double(band) * 39 + (side > 0 ? 61 : 0)
                        + Double(seed % 11) * 6 - 30 - world
                    guard ahead > -80, ahead < HoneySlideRules.drawDistance else { continue }
                    let t = HoneySlideRules.depth(ahead: ahead)
                    let offset = side * (1.43 + Double(band) * 0.85 + Double(seed % 7) * 0.055)
                    let p = point(t, offset, projection)
                    let s = t * (1.13 + Double(seed % 5) * 0.075)
                    // Cull the complete canopy, not just its trunk: a large
                    // tree can enter from the side with its roots offscreen.
                    guard p.x + 125 * s > 0, p.x - 125 * s < 1600 else { continue }
                    var scenery = c
                    scenery.opacity = HoneySlideRules.distantOpacity(ahead: ahead)
                    if band == 1 && seed % 11 == 0 {
                        cliff(&scenery, at: p, scale: s, phase: Double(index))
                    } else if let symbol = c.resolveSymbol(id: seed % 4) {
                        scenery.translateBy(x: p.x, y: p.y)
                        scenery.scaleBy(x: s, y: s)
                        scenery.draw(symbol, at: .zero, anchor: .bottom)
                    }
                }
            }
            // Low plants, rocks and flower patches make a continuous verge,
            // with enough space between the trunks for the rail to read clearly.
            for side in [-1.0, 1.0] {
                let ahead = Double(index) * step + 94 - world
                guard ahead > -80, ahead < HoneySlideRules.drawDistance else { continue }
                let t = HoneySlideRules.depth(ahead: ahead)
                let p = point(t, side * (1.14 + Double(abs(index) % 3) * 0.065), projection)
                let s = t * 1.3
                guard p.x + 110 * s > 0, p.x - 110 * s < 1600,
                      let symbol = c.resolveSymbol(id: 4 + abs(index) % 2) else { continue }
                var verge = c
                verge.opacity = HoneySlideRules.distantOpacity(ahead: ahead)
                verge.translateBy(x: p.x, y: p.y)
                verge.scaleBy(x: s, y: s)
                verge.draw(symbol, at: .zero, anchor: .bottom)
            }
        }
    }

    private func drawSlide(_ c: inout GraphicsContext, projection: HoneySlideProjection) {
        let gold = Color(red: 1.0, green: 0.68, blue: 0.025)
        c.fill(ribbon(-1.05, 1.05, projection), with: .color(Color(red: 0.30, green: 0.16, blue: 0.035)))
        c.fill(ribbon(-1, 1, projection), with: .linearGradient(Gradient(colors: [
            Color(red: 0.86, green: 0.48, blue: 0.02), gold,
            Color(red: 1, green: 0.82, blue: 0.20), gold]),
            startPoint: CGPoint(x: 100, y: 180), endPoint: CGPoint(x: 1420, y: 920)))
        drawChurningHoney(&c, projection: projection)
        c.fill(ribbon(-1, -0.94, projection), with: .color(.brown.opacity(0.19)))
        c.fill(ribbon(0.94, 1, projection), with: .color(.brown.opacity(0.19)))
        let samples = HoneySlideRules.trackDepthSamples
        for side in [-1.0, 1.0] {
            let feet = samples.map { point($0, side, projection) }
            let tops = zip(feet, samples).map { p, depth in
                CGPoint(x: p.x, y: p.y - HoneySlideRules.railHeight * depth)
            }
            var wall = Path()
            // addLines starts a new subpath. Both edges must be submitted
            // together, otherwise each closes across the entire winding course.
            wall.addLines(feet + tops.reversed())
            wall.closeSubpath()
            c.fill(wall, with: .linearGradient(Gradient(colors: [
                Color(red: 0.86, green: 0.56, blue: 0.23), Color(red: 0.43, green: 0.21, blue: 0.07)]),
                startPoint: CGPoint(x: 0, y: 280), endPoint: CGPoint(x: 0, y: 920)))
            // A variable-width continuous cap replaces hundreds of separate
            // overlapping round strokes and their individual draw commands.
            c.fill(railRibbon(tops, depths: samples, width: 24),
                   with: .color(Color(red: 1, green: 0.65, blue: 0.04)))
            c.fill(railRibbon(tops, depths: samples, width: 6),
                   with: .color(Color(red: 1, green: 0.94, blue: 0.63)))
        }
        // World-fixed joints share one fill; their width still follows depth.
        let world = simulation.distance
        let joint = Int(floor(world / 48))
        var seams = Path()
        for index in (joint - 2)...(joint + 85) {
            let ahead = Double(index) * 48 - world
            guard ahead > -80 else { continue }
            let t = HoneySlideRules.depth(ahead: ahead)
            for side in [-1.0, 1.0] {
                let p = point(t, side, projection)
                let height = HoneySlideRules.railHeight * t
                let rect = CGRect(x: p.x - max(0.1, 3 * t) / 2, y: p.y - height,
                                  width: max(0.1, 3 * t), height: height)
                seams.addRect(rect)
            }
        }
        c.fill(seams, with: .color(.brown.opacity(0.55)))
        drawRailHoney(&c, projection: projection)
    }

    private func railRibbon(_ points: [CGPoint], depths: [Double], width: Double) -> Path {
        var left: [CGPoint] = [], right: [CGPoint] = []
        left.reserveCapacity(points.count); right.reserveCapacity(points.count)
        for i in points.indices {
            let before = points[max(0, i - 1)], after = points[min(points.count - 1, i + 1)]
            let dx = after.x - before.x, dy = after.y - before.y
            let length = max(0.0001, hypot(dx, dy))
            let radius = max(0.05, width * depths[i]) / 2
            let nx = -dy / length * radius, ny = dx / length * radius
            left.append(CGPoint(x: points[i].x + nx, y: points[i].y + ny))
            right.append(CGPoint(x: points[i].x - nx, y: points[i].y - ny))
        }
        var path = Path(); path.addLines(left + right.reversed()); path.closeSubpath()
        return path
    }

    /// Raised, filled waves and rotating eddies share the course projection.
    /// Flow advects through the world independently of the stationary banks.
    private func drawChurningHoney(_ c: inout GraphicsContext, projection: HoneySlideProjection) {
        let flow = distance * 58
        let first = Int(floor((simulation.distance + flow) / 155)) - 2
        let last = Int(ceil((simulation.distance + flow + 4200) / 155))
        let cream = Color(red: 1, green: 0.98, blue: 0.78)
        let amber = Color(red: 0.94, green: 0.43, blue: 0.01)
        func surface(_ z: Double, _ lane: Double, _ lift: Double = 0) -> CGPoint {
            let depth = HoneySlideRules.depth(ahead: z - simulation.distance)
            let p = point(depth, lane, projection)
            return CGPoint(x: p.x, y: p.y - lift * depth)
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
                ridge.reserveCapacity(steps + 1); back.reserveCapacity(steps + 1); front.reserveCapacity(steps + 1)
                shineTop.reserveCapacity(steps + 1); shineBottom.reserveCapacity(steps + 1)
                for step in 0...steps {
                    let u = Double(step) / Double(steps)
                    let x = lane + (u - 0.5) * 0.42
                    let roll = sin(u * .pi)
                    let wobble = sin(u * 8 + bandPhase)
                    let zz = z + offset + sin(x * 6 + bandPhase) * 33 + wobble * 12
                    let height = roll * (17 + 7 * sin(bandPhase + u * 5))
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
                if detail > 0 {
                    let shoulder = HoneyFluidContour.closed(back + ridge.reversed())
                    let trough = HoneyFluidContour.closed(ridge + front.reversed())
                    var volume = c
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
                c.fill(crest, with: .linearGradient(Gradient(colors: [cream.opacity(min(0.83, t * 1.3)),
                    Color.yellow.opacity(0.18)]), startPoint: CGPoint(x: center.x, y: center.y - 18 * t),
                    endPoint: CGPoint(x: center.x, y: center.y + 18 * t)))
            }
            // Eddies curl around one another with a thick honey meniscus.
            for band in 0..<3 where t > 0.12 {
                let lane = Double(band - 1) * 0.60 + sin(Double(index) * 2.1 + Double(band)) * 0.12
                let zz = z + 82 + Double(band) * 17
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
                    c.fill(swirl, with: .linearGradient(Gradient(colors: [
                        cream.opacity(min(0.7, t)), Color(red: 1, green: 0.84, blue: 0.12).opacity(0.32)]),
                        startPoint: CGPoint(x: center.x - 35 * t, y: center.y - 16 * t),
                        endPoint: CGPoint(x: center.x + 30 * t, y: center.y + 28 * t)))
                }
                if t > 0.20 {
                    let p = surface(zz - 7, lane + 0.055, 3)
                    ellipse(&c, CGRect(x: p.x, y: p.y, width: 10 * t, height: 5 * t),
                            [cream.opacity(0.8), .yellow.opacity(0.1)])
                }
            }
        }
    }

    private func drawRailHoney(_ c: inout GraphicsContext, projection: HoneySlideProjection) {
        let world = simulation.distance
        let first = Int(floor(world / 160)) - 1
        let last = Int(ceil((world + HoneySlideRules.drawDistance) / 160))
        for index in stride(from: last, through: first, by: -1) {
            let ahead = Double(index) * 160 - world
            guard ahead > -80, ahead < HoneySlideRules.drawDistance else { continue }
            let t = HoneySlideRules.depth(ahead: ahead)
            for side in [-1.0, 1.0] {
                let foot = point(t, side, projection)
                guard foot.x > -80 && foot.x < 1680 else { continue }
                let top = CGPoint(x: foot.x, y: foot.y - HoneySlideRules.railHeight * t)
                let length = Double(26 + abs(index) % 4 * 8) * t
                var honey = c
                honey.opacity = HoneySlideRules.distantOpacity(ahead: ahead)
                // Rounded tongues cling to the wood and droop into the channel.
                var drip = Path()
                drip.move(to: CGPoint(x: top.x - side * 10 * t, y: top.y - 5 * t))
                drip.addQuadCurve(to: CGPoint(x: top.x - side * 13 * t, y: top.y + length),
                                  control: CGPoint(x: top.x - side * 26 * t, y: top.y + length * 0.45))
                honey.stroke(drip, with: .color(Color(red: 1, green: 0.62, blue: 0.015)),
                             style: StrokeStyle(lineWidth: 22 * t, lineCap: .round))
                honey.stroke(drip, with: .color(.yellow),
                             style: StrokeStyle(lineWidth: 13 * t, lineCap: .round))
                var highlight = Path()
                highlight.move(to: CGPoint(x: top.x - side * 12 * t, y: top.y - 3 * t))
                highlight.addLine(to: CGPoint(x: top.x - side * 17 * t, y: top.y + length * 0.55))
                honey.stroke(highlight, with: .color(.white.opacity(0.8)),
                             style: StrokeStyle(lineWidth: 3 * t, lineCap: .round))
                if abs(index) % 3 == 0 {
                    var spill = Path()
                    spill.move(to: top)
                    spill.addQuadCurve(to: CGPoint(x: top.x + side * 19 * t, y: foot.y + 8 * t),
                                       control: CGPoint(x: top.x + side * 30 * t, y: top.y + 18 * t))
                    honey.stroke(spill, with: .color(.orange),
                                 style: StrokeStyle(lineWidth: 25 * t, lineCap: .round))
                    honey.stroke(spill, with: .color(.yellow.opacity(0.85)),
                                 style: StrokeStyle(lineWidth: 14 * t, lineCap: .round))
                    ellipse(&honey, CGRect(x: foot.x + side * 18 * t - 22 * t, y: foot.y + 2 * t,
                                          width: 44 * t, height: 13 * t), [.yellow, .orange])
                }
                if t > 0.12 {
                    let phase = (distance * 2.4 + Double(abs(index) % 9) / 9).truncatingRemainder(dividingBy: 1)
                    let x = top.x + side * (10 + phase * 52) * t
                    let y = top.y + (phase * 42 - sin(phase * .pi) * 62) * t
                    honey.opacity *= (1 - phase) * 0.75
                    ellipse(&honey, CGRect(x: x, y: y, width: 7 * t, height: 15 * t), [.white, .yellow])
                }
            }
        }
    }

    private func drawCheckpoints(_ c: inout GraphicsContext, billboardYScale: Double) {
        for row in simulation.checkpoints.reversed() {
            let ahead = row.worldPosition - simulation.distance
            guard ahead + HoneySlideRules.dividerTail > HoneySlideRules.nearClipAhead,
                  ahead < HoneySlideRules.drawDistance, row.options.count == 3 else { continue }
            var rowContext = c
            rowContext.opacity = HoneySlideRules.distantOpacity(ahead: ahead)
            let t = HoneySlideRules.depth(ahead: ahead)
            let s = HoneySlideRules.answerScale(depth: t)
            for divider in [-HoneySlideRules.laneBoundary, HoneySlideRules.laneBoundary] {
                dividerWall(&rowContext, rowPosition: row.worldPosition, lateral: divider)
            }
            guard ahead > HoneySlideRules.nearClipAhead else { continue }
            for i in 0..<3 {
                let selected = row.selectedIndex == i
                if selected && row.wasCorrect && collectionTarget != nil { continue }
                let tumble = selected ? min(1, (distance - (row.impactAt ?? distance)) / HoneySlideRules.tumbleDuration) : 0
                if selected && tumble >= 1 { continue }
                let bounds = HoneySlideRules.potBounds(depth: t, lateral: Double(i - 1) * 0.66,
                    elapsed: distance, billboardYScale: billboardYScale, course: simulation.course)
                guard bounds.insetBy(dx: selected ? -150 * s : 0, dy: selected ? -70 * s : 0)
                    .intersects(CGRect(x: 0, y: 0, width: 1600, height: 900)) else { continue }
                let p = ridingPoint(t, Double(i - 1) * 0.66)
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

    private func dividerWall(_ c: inout GraphicsContext, rowPosition: Double, lateral: Double) {
        let half = HoneySlideRules.dividerHalfWidth
        var shadow = Path(), leftFace = Path(), rightFace = Path(), topFace = Path()
        var orangeEdge = Path(), yellowEdge = Path(), edgeGloss = Path()
        var joints: [(Path, Double)] = []
        var drips: [(CGPoint, Double)] = []
        var nose: (CGPoint, CGPoint, Double)?
        func face(_ points: [CGPoint]) -> Path {
            var p = Path(); p.addLines(points); p.closeSubpath(); return p
        }
        // Fixed world blocks, batched into four surfaces. Detail remains
        // stable without paying for a separate gradient for every block.
        for i in 0..<HoneySlideRules.dividerSections {
            let segment = HoneySlideRules.dividerSegment(rowPosition: rowPosition, index: i)
            let far = segment.far - simulation.distance
            guard far > HoneySlideRules.nearClipAhead else { continue }
            let near = max(HoneySlideRules.nearClipAhead, segment.near - simulation.distance)
            let tf = HoneySlideRules.depth(ahead: far), tn = HoneySlideRules.depth(ahead: near)
            let fl = ridingPoint(tf, lateral - half), fr = ridingPoint(tf, lateral + half)
            let nl = ridingPoint(tn, lateral - half), nr = ridingPoint(tn, lateral + half)
            let hf = HoneySlideRules.dividerHeight * tf, hn = HoneySlideRules.dividerHeight * tn
            let topFL = CGPoint(x: fl.x, y: fl.y - hf), topFR = CGPoint(x: fr.x, y: fr.y - hf)
            let topNL = CGPoint(x: nl.x, y: nl.y - hn), topNR = CGPoint(x: nr.x, y: nr.y - hn)
            guard min(topFL.y, topFR.y) < 920 else { continue }
            shadow.addPath(face([fl, fr, nr, nl]).offsetBy(dx: 8 * tn, dy: 9 * tn))
            leftFace.addPath(face([fl, topFL, topNL, nl]))
            rightFace.addPath(face([fr, topFR, topNR, nr]))
            topFace.addPath(face([topFL, topFR, topNR, topNL]))
            addBand(to: &orangeEdge, from: topFL, to: topNL, farWidth: 11 * tf, nearWidth: 11 * tn, farShift: 2 * tf, nearShift: 2 * tn)
            addBand(to: &yellowEdge, from: topFL, to: topNL, farWidth: 7 * tf, nearWidth: 7 * tn)
            addBand(to: &edgeGloss, from: topFL, to: topNL, farWidth: 2 * tf, nearWidth: 2 * tn, farShift: -2 * tf, nearShift: -2 * tn)
            if i % 3 == 1 { drips.append((topFR, tf)) }
            if i % 2 == 0 {
                var joint = Path(); joint.move(to: topNL); joint.addLine(to: topNR); joint.addLine(to: nr)
                joints.append((joint, tn))
            }
            if i == HoneySlideRules.dividerSections - 1 { nose = (nl, nr, tn) }
        }
        guard !topFace.isEmpty else { return }
        c.fill(shadow, with: .color(.brown.opacity(0.23)))
        c.fill(leftFace, with: .linearGradient(Gradient(colors: [
            Color(red: 0.77, green: 0.44, blue: 0.15), Color(red: 0.36, green: 0.16, blue: 0.045)]),
            startPoint: CGPoint(x: 0, y: 180), endPoint: CGPoint(x: 0, y: 1000)))
        c.fill(rightFace, with: .linearGradient(Gradient(colors: [
            Color(red: 0.88, green: 0.52, blue: 0.18), Color(red: 0.49, green: 0.23, blue: 0.065)]),
            startPoint: CGPoint(x: 0, y: 180), endPoint: CGPoint(x: 0, y: 1000)))
        c.fill(topFace, with: .linearGradient(Gradient(colors: [
            Color(red: 1, green: 0.87, blue: 0.32), Color(red: 0.93, green: 0.56, blue: 0.13)]),
            startPoint: CGPoint(x: 0, y: 180), endPoint: CGPoint(x: 0, y: 1000)))
        c.fill(orangeEdge, with: .color(.orange))
        c.fill(yellowEdge, with: .color(.yellow))
        c.fill(edgeGloss, with: .color(Color(red: 1, green: 0.97, blue: 0.72)))
        for (p, t) in drips {
            var drip = Path(); drip.move(to: p)
            drip.addQuadCurve(to: CGPoint(x: p.x + 3 * t, y: p.y + 24 * t),
                              control: CGPoint(x: p.x + 9 * t, y: p.y + 7 * t))
            c.stroke(drip, with: .color(.orange), style: StrokeStyle(lineWidth: 9 * t, lineCap: .round))
            c.stroke(drip, with: .color(.yellow), style: StrokeStyle(lineWidth: 5 * t, lineCap: .round))
        }
        for (joint, t) in joints {
            c.stroke(joint, with: .color(Color(red: 0.49, green: 0.25, blue: 0.075)), lineWidth: 2 * t)
        }
        if let (nl, nr, t) = nose {
            let width = nr.x - nl.x, height = HoneySlideRules.dividerHeight * t
            let rect = CGRect(x: nl.x, y: nl.y - height, width: width, height: height + 5 * t)
            c.fill(Path(roundedRect: rect, cornerRadius: width * 0.4), with: .linearGradient(Gradient(colors: [
                Color(red: 0.93, green: 0.62, blue: 0.22), Color(red: 0.45, green: 0.21, blue: 0.06)]),
                startPoint: rect.origin, endPoint: CGPoint(x: rect.maxX, y: rect.maxY)))
            ellipse(&c, CGRect(x: nl.x - 2 * t, y: nl.y - height - width * 0.15, width: width + 4 * t, height: width * 0.46),
                    [Color(red: 1, green: 0.96, blue: 0.56), .yellow, .orange])
            rounded(&c, CGRect(x: nl.x + width * 0.17, y: nl.y - height,
                              width: width * 0.15, height: height * 0.6), width * 0.075, .yellow)
            ellipse(&c, CGRect(x: nl.x - 12 * t, y: nl.y - 3 * t, width: width + 24 * t, height: 12 * t),
                    [.yellow.opacity(0.8), .orange.opacity(0)])
        }
    }

    /// Batch a perspective-width band without per-block rounded strokes.
    private func addBand(to path: inout Path, from a: CGPoint, to b: CGPoint,
                         farWidth: Double, nearWidth: Double, farShift: Double = 0, nearShift: Double = 0) {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = max(0.0001, hypot(dx, dy))
        let nx = -dy / length / 2, ny = dx / length / 2
        path.move(to: CGPoint(x: a.x + nx * farWidth, y: a.y + farShift + ny * farWidth))
        path.addLine(to: CGPoint(x: b.x + nx * nearWidth, y: b.y + nearShift + ny * nearWidth))
        path.addLine(to: CGPoint(x: b.x - nx * nearWidth, y: b.y + nearShift - ny * nearWidth))
        path.addLine(to: CGPoint(x: a.x - nx * farWidth, y: a.y + farShift - ny * farWidth))
        path.closeSubpath()
    }

    private func cliff(_ c: inout GraphicsContext, at p: CGPoint, scale s: Double, phase: Double) {
        let rock = CGRect(x: p.x - 90 * s, y: p.y - 150 * s, width: 180 * s, height: 153 * s)
        c.fill(Path(roundedRect: rock, cornerRadius: 20 * s), with: .linearGradient(Gradient(colors: [
            Color(red: 0.74, green: 0.61, blue: 0.42), Color(red: 0.41, green: 0.34, blue: 0.23)]),
            startPoint: rock.origin, endPoint: CGPoint(x: rock.maxX, y: rock.maxY)))
        for i in 0..<3 {
            let x = p.x - 65 * s + Double(i) * 43 * s
            rounded(&c, CGRect(x: x, y: p.y - 152 * s, width: 31 * s, height: 150 * s), 15 * s, .orange)
            rounded(&c, CGRect(x: x + 7 * s, y: p.y - 150 * s, width: 7 * s, height: 140 * s), 3 * s, .yellow.opacity(0.8))
            let pulse = (distance * 2.3 + phase + Double(i) * 0.33).truncatingRemainder(dividingBy: 1)
            ellipse(&c, CGRect(x: x + 10 * s, y: p.y - 140 * s + pulse * 120 * s, width: 8 * s, height: 24 * s),
                    [.white.opacity(0.65), .yellow.opacity(0.05)])
        }
        ellipse(&c, CGRect(x: p.x - 102 * s, y: p.y - 169 * s, width: 205 * s, height: 38 * s), [.yellow, .orange])
        ellipse(&c, CGRect(x: p.x - 105 * s, y: p.y - 7 * s, width: 210 * s, height: 19 * s), [.orange, .yellow.opacity(0.3)])
    }

    private func barrel(_ c: inout GraphicsContext, scale s: Double, text: String, opening: Double) {
        // A closed or fully open pot is one cached image, including its face.
        // Only the 0.42-second moving shutter needs procedural drawing.
        if opening <= 0 || opening >= 1 {
            let id = opening <= 0 ? "closed-pot" : "pot:\(text)"
            if let image = c.resolveSymbol(id: id) {
                var pot = c
                pot.scaleBy(x: s / 2, y: s / 2)
                pot.draw(image, at: .zero, anchor: UnitPoint(x: 0.5, y: 144.0 / 166))
            }
            return
        }
        var pot = c
        pot.scaleBy(x: s, y: s)
        var artwork = pot
        artwork.scaleBy(x: 0.5, y: 0.5)
        if let base = c.resolveSymbol(id: 6) {
            artwork.draw(base, at: .zero, anchor: UnitPoint(x: 0.5, y: 144.0 / 166))
        }
        HoneyPotArtwork.face(&pot, text: text, opening: opening)
        if let crown = c.resolveSymbol(id: 7) {
            artwork.draw(crown, at: .zero, anchor: UnitPoint(x: 0.5, y: 144.0 / 166))
        }
    }


}

private enum HoneyRiderDrawing {
    static func draw(in context: GraphicsContext, size: CGSize, simulation: HoneySlideSimulation, reduceMotion: Bool) {
        guard let bear = context.resolveSymbol(id: "rider") else { return }
        let width = min(size.width * 0.285, size.height * 0.43)
        let player = HoneySlideRules.ridingPoint(depth: HoneySlideRules.playerDepth,
            lateral: simulation.lateral, distance: simulation.elapsed, course: simulation.course)
        let bob = reduceMotion ? 0 : sin(simulation.elapsed * 6.5) * 4 * min(size.width / 1600, size.height / 900)
        var sprite = context
        sprite.translateBy(x: player.x / 1600 * size.width, y: size.height * 0.735 + bob)
        sprite.rotate(by: .degrees(reduceMotion ? 0 : simulation.tubeHeading))
        sprite.scaleBy(x: width / 400, y: width / 400)
        sprite.draw(bear, at: .zero)
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
        let spriteWidth = min(size.width * 0.285, size.height * 0.43)
        let spriteHeight = spriteWidth * 1312 / 1247
        let player = HoneySlideRules.ridingPoint(depth: HoneySlideRules.playerDepth,
            lateral: simulation.lateral, distance: simulation.elapsed, course: simulation.course)
        let angle = reduceMotion ? 0 : simulation.tubeHeading * .pi / 180
        let bob = reduceMotion ? 0 : sin(simulation.elapsed * 6.5) * 4 * min(size.width / 1600, size.height / 900)
        var c = context
        c.translateBy(x: player.x / 1600 * size.width - sin(angle) * spriteHeight * 0.28,
                      y: size.height * 0.735 + cos(angle) * spriteHeight * 0.28 + bob)
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

    static func face(_ c: inout GraphicsContext, text: String?, opening: Double = 1) {
        let window = CGRect(x: -43, y: -92, width: 86, height: 78)
        var face = c
        face.clip(to: Path(roundedRect: window, cornerRadius: 11))
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
/// gradients and text from every subsequent frame. No disk or network work.
@MainActor
private final class HoneyArtworkCache {
    static let shared = HoneyArtworkCache()
    private let images = NSCache<NSString, CGImage>()
    private init() {
        images.countLimit = 64
        images.totalCostLimit = 48 * 1024 * 1024
    }
    func image<Content: View>(key: String, size: CGSize, density: CGFloat, content: Content) -> CGImage? {
        let cacheKey = key as NSString
        if let image = images.object(forKey: cacheKey) { return image }
        let renderer = ImageRenderer(content: content.frame(width: size.width, height: size.height))
        renderer.scale = density
        guard let image = renderer.cgImage else { return nil }
        images.setObject(image, forKey: cacheKey, cost: image.bytesPerRow * image.height)
        return image
    }
}

private struct HoneyBitmapSymbol<Content: View>: View, Equatable {
    let key: String
    let size: CGSize
    var density: CGFloat = 2
    let content: Content
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.key == rhs.key && lhs.size == rhs.size && lhs.density == rhs.density }
    var body: some View {
        if let image = HoneyArtworkCache.shared.image(key: key, size: size, density: density, content: content) {
            Image(decorative: image, scale: density).resizable().frame(width: size.width, height: size.height)
        } else {
            content.frame(width: size.width, height: size.height)
        }
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
    var penalty: Anchor<CGRect>?
}

private struct HoneyScoreAnchor: PreferenceKey {
    static var defaultValue: HoneyHUDAnchors { HoneyHUDAnchors() }
    static func reduce(value: inout HoneyHUDAnchors, nextValue: () -> HoneyHUDAnchors) {
        let next = nextValue()
        if let score = next.score { value.score = score }
        if let penalty = next.penalty { value.penalty = penalty }
    }
}

/// Permanently mounted, lightweight effects above the HUD. Numbered images
/// are warmed with the course textures, before the collision that uses them.
private struct HoneyImpactEffects: View {
    let simulation: HoneySlideSimulation
    let rider: Image
    let reduceMotion: Bool
    let target: CGRect?
    let penaltyTarget: CGRect?
    private var potTexts: [String] {
        Array(Set(simulation.checkpoints.prefix(4).flatMap { $0.options.map(\.text) }
                  + simulation.impacts.map(\.text))).sorted()
    }
    var body: some View {
        Canvas { context, size in
            drawCollection(in: context, size: size)
            if let progress = simulation.penaltyProgress, let target = penaltyTarget,
               let penalty = context.resolveSymbol(id: "penalty") {
                var badge = context
                let pulse = 1 + sin(min(1, progress * 5) * .pi) * 0.14
                badge.opacity = min(1, (1 - progress) * 7)
                badge.translateBy(x: target.midX, y: target.midY)
                badge.scaleBy(x: target.width / 120 * pulse, y: target.width / 120 * pulse)
                badge.draw(penalty, at: .zero)
            }
        } symbols: {
            ForEach(potTexts, id: \.self) { text in
                HoneyBitmapSymbol(key: "pot:\(text)", size: CGSize(width: 308, height: 332),
                    content: HoneyPotIllustration(text: text)).equatable().tag("pot:\(text)")
            }
            rider.resizable().scaledToFit().frame(width: 400, height: 400 * 1312 / 1247).tag("rider")
            Text("−1").font(.system(size: 90, weight: .black, design: .rounded))
                .foregroundStyle(Color(red: 0.79, green: 0.085, blue: 0.08))
                .shadow(color: .white.opacity(0.6), radius: 0, y: 2)
                .frame(width: 120).tag("penalty")
        }
    }

    private func drawCollection(in context: GraphicsContext, size: CGSize) {
        guard let target = target else { return }
        for impact in simulation.impacts where impact.correct {
            let progress = impact.progress(at: simulation.elapsed)
            guard progress < 1, let pot = context.resolveSymbol(id: "pot:\(impact.text)") else { continue }
            // Convert the same ground anchor, center offset and uniform scale
            // used by barrel. At contact this is exactly the pot's last pose.
            let origin = CGPoint(x: impact.origin.x / 1600 * size.width,
                                 y: impact.origin.y / 900 * size.height - 61 * impact.scale * size.width / 1600)
            let end = CGPoint(x: target.midX, y: target.midY)
            let initialScale = impact.scale * size.width / 1600 / 2
            let finalScale = min(target.width / 308, target.height / 332)
            let motion = HoneyCollectionMotion(progress: progress, origin: origin, target: end,
                                               initialScale: initialScale, finalScale: finalScale)
            // Small droplets follow the path; the pot itself stays opaque.
            if progress > 0.04 && progress < 0.92 {
                for i in 1...4 {
                    let trail = HoneyCollectionMotion(progress: max(0, progress - Double(i) * 0.035),
                        origin: origin, target: end, initialScale: initialScale, finalScale: finalScale)
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

private struct HoneyHUD: View, Equatable {
    let scale: CGFloat
    let width: CGFloat
    let prompt: String
    let score: Int
    let questionNumber: Int
    let totalQuestions: Int
    let canPause: Bool
    let penaltyProgress: Double?
    let showsFeedback: Bool
    let missedChallenge: String
    let onPause: () -> Void

    private var buttonSide: CGFloat { 120 * scale }
    private var scorePotScale: CGFloat { 84 * scale / 154 }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.scale == rhs.scale && lhs.width == rhs.width && lhs.prompt == rhs.prompt && lhs.score == rhs.score && lhs.canPause == rhs.canPause
            && lhs.questionNumber == rhs.questionNumber && lhs.totalQuestions == rhs.totalQuestions
            && lhs.penaltyProgress == rhs.penaltyProgress && lhs.showsFeedback == rhs.showsFeedback
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
                        .background(HoneyQuestionSign(showsHoney: false))
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
                    .frame(width: min(width * 0.50, 760 * scale), height: 120 * scale)
                    .background(HoneyQuestionSign())
                    .shadow(color: .brown.opacity(0.25), radius: 0, y: 6 * scale)
                if showsFeedback && !missedChallenge.isEmpty {
                    Text(missedChallenge)
                        .font(.system(size: 28 * scale, weight: .bold, design: .rounded))
                        .foregroundStyle(.brown)
                        .padding(8 * scale).background(.regularMaterial, in: Capsule())
                }
            }
        }
    }

    private var scorePanel: some View {
        HStack(spacing: 8 * scale) {
            HoneyPotIllustration(text: penaltyProgress == nil ? "\(score)" : "", showsShadow: false)
                .frame(width: 154 * scorePotScale, height: 166 * scorePotScale)
                .anchorPreference(key: HoneyScoreAnchor.self, value: .bounds) { HoneyHUDAnchors(score: $0) }
                .overlay {
                    // The penalty replaces the digit on the pot's face.
                    Color.clear
                        .frame(width: 86 * scorePotScale, height: 78 * scorePotScale)
                        .anchorPreference(key: HoneyScoreAnchor.self, value: .bounds) { HoneyHUDAnchors(penalty: $0) }
                        .offset(y: 9 * scorePotScale)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(Currency.name) \(score)")
                .accessibilityIdentifier("honey-score")

            progressIndicator
        }
        .padding(.horizontal, 18 * scale)
        .frame(height: buttonSide)
        .background(HoneyQuestionSign(showsHoney: false))
        .environment(\.layoutDirection, .leftToRight)
    }

    private var progressIndicator: some View {
        VStack(spacing: 3 * scale) {
            Text(verbatim: "\(questionNumber)")
                .font(.system(size: 30 * scale, weight: .black, design: .rounded))
            Rectangle()
                .fill(HoneyPotArtwork.darkWood.opacity(0.35))
                .frame(width: 24 * scale, height: 2 * scale)
            Text(verbatim: "\(totalQuestions)")
                .font(.system(size: 22 * scale, weight: .bold, design: .rounded))
                .opacity(0.8)
        }
        .monospacedDigit()
        .foregroundStyle(Color(red: 0.25, green: 0.10, blue: 0.03))
        .frame(width: 46 * scale, height: 82 * scale)
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
        // frame must not continually rebuild the three VoiceOver controls.
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

private struct HoneyTreeSymbol: View, Equatable {
    let variant: Int
    var body: some View {
        Canvas { c, _ in
            let x = 115.0, y = 287.0
            c.fill(Path(ellipseIn: CGRect(x: x - 85, y: y - 3, width: 170, height: 14)),
                   with: .color(Color(red: 0.05, green: 0.24, blue: 0.09).opacity(0.5)))
            let trunk = CGRect(x: x - 12, y: y - 160, width: 24, height: 163)
            c.fill(Path(roundedRect: trunk, cornerRadius: 8), with: .color(Color(red: 0.49, green: 0.29, blue: 0.10)))
            c.fill(Path(roundedRect: CGRect(x: x - 9, y: y - 158, width: 5, height: 145), cornerRadius: 2),
                   with: .color(Color(red: 0.74, green: 0.48, blue: 0.22)))
            for j in 0..<4 {
                let rect = CGRect(x: x + Double(j % 3 - 1) * 45 - 53,
                                  y: y - (220 + Double(j / 3) * 50), width: 110, height: 105)
                c.fill(Path(ellipseIn: rect), with: .linearGradient(Gradient(colors: [
                    Color(red: 0.48 + Double(variant) * 0.035, green: 0.76, blue: 0.17),
                    Color(red: 0.08, green: 0.40 + Double(variant) * 0.018, blue: 0.14)]),
                    startPoint: rect.origin, endPoint: CGPoint(x: rect.maxX, y: rect.maxY)))
                c.fill(Path(ellipseIn: CGRect(x: rect.minX + 19, y: rect.minY + 12, width: 30, height: 18)),
                       with: .color(.yellow.opacity(0.16)))
            }
            let bush = CGRect(x: x - 55, y: y - 15, width: 112, height: 25)
            c.fill(Path(ellipseIn: bush), with: .linearGradient(Gradient(colors: [
                Color(red: 0.26, green: 0.61, blue: 0.18), Color(red: 0.07, green: 0.35, blue: 0.12)]),
                startPoint: bush.origin, endPoint: CGPoint(x: bush.maxX, y: bush.maxY)))
            for j in 0..<3 {
                c.fill(Path(ellipseIn: CGRect(x: x - 32 + Double(j) * 30, y: y - 13, width: 10, height: 9)),
                       with: .color(.white))
                c.fill(Path(ellipseIn: CGRect(x: x - 29 + Double(j) * 30, y: y - 10, width: 4, height: 4)),
                       with: .color(.yellow))
            }
        }
        .frame(width: 230, height: 300)
    }
}

private struct HoneyUnderbrushSymbol: View, Equatable {
    let variant: Int
    var body: some View {
        Canvas { c, _ in
            let base = CGRect(x: 7, y: 84, width: 206, height: 26)
            c.fill(Path(ellipseIn: base), with: .color(Color(red: 0.05, green: 0.27, blue: 0.07).opacity(0.5)))
            for i in 0..<5 {
                let rect = CGRect(x: 12 + Double(i) * 34, y: 43 + Double(i % 2) * 13,
                                  width: 66, height: 53)
                c.fill(Path(ellipseIn: rect), with: .linearGradient(Gradient(colors: [
                    Color(red: 0.40, green: 0.69, blue: 0.12), Color(red: 0.09, green: 0.38, blue: 0.12)]),
                    startPoint: rect.origin, endPoint: CGPoint(x: rect.maxX, y: rect.maxY)))
            }
            if variant == 1 {
                let rock = CGRect(x: 71, y: 56, width: 61, height: 40)
                c.fill(Path(roundedRect: rock, cornerRadius: 15), with: .linearGradient(Gradient(colors: [
                    Color(red: 0.79, green: 0.71, blue: 0.46), Color(red: 0.44, green: 0.42, blue: 0.25)]),
                    startPoint: rock.origin, endPoint: CGPoint(x: rock.maxX, y: rock.maxY)))
            }
            for i in 0..<5 {
                let x = 30 + Double(i) * 36
                let y = 55 + Double((i + variant) % 3) * 16
                for petal in 0..<5 {
                    let angle = Double(petal) / 5 * .pi * 2
                    c.fill(Path(ellipseIn: CGRect(x: x + cos(angle) * 7 - 5,
                                                 y: y + sin(angle) * 7 - 5, width: 10, height: 10)),
                           with: .color(.white.opacity(0.95)))
                }
                c.fill(Path(ellipseIn: CGRect(x: x - 4, y: y - 4, width: 8, height: 8)), with: .color(.yellow))
            }
        }
        .frame(width: 220, height: 112)
    }
}

private struct HoneyQuestionSign: View {
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
