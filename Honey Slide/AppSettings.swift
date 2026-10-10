//
//  AppSettings.swift
//  Elephant Challenge: Math Memory
//
//  The bridge between SwiftUI's `@AppStorage` and the pure-logic `ProgressStore`.
//  Views bind to the key constants declared here; anything that needs a
//  validated, migrated value goes through `Progress` instead.
//

import Foundation
import SwiftUI

/// App-wide access to the migrated progress store, wired to iCloud.
enum Progress {
    static let store: ProgressStore = {
        let store = ProgressStore.shared
        store.cloudMerge = { key, local in
            ProgressSync.shared.mergedScore(for: key, localScore: local)
        }
        // Wired before the migration runs: the repair of an impossible card
        // total has to reach iCloud in the same breath as it lands locally.
        store.cloudOverwrite = { key, value in
            ProgressSync.shared.overwrite(value, forKey: key)
        }
        store.migrateIfNeeded()
        return store
    }()
}

/// Storage keys and the small settings that are not part of gameplay progress.
enum GameSettings {
    // Keys shared with `@AppStorage` bindings in the views.
    static let characterKey = ProgressStore.Key.characterID
    static let playerNameKey = ProgressStore.Key.playerName
    static let onboardingCompleteKey = ProgressStore.Key.onboardingComplete
    static let totalCardsKey = ProgressStore.Key.totalCards
    static let topicKey = ProgressStore.Key.selectedTopic
    static let levelKey = ProgressStore.Key.selectedLevel
    static let mixedVariantKey = ProgressStore.Key.mixedVariant
    static let practiceModeKey = ProgressStore.Key.practiceMode
    static let gameSoundsEnabledKey = ProgressStore.Key.gameSoundsEnabled
    static let musicEnabledKey = ProgressStore.Key.musicEnabled

    /// Reads a stored flag, accepting every shape UserDefaults can hand back.
    /// A plain `as? Bool` silently misses numbers and strings — which is what a
    /// launch argument or a hand-edited plist produces — and would fall through
    /// to the default, quietly ignoring the player's setting.
    private static func storedBool(_ key: String, default fallback: Bool) -> Bool {
        guard let value = UserDefaults.standard.object(forKey: key) else { return fallback }
        if let number = value as? NSNumber { return number.boolValue }
        if let text = value as? String { return (text as NSString).boolValue }
        return fallback
    }
    static let premiumCacheKey = ProgressStore.Key.premiumCache

    /// Sound effects and background music.
    static var gameSoundsEnabled: Bool {
        get { storedBool(gameSoundsEnabledKey, default: true) }
        set { UserDefaults.standard.set(newValue, forKey: gameSoundsEnabledKey) }
    }

    static var musicEnabled: Bool {
        get { storedBool(musicEnabledKey, default: true) }
        set { UserDefaults.standard.set(newValue, forKey: musicEnabledKey) }
    }

    /// Spoken sums. On by default; `AppAudio` silently ignores this when the
    /// selected language has no installed voice.

    static var characterID: String {
        get { Progress.store.selectedCharacterID }
        set { Progress.store.selectedCharacterID = newValue }
    }

    static var playerName: String {
        get { UserDefaults.standard.string(forKey: playerNameKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: playerNameKey) }
    }

    /// Mirror of the Premium entitlement, written by `PremiumStore` and
    /// readable from anywhere without touching StoreKit.
    static var premiumUnlockedCache: Bool {
        get { Progress.store.isPremiumCached }
        set { Progress.store.isPremiumCached = newValue }
    }
}
