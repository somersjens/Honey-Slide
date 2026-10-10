//
//  PolarScenery.swift
//  Flying Penguin
//
//  Everything the character flies past: sky and clouds, the water itself, the
//  launch pad the cannon stands on and the splashes it throws. Every layer reads
//  the playfield's single `worldOffset` and moves at its own parallax, so one
//  conveyor drives the whole scene and nothing can drift out of step with the
//  rings.
//
//  The layers here are shared by all ten worlds and take their colours from a
//  `SceneryTheme`; what actually differs per character lives in
//  `SceneryTheme`, `SceneryHorizon`, `SceneryFloaters` and `SceneryAir`. The
//  `PolarScene` palette below remains the penguin's own, and is what the menu
//  backdrop is still painted with.
//

import SwiftUI

// MARK: - Shared world helpers

enum PolarScene {
    /// All scenery seeds are fixed small integers. Cache their deterministic
    /// wobble once instead of evaluating `sin` throughout every 60 Hz redraw.
    private static let jitterTable: [CGFloat] = (0..<1024).map { calculatedJitter($0) }

    /// Wraps a repeating scenery item into a band that reaches `margin` beyond
    /// both screen edges, so items leave and re-enter fully offscreen instead
    /// of popping into existence at the rim.
    static func scrollX(index: Int,
                        count: Int,
                        width: CGFloat,
                        worldOffset: CGFloat,
                        parallax: CGFloat,
                        margin: CGFloat) -> CGFloat {
        guard count > 0, width > 0 else { return 0 }
        let span = width + margin * 2
        let spacing = span / CGFloat(count)
        let raw = worldOffset * parallax + CGFloat(index) * spacing
        var wrapped = raw.truncatingRemainder(dividingBy: span)
        if wrapped < 0 { wrapped += span }
        return wrapped - margin
    }

    /// Deterministic −1…1 jitter. Every scenery item is drawn from the same
    /// handful of shapes; a seeded wobble is what keeps a row of them from
    /// reading as a repeated stamp.
    static func jitter(_ seed: Int) -> CGFloat {
        if jitterTable.indices.contains(seed) { return jitterTable[seed] }
        return calculatedJitter(seed)
    }

    private static func calculatedJitter(_ seed: Int) -> CGFloat {
        let raw = sin(Double(seed) * 12.9898) * 43758.5453
        return CGFloat((raw - raw.rounded(.down)) * 2 - 1)
    }

    // The ice palette. Every other world takes its colours from its own
    // `SceneryTheme`; these are what the sea ice itself is drawn in, and what
    // the menu backdrop is tinted from.
    static let iceLight = Color(red: 0.90, green: 0.98, blue: 1.00)
    static let iceMid = Color(red: 0.62, green: 0.88, blue: 0.97)
    static let iceDeep = Color(red: 0.29, green: 0.70, blue: 0.90)
    static let seaMid = Color(red: 0.05, green: 0.50, blue: 0.80)
    /// Reading colour for copy that sits on the pale menu backdrop.
    static let ink = Color(red: 0.06, green: 0.24, blue: 0.46)
    /// Where the sea crosses `CannonLaunchPad`'s own frame.
    static let padWaterline: CGFloat = 0.40
    /// Height of the levelled strip that carries the cannon's wheels.
    static let padDeckFraction: CGFloat = 0.165
}

// MARK: - Sky

/// Sky gradient, the theme's own low sun and two parallax bands of clouds, plus
/// whatever that world puts in the air between them.
struct PolarSkyLayer: View {
    let size: CGSize
    let worldOffset: CGFloat
    let theme: SceneryTheme

    /// Kept high in the frame and soft, so the answer rings that travel across
    /// the same band always stay the highest-contrast thing on screen.
    private let farBand: [CGFloat] = [0.15, 0.33, 0.21, 0.42]
    private let nearBand: [CGFloat] = [0.10, 0.25, 0.16]

