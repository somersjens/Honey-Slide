//
//  CharacterUnlocks.swift
//  Elephant Challenge: Math Memory
//
//  Which of the ten characters the player has earned. Access is *derived* from
//  the card total rather than stored as a flag, so an unlock can never be lost
//  by a missed animation or an interrupted write.
//

import Foundation

public struct CharacterRequirement: Identifiable, Equatable, Sendable {
    public let characterID: String
    /// Total cards needed. 0 means available from the start.
    public let cards: Int
    /// Position in the catalog, used for ordering.
    public let order: Int

    public var id: String { characterID }

    public init(characterID: String, cards: Int, order: Int) {
        self.characterID = characterID
        self.cards = cards
        self.order = order
    }
}

public enum CharacterUnlocks {
    /// Catalog order. Must match `CharacterCatalog.all`, which is asserted by a
    /// test so the two lists can never drift apart.
    public static let orderedCharacterIDs = [
        "lion", "octopus", "crab", "elephant", "bear",
        "fox", "frog", "flying_penguin", "bunny", "dog"
    ]

    public static let starterCharacterID = orderedCharacterIDs[0]

    /// The requirement table, built from the central configuration. A character
    /// with no configured requirement is Premium-exclusive and is never
    /// reachable by collecting cards.
    public static let requirements: [CharacterRequirement] = {
        orderedCharacterIDs.enumerated().map { index, id in
            let cards = GameConfig.characterUnlockRequirements.indices.contains(index)
                ? GameConfig.characterUnlockRequirements[index]
                : nil
            return CharacterRequirement(characterID: id, cards: cards ?? Int.max, order: index)
        }
    }()

    /// The characters only Premium can open. Derived from the configuration
    /// rather than a second hardcoded list, so the two can never disagree.
    public static var premiumCharacterIDs: [String] {
        requirements.filter { $0.cards == Int.max }.map(\.characterID)
    }

    /// The characters that can be earned by playing, starter included.
    public static var cardCharacterIDs: [String] {
        requirements.filter { $0.cards != Int.max }.map(\.characterID)
    }

    public static func requirement(for characterID: String) -> CharacterRequirement? {
        requirements.first { $0.characterID == characterID }
    }

    /// Cards needed for a character, or nil when it is not card-unlockable.
    public static func cardsRequired(for characterID: String) -> Int? {
        guard let requirement = requirement(for: characterID),
              requirement.cards != Int.max else { return nil }
        return requirement.cards
    }

    public static func isUnlocked(characterID: String,
                                  totalCards: Int,
                                  isPremium: Bool) -> Bool {
        if isPremium { return true }
        guard let needed = cardsRequired(for: characterID) else { return false }
        return totalCards >= needed
    }

    /// Every character unlocked at a given card total (ignoring Premium).
    public static func unlockedCharacterIDs(totalCards: Int) -> [String] {
        requirements
            .filter { $0.cards != Int.max && totalCards >= $0.cards }
            .map(\.characterID)
    }

    /// Characters that crossed their requirement between two totals. Used to
    /// celebrate exactly the animals a session actually earned.
    public static func newlyUnlocked(from previousTotal: Int, to newTotal: Int) -> [String] {
        guard newTotal > previousTotal else { return [] }
        return requirements
            .filter { $0.cards != Int.max }
            .filter { $0.cards > previousTotal && $0.cards <= newTotal }
            .sorted { $0.order < $1.order }
            .map(\.characterID)
    }

    /// The next character still to be earned, and how many cards are left.
    public static func nextMilestone(totalCards: Int) -> (characterID: String, remaining: Int)? {
        guard let next = requirements
            .filter({ $0.cards != Int.max && $0.cards > totalCards })
            .min(by: { $0.cards < $1.cards }) else { return nil }
        return (next.characterID, next.cards - totalCards)
    }
}
