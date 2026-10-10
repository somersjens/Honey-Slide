//
//  SceneryHorizon.swift
//  Flying Penguin
//
//  The band standing on the waterline. Two layers ride the shared conveyor: a
//  hazy far silhouette at a crawl, and the detailed items — reeds, palms, pines,
//  a zoo wall — a little quicker in front of it.
//
//  Everything here stays low in contrast on purpose: the bottom answer ring
//  travels straight through this band, and it has to remain the brightest thing
//  on screen while it does.
//

import SwiftUI

/// The complete horizon for one theme: far ridge plus near detail.
struct SceneryHorizonBand: View {
    let size: CGSize
    let waterline: CGFloat
    let worldOffset: CGFloat
    let theme: SceneryTheme

    private let farCount = 3
    private let nearCount = 4

    var body: some View {
        ZStack {
            ForEach(0..<farCount, id: \.self) { index in
                let width = size.width * (0.52 + PolarScene.jitter(index &* 13) * 0.10)
                let height = size.height * (0.115 + PolarScene.jitter(index &* 7 &+ 2) * 0.030)
                FarRidgeShape(profile: theme.ridge.profile, seed: index &* 3 &+ 1)
                    .fill(LinearGradient(colors: [theme.ridge.far,
                                                  theme.ridge.far.opacity(0.35)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: width, height: height)
                    .opacity(0.55)
                    .position(x: PolarScene.scrollX(index: index,
                                                    count: farCount,
                                                    width: size.width,
                                                    worldOffset: worldOffset,
                                                    parallax: 0.045,
                                                    margin: width * 0.6),
                              // Bottom exactly on the waterline. Any further
                              // down and the shape shows through the water's
                              // translucent near half as a false sea floor.
                              y: waterline - height * 0.5)
            }

            ForEach(0..<nearCount, id: \.self) { index in
                let width = size.width * (0.22 + PolarScene.jitter(index &* 11) * 0.045)
                // Roughly the bottom tenth of an item is taken by the water, so
                // the band is sized for what has to remain visible above it.
                let height = size.height * (0.150 + PolarScene.jitter(index &* 5 &+ 1) * 0.030)
                // Coprime with 3, so the seeds run through every residue: the
                // details pick their variant off `seed % 3`, and a stride of 3
                // handed all four slots the same one.
                SceneryHorizonItem(style: theme.horizon,
                                   palette: theme.ridge,
                                   seed: index &* 7 &+ 1)
                    .frame(width: width, height: height)
                    .opacity(0.92)
                    .position(x: PolarScene.scrollX(index: index,
                                                    count: nearCount,
                                                    width: size.width,
                                                    worldOffset: worldOffset,
                                                    parallax: 0.12,
                                                    margin: width * 0.7),
                              y: waterline - height * 0.5 + height * 0.02)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Far silhouette

/// One hazy shape resting on the waterline. Four profiles cover every world:
/// peaks for ice and mountains, bumps for hills and tree lines, tables for the
/// savanna, a single dome for islands.
struct FarRidgeShape: Shape {
    let profile: SceneryRidgeProfile
    let seed: Int

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let j: (Int) -> CGFloat = { PolarScene.jitter(seed &* 37 &+ $0) }
        var path = Path()
        path.move(to: CGPoint(x: 0, y: h))

        switch profile {
        case .jagged:
            path.addLine(to: CGPoint(x: w * 0.14, y: h * (0.52 + j(1) * 0.12)))
            path.addLine(to: CGPoint(x: w * 0.27, y: h * (0.16 + j(2) * 0.10)))
            path.addLine(to: CGPoint(x: w * 0.40, y: h * (0.46 + j(3) * 0.10)))
            path.addLine(to: CGPoint(x: w * 0.56, y: h * (0.06 + j(4) * 0.06)))
            path.addLine(to: CGPoint(x: w * 0.71, y: h * (0.44 + j(5) * 0.12)))
            path.addLine(to: CGPoint(x: w * 0.85, y: h * (0.24 + j(6) * 0.10)))
            path.addLine(to: CGPoint(x: w, y: h))

        case .rounded:
            path.addCurve(to: CGPoint(x: w * 0.34, y: h),
                          control1: CGPoint(x: w * 0.06, y: h * (0.30 + j(1) * 0.14)),
                          control2: CGPoint(x: w * 0.28, y: h * (0.22 + j(2) * 0.12)))
            path.addCurve(to: CGPoint(x: w * 0.68, y: h),
                          control1: CGPoint(x: w * 0.40, y: h * (0.10 + j(3) * 0.10)),
                          control2: CGPoint(x: w * 0.62, y: h * (0.18 + j(4) * 0.10)))
            path.addCurve(to: CGPoint(x: w, y: h),
                          control1: CGPoint(x: w * 0.74, y: h * (0.34 + j(5) * 0.12)),
                          control2: CGPoint(x: w * 0.96, y: h * (0.26 + j(6) * 0.10)))

        case .mesa:
            path.addLine(to: CGPoint(x: w * 0.10, y: h * (0.54 + j(1) * 0.10)))
            path.addLine(to: CGPoint(x: w * 0.19, y: h * (0.40 + j(2) * 0.08)))
            path.addLine(to: CGPoint(x: w * 0.42, y: h * (0.40 + j(2) * 0.08)))
            path.addLine(to: CGPoint(x: w * 0.50, y: h * 0.62))
            path.addLine(to: CGPoint(x: w * 0.60, y: h * (0.22 + j(3) * 0.08)))
            path.addLine(to: CGPoint(x: w * 0.86, y: h * (0.22 + j(3) * 0.08)))
            path.addLine(to: CGPoint(x: w * 0.95, y: h * 0.56))
            path.addLine(to: CGPoint(x: w, y: h))

        case .island:
            path.addCurve(to: CGPoint(x: w, y: h),
                          control1: CGPoint(x: w * 0.22, y: h * (0.06 + j(1) * 0.06)),
                          control2: CGPoint(x: w * 0.80, y: h * (0.12 + j(2) * 0.08)))
        }

        path.closeSubpath()
        return path
    }
}

// MARK: - Near detail

/// One themed silhouette standing on the waterline, drawn bottom-anchored inside
/// whatever frame the band gives it.
struct SceneryHorizonItem: View {
    let style: SceneryHorizonStyle
    let palette: SceneryTheme.RidgePalette
    let seed: Int

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height
            ZStack {
                switch style {
                case .iceRidge:
                    IceRidgeDetail(palette: palette, seed: seed, w: w, h: h)
                case .reedBank:
                    ReedBankDetail(palette: palette, seed: seed, w: w, h: h)
                case .blossomTrees:
                    BlossomTreeDetail(palette: palette, seed: seed, w: w, h: h)
                case .gardenFence:
                    GardenFenceDetail(palette: palette, seed: seed, w: w, h: h)
                case .acaciaSavanna:
                    AcaciaDetail(palette: palette, seed: seed, w: w, h: h)
                case .seaStacks:
                    SeaStackDetail(palette: palette, seed: seed, w: w, h: h)
                case .palmShore:
                    PalmShoreDetail(palette: palette, seed: seed, w: w, h: h)
                case .zooPavilion:
                    ZooPavilionDetail(palette: palette, seed: seed, w: w, h: h)
                case .pineForest:
                    PineForestDetail(palette: palette, seed: seed, w: w, h: h)
                case .autumnWoods:
                    AutumnWoodDetail(palette: palette, seed: seed, w: w, h: h)
                }
            }
            .frame(width: w, height: h)
        }
    }
}

// MARK: Ice

private struct IceRidgeDetail: View {
    let palette: SceneryTheme.RidgePalette
    let seed: Int
    let w: CGFloat
    let h: CGFloat

    var body: some View {
        DriftIceShape(seed: seed, topFraction: 0.94)
            .fill(LinearGradient(colors: [.white, palette.near.opacity(0.60)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay(
                DriftIceShape(seed: seed, topFraction: 0.94)
                    .stroke(palette.accent.opacity(0.30), lineWidth: max(1, w * 0.008))
            )
            .opacity(0.75)
    }
}

// MARK: Pond

/// A bank of bulrushes: a low mound of growth with cattails standing out of it.
private struct ReedBankDetail: View {
    let palette: SceneryTheme.RidgePalette
    let seed: Int
    let w: CGFloat
    let h: CGFloat

    var body: some View {
        let stems = 6
        ZStack {
            Ellipse()
                .fill(LinearGradient(colors: [palette.near.opacity(0.92),
                                              palette.near],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: w * 0.92, height: h * 0.52)
                .position(x: w * 0.5, y: h * 0.80)

            ForEach(0..<stems, id: \.self) { index in
                let wobble = PolarScene.jitter(seed &* 17 &+ index)
                let x = w * (0.12 + CGFloat(index) * 0.155 + wobble * 0.03)
                let top = h * (0.16 + abs(wobble) * 0.26)
                Group {
                    Capsule()
                        .fill(palette.near.opacity(0.95))
                        .frame(width: max(1.5, w * 0.014), height: h * 0.78 - top)
                        .position(x: x, y: (top + h * 0.78) * 0.5)
                    // The cattail head. Only every other stem carries one, so
                    // the clump reads as reeds rather than as a row of pins.
                    if index % 2 == 0 {
                        Capsule()
                            .fill(palette.accent)
                            .frame(width: w * 0.042, height: h * 0.20)
                            .position(x: x, y: top + h * 0.08)
                    }
                    // A leaf peeling off the stem.
                    ReedBlade(bendsLeft: index.isMultiple(of: 3))
                        .stroke(palette.near.opacity(0.85),
                                style: StrokeStyle(lineWidth: max(1.5, w * 0.013),
                                                   lineCap: .round))
                        .frame(width: w * 0.14, height: h * 0.42)
                        .position(x: x, y: h * 0.60)
                }
            }
        }
    }
}

private struct ReedBlade: Shape {
    let bendsLeft: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let sign: CGFloat = bendsLeft ? -1 : 1
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.midX + sign * rect.width * 0.45,
                                      y: rect.minY),
                          control: CGPoint(x: rect.midX + sign * rect.width * 0.05,
                                           y: rect.height * 0.35))
        return path
    }
}

// MARK: Blossom

private struct BlossomTreeDetail: View {
    let palette: SceneryTheme.RidgePalette
    let seed: Int
    let w: CGFloat
    let h: CGFloat

    var body: some View {
        ZStack {
            // The lawn the trees stand on. Green, not a paler wash of the same
            // pink: without one cool note the whole slot read as a cloud that
            // had sunk to the waterline.
            Ellipse()
                .fill(LinearGradient(colors: [palette.far,
                                              palette.far.opacity(0.75)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: w * 1.02, height: h * 0.36)
                .position(x: w * 0.5, y: h * 0.88)

            ForEach(0..<3, id: \.self) { index in
                RoundTree(canopy: index.isMultiple(of: 2) ? palette.near : palette.accent,
                          highlight: index.isMultiple(of: 2) ? palette.accent : palette.near,
                          trunk: Color(red: 0.42, green: 0.30, blue: 0.25),
                          seed: seed &* 23 &+ index,
                          height: h)
                    .position(x: w * (0.24 + CGFloat(index) * 0.26
                                      + PolarScene.jitter(seed &+ index) * 0.03),
                              y: h * 0.55)
            }
        }
    }
}

/// A tree drawn from the band's height rather than its width. The horizon slots
/// are three times wider than they are tall; a canopy sized off the width came
/// out taller than the whole band and read as a coloured cloud.
private struct RoundTree: View {
    let canopy: Color
    let highlight: Color
    let trunk: Color
    let seed: Int
    let height: CGFloat

    var body: some View {
        let unit = height
        let lobes: [(x: CGFloat, y: CGFloat, r: CGFloat)] = [
            (-0.16, 0.06, 0.17), (0.02, -0.06, 0.21), (0.19, 0.05, 0.16)
        ]
        return ZStack {
            Capsule()
                .fill(trunk)
                .frame(width: max(2, unit * 0.055), height: unit * 0.40)
                .offset(y: unit * 0.20)

            ForEach(lobes.indices, id: \.self) { index in
                let lobe = lobes[index]
                let wobble = PolarScene.jitter(seed &* 7 &+ index)
                Circle()
                    .fill(index == 1 ? canopy : highlight)
                    .frame(width: unit * (lobe.r * 2 + wobble * 0.03))
                    .offset(x: unit * (lobe.x + wobble * 0.02),
                            y: unit * (lobe.y - 0.16))
            }
        }
        .frame(width: unit, height: unit)
    }
}

// MARK: Garden

/// A picket fence panel with a hedge behind it — or, on every third slot, the
/// kennel at the end of the garden.
private struct GardenFenceDetail: View {
    let palette: SceneryTheme.RidgePalette
    let seed: Int
    let w: CGFloat
    let h: CGFloat

    private var showsKennel: Bool { seed % 3 == 1 }

    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { index in
                Ellipse()
                    .fill(palette.near.opacity(index == 1 ? 1 : 0.85))
                    .frame(width: w * 0.46, height: h * (0.44 + CGFloat(index) * 0.05))
                    .position(x: w * (0.22 + CGFloat(index) * 0.28), y: h * 0.78)
            }

            if showsKennel {
                ZStack {
                    RoundedRectangle(cornerRadius: w * 0.02)
                        .fill(palette.accent)
                        .frame(width: w * 0.34, height: h * 0.32)
                        .position(x: w * 0.5, y: h * 0.74)
                    Triangle()
                        .fill(palette.accent.opacity(0.82))
                        .frame(width: w * 0.42, height: h * 0.22)
                        .position(x: w * 0.5, y: h * 0.47)
                    Capsule()
                        .fill(Color.black.opacity(0.35))
                        .frame(width: w * 0.12, height: h * 0.20)
                        .position(x: w * 0.5, y: h * 0.80)
                }
            } else {
                FencePanel()
                    .fill(Color.white.opacity(0.95))
                    .frame(width: w * 0.90, height: h * 0.52)
                    .position(x: w * 0.5, y: h * 0.62)
            }
        }
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct FencePanel: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        var path = Path()
        let pickets = 6
        let pitch = w / CGFloat(pickets)
        for index in 0..<pickets {
            let x = CGFloat(index) * pitch + pitch * 0.18
            let width = pitch * 0.5
            path.addRoundedRect(in: CGRect(x: x, y: h * 0.10, width: width, height: h * 0.90),
                                cornerSize: CGSize(width: width * 0.3, height: width * 0.3))
            // The pointed cap that makes it a garden fence and not a wall.
            path.move(to: CGPoint(x: x, y: h * 0.14))
            path.addLine(to: CGPoint(x: x + width * 0.5, y: 0))
            path.addLine(to: CGPoint(x: x + width, y: h * 0.14))
            path.closeSubpath()
        }
        path.addRect(CGRect(x: 0, y: h * 0.32, width: w, height: h * 0.13))
        path.addRect(CGRect(x: 0, y: h * 0.66, width: w, height: h * 0.13))
        return path
    }
}

// MARK: Savanna

private struct AcaciaDetail: View {
    let palette: SceneryTheme.RidgePalette
    let seed: Int
    let w: CGFloat
    let h: CGFloat

    var body: some View {
        ZStack {
            // Dry ground, in the same warm tone as the far tables.
            Ellipse()
                .fill(palette.far.opacity(0.75))
                .frame(width: w * 0.98, height: h * 0.26)
                .position(x: w * 0.5, y: h * 0.92)

            AcaciaTrunk()
                .stroke(palette.near,
                        style: StrokeStyle(lineWidth: max(2, w * 0.022),
                                           lineCap: .round))
                .frame(width: w * 0.36, height: h * 0.62)
                .position(x: w * 0.46, y: h * 0.62)

            // The flat crown: two stacked ellipses read as the layered canopy
            // an acacia is recognised by.
            Ellipse()
                .fill(palette.accent)
                .frame(width: w * 0.66, height: h * 0.18)
                .position(x: w * 0.46, y: h * 0.30)
            Ellipse()
                .fill(palette.accent.opacity(0.80))
                .frame(width: w * 0.42, height: h * 0.13)
                .position(x: w * 0.52, y: h * 0.20)

            ForEach(0..<3, id: \.self) { index in
                let wobble = PolarScene.jitter(seed &* 19 &+ index)
                GrassTuft()
                    .stroke(palette.near.opacity(0.75),
                            style: StrokeStyle(lineWidth: max(1.4, w * 0.011),
                                               lineCap: .round))
                    .frame(width: w * 0.16, height: h * 0.20)
                    .position(x: w * (0.14 + CGFloat(index) * 0.33 + wobble * 0.04),
                              y: h * 0.86)
            }
        }
    }
}

private struct AcaciaTrunk: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        var path = Path()
        path.move(to: CGPoint(x: w * 0.5, y: h))
        path.addLine(to: CGPoint(x: w * 0.5, y: h * 0.45))
        path.move(to: CGPoint(x: w * 0.5, y: h * 0.45))
        path.addLine(to: CGPoint(x: w * 0.10, y: h * 0.06))
        path.move(to: CGPoint(x: w * 0.5, y: h * 0.45))
        path.addLine(to: CGPoint(x: w * 0.92, y: h * 0.10))
        return path
    }
}

private struct GrassTuft: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        var path = Path()
        for index in 0..<4 {
            let x = w * (0.15 + CGFloat(index) * 0.24)
            let lean = CGFloat(index - 2) * w * 0.14
            path.move(to: CGPoint(x: x, y: h))
            path.addQuadCurve(to: CGPoint(x: x + lean, y: 0),
                              control: CGPoint(x: x, y: h * 0.45))
        }
        return path
    }
}

