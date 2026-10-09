//
//  LibreBaseApp.swift
//  LibreBase
//
//  Created by Michel Storms on 02/06/2026.
//

import SwiftUI

@main
struct LibreBaseApp: App {
    @StateObject private var scale = ScaleClient.shared
    @StateObject private var health = Health.shared
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    init() {
        // Seed deterministic state before any view renders when capturing
        // App Store screenshots; a no-op otherwise.
        ScreenshotMode.configure()
        guard !ScreenshotMode.isActive else { return }

        // Set up weigh-in capture here, not in a view: iOS can relaunch the app
        // in the background when the scale wakes, and no view is created then.
        // Creating the Bluetooth central raises the permission prompt, so wait
        // for onboarding to have asked for it first.
        WeighInRecorder.shared.install()
        if UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") {
            ScaleClient.shared.start()
        }
    }

    var body: some Scene {
        WindowGroup {
            if hasCompletedOnboarding {
                ContentView()
                    .environmentObject(scale)
                    .environmentObject(health)
            } else {
                OnboardingView(initialStep: ScreenshotMode.onboardingInitialStep)
                    .environmentObject(scale)
                    .environmentObject(health)
            }
        }
    }
}
