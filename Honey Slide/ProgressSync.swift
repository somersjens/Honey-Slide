//
//  ProgressSync.swift
//  Jumping Fox
//
//  Keeps durable game progress in iCloud's key-value store. Counters and
//  scores are monotonic: if two devices update independently, progress can
//  only move forwards.
//
//  The player's name rides along in the same store so that — like the scores —
//  it survives deleting and reinstalling the app. A restored account then shows
//  its name again instead of coming back nameless.
//

import Foundation
import Combine

final class ProgressSync: ObservableObject {
    static let shared = ProgressSync()

    @Published private(set) var revision = 0

    private let cloudStore = NSUbiquitousKeyValueStore.default
    private var notificationToken: NSObjectProtocol?
    private var defaultsToken: NSObjectProtocol?
    /// A full score reconciliation touches every board of all 594 levels. It is
    /// durable-storage work, not UI work, so serialize and coalesce it away
    /// from the main actor. Only the final revision notification returns to the
    /// main queue.
    private let reconcileQueue = DispatchQueue(
        label: "com.flyingpenguin.progress.reconcile",
        qos: .utility
    )
    private var fullReconcileQueued = false

    /// iCloud key for the player's name. Kept distinct from the local
    /// UserDefaults key so the mirroring below is always explicit.
    private let playerNameCloudKey = "profile.playerName.cloud"
    /// The last name we reconciled, so a UserDefaults change can be checked
    /// cheaply and we never echo our own restore back to the cloud.
    private var lastKnownPlayerName = ""

    private init() {
        notificationToken = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloudStore,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleFullReconciliation()
            self?.restorePlayerNameFromCloudIfNeeded()
        }

