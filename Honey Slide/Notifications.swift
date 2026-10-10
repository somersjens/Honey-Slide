//
//  Notifications.swift
//  Elephant Challenge: Math Memory
//
//  Local re-engagement notifications: a small, kind, anti-spam set of reminders
//  that keep a streak alive, welcome a lapsed player back, celebrate collected
//  cards and nudge toward the next animal.
//
//  There is no backend, so iOS can never recompute content in the background.
//  Everything is a *pre-scheduled* local notification (UNCalendarNotificationTrigger)
//  built from the CURRENT game state, and the whole schedule is torn down and
//  rebuilt every time the app is used. Re-opening the app therefore pushes the
//  reactivation ladder forward on its own — an active player never sees a
//  "we miss you", and the "recently active" rule needs no fire-time check.
//
//  Timing is anchored to the clock time the user granted permission: that is a
//  moment of day they tend to be reachable and inclined to play again.
//

import Foundation
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Card history (for the weekly summary)

/// A tiny rolling ledger of the player's card total sampled per day, so the
/// weekly summary can report how many cards were earned in the last week (the
/// app otherwise only keeps the running total, not a per-week delta).
private struct CardHistory {
    private static let key = "notif.cardHistory"
    private static let retentionDays = 16

    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.calendar = Calendar.current
        f.timeZone = TimeZone.current
        return f
    }()

    private var samples: [String: Int] {
        get {
            guard let data = UserDefaults.standard.data(forKey: Self.key),
                  let decoded = try? JSONDecoder().decode([String: Int].self, from: data)
            else { return [:] }
            return decoded
        }
        nonmutating set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: Self.key)
            }
        }
    }

    /// Record today's total (keeping the highest seen today) and prune old rows.
    func record(total: Int, now: Date = Date()) {
        var updated = samples
        let today = formatter.string(from: now)
        updated[today] = max(updated[today] ?? 0, total)
        let cutoff = Calendar.current.date(byAdding: .day, value: -Self.retentionDays, to: now)
        if let cutoff {
            updated = updated.filter { key, _ in
                (formatter.date(from: key).map { $0 >= cutoff }) ?? false
            }
        }
        samples = updated
    }

    /// Cards earned over the past 7 days, or 0 when there isn't a week of
    /// history yet (so we never invent a spurious weekly total).
    func earnedInLastWeek(currentTotal: Int, now: Date = Date()) -> Int {
        let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: now) ?? now
        let baseline = samples
            .compactMap { key, value -> (Date, Int)? in
                guard let date = formatter.date(from: key), date <= weekAgo else { return nil }
                return (date, value)
            }
            .max(by: { $0.0 < $1.0 })?.1
        guard let baseline else { return 0 }
        return max(0, currentTotal - baseline)
    }
}

// MARK: - Manager

/// Owns notification permission, the preferred send-time, and the reschedule
/// pipeline. A single shared instance, wired up from `Jumping_FoxApp`.
final class NotificationManager: NSObject {
    static let shared = NotificationManager()

    // Anti-spam / cadence knobs. Named here so the whole policy is in one place.
    private enum Policy {
        static let minimumHoursBetweenPushes: Double = 20   // {minimum_hours_between_pushes}
        static let maxPerRolling7Days = 3
        static let messageRepeatDays = 3                    // {message_repeat_days}
        static let reactivationCooldownDays = 7
        static let informationalCooldownDays = 14
        static let premiumCooldownDays = 30
        static let ignoredPushesThreshold = 3               // {ignored_pushes}
        static let suppressionDays = 7                      // {suppression_days}
    }

    // Content knobs.
    private enum Content {
        static let premiumLevelsPerTopic = 99               // real Premium offer
        static let animalNudgeCards = 40                    // "within a session or two"
        static let premiumMinCompletedGames = 10
        static let cardMilestones = [50, 150, 400, 800, 1500, 3000]
    }

