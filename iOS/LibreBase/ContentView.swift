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
    @State private var showReportScale = false
    @State private var pickerCmValue = 170   // wheel selection, metric (cm)
    @State private var pickerFeet = 5         // wheel selection, imperial
    @State private var pickerInches = 7

    @ScaledMetric(relativeTo: .largeTitle) private var weightFontSize: CGFloat = 72
    @ScaledMetric(relativeTo: .title) private var unitFontSize: CGFloat = 28

    /// Show height in feet/inches in imperial regions, centimeters otherwise.
    /// Screenshot mode can pin this so the kg/lb scenes render deterministically.
    private var useMetric: Bool {
        ScreenshotMode.forcedUseMetric ?? (Locale.current.measurementSystem == .metric)
    }

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
            // Screenshot mode: show a demo weigh-in and skip the real Bluetooth /
            // Health machinery (no prompts, no scanning) so captures are clean.
            if ScreenshotMode.isActive {
                if ScreenshotMode.showsReading { scale.loadDemoReading() }
                return
            }

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
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
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

            batteryIndicator

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

    /// Compact battery readout (glyph + percentage, no label) shown left of the
    /// Settings gear in the header.
    private var batteryIndicator: some View {
        HStack(spacing: 4) {
            Image(systemName: batterySymbol)
                .foregroundStyle(batteryTint)
            Text(batteryPercent)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(scale.batteryLevelPct.map { "Battery \($0) percent" } ?? "Battery level unknown")
    }

    // MARK: - Status pills

    private var statusPills: some View {
        // Full-width status chip — the status carries full sentences ("Step on the
        // scale to weigh again"), so it wraps to two lines rather than truncating.
        // Battery now lives in the header, so this takes the whole row.
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: scale.isConnected ? "dot.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                .foregroundStyle(scale.isConnected ? Brand.teal : .orange)
            Text(scale.status)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.footnote)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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

    private var batteryPercent: String {
        guard let pct = scale.batteryLevelPct else { return "—" }
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
                        .font(.system(size: weightFontSize, weight: .bold, design: .rounded))
                        .contentTransition(.numericText())
                    Text(weightUnit)
                        .font(.system(size: unitFontSize, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(weightValue) \(weightUnit)")
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
                
                Button {
                    showReportScale = true
                } label: {
                    Text("Having trouble connecting?")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.white.opacity(0.8))
                        .underline()
                }
                .padding(.top, 16)
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
                    Link(destination: Constants.supportMailURL) {
                        Label("Support", systemImage: "envelope")
                    }
                    Button {
                        showReportScale = true
                    } label: {
                        Label("Report your scale", systemImage: "exclamationmark.bubble")
                    }
                    Link(destination: Constants.privacyURL) {
                        Label("Privacy Policy", systemImage: "hand.raised")
                    }
                    Link(destination: Constants.githubURL) {
                        Label("Source on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    Link(destination: Constants.licenseURL) {
                        Label("Source code (MIT)", systemImage: "doc.text")
                    }
                    Link(destination: Constants.otherAppsURL) {
                        Label("My Other Apps", systemImage: "square.grid.2x2")
                    }
                } header: {
                    Text("Support & Legal")
                } footer: {
                    VStack(spacing: 10) {
                        Text("LibreBase is tested only with the original QardioBase (1st gen). Have a QardioBase 2 or X? Tap “Report your scale” — we'd love to help support it.")
                        Text(Constants.versionLabel + " · open source, MIT licensed.")
                    }
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showSettings = false }
                }
            }
            .sheet(isPresented: $showReportScale) {
                ReportScaleView().environmentObject(scale)
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
