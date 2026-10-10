//
//  ProgressStore.swift
//  Elephant Challenge: Math Memory
//
//  Everything the game remembers between launches: the card total, per-level
//  personal bests, the selected level/topic/card mode, unlocked characters.
//
//  Storage is versioned. Data written by Jumping Fox is migrated once, and any
//  value that fails validation falls back to a safe default rather than
//  crashing or producing a nonsensical game.
//

import Foundation

/// The narrow slice of UserDefaults this store needs, so tests can run against
/// an in-memory double instead of the app's real defaults.
public protocol KeyValueStore: AnyObject {
    func integer(forKey key: String) -> Int
    func string(forKey key: String) -> String?
    func object(forKey key: String) -> Any?
    func stringArray(forKey key: String) -> [String]?
    func set(_ value: Int, forKey key: String)
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
}

extension UserDefaults: KeyValueStore {}

/// A dictionary-backed store for tests.
public final class InMemoryKeyValueStore: KeyValueStore {
    private var storage: [String: Any]

    public init(_ initial: [String: Any] = [:]) {
        storage = initial
    }

    public func integer(forKey key: String) -> Int { (storage[key] as? Int) ?? 0 }
    public func string(forKey key: String) -> String? { storage[key] as? String }
    public func object(forKey key: String) -> Any? { storage[key] }
    public func stringArray(forKey key: String) -> [String]? { storage[key] as? [String] }
    public func set(_ value: Int, forKey key: String) { storage[key] = value }
    public func set(_ value: Any?, forKey key: String) { storage[key] = value }
    public func removeObject(forKey key: String) { storage.removeValue(forKey: key) }
}

// MARK: - Boards

/// One scoreboard. A level does not have a single best: practising it in Order,
/// Random or Mixed are separate exercises, and on Supermix each combination of
/// operations is separate again. Every one of those keeps its own best and its
/// own "reached the maximum" tally. Targets depend on the chosen exercise;
/// only Supermix reaches 50 bubbles.
public struct LevelBoard: Hashable, Sendable {
    public let level: MathLevel
    /// Only meaningful on Supermix; ignored for every single-operation topic.
    public let mixedVariant: MixedVariant
    /// Which of the three order buttons was played. Supermix has none — its
    /// four combinations replace them — so it always stores `.mixed`.
    public let mode: PracticeMode

    public init(level: MathLevel,
                mixedVariant: MixedVariant = .basic,
                mode: PracticeMode = .mixed) {
        self.level = level
        self.mixedVariant = mixedVariant
        self.mode = level.topic.usesSupermixGrid ? .mixed : mode
    }

    /// The suffix that identifies this board in storage. `.mixed` contributes
    /// no suffix at all, so every score earned before the three buttons existed
    /// stays exactly where it was — that is the route the game used to play.
    public var storageID: String {
        level.topic == .mixed
            ? "\(level.id)+\(mixedVariant.rawValue)"
            : "\(level.id)\(mode.idSuffix)"
    }

    /// What a full score is worth on this board.
    public var maximum: Int {
        if level.topic.usesSupermixGrid { return GameConfig.supermixLevelMaximum }

        switch mode {
        case .order:  return GameConfig.orderLevelMaximum
        case .random: return GameConfig.randomLevelMaximum
        case .mixed:  return GameConfig.mixedLevelMaximum
        }
    }

    /// Every board a level has, which is what the topic and menu totals add up.
    /// Nothing may fall out of this list: a score earned in another mode or on
    /// another Supermix combination must never look lost.
    public static func all(for level: MathLevel) -> [LevelBoard] {
        let variants: [MixedVariant] = level.topic == .mixed ? MixedVariant.allCases : [.basic]
        let modes: [PracticeMode] = level.topic.usesSupermixGrid
            ? [.mixed]
            : PracticeMode.allCases
        return variants.flatMap { variant in
            modes.map { LevelBoard(level: level, mixedVariant: variant, mode: $0) }
        }
    }
}

// MARK: - Store

public final class ProgressStore {
    public static let shared = ProgressStore(defaults: UserDefaults.standard)

