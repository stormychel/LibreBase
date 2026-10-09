//
//  QardioResult.swift
//  LibreBase
//
//  Created by Michel Storms on 09/10/2026.
//

import Foundation

/// Body composition as reported by the scale's own bioimpedance model. Every
/// field is optional: a weigh-in in socks or shoes yields weight only.
struct BodyComposition: Equatable {
    var fatPct: Double?
    var waterPct: Double?
    var musclePct: Double?
    var bonePct: Double?

    var isEmpty: Bool {
        fatPct == nil && waterPct == nil && musclePct == nil && bonePct == nil
    }
}

/// The on-scale user profile a weigh-in was attributed to. Multi-user scales
/// (QardioBase 2) tag every result with one.
struct ScaleUser: Equatable {
    let id: String
    let name: String
}

/// Decoder for the QardioBase final-result JSON (`B24F98BE-…`), e.g.
/// `{"weight":"71.4","bmi":"24.7","z":"574","fat":"22","tbw":"50","bmc":"4",
///   "mt":"14","sm":"37","algorithm":"0","user":"daddy","userid":"…"}`.
enum QardioResult {
    /// Foot-to-foot impedance outside this window means the scale had no usable
    /// skin contact, and its body-composition numbers are noise (a B100 capture
    /// with `z` = 2031 reported 57 % fat at a BMI of 19).
    static let plausibleImpedanceOhm = 200.0...1200.0

    static func parse(_ data: Data, timestamp: Date = Date()) -> ScaleReading? {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let weightKg = number(json["weight"]),
            ScaleReading.isPlausibleWeight(weightKg)
        else { return nil }

        var reading = ScaleReading(weightKg: weightKg, timestamp: timestamp)

        // The JSON also includes a "bmi" field, but it relies on a height set via
        // the Qardio app; we ignore it and compute BMI in-app from a stored height.
        let impedanceOK = number(json["z"]).map(plausibleImpedanceOhm.contains) ?? true
        if impedanceOK {
            let composition = BodyComposition(
                fatPct: percent(json["fat"], in: 3...60),
                waterPct: percent(json["tbw"], in: 20...80),
                musclePct: percent(json["sm"], in: 10...70),
                bonePct: percent(json["bmc"], in: 1...10)
            )
            if !composition.isEmpty { reading.composition = composition }
        }

        if let id = text(json["userid"]) {
            reading.scaleUser = ScaleUser(id: id, name: text(json["user"]) ?? "Unnamed")
        }
        return reading
    }

    /// The scale sends numbers as strings; accept real JSON numbers too in case
    /// another firmware doesn't.
    private static func number(_ value: Any?) -> Double? {
        if let s = value as? String { return Double(s.trimmingCharacters(in: .whitespaces)) }
        return (value as? NSNumber)?.doubleValue
    }

    private static func percent(_ value: Any?, in range: ClosedRange<Double>) -> Double? {
        number(value).flatMap { range.contains($0) ? $0 : nil }
    }

    private static func text(_ value: Any?) -> String? {
        let s: String?
        if let string = value as? String { s = string } else { s = (value as? NSNumber)?.stringValue }
        guard let trimmed = s?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

/// Which on-scale user this phone saves weigh-ins for. A household scale reports
/// every member's weigh-in to whichever phone is listening, so without a binding
/// someone else's weight lands in the phone owner's Apple Health.
enum ScaleUserBinding {
    static let boundIDKey = "scaleUserID"
    static let saveAnyUserKey = "scaleSaveAnyUser"
    static let knownUsersKey = "knownScaleUsers"

    enum Decision: Equatable {
        case save
        case skip(ScaleUser)
    }

    /// Decide whether a weigh-in belongs to this phone's owner, remembering the
    /// user so it can be offered in Settings. The first user ever seen is bound
    /// automatically, which keeps single-user households working untouched.
    static func decide(for user: ScaleUser?, defaults: UserDefaults = .standard) -> Decision {
        // No attribution in the result (single-user firmware): nothing to filter on.
        guard let user else { return .save }

        var known = knownUsers(defaults: defaults)
        known[user.id] = user.name
        defaults.set(known, forKey: knownUsersKey)

        if defaults.bool(forKey: saveAnyUserKey) { return .save }
        let bound = defaults.string(forKey: boundIDKey) ?? ""
        if bound.isEmpty {
            defaults.set(user.id, forKey: boundIDKey)
            return .save
        }
        return bound == user.id ? .save : .skip(user)
    }

    /// Scale user id → display name, for every user seen so far.
    static func knownUsers(defaults: UserDefaults = .standard) -> [String: String] {
        defaults.dictionary(forKey: knownUsersKey) as? [String: String] ?? [:]
    }
}
