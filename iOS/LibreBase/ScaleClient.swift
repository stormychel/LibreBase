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
    /// hex. Leave on for the first real-device run to capture the GATT table.
    @Published var reconMode = true
    @Published var reconLog: [String] = []

    /// Fires once per weigh-in when the scale stops sending updates.
    var onFinalReading: ((ScaleReading) -> Void)?

    // MARK: - BLE
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var weightChar: CBCharacteristic?
    private var batteryChar: CBCharacteristic?

    // Standard SIG services / characteristics
    private let weightScaleService  = CBUUID(string: "181D")
    private let weightMeasurement   = CBUUID(string: "2A9D")
    private let bodyCompService     = CBUUID(string: "181B")
    private let bodyCompMeasurement = CBUUID(string: "2A9C")
    private let batteryService      = CBUUID(string: "180F")
    private let batteryLevel        = CBUUID(string: "2A19")
    private let deviceInfoService   = CBUUID(string: "180A")

    // QardioBase B100 custom profile (discovered via recon)
    private let qbMeasure = CBUUID(string: "9F3F4E1B-37D7-4F95-B374-CF585D808BEB") // notify: measurement stream
    private let qbControl = CBUUID(string: "A78AF805-8F3F-4E8F-A964-318B768BC38C") // notify: state (00 idle, 03 measuring, 06 done)

    /// Raw ADC counts per kilogram, from the scale's own calibration table
    /// (char 1EC92A15 → {"50":"5945","100":"11888","150":"17836"} ≈ 118.9/kg).
    private let rawPerKg = 118.907

    /// Advertised-name hint used to recognize the scale during the scan.
    private let nameHint = "qardio"

    // Debounce: a weigh-in may stream several frames before stabilizing.
    private var completionWorkItem: DispatchWorkItem?
    private let completionDebounceSeconds: TimeInterval = 1.5
    private var sessionActive = false

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
        lastReading = nil
        completionWorkItem?.cancel()
        connectTimeoutWorkItem?.cancel()
        if reconMode { reconLog.removeAll() }

        status = "Searching for scale…"
        central.stopScan()
        // In recon mode scan for everything (custom scales advertise vendor UUIDs);
        // otherwise filter to the standard Weight Scale service.
        central.scanForPeripherals(withServices: reconMode ? nil : [weightScaleService],
                                   options: nil)

        let work = DispatchWorkItem { [weak self] in
            guard let self = self, !self.isConnected else { return }
            self.central.stopScan()
            self.status = "No scale found. Step on the scale to wake it, then retry."
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
        status = "Connected — reading saved"
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

    /// Scans a measurement frame for any 16-bit window that, divided by the
    /// calibration slope, lands in human-weight range. The frame/offset that
    /// matches the user's real weight pins the weight field. (Decoding aid only.)
    private func weightCandidates(_ data: Data) -> String {
        let b = [UInt8](data)
        guard b.count >= 2 else { return "" }
        var hits: [String] = []
        for i in 0..<(b.count - 1) {
            let le = Double(UInt16(b[i]) | (UInt16(b[i + 1]) << 8)) / rawPerKg
            let be = Double(UInt16(b[i + 1]) | (UInt16(b[i]) << 8)) / rawPerKg
            if (20...250).contains(le) { hits.append(String(format: "LE@%d=%.1f", i, le)) }
            if (20...250).contains(be) { hits.append(String(format: "BE@%d=%.1f", i, be)) }
        }
        return hits.isEmpty ? "" : "  ?kg{ \(hits.joined(separator: " ")) }"
    }

    private func controlStateName(_ data: Data) -> String {
        guard let v = data.first else { return "?" }
        switch v {
        case 0x00: return "idle"
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

        // Accept by name hint or by advertised standard service.
        guard advName.localizedCaseInsensitiveContains(nameHint) || advertisesWeightScale || !reconMode else {
            return
        }

        central.stopScan()
        connectTimeoutWorkItem?.cancel()
        status = "Connecting…"
        self.peripheral = p
        p.delegate = self
        central.connect(p, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        isConnected = true
        status = "Connected — discovering…"
        // Recon: discover everything. Otherwise just the services we need.
        p.discoverServices(reconMode ? nil
            : [weightScaleService, bodyCompService, batteryService, deviceInfoService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        isConnected = false
        status = "Failed to connect"
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        isConnected = false
        status = "Disconnected"
        weightChar = nil
        batteryChar = nil
        updateBatteryStatus(nil)
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
            case weightMeasurement, bodyCompMeasurement:
                weightChar = ch
                p.setNotifyValue(true, for: ch)
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
        if weightChar != nil {
            status = "Connected — step on the scale"
        } else if !reconMode {
            status = "Scale found, but no standard weight service. Enable recon."
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
        case qbMeasure:
            log("<- measure: \(hex(data))\(weightCandidates(data))")
        default:
            log("<- \(ch.uuid): \(hex(data))")
        }

        switch ch.uuid {
        case weightMeasurement:
            parseWeight(data)
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
