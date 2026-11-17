//
//  QuickMealBolusView.swift
//  Loop
//
//  Quick meal presets: tap "Add Meal", pick Snack / Small Meal / Large Meal,
//  then verify Loop's recommended bolus and slide to deliver.
//
//  The heavy lifting (bolus recommendation, max-bolus checks, stale-data
//  notices, Face ID / passcode, saving the carb entry and enacting the bolus)
//  is all done by the stock BolusEntryViewModel, so this screen follows exactly
//  the same safety rules as the normal "Save Carbs & Deliver" flow.
//

import SwiftUI
import HealthKit
import LoopKit
import LoopKitUI
import LoopUI

// MARK: - Presets

enum MealPreset: String, CaseIterable, Identifiable {
    case snack
    case smallMeal
    case largeMeal

    var id: String { rawValue }

    /// Carb range shown to the user.
    var carbRange: ClosedRange<Double> {
        switch self {
        case .snack:     return 12...15
        case .smallMeal: return 25...40
        case .largeMeal: return 45...60
        }
    }

    /// Grams actually entered for this preset: the midpoint of the range,
    /// rounded down (slightly conservative). Change these here if you like.
    var carbGrams: Double {
        ((carbRange.lowerBound + carbRange.upperBound) / 2).rounded(.down)
    }

    var title: String {
        switch self {
        case .snack:     return NSLocalizedString("Snack", comment: "Quick meal preset: snack")
        case .smallMeal: return NSLocalizedString("Small Meal", comment: "Quick meal preset: small meal")
        case .largeMeal: return NSLocalizedString("Large Meal", comment: "Quick meal preset: large meal")
        }
    }

    var rangeDescription: String {
        String(format: NSLocalizedString("%1$ld–%2$ld g", comment: "Quick meal preset carb range (1: low, 2: high)"),
               Int(carbRange.lowerBound), Int(carbRange.upperBound))
    }

    var menuTitle: String {
        "\(title) (\(rangeDescription))"
    }

    /// Loop's default absorption-time emoji (fast / medium / slow).
    var emoji: String {
        switch self {
        case .snack:     return "🍭"
        case .smallMeal: return "🌮"
        case .largeMeal: return "🍕"
        }
    }

    func absorptionTime(from defaults: CarbStore.DefaultAbsorptionTimes) -> TimeInterval {
        switch self {
        case .snack:     return defaults.fast
        case .smallMeal: return defaults.medium
        case .largeMeal: return defaults.slow
        }
    }

    func makeCarbEntry(defaultAbsorptionTimes: CarbStore.DefaultAbsorptionTimes, now: Date = Date()) -> NewCarbEntry {
        NewCarbEntry(
            date: now,
            quantity: HKQuantity(unit: .gram(), doubleValue: carbGrams),
            startDate: now,
            foodType: emoji,
            absorptionTime: absorptionTime(from: defaultAbsorptionTimes)
        )
    }
}

// MARK: - Verify screen

struct QuickMealBolusView: View {
    @EnvironmentObject private var displayGlucosePreference: DisplayGlucosePreference
    @Environment(\.dismissAction) private var dismiss
    @Environment(\.appName) private var appName

    let preset: MealPreset
    @ObservedObject var viewModel: BolusEntryViewModel

    /// Called when the user wants the full carb entry screen instead.
    var onCustomize: () -> Void

