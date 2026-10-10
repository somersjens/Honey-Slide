//
//  SceneryAir.swift
//  Flying Penguin
//
//  The sky's own inhabitants: the cloud silhouettes each world uses, and the
//  small things drifting between them — gulls over the lagoon, dragonflies over
//  the pond, petals over the blossom garden, stars over the reef at dusk.
//
//  All of it is slow, small and low in contrast. The answer rings cross this
//  band, and nothing up here may compete with them.
//

import SwiftUI

// MARK: - Clouds

/// A cartoon cloud in one theme's colours. Lobes unioned by a single non-zero
/// fill, with a cooler copy peeking out below for volume.
struct SceneryCloud: View {
    let seed: Int
    let style: SceneryCloudStyle
    let light: Color
    let shade: Color

    var body: some View {
        GeometryReader { proxy in
            let h = proxy.size.height
            ZStack {
                SceneryCloudShape(seed: seed, style: style)
                    .fill(shade)
                    .offset(y: h * 0.09)
                SceneryCloudShape(seed: seed, style: style)
                    .fill(LinearGradient(colors: [light, light.opacity(0.86)],
                                         startPoint: .top, endPoint: .bottom))
            }
        }
    }
}

private struct SceneryCloudShape: Shape {
    let seed: Int
    let style: SceneryCloudStyle

    /// Round and tall, or long and flat. Everything else about the cloud is
    /// shared, which is what keeps ten worlds looking like one game.
    private var lobes: [(x: CGFloat, y: CGFloat, r: CGFloat)] {
        switch style {
        case .puffy:
            return [(0.30, 0.58, 0.175), (0.50, 0.50, 0.225),
                    (0.71, 0.60, 0.180), (0.845, 0.66, 0.115)]
        case .wispy:
            return [(0.22, 0.66, 0.115), (0.42, 0.60, 0.150),
                    (0.62, 0.63, 0.130), (0.80, 0.68, 0.095)]
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        let baseTop: CGFloat
        switch style {
        case .puffy:
            baseTop = 0.60
        case .wispy:
            baseTop = 0.68
        }
        // The lobes carry the silhouette; the base only closes the flat bottom
        // they all rest on.
        path.addRoundedRect(in: CGRect(x: w * 0.16, y: h * baseTop,
                                       width: w * 0.70, height: h * (0.93 - baseTop)),
                            cornerSize: CGSize(width: h * 0.30, height: h * 0.30))
        for (index, lobe) in lobes.enumerated() {
            let wobble = PolarScene.jitter(seed &* 5 &+ index)
            let radius = (lobe.r + wobble * 0.020) * w
            let centre = CGPoint(x: lobe.x * w, y: (lobe.y + wobble * 0.04) * h)
            path.addEllipse(in: CGRect(x: centre.x - radius,
                                       y: centre.y - radius,
                                       width: radius * 2,
                                       height: radius * 2))
        }
        return path
    }
}

// MARK: - Drifting air

/// Whatever the theme puts between the clouds and the water.
struct SceneryAirLayer: View {
    let size: CGSize
    let worldOffset: CGFloat
    let style: SceneryAirStyle
    let tint: Color

    var body: some View {
        ZStack {
            switch style {
            case .none:
                EmptyView()
            case .birds:
                birds
            case .dragonflies:
                dragonflies
            case .petals:
                drifters(count: 8, parallax: 0.50, isLeaf: false)
            case .leaves:
                drifters(count: 7, parallax: 0.58, isLeaf: true)
            case .stars:
                stars
            }
        }
        .allowsHitTesting(false)
    }

    /// A skein of gulls. Two strokes each — any more detail at this size only
    /// reads as noise.
    ///
    /// They travel faster than the clouds rather than slower: a bird is not a
    /// distant object being passed, it is flying under its own power, and at
    /// cloud parallax it hung in the sky like a sticker.
    private var birds: some View {
        let count = 4
        let heights: [CGFloat] = [0.11, 0.19, 0.14, 0.24]
        return ForEach(0..<count, id: \.self) { index in
            let wobble = PolarScene.jitter(index &* 61)
            let width = size.width * (0.045 + abs(wobble) * 0.018)
            BirdMark()
                .stroke(tint.opacity(0.42 + Double(abs(wobble)) * 0.20),
                        style: StrokeStyle(lineWidth: max(1.4, width * 0.075),
                                           lineCap: .round))
                .frame(width: width, height: width * 0.42)
                .position(x: PolarScene.scrollX(index: index,
                                                count: count,
                                                width: size.width,
                                                worldOffset: worldOffset,
                                                parallax: 0.55 + abs(wobble) * 0.20,
                                                margin: width),
                          // A slow rise and fall over the glide, so the skein
                          // is never a straight line of identical marks.
                          y: size.height * heights[index]
                             + CGFloat(sin(Double(worldOffset) * 0.014 + Double(index))) * size.height * 0.020)
        }
    }

