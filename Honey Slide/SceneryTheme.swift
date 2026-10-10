//
//  SceneryTheme.swift
//  Flying Penguin
//
//  One world per character. The flight itself never changes — same cannon, same
//  rings in the character's own colour, same water to dive into — but the place
//  it happens in does: the frog is shot across a lily pond, the elephant across
//  a zoo basin, the fox across an autumn lake.
//
//  Everything a scene needs is data in this one file. The layers in
//  `PolarScenery`, `SceneryHorizon`, `SceneryFloaters` and `SceneryAir` read a
//  `SceneryTheme` and never mention a character, so adding an eleventh animal is
//  one entry here plus, at most, one new `case` in the style each layer switches
//  on.
//

import SwiftUI

// MARK: - Style vocabulary

/// The silhouette of the clouds. Colour comes from the theme; this only picks
/// how the lobes are laid out.
enum SceneryCloudStyle {
    /// Round cartoon lobes. The default, and what the polar sky has always used.
    case puffy
    /// Wider and flatter, for the hot skies (savanna) and the open ocean.
    case wispy
}

/// What drifts through the sky above the flight path. Deliberately small and
/// slow: the rings cross this same band.
enum SceneryAirStyle {
    case none
    case birds
    case dragonflies
    case petals
    case leaves
    case stars
}

/// The soft, far silhouette resting on the horizon, behind the detailed items.
enum SceneryRidgeProfile {
    /// Angular peaks: ice shelf, mountains.
    case jagged
    /// Soft bumps: hills, tree lines, hedges.
    case rounded
    /// Flat-topped tables, for the savanna.
    case mesa
    /// A single low dome, for islands and sea stacks.
    case island
}

/// The detailed band standing on the waterline — the thing that actually says
/// which world this is.
enum SceneryHorizonStyle {
    case iceRidge
    case reedBank
    case blossomTrees
    case gardenFence
    case acaciaSavanna
    case seaStacks
    case palmShore
    case zooPavilion
    case pineForest
    case autumnWoods
}

/// What floats on the water between the character and the horizon.
enum SceneryFloaterStyle {
    case iceFloe
    case lilyPad
    case petalRaft
    case poolToy
    case driftLog
    case kelpBulb
    case beachBall
    case zooBall
    case mossLog
    case autumnLeaf
}

/// The surface finish of the deck the cannon is rolled onto. The berg's shape is
/// shared by every world; only what covers it changes.
enum SceneryPadStyle {
    case snow
    case moss
    case blossom
    case sand
    case plank
    case tile
    case rock
}

// MARK: - Theme

/// Every colour and style choice for one character's flight scene.
struct SceneryTheme {
    struct SunLight {
        let core: Color
        let halo: Color
        /// Unit position in the scene, so it follows any screen size.
        let centre: CGPoint
        /// Diameter as a fraction of the scene width.
        let scale: CGFloat
    }

    struct CloudPalette {
        let style: SceneryCloudStyle
        let light: Color
        let shade: Color
    }

    struct RidgePalette {
        let profile: SceneryRidgeProfile
        /// The far silhouette, kept hazy — the bottom answer ring travels
        /// straight through this band.
        let far: Color
        /// The detailed items standing in front of it.
        let near: Color
        /// Blossom, foliage, flags: the one saturated note the near band gets.
        let accent: Color
    }

    struct WaterPalette {
        let shallow: Color
        let mid: Color
        let deep: Color
        /// The single bright surface line the eye locks onto.
        let crest: Color
        /// The glow under that line.
        let glow: Color
        let foam: Color
    }

    struct PadPalette {
        let style: SceneryPadStyle
        let light: Color
        let mid: Color
        let deep: Color
        /// Whatever covers the deck: snow, moss, sand, planking.
        let cap: Color
    }

    let id: String
    let skyTop: Color
    let skyMid: Color
    let skyLow: Color
    let sun: SunLight
    let clouds: CloudPalette
    let air: SceneryAirStyle
    /// Tint for the drifting air items — birds, petals, leaves.
    let airTint: Color
    let ridge: RidgePalette
    let horizon: SceneryHorizonStyle
    let water: WaterPalette
    let floater: SceneryFloaterStyle
    let pad: PadPalette
}

