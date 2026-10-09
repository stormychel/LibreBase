//
//  ScaleClient.swift
//  LibreBase
//
//  Created by Michel Storms on 02/06/2026.
//

import Combine
import CoreBluetooth
import Foundation

/// A single stabilized weigh-in from the scale.
struct ScaleReading {
    let weightKg: Double
    let timestamp: Date
    /// Only set by scales that report it (QardioBase result JSON).
    var composition: BodyComposition?
    var scaleUser: ScaleUser?

    /// Physiologically plausible adult weight range, also rejects SFLOAT/NaN junk.
    static func isPlausibleWeight(_ kg: Double) -> Bool {
        kg.isFinite && kg >= 2 && kg <= 400
    }
}

/// Connects to a Qardio (Base) smart scale over Bluetooth LE, reads weight, and
/// exposes it for saving to Apple Health.
///
/// The QardioBase BLE protocol is undocumented (see README — reverse-engineering
/// playbook). This client targets the **standard SIG services** as the best case:
///   - Weight Scale        0x181D / Weight Measurement 0x2A9D
///   - Body Composition    0x181B / Body Composition   0x2A9C
///   - Battery             0x180F / Battery Level       0x2A19
///   - Device Information   0x180A
/// plus, for scales that gate measurements behind them (QardioBase X):
///   - User Data           0x181C / User Control Point  0x2A9F
///   - Current Time        0x1805 / Current Time        0x2A2B
///
/// If the scale turns out to speak a custom profile, `reconMode` (on by default)
/// discovers *every* service/characteristic and logs every payload as hex to
/// `reconLog` — that first real-device run is the README's Phase-1 recon and
/// produces the bytes needed to finalize the parser.
final class ScaleClient: NSObject, ObservableObject {
    // MARK: - UI state
    @Published var status = "Searching for scale…"
    @Published var lastReading: ScaleReading?
    @Published var isConnected = false
    @Published var batteryLevelPct: Int?
    @Published var batteryStatusLine = "Battery: unavailable"

    // MARK: - Recon (Phase 1)
    /// When true, discover ALL services/characteristics and log every payload as
    /// hex. Off for production — the QardioBase protocol is now decoded. Flip on
    /// only to re-capture the GATT table from a new device.
    @Published var reconMode = false
    @Published var reconLog: [String] = []

    /// Fires once per weigh-in when the scale stops sending updates.
    var onFinalReading: ((ScaleReading) -> Void)?

    // MARK: - BLE
    /// Created on demand by `start()` rather than in `init`: building the central
    /// is what triggers the system Bluetooth permission prompt, and we want that
    /// to happen in onboarding's permission step — not in the app's first frame.
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var weightChar: CBCharacteristic?
    private var batteryChar: CBCharacteristic?
    private var qardioEngineeringChar: CBCharacteristic?
    private var qardioMeasurementChar: CBCharacteristic?
    private var bodyCompChar: CBCharacteristic?
    private var userControlPointChar: CBCharacteristic?
    /// Body Composition arrives as its own indication, before or after the
    /// weight; held here until there is a reading to attach it to.
    private var pendingComposition: BodyComposition?
    /// Services still waiting on characteristic discovery, so "no supported
    /// weight service" is decided once at the end instead of per service.
    private var servicesAwaitingCharacteristics = 0

    // Standard SIG services / characteristics
    private let weightScaleService  = CBUUID(string: "181D")
    private let weightMeasurement   = CBUUID(string: "2A9D")
    private let bodyCompService     = CBUUID(string: "181B")
    private let bodyCompMeasurement = CBUUID(string: "2A9C")
    private let batteryService      = CBUUID(string: "180F")
    private let batteryLevel        = CBUUID(string: "2A19")
    private let deviceInfoService   = CBUUID(string: "180A")
    private let userDataService     = CBUUID(string: "181C")
    private let userControlPoint    = CBUUID(string: "2A9F")
    private let currentTimeService  = CBUUID(string: "1805")
    private let currentTime         = CBUUID(string: "2A2B")

