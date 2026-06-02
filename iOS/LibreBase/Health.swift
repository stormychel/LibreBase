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

    /// Request permission to write body mass. We never read, so no read types.
    func requestAuth() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let mass = HKQuantityType(.bodyMass)
        try await store.requestAuthorization(toShare: [mass], read: [])
    }

    /// Save a weight sample (kilograms) to Apple Health.
    func saveWeight(kg: Double, date: Date) async throws {
        let type = HKQuantityType(.bodyMass)
        let quantity = HKQuantity(unit: .gramUnit(with: .kilo), doubleValue: kg)
        let sample = HKQuantitySample(type: type, quantity: quantity, start: date, end: date)
        try await store.save(sample)
    }
}
