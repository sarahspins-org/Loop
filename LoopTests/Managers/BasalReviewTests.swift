//
//  BasalReviewTests.swift
//  LoopTests
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import XCTest
import LoopKit
@testable import Loop

final class BasalReviewAnalyzerTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    // 2026-11-17 08:20 UTC. The window is 2026-11-14 08:00 → 2026-11-17 08:00.
    private let now = ISO8601DateFormatter().date(from: "2026-11-17T08:20:00Z")!
    private var windowEnd: Date { ISO8601DateFormatter().date(from: "2026-11-17T08:00:00Z")! }
    private var windowStart: Date { windowEnd.addingTimeInterval(-.hours(72)) }

    private func flat(_ rate: Double) -> [RepeatingScheduleValue<Double>] {
        [RepeatingScheduleValue(startTime: 0, value: rate)]
    }

    private func hourOfDay(_ date: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar.component(.hour, from: date)
    }

    /// Dates at `hour:minute` UTC on each day of the window.
    private func dailyDates(hour: Int, minute: Int = 0, days: [Int] = [0, 1, 2]) -> [Date] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let firstMidnight = calendar.startOfDay(for: windowStart).addingTimeInterval(.hours(24))
        return days.map { firstMidnight.addingTimeInterval(.hours(Double(24 * $0)) + .hours(Double(hour)) + .minutes(Double(minute))) }
    }

    private func makeInput(
        schedule: [RepeatingScheduleValue<Double>]? = nil,
        baseline: [RepeatingScheduleValue<Double>]? = nil,
        loopRate: (Date) -> Double = { _ in 1.0 },
        extraDoses: [DoseEntry] = [],
        historyStart: Date? = nil,
        glucose: (Date) -> Double = { _ in 120 },
        carbDates: [Date] = [],
        overrides: [DateInterval] = [],
        maximumBasalRate: Double? = 5,
        supportedRates: [Double] = []
    ) -> BasalReviewInput {
        let schedule = schedule ?? flat(1.0)
        let start = historyStart ?? windowStart.addingTimeInterval(-.hours(6))
        var doses: [DoseEntry] = []
        var glucoseValues: [BasalReviewGlucose] = []
        var t = start
        while t < now {
            let end = t.addingTimeInterval(.minutes(5))
            doses.append(DoseEntry(type: .tempBasal, startDate: t, endDate: end, value: loopRate(t), unit: .unitsPerHour, automatic: true))
            glucoseValues.append(BasalReviewGlucose(date: t, mgdL: glucose(t), wasUserEntered: false))
            t = end
        }
        return BasalReviewInput(
            now: now,
            timeZone: utc,
            schedule: schedule,
            baseline: baseline ?? schedule,
            doses: doses + extraDoses,
            carbEntryDates: carbDates,
            glucose: glucoseValues,
            overrideIntervals: overrides,
            suspendThresholdMgdL: 75,
            maximumBasalRate: maximumBasalRate,
            supportedBasalRates: supportedRates,
            maximumScheduleEntryCount: 24
        )
    }

    /// Loop running at `rate` between 02:00 and 06:00 every night, on schedule otherwise.
    private func overnight(_ rate: Double, base: Double = 1.0) -> (Date) -> Double {
        { date in (2..<6).contains(self.hourOfDay(date)) ? rate : base }
    }

    private func rate(_ review: BasalReview, atHour hour: Int) -> Double {
        BasalReviewAnalyzer.rate(at: TimeInterval(hour) * 3600, in: review.proposedItems)
    }

    // MARK: -

    func testNoChangeWhenLoopRunsOnSchedule() {
        let review = BasalReviewAnalyzer().review(makeInput())
        XCTAssertNil(review.skipReason)
        XCTAssertFalse(review.hasChanges)
        XCTAssertEqual(review.proposedItems, flat(1.0))
    }

    func testConsistentOvernightNeedRaisesEarlierHoursByAtMostTenPercent() {
        let review = BasalReviewAnalyzer().review(makeInput(loopRate: overnight(1.4)))

        XCTAssertTrue(review.hasChanges)
        // Need seen at 02–06 is applied 1–2 hours earlier, smoothed at the edges.
        XCTAssertEqual(rate(review, atHour: 0), 1.05, accuracy: 1e-9)
        XCTAssertEqual(rate(review, atHour: 1), 1.10, accuracy: 1e-9)
        XCTAssertEqual(rate(review, atHour: 3), 1.10, accuracy: 1e-9)
        XCTAssertEqual(rate(review, atHour: 4), 1.05, accuracy: 1e-9)
        XCTAssertEqual(rate(review, atHour: 5), 1.00, accuracy: 1e-9)
        XCTAssertEqual(rate(review, atHour: 12), 1.00, accuracy: 1e-9)
        XCTAssertEqual(review.changes.count, 3)
        for change in review.changes {
            XCTAssertLessThanOrEqual(change.proposedRate, change.currentRate * 1.1 + 1e-9)
        }
    }

    func testLowBlocksRaisesForHoursBeforeIt() {
        let lowAt = dailyDates(hour: 3, minute: 30, days: [1])[0]
        let review = BasalReviewAnalyzer().review(makeInput(
            loopRate: overnight(1.4),
            glucose: { abs($0.timeIntervalSince(lowAt)) < 60 ? 60 : 120 }
        ))
        for hour in 0...3 {
            XCTAssertEqual(rate(review, atHour: hour), 1.0, accuracy: 1e-9, "hour \(hour)")
            XCTAssertTrue(review.hours[hour].blockedByLow)
        }
        XCTAssertEqual(rate(review, atHour: 4), 1.05, accuracy: 1e-9)
    }

    func testCarbsExcludeTheFollowingHours() {
        let review = BasalReviewAnalyzer().review(makeInput(loopRate: overnight(1.4), carbDates: dailyDates(hour: 2)))
        XCTAssertFalse(review.hasChanges)
    }

    func testManualBolusExcludesButAutomaticBolusCountsAsDelivery() {
        // Temp basal on schedule, but 0.1 U automatic boluses every 15 minutes overnight: ratio 1.4.
        var autoBoluses: [DoseEntry] = []
        for night in dailyDates(hour: 2) {
            for quarter in 0..<16 {
                let t = night.addingTimeInterval(.minutes(Double(15 * quarter)))
                autoBoluses.append(DoseEntry(type: .bolus, startDate: t, endDate: t.addingTimeInterval(4), value: 0.1, unit: .units, automatic: true))
            }
        }
        let automatic = BasalReviewAnalyzer().review(makeInput(extraDoses: autoBoluses))
        XCTAssertEqual(rate(automatic, atHour: 1), 1.10, accuracy: 1e-9)

        let manual = autoBoluses.map {
            DoseEntry(type: .bolus, startDate: $0.startDate, endDate: $0.endDate, value: 0.1, unit: .units, automatic: false)
        }
        XCTAssertFalse(BasalReviewAnalyzer().review(makeInput(extraDoses: manual)).hasChanges)
    }

    func testOverridesExcludeHours() {
        let overrides = dailyDates(hour: 1).map { DateInterval(start: $0, duration: .hours(6)) }
        XCTAssertFalse(BasalReviewAnalyzer().review(makeInput(loopRate: overnight(1.4), overrides: overrides)).hasChanges)
    }

    func testOneUnusualNightIsNotEnough() {
        let oddNight = dailyDates(hour: 0, days: [1])[0]
        let review = BasalReviewAnalyzer().review(makeInput(loopRate: { date in
            date >= oddNight && date < oddNight.addingTimeInterval(.hours(24)) && (2..<6).contains(self.hourOfDay(date)) ? 1.6 : 1.0
        }))
        XCTAssertFalse(review.hasChanges)
    }

    func testConsistentlyLowerDeliveryLowersSchedule() {
        let review = BasalReviewAnalyzer().review(makeInput(loopRate: overnight(0.6)))
        XCTAssertEqual(rate(review, atHour: 0), 0.95, accuracy: 1e-9)
        XCTAssertEqual(rate(review, atHour: 2), 0.90, accuracy: 1e-9)
        for change in review.changes {
            XCTAssertGreaterThanOrEqual(change.proposedRate, change.currentRate * 0.9 - 1e-9)
        }
    }

    func testDriftFromBaselineIsCapped() {
        let review = BasalReviewAnalyzer().review(makeInput(
            schedule: flat(1.28),
            baseline: flat(1.0),
            loopRate: overnight(1.28 * 1.4, base: 1.28)
        ))
        XCTAssertEqual(rate(review, atHour: 2), 1.30, accuracy: 1e-9)
        XCTAssertTrue(review.reachedDriftLimit)
    }

    func testNeverAboveMaximumBasal() {
        let review = BasalReviewAnalyzer().review(makeInput(loopRate: overnight(1.4), maximumBasalRate: 1.05))
        XCTAssertLessThanOrEqual(review.proposedItems.map(\.value).max() ?? 0, 1.05 + 1e-9)
    }

    func testRoundingToPumpRatesNeverOvershoots() {
        XCTAssertEqual(BasalReviewAnalyzer.round(1.08, down: true, to: [1.0, 1.1, 1.2]), 1.0)
        XCTAssertEqual(BasalReviewAnalyzer.round(0.92, down: false, to: [0.8, 0.9, 1.0]), 1.0)
        let review = BasalReviewAnalyzer().review(makeInput(loopRate: overnight(1.4), supportedRates: [1.0, 1.2]))
        XCTAssertFalse(review.hasChanges, "Nearest pump rate within the 10% cap is the current rate")
    }

    func testSkipsWithoutEnoughHistory() {
        let review = BasalReviewAnalyzer().review(makeInput(historyStart: now.addingTimeInterval(-.hours(24))))
        XCTAssertEqual(review.skipReason, .insufficientDoseHistory)
        XCTAssertFalse(review.hasChanges)
    }

    func testCGMGapsMakeHoursUnusable() {
        var input = makeInput(loopRate: overnight(1.4))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        input.glucose = input.glucose.filter { !(2..<6).contains(hourOfDay($0.date)) || calendar.component(.minute, from: $0.date) < 20 }
        XCTAssertFalse(BasalReviewAnalyzer().review(input).hasChanges)
    }

    // MARK: - Applier guardrails

    func testApplierRejectsChangesOutsideLimits() {
        let analyzed = BasalReviewAnalyzer().review(makeInput(loopRate: overnight(1.4)))
        XCTAssertTrue(BasalReviewApplier.passesGuardrails(analyzed, baseline: flat(1.0), maximumBasalRate: 5, settings: .standard))

        var tooBig = analyzed
        tooBig.proposedItems = [RepeatingScheduleValue(startTime: 0, value: 1.2)]
        XCTAssertFalse(BasalReviewApplier.passesGuardrails(tooBig, baseline: flat(1.0), maximumBasalRate: 5, settings: .standard))

        XCTAssertFalse(BasalReviewApplier.passesGuardrails(analyzed, baseline: flat(1.0), maximumBasalRate: 1.05, settings: .standard))
        XCTAssertFalse(BasalReviewApplier.passesGuardrails(analyzed, baseline: flat(0.8), maximumBasalRate: 5, settings: .standard))
    }

    func testApplierRefusesStaleSuggestion() {
        var review = BasalReviewAnalyzer().review(makeInput(loopRate: overnight(1.4)))
        let settings = TherapySettings(basalRateSchedule: BasalRateSchedule(dailyItems: flat(0.9), timeZone: utc))
        var result: Swift.Result<Void, BasalReviewApplyError>?
        BasalReviewApplier.apply(review, therapySettings: settings, delegate: nil, now: now) { result = $0 }
        XCTAssertEqual(failure(result), .scheduleChanged)

        review.createdAt = now.addingTimeInterval(-.hours(48))
        let matching = TherapySettings(basalRateSchedule: BasalRateSchedule(dailyItems: flat(1.0), timeZone: utc))
        BasalReviewApplier.apply(review, therapySettings: matching, delegate: nil, now: now) { result = $0 }
        XCTAssertEqual(failure(result), .expired)
    }

    private func failure(_ result: Swift.Result<Void, BasalReviewApplyError>?) -> BasalReviewApplyError? {
        if case .failure(let error)? = result { return error }
        return nil
    }
}

