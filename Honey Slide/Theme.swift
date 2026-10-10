//
//  Theme.swift
//  Elephant Challenge: Math Memory
//
//  Character catalog: 10 animals, each with a clearly different colour and a
//  matching visual theme for the whole app. Characters are earned by collecting
//  cards; the requirements live in `GameConfig.characterUnlockRequirements`.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The single currency collected throughout the game.
enum Currency {
    static let iconName = "honey-pot"
    static let name = "Honey"
}

/// A simple, single-colour Honey glyph for menus, rewards and intro screens.
/// The sculpted pot belongs to the playfield and its score counter.
struct CurrencyIcon: View {
    let size: CGFloat

    var body: some View {
        HoneyCurrencyGlyph()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// A lid and a broad, rounded jar, filled with the surrounding text colour.
/// This vector keeps menu currency legible even at small icon sizes.
private struct HoneyCurrencyGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.addRoundedRect(in: CGRect(x: 24, y: 7, width: 52, height: 13), cornerSize: CGSize(width: 5, height: 5))
        p.move(to: CGPoint(x: 30, y: 25))
        p.addLine(to: CGPoint(x: 70, y: 25))
        p.addCurve(to: CGPoint(x: 88, y: 56), control1: CGPoint(x: 71, y: 37), control2: CGPoint(x: 88, y: 38))
        p.addCurve(to: CGPoint(x: 77, y: 91), control1: CGPoint(x: 91, y: 74), control2: CGPoint(x: 88, y: 89))
        p.addQuadCurve(to: CGPoint(x: 23, y: 91), control: CGPoint(x: 50, y: 98))
        p.addCurve(to: CGPoint(x: 12, y: 56), control1: CGPoint(x: 12, y: 89), control2: CGPoint(x: 9, y: 74))
        p.addCurve(to: CGPoint(x: 30, y: 25), control1: CGPoint(x: 12, y: 38), control2: CGPoint(x: 29, y: 37))
        p.closeSubpath()
        let scale = min(rect.width, rect.height) / 100
        return p.applying(CGAffineTransform(scaleX: scale, y: scale))
            .offsetBy(dx: rect.midX - 50 * scale, dy: rect.midY - 50 * scale)
    }
}

struct AnimalCharacter: Identifiable, Equatable {
    let id: String
    let name: String
    let emoji: String
    /// Idle frame of the eight-image sheet. Menus, the welcome flow, the
    /// intro card and the result screen all show this one drawing. Gameplay
    /// swaps the other frames and never uses this name.
    let imageName: String
    /// The idle frame reduced to 256 px, for the Premium strip and the
    /// Settings picker. Those screens draw the whole cast at once.
    let thumbnailName: String
    // Colour components (0–1).
    let primaryRGB: (Double, Double, Double)
    let deepRGB: (Double, Double, Double)
    let skyRGB: (Double, Double, Double)
    let tintRGB: (Double, Double, Double)

    static func == (lhs: AnimalCharacter, rhs: AnimalCharacter) -> Bool {
        lhs.id == rhs.id
    }

    var color: Color { Color(red: primaryRGB.0, green: primaryRGB.1, blue: primaryRGB.2) }
    var deepColor: Color { Color(red: deepRGB.0, green: deepRGB.1, blue: deepRGB.2) }
    var skyColor: Color { Color(red: skyRGB.0, green: skyRGB.1, blue: skyRGB.2) }
    var tintColor: Color { Color(red: tintRGB.0, green: tintRGB.1, blue: tintRGB.2) }

    var artwork: Image { menuImage(named: imageName) }
    private func menuImage(named name: String) -> Image {
        #if canImport(UIKit)
        if let existing = UIImage(named: name) { return Image(uiImage: existing) }
        #endif
        // The Honey Slide asset catalog supplies the bear for the app shell.
        return Image("1_bear")
    }
    /// Use wherever the portrait is drawn at roughly 75 pt or less.
    var thumbnail: Image { menuImage(named: thumbnailName) }

    /// Catalog prefix of the eight gameplay frames. The lion keeps its original
    /// `1.1`…`1.8` imageset names; every other animal is `{prefix}_01`…`_08`.
    var spritePrefix: String {
        switch id {
        case "flying_penguin": return "penguin"
        case "bunny": return "rabbit"
        default: return id
        }
    }

