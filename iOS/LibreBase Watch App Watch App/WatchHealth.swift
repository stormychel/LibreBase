//
//  WatchHealth.swift
//  LibreBase Watch App
//
//  Created by Michel Storms on 04/06/2026.
//

import Combine
import HealthKit

/// Read-only HealthKit access for the watch mirror. Deliberately self-contained
/// (no dependency on the iOS `Health`) so the watch target needs no cross-target
/// file membership. Unifying this with the iOS code into a shared package is
/// tracked in issue #29.
final class WatchHealth: ObservableObject {
    let store = HKHealthStore()

    /// Request read access to weight and height. The watch only displays data.
    func requestReadAuth() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        try await store.requestAuthorization(
            toShare: [],
            read: [HKQuantityType(.bodyMass), HKQuantityType(.height)]
        )
    }

    /// Most recent body-mass sample in kilograms with its date, or nil.
    func latestWeight() async -> (kg: Double, date: Date)? {
        await latest(.bodyMass).map { ($0.quantity.doubleValue(for: .gramUnit(with: .kilo)), $0.endDate) }
    }

    /// Most recent height sample in centimeters, or nil.
    func latestHeightCm() async -> Double? {
        await latest(.height)?.quantity.doubleValue(for: .meterUnit(with: .centi))
    }

    private func latest(_ identifier: HKQuantityTypeIdentifier) async -> HKQuantitySample? {
        guard HKHealthStore.isHealthDataAvailable() else { return nil }
        let type = HKQuantityType(identifier)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        return await withCheckedContinuation { cont in
            let query = HKSampleQuery(sampleType: type, predicate: nil,
                                      limit: 1, sortDescriptors: [sort]) { _, samples, _ in
                cont.resume(returning: samples?.first as? HKQuantitySample)
            }
            self.store.execute(query)
        }
    }
}
