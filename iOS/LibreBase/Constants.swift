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

    private static var versionBuild: (version: String, build: String) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return (version, build)
    }

    private static func mailto(subject: String, body: String = "") -> URL {
        let s = subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        var url = "mailto:\(supportEmail)?subject=\(s)"
        if !body.isEmpty {
            url += "&body=\(body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
        }
        return URL(string: url)!
    }

    static var supportMailURL: URL {
        let (v, b) = versionBuild
        return mailto(subject: "LibreBase v\(v)-\(b) support request")
    }

    /// We've only verified the original QardioBase — invite owners of other Base
    /// models to write in with their results so we can try to support them.
    static var scaleReportMailURL: URL {
        let (v, b) = versionBuild
        return mailto(
            subject: "LibreBase — my Qardio scale",
            body: """
            Which Qardio model do you have (e.g. QardioBase 2 or QardioBase X)? \
            Did LibreBase connect and read your weight? Anything you can share \
            helps us support more scales — thank you!

            (LibreBase \(v)-\(b))
            """
        )
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
