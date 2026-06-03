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

    var body: some Scene {
        WindowGroup {
            if hasCompletedOnboarding {
                ContentView()
                    .environmentObject(scale)
                    .environmentObject(health)
            } else {
                OnboardingView()
                    .environmentObject(scale)
                    .environmentObject(health)
            }
        }
    }
}
