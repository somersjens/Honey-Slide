//
//  MenuPolarBackground.swift
//  Space Lion
//
//  Shared space styling for every menu surface. The old type name is kept as
//  a compatibility wrapper for promo compositions that still reference it.
//

import SwiftUI

enum SpaceMenuPalette {
    static let void = Color(red: 0.018, green: 0.027, blue: 0.105)
    static let horizon = Color(red: 0.055, green: 0.105, blue: 0.255)
    static let nebula = Color(red: 0.165, green: 0.105, blue: 0.355)
    static let starlight = Color(red: 0.80, green: 0.94, blue: 1.00)
    static let ink = Color(red: 0.045, green: 0.075, blue: 0.18)
    static let mutedInk = ink.opacity(0.67)
}

/// The shared backdrop behind the welcome flow, main menu and Premium sheet.
/// Everything is deterministic so stars never jump when SwiftUI recomputes a
/// screen, while the layered nebulae still give the scene depth.
struct SpaceMenuBackground: View {
    let accent: Color

    var body: some View {
        GeometryReader { proxy in
            let diameter = max(proxy.size.width, proxy.size.height)

            ZStack {
                LinearGradient(
                    colors: [SpaceMenuPalette.void,
                             Color(red: 0.035, green: 0.065, blue: 0.18),
                             SpaceMenuPalette.horizon],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                Circle()
                    .fill(RadialGradient(
                        colors: [accent.opacity(0.33), accent.opacity(0.08), .clear],
                        center: .center,
                        startRadius: 4,
                        endRadius: diameter * 0.42
                    ))
                    .frame(width: diameter * 0.82, height: diameter * 0.82)
                    .blur(radius: 24)
                    .offset(x: -proxy.size.width * 0.34,
                            y: -proxy.size.height * 0.28)

                Circle()
                    .fill(RadialGradient(
                        colors: [SpaceMenuPalette.starlight.opacity(0.15),
                                 accent.opacity(0.05),
                                 .clear],
                        center: .center,
                        startRadius: 5,
                        endRadius: diameter * 0.36
                    ))
                    .frame(width: diameter * 0.70, height: diameter * 0.70)
                    .blur(radius: 34)
                    .offset(x: proxy.size.width * 0.43,
                            y: -proxy.size.height * 0.14)

                SpaceStarField(count: 54)

                // A planet only partly enters the frame. Its bright rim keeps
                // the menu playful while leaving the middle quiet for content.
                ZStack {
                    Circle()
                        .fill(LinearGradient(
                            colors: [accent.opacity(0.72),
                                     Color(red: 0.13, green: 0.20, blue: 0.44),
                                     SpaceMenuPalette.void],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                    Circle()
                        .stroke(
                            LinearGradient(colors: [.white.opacity(0.65),
                                                    accent.opacity(0.30),
                                                    .clear],
                                           startPoint: .topLeading,
                                           endPoint: .bottomTrailing),
                            lineWidth: max(2, diameter * 0.006)
                        )
                }
                .frame(width: diameter * 0.57, height: diameter * 0.57)
                .shadow(color: accent.opacity(0.30), radius: 34)
                .offset(x: proxy.size.width * 0.47,
                        y: proxy.size.height * 0.55)

                ForEach(0..<3, id: \.self) { index in
                    Ellipse()
                        .stroke(index == 0 ? accent.opacity(0.20) : .white.opacity(0.08),
                                style: StrokeStyle(lineWidth: index == 0 ? 1.4 : 1,
                                                   dash: index == 2 ? [7, 9] : []))
                        .frame(width: proxy.size.width * CGFloat(0.72 + Double(index) * 0.18),
                               height: proxy.size.height * CGFloat(0.32 + Double(index) * 0.10))
                        .rotationEffect(.degrees(Double(-13 + index * 9)))
                        .offset(x: proxy.size.width * 0.28,
                                y: proxy.size.height * CGFloat(0.24 + Double(index) * 0.08))
                }

                LinearGradient(colors: [.white.opacity(0.055), .clear, .black.opacity(0.10)],
                               startPoint: .top,
                               endPoint: .bottom)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A cosmic veil for cards that are shown over the active playfield. The game
/// remains visible, but the stars make the start and result screens feel like
/// part of the same menu system as Home and Premium.
struct SpaceModalBackdrop: View {
    let accent: Color
    var opacity: Double = 1

    var body: some View {
        ZStack {
            Color.black.opacity(0.50 * opacity)
            LinearGradient(colors: [SpaceMenuPalette.void.opacity(0.72 * opacity),
                                    accent.opacity(0.16 * opacity),
                                    SpaceMenuPalette.horizon.opacity(0.58 * opacity)],
                           startPoint: .topLeading,
                           endPoint: .bottomTrailing)
            SpaceStarField(count: 34)
                .opacity(0.72 * opacity)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A small orbital stage used behind menu characters. It avoids a generic
/// circular portrait treatment and makes the character read as the pilot.
struct SpaceOrbitHalo: View {
    let accent: Color
    let diameter: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [accent.opacity(0.28),
                                               accent.opacity(0.08),
                                               .clear],
                                     center: .center,
                                     startRadius: 2,
                                     endRadius: diameter * 0.58))
            Circle()
                .stroke(.white.opacity(0.55), lineWidth: 1.2)
                .frame(width: diameter * 0.72, height: diameter * 0.72)
            Ellipse()
                .stroke(accent.opacity(0.66), lineWidth: 1.5)
                .frame(width: diameter, height: diameter * 0.42)
                .rotationEffect(.degrees(-16))
            Ellipse()
                .stroke(.white.opacity(0.30),
                        style: StrokeStyle(lineWidth: 1, dash: [4, 6]))
                .frame(width: diameter * 0.84, height: diameter * 0.34)
                .rotationEffect(.degrees(36))
            Circle()
                .fill(.white)
                .frame(width: max(4, diameter * 0.035),
                       height: max(4, diameter * 0.035))
                .shadow(color: accent, radius: 5)
                .offset(x: diameter * 0.39, y: -diameter * 0.08)
        }
        .frame(width: diameter, height: diameter)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A light spacecraft-glass panel. Existing menu typography stays highly
/// legible, while the blue lower edge, luminous rim and inset line bring the
/// space treatment into the content rather than leaving it in the wallpaper.
private struct SpaceMenuPanelModifier: ViewModifier {
    let accent: Color
    let cornerRadius: CGFloat
    let prominent: Bool

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(LinearGradient(
                        colors: [.white.opacity(prominent ? 0.95 : 0.88),
                                 Color(red: 0.86, green: 0.93, blue: 1.00)
                                    .opacity(prominent ? 0.92 : 0.80)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(LinearGradient(
                                colors: [accent.opacity(prominent ? 0.11 : 0.08),
                                         .clear,
                                         accent.opacity(prominent ? 0.07 : 0.05)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ))
                    }
                    .overlay(alignment: .topTrailing) {
                        Circle()
                            .fill(RadialGradient(colors: [accent.opacity(0.22), .clear],
                                                 center: .center,
                                                 startRadius: 0,
                                                 endRadius: 90))
                            .frame(width: 180, height: 180)
                            .offset(x: 48, y: -72)
                            .clipShape(RoundedRectangle(cornerRadius: cornerRadius,
                                                       style: .continuous))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(
                                LinearGradient(colors: [.white.opacity(0.96),
                                                        accent.opacity(0.90),
                                                        SpaceMenuPalette.starlight.opacity(0.72),
                                                        accent.opacity(0.74)],
                                               startPoint: .topLeading,
                                               endPoint: .bottomTrailing),
                                lineWidth: prominent ? 2.4 : 1.7
                            )
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: max(1, cornerRadius - 4), style: .continuous)
                            .inset(by: 4)
                            .stroke(accent.opacity(0.18), lineWidth: 1)
                    }
            }
            .shadow(color: accent.opacity(prominent ? 0.28 : 0.18),
                    radius: prominent ? 24 : 16,
                    y: prominent ? 10 : 7)
            .shadow(color: .black.opacity(0.22), radius: 18, y: 10)
    }
}

extension View {
    func spaceMenuPanel(accent: Color,
                        cornerRadius: CGFloat = 28,
                        prominent: Bool = false) -> some View {
        modifier(SpaceMenuPanelModifier(accent: accent,
                                        cornerRadius: cornerRadius,
                                        prominent: prominent))
    }
}

/// Stable stars shared by backgrounds and modal veils.
private struct SpaceStarField: View {
    let count: Int

    var body: some View {
        GeometryReader { proxy in
            ForEach(0..<count, id: \.self) { index in
                let x = CGFloat((index * 47 + 13) % 101) / 100
                let y = CGFloat((index * 71 + 29) % 103) / 102
                let size = CGFloat(1 + (index * 11) % 4)

                if index.isMultiple(of: 11) {
                    Image(systemName: "sparkle")
                        .font(.system(size: size * 2.2, weight: .medium))
                        .foregroundStyle(.white.opacity(0.72))
                        .shadow(color: .cyan.opacity(0.7), radius: 3)
                        .position(x: proxy.size.width * x,
                                  y: proxy.size.height * y)
                } else {
                    Circle()
                        .fill(index.isMultiple(of: 3)
                              ? SpaceMenuPalette.starlight.opacity(0.72)
                              : Color.white.opacity(0.48))
                        .frame(width: size, height: size)
                        .shadow(color: .white.opacity(size > 2 ? 0.5 : 0), radius: 2)
                        .position(x: proxy.size.width * x,
                                  y: proxy.size.height * y)
                }
            }
        }
    }
}

/// Kept so archived promo layouts do not need to change in lockstep with the
/// live screens. It now renders the space backdrop as well.
struct MenuPolarBackground: View {
    let accent: Color

    var body: some View {
        SpaceMenuBackground(accent: accent)
    }
}