    private enum Key {
        static let didRequestOnTap = "notif.didRequestOnStreakTap"
        static let preferredHour = "notif.preferredHour"
        static let preferredMinute = "notif.preferredMinute"
        static let enabledDate = "notif.enabledDate"
        static let announcedMilestones = "notif.announcedCardMilestones"
        static let announcedAnimals = "notif.announcedAnimals"
        static let ignoredCount = "notif.ignoredCount"
        static let suppressUntil = "notif.suppressUntil"
    }

    /// Every request we create carries this prefix, so a reschedule only ever
    /// clears our own notifications.
    private static let identifierPrefix = "ec.notif."

    private let defaults = UserDefaults.standard
    private let center = UNUserNotificationCenter.current()
    private let history = CardHistory()

    /// Set when the app is opened by tapping one of our notifications, so the
    /// following `didBecomeActive` does not count that delivery as "ignored".
    private var openedFromNotification = false

    private override init() { super.init() }

    // MARK: Lifecycle

    /// Called once at launch. Installs the delegate, observes app lifecycle and
    /// performs an initial reschedule for players who granted permission in an
    /// earlier session.
    func start() {
        center.delegate = self
#if canImport(UIKit)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.rescheduleAll()
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.handleForeground()
        }
#endif
        rescheduleAll()
    }

    // MARK: Permission

    /// Requests permission the first time the player taps the streak widget, and
    /// never again. `presentPicker` opens the daily/weekly goal picker — but only
    /// *after* the player has answered the system prompt, so the two never
    /// present at once (which was both jarring and janky). On any later tap the
    /// picker opens immediately, exactly as before the prompt existed.
    ///
    /// On grant we remember the current clock time as the daily send-time and
    /// kick off the first schedule.
    func requestAuthorizationOnStreakTap(then presentPicker: @escaping () -> Void) {
        guard !defaults.bool(forKey: Key.didRequestOnTap) else {
            presentPicker()
            return
        }
        defaults.set(true, forKey: Key.didRequestOnTap)
        center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, _ in
            // Everything the picker and scheduler need happens on the main thread
            // right after the player dismisses the prompt.
            DispatchQueue.main.async {
                presentPicker()
                guard let self, granted else { return }
                let now = Date()
                let comps = Calendar.current.dateComponents([.hour, .minute], from: now)
                self.defaults.set(comps.hour ?? 18, forKey: Key.preferredHour)
                self.defaults.set(comps.minute ?? 0, forKey: Key.preferredMinute)
                if self.defaults.object(forKey: Key.enabledDate) == nil {
                    self.defaults.set(now, forKey: Key.enabledDate)
                }
                self.rescheduleAll()
            }
        }
    }

    // MARK: Foreground handling (ignored-count + one-time "announce" tracking)

    private func handleForeground() {
        center.getDeliveredNotifications { [weak self] delivered in
            guard let self else { return }
            let ids = delivered.map(\.request.identifier)
            DispatchQueue.main.async {
                self.markDeliveredAsAnnounced(ids)
                if self.openedFromNotification {
                    self.openedFromNotification = false
                } else if !ids.isEmpty {
                    // Notifications the player left sitting in Notification Center
                    // count as ignored; enough of them pause non-essential pushes.
                    let count = self.defaults.integer(forKey: Key.ignoredCount) + ids.count
                    if count >= Policy.ignoredPushesThreshold {
                        let until = Calendar.current.date(
                            byAdding: .day, value: Policy.suppressionDays, to: Date()
                        )
                        self.defaults.set(until, forKey: Key.suppressUntil)
                        self.defaults.set(0, forKey: Key.ignoredCount)
                    } else {
                        self.defaults.set(count, forKey: Key.ignoredCount)
                    }
                }
                self.center.removeAllDeliveredNotifications()
                self.rescheduleAll()
            }
        }
    }

    /// A once-per-user / once-per-milestone / once-per-animal message is marked
    /// spent only when it was actually delivered, not merely scheduled — a player
    /// who re-opens before it fires should still get it next time.
    private func markDeliveredAsAnnounced(_ identifiers: [String]) {
        for id in identifiers {
            let key = messageKey(fromIdentifier: id)
            if key.hasPrefix("milestone.") {
                let value = Int(key.dropFirst("milestone.".count)) ?? -1
                var set = Set(defaults.array(forKey: Key.announcedMilestones) as? [Int] ?? [])
                // Mark this threshold and every lower one, so already-passed
                // milestones can never re-fire on a later cycle.
                for threshold in Content.cardMilestones where threshold <= value {
                    set.insert(threshold)
                }
                defaults.set(Array(set).sorted(), forKey: Key.announcedMilestones)
            } else if key.hasPrefix("animal.") {
                let animalID = String(key.dropFirst("animal.".count))
                var set = Set(defaults.array(forKey: Key.announcedAnimals) as? [String] ?? [])
                set.insert(animalID)
                defaults.set(Array(set).sorted(), forKey: Key.announcedAnimals)
            }
        }
    }

    // MARK: Scheduling

    /// The heart of the feature: cancel everything, read the current state, build
    /// the candidate timeline, resolve conflicts by priority + anti-spam, and
    /// schedule the survivors. Safe to call as often as we like.
    func rescheduleAll() {
        center.getNotificationSettings { [weak self] settings in
            guard let self else { return }
            let authorized = settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
            DispatchQueue.main.async {
                self.clearPending()
                guard authorized, let state = self.currentState() else { return }
                self.history.record(total: state.currentCards)
                let accepted = self.resolve(self.buildCandidates(state))
                for candidate in accepted { self.schedule(candidate) }
            }
        }
    }

    private func clearPending() {
        // Every pending request in this app is ours, so a synchronous clear is
        // both safe and free of the races a callback-based removal would create
        // against the notifications we are about to add.
        center.removeAllPendingNotificationRequests()
    }

    private func schedule(_ candidate: Candidate) {
        let content = UNMutableNotificationContent()
        content.title = candidate.title
        content.body = candidate.body
        content.sound = .default
        var comps = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute], from: candidate.fireDate
        )
        comps.second = 0
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let identifier = "\(Self.identifierPrefix)\(candidate.messageKey)."
            + String(Int(candidate.fireDate.timeIntervalSince1970))
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
    }

    private func messageKey(fromIdentifier identifier: String) -> String {
        guard identifier.hasPrefix(Self.identifierPrefix) else { return "" }
        let body = identifier.dropFirst(Self.identifierPrefix.count)
        // Strip the trailing ".<epoch>" we appended when scheduling.
        if let dot = body.lastIndex(of: ".") { return String(body[..<dot]) }
        return String(body)
    }

    // MARK: State snapshot

    /// Everything the timeline needs, read from the existing stores. Returns nil
    /// when no send-time is known (the player never granted permission).
    private func currentState() -> NotificationState? {
        guard defaults.object(forKey: Key.preferredHour) != nil else { return nil }

        let tracker = PlaytimeTracker.shared
        let now = Date()
        let calendar = Calendar.current
        // Anchor the ladder to the last day the player actually played (or today).
        let anchor = calendar.startOfDay(for: tracker.lastActiveDate ?? now)

        let currentCards = CharacterUnlockStore.totalCards
        let nextMilestone = CharacterUnlockStore.nextMilestone()

        let suppressUntil = defaults.object(forKey: Key.suppressUntil) as? Date
        let suppressed = suppressUntil.map { $0 > now } ?? false

        return NotificationState(
            now: now,
            anchor: anchor,
            preferredHour: defaults.integer(forKey: Key.preferredHour),
            preferredMinute: defaults.integer(forKey: Key.preferredMinute),
            enabledDate: defaults.object(forKey: Key.enabledDate) as? Date,
            streakDays: tracker.streakDays,
            dailyGoalMinutes: tracker.dailyGoalMinutes,
            hasEverPlayed: tracker.lastActiveDate != nil,
            currentCards: currentCards,
            weeklyCards: history.earnedInLastWeek(currentTotal: currentCards, now: now),
            nextAnimalName: nextMilestone?.character.localizedName,
            nextAnimalID: nextMilestone?.character.id,
            nextAnimalRemaining: nextMilestone?.remaining,
            reachedCardMilestone: Content.cardMilestones
                .filter { $0 <= currentCards }
                .filter { !(defaults.array(forKey: Key.announcedMilestones) as? [Int] ?? []).contains($0) }
                .max(),
            isPremium: GameSettings.premiumUnlockedCache,
            completedGames: defaults.integer(forKey: "review.completedGames"),
            announcedAnimals: Set(defaults.array(forKey: Key.announcedAnimals) as? [String] ?? []),
            suppressed: suppressed
        )
    }

    // MARK: Candidate timeline

    private func fireDate(_ state: NotificationState, dayOffset: Int) -> Date {
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: dayOffset, to: state.anchor) ?? state.anchor
        return calendar.date(
            bySettingHour: state.preferredHour, minute: state.preferredMinute, second: 0, of: day
        ) ?? day
    }

    /// Builds every message that currently applies. Conflicts and frequency are
    /// resolved afterwards in `resolve(_:)`, so this stays a plain eligibility list.
    private func buildCandidates(_ state: NotificationState) -> [Candidate] {
        // Suppression pauses all of these non-essential nudges.
        guard !state.suppressed else { return [] }
        var out: [Candidate] = []

        // 1 & 2 — keep the streak alive (highest priority).
        if state.streakDays >= 1 {
            if state.streakDays == 2 {
                out.append(Candidate(
                    messageKey: "day3", category: .streak, priority: 1,
                    fireDate: fireDate(state, dayOffset: 1),
                    title: L("notif.day3.title"),
                    body: L("notif.day3.body \(state.dailyGoalMinutes)")))
            } else {
                out.append(Candidate(
                    messageKey: "streak", category: .streak, priority: 1,
                    fireDate: fireDate(state, dayOffset: 1),
                    title: L("notif.streak.title \(state.streakDays)"),
                    body: L("notif.streak.body \(state.dailyGoalMinutes)")))
            }
        }

        // 7 — a new animal is nearly unlocked (once per animal, only when close).
        if let remaining = state.nextAnimalRemaining, let name = state.nextAnimalName,
           let animalID = state.nextAnimalID,
           remaining > 0, remaining <= Content.animalNudgeCards,
           !state.announcedAnimals.contains(animalID) {
            out.append(Candidate(
                messageKey: "animal.\(animalID)", category: .informational, priority: 2,
                fireDate: fireDate(state, dayOffset: 2),
                title: L("notif.animal.title \(remaining)"),
                body: L("notif.animal.body \(name)")))
        }

        // 4 — a long absence (7 days+), then re-offered every two weeks.
        for (index, offset) in [10, 24, 38].enumerated() {
            out.append(Candidate(
                messageKey: "comeback.\(index)", category: .reactivation, priority: 3,
                fireDate: fireDate(state, dayOffset: offset),
                title: L("notif.comeback.title"),
                body: L("notif.comeback.body")))
        }

        // 3 — a short absence (2–4 days).
        out.append(Candidate(
            messageKey: "reactivate", category: .reactivation, priority: 4,
            fireDate: fireDate(state, dayOffset: 3),
            title: L("notif.reactivate.title"),
            body: L("notif.reactivate.body \(3)")))

        // 6 — the past week's cards (only with a real week of history).
        if state.weeklyCards >= 2 {
            out.append(Candidate(
                messageKey: "weekly", category: .informational, priority: 5,
                fireDate: fireDate(state, dayOffset: 7),
                title: L("notif.weekly.title \(state.weeklyCards)"),
                body: L("notif.weekly.body \(state.currentCards)")))
        }

        // 5 — a freshly reached card milestone (once per threshold).
        if let milestone = state.reachedCardMilestone {
            out.append(Candidate(
                messageKey: "milestone.\(milestone)", category: .informational, priority: 6,
                fireDate: fireDate(state, dayOffset: 1),
                title: L("notif.cards.title \(state.currentCards)"),
                body: L("notif.cards.body \(state.dailyGoalMinutes)")))
        }

        // 9 — Premium, for engaged non-Premium players, on a 30-day cadence.
        if !state.isPremium, state.completedGames >= Content.premiumMinCompletedGames {
            out.append(Candidate(
                messageKey: "premium", category: .premium, priority: 8,
                fireDate: fireDate(state, dayOffset: Policy.premiumCooldownDays),
                title: L("notif.premium.title"),
                body: L("notif.premium.body \(Content.premiumLevelsPerTopic)")))
        }

        return out
    }

    /// Resolves the eligibility list into a conflict-free schedule. Higher
    /// priority claims its slot first; a candidate is dropped when it would break
    /// any spacing or per-category cooldown against what is already accepted.
    private func resolve(_ candidates: [Candidate]) -> [Candidate] {
        let ordered = candidates
            .filter { $0.fireDate > Date() }
            .sorted { $0.priority != $1.priority ? $0.priority < $1.priority
                                                 : $0.fireDate < $1.fireDate }
        var accepted: [Candidate] = []
        let minGap = Policy.minimumHoursBetweenPushes * 3600
        let sevenDays: Double = 7 * 86400

        for candidate in ordered {
            var ok = true
            var within7 = 0
            for other in accepted {
                let gap = abs(candidate.fireDate.timeIntervalSince(other.fireDate))
                if gap < minGap { ok = false; break }
                if gap < sevenDays { within7 += 1 }
                if !cooldownSatisfied(candidate, other) { ok = false; break }
            }
            if ok && within7 < Policy.maxPerRolling7Days {
                accepted.append(candidate)
            }
        }
        return accepted.sorted { $0.fireDate < $1.fireDate }
    }

    /// Per-spec cooldowns between two accepted messages.
    private func cooldownSatisfied(_ a: Candidate, _ b: Candidate) -> Bool {
        let days = abs(a.fireDate.timeIntervalSince(b.fireDate)) / 86400
        // The very same message may not repeat within a few days.
        if a.messageKey == b.messageKey && days < Double(Policy.messageRepeatDays) { return false }
        if a.category == b.category {
            switch a.category {
            case .reactivation:
                if days < Double(Policy.reactivationCooldownDays) { return false }
            case .informational:
                if days < Double(Policy.informationalCooldownDays) { return false }
            case .premium:
                if days < Double(Policy.premiumCooldownDays) { return false }
            case .streak:
                break // spacing handled by the shared minimum-gap rule
            }
        }
        return true
    }
}