    /// Low over the water, where a pond's dragonflies actually hunt. Kept small:
    /// at any size where the wings are individually readable, the body becomes a
    /// dash flying across the answer column.
    private var dragonflies: some View {
        let count = 3
        let heights: [CGFloat] = [0.66, 0.78, 0.71]
        return ForEach(0..<count, id: \.self) { index in
            let wobble = PolarScene.jitter(index &* 67 &+ 3)
            let width = size.width * (0.026 + abs(wobble) * 0.008)
            Dragonfly(tint: tint)
                .frame(width: width, height: width * 0.55)
                .position(x: PolarScene.scrollX(index: index,
                                                count: count,
                                                width: size.width,
                                                worldOffset: worldOffset,
                                                parallax: 0.42,
                                                margin: width),
                          y: size.height * heights[index]
                             + CGFloat(sin(Double(worldOffset) * 0.035 + Double(index) * 2)) * size.height * 0.022)
        }
    }

    /// Petals or leaves, tumbling as they cross. The rotation is driven by the
    /// world offset, so they stop turning exactly when the world stops moving.
    private func drifters(count: Int, parallax: CGFloat, isLeaf: Bool) -> some View {
        ForEach(0..<count, id: \.self) { index in
            let wobble = PolarScene.jitter(index &* 71 &+ 5)
            let width = size.width * (0.022 + abs(wobble) * 0.012)
            Group {
                if isLeaf {
                    LeafShape()
                        .fill(tint.opacity(0.75 + Double(abs(wobble)) * 0.2))
                } else {
                    Ellipse()
                        .fill(tint.opacity(0.70 + Double(abs(wobble)) * 0.25))
                }
            }
            .frame(width: width, height: width * (isLeaf ? 0.58 : 0.68))
            .rotationEffect(.degrees(Double(worldOffset) * (0.5 + Double(abs(wobble))) + Double(index) * 47))
            .position(x: PolarScene.scrollX(index: index,
                                            count: count,
                                            width: size.width,
                                            worldOffset: worldOffset,
                                            parallax: parallax,
                                            margin: width * 2),
                      y: size.height * (0.16 + CGFloat(index) * 0.075)
                         + CGFloat(sin(Double(worldOffset) * 0.022 + Double(index))) * size.height * 0.030)
        }
    }

    /// Fixed points of light: the only layer in the scene that does not move,
    /// because nothing this far away would.
    private var stars: some View {
        ForEach(0..<11, id: \.self) { index in
            let wobble = PolarScene.jitter(index &* 73 &+ 9)
            Circle()
                .fill(tint.opacity(0.35 + Double(abs(wobble)) * 0.45))
                .frame(width: max(1.5, size.width * (0.004 + abs(wobble) * 0.004)))
                .position(x: size.width * CGFloat((index &* 37 &+ 11) % 100) / 100,
                          y: size.height * (0.03 + CGFloat((index &* 53 &+ 7) % 100) / 100 * 0.34))
        }
    }
}

private struct BirdMark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY * 0.35))
        path.addQuadCurve(to: CGPoint(x: rect.midX, y: rect.maxY * 0.75),
                          control: CGPoint(x: rect.width * 0.26, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY * 0.35),
                          control: CGPoint(x: rect.width * 0.74, y: rect.minY))
        return path
    }
}

/// Four wings crossing a short body. Anything longer read as a dash with a
/// smudge over it rather than as an insect.
private struct Dragonfly: View {
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height
            ZStack {
                ForEach(0..<4, id: \.self) { index in
                    let isFront = index < 2
                    Ellipse()
                        .fill(Color.white.opacity(0.72))
                        .overlay(Ellipse().stroke(tint.opacity(0.35), lineWidth: 0.6))
                        .frame(width: w * 0.40, height: h * 0.26)
                        .rotationEffect(.degrees(index.isMultiple(of: 2) ? -26 : 26))
                        .position(x: w * (isFront ? 0.40 : 0.60),
                                  y: h * (index.isMultiple(of: 2) ? 0.32 : 0.62))
                }
                Capsule()
                    .fill(tint)
                    .frame(width: w * 0.60, height: max(1.5, h * 0.14))
                    .position(x: w * 0.52, y: h * 0.48)
                Circle()
                    .fill(tint)
                    .frame(width: max(2.5, h * 0.30))
                    .position(x: w * 0.20, y: h * 0.48)
            }
        }
    }
}
