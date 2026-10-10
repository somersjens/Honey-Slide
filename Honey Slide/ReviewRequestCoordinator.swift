//
//  ReviewRequestCoordinator.swift
//  Jumping Fox
//

import Foundation

/// Tracks native App Store review opportunities. Apple does not report whether
/// `requestReview()` actually presents, so a consumed phase always counts as an
/// attempt and later phases remain independent reserve opportunities.
final class ReviewRequestCoordinator {
    static let shared = ReviewRequestCoordinator()

    private struct Phase {
        let games: Int
        let minimumInstallAgeDays: Int
    }

    private static let phases = [
        Phase(games: 10, minimumInstallAgeDays: 0),
        Phase(games: 30, minimumInstallAgeDays: 7),
        Phase(games: 50, minimumInstallAgeDays: 14),
        Phase(games: 75, minimumInstallAgeDays: 21),
        Phase(games: 100, minimumInstallAgeDays: 28)
    ]

    private enum Key {
        static let installationDate = "review.installationDate"
        static let completedGames = "review.completedGames"
        static let usedPhases = "review.usedPhases"
        static let lastAttemptDate = "review.lastAttemptDate"
    }

    private static let minimumSessionGames = 3
    private static let cooldown: TimeInterval = 7 * 24 * 60 * 60

    private let defaults: UserDefaults
    private let lock = NSLock()

    // Session-only state deliberately resets after every app launch.
    private var sessionCompletedGames = 0
    private var hasQualifiedReturnPending = false
    private var didAttemptThisSession = false

    init(defaults: UserDefaults = .standard, now: Date = Date()) {
        self.defaults = defaults
        if defaults.object(forKey: Key.installationDate) == nil {
            defaults.set(now, forKey: Key.installationDate)
        }
    }

    /// Records a genuinely finished run. Pauses do not call this method.
    func recordCompletedGame(isNewHighScore: Bool, score: Int, maximumScore: Int) {
        lock.lock()
        defer { lock.unlock() }

        let currentTotal = max(0, defaults.integer(forKey: Key.completedGames))
        if currentTotal < Int.max {
            defaults.set(currentTotal + 1, forKey: Key.completedGames)
        }
        if sessionCompletedGames < Int.max {
            sessionCompletedGames += 1
        }

        // Avoid multiplication so corrupt/extreme values cannot overflow.
        let halfwayScore = maximumScore > 0 ? (maximumScore / 2 + maximumScore % 2) : Int.max
        if isNewHighScore, score >= halfwayScore {
            hasQualifiedReturnPending = true
        }
    }

    /// Starting another level before the returned menu settles expires the old
    /// opportunity; it must never leak into a later, unrelated menu return.
    func discardPendingReturn() {
        lock.lock()
        hasQualifiedReturnPending = false
        lock.unlock()
    }

    /// Called only after the main menu's return sequence has fully settled.
    /// State is persisted before returning true, preventing view rebuilds or
    /// termination from consuming the same phase twice.
    func menuReturnDidSettle(now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard hasQualifiedReturnPending else { return false }
        // This opportunity belongs to the return that just settled. Missing
        // conditions may be evaluated again after a later qualifying high score.
        hasQualifiedReturnPending = false

        guard !didAttemptThisSession,
              sessionCompletedGames >= Self.minimumSessionGames else {
            return false
        }

        if let lastAttempt = defaults.object(forKey: Key.lastAttemptDate) as? Date,
           now.timeIntervalSince(lastAttempt) < Self.cooldown {
            return false
        }

        let installationDate =
            (defaults.object(forKey: Key.installationDate) as? Date) ?? now
        let installedFor = max(0, now.timeIntervalSince(installationDate))
        let totalGames = max(0, defaults.integer(forKey: Key.completedGames))
        let usedPhases = Set(defaults.array(forKey: Key.usedPhases) as? [Int] ?? [])

        guard let phase = Self.phases.first(where: {
            totalGames >= $0.games
                && installedFor >= TimeInterval($0.minimumInstallAgeDays * 24 * 60 * 60)
                && !usedPhases.contains($0.games)
        }) else {
            return false
        }

        var updatedPhases = usedPhases
        updatedPhases.insert(phase.games)
        defaults.set(updatedPhases.sorted(), forKey: Key.usedPhases)
        defaults.set(now, forKey: Key.lastAttemptDate)
        didAttemptThisSession = true
        return true
    }
}