    /// Frame numbers match the lion sheet. Frame 4 is on disk but unused:
    /// the flight skips it, the same way the original lion motion does.
    func gameplayAsset(frame: Int) -> String {
        if id == "lion" { return "1.\(frame)" }
        return String(format: "%@_%02d", spritePrefix, frame)
    }

    /// The welcome screen hangs the lion on the left of the form. Every other
    /// animal hangs on the right.
    var hangsOnLeadingSide: Bool { id == "lion" }

    /// How this character's drawing sits inside the shared canvas. The archived
    /// flight rig reads it. Menu portraits use the idle frame directly.
    var rig: CharacterRig { CharacterRig.rig(for: id) }

    /// Localized display name, resolved per language from the string catalog
    /// ("character.frog", "character.penguin", …).
    var localizedName: String {
        if id == "flying_penguin" { return L(key: "character.penguin") }
        return L(key: "character.\(id)")
    }
}

/// One character's flight artwork: a body canvas with a separate arm canvas on
/// either side of it. Every layer of a rig — and the portrait cut from the same
/// drawing — shares one 3:2 canvas and one alignment, so the arms only ever need
/// their own shoulder point.
///
/// Assets are named after the character's position in
/// `CharacterUnlocks.orderedCharacterIDs` — `1_body_only`, `2_body_only`, … —
/// so a new character is a folder of four PNGs plus one entry in `all` below.
struct CharacterRig {
    let bodyImage: String
    let frontArmImage: String
    let backArmImage: String
    /// Shoulder of the far arm, in its own canvas' unit space. Sits a little
    /// above the joint's centre so the arm swings from the top of the socket.
    let backShoulder: UnitPoint
    /// Shoulder of the near arm, measured the same way.
    let frontShoulder: UnitPoint
    /// Brings this drawing onto the starter penguin's footprint. Every character
    /// has to read at one size and leave the cannon from one spot, and the
    /// drawings fill their shared canvas very differently: ears, tails, tentacles
    /// and outstretched legs all push a character off centre and make it large.
    let artScale: CGFloat
    /// Shift after scaling, as a fraction of the canvas.
    let artOffset: CGSize

    /// Keyed by character ID. A character with no rig here flies the starter
    /// penguin's artwork, which is what every character did before rigs were
    /// drawn per animal.
    static let all: [String: CharacterRig] = [
        "flying_penguin": rig(1, back: (0.715, 0.600), front: (0.550, 0.550),
                              scale: 1, offset: (0, 0)),
        "bunny": rig(2, back: (0.646, 0.698), front: (0.502, 0.604),
                     scale: 0.820, offset: (0.037, 0.033)),
        "dog": rig(3, back: (0.758, 0.744), front: (0.575, 0.641),
                   scale: 0.760, offset: (0.001, -0.016)),
        "lion": rig(4, back: (0.744, 0.651), front: (0.547, 0.552),
                    scale: 0.765, offset: (0.014, 0.038)),
        "octopus": rig(5, back: (0.764, 0.573), front: (0.575, 0.546),
                       scale: 0.860, offset: (0.054, 0.023)),
        "crab": rig(6, back: (0.681, 0.606), front: (0.489, 0.521),
                    scale: 0.893, offset: (0.007, 0.046)),
        "elephant": rig(7, back: (0.681, 0.627), front: (0.486, 0.528),
                        scale: 0.812, offset: (-0.006, 0.015)),
        "bear": rig(8, back: (0.751, 0.601), front: (0.524, 0.490),
                    scale: 0.848, offset: (-0.005, 0.040)),
        "fox": rig(9, back: (0.703, 0.617), front: (0.520, 0.524),
                   scale: 0.852, offset: (0.016, 0.046)),
        "frog": rig(10, back: (0.745, 0.590), front: (0.546, 0.481),
                    scale: 0.859, offset: (0.027, 0.041))
    ]

    static func rig(for characterID: String) -> CharacterRig {
        all[characterID] ?? all[CharacterUnlocks.starterCharacterID]!
    }

