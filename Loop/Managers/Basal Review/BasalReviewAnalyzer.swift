//
//  BasalReviewAnalyzer.swift
//  Loop
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation
import LoopKit

/// A glucose reading as the basal review sees it. Values are in mg/dL.
struct BasalReviewGlucose: Equatable {
    var date: Date
    var mgdL: Double
    var wasUserEntered: Bool
}

/// Everything the analyzer needs. Kept free of stores so it can be unit tested with plain values.
struct BasalReviewInput {
    var now: Date
    var timeZone: TimeZone
    /// The basal schedule in effect now (and, because of the cooldown, for the whole lookback).
    var schedule: [RepeatingScheduleValue<Double>]
    /// The schedule the user confirmed as their starting point. Drift is measured against this.
    var baseline: [RepeatingScheduleValue<Double>]
    /// Normalized doses covering at least the lookback window.
    var doses: [DoseEntry]
    var carbEntryDates: [Date]
    var glucose: [BasalReviewGlucose]
    /// Times when an override or preset was active.
    var overrideIntervals: [DateInterval]
    /// The user's suspend threshold in mg/dL, if set.
    var suspendThresholdMgdL: Double?
    var maximumBasalRate: Double?
    /// Basal rates the pump can be programmed to. Empty means "round to 0.05 U/hr".
    var supportedBasalRates: [Double]
    var maximumScheduleEntryCount: Int?
}

/// What the review found for one hour of the day.
struct BasalReviewHourFinding: Codable, Equatable {
    var hour: Int
    var cleanDays: Int
    var daysNeedingMore: Int
    var daysNeedingLess: Int
    /// Median of (delivered ÷ scheduled) across clean days, if any.
    var medianDeliveryRatio: Double?
    /// The factor this hour's own data supports, before shifting earlier.
    var observedFactor: Double
    /// The factor actually proposed for this hour (after shifting, the low guard and drift limit).
    var proposedFactor: Double
    var blockedByLow: Bool
    var limitedByDrift: Bool
}

/// One contiguous piece of the schedule that changes.
struct BasalReviewChange: Codable, Equatable {
    /// Seconds from midnight.
    var startTime: TimeInterval
    /// Seconds from midnight; 86400 means midnight at the end of the day.
    var endTime: TimeInterval
    var currentRate: Double
    var proposedRate: Double
}

enum BasalReviewSkipReason: String, Codable, Equatable {
    case insufficientDoseHistory
    case insufficientGlucoseHistory
    case tooManyScheduleEntries
}

/// The result of one review.
struct BasalReview: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var createdAt: Date
    var windowStart: Date
    var windowEnd: Date
    var timeZoneIdentifier: String
    var currentItems: [RepeatingScheduleValue<Double>]
    var proposedItems: [RepeatingScheduleValue<Double>]
    var hours: [BasalReviewHourFinding]
    var changes: [BasalReviewChange]
    var skipReason: BasalReviewSkipReason?

    var hasChanges: Bool { skipReason == nil && !changes.isEmpty }

    /// True when some hour wanted to move further but the drift limit stopped it.
    var reachedDriftLimit: Bool { hours.contains { $0.limitedByDrift } }

    var timeZone: TimeZone { TimeZone(identifier: timeZoneIdentifier) ?? .current }
}

/// Looks back over Loop's own delivery history and works out whether the scheduled basal looks
/// consistently too high or too low at particular times of day.
///
/// The idea: when the schedule is right and nothing else is going on (no food, no manual bolus,
/// no override), Loop should be delivering roughly the scheduled rate. If, on most of the last
/// three days, Loop had to run well above (or below) the schedule at the same time of day, the
/// schedule there is probably off. The analyzer suggests a small, capped move in that direction.
struct BasalReviewAnalyzer {
    let settings: BasalReviewSettings

    init(settings: BasalReviewSettings = .standard) {
        self.settings = settings
    }

    private static let slotLength: TimeInterval = .hours(1)
    private static let day: TimeInterval = .hours(24)

    /// One clock hour inside the lookback window.
    struct Slot {
        var start: Date
        var hourOfDay: Int
        var isClean: Bool
        var deliveryRatio: Double?
        var hasLowAfter: Bool
        var end: Date { start.addingTimeInterval(BasalReviewAnalyzer.slotLength) }
    }

