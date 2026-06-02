//
//  OnboardingView.swift
//  LibreBase
//
//  Created by Michel Storms on 02/06/2026.
//

import SwiftUI

/// First-run walkthrough: a short, branded introduction that sets expectations
/// before the system permission prompts appear on the main screen. Three steps —
/// welcome, how it works, and a privacy/permissions primer — styled with the
/// icon's teal gradient (see `Brand`). Completion is recorded in
/// `hasCompletedOnboarding`, gated by `LibreBaseApp`.
struct OnboardingView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var step = 0

    private let totalSteps = 3

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
                            default: privacyStep
                            }
                        }
                        .frame(minHeight: geo.size.height)
                        .frame(maxWidth: .infinity)
                        .animation(.easeInOut(duration: 0.3), value: step)
                    }
                }
            }
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

    // MARK: - Step 2: Privacy & permissions primer

    private var privacyStep: some View {
        VStack(spacing: 28) {
            Spacer()

            Image(systemName: "lock.shield.fill")
                .font(.system(size: 60))
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

            VStack(alignment: .leading, spacing: 22) {
                infoRow(
                    icon: "dot.radiowaves.left.and.right",
                    title: "Bluetooth",
                    detail: "To find your QardioBase and read each weigh-in."
                )
                infoRow(
                    icon: "heart.text.square.fill",
                    title: "Apple Health",
                    detail: "To save your weight, and read your height so BMI is accurate."
                )
            }
            .padding(.horizontal, 28)

            Spacer()

            primaryButton("Connect my scale") {
                withAnimation { hasCompletedOnboarding = true }
            }
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

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Brand.gradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: Brand.deep.opacity(0.3), radius: 10, y: 5)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 32)
    }
}

#Preview {
    OnboardingView()
}