    /// Every rig is the same four assets under one number, so only the measured
    /// numbers are worth spelling out per character.
    private static func rig(_ index: Int,
                            back: (CGFloat, CGFloat),
                            front: (CGFloat, CGFloat),
                            scale: CGFloat,
                            offset: (CGFloat, CGFloat)) -> CharacterRig {
        CharacterRig(bodyImage: "\(index)_body_only",
                     frontArmImage: "\(index)_front_arm",
                     backArmImage: "\(index)_back_arm",
                     backShoulder: UnitPoint(x: back.0, y: back.1),
                     frontShoulder: UnitPoint(x: front.0, y: front.1),
                     artScale: scale,
                     artOffset: CGSize(width: offset.0, height: offset.1))
    }
}

/// The idle frame of a character, fitted into a square. The eight-frame sheets
/// are already nearly square and contain the whole astronaut, so menus do not
/// apply the old flight-rig offset.
struct CharacterPortrait: View {
    let character: AnimalCharacter
    /// The square the portrait is laid out in. Magnification is a drawing-only
    /// transform, so the layout footprint stays `side` even when the artwork
    /// overlaps a ring.
    let side: CGFloat
    /// Extra magnification. `1` fits the whole frame inside `side`.
    var magnification: CGFloat = 1
    /// Small portraits (roughly 75 pt and under) read the 256 px copy.
    var usesThumbnail: Bool = false

    var body: some View {
        (usesThumbnail ? character.thumbnail : character.artwork)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: side, height: side)
            .scaleEffect(magnification)
    }
}

enum CharacterCatalog {
    /// The character available from the very first card.
    static let freeCharacterID = CharacterUnlocks.starterCharacterID

    /// The localized fallback used when the player leaves their name empty.
    /// The starter follows the configured character order, so changing the
    /// first playable character never leaves the welcome name behind.
    static var defaultPlayerName: String {
        character(id: CharacterUnlocks.starterCharacterID).localizedName
    }

    /// Order must match `CharacterUnlocks.orderedCharacterIDs`. Each palette is
    /// taken from its portrait artwork. Asset names remain attached to their
    /// animals even when the playable catalog order changes.
    static let all: [AnimalCharacter] = [
        AnimalCharacter(id: "flying_penguin", name: "Penguin", emoji: "🐧",
                        imageName: "penguin_01", thumbnailName: "penguin_thumb",
                        primaryRGB: (0.13, 0.42, 0.86), deepRGB: (0.04, 0.16, 0.38),
                        skyRGB: (0.86, 0.95, 1.00), tintRGB: (0.68, 0.86, 0.98)),
        AnimalCharacter(id: "bunny", name: "Bunny", emoji: "🐰",
                        imageName: "rabbit_01", thumbnailName: "rabbit_thumb",
                        primaryRGB: (0.96, 0.55, 0.64), deepRGB: (0.58, 0.31, 0.37),
                        skyRGB: (0.99, 0.94, 0.96), tintRGB: (0.97, 0.86, 0.89)),
        AnimalCharacter(id: "dog", name: "Dog", emoji: "🐶",
                        imageName: "dog_01", thumbnailName: "dog_thumb",
                        primaryRGB: (0.13, 0.70, 0.71), deepRGB: (0.05, 0.42, 0.43),
                        skyRGB: (0.90, 0.99, 0.99), tintRGB: (0.76, 0.97, 0.97)),
        AnimalCharacter(id: "lion", name: "Lion", emoji: "🦁",
                        imageName: "1.1", thumbnailName: "lion_thumb",
                        primaryRGB: (0.97, 0.73, 0.10), deepRGB: (0.58, 0.43, 0.02),
                        skyRGB: (0.99, 0.97, 0.89), tintRGB: (0.97, 0.91, 0.74)),
        AnimalCharacter(id: "octopus", name: "Octopus", emoji: "🐙",
                        imageName: "octopus_01", thumbnailName: "octopus_thumb",
                        primaryRGB: (0.66, 0.38, 0.90), deepRGB: (0.38, 0.20, 0.54),
                        skyRGB: (0.96, 0.93, 0.99), tintRGB: (0.90, 0.82, 0.97)),
        AnimalCharacter(id: "crab", name: "Crab", emoji: "🦀",
                        imageName: "crab_01", thumbnailName: "crab_thumb",
                        primaryRGB: (0.91, 0.24, 0.16), deepRGB: (0.55, 0.11, 0.06),
                        skyRGB: (0.99, 0.91, 0.90), tintRGB: (0.97, 0.78, 0.76)),
        AnimalCharacter(id: "elephant", name: "Elephant", emoji: "🐘",
                        imageName: "elephant_01", thumbnailName: "elephant_thumb",
                        primaryRGB: (0.44, 0.59, 0.80), deepRGB: (0.25, 0.34, 0.48),
                        skyRGB: (0.94, 0.96, 0.99), tintRGB: (0.86, 0.91, 0.97)),
        AnimalCharacter(id: "bear", name: "Bear", emoji: "🐻",
                        imageName: "bear_01", thumbnailName: "bear_thumb",
                        primaryRGB: (0.65, 0.42, 0.22), deepRGB: (0.39, 0.24, 0.11),
                        skyRGB: (0.99, 0.95, 0.92), tintRGB: (0.97, 0.88, 0.80)),
        AnimalCharacter(id: "fox", name: "Fox", emoji: "🦊",
                        imageName: "fox_01", thumbnailName: "fox_thumb",
                        primaryRGB: (0.97, 0.48, 0.08), deepRGB: (0.58, 0.26, 0.01),
                        skyRGB: (0.99, 0.93, 0.89), tintRGB: (0.97, 0.84, 0.73)),
        AnimalCharacter(id: "frog", name: "Frog", emoji: "🐸",
                        imageName: "frog_01", thumbnailName: "frog_thumb",
                        primaryRGB: (0.29, 0.72, 0.22), deepRGB: (0.15, 0.43, 0.11),
                        skyRGB: (0.92, 0.99, 0.91), tintRGB: (0.82, 0.97, 0.79))
    ]
    .sorted {
        let order = CharacterUnlocks.orderedCharacterIDs
        return (order.firstIndex(of: $0.id) ?? .max) < (order.firstIndex(of: $1.id) ?? .max)
    }