// MARK: - Catalog

enum SceneryThemes {
    /// The scene for a character, falling back to the polar one so an
    /// unrecognised id can never leave the playfield without a sky.
    static func theme(for characterID: String) -> SceneryTheme {
        all[characterID] ?? polar
    }

    static let all: [String: SceneryTheme] = [
        "flying_penguin": polar,
        "frog": pond,
        "bunny": blossom,
        "dog": garden,
        "lion": savanna,
        "octopus": reef,
        "crab": lagoon,
        "elephant": zoo,
        "bear": mountainLake,
        "fox": autumnLake
    ]

    // MARK: Penguin — the polar sea the game started in

    static let polar = SceneryTheme(
        id: "flying_penguin",
        skyTop: rgb(0.47, 0.77, 0.98),
        skyMid: rgb(0.74, 0.91, 1.00),
        skyLow: rgb(0.94, 0.985, 1.00),
        sun: .init(core: .white, halo: rgb(1.00, 0.99, 0.90),
                   centre: CGPoint(x: 0.79, y: 0.19), scale: 0.32),
        clouds: .init(style: .puffy, light: .white, shade: rgb(0.71, 0.87, 0.97)),
        air: .none,
        airTint: .white,
        ridge: .init(profile: .jagged,
                     far: rgb(0.87, 0.95, 1.00),
                     near: rgb(0.62, 0.88, 0.97),
                     accent: rgb(0.29, 0.70, 0.90)),
        horizon: .iceRidge,
        water: .init(shallow: rgb(0.28, 0.83, 0.95),
                     mid: rgb(0.05, 0.50, 0.80),
                     deep: rgb(0.01, 0.20, 0.55),
                     crest: .white,
                     glow: rgb(0.30, 0.85, 1.00),
                     foam: .white),
        floater: .iceFloe,
        pad: .init(style: .snow,
                   light: .white,
                   mid: rgb(0.62, 0.88, 0.97),
                   deep: rgb(0.29, 0.70, 0.90),
                   cap: .white)
    )

    // MARK: Frog — a reed-fringed pond, thick with lilies

    static let pond = SceneryTheme(
        id: "frog",
        skyTop: rgb(0.50, 0.79, 0.94),
        skyMid: rgb(0.79, 0.94, 0.89),
        skyLow: rgb(0.95, 0.99, 0.89),
        sun: .init(core: .white, halo: rgb(1.00, 0.98, 0.74),
                   centre: CGPoint(x: 0.76, y: 0.16), scale: 0.31),
        clouds: .init(style: .puffy, light: .white, shade: rgb(0.74, 0.89, 0.82)),
        air: .dragonflies,
        airTint: rgb(0.16, 0.46, 0.76),
        ridge: .init(profile: .rounded,
                     far: rgb(0.64, 0.82, 0.62),
                     near: rgb(0.24, 0.54, 0.24),
                     accent: rgb(0.55, 0.34, 0.16)),
        horizon: .reedBank,
        water: .init(shallow: rgb(0.44, 0.85, 0.66),
                     mid: rgb(0.09, 0.50, 0.34),
                     deep: rgb(0.02, 0.22, 0.16),
                     crest: rgb(0.93, 1.00, 0.94),
                     glow: rgb(0.48, 0.96, 0.62),
                     foam: rgb(0.94, 1.00, 0.94)),
        floater: .lilyPad,
        pad: .init(style: .moss,
                   light: rgb(0.84, 0.87, 0.76),
                   mid: rgb(0.54, 0.62, 0.46),
                   deep: rgb(0.26, 0.35, 0.22),
                   cap: rgb(0.40, 0.70, 0.30))
    )

    // MARK: Bunny — a blossom garden's ornamental pond

