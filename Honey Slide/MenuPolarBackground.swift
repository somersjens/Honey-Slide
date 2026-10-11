//
//  MenuPolarBackground.swift
//  Honey Slide
//
//  Shared meadow styling for every menu surface. The layout follows Hungry
//  Frog's quiet land backdrop — cream field, soft sun, low hills — and then
//  adds a honey layer: amber light, honeycomb and drips. The old type name
//  stays as a wrapper for promo compositions that still reference it.
//

import SwiftUI

enum HoneyMenuPalette {
    /// Warm cream, a step more golden than the meadow it is based on.
    static let cream = Color(red: 1.00, green: 0.955, blue: 0.84)
    static let meadow = Color(red: 0.76, green: 0.88, blue: 0.58)
    static let honey = Color(red: 0.96, green: 0.74, blue: 0.24)
    static let comb = Color(red: 0.84, green: 0.52, blue: 0.10)
    /// Soft wash used where menu panels used to pick up starlight.
    static let gloss = Color(red: 1.00, green: 0.93, blue: 0.74)
    /// Warm brown ink, readable on the cream panels.
    static let ink = Color(red: 0.36, green: 0.18, blue: 0.04)
    static let mutedInk = ink.opacity(0.67)
}

/// The shared backdrop behind the welcome flow, main menu and Premium sheet.
/// Hills stay low in contrast so controls and longer copy remain easy to read.
struct HoneyMenuBackground: View {
    let accent: Color

