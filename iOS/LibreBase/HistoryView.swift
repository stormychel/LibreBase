//
//  HistoryView.swift
//  LibreBase
//
//  Created by Michel Storms on 15/10/2026.
//

import Charts
import SwiftUI

/// Recent weigh-ins and a weight trend, read back from Apple Health so Health
/// stays the source of truth (#16). Includes weights from any app, not just
/// LibreBase.
struct HistoryView: View {
    @EnvironmentObject var health: Health
    @Environment(\.dismiss) private var dismiss
    @AppStorage("heightCm") private var heightCm = 0.0

    let useMetric: Bool

    enum Range: String, CaseIterable, Identifiable {
        case month = "30 days"
        case quarter = "90 days"
        case year = "1 year"

        var id: Self { self }

        var days: Int {
            switch self {
            case .month:   return 30
            case .quarter: return 90
            case .year:    return 365
            }
        }
    }

    @State private var range: Range = .quarter
    @State private var weighIns: [WeighIn] = []
    @State private var isLoading = true

    private var unit: String { useMetric ? "kg" : "lb" }

    private func display(_ kg: Double) -> Double { useMetric ? kg : kg / 0.45359237 }

    private func bmi(_ kg: Double) -> Double? {
        guard heightCm > 0 else { return nil }
        let m = heightCm / 100
        return kg / (m * m)
    }

    /// Change over the range, oldest to newest weigh-in.
    private var changeLine: String? {
        guard let newest = weighIns.first, let oldest = weighIns.last, weighIns.count > 1 else { return nil }
        let delta = display(newest.weightKg) - display(oldest.weightKg)
        return String(format: "%@%.1f %@ over %@", delta > 0 ? "+" : "", delta, unit, range.rawValue)
    }

    /// Y axis padded around the data so small changes stay visible instead of
    /// being flattened against a zero baseline.
    private var yDomain: ClosedRange<Double> {
        let values = weighIns.map { display($0.weightKg) }
        guard let lo = values.min(), let hi = values.max() else { return 0...1 }
        let pad = max((hi - lo) * 0.2, 1)
        return (lo - pad)...(hi + pad)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Range", selection: $range) {
                        ForEach(Range.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }

                if isLoading {
                    Section {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    }
                } else if weighIns.isEmpty {
                    Section {
                        ContentUnavailableView(
                            "No weigh-ins",
                            systemImage: "chart.xyaxis.line",
                            description: Text("Nothing in Apple Health for the last \(range.rawValue). If you have weighed in, allow LibreBase to read Weight in Settings ▸ Privacy ▸ Health ▸ LibreBase.")
                        )
                    }
                } else {
                    Section {
                        chart
                            .frame(height: 200)
                            .padding(.vertical, 8)
                    } footer: {
                        if let changeLine { Text(changeLine) }
                    }

                    Section("Weigh-ins") {
                        ForEach(weighIns) { row($0) }
                    }
                }
            }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task(id: range) { await load() }
        }
    }

    private var chart: some View {
        Chart(weighIns) { w in
            LineMark(
                x: .value("Date", w.date),
                y: .value("Weight", display(w.weightKg))
            )
            .interpolationMethod(.monotone)
            .foregroundStyle(Brand.gradient)

            PointMark(
                x: .value("Date", w.date),
                y: .value("Weight", display(w.weightKg))
            )
            .symbolSize(weighIns.count > 40 ? 12 : 30)
            .foregroundStyle(Brand.teal)
        }
        .chartYScale(domain: yDomain)
        .chartYAxisLabel(unit)
    }

    private func row(_ w: WeighIn) -> some View {
        let weight = String(format: "%.1f %@", display(w.weightKg), unit)
        let bmiText = bmi(w.weightKg).map { String(format: "BMI %.1f", $0) }
        return HStack {
            Text(w.date, format: Date.FormatStyle(date: .abbreviated, time: .shortened))
                .foregroundStyle(.secondary)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(weight)
                    .font(.body.weight(.semibold))
                    .monospacedDigit()
                if let bmiText {
                    Text(bmiText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func load() async {
        isLoading = true
        let start = Calendar.current.date(byAdding: .day, value: -range.days, to: Date()) ?? Date()
        let result = ScreenshotMode.isActive
            ? ScreenshotMode.demoWeighIns().filter { $0.date >= start }
            : await health.weighIns(since: start)
        // The HealthKit query ignores cancellation: when the range changed while
        // it ran, the newer load owns the state, so drop this stale result.
        guard !Task.isCancelled else { return }
        weighIns = result
        isLoading = false
    }
}