    static let blossom = SceneryTheme(
        id: "bunny",
        // Blue at the top, warming to blossom only near the horizon: a sky that
        // is pink all the way up leaves the pink rings nothing to stand out
        // against.
        skyTop: rgb(0.56, 0.74, 0.96),
        skyMid: rgb(0.86, 0.89, 0.97),
        skyLow: rgb(1.00, 0.94, 0.94),
        sun: .init(core: .white, halo: rgb(1.00, 0.92, 0.95),
                   centre: CGPoint(x: 0.74, y: 0.15), scale: 0.34),
        clouds: .init(style: .puffy, light: .white, shade: rgb(0.87, 0.84, 0.93)),
        air: .petals,
        airTint: rgb(0.98, 0.66, 0.78),
        ridge: .init(profile: .rounded,
                     far: rgb(0.68, 0.82, 0.64),
                     near: rgb(0.97, 0.52, 0.68),
                     accent: rgb(0.99, 0.76, 0.85)),
        horizon: .blossomTrees,
        water: .init(shallow: rgb(0.72, 0.90, 0.97),
                     mid: rgb(0.36, 0.52, 0.84),
                     deep: rgb(0.18, 0.24, 0.54),
                     crest: .white,
                     glow: rgb(0.86, 0.76, 1.00),
                     foam: .white),
        floater: .petalRaft,
        pad: .init(style: .blossom,
                   // Warm stone. A pad any paler than this reads as the
                   // penguin's ice with pink confetti on it.
                   light: rgb(0.96, 0.92, 0.90),
                   mid: rgb(0.80, 0.72, 0.72),
                   deep: rgb(0.50, 0.42, 0.46),
                   cap: rgb(0.98, 0.72, 0.82))
    )

    // MARK: Dog — the garden, with the paddling pool overflowing

    static let garden = SceneryTheme(
        id: "dog",
        skyTop: rgb(0.40, 0.79, 0.89),
        skyMid: rgb(0.76, 0.94, 0.96),
        skyLow: rgb(0.95, 0.99, 0.99),
        sun: .init(core: .white, halo: rgb(1.00, 1.00, 0.86),
                   centre: CGPoint(x: 0.81, y: 0.17), scale: 0.30),
        clouds: .init(style: .puffy, light: .white, shade: rgb(0.67, 0.87, 0.89)),
        air: .birds,
        airTint: rgb(0.28, 0.40, 0.48),
        ridge: .init(profile: .rounded,
                     far: rgb(0.62, 0.82, 0.74),
                     near: rgb(0.26, 0.58, 0.50),
                     accent: rgb(0.94, 0.42, 0.34)),
        horizon: .gardenFence,
        water: .init(shallow: rgb(0.40, 0.93, 0.92),
                     mid: rgb(0.04, 0.56, 0.62),
                     deep: rgb(0.01, 0.26, 0.34),
                     crest: .white,
                     glow: rgb(0.40, 0.95, 0.98),
                     foam: .white),
        floater: .poolToy,
        pad: .init(style: .plank,
                   light: rgb(0.94, 0.86, 0.72),
                   mid: rgb(0.73, 0.59, 0.43),
                   deep: rgb(0.44, 0.33, 0.23),
                   cap: rgb(0.86, 0.73, 0.56))
    )

    // MARK: Lion — the waterhole, late in a hot afternoon

    static let savanna = SceneryTheme(
        id: "lion",
        skyTop: rgb(0.44, 0.72, 0.92),
        skyMid: rgb(0.87, 0.88, 0.77),
        skyLow: rgb(0.99, 0.95, 0.81),
        sun: .init(core: rgb(1.00, 0.99, 0.88), halo: rgb(1.00, 0.86, 0.46),
                   centre: CGPoint(x: 0.72, y: 0.18), scale: 0.40),
        clouds: .init(style: .wispy, light: rgb(1.00, 0.99, 0.95),
                      shade: rgb(0.90, 0.84, 0.68)),
        air: .birds,
        airTint: rgb(0.40, 0.30, 0.20),
        ridge: .init(profile: .mesa,
                     far: rgb(0.82, 0.73, 0.56),
                     near: rgb(0.47, 0.38, 0.22),
                     accent: rgb(0.30, 0.46, 0.22)),
        horizon: .acaciaSavanna,
        water: .init(shallow: rgb(0.52, 0.85, 0.74),
                     mid: rgb(0.10, 0.48, 0.44),
                     deep: rgb(0.05, 0.24, 0.22),
                     crest: rgb(1.00, 0.99, 0.92),
                     glow: rgb(0.60, 0.95, 0.80),
                     foam: rgb(1.00, 0.99, 0.93)),
        floater: .driftLog,
        pad: .init(style: .rock,
                   light: rgb(0.95, 0.87, 0.68),
                   mid: rgb(0.79, 0.63, 0.37),
                   deep: rgb(0.48, 0.36, 0.19),
                   cap: rgb(0.87, 0.74, 0.43))
    )

