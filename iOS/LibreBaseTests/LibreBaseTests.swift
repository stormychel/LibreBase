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
}