    public enum Key {
        public static let storageVersion = "storage.version"
        public static let totalCards = "progress.totalCards"
        public static let selectedTopic = "settings.topic"
        public static let selectedLevel = "settings.level"
        public static let mixedVariant = "settings.mixedVariant"
        public static let practiceMode = "settings.practiceMode"
        public static let characterID = "settings.character"
        public static let playerName = "profile.playerName"
        public static let onboardingComplete = "onboarding.complete"
        public static let gameSoundsEnabled = "settings.gameSoundsEnabled"
        public static let musicEnabled = "settings.musicEnabled"
        public static let languageOverride = "settings.languageOverride"
        public static let premiumCache = "premium.unlocked"
        public static let announcedUnlocks = "characters.announcedUnlocks"

        /// Bests are kept per board — see `LevelBoard`.
        public static func best(_ board: LevelBoard) -> String { "best.\(board.storageID)" }

        /// How often that board has been taken all the way to its maximum.
        public static func maxCompletions(_ board: LevelBoard) -> String {
            "max-completions.\(board.storageID)"
        }

        /// Version 2 kept one best per level, regardless of the card count.
        static func legacyBest(_ levelID: String) -> String { "best.\(levelID)" }

        /// Version 3 appended the answer-card count to every board key.
        static let legacyCardCounts = [2, 3, 4]
        static let legacySelectedCardCount = "settings.cardCount"

        // Jumping Fox keys, read once during migration.
        public enum Legacy {
            public static let trophyTotal = "characters.trophyTotal"
            public static let audioMode = "settings.audioMode"
            public static let soundEnabled = "settings.soundEnabled"
            public static let announcedUnlocks = "characters.announcedTrophyUnlocks"
            public static let menuFilter = "ui.menuFilter"
            public static let homeSnapshot = "menu.homeProgressSnapshot.v1"
            public static let pausedSessions = "paused.sessions"
            /// Every key prefix Jumping Fox owned that Math Memory does not.
            public static let obsoletePrefixes = [
                "best.addition", "best.subtraction", "best.tables", "best.fractions",
                "best.percentages", "best.super", "max-completions.", "tutorial.",
                "paused.", "menu.", "settings.lifeMode", "settings.answerHelper",
                "settings.showStreak", "settings.showTrophies",
                "settings.capTrophiesAtThirty", "ui.menuMode", "ui.supermixCategory"
            ]
        }
    }

    private let defaults: KeyValueStore
    /// Optional hook so best scores can be merged with iCloud. Left nil in
    /// tests, which keeps the store pure.
    public var cloudMerge: ((String, Int) -> Int)?
    /// Optional hook for the one case a merge cannot express: replacing a
    /// stored value outright, however high the cloud's copy is. Only the
    /// repair below uses it.
    public var cloudOverwrite: ((String, Int) -> Void)?

    public init(defaults: KeyValueStore) {
        self.defaults = defaults
    }

    // MARK: - Migration

    /// Brings stored data up to the current version. Safe to call on every
    /// launch: it is a no-op once the version matches.
    @discardableResult
    public func migrateIfNeeded() -> Int {
        let stored = defaults.integer(forKey: Key.storageVersion)
        guard stored < GameConfig.storageVersion else { return stored }

        if stored < 2 {
            migrateFromJumpingFox()
        }
        if stored < 4 {
            migrateToFixedAnswerCount(from: stored)
        }
        if stored < 5 {
            repairImplausibleCardTotal()
        }

        defaults.set(GameConfig.storageVersion, forKey: Key.storageVersion)
        return GameConfig.storageVersion
    }

    /// A card total no amount of play can account for is a leftover — from a
    /// test build, or from a trophy count carried over by an older migration.
    /// It matters because the total is what unlocks characters, and because
    /// iCloud merges it upwards only: once a wrong number is in the cloud,
    /// nothing that plays by the rules can ever bring it back down.
    ///
    /// The repair falls back on the one figure that is unarguably earned: the
    /// player's own best score on every board they have played. Filling every
    /// board of all 99 levels holds around 64,000 cards, so the threshold below
    /// is several complete games clear of anything reachable — a real total is
    /// never touched.
    private func repairImplausibleCardTotal() {
        let stored = totalCards
        guard stored > Self.implausibleCardTotal else { return }

        let earned = MathTopic.allCases.reduce(0) { sum, topic in
            sum + LevelCatalog.levels(for: topic).reduce(0) {
                $0 + bestScoreAcrossBoards(level: $1)
            }
        }
        totalCards = earned
        // The corrected value has to reach iCloud as an overwrite. Left to the
        // ordinary merge, the old number would simply win again on the next
        // launch and the repair would undo itself.
        cloudOverwrite?(Key.totalCards, earned)
    }