    // MARK: Octopus — a reef under a dusk sky

    static let reef = SceneryTheme(
        id: "octopus",
        skyTop: rgb(0.34, 0.30, 0.66),
        skyMid: rgb(0.68, 0.64, 0.90),
        skyLow: rgb(0.92, 0.88, 0.98),
        sun: .init(core: .white, halo: rgb(0.86, 0.83, 1.00),
                   centre: CGPoint(x: 0.78, y: 0.13), scale: 0.24),
        clouds: .init(style: .wispy, light: rgb(0.93, 0.91, 0.99),
                      shade: rgb(0.60, 0.54, 0.82)),
        air: .stars,
        airTint: .white,
        ridge: .init(profile: .island,
                     far: rgb(0.47, 0.41, 0.66),
                     near: rgb(0.33, 0.24, 0.48),
                     accent: rgb(0.98, 0.55, 0.78)),
        horizon: .seaStacks,
        water: .init(shallow: rgb(0.42, 0.62, 0.94),
                     mid: rgb(0.16, 0.22, 0.72),
                     deep: rgb(0.05, 0.05, 0.32),
                     crest: .white,
                     glow: rgb(0.72, 0.62, 1.00),
                     foam: rgb(0.96, 0.94, 1.00)),
        floater: .kelpBulb,
        pad: .init(style: .rock,
                   light: rgb(0.75, 0.70, 0.88),
                   mid: rgb(0.47, 0.39, 0.63),
                   deep: rgb(0.24, 0.18, 0.38),
                   cap: rgb(0.61, 0.51, 0.79))
    )

    // MARK: Crab — a turquoise lagoon behind a palm shore

    static let lagoon = SceneryTheme(
        id: "crab",
        skyTop: rgb(0.32, 0.74, 0.96),
        skyMid: rgb(0.71, 0.92, 0.99),
        skyLow: rgb(0.97, 0.99, 1.00),
        sun: .init(core: .white, halo: rgb(1.00, 0.95, 0.72),
                   centre: CGPoint(x: 0.80, y: 0.16), scale: 0.32),
        clouds: .init(style: .puffy, light: .white, shade: rgb(0.67, 0.87, 0.95)),
        air: .birds,
        airTint: rgb(0.30, 0.36, 0.42),
        ridge: .init(profile: .island,
                     far: rgb(0.58, 0.79, 0.68),
                     near: rgb(0.20, 0.53, 0.40),
                     accent: rgb(0.94, 0.30, 0.24)),
        horizon: .palmShore,
        water: .init(shallow: rgb(0.48, 0.95, 0.90),
                     mid: rgb(0.02, 0.62, 0.72),
                     deep: rgb(0.01, 0.30, 0.46),
                     crest: .white,
                     glow: rgb(0.45, 0.97, 0.95),
                     foam: .white),
        floater: .beachBall,
        pad: .init(style: .sand,
                   light: rgb(1.00, 0.96, 0.84),
                   mid: rgb(0.94, 0.83, 0.61),
                   deep: rgb(0.71, 0.57, 0.36),
                   cap: rgb(0.99, 0.91, 0.73))
    )

    // MARK: Elephant — the zoo's big bathing basin

    static let zoo = SceneryTheme(
        id: "elephant",
        skyTop: rgb(0.48, 0.72, 0.94),
        skyMid: rgb(0.81, 0.90, 0.98),
        skyLow: rgb(0.96, 0.98, 1.00),
        sun: .init(core: .white, halo: rgb(1.00, 0.98, 0.87),
                   centre: CGPoint(x: 0.77, y: 0.16), scale: 0.30),
        clouds: .init(style: .puffy, light: .white, shade: rgb(0.73, 0.83, 0.93)),
        air: .birds,
        airTint: rgb(0.32, 0.40, 0.50),
        ridge: .init(profile: .rounded,
                     // The park the enclosure stands in, not more grey wall.
                     far: rgb(0.58, 0.74, 0.62),
                     near: rgb(0.52, 0.57, 0.62),
                     accent: rgb(0.93, 0.44, 0.32)),
        horizon: .zooPavilion,
        water: .init(shallow: rgb(0.58, 0.84, 0.94),
                     mid: rgb(0.18, 0.44, 0.70),
                     deep: rgb(0.07, 0.20, 0.44),
                     crest: .white,
                     glow: rgb(0.55, 0.82, 1.00),
                     foam: .white),
        floater: .zooBall,
        pad: .init(style: .tile,
                   // Poured concrete, not ice: the zoo's basin has a built edge.
                   light: rgb(0.89, 0.89, 0.88),
                   mid: rgb(0.68, 0.70, 0.73),
                   deep: rgb(0.40, 0.44, 0.50),
                   cap: rgb(0.55, 0.59, 0.65))
    )