    // QardioBase B100 custom profile (discovered via recon, 2026-06-02).
    // The reliable weight source is the final-result JSON on `qbResult`, gated on
    // the `qbControl` "done" (0x06) state — see parseQardioMeasurementJSON. The
    // noisy `qbMeasure` engineering stream is used only for the early
    // `00 00 05 06` "result ready" marker; its raw frames are not decoded.
    private let qbService = CBUUID(string: "C8219E89-93E0-4169-A3DC-EA7959E866AF")
    private let qbMeasure = CBUUID(string: "9F3F4E1B-37D7-4F95-B374-CF585D808BEB") // notify: engineering/status stream
    private let qbResult = CBUUID(string: "B24F98BE-9CD4-4F82-B935-01F18F104EDE") // read: final measurement JSON
    private let qbControl = CBUUID(string: "A78AF805-8F3F-4E8F-A964-318B768BC38C") // notify: state (00 idle, 03 measuring, 06 done)

    /// Advertised-name hint used to recognize the scale during the scan.
    private let nameHint = "qardio"

    // Debounce: a weigh-in may stream several frames before stabilizing.
    private var completionWorkItem: DispatchWorkItem?
    /// Longer when Body Composition is subscribed, to leave room for its frame
    /// to follow the weight before the reading is finalized and saved.
    private var completionDebounceSeconds: TimeInterval { bodyCompChar == nil ? 1.5 : 3 }
    private var sessionActive = false
    private var qardioMeasurementActive = false
    /// Set true only when we drop the link on purpose (e.g. Retry). The resulting
    /// `didDisconnectPeripheral` then skips the automatic reconnect instead of
    /// racing a fresh scan. Any *unexpected* disconnect (the scale powering down
    /// after a weigh-in) leaves this false and triggers the pending reconnect.
    private var intentionalDisconnect = false
    /// Guards against saving the same weigh-in twice: the result JSON is read on
    /// both the `00 00 05 06` marker and the `control = 06` done state, so it can
    /// decode more than once per session. Reset when a new measurement starts.
    private var didFinalizeSession = false

    // Connect timeout
    private var connectTimeoutWorkItem: DispatchWorkItem?

    // MARK: - Public API

