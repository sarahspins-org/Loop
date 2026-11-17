//
//  BasalReviewManager.swift
//  Loop
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation
import HealthKit
import OSLog
import LoopKit
import LoopKitUI
import LoopCore

/// Runs the retrospective basal review once a day after a loop cycle, and posts a notification
/// when it has a suggestion. It never changes the schedule itself: the user applies a suggestion
/// from the review screen, through `BasalReviewApplier`.
final class BasalReviewManager {
    private let log = OSLog(category: "BasalReviewManager")

    let store: BasalReviewStore
    let settings: BasalReviewSettings
    private let analyzer: BasalReviewAnalyzer

    /// Supplied by DeviceDataManager so rounding matches what the pump can be programmed to.
    var pumpBasalLimits: () -> (supportedRates: [Double], maximumScheduleEntryCount: Int)? = { nil }

    private var isReviewing = false
    private let lock = NSLock()

    init(store: BasalReviewStore = .shared, settings: BasalReviewSettings = .standard) {
        self.store = store
        self.settings = settings
        self.analyzer = BasalReviewAnalyzer(settings: settings)
    }

    // MARK: - Bookkeeping

    /// Called after every loop cycle so the review knows when overrides were active.
    func recordLoopCompleted(at now: Date, activeOverride: TemporaryScheduleOverride?) {
        guard store.isEnabled else { return }

        var log = store.overrideLog.filter { $0.end > now.addingTimeInterval(-settings.lookback - .hours(24)) }
        if let override = activeOverride, override.isActive(at: now) {
            let interval = DateInterval(start: override.startDate, end: max(override.startDate, now))
            if let index = log.lastIndex(where: { $0.start == interval.start }) {
                log[index] = interval
            } else {
                log.append(interval)
            }
        }
        if log != store.overrideLog {
            store.overrideLog = log
        }
    }

    /// Called whenever the basal schedule changes, from any source.
    func basalScheduleDidChange(at now: Date) {
        store.lastScheduleChange = now
        if store.pending != nil {
            store.pending = nil
            NotificationManager.removeBasalReviewNotification()
        }
    }

    // MARK: - Scheduling

    enum Readiness: Equatable {
        case disabled
        case collectingData(until: Date)
        case coolingDown(until: Date)
        case waitingForNextReview(at: Date)
        case due
    }

    func readiness(at now: Date) -> Readiness {
        Self.readiness(store: store, settings: settings, at: now)
    }

    static func readiness(store: BasalReviewStore, settings: BasalReviewSettings = .standard, at now: Date) -> Readiness {
        guard store.isEnabled, let enabledAt = store.enabledAt else { return .disabled }

        let dataReady = enabledAt.addingTimeInterval(settings.lookback)
        if now < dataReady { return .collectingData(until: dataReady) }

        if let changed = store.lastScheduleChange {
            let cooldownEnd = changed.addingTimeInterval(settings.cooldownAfterScheduleChange)
            if now < cooldownEnd { return .coolingDown(until: cooldownEnd) }
        }

        if let last = store.lastReviewDate {
            let next = last.addingTimeInterval(settings.reviewInterval)
            if now < next { return .waitingForNextReview(at: next) }
        }
        return .due
    }

    // MARK: - Review

    struct Sources {
        var doseStore: DoseStoreProtocol
        var carbStore: CarbStoreProtocol
        var glucoseStore: GlucoseStoreProtocol
    }

