//
//  GlucoseAwareIOBLimitSelectionView.swift
//  Loop
//
//  Settings → Algorithm Experiments → Glucose-Aware IOB Limit
//

import SwiftUI
import HealthKit
import LoopKit
import LoopKitUI

public struct GlucoseAwareIOBLimitSelectionView: View {
    @EnvironmentObject private var displayGlucosePreference: DisplayGlucosePreference

    @Binding var isEnabled: Bool

    // Stored in mg/dL regardless of display unit.
    @AppStorage(UserDefaults.GlucoseAwareIOBLimitKey.breakpoint)
    private var breakpoint: Double = GlucoseAwareIOBLimit.defaultSensitivityBreakpoint

    @AppStorage(UserDefaults.GlucoseAwareIOBLimitKey.lowRangeSensitivity)
    private var lowRangeSensitivity: Double = GlucoseAwareIOBLimit.defaultLowRangeSensitivity

    public init(isEnabled: Binding<Bool>) {
        self._isEnabled = isEnabled
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(NSLocalizedString("Glucose-Aware IOB Limit", comment: "Title of glucose-aware IOB limit experiment"))
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 10)

                Divider()

                Text(String(format: NSLocalizedString(
                    "Limits how much insulin Loop's automatic dosing can stack up, based on your current glucose.\n\nAbove the breakpoint, Loop uses your normal Insulin Sensitivity. Below it, Loop assumes the stronger sensitivity you enter here. Automatic dosing will not build insulin on board beyond what would bring you to the bottom of your correction range (plus what's needed for carbs on board).\n\nThis only ever reduces automatic insulin. It does not change predictions, manual bolus recommendations, or Loop's normal suspend behavior, and it does not lower your basal below scheduled on its own.\n\nTrade-off: Loop will respond more slowly to unannounced rises, such as an unlogged meal.\n\nCurrently: below %1$@, 1 U is expected to lower glucose by %2$@.",
                    comment: "Description of glucose-aware IOB limit (1: breakpoint, 2: low-range sensitivity)"),
                    glucoseString(breakpoint), sensitivityString(lowRangeSensitivity)))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                Toggle(NSLocalizedString("Enable Glucose-Aware IOB Limit", comment: "Toggle title for glucose-aware IOB limit"), isOn: $isEnabled)
                    .padding(.vertical, 6)

                Divider()

                Group {
                    valueRow(
                        title: NSLocalizedString("Breakpoint", comment: "Glucose-aware IOB limit breakpoint setting title"),
                        detail: NSLocalizedString("Below this glucose you're more sensitive to insulin.", comment: "Glucose-aware IOB limit breakpoint setting detail"),
                        valueText: glucoseString(breakpoint),
                        value: $breakpoint,
                        range: GlucoseAwareIOBLimit.sensitivityBreakpointRange
                    )

                    Divider()

                    valueRow(
                        title: NSLocalizedString("Sensitivity Below Breakpoint", comment: "Glucose-aware IOB limit low-range sensitivity setting title"),
                        detail: NSLocalizedString("How far 1 U lowers you when you're below the breakpoint. Higher = more sensitive = less automatic insulin.", comment: "Glucose-aware IOB limit low-range sensitivity setting detail"),
                        valueText: sensitivityString(lowRangeSensitivity),
                        value: $lowRangeSensitivity,
                        range: GlucoseAwareIOBLimit.lowRangeSensitivityRange
                    )

                    Button(NSLocalizedString("Reset to Defaults", comment: "Button to reset glucose-aware IOB limit values")) {
                        breakpoint = GlucoseAwareIOBLimit.defaultSensitivityBreakpoint
                        lowRangeSensitivity = GlucoseAwareIOBLimit.defaultLowRangeSensitivity
                    }
                    .padding(.top, 6)
                }
                .disabled(!isEnabled)
                .opacity(isEnabled ? 1 : 0.5)
            }
            .padding()
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Rows

    private func valueRow(title: String, detail: String, valueText: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Stepper(value: value, in: range, step: stepSize) {
                HStack {
                    Text(title)
                    Spacer()
                    Text(valueText)
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
            }
            Text(detail)
                .font(.footnote)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Units

    /// 5 mg/dL, or 0.1 mmol/L when displaying mmol/L. Values are stored in mg/dL.
    private var stepSize: Double {
        displayGlucosePreference.unit == .milligramsPerDeciliter ? 5 : 0.1 * 18.0182
    }

    private func glucoseString(_ mgdl: Double) -> String {
        displayGlucosePreference.format(HKQuantity(unit: .milligramsPerDeciliter, doubleValue: mgdl))
    }

    private func sensitivityString(_ mgdlPerUnit: Double) -> String {
        glucoseString(mgdlPerUnit) + "/U"
    }
}

struct GlucoseAwareIOBLimitSelectionView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            GlucoseAwareIOBLimitSelectionView(isEnabled: .constant(true))
                .environmentObject(DisplayGlucosePreference(displayGlucoseUnit: .milligramsPerDeciliter))
        }
    }
}