    /// Create the Bluetooth central — which is what raises the system Bluetooth
    /// permission prompt. Called from onboarding's permission step (so the prompt
    /// appears in context), and again from the main screen as a safety net for
    /// users upgrading past onboarding. Idempotent. Once the central reports
    /// `.poweredOn`, `centralManagerDidUpdateState` kicks off the first connect.
    func start() {
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main)
        }
    }

    /// Populate a believable weigh-in for App Store screenshots (see
    /// `ScreenshotMode`). Never called in normal use. The timestamp is a fixed
    /// fixture so the `reading` scene renders identically across runs and machines.
    func loadDemoReading() {
        isConnected = true
        batteryLevelPct = 84
        batteryStatusLine = "Battery: 84%"
        status = "Weigh-in complete"
        var components = DateComponents()
        components.year = 2026; components.month = 6; components.day = 1
        components.hour = 9; components.minute = 41
        let fixture = Calendar(identifier: .gregorian).date(from: components) ?? Date()
        lastReading = ScaleReading(weightKg: 72.6, timestamp: fixture)
    }

    /// Resume scanning after the app returns to the foreground — iOS suspends BLE
    /// scans while backgrounded, so a scan started earlier may be dead. Unlike
    /// `startConnect`, this preserves the last reading on screen and only kicks a
    /// scan when we aren't already connected, so reconnection is automatic without
    /// the user tapping anything.
    func resumeScanning() {
        guard let central, central.state == .poweredOn, !isConnected else { return }
        central.scanForPeripherals(withServices: nil, options: nil)
        if lastReading == nil { status = "Searching… step on the scale to connect" }
    }

    /// Begin scanning/connecting to the scale. Call on app start or on Retry.
    func startConnect(timeout: TimeInterval = 30) {
        guard let central, central.state == .poweredOn else {
            status = "Bluetooth unavailable"
            return
        }

        isConnected = false
        sessionActive = false
        qardioMeasurementActive = false
        didFinalizeSession = false
        qardioEngineeringChar = nil
        qardioMeasurementChar = nil
        lastReading = nil
        completionWorkItem?.cancel()
        connectTimeoutWorkItem?.cancel()
        // Drop any pending auto-reconnect so we don't end up with two connection
        // attempts to the same peripheral when the user taps Retry. Mark it
        // intentional so didDisconnectPeripheral doesn't immediately re-queue it.
        if let peripheral {
            intentionalDisconnect = true
            central.cancelPeripheralConnection(peripheral)
        }
        if reconMode { reconLog.removeAll() }

        status = "Searching for scale…"
        central.stopScan()
        // Scan unfiltered: the QardioBase does not advertise its vendor service
        // UUID, so a service-filtered scan never surfaces it. We match by name
        // hint / advertised standard service in didDiscover instead.
        central.scanForPeripherals(withServices: nil, options: nil)

        let work = DispatchWorkItem { [weak self] in
            guard let self = self, !self.isConnected else { return }
            // Deliberately do NOT stop scanning here. The QardioBase sleeps and
            // only advertises when stepped on, so the smart thing is to keep the
            // scan running indefinitely: the moment the user steps on, didDiscover
            // fires and we connect — no manual Retry needed. We only nudge the
            // status so the screen explains what to do.
            self.status = self.peripheral == nil
                ? "Searching… step on the scale to connect"
                : "Step on the scale to wake it…"
        }
        connectTimeoutWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
    }

    // MARK: - Battery

    private func updateBatteryStatus(_ level: Int?) {
        guard let level = level else {
            batteryLevelPct = nil
            batteryStatusLine = "Battery: unavailable"
            return
        }
        batteryLevelPct = level
        if level <= 10 {
            batteryStatusLine = "Battery: \(level)% (Critical)"
        } else if level <= 20 {
            batteryStatusLine = "Battery: \(level)% (Low)"
        } else {
            batteryStatusLine = "Battery: \(level)%"
        }
    }

    // MARK: - Validation

    private func isValidWeight(_ kg: Double) -> Bool {
        ScaleReading.isPlausibleWeight(kg)
    }

    // MARK: - Finalize

    private func scheduleFinalize() {
        completionWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.finalizeIfNeeded() }
        completionWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + completionDebounceSeconds, execute: work)
    }

    private func finalizeIfNeeded() {
        guard sessionActive, let reading = lastReading else { return }
        guard isValidWeight(reading.weightKg) else {
            sessionActive = false
            status = "Measurement invalid — please step on the scale again."
            return
        }
        sessionActive = false
        didFinalizeSession = true
        status = "Weigh-in complete"
        onFinalReading?(reading)
    }

    // MARK: - Parsers (standard Weight Measurement 0x2A9D / Body Composition 0x2A9C)

    private func parseWeight(_ data: Data) {
        guard let weight = StandardScaleProfile.parseWeight(data) else { return }

        // Note: the standard payload may carry a BMI field (flag 0x08), but it is
        // derived from a height stored on the scale that can only be set via the
        // (discontinued) Qardio app. We ignore it and compute BMI in-app instead.
        // Trust the scale's clock only when it is recent: an unset one reads 1970.
        let now = Date()
        let timestamp = weight.timestamp.flatMap {
            (now.addingTimeInterval(-7 * 86_400)...now.addingTimeInterval(300)).contains($0) ? $0 : nil
        } ?? now
        DispatchQueue.main.async {
            guard !self.didFinalizeSession else { return }
            self.lastReading = ScaleReading(weightKg: weight.kg, timestamp: timestamp,
                                            composition: self.pendingComposition)
            self.sessionActive = true
            self.status = "Measuring…"
            self.scheduleFinalize()
        }
    }

    private func parseBodyComposition(_ data: Data) {
        DispatchQueue.main.async {
            guard !self.didFinalizeSession else { return }
            guard let composition = StandardScaleProfile.parseBodyComposition(
                data, weightKg: self.sessionActive ? self.lastReading?.weightKg : nil) else { return }
            self.pendingComposition = composition
            if self.sessionActive, self.lastReading != nil {
                self.lastReading?.composition = composition
                self.scheduleFinalize()
            }
        }
    }

    // MARK: - User Data Service consent (QardioBase X)

    /// Scales with the User Data Service stay silent until a client identifies a
    /// user: Register New User (once, the scale assigns an index) then Consent
    /// (every connection) on the User Control Point. The index and the consent
    /// code we chose are kept per scale so repeat weigh-ins reuse the same user.
    private func beginUserConsent(on p: CBPeripheral) {
        guard let userControlPointChar else { return }
        status = "Setting up scale…"
        if let user = storedScaleUser(for: p) {
            log("-> user control point: consent, user \(user.index)")
            p.writeValue(StandardScaleProfile.ControlPoint.consent(userIndex: user.index, consentCode: user.code),
                         for: userControlPointChar, type: .withResponse)
        } else {
            let code = UInt16.random(in: 0...9999)
            UserDefaults.standard.set(Int(code), forKey: pendingConsentCodeKey(p))
            log("-> user control point: register new user")
            p.writeValue(StandardScaleProfile.ControlPoint.register(consentCode: code),
                         for: userControlPointChar, type: .withResponse)
        }
    }

    private func handleUserControlPoint(_ data: Data, from p: CBPeripheral) {
        typealias ControlPoint = StandardScaleProfile.ControlPoint
        guard let response = ControlPoint.parseResponse(data) else { return }
        switch (response.request, response.succeeded) {
        case (ControlPoint.registerNewUser, true):
            guard let index = response.userIndex else { return }
            let code = UserDefaults.standard.integer(forKey: pendingConsentCodeKey(p))
            UserDefaults.standard.set([Int(index), code], forKey: scaleUserKey(p))
            beginUserConsent(on: p)
        case (ControlPoint.consent, true):
            status = "Connected — step on the scale"
        case (ControlPoint.consent, false):
            // The scale no longer knows our user (reset, or deleted on the
            // scale): forget it and register afresh, once.
            guard storedScaleUser(for: p) != nil else { return }
            UserDefaults.standard.removeObject(forKey: scaleUserKey(p))
            beginUserConsent(on: p)
        default:
            status = "Scale didn't accept this phone — use “Report your scale” in Settings"
        }
    }

    private func scaleUserKey(_ p: CBPeripheral) -> String { "udsUser.\(p.identifier.uuidString)" }
    private func pendingConsentCodeKey(_ p: CBPeripheral) -> String { "udsPendingCode.\(p.identifier.uuidString)" }

    private func storedScaleUser(for p: CBPeripheral) -> (index: UInt8, code: UInt16)? {
        guard let pair = UserDefaults.standard.array(forKey: scaleUserKey(p)) as? [Int], pair.count == 2,
              let index = UInt8(exactly: pair[0]), let code = UInt16(exactly: pair[1]) else { return nil }
        return (index, code)
    }

    // MARK: - Recon logging

    private func log(_ line: String) {
        guard reconMode else { return }
        DispatchQueue.main.async {
            self.reconLog.append(line)
            print("[recon] \(line)")
        }
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    private func readQardioMeasurementJSON() {
        guard let peripheral, let qardioMeasurementChar else {
            log("qardio measurement JSON: B24F98BE characteristic not discovered")
            return
        }
        peripheral.readValue(for: qardioMeasurementChar)
    }

    /// Final QardioBase result. Unlike the noisy engineering stream, this is
    /// plain UTF-8 JSON, e.g. {"weight":"76.0","bmi":"19.3",...} — decoded by
    /// `QardioResult`.
    private func parseQardioMeasurementJSON(_ data: Data) {
        // The result is read on two triggers per weigh-in; only save it once.
        guard !didFinalizeSession else { return }

        guard let reading = QardioResult.parse(data) else {
            if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                log("qardio measurement JSON unparsed: \(text)")
            }
            return
        }

        log(String(format: "qardio measurement JSON decoded: %.1f kg", reading.weightKg))

        // Set the guard synchronously (delegate callbacks run on the main queue):
        // if a second result read is already in flight, it must see the flag set
        // here, not later inside the async block, or it would save twice.
        didFinalizeSession = true

        DispatchQueue.main.async {
            self.lastReading = reading
            self.sessionActive = false
            self.qardioMeasurementActive = false
            self.status = "Weigh-in complete"
            self.onFinalReading?(reading)
        }
    }

    private func controlStateName(_ data: Data) -> String {
        guard let v = data.first else { return "?" }
        switch v {
        case 0x00: return "idle"
        case 0x01: return "config"
        case 0x03: return "measuring"
        case 0x06: return "done"
        default:   return String(format: "0x%02x", v)
        }
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

// MARK: - CoreBluetooth

extension ScaleClient: CBCentralManagerDelegate, CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            startConnect()
        default:
            status = "Bluetooth not available"
            isConnected = false
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover p: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        let advName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? ""
        // Only log named peripherals — unnamed ones are environment noise.
        if !advName.isEmpty { log("found peripheral: \"\(advName)\" rssi:\(RSSI)") }

        let advertisesWeightScale =
            (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?.contains(weightScaleService) ?? false
        let advertisesQardioBase =
            (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?.contains(qbService) ?? false

        // Accept by name hint or by advertised standard service.
        guard advName.localizedCaseInsensitiveContains(nameHint) || advertisesWeightScale || advertisesQardioBase else {
            return
        }

        // Keep the connect timeout running: it's cancelled in didConnect. If the
        // scale sleeps before the connect completes, the timeout fires and the
        // pending connect stays queued to finish when it wakes.
        central.stopScan()
        status = "Connecting…"
        self.peripheral = p
        p.delegate = self
        central.connect(p, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        isConnected = true
        connectTimeoutWorkItem?.cancel()
        // Fresh connection → clean session state so the next step-on records.
        intentionalDisconnect = false
        sessionActive = false
        didFinalizeSession = false
        qardioMeasurementActive = false
        status = "Connected — discovering…"
        pendingComposition = nil
        // Recon: discover everything. Otherwise just the services we need.
        p.discoverServices(reconMode ? nil
            : [weightScaleService, bodyCompService, batteryService, deviceInfoService, qbService,
               userDataService, currentTimeService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        isConnected = false
        intentionalDisconnect = false
        // Keep trying on our own: resume scanning so the next advertisement
        // reconnects automatically rather than stranding the user on a manual tap.
        status = "Reconnecting… step on the scale"
        central.scanForPeripherals(withServices: nil, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        isConnected = false
        weightChar = nil
        batteryChar = nil
        qardioEngineeringChar = nil
        qardioMeasurementChar = nil
        qardioMeasurementActive = false
        bodyCompChar = nil
        userControlPointChar = nil
        updateBatteryStatus(nil)

        // A deliberate teardown (Retry) is owned by startConnect — don't fight it
        // by re-queuing a connect to the peripheral we just dropped.
        if intentionalDisconnect {
            intentionalDisconnect = false
            return
        }

        // Otherwise this was unexpected: the QardioBase powers down its radio
        // after a weigh-in and drops the link. Issue a pending reconnect with no
        // timeout — CoreBluetooth keeps it queued and reconnects the moment the
        // scale wakes on the next step-on, so repeated weigh-ins record without
        // tapping Retry.
        status = "Step on the scale to weigh again"
        central.connect(p, options: nil)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        servicesAwaitingCharacteristics = p.services?.count ?? 0
        for s in p.services ?? [] {
            log("service: \(s.uuid)")
            p.discoverCharacteristics(nil, for: s)
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for ch in s.characteristics ?? [] {
            log("  char: \(ch.uuid) [\(propString(ch.properties))]")

            switch ch.uuid {
            case weightMeasurement:
                weightChar = ch
                p.setNotifyValue(true, for: ch)
            case bodyCompMeasurement:
                // Supplements a weight reading; never marks the scale supported
                // on its own.
                bodyCompChar = ch
                p.setNotifyValue(true, for: ch)
            case userControlPoint:
                // The consent flow starts once its indications are on — see
                // didUpdateNotificationStateFor.
                userControlPointChar = ch
                p.setNotifyValue(true, for: ch)
            case currentTime:
                // A scale whose clock was never set (the Qardio app used to do
                // it) reads 1970; some refuse to measure until it is written.
                if ch.properties.contains(.write) {
                    p.writeValue(StandardScaleProfile.currentTime(Date()), for: ch, type: .withResponse)
                }
                if reconMode, ch.properties.contains(.read) { p.readValue(for: ch) }
            case qbControl:
                // State machine (00 idle, 03 measuring, 06 done) — drives the
                // result read. Required: without this notify the scale is silent.
                p.setNotifyValue(true, for: ch)
            case qbMeasure:
                qardioEngineeringChar = ch
                if ch.properties.contains(.notify) || ch.properties.contains(.indicate) {
                    p.setNotifyValue(true, for: ch)
                }
            case qbResult:
                qardioMeasurementChar = ch
            case batteryLevel:
                batteryChar = ch
                p.readValue(for: ch)
                if ch.properties.contains(.notify) { p.setNotifyValue(true, for: ch) }
            default:
                // Recon: subscribe to every streamable characteristic and read
                // every readable one, so stepping on the scale reveals the payload.
                if reconMode {
                    if ch.properties.contains(.notify) || ch.properties.contains(.indicate) {
                        p.setNotifyValue(true, for: ch)
                    }
                    if ch.properties.contains(.read) {
                        p.readValue(for: ch)
                    }
                }
            }
        }
        servicesAwaitingCharacteristics -= 1
        if weightChar != nil || qardioMeasurementChar != nil {
            // With a User Control Point the scale isn't ready until consent.
            if userControlPointChar == nil { status = "Connected — step on the scale" }
        } else if !reconMode, servicesAwaitingCharacteristics <= 0 {
            status = "Scale found, but no supported weight service."
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard error == nil, let data = ch.value else {
            status = "Read error"
            return
        }

        switch ch.uuid {
        case qbControl:
            log("<- control: \(hex(data)) [\(controlStateName(data))]")
            switch data.first {
            case 0x03:
                // New weigh-in starting — arm finalize and clear the guard.
                qardioMeasurementActive = true
                sessionActive = true
                didFinalizeSession = false
                status = "Measuring…"
            case 0x06:
                qardioMeasurementActive = false
                readQardioMeasurementJSON()
            case 0x00:
                qardioMeasurementActive = false
            default:
                break
            }
        case qbMeasure:
            log("<- measure: \(hex(data))")
            // The only frame we act on is the "result ready" marker, a slightly
            // earlier trigger than control=06 for reading the result JSON.
            if data.count >= 4, data[0] == 0x00, data[1] == 0x00, data[2] == 0x05, data[3] == 0x06 {
                readQardioMeasurementJSON()
            }
        default:
            log("<- \(ch.uuid): \(hex(data))")
        }

        switch ch.uuid {
        case weightMeasurement:
            parseWeight(data)
        case bodyCompMeasurement:
            parseBodyComposition(data)
        case userControlPoint:
            handleUserControlPoint(data, from: p)
        case qbResult:
            parseQardioMeasurementJSON(data)
        case batteryLevel:
            if !data.isEmpty {
                let level = Int(data[0])
                if (0...100).contains(level) {
                    DispatchQueue.main.async { self.updateBatteryStatus(level) }
                }
            }
        default:
            break
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor ch: CBCharacteristic, error: Error?) {
        if let error = error {
            status = "Notify error: \(error.localizedDescription)"
            return
        }
        if ch.uuid == userControlPoint, ch.isNotifying {
            beginUserConsent(on: p)
        }
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor ch: CBCharacteristic, error: Error?) {
        // Diagnostic only: a rejected write (e.g. the scale wants pairing) is what
        // a capture needs to show for a scale we can't test ourselves.
        if let error { log("write to \(ch.uuid) failed: \(error.localizedDescription)") }
    }
}
