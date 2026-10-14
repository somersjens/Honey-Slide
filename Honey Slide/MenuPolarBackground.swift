//
//  MenuPolarBackground.swift
//  Honey Slide
//
//  Shared cream, beeswax and poured-honey finishes for the app's menus.
//  All decoration stays inside the existing layout and never intercepts input.
//

import SwiftUI

enum HoneyMenuPalette {
    static let cream = Color(red: 1.00, green: 0.96, blue: 0.86)
    static let paper = Color(red: 1.00, green: 0.985, blue: 0.94)
    static let gloss = Color(red: 1.00, green: 0.89, blue: 0.62)
    static let honey = Color(red: 0.98, green: 0.72, blue: 0.20)
    static let comb = Color(red: 0.84, green: 0.48, blue: 0.09)
    static let caramel = Color(red: 0.65, green: 0.32, blue: 0.075)
    static let ink = Color(red: 0.35, green: 0.18, blue: 0.065)
    static let mutedInk = Color(red: 0.53, green: 0.36, blue: 0.20)

    static var honeyFill: LinearGradient {
        LinearGradient(stops: [.init(color: gloss, location: 0),
                               .init(color: honey, location: 0.48),
                               .init(color: comb, location: 1)],
                       startPoint: .top, endPoint: .bottom)
    }
    static var creamFill: LinearGradient {
        LinearGradient(colors: [paper, cream],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    static var selectedHoneyFill: LinearGradient {
        LinearGradient(stops: [.init(color: gloss, location: 0),
                               .init(color: honey, location: 0.35),
                               .init(color: honey, location: 0.72),
                               .init(color: Color(red: 0.93, green: 0.59, blue: 0.12), location: 1)],
                       startPoint: .top, endPoint: .bottom)
    }
}

/// Sunlit parchment with connected combs at the edges and a pool of honey
/// below the controls. No landscape silhouettes or scattered star-like flecks.
struct HoneyMenuBackground: View {
    let accent: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(colors: [HoneyMenuPalette.paper,
                                        HoneyMenuPalette.cream,
                                        HoneyMenuPalette.gloss.opacity(0.72)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [.white.opacity(0.94), .clear],
                               center: UnitPoint(x: 0.24, y: 0.13),
                               startRadius: 0,
                               endRadius: proxy.size.width * 0.65)
                HoneyBackdropArtwork()
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct HoneyBackdropArtwork: View {
    var body: some View {
        Canvas { context, size in
            let radius = min(size.width * 0.046, size.height * 0.085)
            // A connected comb fades toward the centre, leaving the copy calm.
            for corner in 0..<2 {
                let anchor = CGPoint(x: corner == 0 ? -radius * 0.2 : size.width + radius * 0.2,
                                     y: corner == 0 ? radius * 0.5 : size.height * 0.74)
                for column in 0..<5 {
                    for row in -2...3 {
                        let inward = (CGFloat(column) + (row.isMultiple(of: 2) ? 0 : 0.5)) * radius * sqrt(3)
                        let x = anchor.x + (corner == 0 ? inward : -inward)
                        let y = anchor.y + CGFloat(row) * radius * 1.5
                        let cell = HoneycombCell().path(in: CGRect(x: x - radius, y: y - radius,
                                                                   width: radius * 2, height: radius * 2))
                        let fade = Double(5 - column) / 5
                        context.fill(cell, with: .color(HoneyMenuPalette.honey.opacity(0.055 * fade)))
                        context.stroke(cell, with: .color(HoneyMenuPalette.comb.opacity(0.17 * fade)),
                                       lineWidth: 1.2)
                    }
                }
            }

            var pool = Path()
            pool.move(to: CGPoint(x: 0, y: size.height * 0.94))
            pool.addCurve(to: CGPoint(x: size.width, y: size.height * 0.84),
                          control1: CGPoint(x: size.width * 0.34, y: size.height * 1.04),
                          control2: CGPoint(x: size.width * 0.64, y: size.height * 0.79))
            pool.addLine(to: CGPoint(x: size.width, y: size.height))
            pool.addLine(to: CGPoint(x: 0, y: size.height))
            pool.closeSubpath()
            context.fill(pool, with: .linearGradient(
                Gradient(colors: [HoneyMenuPalette.honey.opacity(0.22),
                                  HoneyMenuPalette.comb.opacity(0.38)]),
                startPoint: CGPoint(x: 0, y: size.height * 0.83),
                endPoint: CGPoint(x: 0, y: size.height)))
            var shine = Path()
            shine.move(to: CGPoint(x: 0, y: size.height * 0.945))
            shine.addCurve(to: CGPoint(x: size.width, y: size.height * 0.845),
                           control1: CGPoint(x: size.width * 0.34, y: size.height * 1.045),
                           control2: CGPoint(x: size.width * 0.64, y: size.height * 0.795))
            context.stroke(shine, with: .color(.white.opacity(0.65)), lineWidth: 2)
        }
    }
}

/// Warm brown rather than a black/blue veil; the paused course stays visible.
struct HoneyModalBackdrop: View {
    let accent: Color
    var opacity: Double = 1

    var body: some View {
        ZStack {
            HoneyMenuPalette.ink.opacity(0.57 * opacity)
            LinearGradient(colors: [HoneyMenuPalette.gloss.opacity(0.12 * opacity),
                                    .clear,
                                    HoneyMenuPalette.caramel.opacity(0.24 * opacity)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            HoneyBackdropArtwork().opacity(0.45 * opacity)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// An embossed beeswax medallion, with small neighbouring cells. The portrait
/// keeps its footprint; the ornament sits behind it rather than framing a cockpit.
struct HoneyGlowHalo: View {
    let accent: Color
    let diameter: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [HoneyMenuPalette.honey.opacity(0.28), .clear],
                                     center: .center, startRadius: 0,
                                     endRadius: diameter * 0.52))
            HoneycombCell()
                .fill(HoneyMenuPalette.creamFill)
                .overlay {
                    HoneycombCell().stroke(HoneyMenuPalette.honey.opacity(0.75), lineWidth: 2)
                }
                .overlay {
                    HoneycombCell().inset(by: diameter * 0.035)
                        .stroke(.white.opacity(0.9), lineWidth: 1.5)
                }
                .frame(width: diameter * 0.88, height: diameter * 0.88)
                .shadow(color: HoneyMenuPalette.caramel.opacity(0.16), radius: 8, y: 5)
            ForEach(0..<3, id: \.self) { index in
                HoneycombCell()
                    .fill(index == 1 ? HoneyMenuPalette.honey : HoneyMenuPalette.gloss)
                    .overlay { HoneycombCell().stroke(HoneyMenuPalette.comb.opacity(0.5), lineWidth: 1) }
                    .frame(width: diameter * 0.12, height: diameter * 0.12)
                    .offset(x: diameter * (index == 1 ? -0.34 : 0.34),
                            y: diameter * (CGFloat(index) * 0.24 - 0.24))
            }
        }
        .frame(width: diameter, height: diameter)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A continuous honey lip with rounded drips. The drips stay near the edges
/// to keep headings and button labels unobstructed.
private struct HoneySyrupLip: Shape {
    func path(in rect: CGRect) -> Path {
        let base = rect.height * 0.26
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + base))
        for (position, depth, breadth) in [(0.88, 0.58, 0.018), (0.83, 0.96, 0.014),
                                           (0.13, 0.67, 0.017), (0.08, 0.44, 0.012)] {
            let x = rect.minX + rect.width * position
            let half = min(rect.width * breadth, rect.height * 0.25)
            let bottom = rect.minY + rect.height * depth
            path.addLine(to: CGPoint(x: x + half * 1.6, y: rect.minY + base))
            path.addQuadCurve(to: CGPoint(x: x + half, y: rect.minY + base + half),
                              control: CGPoint(x: x + half, y: rect.minY + base))
            path.addLine(to: CGPoint(x: x + half, y: bottom - half))
            path.addQuadCurve(to: CGPoint(x: x - half, y: bottom - half),
                              control: CGPoint(x: x, y: bottom + half))
            path.addLine(to: CGPoint(x: x - half, y: rect.minY + base + half))
            path.addQuadCurve(to: CGPoint(x: x - half * 1.6, y: rect.minY + base),
                              control: CGPoint(x: x - half, y: rect.minY + base))
        }
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + base))
        path.closeSubpath()
        return path
    }
}

/// A rounded reflection follows the surface of pooled honey.
private struct HoneySurfaceReflection: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.width * 0.08, y: rect.height * 0.16))
        path.addCurve(to: CGPoint(x: rect.width * 0.76, y: rect.height * 0.13),
                      control1: CGPoint(x: rect.width * 0.24, y: rect.height * 0.04),
                      control2: CGPoint(x: rect.width * 0.59, y: rect.height * 0.06))
        path.addCurve(to: CGPoint(x: rect.width * 0.29, y: rect.height * 0.36),
                      control1: CGPoint(x: rect.width * 0.83, y: rect.height * 0.24),
                      control2: CGPoint(x: rect.width * 0.48, y: rect.height * 0.26))
        path.addCurve(to: CGPoint(x: rect.width * 0.08, y: rect.height * 0.16),
                      control1: CGPoint(x: rect.width * 0.08, y: rect.height * 0.43),
                      control2: CGPoint(x: rect.width * 0.04, y: rect.height * 0.26))
        path.closeSubpath()
        return path
    }
}

