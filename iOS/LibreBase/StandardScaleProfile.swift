//
//  StandardScaleProfile.swift
//  LibreBase
//
//  Created by Michel Storms on 09/10/2026.
//

import Foundation

/// Encoders/decoders for the Bluetooth SIG scale stack the QardioBase X speaks:
/// Weight Scale (0x181D), Body Composition (0x181B), User Data (0x181C) and
/// Current Time (0x1805). Pure functions, so they can be tested without a scale.
enum StandardScaleProfile {
    struct Weight: Equatable {
        let kg: Double
        /// The scale's own clock, when the frame carries it.
        let timestamp: Date?
        /// User Data index the scale attributed the weigh-in to (0xFF = unknown).
        let userIndex: UInt8?
    }

    /// GATT dates are Gregorian whatever calendar the phone is set to.
    static var gregorian: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    // MARK: - Weight Measurement (0x2A9D)

    /// flags(1) weight(2) [timestamp(7)] [user(1)] [bmi(2) height(2)]
    static func parseWeight(_ data: Data, calendar: Calendar = gregorian) -> Weight? {
        let b = [UInt8](data)
        guard b.count >= 3 else { return nil }
        let flags = b[0]
        let kg = mass(raw: u16(b, 1), imperial: flags & 0x01 != 0)
        var offset = 3
        var timestamp: Date?
        if flags & 0x02 != 0 {
            guard b.count >= offset + 7 else { return nil }
            timestamp = date(Array(b[offset..<offset + 7]), calendar: calendar)
            offset += 7
        }
        var userIndex: UInt8?
        if flags & 0x04 != 0 {
            guard b.count >= offset + 1 else { return nil }
            userIndex = b[offset]
        }
        return Weight(kg: kg, timestamp: timestamp, userIndex: userIndex)
    }

    // MARK: - Body Composition Measurement (0x2A9C)

    /// flags(2) fat%(2) [timestamp(7)] [user(1)] [bmr(2)] [muscle%(2)]
    /// [muscle mass(2)] [fat-free mass(2)] [soft lean mass(2)] [water mass(2)]
    /// [impedance(2)] [weight(2)] [height(2)]. Water arrives as a mass, so it
    /// needs a weight to become a percentage — the frame's own if present, else
    /// `weightKg` from the Weight Measurement.
    static func parseBodyComposition(_ data: Data, weightKg: Double? = nil) -> BodyComposition? {
        let b = [UInt8](data)
        guard b.count >= 4 else { return nil }
        let flags = u16(b, 0)
        let imperial = flags & 0x0001 != 0
        var offset = 4
        var fields: [Int: UInt16] = [:]
        // Optional fields in wire order: (flag bit, byte length).
        for (bit, length) in [(1, 7), (2, 1), (3, 2), (4, 2), (5, 2), (6, 2), (7, 2), (8, 2), (9, 2), (10, 2), (11, 2)]
        where flags & (1 << UInt16(bit)) != 0 {
            guard b.count >= offset + length else { return nil }
            if length == 2 { fields[bit] = u16(b, offset) }
            offset += length
        }

        var composition = BodyComposition()
        // 0xFFFF = "measurement unsuccessful". Percentages are in 0.1 % units.
        let fatRaw = u16(b, 2)
        if fatRaw != 0xFFFF { composition.fatPct = within(Double(fatRaw) * 0.1, 3...60) }
        if let muscle = fields[4] { composition.musclePct = within(Double(muscle) * 0.1, 10...70) }
        let weight = fields[10].map { mass(raw: $0, imperial: imperial) } ?? weightKg
        if let water = fields[8], let weight, weight > 0 {
            composition.waterPct = within(mass(raw: water, imperial: imperial) / weight * 100, 20...80)
        }
        return composition.isEmpty ? nil : composition
    }

    /// A measurement may be split over several indications (multiple-packet
    /// flag); later frames fill in what earlier ones lacked.
    static func parseBodyComposition(frames: [Data], weightKg: Double?) -> BodyComposition? {
        var merged = BodyComposition()
        for frame in frames {
            guard let part = parseBodyComposition(frame, weightKg: weightKg) else { continue }
            merged.fatPct = part.fatPct ?? merged.fatPct
            merged.waterPct = part.waterPct ?? merged.waterPct
            merged.musclePct = part.musclePct ?? merged.musclePct
            merged.bonePct = part.bonePct ?? merged.bonePct
        }
        return merged.isEmpty ? nil : merged
    }

    // MARK: - Current Time (0x2A2B)

    /// year(2) month day hour minute second weekday(1 = Monday) fractions256 adjust-reason
    static func currentTime(_ date: Date, calendar: Calendar = gregorian) -> Data {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: date)
        let year = UInt16(c.year ?? 2000)
        // Calendar: 1 = Sunday … 7 = Saturday. Bluetooth: 1 = Monday … 7 = Sunday.
        let weekday = UInt8(((c.weekday ?? 1) + 5) % 7 + 1)
        return Data([UInt8(year & 0xFF), UInt8(year >> 8), UInt8(c.month ?? 1), UInt8(c.day ?? 1),
                     UInt8(c.hour ?? 0), UInt8(c.minute ?? 0), UInt8(c.second ?? 0), weekday, 0, 0])
    }

    // MARK: - User Control Point (0x2A9F)

    enum ControlPoint {
        static let registerNewUser: UInt8 = 0x01
        static let consent: UInt8 = 0x02
        static let responseCode: UInt8 = 0x20
        static let success: UInt8 = 0x01

        static func register(consentCode: UInt16) -> Data {
            Data([registerNewUser, UInt8(consentCode & 0xFF), UInt8(consentCode >> 8)])
        }

        static func consent(userIndex: UInt8, consentCode: UInt16) -> Data {
            Data([consent, userIndex, UInt8(consentCode & 0xFF), UInt8(consentCode >> 8)])
        }

        struct Response: Equatable {
            let request: UInt8
            let succeeded: Bool
            /// The assigned user index, on a successful Register New User.
            let userIndex: UInt8?
        }

        /// 0x20, request op code, response value, [parameter]
        static func parseResponse(_ data: Data) -> Response? {
            let b = [UInt8](data)
            guard b.count >= 3, b[0] == responseCode else { return nil }
            let ok = b[2] == success
            return Response(request: b[1], succeeded: ok,
                            userIndex: ok && b[1] == registerNewUser && b.count >= 4 ? b[3] : nil)
        }
    }

    // MARK: - Helpers

    private static func u16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) | (UInt16(b[i + 1]) << 8) }

    /// SI: 0.005 kg/unit. Imperial: 0.01 lb/unit → kg.
    private static func mass(raw: UInt16, imperial: Bool) -> Double {
        imperial ? Double(raw) * 0.01 * 0.45359237 : Double(raw) * 0.005
    }

    private static func within(_ value: Double, _ range: ClosedRange<Double>) -> Double? {
        range.contains(value) ? value : nil
    }

    private static func date(_ b: [UInt8], calendar: Calendar) -> Date? {
        var c = DateComponents()
        c.year = Int(u16(b, 0)); c.month = Int(b[2]); c.day = Int(b[3])
        c.hour = Int(b[4]); c.minute = Int(b[5]); c.second = Int(b[6])
        return calendar.date(from: c)
    }
}