    var body: some View {
        ZStack {
            LinearGradient(colors: [theme.skyTop, theme.skyMid, theme.skyLow],
                           startPoint: .top, endPoint: .bottom)

            Circle()
                .fill(RadialGradient(colors: [theme.sun.core,
                                              theme.sun.halo.opacity(0.55),
                                              theme.sun.halo.opacity(0)],
                                     center: .center,
                                     startRadius: size.width * 0.012,
                                     endRadius: size.width * theme.sun.scale * 0.5))
                .frame(width: size.width * theme.sun.scale,
                       height: size.width * theme.sun.scale)
                .position(x: size.width * theme.sun.centre.x,
                          y: size.height * theme.sun.centre.y)

            SceneryAirLayer(size: size,
                            worldOffset: worldOffset,
                            style: theme.air,
                            tint: theme.airTint)

            ForEach(farBand.indices, id: \.self) { index in
                cloud(index: index,
                      count: farBand.count,
                      y: farBand[index],
                      parallax: 0.05,
                      width: size.width * (0.19 + PolarScene.jitter(index &* 3) * 0.03),
                      opacity: 0.52)
            }

            ForEach(nearBand.indices, id: \.self) { index in
                cloud(index: index,
                      count: nearBand.count,
                      y: nearBand[index],
                      parallax: 0.15,
                      width: size.width * (0.30 + PolarScene.jitter(index &* 7 &+ 2) * 0.045),
                      opacity: 0.80)
            }
        }
        .allowsHitTesting(false)
    }

    private func cloud(index: Int,
                       count: Int,
                       y: CGFloat,
                       parallax: CGFloat,
                       width: CGFloat,
                       opacity: Double) -> some View {
        SceneryCloud(seed: index &+ count &* 13,
                     style: theme.clouds.style,
                     light: theme.clouds.light,
                     shade: theme.clouds.shade)
            .frame(width: width, height: width * 0.45)
            .opacity(opacity)
            .position(x: PolarScene.scrollX(index: index,
                                            count: count,
                                            width: size.width,
                                            worldOffset: worldOffset,
                                            parallax: parallax,
                                            margin: width * 0.75),
                      y: size.height * y)
    }
}

/// The polar cloud, for the menu backdrop that is painted in the app's own ice
/// palette rather than in a character's.
struct PolarCloud: View {
    let seed: Int

    var body: some View {
        SceneryCloud(seed: seed,
                     style: SceneryThemes.polar.clouds.style,
                     light: SceneryThemes.polar.clouds.light,
                     shade: SceneryThemes.polar.clouds.shade)
    }
}

// MARK: - Sea ice

/// One floating block: a blue underside below the surface, a faceted white slab
/// above it and a snow cap on top.
struct SeaIceBlock: View {
    let seed: Int
    let isPad: Bool
    /// Blocks drawn over the water need to bring their own surface line with
    /// them; the sea's crest passes behind them, not in front.
    var showsFoam = false