    // MARK: Bear — a cold mountain lake under the pines

    static let mountainLake = SceneryTheme(
        id: "bear",
        skyTop: rgb(0.52, 0.74, 0.90),
        skyMid: rgb(0.85, 0.90, 0.93),
        skyLow: rgb(0.99, 0.96, 0.92),
        sun: .init(core: .white, halo: rgb(1.00, 0.93, 0.74),
                   // Low and to the left: the one theme lit from the other side,
                   // which is enough to make the lake feel like early morning.
                   centre: CGPoint(x: 0.22, y: 0.15), scale: 0.34),
        clouds: .init(style: .puffy, light: .white, shade: rgb(0.77, 0.81, 0.85)),
        air: .birds,
        airTint: rgb(0.32, 0.28, 0.24),
        ridge: .init(profile: .jagged,
                     far: rgb(0.68, 0.74, 0.83),
                     near: rgb(0.16, 0.37, 0.31),
                     accent: rgb(0.45, 0.31, 0.19)),
        horizon: .pineForest,
        water: .init(shallow: rgb(0.44, 0.78, 0.78),
                     mid: rgb(0.09, 0.40, 0.46),
                     deep: rgb(0.04, 0.19, 0.26),
                     crest: .white,
                     glow: rgb(0.50, 0.90, 0.90),
                     foam: .white),
        floater: .mossLog,
        pad: .init(style: .rock,
                   light: rgb(0.89, 0.85, 0.79),
                   mid: rgb(0.62, 0.55, 0.47),
                   deep: rgb(0.34, 0.29, 0.25),
                   cap: rgb(0.44, 0.61, 0.35))
    )

    // MARK: Fox — a lake in a wood that has already turned

    static let autumnLake = SceneryTheme(
        id: "fox",
        // The warmth belongs at the horizon, where the turned wood is. Carrying
        // it all the way up left the whole middle of the screen one beige haze
        // with orange rings floating in it.
        skyTop: rgb(0.50, 0.71, 0.93),
        skyMid: rgb(0.82, 0.87, 0.90),
        skyLow: rgb(0.99, 0.92, 0.80),
        sun: .init(core: rgb(1.00, 0.97, 0.84), halo: rgb(1.00, 0.76, 0.40),
                   centre: CGPoint(x: 0.70, y: 0.20), scale: 0.38),
        clouds: .init(style: .puffy, light: .white,
                      shade: rgb(0.88, 0.82, 0.78)),
        air: .leaves,
        airTint: rgb(0.95, 0.52, 0.16),
        ridge: .init(profile: .rounded,
                     far: rgb(0.87, 0.73, 0.59),
                     near: rgb(0.80, 0.40, 0.14),
                     accent: rgb(0.96, 0.76, 0.22)),
        horizon: .autumnWoods,
        water: .init(shallow: rgb(0.50, 0.80, 0.86),
                     mid: rgb(0.13, 0.42, 0.58),
                     deep: rgb(0.05, 0.20, 0.34),
                     crest: .white,
                     glow: rgb(0.98, 0.78, 0.50),
                     foam: .white),
        floater: .autumnLeaf,
        pad: .init(style: .plank,
                   light: rgb(0.95, 0.89, 0.79),
                   mid: rgb(0.71, 0.55, 0.37),
                   deep: rgb(0.40, 0.28, 0.18),
                   cap: rgb(0.94, 0.62, 0.24))
    )

    private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color {
        Color(red: r, green: g, blue: b)
    }
}
