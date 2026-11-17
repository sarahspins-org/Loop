//
//  GlucoseAwareIOBLimit.swift
//  Loop
//
//  Caps how much insulin automatic dosing may stack, based on current glucose,
//  using a two-zone sensitivity model: your scheduled insulin sensitivity
//  above a breakpoint, and a stronger (larger mg/dL-per-unit) sensitivity below it.
//
//  The cap is the insulin on board that would bring you from your current glucose
//  down to the bottom of your correction range, plus enough to cover carbs still
//  on board. Automatic dosing is never allowed to push IOB above it.
//
//  This only ever REDUCES automatic insulin. It does not change glucose forecasts,
//  manual bolus recommendations, or the normal suspend behavior, and it never
//  cuts your scheduled basal on its own (Loop's normal logic still can).
//

import Foundation

enum GlucoseAwareIOBLimit {

    // MARK: - Tunables (mg/dL)

    /// Set to false to turn this feature off and restore stock Loop behavior.
    static let isEnabled = true

    /// Glucose below which you are more sensitive to insulin.
    static let sensitivityBreakpoint: Double = 150

    /// How far 1 U drops you when you are below the breakpoint (mg/dL per U).
    /// Above the breakpoint, your scheduled Insulin Sensitivity setting is used.
    static let lowRangeSensitivity: Double = 190

    // MARK: - Calculation

    /// Maximum insulin on board (U) automatic dosing may build up to.
    ///
    /// - Parameters:
    ///   - glucose: current glucose, mg/dL
    ///   - correctionRangeLowerBound: bottom of the active correction range, mg/dL
    ///   - scheduledSensitivity: scheduled insulin sensitivity right now, mg/dL per U
    ///   - carbsOnBoard: active carbs, g
    ///   - carbRatio: scheduled carb ratio right now, g per U
    static func maximumInsulinOnBoard(
        glucose: Double,
        correctionRangeLowerBound: Double,
        scheduledSensitivity: Double,
        carbsOnBoard: Double,
        carbRatio: Double
    ) -> Double {
        guard scheduledSensitivity > 0 else { return 0 }

        let highSensitivity = scheduledSensitivity
        // Never treat the low zone as LESS sensitive than the schedule.
        let lowSensitivity = max(lowRangeSensitivity, scheduledSensitivity)
        let breakpoint = max(sensitivityBreakpoint, correctionRangeLowerBound)

        let highZoneUnits = max(0, glucose - breakpoint) / highSensitivity
        let lowZoneUnits = max(0, min(glucose, breakpoint) - correctionRangeLowerBound) / lowSensitivity
        let carbUnits = carbRatio > 0 ? max(0, carbsOnBoard) / carbRatio : 0

        return highZoneUnits + lowZoneUnits + carbUnits
    }
}