final class BasalReviewReadinessTests: XCTestCase {
    private var defaults: UserDefaults!
    private var store: BasalReviewStore!

    override func setUp() {
        defaults = UserDefaults(suiteName: "BasalReviewReadinessTests")!
        defaults.removePersistentDomain(forName: "BasalReviewReadinessTests")
        store = BasalReviewStore(defaults: defaults)
    }

    func testReadinessFollowsDataCooldownAndInterval() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        XCTAssertEqual(BasalReviewManager.readiness(store: store, at: start), .disabled)

        store.enable(now: start, currentSchedule: [RepeatingScheduleValue(startTime: 0, value: 1)])
        XCTAssertEqual(BasalReviewManager.readiness(store: store, at: start.addingTimeInterval(.hours(10))),
                       .collectingData(until: start.addingTimeInterval(.hours(72))))
        XCTAssertEqual(BasalReviewManager.readiness(store: store, at: start.addingTimeInterval(.hours(72))), .due)

        store.lastScheduleChange = start.addingTimeInterval(.hours(80))
        XCTAssertEqual(BasalReviewManager.readiness(store: store, at: start.addingTimeInterval(.hours(100))),
                       .coolingDown(until: start.addingTimeInterval(.hours(152))))

        store.lastReviewDate = start.addingTimeInterval(.hours(152))
        XCTAssertEqual(BasalReviewManager.readiness(store: store, at: start.addingTimeInterval(.hours(160))),
                       .waitingForNextReview(at: start.addingTimeInterval(.hours(176))))
        XCTAssertEqual(BasalReviewManager.readiness(store: store, at: start.addingTimeInterval(.hours(176))), .due)
    }

    func testScheduleChangeClearsPendingSuggestion() {
        let manager = BasalReviewManager(store: store)
        store.enable(now: Date(), currentSchedule: nil)
        store.pending = BasalReview(createdAt: Date(), windowStart: Date(), windowEnd: Date(), timeZoneIdentifier: "UTC",
                                    currentItems: [], proposedItems: [], hours: [], changes: [], skipReason: nil)
        manager.basalScheduleDidChange(at: Date())
        XCTAssertNil(store.pending)
    }

    func testUndoOnlyWhenScheduleMatchesWhatWasApplied() {
        let old = [RepeatingScheduleValue(startTime: 0, value: 1.0)]
        let new = [RepeatingScheduleValue(startTime: 0, value: 1.05)]
        store.history = [BasalReviewHistoryEntry(date: Date(), kind: .applied, reviewID: nil, previousItems: old, newItems: new)]
        XCTAssertNotNil(store.undoableEntry(currentSchedule: new))
        XCTAssertNil(store.undoableEntry(currentSchedule: old))
    }
}
