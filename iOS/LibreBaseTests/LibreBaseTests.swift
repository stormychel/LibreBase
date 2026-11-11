//
//  LibreBaseTests.swift
//  LibreBaseTests
//
//  Created by Michel Storms on 02/06/2026.
//

import Testing
@testable import LibreBase

struct LibreBaseTests {

    @Test func example() async throws {
        // Write your test here and use APIs like `#expect(...)` to check expected conditions.
        // Swift Testing Documentation
        // https://developer.apple.com/documentation/testing
    }


    // MARK: - Weight unit setting (#57)

    @Test func weightUnitSettingOverridesRegion() {
        #expect(WeightUnitSetting.automatic.showsKilograms(regionIsMetric: true))
        #expect(!WeightUnitSetting.automatic.showsKilograms(regionIsMetric: false))
        #expect(!WeightUnitSetting.pounds.showsKilograms(regionIsMetric: true))
        #expect(WeightUnitSetting.kilograms.showsKilograms(regionIsMetric: false))
        #expect(WeightUnitSetting(rawValue: "pounds") == .pounds)
    }
}
