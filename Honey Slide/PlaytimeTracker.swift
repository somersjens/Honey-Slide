//
//  PlaytimeTracker.swift
//  Jumping Fox
//
//  Measures ACTIVE playtime only, tracks daily/weekly goals and the streak.
//
//  Time counts while a challenge is active, the app is foregrounded and the
//  player interacted recently (45 s idle limit). Accrual is driven by
//  interactions — there is no per-second timer re-rendering the UI, and the
//  published minute values only change when a whole minute rolls over.
//
//  Per day we store: date, active seconds, that day's goal. The streak is
//  derived from these records, so changing today's goal never rewrites
//  history.
//

import Foundation
import Combine
#if canImport(UIKit)
import UIKit
#endif

struct DayRecord: Codable {
    var date: String        // "yyyy-MM-dd" in the user's local calendar/timezone
    var seconds: Double
    var goalMinutes: Int

    var goalMet: Bool { seconds >= Double(goalMinutes) * 60 }
}

/// Main-thread only (SwiftUI + SpriteKit both call from the main thread).
final class PlaytimeTracker: ObservableObject {
    static let shared = PlaytimeTracker()

    // Published summaries — updated only when the visible value changes.
    @Published private(set) var todayMinutes = 0
    @Published private(set) var weekMinutes = 0
    @Published private(set) var streakDays = 0

    private var days: [String: DayRecord] = [:]
    private var challengeActive = false
    private var appActive = true
    private var lastAccrual: Date?
    private var unsavedSeconds: Double = 0

    /// The day the published summaries were last computed for, plus the caches
    /// that keep `accrue` off the calendar and the date formatter. See
    /// `dayKey(for:)` and `weekSeconds(at:)`.
    private var displayedDayKey = ""
    private var cachedDayKey = ""
    private var cachedDayStart: Date?
    private var cachedDayEnd: Date?
    private var weekInterval: DateInterval?
    private var weekSecondsCache: Double = 0

    private let idleLimit: TimeInterval = 45
    private let saveInterval: Double = 30
    private let daysKey = "playtime.days"
    private let dailyKey = "goal.dailyMinutes"
    private let weeklyKey = "goal.weeklyMinutes"

    private let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.calendar = Calendar.current
        formatter.timeZone = TimeZone.current
        return formatter
    }()

    private init() {
        load()
        recomputeDisplay()
#if canImport(UIKit)
        NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.appActive = false
            // Leaving the app is the one moment with no later frame to write
            // in, so this write is not handed to the background queue.
            self?.pauseAccrual(synchronous: true)
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.appActive = true
            self.lastAccrual = self.challengeActive ? Date() : nil
            self.recomputeDisplay() // day may have rolled over
        }