    var body: some View {
        GeometryReader { proxy in
            let diameter = max(proxy.size.width, proxy.size.height)

            ZStack {
                HoneyMenuPalette.cream

                Circle()
                    .fill(Color.white.opacity(0.70))
                    .frame(width: proxy.size.width * 0.46,
                           height: proxy.size.width * 0.46)
                    .blur(radius: 18)
                    .offset(x: -proxy.size.width * 0.30,
                            y: -proxy.size.height * 0.32)

                Circle()
                    .fill(HoneyMenuPalette.honey.opacity(0.34))
                    .frame(width: proxy.size.width * 0.22,
                           height: proxy.size.width * 0.22)
                    .blur(radius: 10)
                    .offset(x: -proxy.size.width * 0.22,
                            y: -proxy.size.height * 0.36)

                Ellipse()
                    .fill(HoneyMenuPalette.meadow.opacity(0.55))
                    .frame(width: proxy.size.width * 0.72,
                           height: max(110, proxy.size.height * 0.30))
                    .offset(x: proxy.size.width * 0.22,
                            y: proxy.size.height * 0.46)

                Ellipse()
                    .fill(HoneyMenuPalette.honey.opacity(0.28))
                    .frame(width: proxy.size.width * 0.58,
                           height: max(90, proxy.size.height * 0.22))
                    .offset(x: -proxy.size.width * 0.30,
                            y: proxy.size.height * 0.50)

                Ellipse()
                    .fill(accent.opacity(0.10))
                    .frame(width: proxy.size.width * 0.46,
                           height: max(70, proxy.size.height * 0.16))
                    .offset(x: proxy.size.width * 0.08,
                            y: proxy.size.height * 0.38)

                HoneycombCell()
                    .fill(HoneyMenuPalette.honey.opacity(0.16))
                    .overlay {
                        HoneycombCell()
                            .stroke(HoneyMenuPalette.comb.opacity(0.28), lineWidth: 3)
                    }
                    .frame(width: diameter * 0.42, height: diameter * 0.42)
                    .offset(x: proxy.size.width * 0.46,
                            y: proxy.size.height * 0.42)

                HoneyDrip()
                    .fill(
                        LinearGradient(colors: [HoneyMenuPalette.honey.opacity(0.85),
                                                HoneyMenuPalette.comb.opacity(0.70)],
                                       startPoint: .top,
                                       endPoint: .bottom)
                    )
                    .frame(width: 16, height: 26)
                    .offset(x: proxy.size.width * 0.16,
                            y: -proxy.size.height * 0.47)

                HoneyMenuSprinkles(accent: accent)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A warm veil for cards shown over the playfield. The game stays visible,
/// while the honey wash ties the start and result screens to Home and Premium.
struct HoneyModalBackdrop: View {
    let accent: Color
    var opacity: Double = 1

    var body: some View {
        ZStack {
            Color(red: 0.28, green: 0.14, blue: 0.04).opacity(0.48 * opacity)
            LinearGradient(colors: [HoneyMenuPalette.cream.opacity(0.16 * opacity),
                                    accent.opacity(0.14 * opacity),
                                    HoneyMenuPalette.honey.opacity(0.22 * opacity)],
                           startPoint: .topLeading,
                           endPoint: .bottomTrailing)
            HoneyModalMotif()
                .opacity(0.85 * opacity)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A soft glow behind a menu character, with one honeycomb ring. It keeps the
/// portrait readable without turning the animal into a pilot.
struct HoneyGlowHalo: View {
    let accent: Color
    let diameter: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [accent.opacity(0.30),
                                               HoneyMenuPalette.honey.opacity(0.16),
                                               .clear],
                                     center: .center,
                                     startRadius: 2,
                                     endRadius: diameter * 0.56))
            HoneycombCell()
                .stroke(accent.opacity(0.55), lineWidth: 1.6)
                .frame(width: diameter * 0.78, height: diameter * 0.78)
            Circle()
                .stroke(.white.opacity(0.72), lineWidth: 1.2)
                .frame(width: diameter * 0.58, height: diameter * 0.58)
            HoneyDrip()
                .fill(HoneyMenuPalette.honey)
                .frame(width: max(7, diameter * 0.07),
                       height: max(11, diameter * 0.11))
                .shadow(color: HoneyMenuPalette.comb.opacity(0.45), radius: 3)
                .offset(x: diameter * 0.34, y: diameter * 0.16)
        }
        .frame(width: diameter, height: diameter)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A cream card with an amber rim and a small comb in the corner. Typography
/// stays on the light fill; the honey shows up in the edge and the watermark.
private struct HoneyMenuPanelModifier: ViewModifier {
    let accent: Color
    let cornerRadius: CGFloat
    let prominent: Bool

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(LinearGradient(
                        colors: [.white.opacity(prominent ? 0.94 : 0.86),
                                 HoneyMenuPalette.gloss.opacity(prominent ? 0.92 : 0.78)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(LinearGradient(
                                colors: [accent.opacity(prominent ? 0.08 : 0.05),
                                         .clear,
                                         HoneyMenuPalette.honey.opacity(prominent ? 0.10 : 0.06)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ))
                    }
                    .overlay(alignment: .topTrailing) {
                        HoneycombCell()
                            .fill(HoneyMenuPalette.honey.opacity(0.18))
                            .frame(width: 108, height: 108)
                            .offset(x: 34, y: -42)
                            .clipShape(RoundedRectangle(cornerRadius: cornerRadius,
                                                       style: .continuous))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(
                                LinearGradient(colors: [.white.opacity(0.96),
                                                        HoneyMenuPalette.honey.opacity(0.90),
                                                        accent.opacity(0.72)],
                                               startPoint: .topLeading,
                                               endPoint: .bottomTrailing),
                                lineWidth: prominent ? 2.2 : 1.4
                            )
                    }
            }
            .shadow(color: HoneyMenuPalette.ink.opacity(prominent ? 0.10 : 0.07),
                    radius: prominent ? 16 : 12,
                    y: prominent ? 8 : 6)
            .shadow(color: accent.opacity(prominent ? 0.16 : 0.10),
                    radius: prominent ? 18 : 12,
                    y: 6)
    }
}

extension View {
    func honeyMenuPanel(accent: Color,
                        cornerRadius: CGFloat = 28,
                        prominent: Bool = false) -> some View {
        modifier(HoneyMenuPanelModifier(accent: accent,
                                        cornerRadius: cornerRadius,
                                        prominent: prominent))
    }
}

/// Point-up hex used for combs in the backdrop, panels and level cards.
struct HoneycombCell: Shape {
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        var path = Path()
        for index in 0..<6 {
            let angle = (Double(index) * 60 - 90) * .pi / 180
            let point = CGPoint(x: center.x + CGFloat(cos(angle)) * radius,
                                y: center.y + CGFloat(sin(angle)) * radius)
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        path.closeSubpath()
        return path
    }
}

/// A hanging drop. The flat top is the comb it leaves; the curve is the drip.
struct HoneyDrip: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.18, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.18, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.midX, y: rect.maxY),
                          control: CGPoint(x: rect.maxX + rect.width * 0.08,
                                           y: rect.midY))
        path.addQuadCurve(to: CGPoint(x: rect.minX + rect.width * 0.18, y: rect.minY),
                          control: CGPoint(x: rect.minX - rect.width * 0.08,
                                           y: rect.midY))
        path.closeSubpath()
        return path
    }
}

/// Leaves from the meadow, plus honeycomb and drips. Positions are fixed so
/// the field does not jump when SwiftUI redraws a screen.
private struct HoneyMenuSprinkles: View {
    let accent: Color

    var body: some View {
        GeometryReader { proxy in
            ForEach(0..<14, id: \.self) { index in
                let x = proxy.size.width * CGFloat((index * 37 + 9) % 100) / 100
                let y = proxy.size.height * CGFloat((index * 53 + 17) % 100) / 100
                sprinkle(index)
                    .rotationEffect(.degrees(index.isMultiple(of: 2)
                                             ? 0
                                             : Double(index * 31 - 70)))
                    .position(x: x, y: y)
            }
        }
    }

    @ViewBuilder
    private func sprinkle(_ index: Int) -> some View {
        if index.isMultiple(of: 5) {
            HoneyDrip()
                .fill(HoneyMenuPalette.honey.opacity(0.32))
                .frame(width: 8, height: 14)
        } else if index.isMultiple(of: 2) {
            HoneycombCell()
                .stroke(HoneyMenuPalette.comb.opacity(0.24), lineWidth: 1.2)
                .background(HoneycombCell().fill(accent.opacity(0.06)))
                .frame(width: CGFloat(16 + index % 3 * 7),
                       height: CGFloat(16 + index % 3 * 7))
        } else {
            Capsule()
                .fill(Color(red: 0.48, green: 0.68, blue: 0.34).opacity(0.16))
                .frame(width: CGFloat(7 + index % 3 * 3),
                       height: CGFloat(18 + index % 4 * 5))
        }
    }
}

/// Faint combs on the modal veil. They stay large and few so they read as
/// honeycomb, not as a star field.
private struct HoneyModalMotif: View {
    var body: some View {
        GeometryReader { proxy in
            ForEach(0..<7, id: \.self) { index in
                let side = CGFloat(26 + (index % 3) * 18)
                HoneycombCell()
                    .stroke(Color.white.opacity(index.isMultiple(of: 2) ? 0.16 : 0.09),
                            lineWidth: 1.3)
                    .frame(width: side, height: side)
                    .position(x: proxy.size.width * CGFloat((index * 41 + 11) % 100) / 100,
                              y: proxy.size.height * CGFloat((index * 59 + 23) % 100) / 100)
            }
        }
    }
}

/// Kept so archived promo layouts do not need to change with the live screens.
struct MenuPolarBackground: View {
    let accent: Color

    var body: some View {
        HoneyMenuBackground(accent: accent)
    }
}
