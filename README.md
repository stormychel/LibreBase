# Resurrecting the QardioBase — A Reverse-Engineering Playbook

*Building an independent BLE app for the Qardio smart scale after Qardio Inc. shut down*

---

## 0. Context

Qardio Inc. effectively collapsed in 2025 — the Netherlands B.V. filed for bankruptcy, the UK entity had repeated strike-off actions, the backend went dark, and the `qardio.com` domain was sold off in November 2025. The official **Qardio App** was pulled from both the App Store and Google Play. The hardware (QardioBase / QardioBase 2 / QardioBase X) is intact but orphaned: no app, no cloud, no support.

The good news: the scale still talks **directly over Bluetooth LE**, and that path appears to be local — not gated behind the dead servers. That makes an independent client feasible.

This document is the build plan. Target: a small SwiftUI + CoreBluetooth app that pairs the scale, reads weight + body-composition, and writes everything into **Apple Health (HealthKit)** so you're never hostage to one vendor again.

**Precedent:** `LibreArm` did exactly this for the QardioArm blood-pressure cuff — reverse-engineered the BLE protocol with nRF Connect and shipped a HealthKit logger to the App Store. No equivalent exists yet for the BASE scale. `openScale` (oliexdev/openScale) is the big open-source scale project but does **not** currently support Qardio, so this is original work — on a very well-trodden path.

---

## 0.5 FIRST — Rescue the data (time-sensitive)

The old iPhone that still has the working app is being handed on. **Do this before it's wiped**, in order:

1. **Confirm history is in Health.** On the new phone: `Health → Browse → Body Measurements → Weight`. If the QardioBase history is there, sync was on, the data lives in iCloud/HealthKit under the user's Apple ID, and it already migrated to the new phone independently of Qardio.
2. **Full export as backup.** `Health → profile picture → Export All Health Data` → produces a zip of XML. Keep it forever.
3. **Check the Qardio app for a local export.** Open it on the old phone one last time and look for any in-app export/share. If the data was never synced to Health, this is the only copy and it dies with the wipe.

> **Bonus:** the old phone is also your one chance to **sniff a real session** between the genuine app and the scale (see Phase 2). Do the capture before the handoff.

---

## 1. The plan at a glance

| Phase | Goal | Tooling | Effort |
|-------|------|---------|--------|
| 1. Recon | Dump the GATT table; spot standard vs custom services | nRF Connect | ~10 min |
| 2. Capture | Record a real weigh-in handshake | PacketLogger (iOS) / HCI snoop (Android) / nRF52840 sniffer | 1 evening |
| 3. Decode | Parse weight + impedance payloads | Wireshark, openScale source as reference | a few evenings |
| 4. Build | SwiftUI + CoreBluetooth → HealthKit | Xcode | ~1 day once protocol is known |

**Best case:** the scale speaks the standard Weight Scale Service — a weekend, mostly UI/HealthKit polish.
**Likely case:** lightweight custom profile, no crypto — a few evenings of sniff-and-decode.
**Worst case (unlikely):** measurements gated behind a server-issued token. Field reports of the scale working over direct BLE with the servers down suggest this is *not* the case.

---

## 2. Phase 1 — Recon (do this now)

Install **nRF Connect** (iOS or Android), scan, connect to the scale, and dump its GATT table. The decisive question:

**Does it expose the standard SIG-defined services?**

| UUID | Service | Meaning if present |
|------|---------|--------------------|
| `0x181D` | Weight Scale | Weight payload is IEEE-spec'd — half the work done |
| `0x181B` | Body Composition | Impedance/composition payload is spec'd |
| `0x180F` | Battery Service | Battery level, free |
| `0x180A` | Device Information | Model/firmware strings |

If you instead see **128-bit vendor-specific UUIDs**, it's a custom profile and you sniff (Phase 2).

**What to record for each characteristic:**
- UUID
- Properties (`read` / `write` / `writeWithoutResponse` / `notify` / `indicate`)
- Handle

Then **subscribe to every `notify`/`indicate` characteristic, step on the scale, and watch what arrives.** For many scales a measurement notification fires on weigh-in with no handshake at all — that alone might be the whole protocol.

---

## 3. Phase 2 — Capture a real session

You want the genuine app's full exchange: any init writes, pairing, and the measurement notifications. Three routes, pick what's convenient:

### A. iOS PacketLogger (cleanest for an Apple dev)
1. Install Apple's **Bluetooth logging profile** on the old iPhone (from the Apple developer "Bug Reporting" profiles, or trigger via `sysdiagnose`).
2. Tether to a Mac, open **PacketLogger** (ships with *Additional Tools for Xcode*).
3. Do a real weigh-in with the official app.
4. Save the HCI trace.

