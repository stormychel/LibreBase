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
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("autoSaveToHealth") private var autoSaveToHealth = true
    @AppStorage("heightCm") private var heightCm = 0.0
    @State private var showHeightSheet = false
    @State private var showSettings = false
    @State private var pickerCmValue = 170   // wheel selection, metric (cm)
    @State private var pickerFeet = 5         // wheel selection, imperial
    @State private var pickerInches = 7

    /// Show height in feet/inches in imperial regions, centimeters otherwise.
    private var useMetric: Bool { Locale.current.measurementSystem == .metric }

    // Weight is always stored in kilograms; display it in the user's preferred
    // unit (pounds in imperial regions). Saving to Health is unaffected.
    private var weightValue: String {
        guard let r = scale.lastReading else { return "—" }
        if useMetric { return String(format: "%.1f", r.weightKg) }
        return String(format: "%.1f", r.weightKg / 0.45359237)
    }

    private var weightUnit: String { useMetric ? "kg" : "lb" }

    // BMI is computed in-app from a locally stored height. We deliberately ignore
    // the scale's own BMI: it depends on a height set via the (discontinued)
    // Qardio app and is often stale, for another user, or absent entirely.
    private var bmi: Double? {
        guard let r = scale.lastReading, heightCm > 0 else { return nil }
        let m = heightCm / 100
        return r.weightKg / (m * m)
    }

    /// Plain-language BMI band plus the color used for its badge.
    private func bmiCategory(_ value: Double) -> (label: String, color: Color) {
        switch value {
        case ..<18.5: return ("Underweight", .blue)
        case ..<25:   return ("Normal", .green)
        case ..<30:   return ("Overweight", .orange)
        default:      return ("Obese", .red)
        }
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

    var body: some View {
        ZStack {
            // A whisper of the brand gradient behind the content keeps the screen
            // on-identity without fighting the cards for attention.
            Brand.softBackground
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 18) {
                    header
                    statusPills
                    heroCard

                    // When a previous reading is on screen but the scale has since
                    // dropped (it powers down after each weigh-in), offer a manual
                    // reconnect. The no-reading disconnected case is handled inside
                    // the hero, so this only covers "result shown, link dropped".
                    if !scale.isConnected && scale.lastReading != nil {
                        Button {
                            scale.startConnect()
                        } label: {
                            Label("Reconnect", systemImage: "arrow.clockwise")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Brand.gradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .foregroundStyle(.white)
                        }
                    }

                    settingsCard
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
        }
        .sheet(isPresented: $showHeightSheet) { heightPicker }
        .sheet(isPresented: $showSettings) { settingsSheet }
        .onChange(of: scenePhase) { _, phase in
            // iOS suspends BLE scans in the background; re-arm one on return so the
            // scale reconnects on its own without the user tapping Reconnect.
            if phase == .active { scale.resumeScanning() }
        }
        .task {
            // Safety net: onboarding normally creates the Bluetooth central in its
            // permission step, but users upgrading past onboarding never saw it —
            // start it here too. Idempotent.
            scale.start()

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

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image("BrandIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("LibreBase")
                    .font(.title2.bold())
                if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                    Text("v\(version)")
                        .font(.caption.weight(.light))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            Spacer()

            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Settings")
        }
    }

    // MARK: - Status pills

    private var statusPills: some View {
        HStack(spacing: 10) {
            pill(
                systemImage: scale.isConnected ? "dot.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash",
                text: scale.status,
                tint: scale.isConnected ? Brand.teal : .orange
            )
            Spacer(minLength: 0)
            pill(
                systemImage: batterySymbol,
                text: batteryShort,
                tint: batteryTint
            )
        }
    }

    private func pill(systemImage: String, text: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
            Text(text)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .font(.footnote)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var batterySymbol: String {
        guard let pct = scale.batteryLevelPct else { return "battery.0percent" }
        switch pct {
        case ..<15:  return "battery.25percent"
        case ..<55:  return "battery.50percent"
        case ..<85:  return "battery.75percent"
        default:     return "battery.100percent"
        }
    }

    private var batteryShort: String {
        guard let pct = scale.batteryLevelPct else { return "Battery —" }
        return "\(pct)%"
    }

    private var batteryTint: Color {
        guard let pct = scale.batteryLevelPct else { return .secondary }
        return pct <= 20 ? .orange : Brand.teal
    }

    // MARK: - Hero card

    private var heroCard: some View {
        VStack(spacing: 14) {
            if scale.lastReading != nil {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(weightValue)
                        .font(.system(size: 72, weight: .bold, design: .rounded))
                        .contentTransition(.numericText())
                    Text(weightUnit)
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .foregroundStyle(.white)

                if let bmi {
                    let cat = bmiCategory(bmi)
                    HStack(spacing: 8) {
                        Circle()
                            .fill(cat.color)
                            .frame(width: 9, height: 9)
                        Text("\(cat.label) · BMI \(String(format: "%.1f", bmi))")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(.white.opacity(0.18), in: Capsule())
                } else {
                    Button {
                        seedHeightPicker()
                        showHeightSheet = true
                    } label: {
                        Label("Add height for BMI", systemImage: "ruler")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(.white.opacity(0.18), in: Capsule())
                    }
                }

                if let r = scale.lastReading {
                    Text(r.timestamp, format: Date.FormatStyle(date: .abbreviated, time: .shortened))
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.8))
                }
            } else if scale.isConnected {
                // Connected and idle: the scale is reachable, so inviting a
                // step-on is honest.
                Image(systemName: "figure.stand")
                    .font(.system(size: 52, weight: .light))
                    .foregroundStyle(.white)
                Text("Step on the scale")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                Text("Your weight will appear here automatically.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
            } else {
                // Not connected: don't pretend the scale is ready. The app keeps
                // scanning on its own (see ScaleClient), so stepping on the scale
                // usually reconnects without a tap — but make Reconnect the clear,
                // prominent action in case it doesn't.
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .scaleEffect(1.3)
                    .padding(.bottom, 4)
                Text("Connecting to your scale")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                Text(scale.status)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.9))
                    .multilineTextAlignment(.center)
                Button {
                    scale.startConnect()
                } label: {
                    Label("Reconnect", systemImage: "arrow.clockwise")
                        .font(.headline)
                        .foregroundStyle(Brand.teal)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 13)
                        .background(.white, in: Capsule())
                        .shadow(color: Brand.deep.opacity(0.25), radius: 8, y: 4)
                }
                .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, 20)
        .background(Brand.gradient, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: Brand.deep.opacity(0.3), radius: 18, y: 10)
        .animation(.easeInOut(duration: 0.3), value: scale.isConnected)
    }

    // MARK: - Settings card (on the main screen)

    private var settingsCard: some View {
        VStack(spacing: 0) {
            Toggle("Save to Apple Health", isOn: $autoSaveToHealth)
                .padding(.vertical, 14)
                .padding(.horizontal, 16)

            Divider().padding(.leading, 16)

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
                        .foregroundStyle(heightCm > 0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(Brand.teal))
                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 14)
                .padding(.horizontal, 16)
            }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: - Settings sheet (developer / about)

    private var settingsSheet: some View {
        NavigationStack {
            List {
                Section {
                    // Recon mode toggle (Phase 1 GATT capture) — kept out of the
                    // everyday screen but always available to re-capture a new
                    // device/cycle.
                    Toggle("Recon mode (BLE capture)", isOn: $scale.reconMode)

                    if scale.reconMode {
                        ScrollView {
                            Text(scale.reconLog.isEmpty
                                 ? "Discovering services… step on the scale to capture payloads."
                                 : scale.reconLog.joined(separator: "\n"))
                                .font(.system(.caption2, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 220)
                    }
                } header: {
                    Text("Developer")
                } footer: {
                    Text("Recon mode logs the scale's raw Bluetooth services and payloads — useful for adding support for new QardioBase hardware.")
                }

                Section {
                    Link(destination: URL(string: "https://github.com/stormychel/LibreBase")!) {
                        Label("stormychel/LibreBase", systemImage: "link")
                    }
                } header: {
                    Text("About")
                } footer: {
                    if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                        Text("LibreBase \(version) · open source, MIT licensed.")
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showSettings = false }
                }
            }
        }
        .presentationDetents([.large])
    }

    // MARK: - Height picker

    private var heightPicker: some View {
        NavigationStack {
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
}