    func review(_ input: BasalReviewInput) -> BasalReview {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = input.timeZone

        let windowEnd = calendar.dateInterval(of: .hour, for: input.now)?.start ?? input.now
        let windowStart = windowEnd.addingTimeInterval(-settings.lookback)
        let schedule = Self.sorted(input.schedule)
        let baseline = Self.sorted(input.baseline)

        var result = BasalReview(
            createdAt: input.now,
            windowStart: windowStart,
            windowEnd: windowEnd,
            timeZoneIdentifier: input.timeZone.identifier,
            currentItems: schedule,
            proposedItems: schedule,
            hours: [],
            changes: [],
            skipReason: nil
        )

        // Require dose history that reaches back to the start of the window.
        let basalDoses = input.doses.filter { $0.type == .basal || $0.type == .tempBasal }
        guard let earliestBasal = basalDoses.map(\.startDate).min(),
              earliestBasal <= windowStart.addingTimeInterval(.hours(1)) else {
            result.skipReason = .insufficientDoseHistory
            return result
        }

        let lowThreshold = max(settings.lowGlucoseFloorMgdL, input.suspendThresholdMgdL ?? 0)
        let slots = makeSlots(input: input, schedule: schedule, calendar: calendar,
                              windowStart: windowStart, lowThreshold: lowThreshold)

        guard slots.filter(\.isClean).count >= 24 else {
            // Less than a third of the window is usable; too little to say anything.
            result.skipReason = .insufficientGlucoseHistory
            return result
        }

        // Per hour of day: what does this hour's own data support?
        var findings = (0..<24).map { hour -> BasalReviewHourFinding in
            let hourSlots = slots.filter { $0.hourOfDay == hour }
            let ratios = hourSlots.filter(\.isClean).compactMap(\.deliveryRatio)
            let more = ratios.filter { $0 >= 1 + settings.deadband }.count
            let less = ratios.filter { $0 <= 1 - settings.deadband }.count
            let median = Self.median(ratios)

            var factor = 1.0
            if let median, ratios.count >= settings.minimumCleanDays,
               (more >= settings.minimumAgreeingDays && less == 0) ||
               (less >= settings.minimumAgreeingDays && more == 0) {
                let step = (median - 1) * settings.damping
                factor = 1 + Self.clamp(step, -settings.maximumStepPerReview, settings.maximumStepPerReview)
            }

            return BasalReviewHourFinding(
                hour: hour,
                cleanDays: ratios.count,
                daysNeedingMore: more,
                daysNeedingLess: less,
                medianDeliveryRatio: median,
                observedFactor: factor,
                proposedFactor: 1,
                blockedByLow: false,
                limitedByDrift: false
            )
        }

        // Basal takes time to act, so the need seen at hour h+1..h+2 is met by changing hour h.
        // Averaging the two following hours also smooths isolated one-hour signals.
        let hasLow = (0..<24).map { hour in slots.contains { $0.hourOfDay == hour && $0.hasLowAfter } }
        for hour in 0..<24 {
            var factor = (findings[(hour + 1) % 24].observedFactor + findings[(hour + 2) % 24].observedFactor) / 2
            if factor > 1, hasLow[hour] {
                factor = 1
                findings[hour].blockedByLow = true
            }
            findings[hour].proposedFactor = factor
        }

        // Build the proposed schedule from the current one.
        var boundaries = Set(schedule.map(\.startTime))
        for hour in 0..<24 where findings[hour].proposedFactor != findings[(hour + 23) % 24].proposedFactor {
            boundaries.insert(TimeInterval(hour) * 3600)
        }
        boundaries.insert(0)
        let starts = boundaries.sorted()

        var proposed: [RepeatingScheduleValue<Double>] = []
        for start in starts {
            let hour = min(23, Int(start / 3600))
            let current = Self.rate(at: start, in: schedule)
            let base = Self.rate(at: start, in: baseline.isEmpty ? schedule : baseline)
            let factor = findings[hour].proposedFactor
            let (newRate, driftLimited) = limitedRate(current: current, factor: factor, baseline: base,
                                                      maximumBasalRate: input.maximumBasalRate,
                                                      supportedRates: input.supportedBasalRates)
            if driftLimited {
                findings[hour].limitedByDrift = true
            }
            proposed.append(RepeatingScheduleValue(startTime: start, value: newRate))
        }
        proposed = Self.merged(proposed)

        // Record the final effective factor so the UI tells the truth about what changed.
        for hour in 0..<24 {
            let t = TimeInterval(hour) * 3600
            let current = Self.rate(at: t, in: schedule)
            if current > 0 {
                findings[hour].proposedFactor = Self.rate(at: t, in: proposed) / current
            }
        }

        result.hours = findings

        if let maxEntries = input.maximumScheduleEntryCount, proposed.count > maxEntries {
            result.skipReason = .tooManyScheduleEntries
            return result
        }

        result.proposedItems = proposed
        result.changes = Self.changes(from: schedule, to: proposed)
        return result
    }

