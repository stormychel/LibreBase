//
//  LibreBaseWatchApp.swift
//  LibreBase Watch App
//
//  Created by Michel Storms on 04/06/2026.
//

import SwiftUI

/// watchOS companion entry point. v1 is a read-only mirror: it shows the latest
/// weight + BMI from Apple Health (written by the iPhone app and synced to the
/// watch). It does no Bluetooth — see Docs/watchOS.md and issue #29 for the
/// standalone-BLE research track.
@main
struct LibreBaseWatchApp: App {
    @StateObject private var health = WatchHealth()

    var body: some Scene {
        WindowGroup {
            WatchContentView()
                .environmentObject(health)
        }
    }
}