#endif
    }

    // MARK: Goals

    var dailyGoalMinutes: Int {
        let value = UserDefaults.standard.integer(forKey: dailyKey)
        return value > 0 ? value : 5
    }

    var weeklyGoalMinutes: Int {
        let value = UserDefaults.standard.integer(forKey: weeklyKey)
        return value > 0 ? value : 30
    }

    /// Daily and weekly goals are chosen independently in the menu. Changing
    /// one must not unexpectedly overwrite the other.
    func setDailyGoal(_ minutes: Int) {
        objectWillChange.send()
        UserDefaults.standard.set(minutes, forKey: dailyKey)
        touchTodayGoal()
        save(force: true)
        recomputeDisplay()
    }

    func setWeeklyGoal(_ minutes: Int) {
        objectWillChange.send()
        UserDefaults.standard.set(minutes, forKey: weeklyKey)
        recomputeDisplay()
    }

    /// Only today's record follows the current goal; past days stay frozen.
    private func touchTodayGoal() {
        let key = dayFormatter.string(from: Date())
        if var record = days[key] {
            record.goalMinutes = dailyGoalMinutes
            days[key] = record
        }
    }

    // MARK: Challenge lifecycle

    func challengeStarted() {
        challengeActive = true
        lastAccrual = Date()
    }

    /// Also called when a static screen (game over) appears.
    func challengeEnded(deferPersistence: Bool = false) {
        pauseAccrual(saveImmediately: !deferPersistence)
        challengeActive = false
        if deferPersistence {
            // The elapsed time is already frozen above. Only the JSON write is
            // postponed so it cannot compete with a result-card transition.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.save(force: true)
            }
        }
    }

    /// Called on real gameplay interaction: steering, jumping on an answer,
    /// starting a challenge.
    func registerInteraction() {
        guard challengeActive, appActive else { return }
        let now = Date()
        if let last = lastAccrual {
            let delta = now.timeIntervalSince(last)
            // Gaps longer than the idle limit don't count (player walked away).
            if delta > 0 && delta <= idleLimit {
                accrue(delta, at: now)
            }
        }
        lastAccrual = now
    }

    private func pauseAccrual(saveImmediately: Bool = true, synchronous: Bool = false) {
        if challengeActive, let last = lastAccrual {
            let delta = Date().timeIntervalSince(last)
            if delta > 0 && delta <= idleLimit {
                accrue(delta, at: Date(), allowPersistence: saveImmediately)
            }
        }
        lastAccrual = nil
        if saveImmediately {
            save(force: true, synchronous: synchronous)
        }
    }

    private func accrue(_ delta: TimeInterval, at date: Date,
                        allowPersistence: Bool = true) {
        let key = dayKey(for: date)
        var record = days[key] ?? DayRecord(date: key, seconds: 0, goalMinutes: dailyGoalMinutes)
        let previousMinutes = Int(record.seconds / 60)
        let previousGoalMet = record.goalMet
        record.seconds += delta
        record.goalMinutes = dailyGoalMinutes
        days[key] = record
        if weekInterval?.contains(date) == true { weekSecondsCache += delta }

        unsavedSeconds += delta
        if allowPersistence, unsavedSeconds >= saveInterval {
            save(force: false)
        }

        // This runs on every single answer, and recomputing the summaries walks
        // the week and the streak through a `DateFormatter`. Nothing on screen
        // is finer than a whole minute, and the streak can only move when
        // today's goal is met or the day turns over — so unless one of those
        // has actually happened there is nothing to recompute or publish.
        guard key != displayedDayKey
                || Int(record.seconds / 60) != previousMinutes
                || record.goalMet != previousGoalMet
                || Int(weekSeconds(at: date) / 60) != weekMinutes
        else { return }
        recomputeDisplay()
    }

    // MARK: Activity queries (for the notification scheduler)

    /// The most recent calendar day on which any active playtime was recorded,
    /// or nil if the player has never actually played. Used to anchor the
    /// re-engagement notification ladder.
    var lastActiveDate: Date? {
        days.values
            .filter { $0.seconds > 0 }
            .map(\.date)
            .max()
            .flatMap { dayFormatter.date(from: $0) }
    }

    /// True when the player has recorded any playtime today.
    var hasPlayedToday: Bool {
        (days[dayFormatter.string(from: Date())]?.seconds ?? 0) > 0
    }

    /// Whole calendar days since the player last played, as of `reference`.
    /// Returns nil if they have never played; 0 means they played today.
    func daysInactive(asOf reference: Date = Date()) -> Int? {
        guard let last = lastActiveDate else { return nil }
        let calendar = Calendar.current
        let lastDay = calendar.startOfDay(for: last)
        let today = calendar.startOfDay(for: reference)
        let days = calendar.dateComponents([.day], from: lastDay, to: today).day ?? 0
        return max(0, days)
    }

    // MARK: Derived values

    private func recomputeDisplay() {
        let now = Date()
        let todayKey = dayKey(for: now)
        displayedDayKey = todayKey
        let today = Int((days[todayKey]?.seconds ?? 0) / 60)
        let week = Int(weekSeconds(at: now) / 60)
        let streak = computeStreak()
        // Publish only when a visible value actually changed.
        if today != todayMinutes { todayMinutes = today }
        if week != weekMinutes { weekMinutes = week }
        if streak != streakDays { streakDays = streak }
    }

    // MARK: Hot-path caches

    /// Today's key, held for as long as "today" lasts. Formatting a date is
    /// far from free and this is asked for on every interaction.
    private func dayKey(for date: Date) -> String {
        if let start = cachedDayStart, let end = cachedDayEnd,
           date >= start, date < end {
            return cachedDayKey
        }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date)
        cachedDayStart = start
        cachedDayEnd = calendar.date(byAdding: .day, value: 1, to: start)
            ?? start.addingTimeInterval(24 * 60 * 60)
        cachedDayKey = dayFormatter.string(from: date)
        return cachedDayKey
    }

    /// The running week total, kept up to date by `accrue` rather than summed
    /// over seven formatted days every time it is read. Recomputed in full
    /// when the week rolls over or the stored days are replaced.
    private func weekSeconds(at date: Date) -> Double {
        if let interval = weekInterval, interval.contains(date) {
            return weekSecondsCache
        }
        weekInterval = Calendar.current.dateInterval(of: .weekOfYear, for: date)
        weekSecondsCache = currentWeekSeconds()
        return weekSecondsCache
    }

    /// Drops both caches: called whenever `days` is replaced wholesale.
    private func invalidateCaches() {
        cachedDayStart = nil
        cachedDayEnd = nil
        weekInterval = nil
    }

    private func currentWeekSeconds() -> Double {
        let calendar = Calendar.current
        guard let interval = calendar.dateInterval(of: .weekOfYear, for: Date()) else { return 0 }
        var total = 0.0
        var day = interval.start
        while day < interval.end {
            total += days[dayFormatter.string(from: day)]?.seconds ?? 0
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return total
    }

    /// A day counts once when that day's goal was met. Today only breaks
    /// the streak after the calendar day has passed.
    private func computeStreak() -> Int {
        let calendar = Calendar.current
        var streak = 0
        var day = Date()
        if let today = days[dayFormatter.string(from: day)], today.goalMet {
            streak += 1
        }
        while true {
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
            guard let record = days[dayFormatter.string(from: day)], record.goalMet else { break }
            streak += 1
        }
        return streak
    }

    // MARK: Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: daysKey),
              let decoded = try? JSONDecoder().decode([String: DayRecord].self, from: data) else { return }
        days = decoded
        invalidateCaches()
    }

    /// Encoding the record and handing it to `UserDefaults` is not free, and the
    /// only thing that ever triggers it mid-level is an answer — so once every
    /// half minute of play the cost landed squarely on the frame a child had
    /// just caught something on. The snapshot is taken here, on the main thread
    /// where the record lives, and written on a queue of its own.
    ///
    /// `synchronous` is for the ways a session can end (backgrounding, leaving
    /// the app) where there may be no later moment to write in.
    private func save(force: Bool, synchronous: Bool = false) {
        guard force || unsavedSeconds >= saveInterval else { return }
        unsavedSeconds = 0
        let snapshot = days
        let key = daysKey
        guard !synchronous else {
            Self.write(snapshot, forKey: key)
            return
        }
        Self.saveQueue.async { Self.write(snapshot, forKey: key) }
    }

    private static let saveQueue = DispatchQueue(label: "com.elephantchallenge.playtime.save",
                                                 qos: .utility)

    private static func write(_ days: [String: DayRecord], forKey key: String) {
        guard let data = try? JSONEncoder().encode(days) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