    // MARK: - Slots

    private func makeSlots(input: BasalReviewInput,
                           schedule: [RepeatingScheduleValue<Double>],
                           calendar: Calendar,
                           windowStart: Date,
                           lowThreshold: Double) -> [Slot] {
        let slotCount = Int(settings.lookback / Self.slotLength)
        let manualBolusDates = input.doses
            .filter { $0.type == .bolus && $0.automatic != true }
            .map(\.startDate)
        let suspends = input.doses.filter { $0.type == .suspend }

        return (0..<slotCount).map { index in
            let start = windowStart.addingTimeInterval(TimeInterval(index) * Self.slotLength)
            let end = start.addingTimeInterval(Self.slotLength)
            let hourOfDay = calendar.component(.hour, from: start)
            let exclusionStart = start.addingTimeInterval(-settings.mealAndBolusExclusion)

            let readings = input.glucose.filter { $0.date >= start && $0.date < end }
            let lowWindowEnd = end.addingTimeInterval(settings.lowLookahead)
            let hasLowAfter = input.glucose.contains { $0.date >= start && $0.date < lowWindowEnd && $0.mgdL < lowThreshold }

            var isClean = true
            if input.carbEntryDates.contains(where: { $0 >= exclusionStart && $0 < end }) { isClean = false }
            if manualBolusDates.contains(where: { $0 >= exclusionStart && $0 < end }) { isClean = false }
            if input.overrideIntervals.contains(where: { Self.overlap($0.start, $0.end, start, end) > 0 }) { isClean = false }
            if suspends.contains(where: { Self.overlap($0.startDate, max($0.endDate, $0.startDate.addingTimeInterval(1)), start, end) > 0 }) { isClean = false }
            if readings.count < settings.minimumReadingsPerHour { isClean = false }
            if readings.contains(where: \.wasUserEntered) { isClean = false }

            var ratio: Double?
            if isClean {
                ratio = deliveryRatio(doses: input.doses, schedule: schedule, calendar: calendar, start: start, end: end)
                if ratio == nil { isClean = false }
            }

            return Slot(start: start, hourOfDay: hourOfDay, isClean: isClean, deliveryRatio: ratio, hasLowAfter: hasLowAfter)
        }
    }

    /// Delivered insulin ÷ scheduled insulin for one slot. Automatic boluses (Loop's
    /// automatic bolus dosing strategy) count as delivery; manual boluses already exclude the slot.
    private func deliveryRatio(doses: [DoseEntry],
                               schedule: [RepeatingScheduleValue<Double>],
                               calendar: Calendar,
                               start: Date, end: Date) -> Double? {
        let scheduledUnits = Self.scheduledUnits(schedule: schedule, calendar: calendar, start: start, end: end)
        guard scheduledUnits > 0.01 else { return nil }

        var delivered = 0.0
        var covered: TimeInterval = 0
        for dose in doses {
            switch dose.type {
            case .basal, .tempBasal:
                let seconds = Self.overlap(dose.startDate, dose.endDate, start, end)
                guard seconds > 0 else { continue }
                delivered += dose.unitsPerHour * seconds / 3600
                covered += seconds
            case .bolus where dose.automatic == true:
                if dose.startDate >= start && dose.startDate < end {
                    delivered += dose.deliveredUnits ?? dose.programmedUnits
                }
            default:
                continue
            }
        }

        let length = end.timeIntervalSince(start)
        // Overlapping basal records mean the history is ambiguous; don't guess.
        guard covered <= length * 1.05 else { return nil }
        // Any uncovered time is assumed to have run at the scheduled rate.
        if covered < length {
            delivered += scheduledUnits * (length - covered) / length
        }
        return delivered / scheduledUnits
    }

    // MARK: - Guardrails

