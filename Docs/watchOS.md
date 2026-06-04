# watchOS companion (v1: HealthKit mirror)

LibreBase's watch app is a **read-only mirror**: it shows the latest weight + BMI
from Apple Health (written by the iPhone app and synced to the watch). It does
**no Bluetooth** — that's the standalone-BLE research track in issue #29.

## Target

- Target / scheme: **LibreBase Watch App Watch App** (paired with the LibreBase
  iOS app; the name is doubled because Xcode appends "Watch App" to the product
  name — cosmetic, safe to rename later).
- Sources live in `iOS/LibreBase Watch App Watch App/`.

The watch target is **self-contained** — it has its own small `WatchHealth`
(read-only HealthKit) and `WatchBrand` (teal gradient) rather than sharing the
iOS `Health`/`Brand`, so there's no cross-target file membership to manage.
Unifying the shared bits into a local Swift package is tracked in **#29**.

## What's wired

- `LibreBaseWatchApp.swift` — entry point.
- `WatchContentView.swift` — gradient card (weight + colored BMI badge + weigh-in
  date, kg/lb per locale); empty state when there's no reading yet; refreshes on
  appear, on foreground, and pull-to-refresh.
- `WatchHealth.swift` / `WatchBrand.swift` — self-contained helpers.
- **HealthKit capability:** `LibreBaseWatch.entitlements`
  (`com.apple.developer.healthkit`) + `INFOPLIST_KEY_NSHealthShareUsageDescription`
  are set on the watch target's build settings. On launch the watch asks for
  Health access; once granted (and with a weight in Health) it shows the card.

## Run

Select the **LibreBase Watch App Watch App** scheme + a watchOS 26.5 simulator and
run. Verified: builds, launches, and presents the Health authorization prompt;
empty state renders when no weight is available.

> Note: to see a real reading on the simulator you need a weight in the paired
> iPhone simulator's Health and HealthKit sync — on device it just works once the
> iPhone app has logged a weigh-in.

## Enhancements (not in v1)

- **Complication / Smart Stack** widget (WidgetKit extension) showing the latest
  weight — needs its own target.
- **`HKObserverQuery`** for live updates instead of refresh-on-foreground.
- Standalone Bluetooth weigh-in on the watch — research in **#29**.
