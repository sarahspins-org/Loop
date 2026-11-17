//
//  BasalReviewView.swift
//  Loop
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import SwiftUI
import Charts
import LoopKit
import LoopKitUI

/// Settings, current suggestion, and change history for the retrospective basal review.
struct BasalReviewView: View {
    let therapySettings: () -> TherapySettings
    weak var delegate: TherapySettingsViewModelDelegate?
    var showsDoneButton: Bool = false

    @ObservedObject private var store = BasalReviewStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var isWorking = false
    @State private var confirmation: Confirmation?
    @State private var resultMessage: ResultMessage?

    private enum Confirmation: Identifiable {
        case apply(BasalReview)
        case undo(BasalReviewHistoryEntry)
        case resetBaseline
        var id: String {
            switch self {
            case .apply(let review): return "apply-\(review.id)"
            case .undo(let entry): return "undo-\(entry.id)"
            case .resetBaseline: return "reset"
            }
        }
    }

    private struct ResultMessage: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    var body: some View {
        List {
            enableSection
            if store.isEnabled {
                statusSection
                if let pending = store.pending {
                    suggestionSections(pending)
                }
                baselineSection
            }
            if !store.history.isEmpty {
                historySection
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(NSLocalizedString("Basal Review", comment: "Basal review screen title"))
        .toolbar {
            if showsDoneButton {
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("Done", comment: "Done button")) { dismiss() }
                }
            }
        }
        .disabled(isWorking)
        .overlay {
            if isWorking {
                ProgressView(NSLocalizedString("Talking to pump…", comment: "Basal review progress while syncing to pump"))
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .alert(item: $confirmation, content: confirmationAlert)
        .alert(item: $resultMessage) { result in
            SwiftUI.Alert(title: Text(result.title), message: Text(result.message), dismissButton: .default(Text("OK")))
        }
    }

    // MARK: - Sections

    private var enableSection: some View {
        Section(footer: DescriptiveText(label: NSLocalizedString("Once a day Loop looks back over the last 3 days. If it had to run consistently above or below your scheduled basal at the same time of day, with no food, manual bolus or override involved, it suggests a small change. Changes are never made unless you confirm them.", comment: "Basal review description"))) {
            Toggle(NSLocalizedString("Basal Review", comment: "Basal review toggle"), isOn: Binding(
                get: { store.isEnabled },
                set: { enabled in
                    if enabled {
                        store.enable(now: Date(), currentSchedule: therapySettings().basalRateSchedule?.items)
                    } else {
                        store.disable()
                    }
                }
            ))
        }
    }

    private var statusSection: some View {
        Section(header: SectionHeader(label: NSLocalizedString("Status", comment: "Basal review status header"))) {
            Text(statusText)
            if let review = store.lastReview, let date = store.lastReviewDate {
                LabeledContent(NSLocalizedString("Last review", comment: "Basal review last review label"),
                               value: date.formatted(date: .abbreviated, time: .shortened))
                if !review.hasChanges {
                    Text(noChangeText(review)).font(.footnote).foregroundColor(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func suggestionSections(_ review: BasalReview) -> some View {
        Section(header: SectionHeader(label: NSLocalizedString("Suggestion", comment: "Basal review suggestion header")),
                footer: DescriptiveText(label: String(format: NSLocalizedString("Based on %1$@ – %2$@. Each change is limited to 10%%, and the schedule can't move more than 30%% from your baseline.", comment: "Basal review suggestion footer (1: start, 2: end)"),
                                                     review.windowStart.formatted(date: .abbreviated, time: .shortened),
                                                     review.windowEnd.formatted(date: .abbreviated, time: .shortened)))) {
            scheduleChart(review)
                .frame(height: 180)
                .padding(.vertical, 8)

            ForEach(review.changes, id: \.startTime) { change in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(timeRange(change, in: review.timeZone)).font(.headline)
                        Spacer()
                        Text(rateChange(change)).monospacedDigit()
                    }
                    Text(reason(for: change, in: review)).font(.footnote).foregroundColor(.secondary)
                }
                .padding(.vertical, 2)
            }

            if review.reachedDriftLimit {
                Label(NSLocalizedString("Some times of day have reached the 30% limit from your baseline. If Loop keeps needing more change there, talk with your care team before resetting the baseline.", comment: "Basal review drift limit warning"), systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundColor(.orange)
            }
        }

        Section {
            Button {
                confirmation = .apply(review)
            } label: {
                Text(NSLocalizedString("Do It", comment: "Basal review apply button"))
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .listRowBackground(Color.clear)

            Button(NSLocalizedString("Not Now", comment: "Basal review dismiss button"), role: .cancel) {
                store.pending = nil
                NotificationManager.removeBasalReviewNotification()
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var baselineSection: some View {
        Section(header: SectionHeader(label: NSLocalizedString("Baseline", comment: "Basal review baseline header")),
                footer: DescriptiveText(label: NSLocalizedString("Suggestions can move your schedule at most 30% away from this baseline. Reset it only after reviewing your basal rates, ideally with your care team.", comment: "Basal review baseline footer"))) {
            if let baseline = store.baseline {
                ForEach(Array(baseline.enumerated()), id: \.offset) { _, item in
                    LabeledContent(time(item.startTime, in: therapySettings().basalRateSchedule?.timeZone ?? .current),
                                   value: rateText(item.value))
                }
            }
            Button(NSLocalizedString("Reset Baseline to Current Schedule", comment: "Basal review reset baseline button")) {
                confirmation = .resetBaseline
            }
        }
    }

    private var historySection: some View {
        let undoable = store.undoableEntry(currentSchedule: therapySettings().basalRateSchedule?.items)
        return Section(header: SectionHeader(label: NSLocalizedString("History", comment: "Basal review history header"))) {
            ForEach(store.history.reversed()) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.kind == .applied
                         ? NSLocalizedString("Suggestion applied", comment: "Basal review history: applied")
                         : NSLocalizedString("Change undone", comment: "Basal review history: undone"))
                    Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.footnote).foregroundColor(.secondary)
                    if entry == undoable {
                        Button(NSLocalizedString("Undo This Change", comment: "Basal review undo button")) {
                            confirmation = .undo(entry)
                        }
                        .padding(.top, 4)
                    }
                }
            }
        }
    }

    // MARK: - Chart

    private struct ChartPoint: Identifiable {
        let id = UUID()
        let hour: Double
        let rate: Double
        let series: String
    }

    private func scheduleChart(_ review: BasalReview) -> some View {
        let current = NSLocalizedString("Current", comment: "Basal review chart series: current schedule")
        let proposed = NSLocalizedString("Suggested", comment: "Basal review chart series: suggested schedule")
        var points: [ChartPoint] = []
        for (items, series) in [(review.currentItems, current), (review.proposedItems, proposed)] {
            for item in BasalReviewAnalyzer.sorted(items) {
                points.append(ChartPoint(hour: item.startTime / 3600, rate: item.value, series: series))
            }
            if let last = BasalReviewAnalyzer.sorted(items).last {
                points.append(ChartPoint(hour: 24, rate: last.value, series: series))
            }
        }
        return Chart(points) { point in
            LineMark(x: .value("Hour", point.hour), y: .value("U/hr", point.rate))
                .interpolationMethod(.stepEnd)
                .foregroundStyle(by: .value("Schedule", point.series))
        }
        .chartForegroundStyleScale([current: Color.secondary, proposed: Color.accentColor])
        .chartXScale(domain: 0...24)
        .chartXAxis {
            AxisMarks(values: [0, 6, 12, 18, 24]) { value in
                AxisGridLine()
                AxisValueLabel { if let h = value.as(Double.self) { Text(time(h * 3600, in: review.timeZone)) } }
            }
        }
    }

    // MARK: - Alerts

    private func confirmationAlert(_ confirmation: Confirmation) -> SwiftUI.Alert {
        switch confirmation {
        case .apply(let review):
            return SwiftUI.Alert(
                title: Text(NSLocalizedString("Change Basal Schedule?", comment: "Basal review apply confirmation title")),
                message: Text(review.changes.map { "\(timeRange($0, in: review.timeZone)): \(rateChange($0))" }.joined(separator: "\n")
                              + "\n\n" + NSLocalizedString("The new schedule will be sent to your pump. You can undo it from this screen.", comment: "Basal review apply confirmation message")),
                primaryButton: .default(Text(NSLocalizedString("Do It", comment: "Basal review apply button"))) { apply(review) },
                secondaryButton: .cancel()
            )
        case .undo(let entry):
            return SwiftUI.Alert(
                title: Text(NSLocalizedString("Undo Change?", comment: "Basal review undo confirmation title")),
                message: Text(NSLocalizedString("Your previous basal schedule will be sent to your pump.", comment: "Basal review undo confirmation message")),
                primaryButton: .destructive(Text(NSLocalizedString("Undo", comment: "Undo button"))) { undo(entry) },
                secondaryButton: .cancel()
            )
        case .resetBaseline:
            return SwiftUI.Alert(
                title: Text(NSLocalizedString("Reset Baseline?", comment: "Basal review reset baseline title")),
                message: Text(NSLocalizedString("Your current basal schedule becomes the new baseline. Future suggestions can move up to 30% from it.", comment: "Basal review reset baseline message")),
                primaryButton: .default(Text(NSLocalizedString("Reset", comment: "Reset button"))) {
                    store.resetBaseline(to: therapySettings().basalRateSchedule?.items)
                },
                secondaryButton: .cancel()
            )
        }
    }

    private func apply(_ review: BasalReview) {
        isWorking = true
        BasalReviewApplier.apply(review, therapySettings: therapySettings(), delegate: delegate) { result in
            isWorking = false
            switch result {
            case .success:
                resultMessage = ResultMessage(title: NSLocalizedString("Basal Schedule Updated", comment: "Basal review apply success title"),
                                              message: NSLocalizedString("Your pump has the new schedule. Loop will wait 3 days before suggesting anything else.", comment: "Basal review apply success message"))
            case .failure(let error):
                resultMessage = ResultMessage(title: NSLocalizedString("Not Changed", comment: "Basal review apply failure title"),
                                              message: error.localizedDescription)
            }
        }
    }

    private func undo(_ entry: BasalReviewHistoryEntry) {
        isWorking = true
        BasalReviewApplier.undo(entry, therapySettings: therapySettings(), delegate: delegate) { result in
            isWorking = false
            switch result {
            case .success:
                resultMessage = ResultMessage(title: NSLocalizedString("Change Undone", comment: "Basal review undo success title"),
                                              message: NSLocalizedString("Your previous basal schedule is back on your pump.", comment: "Basal review undo success message"))
            case .failure(let error):
                resultMessage = ResultMessage(title: NSLocalizedString("Not Changed", comment: "Basal review apply failure title"),
                                              message: error.localizedDescription)
            }
        }
    }

    // MARK: - Text

    private var statusText: String {
        switch BasalReviewManager.readiness(store: store, at: Date()) {
        case .disabled:
            return NSLocalizedString("Off", comment: "Basal review status: off")
        case .collectingData(let until):
            return String(format: NSLocalizedString("Collecting 3 days of data. First review after %1$@.", comment: "Basal review status: collecting (1: date)"), until.formatted(date: .abbreviated, time: .shortened))
        case .coolingDown(let until):
            return String(format: NSLocalizedString("Your basal schedule changed recently. Next review after %1$@.", comment: "Basal review status: cooldown (1: date)"), until.formatted(date: .abbreviated, time: .shortened))
        case .waitingForNextReview(let at):
            return String(format: NSLocalizedString("Next review after %1$@.", comment: "Basal review status: waiting (1: date)"), at.formatted(date: .abbreviated, time: .shortened))
        case .due:
            return NSLocalizedString("A review will run after the next loop cycle.", comment: "Basal review status: due")
        }
    }

    private func noChangeText(_ review: BasalReview) -> String {
        switch review.skipReason {
        case .insufficientDoseHistory:
            return NSLocalizedString("Not enough pump history for a review.", comment: "Basal review skip: dose history")
        case .insufficientGlucoseHistory:
            return NSLocalizedString("Too few hours without food, boluses, overrides or CGM gaps to judge.", comment: "Basal review skip: glucose history")
        case .tooManyScheduleEntries:
            return NSLocalizedString("The suggested schedule would have more entries than your pump allows.", comment: "Basal review skip: entries")
        case nil:
            return NSLocalizedString("Your basal schedule looks right. No changes suggested.", comment: "Basal review: no change")
        }
    }

    private func reason(for change: BasalReviewChange, in review: BasalReview) -> String {
        // The change at hour h is driven by what Loop did at h+1 and h+2.
        let startHour = Int(change.startTime / 3600)
        let endHour = max(startHour, Int((change.endTime - 1) / 3600))
        let drivers = Set((startHour...endHour).flatMap { [($0 + 1) % 24, ($0 + 2) % 24] })
        let findings = review.hours.filter { drivers.contains($0.hour) && $0.observedFactor != 1 }
        guard let strongest = findings.max(by: { abs(($0.medianDeliveryRatio ?? 1) - 1) < abs(($1.medianDeliveryRatio ?? 1) - 1) }),
              let ratio = strongest.medianDeliveryRatio else {
            return ""
        }
        let percent = Int(((ratio - 1) * 100).rounded())
        let days = change.proposedRate > change.currentRate ? strongest.daysNeedingMore : strongest.daysNeedingLess
        return String(format: NSLocalizedString("Around %1$@, Loop delivered %2$+d%% vs. your schedule on %3$d of %4$d clean days.", comment: "Basal review reason (1: time, 2: percent, 3: days agreeing, 4: clean days)"),
                      time(TimeInterval(strongest.hour) * 3600, in: review.timeZone), percent, days, strongest.cleanDays)
    }

    private func timeRange(_ change: BasalReviewChange, in timeZone: TimeZone) -> String {
        "\(time(change.startTime, in: timeZone)) – \(time(change.endTime, in: timeZone))"
    }

    private func rateChange(_ change: BasalReviewChange) -> String {
        let percent = Int(((change.proposedRate / change.currentRate - 1) * 100).rounded())
        return String(format: "%@ → %@ (%+d%%)", rateText(change.currentRate), rateText(change.proposedRate), percent)
    }

    private static let rateFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 3
        return formatter
    }()

    private func rateText(_ rate: Double) -> String {
        let number = Self.rateFormatter.string(from: NSNumber(value: rate)) ?? "\(rate)"
        return String(format: NSLocalizedString("%@ U/hr", comment: "Basal rate format (1: rate)"), number)
    }

    private func time(_ secondsFromMidnight: TimeInterval, in timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let date = calendar.startOfDay(for: Date()).addingTimeInterval(secondsFromMidnight)
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

extension BasalReviewView {
    /// Wraps the review screen for presenting modally (from the notification).
    static func hostingController(therapySettings: @escaping () -> TherapySettings,
                                  delegate: TherapySettingsViewModelDelegate?) -> UIViewController {
        UIHostingController(rootView: NavigationView {
            BasalReviewView(therapySettings: therapySettings, delegate: delegate, showsDoneButton: true)
        })
    }
}