/// Cream controls and amber selections share a shallow caramel bevel.
private struct HoneyControlSurface<Surface: InsettableShape>: ViewModifier {
    let shape: Surface
    let active: Bool
    let honeyLip: Bool

    func body(content: Content) -> some View {
        content
            .background {
                shape.fill(active ? HoneyMenuPalette.caramel.opacity(0.72)
                                  : HoneyMenuPalette.comb.opacity(0.30))
                    .offset(y: active ? 3 : 2)
                shape.fill(active ? HoneyMenuPalette.selectedHoneyFill : HoneyMenuPalette.creamFill)
                    .overlay {
                        if active {
                            HoneySurfaceReflection()
                                .fill(LinearGradient(colors: [HoneyMenuPalette.cream.opacity(0.55),
                                                              HoneyMenuPalette.gloss.opacity(0.12)],
                                                     startPoint: .top, endPoint: .bottom))
                        }
                    }
                    .overlay(alignment: .top) {
                        if honeyLip {
                            HoneySyrupLip()
                                .fill(HoneyMenuPalette.honeyFill)
                                .frame(height: 14)
                        }
                    }
                    .overlay {
                        shape.inset(by: 2)
                            .stroke(active ? HoneyMenuPalette.gloss.opacity(0.65)
                                           : HoneyMenuPalette.paper.opacity(0.85), lineWidth: 1)
                    }
                    .overlay {
                        shape.strokeBorder(active ? HoneyMenuPalette.caramel.opacity(0.58)
                                                  : HoneyMenuPalette.comb.opacity(0.32),
                                           lineWidth: active ? 1.3 : 1)
                    }
                    .clipShape(shape)
            }
            .shadow(color: HoneyMenuPalette.caramel.opacity(active ? 0.16 : 0.06),
                    radius: active ? 5 : 3, y: 3)
    }
}

