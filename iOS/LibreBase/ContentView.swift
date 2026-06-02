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

    private var weightText: String {
        guard let r = scale.lastReading else { return "—" }
        return String(format: "%.1f kg", r.weightKg)
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
                        if let bmi = r.bmi {
                            Label(String(format: "BMI %.1f", bmi), systemImage: "figure")
                                .font(.subheadline)
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

                // Save to Health toggle
                Toggle("Save to Apple Health", isOn: $autoSaveToHealth)

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

                // Retry button when disconnected
                if !scale.isConnected {
                    Button("Retry Connect") { scale.startConnect() }
                        .buttonStyle(.bordered)
                }

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
            }
        }
    }
}