// MARK: - Supporting types

private enum NotifCategory { case streak, reactivation, informational, premium }

private struct Candidate {
    let messageKey: String   // stable per message type, for cooldown/announce tracking
    let category: NotifCategory
    let priority: Int        // lower wins
    let fireDate: Date
    let title: String
    let body: String
}

private struct NotificationState {
    let now: Date
    let anchor: Date
    let preferredHour: Int
    let preferredMinute: Int
    let enabledDate: Date?
    let streakDays: Int
    let dailyGoalMinutes: Int
    let hasEverPlayed: Bool
    let currentCards: Int
    let weeklyCards: Int
    let nextAnimalName: String?
    let nextAnimalID: String?
    let nextAnimalRemaining: Int?
    let reachedCardMilestone: Int?
    let isPremium: Bool
    let completedGames: Int
    let announcedAnimals: Set<String>
    let suppressed: Bool
}

// MARK: - Delegate

extension NotificationManager: UNUserNotificationCenterDelegate {
    /// Tapping a notification clears the "ignored" streak and re-opens the app.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        openedFromNotification = true
        defaults.set(0, forKey: Key.ignoredCount)
        markDeliveredAsAnnounced([response.notification.request.identifier])
        completionHandler()
    }

    /// Keep our reminders out of the way while the app is already open.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([])
    }
}