// MARK: Reef

/// Sea stacks: tall, near-vertical columns worn out of the reef, with a rock
/// arch on every third slot. Everything is sized from the band's height — the
/// slots are three times wider than they are tall, and a stack laid out across
/// that width came out lower than it was wide, which read as a row of humps
/// rather than as standing rock.
private struct SeaStackDetail: View {
    let palette: SceneryTheme.RidgePalette
    let seed: Int
    let w: CGFloat
    let h: CGFloat

    private var showsArch: Bool { seed % 3 == 2 }

    var body: some View {
        ZStack {
            // The shoal the rock stands on, so nothing balances on a point.
            Ellipse()
                .fill(palette.near.opacity(0.55))
                .frame(width: w * 0.82, height: h * 0.20)
                .position(x: w * 0.5, y: h * 0.93)

            if showsArch {
                RockArch()
                    .fill(LinearGradient(colors: [palette.near.opacity(0.82), palette.near],
                                         startPoint: .top, endPoint: .bottom),
                          style: FillStyle(eoFill: true))
                    .frame(width: h * 1.30, height: h * 0.86)
                    .position(x: w * 0.46, y: h * 0.90 - h * 0.43)
            } else {
                ForEach(0..<3, id: \.self) { index in
                    let wobble = PolarScene.jitter(seed &* 41 &+ index)
                    // Never more than about twice as tall as it is wide, or the
                    // column stops reading as rock and turns into a fin.
                    let tall = h * (0.54 + CGFloat(index % 2) * 0.22 + wobble * 0.08)
                    RockColumn(seed: seed &* 7 &+ index)
                        .fill(LinearGradient(colors: [palette.near.opacity(0.78),
                                                      palette.near],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: h * (0.38 + abs(wobble) * 0.12), height: tall)
                        .position(x: w * (0.28 + CGFloat(index) * 0.22 + wobble * 0.03),
                                  y: h * 0.92 - tall * 0.5)
                }
            }

            // Coral clinging to the base: the only saturated note the dusk
            // horizon is allowed.
            ForEach(0..<3, id: \.self) { index in
                let wobble = PolarScene.jitter(seed &* 31 &+ index)
                Circle()
                    .fill(palette.accent.opacity(0.55))
                    .frame(width: h * (0.09 + abs(wobble) * 0.05))
                    .position(x: w * (0.18 + CGFloat(index) * 0.31 + wobble * 0.03),
                              y: h * (0.88 + wobble * 0.03))
            }
        }
    }
}

/// One column: near-vertical sides that taper slightly inward, a chipped top,
/// and a wider foot where the swell has undercut it.
private struct RockColumn: Shape {
    let seed: Int

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let j: (Int) -> CGFloat = { PolarScene.jitter(seed &* 53 &+ $0) }
        var path = Path()
        path.move(to: CGPoint(x: w * 0.02, y: h))
        path.addLine(to: CGPoint(x: w * (0.20 + j(1) * 0.05), y: h * 0.62))
        path.addLine(to: CGPoint(x: w * (0.26 + j(2) * 0.04), y: h * 0.22))
        // The chipped cap.
        path.addLine(to: CGPoint(x: w * (0.45 + j(3) * 0.06), y: h * (0.04 + abs(j(4)) * 0.08)))
        path.addLine(to: CGPoint(x: w * (0.72 + j(5) * 0.05), y: h * (0.13 + abs(j(6)) * 0.07)))
        path.addLine(to: CGPoint(x: w * (0.78 + j(7) * 0.04), y: h * 0.58))
        path.addLine(to: CGPoint(x: w * 0.98, y: h))
        path.closeSubpath()
        return path
    }
}

