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

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(scale)
                .environmentObject(health)
        }
    }
}
