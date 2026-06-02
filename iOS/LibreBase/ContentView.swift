//
//  ContentView.swift
//  LibreBase
//
//  Created by Michel Storms on 02/06/2026.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var scale: ScaleClient
    @EnvironmentObject var health: Health
    @AppStorage("autoSaveToHealth") private var autoSaveToHealth = true
    @AppStorage("heightCm") private var heightCm = 0.0
    @State private var showHeightSheet = false
    @State private var pickerCmValue = 170   // wheel selection, metric (cm)
    @State private var pickerFeet = 5         // wheel selection, imperial
    @State private var pickerInches = 7

    /// Show height in feet/inches in imperial regions, centimeters otherwise.
    private var useMetric: Bool { Locale.current.measurementSystem == .metric }

    // Weight is always stored in kilograms; display it in the user's preferred
    // unit (pounds in imperial regions). Saving to Health is unaffected.
    private var weightText: String {
        guard let r = scale.lastReading else { return "—" }
        if useMetric { return String(format: "%.1f kg", r.weightKg) }
        return String(format: "%.1f lb", r.weightKg / 0.45359237)
    }

    // BMI is computed in-app from a locally stored height. We deliberately ignore
    // the scale's own BMI: it depends on a height set via the (discontinued)
    // Qardio app and is often stale, for another user, or absent entirely.
    private var bmi: Double? {
        guard let r = scale.lastReading, heightCm > 0 else { return nil }
        let m = heightCm / 100
        return r.weightKg / (m * m)
    }

    /// Current height rendered in the user's preferred unit, or a prompt if unset.
    private var heightLabel: String {
        guard heightCm > 0 else { return "Set height" }
        if useMetric { return "\(Int(heightCm.rounded())) cm" }
        let totalIn = Int((heightCm / 2.54).rounded())
        return "\(totalIn / 12)′ \(totalIn % 12)″"
    }

    /// Seed the wheel(s) from the stored height before presenting, clamped to the
    /// picker's range. Defaults to a sensible value when no height is set yet.
    private func seedHeightPicker() {
        if useMetric {
            let cm = heightCm > 0 ? Int(heightCm.rounded()) : 170
            pickerCmValue = min(max(cm, 120), 220)
        } else {
            let totalIn = heightCm > 0 ? Int((heightCm / 2.54).rounded()) : 67
            let clamped = min(max(totalIn, 36), 95)   // 3′0″…7′11″
            pickerFeet = clamped / 12
            pickerInches = clamped % 12
        }
    }

    private var heightPicker: some View {
        NavigationView {
            Group {
                if useMetric {
                    Picker("Height", selection: $pickerCmValue) {
                        ForEach(120...220, id: \.self) { Text("\($0) cm").tag($0) }
                    }
                    .pickerStyle(.wheel)
                } else {
                    HStack(spacing: 0) {
                        Picker("Feet", selection: $pickerFeet) {
                            ForEach(3...7, id: \.self) { Text("\($0) ft").tag($0) }
                        }
                        .pickerStyle(.wheel)
                        .frame(maxWidth: .infinity)
                        Picker("Inches", selection: $pickerInches) {
                            ForEach(0...11, id: \.self) { Text("\($0) in").tag($0) }
                        }
                        .pickerStyle(.wheel)
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .navigationTitle("Height")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        let cm = useMetric
                            ? Double(pickerCmValue)
                            : Double(pickerFeet * 12 + pickerInches) * 2.54
                        heightCm = cm
                        showHeightSheet = false
                        // Keep Apple Health in sync with the edit.
                        Task { try? await health.saveHeight(cm: cm) }
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
                // Top bar
                HStack {
                    Text("LibreBase")
                        .font(.title2)
                        .bold()
                    Spacer()
                    Text("Weight")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 8)

                // Status + battery
                HStack {
                    Text(scale.status)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(scale.batteryStatusLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4)

                // Reading card
                VStack(spacing: 8) {
                    if let r = scale.lastReading {
                        Text(weightText)
                            .font(.system(size: 44, weight: .bold, design: .rounded))
                            .contentTransition(.numericText())
                        if let bmi {
                            Label(String(format: "BMI %.1f", bmi), systemImage: "figure")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else {
                            Label("Set your height for BMI", systemImage: "ruler")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Text(r.timestamp, format: Date.FormatStyle(date: .abbreviated, time: .shortened))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Step on the scale")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text("Your weight will appear here.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                // Retry button when disconnected. Placed above the settings on
                // purpose: its appearance/disappearance shifts the UI, drawing
                // attention to the fact that the scale needs to be reconnected.
                if !scale.isConnected {
                    Button("Retry Connect") { scale.startConnect() }
                        .buttonStyle(.bordered)
                }

                // Save to Health toggle
                Toggle("Save to Apple Health", isOn: $autoSaveToHealth)

                // Height — used to compute BMI in-app (the scale's BMI can't be
                // trusted without the Qardio app). Tapping opens a unit-aware
                // wheel picker; the choice is written back to Apple Health.
                Button {
                    seedHeightPicker()
                    showHeightSheet = true
                } label: {
                    HStack {
                        Text("Height")
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(heightLabel)
                            .foregroundStyle(heightCm > 0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.accentColor))
                    }
                }

                // Recon mode toggle (Phase 1 GATT capture) — always available so
                // it can be turned back on to capture a new device/cycle.
                Toggle("Recon mode (BLE capture)", isOn: $scale.reconMode)

                // Recon log — shown only while in recon mode
                if scale.reconMode {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Recon log")
                            .font(.footnote.bold())
                            .frame(maxWidth: .infinity, alignment: .leading)
                        ScrollView {
                            Text(scale.reconLog.isEmpty
                                 ? "Discovering services… step on the scale to capture payloads."
                                 : scale.reconLog.joined(separator: "\n"))
                                .font(.system(.caption2, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 160)
                        .padding(8)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }

                Spacer(minLength: 8)

                // Footer
                VStack(spacing: 4) {
                    Link("GitHub: stormychel/LibreBase",
                         destination: URL(string: "https://github.com/stormychel/LibreBase")!)
                        .font(.footnote)
                    if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                        Text("Version \(version)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, 8)
            }
            .padding(.horizontal, 20)
            .navigationBarHidden(true)
            .sheet(isPresented: $showHeightSheet) { heightPicker }
            .task {
                // Register the save callback before awaiting authorization: the
                // permission prompt suspends this task, and a weigh-in could
                // finalize while it's up. Installing it first avoids dropping
                // that first reading.
                scale.onFinalReading = { reading in
                    guard autoSaveToHealth else { return }
                    Task { @MainActor in
                        do {
                            try await health.saveWeight(kg: reading.weightKg, date: reading.timestamp)
                            scale.status = "Saved to Apple Health"
                        } catch {
                            scale.status = "Couldn't save to Health — check Settings ▸ Privacy ▸ Health"
                        }
                    }
                }

                do {
                    try await health.requestAuth()
                } catch {
                    scale.status = "Health permission denied"
                }

                // Seed height from Apple Health when the user hasn't set one
                // locally, so BMI works without manual entry. A manual value
                // always wins — we never overwrite it.
                if heightCm == 0, let h = await health.latestHeightCm() {
                    heightCm = h
                }
            }
        }
    }
}