    /// Runs a review if one is due. Safe to call after every loop cycle.
    func reviewIfDue(now: Date, loopSettings: LoopSettings, sources: Sources) {
        guard readiness(at: now) == .due else { return }
        guard let schedule = loopSettings.basalRateSchedule else { return }

        lock.lock()
        guard !isReviewing else { lock.unlock(); return }
        isReviewing = true
        lock.unlock()

        let fetchStart = now.addingTimeInterval(-settings.lookback - settings.mealAndBolusExclusion - .hours(1))
        let finish: (BasalReview?) -> Void = { [weak self] review in
            guard let self else { return }
            if let review { self.handle(review, now: now) }
            self.lock.lock(); self.isReviewing = false; self.lock.unlock()
        }

        sources.doseStore.getNormalizedDoseEntries(start: fetchStart, end: now) { [weak self] doseResult in
            guard let self, case .success(let doses) = doseResult else {
                if case .failure(let error) = doseResult {
                    self?.log.error("Basal review could not fetch doses: %{public}@", String(describing: error))
                }
                finish(nil); return
            }
            sources.carbStore.getCarbStatus(start: fetchStart, end: now, effectVelocities: nil) { carbResult in
                guard case .success(let carbStatuses) = carbResult else {
                    self.log.error("Basal review could not fetch carbs")
                    finish(nil); return
                }
                sources.glucoseStore.getGlucoseSamples(start: fetchStart, end: now.addingTimeInterval(1)) { glucoseResult in
                    guard case .success(let samples) = glucoseResult else {
                        self.log.error("Basal review could not fetch glucose")
                        finish(nil); return
                    }

                    let pumpLimits = self.pumpBasalLimits()
                    let input = BasalReviewInput(
                        now: now,
                        timeZone: schedule.timeZone,
                        schedule: schedule.items,
                        baseline: self.store.baseline ?? schedule.items,
                        doses: doses,
                        carbEntryDates: carbStatuses.map { $0.entry.startDate },
                        glucose: samples.map {
                            BasalReviewGlucose(date: $0.startDate,
                                               mgdL: $0.quantity.doubleValue(for: .milligramsPerDeciliter),
                                               wasUserEntered: $0.wasUserEntered)
                        },
                        overrideIntervals: self.store.overrideLog,
                        suspendThresholdMgdL: loopSettings.suspendThreshold?.quantity.doubleValue(for: .milligramsPerDeciliter),
                        maximumBasalRate: loopSettings.maximumBasalRatePerHour,
                        supportedBasalRates: pumpLimits?.supportedRates ?? [],
                        maximumScheduleEntryCount: pumpLimits?.maximumScheduleEntryCount
                    )
                    finish(self.analyzer.review(input))
                }
            }
        }
    }

    private func handle(_ review: BasalReview, now: Date) {
        store.lastReview = review
        store.lastReviewDate = now

        guard review.hasChanges else {
            log.default("Basal review found nothing to change (skip reason: %{public}@)", review.skipReason?.rawValue ?? "none")
            if store.pending != nil {
                store.pending = nil
                NotificationManager.removeBasalReviewNotification()
            }
            return
        }

        let isNew = store.pending?.proposedItems != review.proposedItems
        store.pending = review
        if isNew {
            log.default("Basal review suggests %d change(s)", review.changes.count)
            NotificationManager.sendBasalReviewNotification(for: review)
        }
    }
}

// MARK: - Applying

enum BasalReviewApplyError: LocalizedError, Equatable {
    case noPump
    case scheduleChanged
    case expired
    case failedGuardrail
    case pumpError(String)

    var errorDescription: String? {
        switch self {
        case .noPump:
            return NSLocalizedString("No pump is connected, so the schedule can't be changed.", comment: "Basal review apply error: no pump")
        case .scheduleChanged:
            return NSLocalizedString("Your basal schedule changed since this suggestion was made. Nothing was changed.", comment: "Basal review apply error: schedule changed")
        case .expired:
            return NSLocalizedString("This suggestion is out of date. Loop will make a fresh one at the next review.", comment: "Basal review apply error: expired")
        case .failedGuardrail:
            return NSLocalizedString("This suggestion is outside the safety limits, so it wasn't applied.", comment: "Basal review apply error: guardrail")
        case .pumpError(let message):
            return String(format: NSLocalizedString("The pump didn't accept the new schedule: %1$@. Nothing was changed.", comment: "Basal review apply error: pump (1: error)"), message)
        }
    }
}

/// Sends a schedule to the pump and saves it in Loop only if the pump accepts it.
enum BasalReviewApplier {
    /// Suggestions older than this are not applied.
    static let maximumSuggestionAge: TimeInterval = .hours(36)

