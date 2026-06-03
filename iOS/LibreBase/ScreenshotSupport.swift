//
//  ScreenshotSupport.swift
//  LibreBase
//
//  Created by Michel Storms on 03/06/2026.
//

import Foundation

/// The App Store scenes captured by `Scripts/generate-screenshots.sh`. Each is
/// reached deterministically from a launch argument — no taps required — so the
/// pipeline is stable across devices and runs.
enum ScreenshotScene: String {
    case welcome
    case howItWorks = "how_it_works"
    case privacy
    case reading
    case readingImperial = "reading_imperial"
}

/// Deterministic state injection for App Store screenshots. The app is launched
/// with `-SCREENSHOT_MODE -SCREENSHOT_SCENE <scene>`; `configure()` runs before
/// any view renders (from `LibreBaseApp.init`) and seeds UserDefaults so the
/// requested scene appears without onboarding, permission prompts, or a live
/// scale. The in-memory demo weigh-in is injected separately (see
/// `ScaleClient.loadDemoReading`) because it isn't UserDefaults-backed.
enum ScreenshotMode {
    static var isActive: Bool {
        CommandLine.arguments.contains("-SCREENSHOT_MODE")
    }

    static var scene: ScreenshotScene? {
        guard let index = CommandLine.arguments.firstIndex(of: "-SCREENSHOT_SCENE"),
              index + 1 < CommandLine.arguments.count else { return nil }
        return ScreenshotScene(rawValue: CommandLine.arguments[index + 1])
    }

    /// Which onboarding step a scene opens on (ignored for non-onboarding scenes).
    static var onboardingInitialStep: Int {
        switch scene {
        case .howItWorks: return 1
        case .privacy:    return 2
        default:          return 0
        }
    }

    /// True when the scene should show the completed app with a demo weigh-in.
    static var showsReading: Bool { scene == .reading || scene == .readingImperial }

    /// Forces the unit system for unit-aware scenes so kg/lb is deterministic
    /// regardless of the simulator's region (launch-arg locale doesn't reliably
    /// move `Locale.measurementSystem`). nil = follow the device locale. Only the
    /// display unit changes; BMI is computed from the canonical metric values and
    /// is identical either way.
    static var forcedUseMetric: Bool? {
        guard isActive else { return nil }
        switch scene {
        case .reading:         return true
        case .readingImperial: return false
        default:               return nil
        }
    }

    static func configure() {
        guard isActive, let scene = scene else { return }
        let d = UserDefaults.standard
        switch scene {
        case .welcome, .howItWorks, .privacy:
            // Onboarding scenes — start fresh.
            d.set(false, forKey: "hasCompletedOnboarding")
        case .reading, .readingImperial:
            // Completed app with a saved height so BMI shows.
            d.set(true, forKey: "hasCompletedOnboarding")
            d.set(true, forKey: "autoSaveToHealth")
            d.set(178.0, forKey: "heightCm")
        }
    }
}
