//
//  WeighInRecorder.swift
//  LibreBase
//
//  Created by Michel Storms on 09/10/2026.
//

import Combine
import UIKit

/// Routes each finished weigh-in to Apple Health. Lives at app level rather than
/// in a view: when iOS relaunches the app in the background for a weigh-in (see
/// `ScaleClient` state restoration) no view exists to do the saving.
final class WeighInRecorder: ObservableObject {
    static let shared = WeighInRecorder()

    /// A finished weigh-in that auto-save (being off) didn't write to Health; the
    /// user can still save it by hand until the next weigh-in replaces it.
    @Published var unsavedReading: ScaleReading?
    /// Mirrors `ScaleUserBinding.knownUsers()`; refreshed after each weigh-in.
    @Published var knownScaleUsers = ScaleUserBinding.knownUsers()

    private let scale = ScaleClient.shared
    private let health = Health.shared

    func install() {
        scale.onFinalReading = { [weak self] reading in self?.record(reading) }
    }

    private func record(_ reading: ScaleReading) {
        // A shared scale reports every household member's weigh-in; only
        // save the ones attributed to this phone's owner. See issue #42.
        // Whatever happens to this weigh-in, an older pending one no longer
        // matches the reading on screen.
        unsavedReading = nil
        let decision = ScaleUserBinding.decide(for: reading.scaleUser)
        knownScaleUsers = ScaleUserBinding.knownUsers()
        if case .skip(let user) = decision {
            scale.status = "Weigh-in for “\(user.name)” — not saved to Health"
            return
        }
        // Same key and default as the "Auto-save to Apple Health" toggle.
        guard UserDefaults.standard.object(forKey: "autoSaveToHealth") as? Bool ?? true else {
            unsavedReading = reading
            scale.status = "Weigh-in complete — not saved to Health"
            return
        }
        save(reading)
    }

    func save(_ reading: ScaleReading) {
        Task { @MainActor in
            do {
                try await health.saveWeight(kg: reading.weightKg, date: reading.timestamp)
                if let composition = reading.composition {
                    await health.saveComposition(composition, weightKg: reading.weightKg,
                                                 date: reading.timestamp)
                }
                scale.status = "Saved to Apple Health"
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                scale.status = "Couldn't save to Health — check Settings ▸ Privacy ▸ Health"
                // Keep it saveable by hand unless a newer weigh-in took its place.
                if scale.lastReading?.timestamp == reading.timestamp { unsavedReading = reading }
            }
        }
    }
}
