//
//  SceneryFloaters.swift
//  Flying Penguin
//
//  What floats on the water in each world: ice in the polar sea, lily pads in
//  the pond, a beach ball in the lagoon, enrichment toys in the zoo basin.
//
//  Bands and parallax are identical everywhere, so every theme keeps exactly the
//  depth cues the polar sea was tuned with — only the object changes. Each style
//  brings its own colours: a style belongs to one theme, so a lily pad may
//  simply be green instead of routing that through the palette.
//

import SwiftUI

/// Which side of the sea's own surface a band of floating objects is drawn on.
enum FloaterDepth {
    /// Behind the water foreground: these sit on the crest, and the wash sinks
    /// their lower half for free.
    case behind
    /// In front of it, and lower in the strip — the nearest objects, the ones
    /// that turn a flat shelf into things actually floating in the water.
    case front
}

/// The floating objects for one theme, at three distances. Everything rides the
/// shared conveyor; the further a band is, the slower it goes.
struct DriftingFloaters: View {
    let size: CGSize
    let waterline: CGFloat
    let worldOffset: CGFloat
    let isPad: Bool
    let depth: FloaterDepth
    let theme: SceneryTheme
    var exclusionXs: [CGFloat] = []
    var exclusionSpacing: CGFloat? = nil

    private let farCount = 5
    private let midCount = 4
    // Kept low on purpose: this band is drawn over the water and therefore over
    // a diving character too. Two objects read as depth; more of them start
    // covering the moment the player most needs to see.
    private let nearCount = 2

