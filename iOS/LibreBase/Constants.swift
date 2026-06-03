//
//  Constants.swift
//  LibreBase
//
//  Created by Michel Storms on 03/06/2026.
//

import Foundation

/// App-wide constants: support contact and the legal/source links shown in
/// Settings. Mirrors the convention used across the other apps — a support
/// mailto that auto-tags the version, plus hosted legal URLs.
enum Constants {
    // Support — dedicated catch-all address for LibreBase.
    static let supportEmail = "librebaseapp@michelstorms.dev"

    static var supportMailURL: URL {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let subject = "LibreBase v\(version)-\(build) support request"
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return URL(string: "mailto:\(supportEmail)?subject=\(subject)")!
    }

    // Source — LibreBase is open source (MIT).
    static let githubURL = URL(string: "https://github.com/stormychel/LibreBase")!
    static let licenseURL = URL(string: "https://github.com/stormychel/LibreBase/blob/main/LICENSE")!

    // More from the same developer.
    static let otherAppsURL = URL(string: "https://michelstorms.com/apps.html")!

    // Legal — hosted alongside the other apps' policies.
    static let privacyURL = URL(string: "https://michelstorms.com/librebase/privacy/")!

    /// "1.0.0 (5)" — for display in the Settings footer.
    static var versionLabel: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "LibreBase \(version) (\(build))"
    }
}