    /// Where the sea's surface crosses the block's own frame.
    static let topFraction: CGFloat = 0.62
    private var topFraction: CGFloat { Self.topFraction }

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height
            ZStack {
                DriftIceUnderside(seed: seed, topFraction: topFraction)
                    .fill(LinearGradient(colors: [PolarScene.iceDeep.opacity(0.85),
                                                  PolarScene.seaMid.opacity(0.55)],
                                         startPoint: .top, endPoint: .bottom))

                DriftIceShape(seed: seed, topFraction: topFraction)
                    .fill(LinearGradient(colors: [.white,
                                                  PolarScene.iceLight,
                                                  PolarScene.iceMid],
                                         startPoint: .topLeading,
                                         endPoint: .bottomTrailing))
                    .overlay(
                        DriftIceShape(seed: seed, topFraction: topFraction)
                            .stroke(.white, lineWidth: isPad ? 3 : 2.2)
                    )

                DriftIceFacets(seed: seed, topFraction: topFraction)
                    .stroke(PolarScene.iceDeep.opacity(0.40),
                            style: StrokeStyle(lineWidth: isPad ? 2 : 1.4,
                                               lineCap: .round,
                                               lineJoin: .round))

                // The wet band where the block meets the sea. Without it a
                // white slab on a white horizon has no contact point and the
                // whole waterline reads as one continuous shelf.
                Capsule()
                    .fill(PolarScene.iceDeep.opacity(0.55))
                    .frame(width: w * 0.86, height: max(2, h * 0.055))
                    .position(x: w * 0.5, y: h * topFraction)

                if showsFoam {
                    Capsule()
                        .fill(.white.opacity(0.92))
                        .frame(width: w * 1.16, height: max(3, h * 0.075))
                        .position(x: w * 0.5, y: h * topFraction + h * 0.02)
                }
            }
        }
        // Depth styling belongs to `SceneryFloater`, which knows whether this
        // is one of the two foreground objects. Applying a grouped shadow here
        // forced every distant ice block through an offscreen render pass on
        // every simulation frame (and foreground blocks were shadowed twice).
    }
}

/// The part of a floe that stands above the surface: a chunky slab with two
/// peaks, jittered per seed so no two blocks share a silhouette.
struct DriftIceShape: Shape {
    let seed: Int
    let topFraction: CGFloat

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let line = rect.height * topFraction
        let j: (Int) -> CGFloat = { PolarScene.jitter(seed &* 31 &+ $0) }
        var path = Path()
        path.move(to: CGPoint(x: w * 0.02, y: line))
        path.addLine(to: CGPoint(x: w * (0.13 + j(1) * 0.03), y: line * (0.46 + j(2) * 0.10)))
        path.addLine(to: CGPoint(x: w * (0.31 + j(3) * 0.04), y: line * (0.14 + j(4) * 0.08)))
        path.addLine(to: CGPoint(x: w * (0.52 + j(5) * 0.04), y: line * (0.34 + j(6) * 0.10)))
        path.addLine(to: CGPoint(x: w * (0.68 + j(7) * 0.04), y: line * (0.09 + j(8) * 0.07)))
        path.addLine(to: CGPoint(x: w * (0.85 + j(9) * 0.03), y: line * (0.44 + j(10) * 0.10)))
        path.addLine(to: CGPoint(x: w * 0.98, y: line))
        path.closeSubpath()
        return path
    }
}

private struct DriftIceUnderside: Shape {
    let seed: Int
    let topFraction: CGFloat

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let line = h * topFraction
        let j: (Int) -> CGFloat = { PolarScene.jitter(seed &* 19 &+ $0) }
        var path = Path()
        path.move(to: CGPoint(x: w * 0.06, y: line - h * 0.05))
        path.addLine(to: CGPoint(x: w * 0.21, y: h * (0.86 + j(1) * 0.06)))
        path.addLine(to: CGPoint(x: w * 0.43, y: h * (0.99 + j(2) * 0.01)))
        path.addLine(to: CGPoint(x: w * 0.63, y: h * (0.82 + j(3) * 0.08)))
        path.addLine(to: CGPoint(x: w * 0.81, y: h * (0.94 + j(4) * 0.05)))
        path.addLine(to: CGPoint(x: w * 0.94, y: line - h * 0.05))
        path.closeSubpath()
        return path
    }
}

private struct DriftIceFacets: Shape {
    let seed: Int
    let topFraction: CGFloat

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let line = rect.height * topFraction
        let j: (Int) -> CGFloat = { PolarScene.jitter(seed &* 23 &+ $0) }
        var path = Path()
        path.move(to: CGPoint(x: w * (0.31 + j(3) * 0.04), y: line * (0.14 + j(4) * 0.08)))
        path.addLine(to: CGPoint(x: w * 0.38, y: line * 0.88))
        path.move(to: CGPoint(x: w * (0.68 + j(7) * 0.04), y: line * (0.09 + j(8) * 0.07)))
        path.addLine(to: CGPoint(x: w * 0.62, y: line * 0.90))
        return path
    }
}