    /// Well past what the whole game can hold; see `repairImplausibleCardTotal`.
    private static let implausibleCardTotal = 250_000

    /// Version 3 gave every level three scoreboards — one per answer-card
    /// count — each aiming at its own target (20, 30, 40). There is now one
    /// board per level and mode, always five bubbles, always aiming at 50.
    ///
    /// The three old boards are folded into one by keeping the **highest** of
    /// them. Summing them would invent a score the player never reached in a
    /// single run, and picking one would throw the other two away; the best of
    /// the three is the one result they genuinely achieved. The same rule
    /// applies to the "reached the maximum" tally.
    ///
    /// Version 2, older still, kept a single best per level with no card count
    /// at all. For every topic but Supermix that key is *already* the new one,
    /// so it is left where it is; a Supermix score has no combination attached
    /// and cannot be attributed after the fact, so it lands on the first one.
    private func migrateToFixedAnswerCount(from stored: Int) {
        for topic in MathTopic.allCases {
            for index in 1...GameConfig.maximumLevel {
                let level = MathLevel(topic: topic, index: index)

                if stored < 3, topic.usesSupermixGrid {
                    let legacyKey = Key.legacyBest(level.id)
                    let legacy = defaults.integer(forKey: legacyKey)
                    defaults.removeObject(forKey: legacyKey)
                    if legacy > 0 {
                        let board = LevelBoard(level: level,
                                               mixedVariant: MixedVariant.allCases[0])
                        raise(key: Key.best(board), to: legacy, ceiling: board.maximum)
                    }
                }

                for board in LevelBoard.all(for: level) {
                    fold(intoKey: Key.best(board),
                         from: board.storageID,
                         prefix: "best.",
                         ceiling: board.maximum)
                    fold(intoKey: Key.maxCompletions(board),
                         from: board.storageID,
                         prefix: "max-completions.",
                         ceiling: GameConfig.maximumCompletionCount)
                }
            }
        }

        // A run paused mid-level belonged to a board that no longer exists, and
        // was played against a different target on a different number of
        // bubbles. There is nothing coherent to resume, so the records go.
        defaults.removeObject(forKey: PausedSessionStore.key)
        defaults.removeObject(forKey: Key.legacySelectedCardCount)
    }

    /// Merges the three per-card-count keys of one board into its single new
    /// key, keeping the highest value, and clears the old ones.
    private func fold(intoKey key: String, from storageID: String,
                      prefix: String, ceiling: Int) {
        var best = defaults.integer(forKey: key)
        for cards in Key.legacyCardCounts {
            let legacyKey = "\(prefix)\(storageID).\(cards)"
            best = max(best, defaults.integer(forKey: legacyKey))
            defaults.removeObject(forKey: legacyKey)
        }
        raise(key: key, to: best, ceiling: ceiling)
    }

    private func raise(key: String, to value: Int, ceiling: Int) {
        let capped = min(max(0, value), ceiling)
        guard capped > 0, capped > defaults.integer(forKey: key) else { return }
        defaults.set(capped, forKey: key)
    }