    var body: some View {
        ZStack {
            switch depth {
            case .behind:
                ForEach(0..<farCount, id: \.self) { index in
                    floater(seed: index &* 5,
                            width: size.width * (0.070 + PolarScene.jitter(index &* 17) * 0.016),
                            height: size.height * (0.055 + PolarScene.jitter(index &* 9 &+ 3) * 0.012),
                            index: index,
                            count: farCount,
                            parallax: 0.45,
                            sink: 0,
                            foam: false,
                            opacity: 0.88)
                }
                ForEach(0..<midCount, id: \.self) { index in
                    floater(seed: index &* 7 &+ 2,
                            width: size.width * (0.105 + PolarScene.jitter(index &* 23 &+ 4) * 0.028),
                            height: size.height * (0.082 + PolarScene.jitter(index &* 13 &+ 7) * 0.020),
                            index: index,
                            count: midCount,
                            parallax: 0.78,
                            sink: 0,
                            foam: false,
                            opacity: 1)
                }
            case .front:
                ForEach(0..<nearCount, id: \.self) { index in
                    floater(seed: index &* 11 &+ 5,
                            width: size.width * (0.125 + PolarScene.jitter(index &* 19 &+ 6) * 0.024),
                            height: size.height * (0.082 + PolarScene.jitter(index &* 29 &+ 2) * 0.015),
                            index: index,
                            count: nearCount,
                            parallax: 1.0,
                            sink: size.height * (0.020 + CGFloat(index % 3) * 0.011),
                            foam: true,
                            opacity: 1)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func floater(seed: Int,
                         width: CGFloat,
                         height: CGFloat,
                         index: Int,
                         count: Int,
                         parallax: CGFloat,
                         sink: CGFloat,
                         foam: Bool,
                         opacity: Double) -> some View {
        let x = PolarScene.scrollX(index: index,
                                   count: count,
                                   width: size.width,
                                   worldOffset: worldOffset,
                                   parallax: parallax,
                                   margin: width * 0.8)
        return Group {
            // Foreground objects are selected by their slot, not faded after
            // they have already appeared. Both this band and the hoop corridor
            // move at parallax 1, so the choice remains stable for the complete
            // journey across the screen.
            if isClearOfHoops(x: x, itemWidth: width) {
                SceneryFloater(style: theme.floater,
                               water: theme.water,
                               seed: seed,
                               isPad: isPad,
                               showsFoam: foam)
                    .frame(width: width, height: height)
                    .opacity(opacity)
                    // Lines the object's own waterline up with the sea's — plus
                    // however far in front of it this band floats.
                    .position(x: x,
                              y: waterline + sink
                                  + height * (0.5 - theme.floater.surfaceFraction))
            }
        }
    }

    /// Never create a foreground object in a hoop corridor. The hoops form a
    /// repeating conveyor, so checking the complete repeating corridor rather
    /// than only the sets currently on screen makes this a stable placement
    /// decision. Promoting the preview advances the anchor by exactly one
    /// spacing and therefore cannot make an object appear or disappear.
    private func isClearOfHoops(x: CGFloat, itemWidth: CGFloat) -> Bool {
        switch depth {
        case .behind: return true
        case .front: break
        }
        guard !exclusionXs.isEmpty else { return true }
        let clearRadius = itemWidth * 0.70 + size.width * 0.10
        if let spacing = exclusionSpacing, spacing > 0,
           let anchor = exclusionXs.first {
            let remainder = abs((x - anchor).truncatingRemainder(dividingBy: spacing))
            let distanceToCorridor = min(remainder, spacing - remainder)
            return distanceToCorridor > clearRadius
        }
        return exclusionXs.allSatisfy { abs(x - $0) > clearRadius }
    }
}

extension SceneryFloaterStyle {
    /// Where the water's surface crosses the object's own frame. Buoyant things
    /// (balls, leaves) sit higher in it than heavy ones (logs, ice).
    var surfaceFraction: CGFloat {
        switch self {
        case .iceFloe: return SeaIceBlock.topFraction
        case .lilyPad: return 0.62
        case .petalRaft: return 0.62
        case .poolToy: return 0.66
        case .driftLog: return 0.60
        case .kelpBulb: return 0.60
        case .beachBall: return 0.66
        case .zooBall: return 0.66
        case .mossLog: return 0.60
        case .autumnLeaf: return 0.70
        }
    }
}

/// One floating object.
struct SceneryFloater: View {
    let style: SceneryFloaterStyle
    let water: SceneryTheme.WaterPalette
    let seed: Int
    let isPad: Bool
    var showsFoam = false

    @ViewBuilder
    var body: some View {
        // Only the two near objects need a lifted silhouette. The nine far/mid
        // objects are deliberately low-contrast scenery; grouping and
        // shadowing each one created nine moving offscreen textures per frame.
        if showsFoam {
            content
                .compositingGroup()
                .shadow(color: water.deep.opacity(0.28), radius: 3, y: 2)
        } else {
            content
        }
    }

    private var content: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height
            let line = h * style.surfaceFraction
            ZStack {
                switch style {
                case .iceFloe:
                    SeaIceBlock(seed: seed, isPad: isPad, showsFoam: showsFoam)
                default:
                    // Everything below the surface, seen through the water.
                    Ellipse()
                        .fill(LinearGradient(colors: [water.mid.opacity(0.55),
                                                      water.deep.opacity(0.25)],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: w * 0.62, height: h * 0.34)
                        .position(x: w * 0.5, y: line + h * 0.10)

                    object(width: w, height: h, line: line)

                    if showsFoam {
                        Capsule()
                            .fill(water.foam.opacity(0.90))
                            .frame(width: w * 0.86, height: max(2.5, h * 0.060))
                            .position(x: w * 0.5, y: line + h * 0.015)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func object(width w: CGFloat, height h: CGFloat, line: CGFloat) -> some View {
        switch style {
        case .iceFloe:
            EmptyView()
        case .lilyPad:
            LilyPadFloater(seed: seed, w: w, h: h, line: line)
        case .petalRaft:
            PetalRaftFloater(seed: seed, w: w, h: h, line: line)
        case .poolToy:
            PoolToyFloater(seed: seed, w: w, h: h, line: line)
        case .driftLog:
            DriftLogFloater(seed: seed, w: w, h: h, line: line)
        case .kelpBulb:
            KelpFloater(seed: seed, w: w, h: h, line: line)
        case .beachBall:
            BeachBallFloater(seed: seed, w: w, h: h, line: line)
        case .zooBall:
            ZooBallFloater(seed: seed, w: w, h: h, line: line)
        case .mossLog:
            MossLogFloater(seed: seed, w: w, h: h, line: line)
        case .autumnLeaf:
            AutumnLeafFloater(seed: seed, w: w, h: h, line: line)
        }
    }
}

// MARK: - Pond

/// A lily pad lying flat on the water, notch turned away from the camera, with a
/// lotus opening on roughly every other one.
private struct LilyPadFloater: View {
    let seed: Int
    let w: CGFloat
    let h: CGFloat
    let line: CGFloat

    private var carriesFlower: Bool { seed % 3 != 1 }

    var body: some View {
        ZStack {
            // Brighter than the bank behind it, with a dark rim: a pad in the
            // same green as the reeds simply disappeared into them.
            LilyPadShape(seed: seed)
                .fill(LinearGradient(colors: [Color(red: 0.63, green: 0.86, blue: 0.36),
                                              Color(red: 0.30, green: 0.63, blue: 0.24)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(
                    LilyPadShape(seed: seed)
                        .stroke(Color(red: 0.12, green: 0.34, blue: 0.14).opacity(0.65),
                                lineWidth: max(1, w * 0.012))
                )
                .frame(width: w * 0.96, height: h * 0.44)
                .position(x: w * 0.5, y: line - h * 0.14)

            if carriesFlower {
                ForEach(0..<5, id: \.self) { index in
                    Ellipse()
                        .fill(Color(red: 0.99, green: 0.72, blue: 0.84))
                        .frame(width: w * 0.13, height: h * 0.20)
                        .offset(y: -h * 0.07)
                        .rotationEffect(.degrees(Double(index) * 72))
                        .position(x: w * 0.62, y: line - h * 0.26)
                }
                Circle()
                    .fill(Color(red: 1.00, green: 0.88, blue: 0.36))
                    .frame(width: w * 0.09)
                    .position(x: w * 0.62, y: line - h * 0.26)
            }
        }
    }
}

private struct LilyPadShape: Shape {
    let seed: Int

    func path(in rect: CGRect) -> Path {
        var path = Path()
        // A disc seen at a shallow angle, with the classic wedge cut out of it.
        path.addEllipse(in: rect)
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let notch = PolarScene.jitter(seed) * 0.25
        var wedge = Path()
        wedge.move(to: centre)
        wedge.addLine(to: CGPoint(x: rect.maxX, y: rect.midY - rect.height * (0.34 - notch * 0.2)))
        wedge.addLine(to: CGPoint(x: rect.maxX, y: rect.midY + rect.height * (0.30 + notch * 0.2)))
        wedge.closeSubpath()
        return path.subtracting(wedge)
    }
}

// MARK: - Blossom

/// An open blossom resting on the pond, with a couple of loose petals beside it.
private struct PetalRaftFloater: View {
    let seed: Int
    let w: CGFloat
    let h: CGFloat
    let line: CGFloat

    var body: some View {
        ZStack {
            ForEach(0..<6, id: \.self) { index in
                Ellipse()
                    .fill(index.isMultiple(of: 2)
                          ? Color(red: 0.99, green: 0.74, blue: 0.84)
                          : Color(red: 0.98, green: 0.86, blue: 0.91))
                    .frame(width: w * 0.30, height: h * 0.26)
                    .offset(x: w * 0.16)
                    .rotationEffect(.degrees(Double(index) * 60))
                    .position(x: w * 0.44, y: line - h * 0.16)
            }
            Circle()
                .fill(Color(red: 1.00, green: 0.90, blue: 0.44))
                .frame(width: w * 0.15)
                .position(x: w * 0.44, y: line - h * 0.16)

            // Two petals that came off, riding just behind the flower.
            ForEach(0..<2, id: \.self) { index in
                Ellipse()
                    .fill(Color(red: 0.99, green: 0.80, blue: 0.87))
                    .frame(width: w * 0.20, height: h * 0.11)
                    .rotationEffect(.degrees(index == 0 ? -18 : 12))
                    .position(x: w * (0.82 - CGFloat(index) * 0.06),
                              y: line - h * (0.06 + CGFloat(index) * 0.10))
            }
        }
    }
}

// MARK: - Garden

/// Whatever ended up in the paddling pool: a ball, or the ring the dog chews on.
private struct PoolToyFloater: View {
    let seed: Int
    let w: CGFloat
    let h: CGFloat
    let line: CGFloat

    private var isRing: Bool { seed % 3 == 1 }

    var body: some View {
        let diameter = w * 0.62
        ZStack {
            if isRing {
                Circle()
                    .strokeBorder(Color(red: 0.95, green: 0.42, blue: 0.32),
                                  lineWidth: diameter * 0.22)
                    .frame(width: diameter, height: diameter)
                ForEach(0..<4, id: \.self) { index in
                    Circle()
                        .trim(from: 0, to: 0.09)
                        .stroke(Color.white,
                                style: StrokeStyle(lineWidth: diameter * 0.22))
                        .rotationEffect(.degrees(Double(index) * 90))
                        .frame(width: diameter * 0.78, height: diameter * 0.78)
                }
            } else {
                Circle()
                    .fill(RadialGradient(colors: [Color(red: 0.88, green: 0.95, blue: 0.42),
                                                  Color(red: 0.55, green: 0.74, blue: 0.16)],
                                         center: UnitPoint(x: 0.35, y: 0.30),
                                         startRadius: 0,
                                         endRadius: diameter * 0.7))
                    .frame(width: diameter, height: diameter)
                TennisSeam()
                    .stroke(Color.white.opacity(0.9),
                            style: StrokeStyle(lineWidth: max(1.5, diameter * 0.06),
                                               lineCap: .round))
                    .frame(width: diameter, height: diameter)
            }
        }
        .position(x: w * 0.5, y: line - diameter * 0.30)
    }
}

private struct TennisSeam: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.06, y: rect.midY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - rect.width * 0.06, y: rect.midY),
                          control: CGPoint(x: rect.midX, y: rect.minY - rect.height * 0.22))
        return path
    }
}

// MARK: - Savanna

/// A sun-bleached log with a clump of dry grass caught on it.
private struct DriftLogFloater: View {
    let seed: Int
    let w: CGFloat
    let h: CGFloat
    let line: CGFloat

    var body: some View {
        ZStack {
            Capsule()
                .fill(LinearGradient(colors: [Color(red: 0.76, green: 0.62, blue: 0.40),
                                              Color(red: 0.48, green: 0.36, blue: 0.22)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: w * 0.92, height: h * 0.30)
                .position(x: w * 0.5, y: line - h * 0.10)

            Ellipse()
                .fill(Color(red: 0.62, green: 0.48, blue: 0.30))
                .frame(width: w * 0.13, height: h * 0.26)
                .position(x: w * 0.10, y: line - h * 0.10)

            ForEach(0..<2, id: \.self) { index in
                Capsule()
                    .fill(Color(red: 0.40, green: 0.30, blue: 0.18).opacity(0.45))
                    .frame(width: max(1.2, w * 0.012), height: h * 0.22)
                    .position(x: w * (0.42 + CGFloat(index) * 0.22), y: line - h * 0.10)
            }

            if seed % 3 != 1 {
                GrassTuftShape()
                    .stroke(Color(red: 0.55, green: 0.60, blue: 0.28),
                            style: StrokeStyle(lineWidth: max(1.2, w * 0.012),
                                               lineCap: .round))
                    .frame(width: w * 0.26, height: h * 0.26)
                    .position(x: w * 0.66, y: line - h * 0.36)
            }
        }
    }
}

private struct GrassTuftShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        var path = Path()
        for index in 0..<4 {
            let x = w * (0.18 + CGFloat(index) * 0.22)
            path.move(to: CGPoint(x: x, y: h))
            path.addQuadCurve(to: CGPoint(x: x + CGFloat(index - 2) * w * 0.16, y: 0),
                              control: CGPoint(x: x, y: h * 0.5))
        }
        return path
    }
}

// MARK: - Reef

/// A kelp float: the gas bulb that holds a frond up, with bubbles beside it.
private struct KelpFloater: View {
    let seed: Int
    let w: CGFloat
    let h: CGFloat
    let line: CGFloat

    var body: some View {
        ZStack {
            ForEach(0..<2, id: \.self) { index in
                KelpBlade(bendsLeft: index == 0)
                    .stroke(LinearGradient(colors: [Color(red: 0.30, green: 0.62, blue: 0.42),
                                                    Color(red: 0.14, green: 0.36, blue: 0.30)],
                                           startPoint: .top, endPoint: .bottom),
                            style: StrokeStyle(lineWidth: max(2, w * 0.055), lineCap: .round))
                    .frame(width: w * 0.34, height: h * 0.40)
                    .position(x: w * (0.36 + CGFloat(index) * 0.22), y: line - h * 0.24)
            }

            Ellipse()
                .fill(RadialGradient(colors: [Color(red: 0.60, green: 0.84, blue: 0.62),
                                              Color(red: 0.22, green: 0.48, blue: 0.36)],
                                     center: UnitPoint(x: 0.34, y: 0.30),
                                     startRadius: 0,
                                     endRadius: w * 0.30))
                .frame(width: w * 0.40, height: h * 0.30)
                .position(x: w * 0.46, y: line - h * 0.12)

            ForEach(0..<3, id: \.self) { index in
                let wobble = PolarScene.jitter(seed &* 13 &+ index)
                Circle()
                    .strokeBorder(Color.white.opacity(0.70), lineWidth: max(1, w * 0.014))
                    .frame(width: w * (0.09 + abs(wobble) * 0.05))
                    .position(x: w * (0.76 + wobble * 0.06),
                              y: line - h * (0.10 + CGFloat(index) * 0.13))
            }
        }
    }
}

private struct KelpBlade: Shape {
    let bendsLeft: Bool

    func path(in rect: CGRect) -> Path {
        let sign: CGFloat = bendsLeft ? -1 : 1
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.midX + sign * rect.width * 0.42, y: rect.minY),
                          control: CGPoint(x: rect.midX + sign * rect.width * 0.02,
                                           y: rect.height * 0.40))
        return path
    }
}

// MARK: - Lagoon

/// A beach ball, or a starfish riding a scrap of sandbar.
private struct BeachBallFloater: View {
    let seed: Int
    let w: CGFloat
    let h: CGFloat
    let line: CGFloat

    private var isStarfish: Bool { seed % 3 == 1 }

    var body: some View {
        let diameter = w * 0.60
        ZStack {
            if isStarfish {
                Ellipse()
                    .fill(LinearGradient(colors: [Color(red: 1.00, green: 0.95, blue: 0.80),
                                                  Color(red: 0.92, green: 0.80, blue: 0.58)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: w * 0.86, height: h * 0.22)
                    .position(x: w * 0.5, y: line - h * 0.06)
                StarShape(points: 5)
                    .fill(Color(red: 0.95, green: 0.42, blue: 0.30))
                    .frame(width: w * 0.34, height: w * 0.34)
                    .position(x: w * 0.48, y: line - h * 0.16)
            } else {
                ZStack {
                    Circle()
                        .fill(Color.white)
                    ForEach(0..<4, id: \.self) { index in
                        BallWedge()
                            .fill(index.isMultiple(of: 2)
                                  ? Color(red: 0.94, green: 0.28, blue: 0.24)
                                  : Color(red: 0.20, green: 0.72, blue: 0.86))
                            .rotationEffect(.degrees(Double(index) * 90))
                    }
                    Circle()
                        .fill(Color.white.opacity(0.55))
                        .frame(width: diameter * 0.16)
                        .offset(x: -diameter * 0.22, y: -diameter * 0.24)
                }
                .frame(width: diameter, height: diameter)
                .clipShape(Circle())
                .position(x: w * 0.5, y: line - diameter * 0.32)
            }
        }
    }
}

private struct BallWedge: Shape {
    func path(in rect: CGRect) -> Path {
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        path.move(to: centre)
        path.addArc(center: centre,
                    radius: rect.width * 0.6,
                    startAngle: .degrees(-100),
                    endAngle: .degrees(-46),
                    clockwise: false)
        path.closeSubpath()
        return path
    }
}

private struct StarShape: Shape {
    let points: Int

    func path(in rect: CGRect) -> Path {
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) * 0.5
        let inner = outer * 0.44
        var path = Path()
        for step in 0..<(points * 2) {
            let radius = step.isMultiple(of: 2) ? outer : inner
            let angle = Angle.degrees(Double(step) * 180 / Double(points) - 90).radians
            let point = CGPoint(x: centre.x + cos(angle) * radius,
                                y: centre.y + sin(angle) * radius)
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - Zoo

/// Enrichment toys: the big rubber ball the elephants push around, and the
/// floating log that goes in with it.
private struct ZooBallFloater: View {
    let seed: Int
    let w: CGFloat
    let h: CGFloat
    let line: CGFloat

    private var isLog: Bool { seed % 3 == 1 }

    var body: some View {
        let diameter = w * 0.58
        ZStack {
            if isLog {
                Capsule()
                    .fill(LinearGradient(colors: [Color(red: 0.72, green: 0.58, blue: 0.42),
                                                  Color(red: 0.44, green: 0.33, blue: 0.22)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: w * 0.90, height: h * 0.28)
                    .position(x: w * 0.5, y: line - h * 0.09)
                ForEach(0..<2, id: \.self) { index in
                    Capsule()
                        .fill(Color(red: 0.36, green: 0.27, blue: 0.18).opacity(0.40))
                        .frame(width: max(1.2, w * 0.012), height: h * 0.20)
                        .position(x: w * (0.36 + CGFloat(index) * 0.26), y: line - h * 0.09)
                }
            } else {
                ZStack {
                    Circle()
                        .fill(RadialGradient(colors: [Color(red: 0.58, green: 0.80, blue: 0.95),
                                                      Color(red: 0.16, green: 0.42, blue: 0.70)],
                                             center: UnitPoint(x: 0.34, y: 0.28),
                                             startRadius: 0,
                                             endRadius: diameter * 0.72))
                    Capsule()
                        .fill(Color.white.opacity(0.85))
                        .frame(width: diameter * 1.02, height: diameter * 0.16)
                        .rotationEffect(.degrees(-14))
                    Circle()
                        .fill(Color.white.opacity(0.5))
                        .frame(width: diameter * 0.15)
                        .offset(x: -diameter * 0.21, y: -diameter * 0.25)
                }
                .frame(width: diameter, height: diameter)
                .clipShape(Circle())
                .position(x: w * 0.5, y: line - diameter * 0.32)
            }
        }
    }
}

// MARK: - Mountain lake

/// A waterlogged trunk with moss on its back, or a boulder breaking the surface.
private struct MossLogFloater: View {
    let seed: Int
    let w: CGFloat
    let h: CGFloat
    let line: CGFloat

    private var isBoulder: Bool { seed % 3 == 1 }

    var body: some View {
        ZStack {
            if isBoulder {
                BoulderShape(seed: seed)
                    .fill(LinearGradient(colors: [Color(red: 0.72, green: 0.72, blue: 0.70),
                                                  Color(red: 0.40, green: 0.41, blue: 0.42)],
                                         startPoint: .topLeading,
                                         endPoint: .bottomTrailing))
                    .frame(width: w * 0.70, height: h * 0.40)
                    .position(x: w * 0.5, y: line - h * 0.16)
            } else {
                Capsule()
                    .fill(LinearGradient(colors: [Color(red: 0.58, green: 0.44, blue: 0.30),
                                                  Color(red: 0.32, green: 0.23, blue: 0.15)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: w * 0.94, height: h * 0.30)
                    .position(x: w * 0.5, y: line - h * 0.10)

                Ellipse()
                    .fill(Color(red: 0.45, green: 0.33, blue: 0.22))
                    .frame(width: w * 0.13, height: h * 0.26)
                    .position(x: w * 0.90, y: line - h * 0.10)

                // Moss along the top of the trunk.
                ForEach(0..<3, id: \.self) { index in
                    let wobble = PolarScene.jitter(seed &* 11 &+ index)
                    Ellipse()
                        .fill(Color(red: 0.36, green: 0.58, blue: 0.28).opacity(0.92))
                        .frame(width: w * (0.20 + abs(wobble) * 0.08), height: h * 0.11)
                        .position(x: w * (0.24 + CGFloat(index) * 0.24 + wobble * 0.03),
                                  y: line - h * 0.22)
                }
            }
        }
    }
}

private struct BoulderShape: Shape {
    let seed: Int

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let j: (Int) -> CGFloat = { PolarScene.jitter(seed &* 47 &+ $0) }
        var path = Path()
        path.move(to: CGPoint(x: 0, y: h))
        path.addLine(to: CGPoint(x: w * (0.16 + j(1) * 0.05), y: h * 0.42))
        path.addLine(to: CGPoint(x: w * (0.44 + j(2) * 0.06), y: h * (0.08 + j(3) * 0.06)))
        path.addLine(to: CGPoint(x: w * (0.78 + j(4) * 0.05), y: h * 0.34))
        path.addLine(to: CGPoint(x: w, y: h))
        path.closeSubpath()
        return path
    }
}

// MARK: - Autumn lake

/// Fallen maple leaves lying flat on the water.
private struct AutumnLeafFloater: View {
    let seed: Int
    let w: CGFloat
    let h: CGFloat
    let line: CGFloat

    private let tints: [Color] = [
        Color(red: 0.93, green: 0.44, blue: 0.14),
        Color(red: 0.86, green: 0.24, blue: 0.16),
        Color(red: 0.96, green: 0.74, blue: 0.22)
    ]

    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { index in
                leaf(index: index)
            }
        }
    }

    private func leaf(index: Int) -> some View {
        let wobble = PolarScene.jitter(seed &* 7 &+ index)
        // Sized from the object's height, and never more than twice as long as
        // it is wide. Taking the length from the (much wider) frame turned every
        // leaf into a sliver.
        let length: CGFloat = h * (0.52 + abs(wobble) * 0.12)
        let angle: Double = Double(wobble) * 40 + Double(index) * 22 - 20
        let x: CGFloat = w * (0.28 + CGFloat(index) * 0.24 + wobble * 0.04)
        let y: CGFloat = line - h * (0.12 + CGFloat(index % 2) * 0.07)
        return LeafShape()
            .fill(tints[(seed &+ index) % tints.count])
            .overlay(
                LeafShape()
                    .stroke(Color(red: 0.52, green: 0.26, blue: 0.10).opacity(0.35),
                            lineWidth: max(0.8, h * 0.014))
            )
            .frame(width: length, height: length * 0.58)
            .rotationEffect(.degrees(angle))
            .position(x: x, y: y)
    }
}

/// A simple pointed leaf. Shared with the air layer, where the same shape falls
/// past before it lands on the water.
struct LeafShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        var path = Path()
        // Rounded at the base, pointed at the tip. A shape that comes to a
        // point at both ends reads as a dart at the size these are drawn.
        path.move(to: CGPoint(x: w, y: h * 0.5))
        path.addCurve(to: CGPoint(x: w * 0.04, y: h * 0.5),
                      control1: CGPoint(x: w * 0.58, y: -h * 0.16),
                      control2: CGPoint(x: -w * 0.06, y: h * 0.10))
        path.addCurve(to: CGPoint(x: w, y: h * 0.5),
                      control1: CGPoint(x: -w * 0.06, y: h * 0.90),
                      control2: CGPoint(x: w * 0.58, y: h * 1.16))
        path.closeSubpath()
        return path
    }
}