        // @AppStorage writes progress straight to UserDefaults, so watching the
        // store catches card rewards, unlocks, onboarding and name edits at
        // their source without every view needing sync-specific code.
        defaultsToken = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            self?.reconcileDurableProfile()
            self?.pushPlayerNameToCloudIfChanged()
        }

        lastKnownPlayerName = UserDefaults.standard.string(forKey: GameSettings.playerNameKey) ?? ""
        // Let the singleton and first visible frame finish before starting the
        // complete cloud snapshot. `synchronize()` and thousands of key reads
        // used to land together on the main thread immediately after launch.
        DispatchQueue.main.async { [weak self] in
            self?.scheduleFullReconciliation(synchronizingCloud: true)
        }
    }

    deinit {
        if let notificationToken {
            NotificationCenter.default.removeObserver(notificationToken)
        }
        if let defaultsToken {
            NotificationCenter.default.removeObserver(defaultsToken)
        }
    }

    /// Merges a local score with iCloud and writes the winner to both stores.
    /// This is intentionally a maximum, rather than last-write-wins, so a
    /// score earned on either device can never erase a better score elsewhere.
    /// `NSUbiquitousKeyValueStore` propagates `set` operations automatically;
    /// forcing `synchronize()` here can block the gameplay/main thread for
    /// several seconds on a slow iCloud connection.
    func mergedScore(for key: String, localScore: Int) -> Int {
        let cloudScore = (cloudStore.object(forKey: key) as? NSNumber)?.intValue ?? 0
        let winner = max(localScore, cloudScore)

        if cloudScore < winner {
            cloudStore.set(NSNumber(value: winner), forKey: key)
        }
        return winner
    }

    /// Re-reads every durable value after launch, an account change or an
    /// incoming iCloud update. Writing the winner to both stores makes this
    /// safe to call repeatedly and lets @AppStorage update the visible UI.
    private func scheduleFullReconciliation(synchronizingCloud: Bool = false) {
        guard !fullReconcileQueued else { return }
        fullReconcileQueued = true
        reconcileQueue.async { [weak self] in
            guard let self else { return }
            if synchronizingCloud { self.cloudStore.synchronize() }
            self.reconcileAllProgress()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // Preserve launch ordering: the old synchronous path refreshed
                // iCloud before reading the profile name. Doing this only after
                // the background synchronize avoids briefly restoring stale or
                // empty profile data.
                if synchronizingCloud { self.syncPlayerNameAtLaunch() }
                self.fullReconcileQueued = false
                self.revision &+= 1
            }
        }
    }

    private func reconcileAllProgress() {
        // Snapshot both stores once. Calling `object(forKey:)` through
        // ProgressStore for every board caused roughly 1,881 individual local
        // and ubiquitous-store reads per pass. Dictionary lookup keeps the
        // same monotonic merge semantics with far less locking and IPC churn.
        let defaults = UserDefaults.standard
        let localSnapshot = defaults.dictionaryRepresentation()
        let cloudSnapshot = cloudStore.dictionaryRepresentation

        for topic in MathTopic.allCases {
            for level in LevelCatalog.levels(for: topic) {
                for board in LevelBoard.all(for: level) {
                    let key = ProgressStore.Key.best(board)
                    let local = max(0, (localSnapshot[key] as? NSNumber)?.intValue ?? 0)
                    let cloud = max(0, (cloudSnapshot[key] as? NSNumber)?.intValue ?? 0)
                    let winner = max(local, cloud)
                    if cloud < winner {
                        cloudStore.set(NSNumber(value: winner), forKey: key)
                    }
                    if local < winner {
                        defaults.set(winner, forKey: key)
                    }
                }
            }
        }
        reconcileDurableProfile()
    }

    /// Progress outside the per-level scoreboards also needs to survive an app
    /// deletion: total cards drives character unlocks, and announced unlocks
    /// stops old rewards being presented twice.
    ///
    /// Onboarding completion deliberately does **not** ride along. It used to,
    /// and the result was that a reinstalled app opened its welcome flow — the
    /// local flag starts false — and then threw the player out of it a moment
    /// later, mid-question, when iCloud answered and flipped the flag under
    /// them. It is a per-installation thing rather than progress: a fresh
    /// install walks the three welcome screens and the tutorial behind them,
    /// and every card, score and the player's own name still come back.
    private func reconcileDurableProfile() {
        mergeMonotonicInteger(forKey: ProgressStore.Key.totalCards)
        mergeStringSet(forKey: ProgressStore.Key.announcedUnlocks)
    }

    /// Replaces a cloud value outright, rather than merging upwards. The
    /// monotonic rule everywhere else is what keeps two devices from erasing
    /// each other's progress; a number that was never earned is the one thing
    /// that rule cannot fix, and this is the only caller (see
    /// `ProgressStore.repairImplausibleCardTotal`).
    func overwrite(_ value: Int, forKey key: String) {
        cloudStore.set(NSNumber(value: max(0, value)), forKey: key)
    }

    private func mergeMonotonicInteger(forKey key: String) {
        let local = max(0, UserDefaults.standard.integer(forKey: key))
        let cloud = max(0, (cloudStore.object(forKey: key) as? NSNumber)?.intValue ?? 0)
        let winner = max(local, cloud)

        if cloud < winner {
            cloudStore.set(NSNumber(value: winner), forKey: key)
        }
        if local < winner {
            UserDefaults.standard.set(winner, forKey: key)
        }
    }

    private func mergeStringSet(forKey key: String) {
        let local = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        let cloud = Set(cloudStore.object(forKey: key) as? [String] ?? [])
        let merged = local.union(cloud)
        guard !merged.isEmpty else { return }
        let value = Array(merged).sorted()

        if cloud != merged { cloudStore.set(value, forKey: key) }
        if local != merged { UserDefaults.standard.set(value, forKey: key) }
    }

    // MARK: - Player name

    /// On launch, reconcile the local name with iCloud: a name saved in the
    /// cloud (e.g. from before a reinstall) is restored locally; otherwise an
    /// existing local name seeds the cloud for the first time.
    private func syncPlayerNameAtLaunch() {
        let localName = UserDefaults.standard.string(forKey: GameSettings.playerNameKey) ?? ""
        let cloudName = cloudStore.string(forKey: playerNameCloudKey) ?? ""

        if !cloudName.isEmpty, cloudName != localName {
            UserDefaults.standard.set(cloudName, forKey: GameSettings.playerNameKey)
            lastKnownPlayerName = cloudName
        } else if !localName.isEmpty, cloudName != localName {
            cloudStore.set(localName, forKey: playerNameCloudKey)
            lastKnownPlayerName = localName
        }
    }

    /// Applies a name that arrived from another device — or synced down after a
    /// reinstall — but never overwrites a local name with an empty one.
    private func restorePlayerNameFromCloudIfNeeded() {
        let cloudName = cloudStore.string(forKey: playerNameCloudKey) ?? ""
        guard !cloudName.isEmpty else { return }
        let localName = UserDefaults.standard.string(forKey: GameSettings.playerNameKey) ?? ""
        guard cloudName != localName else { return }
        UserDefaults.standard.set(cloudName, forKey: GameSettings.playerNameKey)
        lastKnownPlayerName = cloudName
    }

    /// Mirrors a local name edit up to iCloud. Any UserDefaults change triggers
    /// this, so a cheap guard limits the work to real name changes and stops a
    /// restore from being echoed straight back.
    private func pushPlayerNameToCloudIfChanged() {
        let localName = UserDefaults.standard.string(forKey: GameSettings.playerNameKey) ?? ""
        guard localName != lastKnownPlayerName else { return }
        lastKnownPlayerName = localName
        guard !localName.isEmpty else { return }
        cloudStore.set(localName, forKey: playerNameCloudKey)
    }
}
