//
//  LibreBaseTests.swift
//  LibreBaseTests
//
//  Created by Michel Storms on 02/06/2026.
//

import Foundation
import Testing
@testable import LibreBase

@MainActor
struct LibreBaseTests {

    // Result JSON from a real QardioBase 2 (B200) capture, issue #42 (userid changed).
    private let b200 = Data(#"{"id":"18335650007791743290529","weight":"71.4","bmi":"24.7","z":"574","fat":"22","tbw":"50","bmc":"4","mt":"14","sm":"37","algorithm":"0","user":"daddy","userid":"u-1"}"#.utf8)
    // Result JSON from the B100 in the README: no user, implausible impedance.
    private let b100 = Data(#"{"weight":"76.0","bmi":"19.3","z":"2031","fat":"57","tbw":"31","bmc":"3","mt":"9","sm":"17"}"#.utf8)

    private func freshDefaults() -> UserDefaults {
        let name = "LibreBaseTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func parsesB200Result() throws {
        let reading = try #require(QardioResult.parse(b200))
        #expect(reading.weightKg == 71.4)
        #expect(reading.composition == BodyComposition(fatPct: 22, waterPct: 50, musclePct: 37, bonePct: 4))
        #expect(reading.scaleUser == ScaleUser(id: "u-1", name: "daddy"))
    }

    @Test func discardsCompositionOnImplausibleImpedance() throws {
        let reading = try #require(QardioResult.parse(b100))
        #expect(reading.weightKg == 76.0)
        #expect(reading.composition == nil)
        #expect(reading.scaleUser == nil)
    }

    @Test func rejectsGarbage() {
        #expect(QardioResult.parse(Data("not json".utf8)) == nil)
        #expect(QardioResult.parse(Data(#"{"weight":"0.0"}"#.utf8)) == nil)
        #expect(QardioResult.parse(Data(#"{"fat":"22"}"#.utf8)) == nil)
    }

    @Test func acceptsNumericFieldsAndDropsOutOfRangeOnes() throws {
        let reading = try #require(QardioResult.parse(Data(#"{"weight":80.5,"fat":0,"tbw":55,"userid":""}"#.utf8)))
        #expect(reading.weightKg == 80.5)
        #expect(reading.composition == BodyComposition(waterPct: 55))
        #expect(reading.scaleUser == nil)
    }

    @Test func bindsFirstScaleUserAndSkipsOthers() {
        let defaults = freshDefaults()
        let me = ScaleUser(id: "u-1", name: "daddy")
        let other = ScaleUser(id: "u-2", name: "mum")

        #expect(ScaleUserBinding.decide(for: nil, defaults: defaults) == .save)
        #expect(ScaleUserBinding.decide(for: me, defaults: defaults) == .save)
        #expect(ScaleUserBinding.decide(for: other, defaults: defaults) == .skip(other))
        #expect(ScaleUserBinding.decide(for: me, defaults: defaults) == .save)
        #expect(ScaleUserBinding.knownUsers(defaults: defaults) == ["u-1": "daddy", "u-2": "mum"])

        defaults.set(true, forKey: ScaleUserBinding.saveAnyUserKey)
        #expect(ScaleUserBinding.decide(for: other, defaults: defaults) == .save)
    }

    // MARK: - Standard SIG profile (QardioBase X, issue #41)

    @Test func parsesStandardWeightMeasurement() throws {
        // SI, no optional fields: 14280 × 0.005 kg = 71.4 kg.
        #expect(StandardScaleProfile.parseWeight(Data([0x00, 0xC8, 0x37]))?.kg == 71.4)
        // Imperial: 15000 × 0.01 lb.
        let lb = try #require(StandardScaleProfile.parseWeight(Data([0x01, 0x98, 0x3A])))
        #expect(abs(lb.kg - 68.0389) < 0.001)
        #expect(StandardScaleProfile.parseWeight(Data([0x00, 0xC8])) == nil)
    }

    @Test func parsesWeightTimestamp() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        // flags 0x02 (timestamp), weight, 2026-10-09 07:30:15.
        let frame = Data([0x02, 0xC8, 0x37, 0xEA, 0x07, 10, 9, 7, 30, 15])
        let weight = try #require(StandardScaleProfile.parseWeight(frame, calendar: utc))
        let c = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: try #require(weight.timestamp))
        #expect([c.year, c.month, c.day, c.hour, c.minute, c.second] == [2026, 10, 9, 7, 30, 15])
        #expect(weight.userIndex == nil)

        // Timestamp and user index (flags 0x06): the index follows the 7 time bytes.
        let attributed = Data([0x06, 0xC8, 0x37, 0xEA, 0x07, 10, 9, 7, 30, 15, 0x02])
        #expect(StandardScaleProfile.parseWeight(attributed, calendar: utc)?.userIndex == 2)
        // User index only (flags 0x04).
        #expect(StandardScaleProfile.parseWeight(Data([0x04, 0xC8, 0x37, 0xFF]))?.userIndex == 0xFF)
        // Flag promises a timestamp the frame doesn't carry.
        #expect(StandardScaleProfile.parseWeight(Data([0x02, 0xC8, 0x37, 0xEA])) == nil)
    }

    @Test func parsesBodyCompositionMeasurement() {
        // flags 0x0510: muscle % (bit 4), water mass (bit 8), weight (bit 10).
        // fat 22.0 %, muscle 37.0 %, water 35.7 kg, weight 71.4 kg → water 50 %.
        let frame = Data([0x10, 0x05, 0xDC, 0x00, 0x72, 0x01, 0xE4, 0x1B, 0xC8, 0x37])
        #expect(StandardScaleProfile.parseBodyComposition(frame)
                == BodyComposition(fatPct: 22, waterPct: 50, musclePct: 37))
        // Unsuccessful measurement, nothing else: no composition.
        #expect(StandardScaleProfile.parseBodyComposition(Data([0x00, 0x00, 0xFF, 0xFF])) == nil)
        // Flag promises a field the frame doesn't carry.
        #expect(StandardScaleProfile.parseBodyComposition(Data([0x10, 0x00, 0xDC, 0x00])) == nil)

        // Split over two frames, water mass without an embedded weight: it
        // becomes a percentage once the weight is supplied.
        let fat = Data([0x00, 0x00, 0xDC, 0x00])
        let water = Data([0x00, 0x01, 0xFF, 0xFF, 0xE4, 0x1B])
        #expect(StandardScaleProfile.parseBodyComposition(frames: [fat, water], weightKg: nil)
                == BodyComposition(fatPct: 22))
        #expect(StandardScaleProfile.parseBodyComposition(frames: [fat, water], weightKg: 71.4)
                == BodyComposition(fatPct: 22, waterPct: 50))

        // User index: directly after the fat field, or after a timestamp.
        #expect(StandardScaleProfile.bodyCompositionUserIndex(fat) == nil)
        #expect(StandardScaleProfile.bodyCompositionUserIndex(Data([0x04, 0x00, 0xDC, 0x00, 0x03])) == 3)
        #expect(StandardScaleProfile.bodyCompositionUserIndex(
            Data([0x06, 0x00, 0xDC, 0x00, 0xEA, 0x07, 10, 9, 7, 30, 15, 0x03])) == 3)
    }

    @Test func encodesCurrentTime() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        // 2026-10-09 07:30:15 UTC is a Friday (Bluetooth weekday 5).
        let date = utc.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 7, minute: 30, second: 15))!
        #expect(StandardScaleProfile.currentTime(date, calendar: utc)
                == Data([0xEA, 0x07, 10, 9, 7, 30, 15, 5, 0, 0]))
    }

    @Test func userControlPointFrames() throws {
        typealias ControlPoint = StandardScaleProfile.ControlPoint
        #expect(ControlPoint.register(consentCode: 1234) == Data([0x01, 0xD2, 0x04]))
        #expect(ControlPoint.consent(userIndex: 2, consentCode: 1234) == Data([0x02, 0x02, 0xD2, 0x04]))
        #expect(ControlPoint.parseResponse(Data([0x20, 0x01, 0x01, 0x02]))
                == ControlPoint.Response(request: 0x01, succeeded: true, value: 0x01, userIndex: 2))
        #expect(ControlPoint.parseResponse(Data([0x20, 0x02, 0x05]))
                == ControlPoint.Response(request: 0x02, succeeded: false, value: 0x05, userIndex: nil))
        let refused = try #require(ControlPoint.parseResponse(Data([0x20, 0x01, 0x04])))
        #expect(refused.requestName == "register new user" && refused.valueName == "operation failed")
        #expect(ControlPoint.parseResponse(Data([0x01, 0x02])) == nil)
    }

    // MARK: - Feature resolution (QardioBase X, issue #54)

    @Test func readsMassResolutionFromFeatures() throws {
        typealias Resolution = StandardScaleProfile.MassResolution
        // The X's Weight Scale Feature 0x00000027: weight resolution 4 → 0.05 kg.
        let x = StandardScaleProfile.weightResolution(feature: Data([0x27, 0x00, 0x00, 0x00]))
        #expect(x == Resolution(kgPerUnit: 0.05, lbPerUnit: 0.1))
        // Not specified, reserved or short: the spec default.
        #expect(StandardScaleProfile.weightResolution(feature: Data([0x07, 0x00, 0x00, 0x00])) == .standard)
        #expect(StandardScaleProfile.weightResolution(feature: Data([0x47, 0x00, 0x00, 0x00])) == .standard)
        #expect(StandardScaleProfile.weightResolution(feature: Data([0x27])) == .standard)
        // The X's Body Composition Feature 0x000023FF: mass resolution 4 → 0.05 kg.
        #expect(StandardScaleProfile.bodyCompositionResolution(feature: Data([0xFF, 0x23, 0x00, 0x00])) == x)

        // The weigh-in from #54's capture: 2006 × 0.05 kg = 100.3 kg, user 2.
        let frame = Data([0x2E, 0xD6, 0x07, 0xEA, 0x07, 0x0A, 0x0F, 0x13, 0x36, 0x32, 0x02, 0x5B, 0x01, 0xAA, 0x00])
        let weight = try #require(StandardScaleProfile.parseWeight(frame, resolution: x))
        #expect(abs(weight.kg - 100.3) < 0.0001)
        #expect(weight.userIndex == 2)
        // Imperial at 0.1 lb/unit: 1500 → 150 lb.
        let lb = try #require(StandardScaleProfile.parseWeight(Data([0x01, 0xDC, 0x05]), resolution: x))
        #expect(abs(lb.kg - 150 * 0.45359237) < 0.0001)
        // Water mass at the same resolution: 714 × 0.05 = 35.7 kg of 71.4 kg.
        let water = Data([0x00, 0x01, 0xFF, 0xFF, 0xCA, 0x02])
        #expect(StandardScaleProfile.parseBodyComposition(water, weightKg: 71.4, resolution: x)
                == BodyComposition(waterPct: 50))
    }

    // MARK: - Two-frame body composition (QardioBase X, issue #59)

    private func hexData(_ s: String) -> Data { Data(s.split(separator: " ").map { UInt8($0, radix: 16)! }) }

    @Test func mergesQardioXContinuationFrame() throws {
        typealias Profile = StandardScaleProfile
        let x = Profile.MassResolution(kgPerUnit: 0.05, lbPerUnit: 0.1)
        // Real pairs from three X captures (#59): head with the multiple-packet
        // flag, truncated before water and impedance, then a flagless continuation.
        let cases: [(head: String, tail: String, weight: Double, fat: Double, water: Double, pulse: Double)] = [
            ("7e 53 5b 01 ea 07 0b 07 0a 0b 16 03 20 06 a6 01 1e 04 56 04",
             "d8 01 3c 02 10 02 38 00 0c 34 01 95 00 24 6b 77 02 06 25", 84.95, 34.7, 47.2, 107),
            ("7e 53 75 00 ea 07 0b 03 0f 0f 05 02 ec 05 3a 02 f0 03 26 04",
             "7d 02 bc 01 95 01 36 00 04 68 00 c9 00 1c 43 7f 03 04 1c", 60.15, 11.7, 63.7, 67),
            ("7e 53 6a 01 ea 07 0b 07 07 31 2d 03 63 06 9c 01 5a 04 94 04",
             "cd 01 fe 01 c3 01 3a 00 0e 3e 01 91 00 25 52 50 02 06 1b", 91.85, 36.2, 46.1, 82),
        ]
        for c in cases {
            let head = hexData(c.head), tail = hexData(c.tail)
            #expect(Profile.awaitsContinuation(head, dialect: .qardioX))
            #expect(!Profile.awaitsContinuation(tail, dialect: .qardioX))
            #expect(!Profile.awaitsContinuation(head, dialect: .standard))
            // A retransmitted head between head and continuation changes nothing.
            #expect(Profile.parseBodyComposition(frames: [head, head, tail], weightKg: c.weight, resolution: x,
                                                 dialect: .qardioX)?.heartRateBpm == c.pulse)
            // The head alone still yields what fits: fat and muscle.
            #expect(Profile.parseBodyComposition(head) == nil)
            let partial = try #require(Profile.parseBodyComposition(frames: [head], weightKg: c.weight,
                                                                      resolution: x, dialect: .qardioX))
            #expect(abs(try #require(partial.fatPct) - c.fat) < 0.001)
            #expect(partial.waterPct == nil)

            let merged = try #require(Profile.parseBodyComposition(frames: [head, tail], weightKg: c.weight,
                                                                     resolution: x, dialect: .qardioX))
            #expect(abs(try #require(merged.fatPct) - c.fat) < 0.001)
            #expect(abs(try #require(merged.waterPct) - c.water) < 0.001)
            #expect(merged.heartRateBpm == c.pulse)
            // Water ≈ 73 % of fat-free mass, which is what makes it a percentage.
            #expect(abs(c.water - 0.73 * (100 - c.fat)) < 2)
        }

        // Spec scales: the next frame is its own packet, never a flagless tail.
        let standard = Profile.parseBodyComposition(frames: [hexData(cases[0].head), hexData(cases[0].tail)],
                                                    weightKg: 84.95, resolution: x)
        #expect(standard?.heartRateBpm == nil)
        // Implausible impedance in the continuation discards the whole measurement,
        // and a later retransmission of that head doesn't bring its fat back.
        let head = hexData(cases[0].head)
        let noContact = hexData("d8 01 d0 07 10 02 38 00 0c 34 01 95 00 24 6b 77 02 06 25")
        #expect(Profile.parseBodyComposition(frames: [head, noContact], weightKg: 84.95,
                                             resolution: x, dialect: .qardioX) == nil)
        #expect(Profile.parseBodyComposition(frames: [head, noContact, head], weightKg: 84.95,
                                             resolution: x, dialect: .qardioX) == nil)
        #expect(Profile.parseBodyComposition(frames: [head, noContact, head, noContact], weightKg: 84.95,
                                             resolution: x, dialect: .qardioX) == nil)
        // A retransmitted good pair still gives the one measurement.
        let tail = hexData(cases[0].tail)
        #expect(Profile.parseBodyComposition(frames: [head, tail, head, tail], weightKg: 84.95,
                                             resolution: x, dialect: .qardioX)?.heartRateBpm == 107)
    }

    // MARK: - User Data writes (QardioBase X, issue #60)

    @Test func encodesUserDataWrites() {
        typealias UserData = StandardScaleProfile.UserData
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let now = utc.date(from: DateComponents(year: 2026, month: 11, day: 8))!
        let birth = DateComponents(year: 1985, month: 6, day: 15)

        #expect(UserData.height(cm: 187) == Data([0xBB, 0x00]))
        #expect(UserData.height(cm: 186.6) == Data([0xBB, 0x00]))
        #expect(UserData.height(cm: 0) == nil)
        #expect(UserData.dateOfBirth(birth) == Data([0xC1, 0x07, 6, 15]))
        #expect(UserData.dateOfBirth(DateComponents(year: 1985)) == nil)
        #expect(UserData.age(dateOfBirth: birth, now: now, calendar: utc) == Data([41]))
        #expect(UserData.gender(.female) == Data([1]))

        let profile = StandardScaleProfile.UserProfile(heightCm: 187, dateOfBirth: birth, sex: .male)
        let writes = UserData.writes(for: profile, now: now)
        #expect(writes.map(\.uuid) == ["2A8E", "2A85", "2A80", "2A8C"])
        #expect(writes.last?.value == Data([0]))
        // Only what's known is written.
        #expect(UserData.writes(for: .init(heightCm: nil, dateOfBirth: nil, sex: nil)).isEmpty)
        #expect(UserData.writes(for: .init(heightCm: 170, dateOfBirth: nil, sex: nil)).map(\.uuid) == ["2A8E"])
    }
}