    /// Jumping Fox stored a trophy total, per-level trophy bests keyed by its
    /// own level ids, and a pile of settings this game no longer has. Trophies
    /// become cards one-for-one (they measured the same thing: correct
    /// answers), everything else is dropped so a stale value can never feed
    /// into the new game.
    private func migrateFromJumpingFox() {
        let legacyTrophies = max(0, defaults.integer(forKey: Key.Legacy.trophyTotal))
        if legacyTrophies > 0, defaults.integer(forKey: Key.totalCards) == 0 {
            defaults.set(legacyTrophies, forKey: Key.totalCards)
        }
        defaults.removeObject(forKey: Key.Legacy.trophyTotal)

        // Carry the previously announced character unlocks across so a player
        // is not re-congratulated for animals they already own.
        if defaults.stringArray(forKey: Key.announcedUnlocks) == nil,
           let announced = defaults.stringArray(forKey: Key.Legacy.announcedUnlocks) {
            defaults.set(announced, forKey: Key.announcedUnlocks)
        }
        defaults.removeObject(forKey: Key.Legacy.announcedUnlocks)

        // Sound: Jumping Fox's three-way audio mode collapses into the two
        // switches this game keeps.
        if defaults.object(forKey: Key.gameSoundsEnabled) == nil {
            if let raw = defaults.string(forKey: Key.Legacy.audioMode) {
                defaults.set(raw == "all" || raw == "musicAndEffects",
                             forKey: Key.gameSoundsEnabled)
            } else if let legacy = defaults.object(forKey: Key.Legacy.soundEnabled) as? Bool {
                defaults.set(legacy, forKey: Key.gameSoundsEnabled)
            }
        }
        defaults.removeObject(forKey: Key.Legacy.audioMode)
        defaults.removeObject(forKey: Key.Legacy.soundEnabled)

        // Jumping Fox's topic filter maps onto the new topic list, so a
        // returning player lands back on the subject they were practising.
        if defaults.string(forKey: Key.selectedTopic) == nil,
           let legacyFilter = defaults.object(forKey: Key.Legacy.menuFilter) as? Int,
           let topic = Self.legacyTopic(forFilter: legacyFilter) {
            defaults.set(topic.rawValue, forKey: Key.selectedTopic)
        }

        // Everything else Jumping Fox owned is gameplay this app removed.
        defaults.removeObject(forKey: Key.Legacy.homeSnapshot)
        defaults.removeObject(forKey: Key.Legacy.pausedSessions)
        defaults.removeObject(forKey: Key.Legacy.menuFilter)
        for prefix in Key.Legacy.obsoletePrefixes where !prefix.hasSuffix(".") {
            defaults.removeObject(forKey: prefix)
        }
    }

    /// Jumping Fox's `MenuFilter` raw values, in its own declaration order.
    static func legacyTopic(forFilter rawValue: Int) -> MathTopic? {
        let order: [MathTopic] = [.addition, .subtraction, .tables,
                                  .fractions, .percentages, .mixed]
        guard order.indices.contains(rawValue) else { return nil }
        return order[rawValue]
    }

    // MARK: - Cards

    /// Total cards ever earned. Never negative, never decreases.
    public var totalCards: Int {
        get { max(0, defaults.integer(forKey: Key.totalCards)) }
        set { defaults.set(max(0, newValue), forKey: Key.totalCards) }
    }

    /// Adds the cards earned in a session and returns the new total.
    @discardableResult
    public func addCards(_ amount: Int) -> Int {
        guard amount > 0 else { return totalCards }
        let updated = totalCards + amount
        totalCards = updated
        return updated
    }

    // MARK: - Personal bests

    public func bestScore(_ board: LevelBoard) -> Int {
        // Existing saves may contain scores earned before this board received
        // its shorter target. Keep them for syncing, but never present more
        // bubbles than the board can now hold.
        min(mergedValue(forKey: Key.best(board)), board.maximum)
    }

    /// The already-reconciled value in local storage, without contacting the
    /// cloud store. SwiftUI uses this while laying out menus: a body pass can
    /// ask for dozens of scores, and turning every read into an iCloud merge
    /// makes scrolling and state animations do storage work on the main thread.
    /// `ProgressSync` updates these local values in the background and bumps
    /// its revision once the snapshot is ready.
    public func storedBestScore(_ board: LevelBoard) -> Int {
        min(max(0, defaults.integer(forKey: Key.best(board))), board.maximum)
    }

    /// Local equivalent of `bestScoreAcrossBoards`, intended for read-only UI
    /// summaries after `ProgressSync` has reconciled the store.
    public func storedBestScoreAcrossBoards(level: MathLevel) -> Int {
        LevelBoard.all(for: level).reduce(0) { $0 + storedBestScore($1) }
    }

    /// One cached-friendly pass for a topic header. Keeping this as a store
    /// operation avoids accidental cloud access from a frequently recomputed
    /// SwiftUI property.
    public func storedScoreTotal(for topic: MathTopic) -> Int {
        LevelCatalog.levels(for: topic).reduce(0) {
            $0 + storedBestScoreAcrossBoards(level: $1)
        }
    }

    /// Every board a level has been played on, added up. The topic and the menu
    /// use this: a score earned with three cards, or on another Supermix
    /// combination, must not vanish from the totals because the player has
    /// since switched.
    public func bestScoreAcrossBoards(level: MathLevel) -> Int {
        LevelBoard.all(for: level).reduce(0) { $0 + bestScore($1) }
    }