// MARK: - Water

/// The water behind everything that floats on it.
struct PolarWaterBackdrop: View {
    let size: CGSize
    let waterline: CGFloat
    let worldOffset: CGFloat
    let isPad: Bool
    let theme: SceneryTheme

    var body: some View {
        let amplitude = WaterSurface.amplitude(isPad: isPad)
        let depth = WaterSurface.depth(size: size, waterline: waterline, isPad: isPad)
        ZStack(alignment: .top) {
            WaterBodyShape(phase: worldOffset * 0.55, amplitude: amplitude)
                .fill(LinearGradient(colors: [theme.water.shallow,
                                              theme.water.mid,
                                              theme.water.deep],
                                     startPoint: .top, endPoint: .bottom))

            // Long, slow swells far out, then quicker chop closer in.
            ForEach(0..<4, id: \.self) { index in
                WaveEdge(phase: worldOffset * (0.30 + CGFloat(index) * 0.12),
                         wavelength: 52 + CGFloat(index) * 9)
                    .stroke(theme.water.foam.opacity(0.26 - Double(index) * 0.042),
                            style: StrokeStyle(lineWidth: isPad ? 4 : 2.5, lineCap: .round))
                    .frame(height: 11)
                    .offset(y: amplitude + CGFloat(index) * (isPad ? 17 : 13))
            }
        }
        .frame(width: size.width, height: depth)
        .position(x: size.width * 0.5,
                  y: waterline - amplitude + depth * 0.5)
    }
}

/// The translucent near half of the water. Drawn over the character and the
/// floating objects, so anything that dips below the line is visibly submerged.
struct PolarWaterForeground: View {
    let size: CGSize
    let waterline: CGFloat
    let worldOffset: CGFloat
    let isPad: Bool
    let theme: SceneryTheme

    var body: some View {
        let amplitude = WaterSurface.amplitude(isPad: isPad)
        let depth = WaterSurface.depth(size: size, waterline: waterline, isPad: isPad)
        ZStack(alignment: .top) {
            WaterBodyShape(phase: worldOffset * 0.55, amplitude: amplitude)
                .fill(LinearGradient(colors: [theme.water.shallow.opacity(0.46),
                                              theme.water.mid.opacity(0.80)],
                                     startPoint: .top, endPoint: .bottom))

            // The crest itself: one bright, slightly glowing line the eye can
            // lock onto, with a paler echo just under it.
            WaveEdge(phase: worldOffset * 0.55, wavelength: 58)
                .stroke(theme.water.crest.opacity(0.95),
                        style: StrokeStyle(lineWidth: isPad ? 7 : 5, lineCap: .round))
                .frame(height: amplitude * 2)
                .offset(y: 0)
                .shadow(color: theme.water.glow.opacity(0.55), radius: 4, y: 2)

            WaveEdge(phase: worldOffset * 0.55 + 14, wavelength: 58)
                .stroke(theme.water.glow.opacity(0.70),
                        style: StrokeStyle(lineWidth: isPad ? 3.5 : 2.5, lineCap: .round))
                .frame(height: 13)
                .offset(y: amplitude + (isPad ? 10 : 7))

            SurfaceSparkles(width: size.width,
                            worldOffset: worldOffset,
                            amplitude: amplitude,
                            isPad: isPad,
                            foam: theme.water.foam)
        }
        .frame(width: size.width, height: depth)
        .position(x: size.width * 0.5,
                  y: waterline - amplitude + depth * 0.5)
        .allowsHitTesting(false)
    }
}

/// Short foam dashes riding the crest. They travel at the full world speed, so
/// they read as the surface itself moving rather than as decoration on it.
private struct SurfaceSparkles: View {
    let width: CGFloat
    let worldOffset: CGFloat
    let amplitude: CGFloat
    let isPad: Bool
    let foam: Color

