# watchOS companion (v1: HealthKit mirror)

LibreBase's watch app is a **read-only mirror**: it shows the latest weight + BMI
from Apple Health (written by the iPhone app and synced to the watch). It does
**no Bluetooth** — that's the standalone-BLE research track in issue #29.

The source is scaffolded under `iOS/LibreBaseWatch/`. The watchOS **target itself
must be created in Xcode** (hand-editing `project.pbxproj` for a new platform
target risks corrupting it). Steps:

## 1. Add the target

Xcode ▸ **File ▸ New ▸ Target… ▸ watchOS ▸ App**.
- Product name: **LibreBase Watch App**
- Interface: SwiftUI, Language: Swift
- Bundle id: `com.michelstorms.LibreBase.watchkitapp` (or your preference)
- Embed in the LibreBase iOS app when prompted.

Delete the auto-generated `ContentView.swift` / `…App.swift` it creates.

## 2. Add the scaffolded files to the target

Add these to the new watch target (drag into the target's group, or set Target
Membership):

- `iOS/LibreBaseWatch/LibreBaseWatchApp.swift`
- `iOS/LibreBaseWatch/WatchContentView.swift`
- `iOS/LibreBaseWatch/Assets.xcassets`

Then tick these **shared** files into the watch target too (File Inspector ▸
Target Membership — they already live in the iOS app):

- `iOS/LibreBase/Health.swift`  (HealthKit wrapper; `requestReadAuth()` +
  `latestWeight()` are used by the watch)
- `iOS/LibreBase/Brand.swift`   (teal design language)

> Later cleanup: move `Health`/`Brand` (and eventually `ScaleClient`) into a
> shared local Swift package so both targets depend on one copy. Tracked with #29.

## 3. Capability + Info.plist

On the watch target:
- Signing & Capabilities ▸ **+ HealthKit**.
- Add **`NSHealthShareUsageDescription`**, e.g.:
  *"LibreBase shows your most recent weight and BMI from Apple Health."*
  (Read-only — no `NSHealthUpdateUsageDescription` needed.)

## 4. Build & run

Select the watch scheme + a paired watch simulator and run. With a weight already
in Health, the gradient card shows weight, BMI category, and the weigh-in date;
otherwise the empty state points you to the iPhone app.

## Enhancements (not in v1)

- **Complication / Smart Stack** widget (WidgetKit extension) showing the latest
  weight — needs its own target.
- **`HKObserverQuery`** for live updates instead of refresh-on-foreground.
- Standalone Bluetooth weigh-in on the watch — research in **#29**.
