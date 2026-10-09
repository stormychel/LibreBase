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
    }

    @Test func encodesCurrentTime() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        // 2026-10-09 07:30:15 UTC is a Friday (Bluetooth weekday 5).
        let date = utc.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 7, minute: 30, second: 15))!
        #expect(StandardScaleProfile.currentTime(date, calendar: utc)
                == Data([0xEA, 0x07, 10, 9, 7, 30, 15, 5, 0, 0]))
    }

    @Test func userControlPointFrames() {
        typealias ControlPoint = StandardScaleProfile.ControlPoint
        #expect(ControlPoint.register(consentCode: 1234) == Data([0x01, 0xD2, 0x04]))
        #expect(ControlPoint.consent(userIndex: 2, consentCode: 1234) == Data([0x02, 0x02, 0xD2, 0x04]))
        #expect(ControlPoint.parseResponse(Data([0x20, 0x01, 0x01, 0x02]))
                == ControlPoint.Response(request: 0x01, succeeded: true, userIndex: 2))
        #expect(ControlPoint.parseResponse(Data([0x20, 0x02, 0x05]))
                == ControlPoint.Response(request: 0x02, succeeded: false, userIndex: nil))
        #expect(ControlPoint.parseResponse(Data([0x01, 0x02])) == nil)
    }
}