/// A rock arch, drawn as a solid block with the opening subtracted by the
/// even-odd fill the caller passes in.
private struct RockArch: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        var path = Path()
        // Heavy legs and an uneven crest: a thin even span reads as a croquet
        // hoop, not as rock the sea has bored a hole through.
        path.move(to: CGPoint(x: 0, y: h))
        path.addLine(to: CGPoint(x: w * 0.08, y: h * 0.44))
        path.addLine(to: CGPoint(x: w * 0.22, y: h * 0.16))
        path.addLine(to: CGPoint(x: w * 0.46, y: h * 0.04))
        path.addLine(to: CGPoint(x: w * 0.72, y: h * 0.14))
        path.addLine(to: CGPoint(x: w * 0.88, y: h * 0.40))
        path.addLine(to: CGPoint(x: w, y: h))
        path.closeSubpath()

        // The opening: a round-topped gap that stops short of the waterline.
        path.move(to: CGPoint(x: w * 0.36, y: h))
        path.addLine(to: CGPoint(x: w * 0.38, y: h * 0.62))
        path.addCurve(to: CGPoint(x: w * 0.62, y: h * 0.62),
                      control1: CGPoint(x: w * 0.41, y: h * 0.38),
                      control2: CGPoint(x: w * 0.59, y: h * 0.38))
        path.addLine(to: CGPoint(x: w * 0.64, y: h))
        path.closeSubpath()
        return path
    }
}

