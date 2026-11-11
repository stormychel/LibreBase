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


    // MARK: - Report capture summary (#56, #62)

    @Test func summarizesCaptures() {
        #expect(CaptureSummary(log: ["found peripheral: \"Square Reader 3837\" rssi:-84"]).description
                == "no Qardio scale found")
        let x = CaptureSummary(log: ["found peripheral: \"QardioBase X\" rssi:-72",
                                     "<- Model Number String: 42 58 30 30",
                                     "<- 2A9D: 4e a3 06 ea 07 0b 07 0a 0b 08 03 00 00 00 00"])
        #expect(x.qardioFound && x.modelNumber == "BX00" && x.gotMeasurement)
        #expect(x.description == "model BX00, measurement received")
        let b100 = CaptureSummary(log: ["found peripheral: \"QardioBase\" rssi:-86",
                                        "<- Model Number String: 42 31 30 30",
                                        "qardio measurement JSON decoded: 97.6 kg"])
        #expect(b100.description == "model B100, measurement received")
        #expect(CaptureSummary(log: ["<- Model Number String: "]).modelNumber == nil)
        #expect(CaptureSummary(log: ["<- Model Number String: 42 32 30 30 00"]).modelNumber == "B200")
    }
}
