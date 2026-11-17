//
//  BasalReviewSettings.swift
//  Loop
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation

/// Tunables and guardrails for the retrospective basal review.
///
/// Every number here limits how far a single review (or a series of reviews) can move the
/// scheduled basal. Change them only with care: they are the safety envelope of the feature.
public struct BasalReviewSettings: Equatable {
    /// How far back each review looks.
    public var lookback: TimeInterval = .hours(72)

    /// How often a review may run.
    public var reviewInterval: TimeInterval = .hours(24)

    /// After any change to the basal schedule (from a review or by hand), no new suggestion is made
    /// until this much data exists under the new schedule.
    public var cooldownAfterScheduleChange: TimeInterval = .hours(72)

    /// An hour is ignored if carbs or a manual bolus happened this long before (or during) it.
    public var mealAndBolusExclusion: TimeInterval = .hours(4)

    /// Basal given at an hour affects glucose for roughly this long afterwards. A low inside this
    /// window blocks raising the basal for that hour.
    public var lowLookahead: TimeInterval = .hours(3)

    /// Lows are anything below max(this, the suspend threshold), in mg/dL.
    public var lowGlucoseFloorMgdL: Double = 70

    /// Minimum CGM readings needed in a one-hour slot for it to count (12 is a full hour at 5 min).
    public var minimumReadingsPerHour: Int = 9

    /// How far Loop's actual delivery must differ from the schedule, as a fraction, for an hour to count
    /// as "needed more" or "needed less".
    public var deadband: Double = 0.10

    /// Days (out of the 3 in the lookback) that must be clean for an hour to be considered.
    public var minimumCleanDays: Int = 2

    /// Days that must agree on the direction, with none disagreeing.
    public var minimumAgreeingDays: Int = 2

    /// Fraction of the observed difference to propose. 0.5 means Loop running +30% suggests +15%
    /// (before the per-review cap).
    public var damping: Double = 0.5

    /// Largest change to any part of the schedule in a single review, as a fraction.
    public var maximumStepPerReview: Double = 0.10

    /// Largest total drift, as a fraction, away from the baseline schedule the user confirmed.
    public var maximumDriftFromBaseline: Double = 0.30

    public init() {}

    public static let standard = BasalReviewSettings()
}
