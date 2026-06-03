//
//  Health.swift
//  LibreBase
//
//  Created by Michel Storms on 02/06/2026.
//

import Combine
import HealthKit

/// Thin wrapper over HealthKit for saving weight measurements.
final class Health: ObservableObject {
    let store = HKHealthStore()

    /// Request permission to write body mass and height, and read height (for BMI).
    func requestAuth() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let mass = HKQuantityType(.bodyMass)
        let height = HKQuantityType(.height)
        try await store.requestAuthorization(toShare: [mass, height], read: [height])
    }

    /// Share (write) authorization for body mass. HealthKit never reveals *read*
    /// authorization, so this is the only status onboarding can reflect — enough
    /// to know whether the permission sheet has been answered.
    var bodyMassWriteStatus: HKAuthorizationStatus {
        store.authorizationStatus(for: HKQuantityType(.bodyMass))
    }

    /// Save a height sample (centimeters) to Apple Health, keeping it in sync with
    /// an edit made in the app.
    func saveHeight(cm: Double) async throws {
        let type = HKQuantityType(.height)
        let quantity = HKQuantity(unit: .meterUnit(with: .centi), doubleValue: cm)
        let sample = HKQuantitySample(type: type, quantity: quantity, start: Date(), end: Date())
        try await store.save(sample)
    }

    /// Most recent height sample in centimeters, or nil if none is stored or read
    /// access wasn't granted. HealthKit never reveals read denial, so callers must
    /// treat nil as "unknown" and fall back to a manually entered height.
    func latestHeightCm() async -> Double? {
        guard HKHealthStore.isHealthDataAvailable() else { return nil }
        let type = HKQuantityType(.height)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        return await withCheckedContinuation { cont in
            let query = HKSampleQuery(sampleType: type, predicate: nil,
                                      limit: 1, sortDescriptors: [sort]) { _, samples, _ in
                guard let sample = samples?.first as? HKQuantitySample else {
                    cont.resume(returning: nil)
                    return
                }
                cont.resume(returning: sample.quantity.doubleValue(for: .meterUnit(with: .centi)))
            }
            self.store.execute(query)
        }
    }

    /// Save a weight sample (kilograms) to Apple Health.
    func saveWeight(kg: Double, date: Date) async throws {
        let type = HKQuantityType(.bodyMass)
        let quantity = HKQuantity(unit: .gramUnit(with: .kilo), doubleValue: kg)
        let sample = HKQuantitySample(type: type, quantity: quantity, start: date, end: date)
        try await store.save(sample)
    }
}