    @State private var hasRecommendation = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 20) {
                    mealCard
                    bolusCard
                    if viewModel.isNoticeVisible, let notice = viewModel.activeNotice {
                        bolusEntryWarning(for: notice, displayGlucosePreference: displayGlucosePreference, appName: appName)
                    }
                    Button(action: onCustomize) {
                        Text("Adjust carbs or bolus…", comment: "Quick meal bolus button to open the full carb entry screen")
                    }
                    .padding(.top, 4)
                }
                .padding()
            }

            confirmArea
        }
        .background(Color(.systemGroupedBackground).edgesIgnoringSafeArea(.all))
        .navigationBarTitle(Text("Verify Bolus", comment: "Title of quick meal bolus verification screen"), displayMode: .inline)
        .supportedInterfaceOrientations(.portrait)
        .alert(item: $viewModel.activeAlert) { alert in
            bolusEntryAlert(for: alert, viewModel: viewModel, displayGlucosePreference: displayGlucosePreference)
        }
        .onReceive(viewModel.$recommendedBolus) { recommendation in
            // Always deliver exactly what Loop currently recommends.
            let amount = recommendation?.doubleValue(for: .internationalUnit()) ?? 0
            viewModel.updateEnteredBolus(amount)
            hasRecommendation = recommendation != nil
        }
    }

    // MARK: Cards

    private var mealCard: some View {
        VStack(spacing: 6) {
            Text(preset.emoji).font(.system(size: 44))
            Text(preset.title).font(.title2.bold())
            Text(String(format: NSLocalizedString("%1$@ g carbs  ·  range %2$@", comment: "Quick meal bolus carbs line (1: grams, 2: range)"),
                        String(Int(preset.carbGrams)), preset.rangeDescription))
                .font(.subheadline)
                .foregroundColor(Color(.carbTintColor))
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemGroupedBackground)))
    }

    private var bolusCard: some View {
        VStack(spacing: 12) {
            Text("Recommended Bolus", comment: "Quick meal bolus: recommended bolus label")
                .font(.headline)
                .foregroundColor(.secondary)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(hasRecommendation ? viewModel.enteredBolusAmountString : "–")
                    .font(.system(size: 54, weight: .bold, design: .rounded))
                    .foregroundColor(Color(.insulinTintColor))
                Text("U", comment: "Insulin unit abbreviation")
                    .font(.title2.bold())
                    .foregroundColor(.secondary)
            }

            Divider()

            HStack {
                summaryItem(label: Text("Glucose", comment: "Quick meal bolus: current glucose label"),
                            value: currentGlucoseString)
                Spacer()
                summaryItem(label: Text("Active Insulin", comment: "Quick meal bolus: IOB label"),
                            value: activeInsulinString)
                Spacer()
                summaryItem(label: Text("Active Carbs", comment: "Quick meal bolus: COB label"),
                            value: activeCarbsString)
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemGroupedBackground)))
    }

    private func summaryItem(label: Text, value: String) -> some View {
        VStack(spacing: 2) {
            label.font(.caption).foregroundColor(.secondary)
            Text(value).font(.subheadline.bold())
        }
    }

    private var confirmArea: some View {
        SlideToConfirm(
            title: slideTitle,
            tint: Color(.insulinTintColor),
            isEnabled: hasRecommendation && !viewModel.enacting
        ) {
            if await viewModel.didPressActionButton() {
                dismiss()
                return true
            }
            return false
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground).shadow(radius: 5).edgesIgnoringSafeArea(.bottom))
    }

    private var slideTitle: String {
        if !hasRecommendation {
            return NSLocalizedString("Calculating…", comment: "Slide control title while waiting for bolus recommendation")
        }
        if viewModel.enteredBolusAmount > 0 {
            return String(format: NSLocalizedString("Slide to deliver %1$@ U", comment: "Slide control title to deliver bolus (1: units)"),
                          viewModel.enteredBolusAmountString)
        }
        return NSLocalizedString("Slide to save carbs", comment: "Slide control title to save carbs with no bolus")
    }

    // MARK: Formatting

    private var currentGlucoseString: String {
        guard let latest = viewModel.glucoseValues.last, !viewModel.isGlucoseDataStale else { return "–" }
        return displayGlucosePreference.format(latest.quantity)
    }

    private var activeInsulinString: String {
        guard let iob = viewModel.activeInsulin else { return "–" }
        return viewModel.formatBolusAmount(iob.doubleValue(for: .internationalUnit())) + " U"
    }

    private var activeCarbsString: String {
        guard let cob = viewModel.activeCarbs else { return "–" }
        return QuantityFormatter(for: .gram()).string(from: cob) ?? "–"
    }
}

// MARK: - Slide to confirm

struct SlideToConfirm: View {
    let title: String
    var tint: Color = .accentColor
    var isEnabled: Bool = true
    /// Return `true` on success; on `false` the knob springs back.
    let onConfirm: () async -> Bool

    @State private var offset: CGFloat = 0
    @State private var isConfirming = false

    private let knobSize: CGFloat = 56
    private let inset: CGFloat = 4

    var body: some View {
        GeometryReader { geometry in
            let maxOffset = max(geometry.size.width - knobSize - inset * 2, 1)
            let progress = Double(offset / maxOffset)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(tint.opacity(isEnabled ? 0.18 : 0.08))

                Capsule()
                    .fill(tint.opacity(0.35))
                    .frame(width: offset + knobSize + inset * 2)

                Text(title)
                    .font(.headline)
                    .foregroundColor(isEnabled ? tint : .secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.leading, knobSize)
                    .opacity(1 - progress)

                Circle()
                    .fill(isEnabled ? tint : Color(.systemGray3))
                    .frame(width: knobSize, height: knobSize)
                    .overlay(
                        Group {
                            if isConfirming {
                                ProgressView().progressViewStyle(CircularProgressViewStyle(tint: .white))
                            } else {
                                Image(systemName: "chevron.right.2")
                                    .font(.title3.weight(.bold))
                                    .foregroundColor(.white)
                            }
                        }
                    )
                    .padding(inset)
                    .offset(x: offset)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard isEnabled, !isConfirming else { return }
                                offset = min(max(0, value.translation.width), maxOffset)
                            }
                            .onEnded { _ in
                                guard isEnabled, !isConfirming else { return }
                                if offset >= maxOffset * 0.9 {
                                    offset = maxOffset
                                    confirm()
                                } else {
                                    withAnimation(.spring()) { offset = 0 }
                                }
                            }
                    )
            }
        }
        .frame(height: knobSize + inset * 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            guard isEnabled, !isConfirming else { return }
            confirm()
        }
        .onChange(of: isEnabled) { enabled in
            if !enabled && !isConfirming {
                withAnimation(.spring()) { offset = 0 }
            }
        }
    }

    private func confirm() {
        isConfirming = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        Task { @MainActor in
            let succeeded = await onConfirm()
            if !succeeded {
                withAnimation(.spring()) { offset = 0 }
                isConfirming = false
            }
        }
    }
}