    /// Applies the drift limit, maximum basal and pump rounding to one proposed rate.
    /// A rate never moves the opposite way from what was asked, and never moves further from the
    /// baseline than allowed.
    private func limitedRate(current: Double, factor: Double, baseline: Double,
                             maximumBasalRate: Double?, supportedRates: [Double]) -> (Double, Bool) {
        guard factor != 1, current > 0 else { return (current, false) }

        let target = current * factor
        let upper = baseline * (1 + settings.maximumDriftFromBaseline)
        let lower = baseline * (1 - settings.maximumDriftFromBaseline)
        var driftLimited = false
        var rate: Double

        if factor > 1 {
            rate = max(current, min(target, upper))
            if rate < target - 1e-9 { driftLimited = true }
            if let maximumBasalRate { rate = max(current, min(rate, maximumBasalRate)) }
            rate = Self.round(rate, down: true, to: supportedRates)
            rate = max(rate, current)
        } else {
            rate = min(current, max(target, lower))
            if rate > target + 1e-9 { driftLimited = true }
            rate = Self.round(rate, down: false, to: supportedRates)
            rate = min(rate, current)
        }
        return (rate, driftLimited)
    }

    /// Rounds toward the current rate so the per-review cap is never exceeded by rounding.
    static func round(_ rate: Double, down: Bool, to supportedRates: [Double]) -> Double {
        if supportedRates.isEmpty {
            let increment = 0.05
            let steps = rate / increment
            let rounded = (down ? (steps + 1e-9).rounded(.down) : (steps - 1e-9).rounded(.up)) * increment
            return (rounded * 1000).rounded() / 1000
        }
        let sortedRates = supportedRates.sorted()
        if down {
            return sortedRates.last(where: { $0 <= rate + 1e-9 }) ?? sortedRates.first!
        } else {
            return sortedRates.first(where: { $0 >= rate - 1e-9 }) ?? sortedRates.last!
        }
    }

    // MARK: - Schedule helpers

    static func sorted(_ items: [RepeatingScheduleValue<Double>]) -> [RepeatingScheduleValue<Double>] {
        items.sorted { $0.startTime < $1.startTime }
    }

    /// Rate at a time of day (seconds from midnight) in a sorted schedule.
    static func rate(at secondsFromMidnight: TimeInterval, in items: [RepeatingScheduleValue<Double>]) -> Double {
        guard let first = items.first else { return 0 }
        return items.last(where: { $0.startTime <= secondsFromMidnight + 1e-6 })?.value ?? first.value
    }

    static func merged(_ items: [RepeatingScheduleValue<Double>]) -> [RepeatingScheduleValue<Double>] {
        var result: [RepeatingScheduleValue<Double>] = []
        for item in sorted(items) {
            if let last = result.last, abs(last.value - item.value) < 1e-9 { continue }
            result.append(item)
        }
        return result
    }

    static func scheduledUnits(schedule: [RepeatingScheduleValue<Double>], calendar: Calendar, start: Date, end: Date) -> Double {
        let step: TimeInterval = .minutes(5)
        var units = 0.0
        var t = start
        while t < end {
            let mid = t.addingTimeInterval(step / 2)
            let seconds = mid.timeIntervalSince(calendar.startOfDay(for: mid))
            units += rate(at: seconds, in: schedule) * step / 3600
            t = t.addingTimeInterval(step)
        }
        return units
    }

    static func changes(from current: [RepeatingScheduleValue<Double>],
                        to proposed: [RepeatingScheduleValue<Double>]) -> [BasalReviewChange] {
        let starts = Set(current.map(\.startTime) + proposed.map(\.startTime) + [0]).sorted()
        var changes: [BasalReviewChange] = []
        for (index, start) in starts.enumerated() {
            let end = index + 1 < starts.count ? starts[index + 1] : day
            let old = rate(at: start, in: current)
            let new = rate(at: start, in: proposed)
            guard abs(old - new) > 1e-9 else { continue }
            if var last = changes.last, last.endTime == start, last.currentRate == old, last.proposedRate == new {
                last.endTime = end
                changes[changes.count - 1] = last
            } else {
                changes.append(BasalReviewChange(startTime: start, endTime: end, currentRate: old, proposedRate: new))
            }
        }
        return changes
    }

    // MARK: - Math

    static func overlap(_ aStart: Date, _ aEnd: Date, _ bStart: Date, _ bEnd: Date) -> TimeInterval {
        max(0, min(aEnd, bEnd).timeIntervalSince(max(aStart, bStart)))
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        min(max(value, lower), upper)
    }
}