### B. Android HCI snoop log
1. Sideload the Qardio Android APK (still on APK mirror sites; it's delisted, not unobtainable).
2. Developer Options → **Enable Bluetooth HCI snoop log**.
3. Weigh in, then pull `btsnoop_hci.log`.
4. Open in **Wireshark**. This is the exact workflow openScale's *"How to support a new scale"* wiki documents.

### C. Passive sniffer (gold standard)
- **nRF52840 dongle** (~€20) + **nRF Sniffer** plugin for Wireshark.
- Captures the live app↔scale link without instrumenting either device.
- Best fidelity, and you keep the capture for offline analysis.

> Filter Wireshark to `btatt` and look at writes *from* the phone (init/auth) and notifications *from* the scale (measurements). Enable a timestamp column so you can correlate the moment you stepped on the scale.

---

## 4. Phase 3 — Decode

### Current QardioBase B100 findings (2026-06-02)

The tested unit does **not** expose standard Weight Scale (`0x181D`) or Body
Composition (`0x181B`) services. It exposes Device Info, Battery, and a custom
Qardio service:

| UUID | Meaning observed |
|------|------------------|
| `A78AF805-8F3F-4E8F-A964-318B768BC38C` | control/state notify: `00` idle, `03` measuring, `06` done |
| `9F3F4E1B-37D7-4F95-B374-CF585D808BEB` | noisy engineering/debug stream; also accepts config write `00 00 01 01` |
| `B24F98BE-9CD4-4F82-B935-01F18F104EDE` | final measurement JSON; read after state `06` |
| `1EC92A15-14E0-43E7-A990-CB37000990BA` | calibration JSON |

Calibration read:

```json
{"0":"0","50":"5945","100":"11888","150":"17836","z":"523"}
```

This gives roughly `118.907` raw load-cell counts per kg. The `z` term appears
to be a millikilogram correction (`523` → `+0.523 kg`).

Known-good weight frame from a real weigh-in where the expected result was
`87.4–87.7 kg`:

```text
21 70 28 10
```

Decode:

```text
raw = littleEndian(bytes[1...2]) = 0x2870 = 10352
kg  = raw / 118.907 + 0.523 = 87.6 kg
```

Later research found the important shortcut: do **not** decode weight from the
engineering stream unless necessary. After state `06`, read
`B24F98BE-9CD4-4F82-B935-01F18F104EDE`; the scale returns plain UTF-8 JSON:

```json
{"weight":"76.0","bmi":"19.3","z":"2031","fat":"57","tbw":"31","bmc":"3","mt":"9","sm":"17"}
```

The app now reads and parses this JSON characteristic. The `9F3F...` frames are
still useful for recon/state timing, but many of their 16-bit windows are false
positives and can repeat between users.

PacketLogger note: when the legacy Qardio app was running, the trace only showed
QardioBase advertisements/scan responses, not ATT/BTATT. That suggests the
official app may not be doing a live BLE GATT session in that setup (for example
it may be relying on Wi-Fi/cloud/local cache), so the useful data for LibreBase
currently comes from direct CoreBluetooth recon against the custom GATT profile.

### Weight
Almost always a **little-endian 16-bit integer** with a fixed scale factor:
- IEEE Weight Scale profile: units of **5 g** (multiply raw by 0.005 for kg).
- Many custom scales: raw value in **grams** or **0.1 kg**.

Step on with a known weight (a dumbbell of known mass helps) to pin the scale factor immediately.

### Body composition
The scale measures **bioimpedance** and the app converts it to body fat %, water %, muscle, bone via a body model (age, sex, height as inputs). The raw frame likely carries impedance (ohms) plus weight. You have two options:
- Reproduce a published impedance→composition formula (openScale's source implements several, with citations — useful as a conceptual reference; note openScale is **GPL**, so treat its code as reference, not copy-paste, for a closed app).
- Or ship weight-only first and add composition later.

### Frame anatomy to look for
- A **flags/op byte** at offset 0 (tells you which optional fields follow).
- **Weight** field.
- Optional **impedance**, **timestamp**, **user index** fields.
- A possible **init write** the app sends before the scale starts streaming (replay it verbatim from your capture).

Document the decoded frame in a table as you go — that table *is* the protocol spec, and it's what you'd contribute back to openScale.

---

## 5. Phase 4 — Build (Swift)

### 5.1 GATT discovery probe

Drop this into a fresh iOS app to run the recon step from your own code. Replace the service UUID once you know it; with `nil` it discovers everything.

```swift
import CoreBluetooth

final class ScaleProbe: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private var central: CBCentralManager!
    private var scale: CBPeripheral?

    // TODO: set once known. nil = discover all services.
    private let targetService: CBUUID? = nil
    // Heuristic name match for the scan phase:
    private let nameHint = "QardioBase"

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        guard c.state == .poweredOn else { return }
        c.scanForPeripherals(withServices: targetService.map { [$0] },
                             options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        print("Scanning…")
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi: NSNumber) {
        let advName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? ""
        print("Found:", advName, "RSSI:", rssi)
        guard advName.localizedCaseInsensitiveContains(nameHint) else { return }
        scale = p
        p.delegate = self
        c.stopScan()
        c.connect(p)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        print("Connected. Discovering services…")
        p.discoverServices(targetService.map { [$0] })
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        for s in p.services ?? [] {
            print("Service:", s.uuid)
            p.discoverCharacteristics(nil, for: s)
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for ch in s.characteristics ?? [] {
            print("  Char:", ch.uuid, "props:", propString(ch.properties))
            if ch.properties.contains(.notify) || ch.properties.contains(.indicate) {
                p.setNotifyValue(true, for: ch)   // subscribe to everything streamable
            }
            if ch.properties.contains(.read) {
                p.readValue(for: ch)
            }
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard let data = ch.value else { return }
        print("  <- \(ch.uuid):", data.map { String(format: "%02x", $0) }.joined(separator: " "))
        // Step on the scale and watch the bytes change here.
    }

    private func propString(_ p: CBCharacteristicProperties) -> String {
        var out: [String] = []
        if p.contains(.read) { out.append("read") }
        if p.contains(.write) { out.append("write") }
        if p.contains(.writeWithoutResponse) { out.append("writeNR") }
        if p.contains(.notify) { out.append("notify") }
        if p.contains(.indicate) { out.append("indicate") }
        return out.joined(separator: ",")
    }
}
```

`Info.plist` needs `NSBluetoothAlwaysUsageDescription`.

### 5.2 Parsing (template — fill in from your capture)

```swift
struct ScaleReading {
    let weightKg: Double
    let impedanceOhm: Double?
    let timestamp: Date
}

func parse(_ data: Data) -> ScaleReading? {
    guard data.count >= 3 else { return nil }
    // EXAMPLE shape — confirm offsets/scale from your sniff:
    let raw = UInt16(data[1]) | (UInt16(data[2]) << 8)   // little-endian
    let weightKg = Double(raw) * 0.005                    // IEEE 5 g units; adjust
    return ScaleReading(weightKg: weightKg, impedanceOhm: nil, timestamp: Date())
}
```

### 5.3 Write to HealthKit

```swift
import HealthKit

let store = HKHealthStore()

func requestAuth() async throws {
    let types: Set = [
        HKQuantityType(.bodyMass),
        HKQuantityType(.bodyFatPercentage),
        HKQuantityType(.leanBodyMass),
        HKQuantityType(.bodyMassIndex)
    ]
    try await store.requestAuthorization(toShare: types, read: types)
}

func save(_ r: ScaleReading) async throws {
    let sample = HKQuantitySample(
        type: HKQuantityType(.bodyMass),
        quantity: HKQuantity(unit: .gramUnit(with: .kilo), doubleValue: r.weightKg),
        start: r.timestamp, end: r.timestamp
    )
    try await store.save(sample)
}
```

Add `bodyFatPercentage` / `leanBodyMass` once the impedance→composition step is in.
`Info.plist` needs `NSHealthShareUsageDescription` and `NSHealthUpdateUsageDescription`, plus the **HealthKit** capability.

---

## 6. Risks & open questions

- **Auth gate:** the one real blocker would be a server-issued token unlocking measurements. Field evidence (scale works over direct BLE with servers dead) argues against it. Confirm in your capture — look for any write the app *must* send before streaming starts.
- **Model differences:** QardioBase vs QardioBase 2 vs QardioBase X may differ in services/firmware. Note your exact model and serial. The X is rechargeable and newer; the original/2 may use the simpler profile.
- **Pairing/bonding:** check whether the scale requires BLE bonding (encryption) or "Just Works". If bonded to the old phone, you may need to factory-reset the scale (`reset` via the app settings / hardware procedure) so it re-advertises for pairing.
- **WiFi path is dead** and irrelevant — ignore it. BLE direct is the route.

---

## 7. Shipping & posture

- Frame it as a **wellness logger**, not a medical device: read values, write to HealthKit, no diagnosis, no medical advice. That distinction is what got LibreArm approved on the App Store.
- **Open-source it** (LibreArm's reasoning: resilience — if it's ever pulled, the code survives). A public repo also makes it a clean portfolio piece for `github.com/stormychel`.
- Consider contributing a **Qardio driver to openScale** on the Android/Kotlin side while the protocol is fresh in your head — you'd be the first, and it helps every other stranded owner.
- Reverse-engineering for interoperability of hardware you own, from a defunct vendor, is broadly defensible — but this is an engineering doc, not legal advice; if you plan to distribute commercially, sanity-check it for your jurisdiction.

---

## 8. References

- **LibreArm** — open-source QardioArm revival (BLE reverse-engineering + HealthKit, App Store approved as wellness app).
- **openScale** (oliexdev/openScale) — open-source BT scale tracker; *"How to support a new scale"* wiki = the capture/decode workflow; source has impedance→composition formulas (GPL — reference only).
- **nRF Connect** (Nordic) — GATT explorer for recon.
- **nRF Sniffer + nRF52840 dongle** — passive BLE capture into Wireshark.
- Apple **PacketLogger** (Additional Tools for Xcode) — iOS HCI capture.
- Apple docs: **Core Bluetooth**, **HealthKit** (`HKQuantityType`, `bodyMass`, `bodyFatPercentage`, `leanBodyMass`, `bodyMassIndex`).

---

### Immediate next actions
1. **Today, before the old phone leaves:** export Health data + capture a real weigh-in session.
2. Run nRF Connect recon — record the GATT table.
3. Step on the scale while subscribed to notifications; see if weight falls out for free.
4. If yes → straight to the Swift build. If no → Wireshark the capture and decode the frame.