    private let count = 12

    var body: some View {
        ForEach(0..<count, id: \.self) { index in
            let jitter = PolarScene.jitter(index &* 29)
            Capsule()
                .fill(foam.opacity(0.42 + Double(abs(jitter)) * 0.28))
                .frame(width: width * (0.016 + abs(jitter) * 0.012),
                       height: isPad ? 2.5 : 1.8)
                .position(x: PolarScene.scrollX(index: index,
                                                count: count,
                                                width: width,
                                                worldOffset: worldOffset,
                                                parallax: 1.0,
                                                margin: width * 0.05),
                          // Hugging the crest reads as foam; further down the
                          // same dashes just looked like litter on the sea.
                          y: amplitude * (1.25 + jitter * 0.35)
                             + CGFloat(index % 3) * (isPad ? 5 : 3.5))
        }
    }
}

/// Both water layers share one surface line, so their wave silhouettes sit
/// exactly on top of each other however the scene is sized.
enum WaterSurface {
    static func amplitude(isPad: Bool) -> CGFloat { isPad ? 11 : 8 }

    static func depth(size: CGSize, waterline: CGFloat, isPad: Bool) -> CGFloat {
        max(1, size.height - waterline + amplitude(isPad: isPad) * 2)
    }
}

/// A travelling wave. `phase` is world distance, so passing the shared
/// `worldOffset` (times a parallax) is all it takes to make the sea scroll.
struct WaveEdge: Shape {
    var phase: CGFloat = 0
    var wavelength: CGFloat = 52

    func path(in rect: CGRect) -> Path {
        var path = Path()
        var x = rect.minX - wavelength + phase.truncatingRemainder(dividingBy: wavelength)
        path.move(to: CGPoint(x: x, y: rect.midY))
        while x < rect.maxX + wavelength {
            path.addCurve(to: CGPoint(x: x + wavelength, y: rect.midY),
                          control1: CGPoint(x: x + wavelength * 0.25, y: rect.minY),
                          control2: CGPoint(x: x + wavelength * 0.75, y: rect.maxY))
            x += wavelength
        }
        return path
    }
}

