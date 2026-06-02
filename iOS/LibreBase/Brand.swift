//
//  Brand.swift
//  LibreBase
//
//  Created by Michel Storms on 02/06/2026.
//

import SwiftUI

/// The LibreBase visual identity, lifted straight from the app icon: a teal
/// gradient running from a bright mint to a deep teal-blue, the same diagonal
/// the icon's gauge sits on. Centralizing it here keeps onboarding and the main
/// screen on one consistent design language.
enum Brand {
    /// Bright mint — the icon's top-leading corner (#3CD6C2).
    static let mint = Color(red: 60 / 255, green: 214 / 255, blue: 194 / 255)
    /// Core teal — the icon's dominant tone and the app's accent (#16BBA8).
    static let teal = Color(red: 22 / 255, green: 187 / 255, blue: 168 / 255)
    /// Deep teal-blue — the icon's bottom-trailing corner (#0F7A92).
    static let deep = Color(red: 15 / 255, green: 122 / 255, blue: 146 / 255)

    /// The signature diagonal gradient, matching the icon's light direction.
    static let gradient = LinearGradient(
        colors: [mint, teal, deep],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// A soft, low-contrast version of the gradient for full-screen backdrops
    /// behind dark text (onboarding), so content stays legible.
    static let softBackground = LinearGradient(
        colors: [mint.opacity(0.18), teal.opacity(0.10), deep.opacity(0.16)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}