private struct HoneyMenuPanelModifier: ViewModifier {
    let accent: Color
    let cornerRadius: CGFloat
    let prominent: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                shape.fill(HoneyMenuPalette.comb.opacity(0.27)).offset(y: prominent ? 4 : 2)
                shape.fill(HoneyMenuPalette.creamFill)
                    .overlay(alignment: .bottomTrailing) {
                        HoneyCombWatermark()
                            .frame(width: prominent ? 128 : 88, height: prominent ? 92 : 64)
                            .offset(x: 18, y: 18)
                    }
                    .overlay(alignment: .top) {
                        if prominent {
                            HoneySyrupLip().fill(HoneyMenuPalette.honeyFill)
                                .frame(height: 24)
                                .shadow(color: HoneyMenuPalette.comb.opacity(0.17), radius: 1, y: 2)
                        }
                    }
                    .overlay {
                        shape.inset(by: 3).stroke(.white.opacity(0.8), lineWidth: 1.2)
                    }
                    .clipShape(shape)
                    .overlay { shape.strokeBorder(HoneyMenuPalette.comb.opacity(0.46), lineWidth: 1.3) }
            }
            .shadow(color: HoneyMenuPalette.ink.opacity(prominent ? 0.13 : 0.07),
                    radius: prominent ? 16 : 8, y: prominent ? 8 : 4)
    }
}

