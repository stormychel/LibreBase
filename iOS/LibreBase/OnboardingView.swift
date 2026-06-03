//
//  OnboardingView.swift
//  LibreBase
//
//  Created by Michel Storms on 02/06/2026.
//

import CoreBluetooth
import HealthKit
import SwiftUI

/// First-run walkthrough: a short, branded introduction that asks for the two
/// permissions LibreBase needs — Bluetooth and Apple Health — in context, before
/// the everyday screen. Styled with the icon's teal gradient (see `Brand`).
/// Completion is recorded in `hasCompletedOnboarding`, gated by `LibreBaseApp`.
struct OnboardingView: View {
    @EnvironmentObject var scale: ScaleClient
    @EnvironmentObject var health: Health
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var step: Int

    init(initialStep: Int = 0) {
        _step = State(initialValue: initialStep)
    }

    // Permission state — mirrored from the system so each row can show its status.
    @State private var bluetoothGranted = false
    @State private var bluetoothDenied = false
    @State private var bluetoothPrompted = false
    @State private var healthGranted = false
    @State private var healthDenied = false
    @State private var healthPrompted = false

    private let totalSteps = 3

    /// Both prompts must have been answered before the user can continue — denial
    /// is fine (they can fix it later in Settings), but we don't let them skip the
    /// ask entirely, since the app does nothing without them.
    private var allPermissionsPrompted: Bool { bluetoothPrompted && healthPrompted }

    var body: some View {
        ZStack {
            Brand.softBackground
                .ignoresSafeArea()

            VStack(spacing: 0) {
                progressDots
                    .padding(.top, 20)

                // Scrollable so content never clips on small screens or with
                // large Dynamic Type, while staying vertically centered when it fits.
                GeometryReader { geo in
                    ScrollView {
                        Group {
                            switch step {
                            case 0: welcomeStep
                            case 1: howItWorksStep
                            default: permissionsStep
                            }
                        }
                        .frame(minHeight: geo.size.height)
                        .frame(maxWidth: .infinity)
                        .animation(.easeInOut(duration: 0.3), value: step)
                    }
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshPermissions() }
        }
    }

    private var progressDots: some View {
        HStack(spacing: 8) {
            ForEach(0..<totalSteps, id: \.self) { i in
                Capsule()
                    .fill(i == step ? AnyShapeStyle(Brand.teal) : AnyShapeStyle(Color.secondary.opacity(0.3)))
                    .frame(width: i == step ? 22 : 8, height: 8)
                    .animation(.easeInOut(duration: 0.25), value: step)
            }
        }
    }

    // MARK: - Step 0: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 24) {
            Spacer()

            Image("BrandIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 112, height: 112)
                .clipShape(RoundedRectangle(cornerRadius: 25, style: .continuous))
                .shadow(color: Brand.deep.opacity(0.35), radius: 18, y: 8)

            VStack(spacing: 12) {
                Text("LibreBase")
                    .font(.largeTitle.bold())
                Text("Your QardioBase scale, back in your hands — and synced straight to Apple Health.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Spacer()

            primaryButton("Get Started") { withAnimation { step = 1 } }
        }
    }

    // MARK: - Step 1: How it works

    private var howItWorksStep: some View {
        VStack(spacing: 28) {
            Spacer()

            VStack(spacing: 8) {
                Text("How it works")
                    .font(.title.bold())
                Text("No account. No cloud. No Qardio app.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 22) {
                infoRow(
                    icon: "antenna.radiowaves.left.and.right",
                    title: "Direct Bluetooth",
                    detail: "LibreBase talks to your QardioBase directly over Bluetooth — nothing in between."
                )
                infoRow(
                    icon: "figure.stand",
                    title: "Step on, that's it",
                    detail: "Your weight appears the moment you step on the scale. Step off and you're done."
                )
                infoRow(
                    icon: "heart.fill",
                    title: "Saved to Apple Health",
                    detail: "Every weigh-in is written to Health, with in-app BMI from your height. Your data stays yours."
                )
            }
            .padding(.horizontal, 28)

            Spacer()

            primaryButton("Continue") { withAnimation { step = 2 } }
        }
    }

    // MARK: - Step 2: Permissions

    private var permissionsStep: some View {
        VStack(spacing: 26) {
            Spacer()

            Image(systemName: "lock.shield.fill")
                .font(.system(size: 56))
                .foregroundStyle(Brand.teal)

            VStack(spacing: 8) {
                Text("A couple of permissions")
                    .font(.title.bold())
                    .multilineTextAlignment(.center)
                Text("LibreBase asks for just what it needs to read your scale — nothing leaves your phone.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }

            VStack(spacing: 12) {
                permissionRow(
                    icon: "dot.radiowaves.left.and.right",
                    title: "Bluetooth",
                    description: "To find your QardioBase and read each weigh-in.",
                    granted: bluetoothGranted,
                    denied: bluetoothDenied,
                    requestTitle: "Allow",
                    request: requestBluetooth
                )
                permissionRow(
                    icon: "heart.text.square.fill",
                    title: "Apple Health",
                    description: "To save your weight, and read your height for BMI.",
                    granted: healthGranted,
                    denied: healthDenied,
                    requestTitle: "Allow",
                    request: requestHealth
                )
            }
            .padding(.horizontal, 24)

            Spacer()

            primaryButton("Connect my scale", enabled: allPermissionsPrompted) {
                withAnimation { hasCompletedOnboarding = true }
            }
        }
        .onAppear(perform: refreshPermissions)
    }

    // MARK: - Permission requests

    private func requestBluetooth() {
        bluetoothPrompted = true
        // Building the central is what raises the system Bluetooth prompt.
        scale.start()
        // The authorization resolves without a scene-phase change, so poll briefly
        // to reflect the user's choice on the row.
        for delay in [1.0, 2.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { refreshPermissions() }
        }
    }

    private func requestHealth() {
        healthPrompted = true
        Task {
            try? await health.requestAuth()
            await MainActor.run { refreshPermissions() }
        }
    }

    private func refreshPermissions() {
        // App Store capture must look identical on every simulator regardless of
        // its real authorization history, so show a fixed "both granted" state
        // rather than querying live permissions.
        if ScreenshotMode.isActive {
            bluetoothGranted = true; bluetoothDenied = false; bluetoothPrompted = true
            healthGranted = true; healthDenied = false; healthPrompted = true
            return
        }

        let bt = CBCentralManager.authorization
        bluetoothGranted = bt == .allowedAlways
        bluetoothDenied = bt == .denied || bt == .restricted
        if bluetoothGranted || bluetoothDenied { bluetoothPrompted = true }

        let h = health.bodyMassWriteStatus
        healthGranted = h == .sharingAuthorized
        healthDenied = h == .sharingDenied
        if healthGranted || healthDenied { healthPrompted = true }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    // MARK: - Components

    private func infoRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(Brand.teal)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func permissionRow(
        icon: String,
        title: String,
        description: String,
        granted: Bool,
        denied: Bool,
        requestTitle: String,
        request: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(Brand.teal)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.green)
            } else if denied {
                Button("Settings") { openSettings() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else {
                Button(requestTitle) { request() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(Brand.teal)
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func primaryButton(_ title: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Brand.gradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: Brand.deep.opacity(0.3), radius: 10, y: 5)
                .opacity(enabled ? 1 : 0.4)
        }
        .disabled(!enabled)
        .padding(.horizontal, 24)
        .padding(.bottom, 32)
    }
}
