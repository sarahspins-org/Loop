//
//  BasalReviewStore.swift
//  Loop
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation
import Combine
import LoopKit

/// A schedule change made through the basal review (applied or undone), kept so it can be shown
/// and reversed.
struct BasalReviewHistoryEntry: Codable, Equatable, Identifiable {
    enum Kind: String, Codable {
        case applied
        case undone
    }

    var id: UUID = UUID()
    var date: Date
    var kind: Kind
    var reviewID: UUID?
    var previousItems: [RepeatingScheduleValue<Double>]
    var newItems: [RepeatingScheduleValue<Double>]
}

/// Persistent state for the basal review, backed by UserDefaults.
///
/// Safe to read from any thread. Writes notify SwiftUI on the main queue.
final class BasalReviewStore: ObservableObject {
    static let shared = BasalReviewStore()

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private enum Key: String {
        case enabled = "com.loopkit.Loop.BasalReview.Enabled"
        case enabledAt = "com.loopkit.Loop.BasalReview.EnabledAt"
        case baseline = "com.loopkit.Loop.BasalReview.Baseline"
        case pending = "com.loopkit.Loop.BasalReview.Pending"
        case lastReview = "com.loopkit.Loop.BasalReview.LastReview"
        case lastReviewDate = "com.loopkit.Loop.BasalReview.LastReviewDate"
        case lastScheduleChange = "com.loopkit.Loop.BasalReview.LastScheduleChange"
        case history = "com.loopkit.Loop.BasalReview.History"
        case overrideLog = "com.loopkit.Loop.BasalReview.OverrideLog"
    }

    // MARK: - Properties

    /// Off by default.
    var isEnabled: Bool {
        get { defaults.bool(forKey: Key.enabled.rawValue) }
        set { defaults.set(newValue, forKey: Key.enabled.rawValue); changed() }
    }

    /// When the feature was last switched on. The first review waits a full lookback after this,
    /// so every hour in the window has a recorded override and schedule-change history.
    var enabledAt: Date? {
        get { defaults.object(forKey: Key.enabledAt.rawValue) as? Date }
        set { defaults.set(newValue, forKey: Key.enabledAt.rawValue); changed() }
    }

    /// The schedule the user confirmed as their starting point; drift is measured against it.
    var baseline: [RepeatingScheduleValue<Double>]? {
        get { decode(Key.baseline) }
        set { encode(newValue, Key.baseline) }
    }

    /// A suggestion waiting for the user.
    var pending: BasalReview? {
        get { decode(Key.pending) }
        set { encode(newValue, Key.pending) }
    }

    /// The most recent review, whether or not it suggested anything.
    var lastReview: BasalReview? {
        get { decode(Key.lastReview) }
        set { encode(newValue, Key.lastReview) }
    }

    var lastReviewDate: Date? {
        get { defaults.object(forKey: Key.lastReviewDate.rawValue) as? Date }
        set { defaults.set(newValue, forKey: Key.lastReviewDate.rawValue); changed() }
    }

    /// Last time the basal schedule changed for any reason.
    var lastScheduleChange: Date? {
        get { defaults.object(forKey: Key.lastScheduleChange.rawValue) as? Date }
        set { defaults.set(newValue, forKey: Key.lastScheduleChange.rawValue); changed() }
    }

    var history: [BasalReviewHistoryEntry] {
        get { decode(Key.history) ?? [] }
        set { encode(Array(newValue.suffix(50)), Key.history) }
    }

    /// Times when an override was active, kept for the lookback window.
    var overrideLog: [DateInterval] {
        get { decode(Key.overrideLog) ?? [] }
        set { encode(newValue, Key.overrideLog) }
    }

    // MARK: - Actions

    func enable(now: Date, currentSchedule: [RepeatingScheduleValue<Double>]?) {
        enabledAt = now
        baseline = currentSchedule
        overrideLog = []
        pending = nil
        isEnabled = true
    }

    func disable() {
        isEnabled = false
        pending = nil
        NotificationManager.removeBasalReviewNotification()
    }

    func resetBaseline(to schedule: [RepeatingScheduleValue<Double>]?) {
        baseline = schedule
        pending = nil
        NotificationManager.removeBasalReviewNotification()
    }

    /// The most recent applied change that can still be undone: the schedule must be exactly what
    /// the review set it to.
    func undoableEntry(currentSchedule: [RepeatingScheduleValue<Double>]?) -> BasalReviewHistoryEntry? {
        guard let last = history.last, last.kind == .applied, let currentSchedule,
              BasalReviewAnalyzer.sorted(currentSchedule) == BasalReviewAnalyzer.sorted(last.newItems) else {
            return nil
        }
        return last
    }

    // MARK: - Private

    private func changed() {
        if Thread.isMainThread {
            objectWillChange.send()
        } else {
            DispatchQueue.main.async { self.objectWillChange.send() }
        }
    }

    private func decode<T: Decodable>(_ key: Key) -> T? {
        guard let data = defaults.data(forKey: key.rawValue) else { return nil }
        return try? decoder.decode(T.self, from: data)
    }

    private func encode<T: Encodable>(_ value: T?, _ key: Key) {
        if let value, let data = try? encoder.encode(value) {
            defaults.set(data, forKey: key.rawValue)
        } else {
            defaults.removeObject(forKey: key.rawValue)
        }
        changed()
    }
}