    /// Records a session score on one board. The stored best is capped at that
    /// board's maximum, so a lucky run of double cards cannot report more than
    /// the level holds. Returns whether it beat the stored best, and what that
    /// best was beforehand.
    @discardableResult
    public func recordScore(_ score: Int,
                            board: LevelBoard) -> (isNewBest: Bool, previousBest: Int) {
        let capped = min(score, board.maximum)
        let previous = bestScore(board)
        guard capped > previous else { return (false, previous) }
        let key = Key.best(board)
        defaults.set(capped, forKey: key)
        _ = cloudMerge?(key, capped)
        return (true, previous)
    }

    // MARK: - Reaching the maximum

    /// How often this board has been taken all the way to its maximum.
    public func maxCompletionCount(_ board: LevelBoard) -> Int {
        min(GameConfig.maximumCompletionCount, mergedValue(forKey: Key.maxCompletions(board)))
    }

    /// Menu rendering counterpart of `maxCompletionCount(_:)`; see
    /// `storedBestScore(_:)` for why cloud work is kept out of body passes.
    public func storedMaxCompletionCount(_ board: LevelBoard) -> Int {
        min(GameConfig.maximumCompletionCount,
            max(0, defaults.integer(forKey: Key.maxCompletions(board))))
    }

    /// Counts one more run that reached the maximum, and returns the new tally.
    @discardableResult
    public func recordMaxCompletion(_ board: LevelBoard) -> Int {
        let next = min(GameConfig.maximumCompletionCount, maxCompletionCount(board) + 1)
        let key = Key.maxCompletions(board)
        defaults.set(next, forKey: key)
        _ = cloudMerge?(key, next)
        return next
    }

    /// Reads a stored counter, merging it with iCloud on the way past and
    /// keeping whichever value is higher.
    private func mergedValue(forKey key: String) -> Int {
        let local = max(0, defaults.integer(forKey: key))
        guard let cloudMerge else { return local }
        let merged = cloudMerge(key, local)
        if merged > local { defaults.set(merged, forKey: key) }
        return merged
    }

    // MARK: - Selection

    public var selectedTopic: MathTopic {
        get {
            guard let raw = defaults.string(forKey: Key.selectedTopic),
                  let topic = MathTopic(rawValue: raw) else { return MathTopic.allCases[0] }
            return topic
        }
        set { defaults.set(newValue.rawValue, forKey: Key.selectedTopic) }
    }

    /// Validated so a corrupt or out-of-range stored value can never produce an
    /// impossible level.
    public var selectedLevel: Int {
        get {
            let stored = defaults.integer(forKey: Key.selectedLevel)
            guard (1...GameConfig.maximumLevel).contains(stored) else { return 1 }
            return stored
        }
        set { defaults.set(min(GameConfig.maximumLevel, max(1, newValue)), forKey: Key.selectedLevel) }
    }

    /// Which Supermix combination the player last chose.
    public var mixedVariant: MixedVariant {
        get {
            guard let raw = defaults.string(forKey: Key.mixedVariant),
                  let variant = MixedVariant(rawValue: raw) else { return MixedVariant.allCases[0] }
            return variant
        }
        set { defaults.set(newValue.rawValue, forKey: Key.mixedVariant) }
    }

    /// Which of the three order buttons is selected. A player who has never
    /// chosen lands on the route the game generated before the buttons existed,
    /// so their existing scores stay on the board they are looking at.
    public var practiceMode: PracticeMode {
        get { PracticeMode.from(rawValue: defaults.string(forKey: Key.practiceMode)) }
        set { defaults.set(newValue.rawValue, forKey: Key.practiceMode) }
    }

    public var level: MathLevel {
        MathLevel(topic: selectedTopic, index: selectedLevel)
    }

    // MARK: - Characters

    public var selectedCharacterID: String {
        get { defaults.string(forKey: Key.characterID) ?? CharacterUnlocks.starterCharacterID }
        set { defaults.set(newValue, forKey: Key.characterID) }
    }

    public var announcedUnlocks: Set<String> {
        get { Set(defaults.stringArray(forKey: Key.announcedUnlocks) ?? []) }
        set { defaults.set(Array(newValue).sorted(), forKey: Key.announcedUnlocks) }
    }

    public var isPremiumCached: Bool {
        get { (defaults.object(forKey: Key.premiumCache) as? Bool) ?? false }
        set { defaults.set(newValue, forKey: Key.premiumCache) }
    }
}