    static func apply(_ review: BasalReview,
                      therapySettings: TherapySettings,
                      delegate: TherapySettingsViewModelDelegate?,
                      store: BasalReviewStore = .shared,
                      settings: BasalReviewSettings = .standard,
                      now: Date = Date(),
                      completion: @escaping (Swift.Result<Void, BasalReviewApplyError>) -> Void) {
        let current = therapySettings.basalRateSchedule.map { BasalReviewAnalyzer.sorted($0.items) }
        guard current == BasalReviewAnalyzer.sorted(review.currentItems) else {
            completion(.failure(.scheduleChanged)); return
        }
        guard now.timeIntervalSince(review.createdAt) <= maximumSuggestionAge else {
            completion(.failure(.expired)); return
        }
        guard passesGuardrails(review,
                               baseline: store.baseline ?? review.currentItems,
                               maximumBasalRate: therapySettings.maximumBasalRatePerHour,
                               settings: settings) else {
            completion(.failure(.failedGuardrail)); return
        }

        sync(items: review.proposedItems, therapySettings: therapySettings, delegate: delegate) { result in
            if case .success = result {
                var history = store.history
                history.append(BasalReviewHistoryEntry(date: now, kind: .applied, reviewID: review.id,
                                                       previousItems: review.currentItems, newItems: review.proposedItems))
                store.history = history
                store.pending = nil
                NotificationManager.removeBasalReviewNotification()
            }
            completion(result)
        }
    }

    /// Puts back the schedule from before the last applied suggestion.
    static func undo(_ entry: BasalReviewHistoryEntry,
                     therapySettings: TherapySettings,
                     delegate: TherapySettingsViewModelDelegate?,
                     store: BasalReviewStore = .shared,
                     now: Date = Date(),
                     completion: @escaping (Swift.Result<Void, BasalReviewApplyError>) -> Void) {
        guard store.undoableEntry(currentSchedule: therapySettings.basalRateSchedule?.items) == entry else {
            completion(.failure(.scheduleChanged)); return
        }
        sync(items: entry.previousItems, therapySettings: therapySettings, delegate: delegate) { result in
            if case .success = result {
                var history = store.history
                history.append(BasalReviewHistoryEntry(date: now, kind: .undone, reviewID: entry.reviewID,
                                                       previousItems: entry.newItems, newItems: entry.previousItems))
                store.history = history
            }
            completion(result)
        }
    }

    /// Independent re-check of the limits, so a corrupted or tampered suggestion can't slip through.
    static func passesGuardrails(_ review: BasalReview,
                                 baseline: [RepeatingScheduleValue<Double>],
                                 maximumBasalRate: Double?,
                                 settings: BasalReviewSettings) -> Bool {
        let current = BasalReviewAnalyzer.sorted(review.currentItems)
        let proposed = BasalReviewAnalyzer.sorted(review.proposedItems)
        let base = BasalReviewAnalyzer.sorted(baseline)
        guard !proposed.isEmpty, proposed.first?.startTime == 0 else { return false }

        let tolerance = 1e-6
        let starts = Set(current.map(\.startTime) + proposed.map(\.startTime) + base.map(\.startTime)).sorted()
        for start in starts {
            let old = BasalReviewAnalyzer.rate(at: start, in: current)
            let new = BasalReviewAnalyzer.rate(at: start, in: proposed)
            let b = BasalReviewAnalyzer.rate(at: start, in: base)
            guard new > 0 else { return false }
            if abs(new - old) <= tolerance { continue }
            if abs(new - old) > old * settings.maximumStepPerReview + tolerance { return false }
            if new > old {
                if new > b * (1 + settings.maximumDriftFromBaseline) + tolerance { return false }
                if let maximumBasalRate, new > maximumBasalRate + tolerance { return false }
            } else if new < b * (1 - settings.maximumDriftFromBaseline) - tolerance {
                return false
            }
        }
        return true
    }

    private static func sync(items: [RepeatingScheduleValue<Double>],
                             therapySettings: TherapySettings,
                             delegate: TherapySettingsViewModelDelegate?,
                             completion: @escaping (Swift.Result<Void, BasalReviewApplyError>) -> Void) {
        // syncBasalRateSchedule never calls back when there is no pump, so check first.
        guard let delegate, delegate.pumpSupportedIncrements() != nil else {
            completion(.failure(.noPump)); return
        }
        delegate.syncBasalRateSchedule(items: items) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let schedule):
                    var updated = therapySettings
                    updated.basalRateSchedule = schedule
                    delegate.saveCompletion(therapySettings: updated)
                    completion(.success(()))
                case .failure(let error):
                    completion(.failure(.pumpError(error.localizedDescription)))
                }
            }
        }
    }
}
