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

    /// Mass per raw unit, as a scale advertises it in its Weight Scale Feature
    /// (0x2A9E) or Body Composition Feature (0x2A9B). The X uses 0.05 kg, ten
    /// times coarser than the spec's default.
    struct MassResolution: Equatable {
        let kgPerUnit: Double
        let lbPerUnit: Double

        /// "Not specified" in the feature: the measurement's own default.
        static let standard = MassResolution(kgPerUnit: 0.005, lbPerUnit: 0.01)

        /// Feature resolution values 1…7; 0 (not specified) and reserved values
        /// fall back to `standard`.
        static func fromFeatureValue(_ value: UInt32) -> MassResolution {
            let table: [(Double, Double)] = [(0.5, 1), (0.2, 0.5), (0.1, 0.2), (0.05, 0.1),
                                             (0.02, 0.05), (0.01, 0.02), (0.005, 0.01)]
            guard (1...7).contains(value) else { return .standard }
            let (kg, lb) = table[Int(value) - 1]
            return MassResolution(kgPerUnit: kg, lbPerUnit: lb)
        }
    }

    // MARK: - Feature characteristics (0x2A9E / 0x2A9B)

    /// Weight Scale Feature: uint32, weight resolution in bits 3–6.
    static func weightResolution(feature data: Data) -> MassResolution {
        guard let value = u32(data) else { return .standard }
        return .fromFeatureValue((value >> 3) & 0x0F)
    }

    /// Body Composition Feature: uint32, mass resolution in bits 11–14.
    static func bodyCompositionResolution(feature data: Data) -> MassResolution {
        guard let value = u32(data) else { return .standard }
        return .fromFeatureValue((value >> 11) & 0x0F)
    }

    /// GATT dates are Gregorian whatever calendar the phone is set to.
    static var gregorian: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    // MARK: - Weight Measurement (0x2A9D)

    /// User index for a weigh-in the scale couldn't attribute to anyone.
    static let unknownUser: UInt8 = 0xFF

    /// flags(1) weight(2) [timestamp(7)] [user(1)] [bmi(2) height(2)]
    static func parseWeight(_ data: Data, resolution: MassResolution = .standard,
                            calendar: Calendar = gregorian) -> Weight? {
        let b = [UInt8](data)
        guard b.count >= 3 else { return nil }
        let flags = b[0]
        let kg = mass(raw: u16(b, 1), imperial: flags & 0x01 != 0, resolution: resolution)
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

    /// How a scale deviates from the Body Composition spec.
    enum Dialect: Equatable {
        case standard
        /// QardioBase X (#59): a measurement with water and impedance doesn't
        /// fit one 20-byte indication, so the scale sets the multiple-packet flag
        /// and sends a second frame **without flags** that carries the remaining
        /// fields, then vendor bytes. In that continuation, water is a
        /// percentage (0.1 % units) rather than a mass — three captures put it at
        /// ~73 % of fat-free mass — and the byte 10 after the remaining fields is
        /// heart rate (matches the scale's display).
        case qardioX
    }

    /// Optional fields in wire order: (flag bit, byte length).
    private static let optionalFields: [(bit: Int, length: Int)] =
        [(1, 7), (2, 1), (3, 2), (4, 2), (5, 2), (6, 2), (7, 2), (8, 2), (9, 2), (10, 2), (11, 2)]
    private static let multiplePacketFlag: UInt16 = 0x1000

    /// flags(2) fat%(2) [timestamp(7)] [user(1)] [bmr(2)] [muscle%(2)]
    /// [muscle mass(2)] [fat-free mass(2)] [soft lean mass(2)] [water mass(2)]
    /// [impedance(2)] [weight(2)] [height(2)]. Water arrives as a mass, so it
    /// needs a weight to become a percentage — the frame's own if present, else
    /// `weightKg` from the Weight Measurement.
    static func parseBodyComposition(_ data: Data, weightKg: Double? = nil,
                                     resolution: MassResolution = .standard) -> BodyComposition? {
        guard let packet = decodePacket([UInt8](data)), packet.missing.isEmpty else { return nil }
        return composition(from: packet, weightKg: weightKg, resolution: resolution, dialect: .standard)
    }

    /// True for a QardioBase X frame that sets the multiple-packet flag and is
    /// too short for the fields it flags: the next frame continues it. (A
    /// continuation starts with water in 0.1 % units, below 0x1000, so it can't
    /// pass for a head.)
    static func awaitsContinuation(_ data: Data, dialect: Dialect) -> Bool {
        guard dialect == .qardioX, let packet = decodePacket([UInt8](data)) else { return false }
        return packet.flags & multiplePacketFlag != 0 && !packet.missing.isEmpty
    }

    /// A measurement may be split over several indications (multiple-packet
    /// flag); later frames fill in what earlier ones lacked. A frame that
    /// follows one awaiting a continuation is read as that continuation.
    static func parseBodyComposition(frames: [Data], weightKg: Double?,
                                     resolution: MassResolution = .standard,
                                     dialect: Dialect = .standard) -> BodyComposition? {
        var merged = BodyComposition()
        func merge(_ packet: Packet) {
            guard let part = composition(from: packet, weightKg: weightKg, resolution: resolution,
                                         dialect: dialect) else { return }
            merged.fatPct = part.fatPct ?? merged.fatPct
            merged.waterPct = part.waterPct ?? merged.waterPct
            merged.musclePct = part.musclePct ?? merged.musclePct
            merged.bonePct = part.bonePct ?? merged.bonePct
            merged.heartRateBpm = part.heartRateBpm ?? merged.heartRateBpm
        }
        // An X head awaiting its continuation is merged once the continuation
        // is in (its impedance may void the whole measurement), or on its own if
        // none arrives. Spec scales send each packet with its own flags.
        var pending: (packet: Packet, bytes: [UInt8])?
        var seenHeads: Set<[UInt8]> = []
        var skipContinuation = false
        for frame in frames {
            let bytes = [UInt8](frame)
            // A head already handled (merged or voided) is a retransmission, and
            // so is the continuation after it.
            if dialect == .qardioX, pending?.bytes != bytes, seenHeads.contains(bytes) {
                skipContinuation = true
                continue
            }
            if skipContinuation {
                skipContinuation = false
                if !awaitsContinuation(frame, dialect: dialect) { continue }
            }
            if let head = pending {
                if bytes == head.bytes { continue }  // retransmitted head
                if !awaitsContinuation(frame, dialect: dialect) {
                    pending = nil
                    merge(`continue`(head.packet, with: bytes, dialect: dialect))
                    continue
                }
                // A new head: the previous one lost its continuation.
                pending = nil
                merge(head.packet)
            }
            guard let packet = decodePacket(bytes) else { continue }
            if packet.missing.isEmpty {
                merge(packet)
            } else if packet.flags & multiplePacketFlag != 0 {
                if dialect == .qardioX {
                    pending = (packet, bytes)
                    seenHeads.insert(bytes)
                } else {
                    merge(packet)
                }
            }
            // Truncated without the multiple-packet flag: malformed, skipped.
        }
        if let head = pending { merge(head.packet) }
        return merged.isEmpty ? nil : merged
    }

    private struct Packet {
        let flags: UInt16
        let fatRaw: UInt16
        var fields: [Int: UInt16]
        /// Flagged fields the frame was too short for, in wire order.
        var missing: [(bit: Int, length: Int)]
        var fromContinuation: Set<Int> = []
        var heartRate: UInt8?
    }

    private static func decodePacket(_ b: [UInt8]) -> Packet? {
        guard b.count >= 4 else { return nil }
        let flags = u16(b, 0)
        var packet = Packet(flags: flags, fatRaw: u16(b, 2), fields: [:], missing: [])
        var offset = 4
        for field in optionalFields where flags & (1 << UInt16(field.bit)) != 0 {
            guard packet.missing.isEmpty, b.count >= offset + field.length else {
                packet.missing.append(field)
                continue
            }
            if field.length == 2 { packet.fields[field.bit] = u16(b, offset) }
            offset += field.length
        }
        return packet
    }

    /// Fills the head frame's missing fields from a flagless continuation.
    private static func `continue`(_ head: Packet, with b: [UInt8], dialect: Dialect) -> Packet {
        var packet = head
        var offset = 0
        for field in head.missing {
            guard b.count >= offset + field.length else { break }
            if field.length == 2 {
                packet.fields[field.bit] = u16(b, offset)
                packet.fromContinuation.insert(field.bit)
            }
            offset += field.length
        }
        packet.missing = []
        if dialect == .qardioX, b.count > offset + 10 { packet.heartRate = b[offset + 10] }
        return packet
    }

    private static func composition(from packet: Packet, weightKg: Double?, resolution: MassResolution,
                                    dialect: Dialect) -> BodyComposition? {
        let imperial = packet.flags & 0x0001 != 0
        let fields = packet.fields
        var composition = BodyComposition()
        // Foot-to-foot impedance outside the plausible window means no usable
        // skin contact: the composition is noise (as for the vendor JSON). The
        // X sends whole ohms; the spec's 0.1 Ω unit would need its own window.
        if dialect == .qardioX, let impedance = fields[9],
           !QardioResult.plausibleImpedanceOhm.contains(Double(impedance)) {
            return nil
        }
        // 0xFFFF = "measurement unsuccessful". Percentages are in 0.1 % units.
        if packet.fatRaw != 0xFFFF { composition.fatPct = within(Double(packet.fatRaw) * 0.1, 3...60) }
        if let muscle = fields[4] { composition.musclePct = within(Double(muscle) * 0.1, 10...70) }
        if let water = fields[8] {
            if dialect == .qardioX, packet.fromContinuation.contains(8) {
                composition.waterPct = within(Double(water) * 0.1, 20...80)
            } else {
                let weight = fields[10].map { mass(raw: $0, imperial: imperial, resolution: resolution) } ?? weightKg
                if let weight, weight > 0 {
                    let waterKg = mass(raw: water, imperial: imperial, resolution: resolution)
                    composition.waterPct = within(waterKg / weight * 100, 20...80)
                }
            }
        }
        if let bpm = packet.heartRate, (30...220).contains(bpm) { composition.heartRateBpm = Double(bpm) }
        return composition.isEmpty ? nil : composition
    }

    /// User Data index a Body Composition frame is attributed to, if it says.
    static func bodyCompositionUserIndex(_ data: Data) -> UInt8? {
        let b = [UInt8](data)
        guard b.count >= 4 else { return nil }
        let flags = u16(b, 0)
        guard flags & 0x0004 != 0 else { return nil }
        let offset = 4 + (flags & 0x0002 != 0 ? 7 : 0)
        return b.count > offset ? b[offset] : nil
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
        static let operationFailed: UInt8 = 0x04
        static let userNotAuthorized: UInt8 = 0x05

        static func register(consentCode: UInt16) -> Data {
            Data([registerNewUser, UInt8(consentCode & 0xFF), UInt8(consentCode >> 8)])
        }

        static func consent(userIndex: UInt8, consentCode: UInt16) -> Data {
            Data([consent, userIndex, UInt8(consentCode & 0xFF), UInt8(consentCode >> 8)])
        }

        struct Response: Equatable {
            let request: UInt8
            let succeeded: Bool
            /// The raw response value (0x01 success … 0x05 user not authorized).
            let value: UInt8
            /// The assigned user index, on a successful Register New User.
            let userIndex: UInt8?

            var requestName: String {
                switch request {
                case ControlPoint.registerNewUser: "register new user"
                case ControlPoint.consent: "consent"
                default: String(format: "op 0x%02x", request)
                }
            }

            var valueName: String {
                switch value {
                case 0x01: "success"
                case 0x02: "op code not supported"
                case 0x03: "invalid parameter"
                case 0x04: "operation failed"
                case 0x05: "user not authorized"
                default: String(format: "0x%02x", value)
                }
            }
        }

        /// 0x20, request op code, response value, [parameter]
        static func parseResponse(_ data: Data) -> Response? {
            let b = [UInt8](data)
            guard b.count >= 3, b[0] == responseCode else { return nil }
            let ok = b[2] == success
            return Response(request: b[1], succeeded: ok, value: b[2],
                            userIndex: ok && b[1] == registerNewUser && b.count >= 4 ? b[3] : nil)
        }
    }

    // MARK: - User Data characteristics (0x181C)

    /// What the scale's body composition model needs to know about its user.
    /// Without it the X assumes 1.70 m and reads fat % far off (#60).
    struct UserProfile: Equatable {
        var heightCm: Double?
        var dateOfBirth: DateComponents?
        var sex: Sex?

        enum Sex: UInt8 { case male = 0, female = 1, unspecified = 2 }
    }

    enum UserData {
        static let writableUUIDs: Set<String> = ["2A8E", "2A85", "2A80", "2A8C"]

        /// Height (0x2A8E): uint16, 0.01 m units.
        static func height(cm: Double) -> Data? {
            guard (50...250).contains(cm) else { return nil }
            let raw = UInt16(cm.rounded())
            return Data([UInt8(raw & 0xFF), UInt8(raw >> 8)])
        }

        /// Date of Birth (0x2A85): year(2) month day.
        static func dateOfBirth(_ c: DateComponents) -> Data? {
            guard let year = c.year, let month = c.month, let day = c.day,
                  (1900...2100).contains(year), (1...12).contains(month), (1...31).contains(day) else { return nil }
            let y = UInt16(year)
            return Data([UInt8(y & 0xFF), UInt8(y >> 8), UInt8(month), UInt8(day)])
        }

        /// Age (0x2A80): uint8 years.
        static func age(dateOfBirth c: DateComponents, now: Date = Date(), calendar: Calendar = gregorian) -> Data? {
            guard let birth = calendar.date(from: c),
                  let years = calendar.dateComponents([.year], from: birth, to: now).year,
                  (5...120).contains(years) else { return nil }
            return Data([UInt8(years)])
        }

        /// Gender (0x2A8C): 0 male, 1 female, 2 unspecified.
        static func gender(_ sex: UserProfile.Sex) -> Data { Data([sex.rawValue]) }

        /// The writes for a profile, as (characteristic UUID string, value):
        /// only the fields the profile has.
        static func writes(for profile: UserProfile, now: Date = Date()) -> [(uuid: String, value: Data)] {
            var out: [(String, Data)] = []
            if let cm = profile.heightCm, let v = height(cm: cm) { out.append(("2A8E", v)) }
            if let dob = profile.dateOfBirth {
                if let v = dateOfBirth(dob) { out.append(("2A85", v)) }
                if let v = age(dateOfBirth: dob, now: now) { out.append(("2A80", v)) }
            }
            if let sex = profile.sex { out.append(("2A8C", gender(sex))) }
            return out
        }
    }

    // MARK: - Helpers

    private static func u16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) | (UInt16(b[i + 1]) << 8) }

    private static func u32(_ data: Data) -> UInt32? {
        let b = [UInt8](data)
        guard b.count >= 4 else { return nil }
        return UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
    }

    /// Raw units → kg, at the resolution the scale advertises (imperial frames
    /// are in pounds).
    private static func mass(raw: UInt16, imperial: Bool, resolution: MassResolution) -> Double {
        imperial ? Double(raw) * resolution.lbPerUnit * 0.45359237 : Double(raw) * resolution.kgPerUnit
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
