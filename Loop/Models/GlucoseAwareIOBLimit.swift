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
//  Turned on/off and configured in Settings → Algorithm Experiments →
//  Glucose-Aware IOB Limit.
//

import Foundation

enum GlucoseAwareIOBLimit {

    // MARK: - Defaults and allowed ranges (mg/dL)

    static let defaultSensitivityBreakpoint: Double = 150
    static let defaultLowRangeSensitivity: Double = 190

    static let sensitivityBreakpointRange: ClosedRange<Double> = 100...250
    static let lowRangeSensitivityRange: ClosedRange<Double> = 20...400

    // MARK: - Current settings

    static var isEnabled: Bool {
        UserDefaults.standard.glucoseAwareIOBLimitEnabled
    }

    /// Glucose below which you are more sensitive to insulin (mg/dL).
    static var sensitivityBreakpoint: Double {
        UserDefaults.standard.glucoseAwareIOBLimitBreakpoint.limited(to: sensitivityBreakpointRange)
    }

    /// How far 1 U drops you below the breakpoint (mg/dL per U).
    /// Above the breakpoint, your scheduled Insulin Sensitivity setting is used.
    static var lowRangeSensitivity: Double {
        UserDefaults.standard.glucoseAwareIOBLimitLowRangeSensitivity.limited(to: lowRangeSensitivityRange)
    }

    // MARK: - Calculation

    /// Maximum insulin on board (U) automatic dosing may build up to.
    ///
    /// - Parameters:
    ///   - glucose: current glucose, mg/dL
    ///   - correctionRangeLowerBound: bottom of the active correction range, mg/dL
    ///   - scheduledSensitivity: scheduled insulin sensitivity right now, mg/dL per U
    ///   - carbsOnBoard: active carbs, g
    ///   - carbRatio: scheduled carb ratio right now, g per U
    ///   - sensitivityBreakpoint: defaults to the saved setting
    ///   - lowRangeSensitivity: defaults to the saved setting
    static func maximumInsulinOnBoard(
        glucose: Double,
        correctionRangeLowerBound: Double,
        scheduledSensitivity: Double,
        carbsOnBoard: Double,
        carbRatio: Double,
        sensitivityBreakpoint: Double = GlucoseAwareIOBLimit.sensitivityBreakpoint,
        lowRangeSensitivity: Double = GlucoseAwareIOBLimit.lowRangeSensitivity
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

// MARK: - Persistence

extension UserDefaults {
    enum GlucoseAwareIOBLimitKey {
        static let enabled = "com.loopkit.algorithmExperiments.glucoseAwareIOBLimitEnabled"
        static let breakpoint = "com.loopkit.algorithmExperiments.glucoseAwareIOBLimitBreakpoint"
        static let lowRangeSensitivity = "com.loopkit.algorithmExperiments.glucoseAwareIOBLimitLowRangeSensitivity"
    }

    var glucoseAwareIOBLimitEnabled: Bool {
        get { bool(forKey: GlucoseAwareIOBLimitKey.enabled) }
        set { set(newValue, forKey: GlucoseAwareIOBLimitKey.enabled) }
    }

    /// mg/dL
    var glucoseAwareIOBLimitBreakpoint: Double {
        get { object(forKey: GlucoseAwareIOBLimitKey.breakpoint) as? Double ?? GlucoseAwareIOBLimit.defaultSensitivityBreakpoint }
        set { set(newValue, forKey: GlucoseAwareIOBLimitKey.breakpoint) }
    }

    /// mg/dL per U
    var glucoseAwareIOBLimitLowRangeSensitivity: Double {
        get { object(forKey: GlucoseAwareIOBLimitKey.lowRangeSensitivity) as? Double ?? GlucoseAwareIOBLimit.defaultLowRangeSensitivity }
        set { set(newValue, forKey: GlucoseAwareIOBLimitKey.lowRangeSensitivity) }
    }
}

private extension Double {
    func limited(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
