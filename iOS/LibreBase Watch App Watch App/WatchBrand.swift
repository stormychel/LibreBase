//
//  WatchBrand.swift
//  LibreBase Watch App
//
//  Created by Michel Storms on 04/06/2026.
//

import SwiftUI

/// The LibreBase teal gradient, from the app icon. Mirrors the iOS `Brand`;
/// kept separate so the watch target is self-contained (unify via a shared
/// package — issue #29).
enum WatchBrand {
    static let mint = Color(red: 60 / 255, green: 214 / 255, blue: 194 / 255)
    static let teal = Color(red: 22 / 255, green: 187 / 255, blue: 168 / 255)
    static let deep = Color(red: 15 / 255, green: 122 / 255, blue: 146 / 255)

    static let gradient = LinearGradient(
        colors: [mint, teal, deep],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}
