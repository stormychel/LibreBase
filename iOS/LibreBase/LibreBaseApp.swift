//
//  LibreBaseApp.swift
//  LibreBase
//
//  Created by Michel Storms on 02/06/2026.
//

import SwiftUI

@main
struct LibreBaseApp: App {
    @StateObject private var scale = ScaleClient()
    @StateObject private var health = Health()
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    init() {
        // Seed deterministic state before any view renders when capturing
        // App Store screenshots; a no-op otherwise.
        ScreenshotMode.configure()
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