/// The filled body of water. Its top edge is the same travelling wave, drawn
/// around `amplitude` so the caller can line the crest up with the waterline.
struct WaterBodyShape: Shape {
    var phase: CGFloat = 0
    var amplitude: CGFloat = 9
    var wavelength: CGFloat = 58

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let amp = min(amplitude, rect.height * 0.4)
        let start = rect.minX - wavelength + phase.truncatingRemainder(dividingBy: wavelength)
        var x = start
        path.move(to: CGPoint(x: x, y: amp))
        while x < rect.maxX + wavelength {
            path.addCurve(to: CGPoint(x: x + wavelength, y: amp),
                          control1: CGPoint(x: x + wavelength * 0.25, y: 0),
                          control2: CGPoint(x: x + wavelength * 0.75, y: amp * 2))
            x += wavelength
        }
        path.addLine(to: CGPoint(x: x, y: rect.maxY))
        path.addLine(to: CGPoint(x: start, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Splash

enum WaterSplashDirection: Equatable { case entering, exiting }

/// The original soft water splash, driven by the newer event-based crossing
/// logic so quick successive dives can still overlap reliably.
struct WaterSplash: View {
    let direction: WaterSplashDirection
    let strength: CGFloat
    let reduceMotion: Bool
    /// Trailer capture renders arbitrary frames offscreen, so it can supply
    /// the same splash at an exact 0...1 point without relying on wall-clock
    /// SwiftUI animation. Normal gameplay leaves this nil and behaves exactly
    /// as before.
    var deterministicProgress: CGFloat? = nil
    @State private var expanded = false

    static func life(direction: WaterSplashDirection,
                     strength: CGFloat,
                     reduceMotion: Bool) -> Double {
        if reduceMotion { return 0.18 }
        return direction == .exiting ? 0.72 : 0.62
    }

    private var clamped: CGFloat { min(1, max(0, strength)) }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let energy = 0.76 + clamped * 0.24
            let lift = height * (direction == .exiting ? 0.78 : 0.54) * energy
            let progress = min(1, max(0, deterministicProgress ?? (expanded ? 1 : 0)))
            ZStack {
                Ellipse()
                    .stroke(.white.opacity(0.92), lineWidth: max(3, width * 0.035))
                    .frame(width: width * 0.68, height: height * 0.24)
                    .scaleEffect(0.28 + progress * (1.35 - 0.28))

                ForEach(0..<9, id: \.self) { index in
                    let spread = (CGFloat(index) - 4) / 4
                    Capsule()
                        .fill(LinearGradient(colors: [.white,
                                                      Color.cyan.opacity(0.82)],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: max(5, width * 0.045),
                               height: height * (direction == .exiting ? 0.34 : 0.25) * energy)
                        .rotationEffect(.degrees(Double(spread) * 52))
                        .offset(x: progress * spread * width * 0.42,
                                y: height * 0.08
                                    + progress * (-lift * (1 - abs(spread) * 0.38) - height * 0.08))
                }

                ForEach(0..<7, id: \.self) { index in
                    let spread = (CGFloat(index) - 3) / 3
                    Circle()
                        .fill(.white.opacity(0.88))
                        .frame(width: max(4, width * 0.055),
                               height: max(4, width * 0.055))
                        .offset(x: progress * spread * width * 0.52,
                                y: progress * (-lift * 0.56 - abs(spread) * height * 0.16))
                }
            }
            .frame(width: width, height: height)
            .position(x: width * 0.5, y: height * 0.55)
            .opacity(1 - progress)
            .animation(deterministicProgress == nil
                       ? (reduceMotion ? .easeOut(duration: 0.18)
                          : .easeOut(duration: direction == .exiting ? 0.72 : 0.62))
                       : nil,
                       value: expanded)
        }
        .onAppear {
            if deterministicProgress == nil { expanded = true }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Launch pad

/// The island the cannon is rolled onto. A built launch site rather than a bare
/// floe: a mass with a flat deck standing clear of the water, a hazard stripe
/// along its front edge in the cannon's own livery, and a face dropping into the
/// water. The silhouette is the same in every world — the cannon has to look
/// like the same cannon on the same launch site — and only the material changes:
/// ice, mossy stone, sun-baked rock, decking, poured concrete.
///
/// The frame's own waterline is `PolarScene.padWaterline`; everything above it
/// is the deck the cannon stands on and everything below is the cliff, so the
/// caller only has to line those two fractions up with the water.
struct CannonLaunchPad: View {
    let theme: SceneryTheme

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height
            ZStack {
                LaunchPadUnderside()
                    .fill(LinearGradient(colors: [theme.pad.deep.opacity(0.92),
                                                  theme.water.mid.opacity(0.62)],
                                         startPoint: .top, endPoint: .bottom))

                // The gradient's stops are pinned to the waterline, so the rock
                // darkens exactly where the water starts. A single top-to-bottom
                // wash left the whole thing pale, which is what made it read as
                // the hull of a boat rather than as land.
                LaunchPadDeck()
                    .fill(LinearGradient(stops: [
                        .init(color: theme.pad.light, location: 0.10),
                        .init(color: theme.pad.light, location: 0.34),
                        .init(color: theme.pad.mid, location: PolarScene.padWaterline),
                        .init(color: theme.pad.deep.opacity(0.95), location: 0.56),
                        .init(color: theme.water.mid.opacity(0.85), location: 1)
                    ], startPoint: .top, endPoint: .bottom))
                    .overlay(LaunchPadDeck().stroke(theme.pad.light,
                                                    lineWidth: max(2, w * 0.007)))

                // A shaded plane down the right of the berg. The material reads
                // as solid because it has facets catching the light differently.
                LaunchPadShadedFace()
                    .fill(theme.pad.mid.opacity(0.45))

                LaunchPadFacets()
                    .stroke(theme.pad.deep.opacity(0.32),
                            style: StrokeStyle(lineWidth: max(1.5, w * 0.005),
                                               lineCap: .round,
                                               lineJoin: .round))

                LaunchPadSurface(style: theme.pad.style,
                                 cap: theme.pad.cap,
                                 width: w,
                                 height: h)

                // Where the water meets the launch site.
                Capsule()
                    .fill(theme.water.foam.opacity(0.88))
                    .frame(width: w * 0.80, height: max(3, h * 0.05))
                    .position(x: w * 0.5, y: h * PolarScene.padWaterline)

                // Loose pieces floating off the near edge, in whatever this
                // world's water carries.
                ForEach(0..<2, id: \.self) { index in
                    let side: CGFloat = index == 0 ? -1 : 1
                    SceneryFloater(style: theme.floater,
                                   water: theme.water,
                                   seed: index &* 13 &+ 3,
                                   isPad: false,
                                   showsFoam: true)
                        .frame(width: w * 0.19, height: h * 0.46)
                        .position(x: w * (0.5 + side * 0.58),
                                  y: h * (PolarScene.padWaterline
                                          + 0.46 * (0.5 - theme.floater.surfaceFraction)))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// What covers the deck. A handful of marks is enough: the eye only needs to be
/// told whether it is looking at snow, moss, sand, planking or tile.
private struct LaunchPadSurface: View {
    let style: SceneryPadStyle
    let cap: Color
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        let w = width
        let h = height
        ZStack {
            switch style {
            case .snow:
                // The ice pad is already white; a cap layer would only flatten it.
                EmptyView()
            case .moss, .blossom:
                ForEach(0..<4, id: \.self) { index in
                    let wobble = PolarScene.jitter(index &* 83)
                    Ellipse()
                        .fill(cap.opacity(0.85))
                        .frame(width: w * (0.13 + abs(wobble) * 0.06), height: h * 0.055)
                        .position(x: w * (0.26 + CGFloat(index) * 0.17 + wobble * 0.02),
                                  y: h * (0.19 + CGFloat(index % 2) * 0.03))
                }
            case .sand, .rock:
                ForEach(0..<5, id: \.self) { index in
                    let wobble = PolarScene.jitter(index &* 89 &+ 4)
                    Circle()
                        .fill(cap.opacity(0.70))
                        .frame(width: w * (0.020 + abs(wobble) * 0.014))
                        .position(x: w * (0.24 + CGFloat(index) * 0.14 + wobble * 0.02),
                                  y: h * (0.22 + CGFloat(index % 3) * 0.035))
                }
            case .plank:
                ForEach(0..<3, id: \.self) { index in
                    Capsule()
                        .fill(cap.opacity(0.55))
                        .frame(width: w * 0.62, height: max(1.5, h * 0.012))
                        .position(x: w * 0.52, y: h * (0.19 + CGFloat(index) * 0.045))
                }
            case .tile:
                ForEach(0..<5, id: \.self) { index in
                    Capsule()
                        .fill(cap.opacity(0.75))
                        .frame(width: max(1.2, w * 0.006), height: h * 0.10)
                        .position(x: w * (0.32 + CGFloat(index) * 0.10), y: h * 0.22)
                }
                Capsule()
                    .fill(cap.opacity(0.75))
                    .frame(width: w * 0.52, height: max(1.2, h * 0.010))
                    .position(x: w * 0.52, y: h * 0.22)
            }
        }
    }
}

/// A berg, not a jetty: an angular crest with a cut-flat middle for the cannon
/// to stand on, over an ice face that tapers inward as it drops into the sea.
private struct LaunchPadDeck: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        var path = Path()
        path.move(to: CGPoint(x: w * 0.02, y: h * 0.40))
        path.addLine(to: CGPoint(x: w * 0.11, y: h * 0.27))
        path.addLine(to: CGPoint(x: w * 0.17, y: h * 0.11))
        path.addLine(to: CGPoint(x: w * 0.245, y: h * 0.215))
        // The levelled strip the wheels rest on.
        path.addLine(to: CGPoint(x: w * 0.32, y: h * 0.155))
        path.addLine(to: CGPoint(x: w * 0.70, y: h * PolarScene.padDeckFraction))
        path.addLine(to: CGPoint(x: w * 0.775, y: h * 0.075))
        path.addLine(to: CGPoint(x: w * 0.855, y: h * 0.235))
        path.addLine(to: CGPoint(x: w * 0.915, y: h * 0.165))
        path.addLine(to: CGPoint(x: w * 0.98, y: h * 0.40))
        // A ragged, tapering keel. A straight bottom edge under a straight top
        // edge is a hull, however the ice above it is shaped.
        path.addLine(to: CGPoint(x: w * 0.88, y: h * 0.60))
        path.addLine(to: CGPoint(x: w * 0.76, y: h * 0.78))
        path.addLine(to: CGPoint(x: w * 0.60, y: h * 0.64))
        path.addLine(to: CGPoint(x: w * 0.45, y: h * 0.80))
        path.addLine(to: CGPoint(x: w * 0.30, y: h * 0.66))
        path.addLine(to: CGPoint(x: w * 0.18, y: h * 0.76))
        path.closeSubpath()
        return path
    }
}

/// The right-hand planes of the berg, turned away from the low polar sun.
private struct LaunchPadShadedFace: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        var path = Path()
        path.move(to: CGPoint(x: w * 0.775, y: h * 0.075))
        path.addLine(to: CGPoint(x: w * 0.855, y: h * 0.235))
        path.addLine(to: CGPoint(x: w * 0.915, y: h * 0.165))
        path.addLine(to: CGPoint(x: w * 0.98, y: h * 0.40))
        path.addLine(to: CGPoint(x: w * 0.88, y: h * 0.60))
        path.addLine(to: CGPoint(x: w * 0.80, y: h * 0.62))
        path.closeSubpath()

        path.move(to: CGPoint(x: w * 0.17, y: h * 0.11))
        path.addLine(to: CGPoint(x: w * 0.245, y: h * 0.215))
        path.addLine(to: CGPoint(x: w * 0.225, y: h * 0.68))
        path.addLine(to: CGPoint(x: w * 0.175, y: h * 0.66))
        path.closeSubpath()
        return path
    }
}

private struct LaunchPadUnderside: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        var path = Path()
        path.move(to: CGPoint(x: w * 0.17, y: h * 0.58))
        path.addLine(to: CGPoint(x: w * 0.27, y: h * 0.96))
        path.addLine(to: CGPoint(x: w * 0.42, y: h * 0.88))
        path.addLine(to: CGPoint(x: w * 0.54, y: h * 1.04))
        path.addLine(to: CGPoint(x: w * 0.68, y: h * 0.86))
        path.addLine(to: CGPoint(x: w * 0.79, y: h * 0.96))
        path.addLine(to: CGPoint(x: w * 0.86, y: h * 0.58))
        path.closeSubpath()
        return path
    }
}

/// The couple of cracks that keep the ice face from reading as a painted board.
private struct LaunchPadFacets: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        var path = Path()
        path.move(to: CGPoint(x: w * 0.245, y: h * 0.215))
        path.addLine(to: CGPoint(x: w * 0.225, y: h * 0.68))
        path.move(to: CGPoint(x: w * 0.855, y: h * 0.235))
        path.addLine(to: CGPoint(x: w * 0.80, y: h * 0.62))
        path.move(to: CGPoint(x: w * 0.55, y: h * 0.165))
        path.addLine(to: CGPoint(x: w * 0.58, y: h * 0.70))
        return path
    }
}
