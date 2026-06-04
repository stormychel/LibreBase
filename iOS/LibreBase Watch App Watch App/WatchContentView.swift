//
//  WatchContentView.swift
//  LibreBase Watch App
//
//  Created by Michel Storms on 04/06/2026.
//

import SwiftUI

/// Read-only glance of the latest weigh-in from Apple Health. Refreshes when the
/// view appears, when the app returns to the foreground, and on pull-to-refresh —
/// HealthKit doesn't push, and the iPhone writes the actual readings.
struct WatchContentView: View {
    @EnvironmentObject var health: WatchHealth
    @Environment(\.scenePhase) private var scenePhase

    @State private var weightKg: Double?
    @State private var weighedAt: Date?
    @State private var heightCm: Double?
    @State private var loaded = false

    private var useMetric: Bool { Locale.current.measurementSystem == .metric }

    private var weightValue: String? {
        guard let kg = weightKg else { return nil }
        return useMetric ? String(format: "%.1f", kg) : String(format: "%.1f", kg / 0.45359237)
    }

    private var weightUnit: String { useMetric ? "kg" : "lb" }

    private var bmi: Double? {
        guard let kg = weightKg, let h = heightCm, h > 0 else { return nil }
        let m = h / 100
        return kg / (m * m)
    }

    private func bmiCategory(_ value: Double) -> (label: String, color: Color) {
        switch value {
        case ..<18.5: return ("Underweight", .blue)
        case ..<25:   return ("Normal", .green)
        case ..<30:   return ("Overweight", .orange)
        default:      return ("Obese", .red)
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                if let weightValue {
                    weightCard(weightValue)
                } else if loaded {
                    emptyState
                } else {
                    ProgressView()
                        .padding(.top, 24)
                }
            }
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("LibreBase")
        .task { await load() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await load() } }
        }
        .refreshable { await load() }
    }

    private func weightCard(_ value: String) -> some View {
        VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                Text(weightUnit)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .foregroundStyle(.white)

            if let bmi {
                let cat = bmiCategory(bmi)
                HStack(spacing: 6) {
                    Circle().fill(cat.color).frame(width: 7, height: 7)
                    Text("\(cat.label) · BMI \(String(format: "%.1f", bmi))")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                }
            }

            if let weighedAt {
                Text(weighedAt, format: Date.FormatStyle(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .padding(.horizontal, 12)
        .background(WatchBrand.gradient, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "figure.stand")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(WatchBrand.teal)
            Text("No weigh-in yet")
                .font(.headline)
            Text("Step on your QardioBase with the LibreBase iPhone app — your latest weight shows up here.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 16)
    }

    private func load() async {
        try? await health.requestReadAuth()
        // Assign unconditionally so a deleted sample / revoked access clears the
        // card instead of leaving a stale reading on screen.
        let latest = await health.latestWeight()
        weightKg = latest?.kg
        weighedAt = latest?.date
        heightCm = await health.latestHeightCm()
        loaded = true
    }
}