    static func character(id: String) -> AnimalCharacter {
        all.first { $0.id == id } ?? all[0]
    }

    /// The first half of the catalog: earned purely by collecting cards.
    static var cardCharacters: [AnimalCharacter] {
        all.filter { !CharacterUnlocks.premiumCharacterIDs.contains($0.id) }
    }

    /// The second half: still earnable with cards, but Premium grants them at once.
    static var premiumCharacters: [AnimalCharacter] {
        all.filter { CharacterUnlocks.premiumCharacterIDs.contains($0.id) }
    }

    /// The selected character, falling back to the starter when the selected
    /// one is not available (yet).
    static func current(isPremium: Bool) -> AnimalCharacter {
        let selected = character(id: GameSettings.characterID)
        if !CharacterUnlockStore.canUse(characterID: selected.id, isPremium: isPremium) {
            return character(id: freeCharacterID)
        }
        return selected
    }
}

/// Character access, derived from the player's card total so an unlock can
/// never be lost through a missed animation. Only the one-time celebration
/// receipt is stored separately.
enum CharacterUnlockStore {
    static var totalCards: Int {
        get { Progress.store.totalCards }
        set { Progress.store.totalCards = newValue }
    }

    /// Cards required for a character, or nil when it is not card-unlockable.
    static func requirement(for characterID: String) -> Int? {
        CharacterUnlocks.cardsRequired(for: characterID)
    }

    static func canUse(characterID: String, isPremium: Bool) -> Bool {
        CharacterUnlocks.isUnlocked(characterID: characterID,
                                    totalCards: totalCards,
                                    isPremium: isPremium)
    }

    /// The next animal still to be earned, for the home screen and reminders.
    static func nextMilestone() -> (character: AnimalCharacter, remaining: Int)? {
        guard let next = CharacterUnlocks.nextMilestone(totalCards: totalCards) else { return nil }
        return (CharacterCatalog.character(id: next.characterID), next.remaining)
    }

    /// Characters that crossed their requirement but have not been celebrated.
    static func unannouncedUnlocks(at total: Int) -> [AnimalCharacter] {
        let announced = Progress.store.announcedUnlocks
        return CharacterUnlocks.unlockedCharacterIDs(totalCards: total)
            .filter { $0 != CharacterCatalog.freeCharacterID && !announced.contains($0) }
            .map { CharacterCatalog.character(id: $0) }
    }

    static func markAnnounced(_ characterID: String) {
        var announced = Progress.store.announcedUnlocks
        announced.insert(characterID)
        Progress.store.announcedUnlocks = announced
    }
}
