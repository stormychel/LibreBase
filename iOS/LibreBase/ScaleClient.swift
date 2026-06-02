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
    let bmi: Double?
    let timestamp: Date
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
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var weightChar: CBCharacteristic?
    private var batteryChar: CBCharacteristic?
    private var qardioEngineeringChar: CBCharacteristic?
    private var qardioMeasurementChar: CBCharacteristic?

    // Standard SIG services / characteristics
    private let weightScaleService  = CBUUID(string: "181D")
    private let weightMeasurement   = CBUUID(string: "2A9D")
    private let bodyCompService     = CBUUID(string: "181B")
    private let bodyCompMeasurement = CBUUID(string: "2A9C")
    private let batteryService      = CBUUID(string: "180F")
    private let batteryLevel        = CBUUID(string: "2A19")
    private let deviceInfoService   = CBUUID(string: "180A")

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
    private let completionDebounceSeconds: TimeInterval = 1.5
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

    // MARK: - Lifecycle
    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: - Public API

    /// Begin scanning/connecting to the scale. Call on app start or on Retry.
    func startConnect(timeout: TimeInterval = 30) {
        guard central.state == .poweredOn else {
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
            if self.peripheral == nil {
                // Never even discovered the scale.
                self.central.stopScan()
                self.status = "No scale found. Step on the scale to wake it, then retry."
            } else {
                // Discovered, but the connect hasn't completed — the scale likely
                // went back to sleep. The pending connect stays queued and will
                // complete on its own when it wakes on the next step-on.
                self.status = "Step on the scale to wake it…"
            }
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

    /// Physiologically plausible adult weight range, also rejects SFLOAT/NaN junk.
    private func isValidWeight(_ kg: Double) -> Bool {
        kg.isFinite && kg >= 2 && kg <= 400
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
        status = "Weigh-in complete"
        onFinalReading?(reading)
    }

    // MARK: - Parser (standard Weight Measurement 0x2A9D)

    private func parseWeight(_ data: Data) {
        let b = [UInt8](data)
        guard b.count >= 3 else { return }

        let flags = b[0]
        let isImperial = (flags & 0x01) != 0
        let timestampPresent = (flags & 0x02) != 0
        let userIDPresent = (flags & 0x04) != 0
        let bmiHeightPresent = (flags & 0x08) != 0

        let rawWeight = UInt16(b[1]) | (UInt16(b[2]) << 8)
        // SI: 0.005 kg/unit. Imperial: 0.01 lb/unit → convert to kg.
        let weightKg = isImperial
            ? Double(rawWeight) * 0.01 * 0.45359237
            : Double(rawWeight) * 0.005

        var idx = 3
        if timestampPresent { idx += 7 }
        if userIDPresent { idx += 1 }

        var bmi: Double?
        if bmiHeightPresent, b.count >= idx + 2 {
            let rawBMI = UInt16(b[idx]) | (UInt16(b[idx + 1]) << 8)
            bmi = Double(rawBMI) * 0.1
        }

        let reading = ScaleReading(weightKg: weightKg, bmi: bmi, timestamp: Date())
        DispatchQueue.main.async {
            self.lastReading = reading
            self.sessionActive = true
            self.status = "Measuring…"
            self.scheduleFinalize()
        }
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
    /// plain UTF-8 JSON, e.g. {"weight":"76.0","bmi":"19.3",...}.
    private func parseQardioMeasurementJSON(_ data: Data) {
        // The result is read on two triggers per weigh-in; only save it once.
        guard !didFinalizeSession else { return }

        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let weightText = json["weight"] as? String,
            let weightKg = Double(weightText),
            isValidWeight(weightKg)
        else {
            if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                log("qardio measurement JSON unparsed: \(text)")
            }
            return
        }

        let bmi = (json["bmi"] as? String).flatMap(Double.init)
        let reading = ScaleReading(weightKg: weightKg, bmi: bmi, timestamp: Date())

        log(String(format: "qardio measurement JSON decoded: %.1f kg%@", weightKg, bmi.map { String(format: ", BMI %.1f", $0) } ?? ""))

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
        // Recon: discover everything. Otherwise just the services we need.
        p.discoverServices(reconMode ? nil
            : [weightScaleService, bodyCompService, batteryService, deviceInfoService, qbService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        isConnected = false
        intentionalDisconnect = false
        status = "Couldn't connect — step on the scale and tap Retry"
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        isConnected = false
        weightChar = nil
        batteryChar = nil
        qardioEngineeringChar = nil
        qardioMeasurementChar = nil
        qardioMeasurementActive = false
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
                // Only the standard Weight Measurement (0x2A9D) is parsed. Body
                // Composition (0x2A9C) has a different layout and no parser yet,
                // so we don't subscribe to it — subscribing would mark the scale
                // "supported" and then never produce a reading.
                weightChar = ch
                p.setNotifyValue(true, for: ch)
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
        if weightChar != nil || qardioMeasurementChar != nil {
            status = "Connected — step on the scale"
        } else if !reconMode {
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
        }
    }
}