private struct HoneyCombWatermark: View {
    var body: some View {
        Canvas { context, size in
            let radius = size.height * 0.24
            for column in 0..<3 {
                for row in 0..<3 {
                    let x = (CGFloat(column) + (row.isMultiple(of: 2) ? 0 : 0.5)) * radius * sqrt(3) + radius
                    let y = CGFloat(row) * radius * 1.5
                    let cell = HoneycombCell().path(in: CGRect(x: x - radius, y: y - radius,
                                                               width: radius * 2, height: radius * 2))
                    context.stroke(cell, with: .color(HoneyMenuPalette.comb.opacity(0.08)), lineWidth: 1)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The same illustrated wooden pot used on the course, at the existing icon
/// size. Menu counters keep its amber cap instead of flattening it to a blob.
struct HoneyMenuCurrencyIcon: View {
    let size: CGFloat

    var body: some View {
        HoneyPotIllustration(showsShadow: false)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct HoneyPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.975 : 1)
            .offset(y: configuration.isPressed ? 2 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension View {
    func honeyMenuPanel(accent: Color, cornerRadius: CGFloat = 28,
                        prominent: Bool = false) -> some View {
        modifier(HoneyMenuPanelModifier(accent: accent, cornerRadius: cornerRadius,
                                        prominent: prominent))
    }

    func honeyControlSurface<S: InsettableShape>(in shape: S,
                                                active: Bool = false,
                                                honeyLip: Bool = false) -> some View {
        modifier(HoneyControlSurface(shape: shape, active: active, honeyLip: honeyLip))
    }
}

/// Point-up hexagons with an inset, also used by the existing reward cards.
struct HoneycombCell: InsettableShape {
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = max(0, min(rect.width, rect.height) / 2 - insetAmount / cos(.pi / 6))
        var path = Path()
        for index in 0..<6 {
            let angle = (Double(index) * 60 - 90) * .pi / 180
            let point = CGPoint(x: center.x + CGFloat(cos(angle)) * radius,
                                y: center.y + CGFloat(sin(angle)) * radius)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }

    func inset(by amount: CGFloat) -> HoneycombCell {
        var cell = self
        cell.insetAmount += amount
        return cell
    }
}

struct HoneyDrip: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.18, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.18, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.midX, y: rect.maxY),
                          control: CGPoint(x: rect.maxX + rect.width * 0.08, y: rect.midY))
        path.addQuadCurve(to: CGPoint(x: rect.minX + rect.width * 0.18, y: rect.minY),
                          control: CGPoint(x: rect.minX - rect.width * 0.08, y: rect.midY))
        path.closeSubpath()
        return path
    }
}

/// Compatibility for existing promo compositions.
struct MenuPolarBackground: View {
    let accent: Color
    var body: some View { HoneyMenuBackground(accent: accent) }
}