// MARK: Lagoon

private struct PalmShoreDetail: View {
    let palette: SceneryTheme.RidgePalette
    let seed: Int
    let w: CGFloat
    let h: CGFloat

    var body: some View {
        ZStack {
            // The sandbar the palms grow out of.
            Ellipse()
                .fill(LinearGradient(colors: [Color(red: 1.00, green: 0.95, blue: 0.80),
                                              Color(red: 0.93, green: 0.82, blue: 0.60)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: w * 0.98, height: h * 0.30)
                .position(x: w * 0.5, y: h * 0.90)

            PalmTree(frond: palette.near, height: h, scale: 1.0, seed: seed)
                .position(x: w * 0.40, y: h * 0.88)
            PalmTree(frond: palette.near, height: h, scale: 0.74, seed: seed &+ 5)
                .position(x: w * 0.68, y: h * 0.89)

            if seed % 3 == 1 {
                // A parasol in the crab's own red, planted in the sand.
                Rectangle()
                    .fill(Color.white.opacity(0.85))
                    .frame(width: max(1.5, w * 0.012), height: h * 0.24)
                    .position(x: w * 0.16, y: h * 0.78)
                Ellipse()
                    .fill(palette.accent)
                    .frame(width: w * 0.24, height: h * 0.12)
                    .position(x: w * 0.16, y: h * 0.66)
            }
        }
    }
}

/// A palm, anchored at the foot of its trunk. The crown is a symmetric fan
/// around the trunk's top: laid out as an arbitrary spread of ellipses beside a
/// separately curved trunk, the two never agreed on where the tree actually
/// stood and every palm looked knocked over.
private struct PalmTree: View {
    let frond: Color
    let height: CGFloat
    let scale: CGFloat
    let seed: Int

    /// Screen angles, measured with 0° pointing right and 270° straight up.
    /// Two nearly horizontal fronds drooping either side, four arcing over the
    /// top — symmetric about the vertical, which is what reads as a palm.
    private let fronds: [Double] = [172, 215, 250, 290, 325, 8]

    var body: some View {
        let unit = height * scale
        let trunkHeight = unit * 0.60
        let lean = unit * 0.09 * (PolarScene.jitter(seed &* 3) > 0 ? 1 : -1)
        let frondLength = unit * 0.34
        return ZStack {
            // The trunk hangs below the stack's centre, so its top lands on the
            // exact point the fronds rotate around.
            PalmTrunk(lean: lean)
                .stroke(Color(red: 0.55, green: 0.40, blue: 0.26),
                        style: StrokeStyle(lineWidth: max(2, unit * 0.055),
                                           lineCap: .round))
                .frame(width: abs(lean) * 2 + unit * 0.10, height: trunkHeight)
                .offset(y: trunkHeight * 0.5)

            ForEach(fronds.indices, id: \.self) { index in
                Ellipse()
                    .fill(index.isMultiple(of: 2) ? frond : frond.opacity(0.82))
                    .frame(width: frondLength, height: frondLength * 0.34)
                    // Offset first, rotate second: the rotation happens about
                    // this stack's centre, which is exactly the trunk's top.
                    .offset(x: frondLength * 0.46)
                    .rotationEffect(.degrees(fronds[index]))
            }
            // Two coconuts where the fronds meet.
            ForEach(0..<2, id: \.self) { index in
                Circle()
                    .fill(Color(red: 0.44, green: 0.31, blue: 0.20))
                    .frame(width: unit * 0.075)
                    .offset(x: unit * (index == 0 ? -0.045 : 0.045), y: unit * 0.045)
            }
        }
        // The stack is centred on the crown; the caller positions the foot.
        .offset(x: lean, y: -trunkHeight)
    }
}

/// The top of the curve sits on the frame's centre line and the foot leans away
/// from it, so the caller can hang the trunk straight under the crown whatever
/// direction it bends.
private struct PalmTrunk: Shape {
    /// How far the foot stands out of plumb, in points.
    let lean: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX - lean, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.midX, y: rect.minY),
                          control: CGPoint(x: rect.midX - lean * 0.9,
                                           y: rect.minY + rect.height * 0.45))
        return path
    }
}

// MARK: Zoo

/// The far side of the basin, read from the water: park trees over a low wall
/// with a visitors' railing, and then one landmark per slot — the viewing
/// window, the keepers' hut, or a line of bunting.
///
/// The wall alone was the whole scene before, and a grey slab on a grey slab is
/// not a zoo. The trees say park, the railing says people stand there, and the
/// landmarks say it is a day out.
private struct ZooPavilionDetail: View {
    let palette: SceneryTheme.RidgePalette
    let seed: Int
    let w: CGFloat
    let h: CGFloat

    private static let leaf = Color(red: 0.28, green: 0.55, blue: 0.33)
    private static let leafLight = Color(red: 0.40, green: 0.66, blue: 0.38)
    private static let glass = Color(red: 0.74, green: 0.90, blue: 0.97)

    var body: some View {
        ZStack {
            // Park trees behind the enclosure.
            ForEach(0..<3, id: \.self) { index in
                RoundTree(canopy: index == 1 ? Self.leafLight : Self.leaf,
                          highlight: index == 1 ? Self.leaf : Self.leafLight,
                          trunk: Color(red: 0.42, green: 0.32, blue: 0.24),
                          seed: seed &* 61 &+ index,
                          height: h * 0.72)
                    .position(x: w * (0.16 + CGFloat(index) * 0.34
                                      + PolarScene.jitter(seed &+ index) * 0.04),
                              y: h * 0.42)
            }

            landmark

            // The enclosure wall, drawn over the trees so they stand behind it.
            RoundedRectangle(cornerRadius: h * 0.05)
                .fill(LinearGradient(colors: [palette.near.opacity(0.80), palette.near],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: w * 0.98, height: h * 0.34)
                .position(x: w * 0.5, y: h * 0.84)

            // Block joints, so the wall reads as masonry rather than a slab.
            ForEach(0..<4, id: \.self) { index in
                Rectangle()
                    .fill(Color.white.opacity(0.18))
                    .frame(width: w * 0.98, height: max(1, h * 0.010))
                    .position(x: w * 0.5, y: h * (0.76 + CGFloat(index) * 0.07))
            }

            // The visitors' railing along the top of the wall.
            Capsule()
                .fill(Color.white.opacity(0.95))
                .frame(width: w * 0.98, height: max(2, h * 0.028))
                .position(x: w * 0.5, y: h * 0.68)
            ForEach(0..<7, id: \.self) { index in
                Rectangle()
                    .fill(Color.white.opacity(0.85))
                    .frame(width: max(1.8, w * 0.014), height: h * 0.10)
                    .position(x: w * (0.08 + CGFloat(index) * 0.14), y: h * 0.72)
            }
        }
    }

    /// One recognisable thing per slot, so a run of enclosures never repeats.
    @ViewBuilder private var landmark: some View {
        switch seed % 3 {
        case 1:
            // The keepers' hut: a striped roof on two posts.
            ForEach(0..<2, id: \.self) { index in
                Rectangle()
                    .fill(Color.white.opacity(0.92))
                    .frame(width: max(2, w * 0.018), height: h * 0.26)
                    .position(x: w * (0.40 + CGFloat(index) * 0.20), y: h * 0.56)
            }
            HStack(spacing: 0) {
                ForEach(0..<6, id: \.self) { index in
                    Rectangle()
                        .fill(index.isMultiple(of: 2) ? palette.accent : Color.white)
                }
            }
            .frame(width: w * 0.34, height: h * 0.22)
            .clipShape(Triangle())
            .position(x: w * 0.50, y: h * 0.32)

        case 2:
            // Bunting strung between two poles.
            ForEach(0..<2, id: \.self) { index in
                Rectangle()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: max(1.8, w * 0.012), height: h * 0.34)
                    .position(x: w * (0.22 + CGFloat(index) * 0.56), y: h * 0.50)
            }
            BuntingLine()
                .stroke(Color.white.opacity(0.9), lineWidth: max(1.5, h * 0.016))
                .frame(width: w * 0.56, height: h * 0.14)
                .position(x: w * 0.50, y: h * 0.38)
            ForEach(0..<6, id: \.self) { index in
                let t = CGFloat(index) / 5
                Triangle()
                    .fill(index.isMultiple(of: 2) ? palette.accent : Color.white.opacity(0.92))
                    .frame(width: h * 0.15, height: h * 0.19)
                    .rotationEffect(.degrees(180))
                    // Hangs off the sag of the line it is strung on.
                    .position(x: w * (0.22 + t * 0.56),
                              y: h * (0.38 + sin(Double(t) * .pi) * 0.10) + h * 0.10)
            }

        default:
            // The viewing window: the pane visitors press their noses against.
            RoundedRectangle(cornerRadius: h * 0.04)
                .fill(Self.glass)
                .overlay(
                    RoundedRectangle(cornerRadius: h * 0.04)
                        .stroke(Color.white.opacity(0.95), lineWidth: max(1.5, h * 0.030))
                )
                .frame(width: w * 0.40, height: h * 0.30)
                .position(x: w * 0.50, y: h * 0.56)
            // A highlight across the glass.
            Capsule()
                .fill(Color.white.opacity(0.55))
                .frame(width: w * 0.10, height: h * 0.05)
                .rotationEffect(.degrees(-24))
                .position(x: w * 0.42, y: h * 0.50)
        }
    }
}

/// The sag of a bunting line between two poles.
private struct BuntingLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                          control: CGPoint(x: rect.midX, y: rect.maxY * 1.6))
        return path
    }
}

// MARK: Pines

private struct PineForestDetail: View {
    let palette: SceneryTheme.RidgePalette
    let seed: Int
    let w: CGFloat
    let h: CGFloat

    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { index in
                let wobble = PolarScene.jitter(seed &* 29 &+ index)
                let scale = 0.78 + CGFloat(index % 2) * 0.30 + wobble * 0.10
                PineTree()
                    .fill(index.isMultiple(of: 2)
                          ? palette.near
                          : palette.near.opacity(0.82))
                    .frame(width: w * 0.34 * scale, height: h * 0.88 * scale)
                    .position(x: w * (0.22 + CGFloat(index) * 0.29 + wobble * 0.03),
                              y: h - h * 0.44 * scale)
            }

            Ellipse()
                .fill(palette.accent.opacity(0.55))
                .frame(width: w * 0.30, height: h * 0.14)
                .position(x: w * 0.86, y: h * 0.92)
        }
    }
}

private struct PineTree: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        var path = Path()
        // Three skirts, each wider than the one above it.
        let tiers: [(top: CGFloat, bottom: CGFloat, half: CGFloat)] = [
            (0.00, 0.34, 0.28), (0.22, 0.62, 0.40), (0.46, 0.90, 0.50)
        ]
        for tier in tiers {
            path.move(to: CGPoint(x: w * 0.5, y: h * tier.top))
            path.addLine(to: CGPoint(x: w * (0.5 + tier.half), y: h * tier.bottom))
            path.addLine(to: CGPoint(x: w * (0.5 - tier.half), y: h * tier.bottom))
            path.closeSubpath()
        }
        path.addRect(CGRect(x: w * 0.44, y: h * 0.86, width: w * 0.12, height: h * 0.14))
        return path
    }
}

// MARK: Autumn

private struct AutumnWoodDetail: View {
    let palette: SceneryTheme.RidgePalette
    let seed: Int
    let w: CGFloat
    let h: CGFloat

    var body: some View {
        ZStack {
            Ellipse()
                .fill(palette.far.opacity(0.80))
                .frame(width: w * 1.02, height: h * 0.30)
                .position(x: w * 0.5, y: h * 0.90)

            // Birch among the maples: pale trunks are what stop the warm
            // canopies from merging into one orange mass.
            ForEach(0..<3, id: \.self) { index in
                RoundTree(canopy: index.isMultiple(of: 2) ? palette.near : palette.accent,
                          highlight: index.isMultiple(of: 2)
                              ? palette.accent
                              : Color(red: 0.86, green: 0.32, blue: 0.16),
                          trunk: index == 1
                              ? Color(red: 0.94, green: 0.92, blue: 0.88)
                              : Color(red: 0.44, green: 0.32, blue: 0.24),
                          seed: seed &* 43 &+ index,
                          height: h)
                    .position(x: w * (0.24 + CGFloat(index) * 0.26
                                      + PolarScene.jitter(seed &+ index) * 0.03),
                              y: h * 0.56)
            }
        }
    }
}
