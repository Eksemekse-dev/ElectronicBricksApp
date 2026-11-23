import Foundation
import CoreBluetooth
import GameController
import Combine

enum BuWizzSpec {
    static let serviceUUID = CBUUID(string: "500592D1-74FB-4481-88B3-9919B1676E93")
    static let appCharPrefix = "50052901"
    static let appCharShort = CBUUID(string: "2901")
    static let appCharLong = CBUUID(string: "00002901-0000-1000-8000-00805F9B34FB")
    static let cmdSetMotor: UInt8 = 0x30
}

enum PadInputSource: String, CaseIterable, Identifiable, Codable {
    case leftStickX = "Lewa gałka X (lewo/prawo)"
    case leftStickY = "Lewa gałka Y (góra/dół)"
    case rightStickX = "Prawa gałka X (lewo/prawo)"
    case rightStickY = "Prawa gałka Y (góra/dół)"
    case buttonsAB = "Przyciski B (-) / A (+)"
    case buttonsXY = "Przyciski X (-) / Y (+)"
    case triggersLR = "Spust L2 (-) / R2 (+)"
    case bumpersLR = "Bark L1 (-) / R1 (+)"
    case none = "Brak / wyłączone"

    var id: String { rawValue }
}

struct PortAssignment: Identifiable, Codable, Equatable {
    var id: Int { portIndex } // 0...5 -> Porty 1...6
    let portIndex: Int
    var source: PadInputSource
    var powerLimitPercent: Double // 0...100%
    var invert: Bool
    var isServo: Bool

    var title: String { "Port \(portIndex + 1)" }
}

struct SteerProfile: Codable, Equatable {
    var leftLimit: Double = -0.75
    var centerOffset: Double = 0.0
    var rightLimit: Double = 0.75
    var deadzone: Double = 0.08

    func computeSteeringByte(stickValue: Double, maxPowerRatio: Double) -> Int8 {
        let v = max(-1.0, min(1.0, stickValue))
        let effectiveMax = max(0.0, min(1.0, maxPowerRatio))

        if abs(v) < deadzone {
            return toInt8(centerOffset * effectiveMax)
        }

        let target: Double
        if v < 0 {
            let ratio = min(1.0, (-v - deadzone) / max(0.001, (1.0 - deadzone)))
            target = centerOffset + ratio * (leftLimit - centerOffset)
        } else {
            let ratio = min(1.0, (v - deadzone) / max(0.001, (1.0 - deadzone)))
            target = centerOffset + ratio * (rightLimit - centerOffset)
        }

        return toInt8(target * effectiveMax)
    }

    private func toInt8(_ v: Double) -> Int8 {
        let clamped = max(-1.0, min(1.0, v))
        return Int8((clamped * 127.0).rounded())
    }
}

struct DiscoveredBuWizz: Identifiable {
    let id: UUID
    let peripheral: CBPeripheral
    let name: String
    let rssi: Int
}

final class BuWizzController: NSObject, ObservableObject {
    @Published var connectionState = "Rozłączono"
    @Published var isConnected = false
    @Published var hasPad = false

    @Published var leftStickX: Double = 0.0
    @Published var leftStickY: Double = 0.0
    @Published var rightStickX: Double = 0.0
    @Published var rightStickY: Double = 0.0

    @Published var lastFrameHex = "--"
    @Published var discoveredDevices: [DiscoveredBuWizz] = []
    @Published var logs: [String] = []

    @Published var servoPortIndex: Int = 0 { // domyślnie Port 1 (indeks 0)
        didSet {
            syncServoPortFlags()
            saveConfig()
        }
    }

    @Published var autoCalibrating = false
    @Published var calibrationStatus = "Gotowy"

    @Published var profile = SteerProfile() {
        didSet { saveConfig() }
    }

    @Published var ports: [PortAssignment] = [
        PortAssignment(portIndex: 0, source: .leftStickX, powerLimitPercent: 80, invert: false, isServo: true),
        PortAssignment(portIndex: 1, source: .leftStickY, powerLimitPercent: 100, invert: false, isServo: false),
        PortAssignment(portIndex: 2, source: .none, powerLimitPercent: 100, invert: false, isServo: false),
        PortAssignment(portIndex: 3, source: .none, powerLimitPercent: 100, invert: false, isServo: false),
        PortAssignment(portIndex: 4, source: .none, powerLimitPercent: 100, invert: false, isServo: false),
        PortAssignment(portIndex: 5, source: .none, powerLimitPercent: 100, invert: false, isServo: false)
    ] {
        didSet { saveConfig() }
    }

    @Published var brakeMask: UInt8 = 0x00
    @Published var lutMask: UInt8 = 0x00

    private struct SavedConfig: Codable {
        var servoPortIndex: Int
        var profile: SteerProfile
        var ports: [PortAssignment]
    }

    private let configKey = "BuWizzPad.Config.v2"
    private var central: CBCentralManager!
    private var targetPeripheral: CBPeripheral?
    private var txCharacteristic: CBCharacteristic?
    private var loopTimer: Timer?
    private var serviceTimeoutTimer: Timer?
    private var calibrationTask: Task<Void, Never>?
    private var overridePortValues: [Int: Int8] = [:]

    override init() {
        super.init()
        loadConfig()
        central = CBCentralManager(delegate: self, queue: .main)
        registerPadNotifications()
        startControlLoop()
    }

    deinit {
        loopTimer?.invalidate()
        serviceTimeoutTimer?.invalidate()
        calibrationTask?.cancel()
    }

    private func log(_ msg: String) {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        logs.insert("[\(stamp)] \(msg)", at: 0)
        if logs.count > 60 {
            logs.removeLast()
        }
    }

    private func syncServoPortFlags() {
        for i in ports.indices {
            ports[i].isServo = (ports[i].portIndex == servoPortIndex)
        }
    }

    func setPortPowerLimit(portIndex: Int, percent: Double) {
        guard ports.indices.contains(portIndex) else { return }
        ports[portIndex].powerLimitPercent = max(0, min(100, percent))
    }

    func setPortSource(portIndex: Int, source: PadInputSource) {
        guard ports.indices.contains(portIndex) else { return }
        ports[portIndex].source = source
    }

    func setPortInvert(portIndex: Int, invert: Bool) {
        guard ports.indices.contains(portIndex) else { return }
        ports[portIndex].invert = invert
    }

    // MARK: - Kalibracja ręczna i automatyczna serwa

    func setLeftLimitFromCurrentServoStick() {
        let val = currentServoSourceRawValue()
        profile.leftLimit = max(-1.0, min(0.0, val))
        calibrationStatus = String(format: "Zapisano Lewo: %.2f", profile.leftLimit)
    }

    func setCenterFromCurrentServoStick() {
        let val = currentServoSourceRawValue()
        profile.centerOffset = max(-1.0, min(1.0, val))
        calibrationStatus = String(format: "Zapisano Środek: %.2f", profile.centerOffset)
    }

    func setRightLimitFromCurrentServoStick() {
        let val = currentServoSourceRawValue()
        profile.rightLimit = max(0.0, min(1.0, val))
        calibrationStatus = String(format: "Zapisano Prawo: %.2f", profile.rightLimit)
    }

    func resetProfile() {
        profile = SteerProfile()
        calibrationStatus = "Przywrócono domyślny profil"
    }

    func startAutoServoCalibration() {
        guard !autoCalibrating else { return }
        calibrationTask?.cancel()
        autoCalibrating = true
        calibrationStatus = "Auto-kalibracja: ruch w lewo..."
        log("Start auto-kalibracji serwa na Porcie \(servoPortIndex + 1)")

        let targetPort = servoPortIndex
        let servoLimitRatio = max(0.15, min(0.85, (ports.indices.contains(targetPort) ? ports[targetPort].powerLimitPercent : 60.0) / 100.0))

        calibrationTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            defer {
                self.overridePortValues.removeValue(forKey: targetPort)
                self.autoCalibrating = false
            }

            // 1. Skanowanie w lewo (od 0.0 do -servoLimitRatio w krokach)
            var foundLeft: Double = -servoLimitRatio
            let steps = 16
            for step in 1...steps {
                if Task.isCancelled { return }
                let frac = Double(step) / Double(steps)
                let cmdVal = -frac * servoLimitRatio
                self.overridePortValues[targetPort] = self.doubleToInt8(cmdVal)
                self.calibrationStatus = String(format: "Lewo: %.0f%%", frac * 100)
                try? await Task.sleep(nanoseconds: 65_000_000)
            }
            foundLeft = -servoLimitRatio
            // Chwila przytrzymania na oporze w lewo
            try? await Task.sleep(nanoseconds: 250_000_000)

            // 2. Powrót do środka (0)
            self.overridePortValues[targetPort] = 0
            self.calibrationStatus = "Powrót na środek..."
            try? await Task.sleep(nanoseconds: 350_000_000)

            // 3. Skanowanie w prawo (od 0.0 do +servoLimitRatio w krokach)
            var foundRight: Double = servoLimitRatio
            for step in 1...steps {
                if Task.isCancelled { return }
                let frac = Double(step) / Double(steps)
                let cmdVal = frac * servoLimitRatio
                self.overridePortValues[targetPort] = self.doubleToInt8(cmdVal)
                self.calibrationStatus = String(format: "Prawo: %.0f%%", frac * 100)
                try? await Task.sleep(nanoseconds: 65_000_000)
            }
            foundRight = servoLimitRatio
            // Chwila przytrzymania na oporze w prawo
            try? await Task.sleep(nanoseconds: 250_000_000)

            // 4. Powrót na środek i zapis wyników
            self.overridePortValues[targetPort] = 0
            self.profile.leftLimit = max(-1.0, min(0.0, foundLeft))
            self.profile.centerOffset = 0.0
            self.profile.rightLimit = max(0.0, min(1.0, foundRight))
            self.calibrationStatus = String(
                format: "Gotowe! L: %.2f | C: %.2f | P: %.2f",
                self.profile.leftLimit,
                self.profile.centerOffset,
                self.profile.rightLimit
            )
            self.log("Zakończono auto-kalibrację serwa: L=\(self.profile.leftLimit), R=\(self.profile.rightLimit)")
        }
    }

    func cancelAutoServoCalibration() {
        calibrationTask?.cancel()
        overridePortValues.removeValue(forKey: servoPortIndex)
        autoCalibrating = false
        calibrationStatus = "Anulowano kalibrację"
    }

    private func currentServoSourceRawValue() -> Double {
        if ports.indices.contains(servoPortIndex) {
            return readSourceValue(ports[servoPortIndex].source)
        }
        return leftStickX
    }

    // MARK: - BLE i Pad

    func scanAndConnect() {
        guard central.state == .poweredOn else {
            connectionState = "Bluetooth niegotowy (stan: \(central.state.rawValue))"
            log("BT state: \(central.state.rawValue)")
            return
        }
        serviceTimeoutTimer?.invalidate()
        isConnected = false
        txCharacteristic = nil
        targetPeripheral = nil
        discoveredDevices.removeAll()
        connectionState = "Skanuję BLE..."
        log("Start skanowania BLE")
        central.stopScan()
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    func retryDiscoverServices() {
        guard let p = targetPeripheral, p.state == .connected else {
            log("Brak aktywnego połączenia")
            return
        }
        startServiceDiscovery(for: p)
    }

    private func startServiceDiscovery(for peripheral: CBPeripheral) {
        serviceTimeoutTimer?.invalidate()
        connectionState = "Połączono – szukam usług..."
        log("discoverServices(nil) dla \(peripheral.name ?? "BLE")")
        peripheral.delegate = self
        peripheral.discoverServices(nil)

        serviceTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            guard let self = self, !self.isConnected else { return }
            self.connectionState = "Timeout szukania usług"
            self.log("Brak odpowiedzi discoverServices po 3s")
        }
    }

    func connect(to item: DiscoveredBuWizz) {
        central.stopScan()
        targetPeripheral = item.peripheral
        item.peripheral.delegate = self
        connectionState = "Łączę z \(item.name)..."
        log("Łączenie z \(item.name)")
        central.connect(item.peripheral, options: nil)
    }

    func disconnect() {
        cancelAutoServoCalibration()
        serviceTimeoutTimer?.invalidate()
        stopAllPortsNow()
        central.stopScan()
        if let p = targetPeripheral {
            log("Rozłączanie z \(p.name ?? "BuWizz3")")
            central.cancelPeripheralConnection(p)
        }
    }

    private func loadConfig() {
        guard let data = UserDefaults.standard.data(forKey: configKey),
              let decoded = try? JSONDecoder().decode(SavedConfig.self, from: data) else {
            syncServoPortFlags()
            return
        }
        servoPortIndex = max(0, min(5, decoded.servoPortIndex))
        profile = decoded.profile
        if decoded.ports.count == 6 {
            ports = decoded.ports
        }
        syncServoPortFlags()
    }

    private func saveConfig() {
        let cfg = SavedConfig(servoPortIndex: servoPortIndex, profile: profile, ports: ports)
        guard let encoded = try? JSONEncoder().encode(cfg) else { return }
        UserDefaults.standard.set(encoded, forKey: configKey)
    }

    private func registerPadNotifications() {
        updatePadFlag()
        NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updatePadFlag()
            self?.log("Pad podłączony")
        }
        NotificationCenter.default.addObserver(
            forName: .GCControllerDidDisconnect,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updatePadFlag()
            self?.resetSticksToZero()
            self?.stopAllPortsNow()
            self?.log("Pad rozłączony")
        }
    }

    private func resetSticksToZero() {
        leftStickX = 0
        leftStickY = 0
        rightStickX = 0
        rightStickY = 0
    }

    private func updatePadFlag() {
        hasPad = !GCController.controllers().isEmpty
    }

    private func pollPad() {
        guard let pad = GCController.controllers().first?.extendedGamepad else {
            resetSticksToZero()
            return
        }
        leftStickX = Double(pad.leftThumbstick.xAxis.value)
        leftStickY = Double(pad.leftThumbstick.yAxis.value)
        rightStickX = Double(pad.rightThumbstick.xAxis.value)
        rightStickY = Double(pad.rightThumbstick.yAxis.value)
    }

    private func readSourceValue(_ source: PadInputSource) -> Double {
        guard let pad = GCController.controllers().first?.extendedGamepad else {
            return 0.0
        }
        switch source {
        case .leftStickX:
            return Double(pad.leftThumbstick.xAxis.value)
        case .leftStickY:
            return Double(pad.leftThumbstick.yAxis.value)
        case .rightStickX:
            return Double(pad.rightThumbstick.xAxis.value)
        case .rightStickY:
            return Double(pad.rightThumbstick.yAxis.value)
        case .buttonsAB:
            let pos = Double(pad.buttonA.value)
            let neg = Double(pad.buttonB.value)
            return max(-1.0, min(1.0, pos - neg))
        case .buttonsXY:
            let pos = Double(pad.buttonY.value)
            let neg = Double(pad.buttonX.value)
            return max(-1.0, min(1.0, pos - neg))
        case .triggersLR:
            let pos = Double(pad.rightTrigger.value)
            let neg = Double(pad.leftTrigger.value)
            return max(-1.0, min(1.0, pos - neg))
        case .bumpersLR:
            let pos = pad.rightShoulder.isPressed ? 1.0 : 0.0
            let neg = pad.leftShoulder.isPressed ? 1.0 : 0.0
            return max(-1.0, min(1.0, pos - neg))
        case .none:
            return 0.0
        }
    }

    private func startControlLoop() {
        loopTimer = Timer.scheduledTimer(withTimeInterval: 0.025, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.pollPad()
            guard self.isConnected else { return }
            self.transmitAllPorts()
        }
    }

    private func stopAllPortsNow() {
        overridePortValues.removeAll()
        sendRawChannelBytes(Array(repeating: 0, count: 6))
    }

    private func transmitAllPorts() {
        var channelBytes: [Int8] = Array(repeating: 0, count: 6)

        for port in ports where (0..<6).contains(port.portIndex) {
            if let forced = overridePortValues[port.portIndex] {
                channelBytes[port.portIndex] = forced
                continue
            }

            var raw = readSourceValue(port.source)
            if port.invert {
                raw = -raw
            }

            let powerRatio = max(0.0, min(1.0, port.powerLimitPercent / 100.0))

            if port.portIndex == servoPortIndex || port.isServo {
                channelBytes[port.portIndex] = profile.computeSteeringByte(
                    stickValue: raw,
                    maxPowerRatio: powerRatio
                )
            } else {
                channelBytes[port.portIndex] = computeLinearMotorByte(
                    rawValue: raw,
                    powerRatio: powerRatio
                )
            }
        }

        sendRawChannelBytes(channelBytes)
    }

    private func computeLinearMotorByte(rawValue: Double, powerRatio: Double) -> Int8 {
        let v = max(-1.0, min(1.0, rawValue))
        if abs(v) < profile.deadzone {
            return 0
        }
        let scaled = v * powerRatio
        return doubleToInt8(scaled)
    }

    private func doubleToInt8(_ value: Double) -> Int8 {
        let clamped = max(-1.0, min(1.0, value))
        return Int8((clamped * 127.0).rounded())
    }

    private func sendRawChannelBytes(_ chValues: [Int8]) {
        guard let peripheral = targetPeripheral,
              let char = txCharacteristic else { return }

        var packet: [UInt8] = [BuWizzSpec.cmdSetMotor]
        packet.append(contentsOf: chValues.prefix(6).map { UInt8(bitPattern: $0) })
        packet.append(brakeMask)
        packet.append(lutMask)

        let payload = Data(packet)
        lastFrameHex = payload.map { String(format: "%02X", $0) }.joined(separator: " ")

        let writeType: CBCharacteristicWriteType =
            char.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        peripheral.writeValue(payload, for: char, type: writeType)
    }

    private func isApplicationCharacteristic(_ uuid: CBUUID) -> Bool {
        let upper = uuid.uuidString.uppercased()
        return upper.hasPrefix(BuWizzSpec.appCharPrefix)
            || uuid == BuWizzSpec.appCharShort
            || uuid == BuWizzSpec.appCharLong
    }
}

extension BuWizzController: CBCentralManagerDelegate, CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            connectionState = "Bluetooth gotowy"
            log("BT poweredOn")
        case .poweredOff:
            connectionState = "Bluetooth wyłączony"
            isConnected = false
            log("BT poweredOff")
        case .unauthorized:
            connectionState = "Brak uprawnień Bluetooth"
            log("BT unauthorized")
        default:
            connectionState = "Status BT: \(central.state.rawValue)"
            log("BT status: \(central.state.rawValue)")
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = advName ?? peripheral.name ?? "Nieznane BLE"
        let rssiInt = RSSI.intValue

        let advUUIDs = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let looksLikeBuWizz = name.localizedCaseInsensitiveContains("buwizz")
            || advUUIDs.contains(BuWizzSpec.serviceUUID)

        let entry = DiscoveredBuWizz(
            id: peripheral.identifier,
            peripheral: peripheral,
            name: name,
            rssi: rssiInt
        )

        if let idx = discoveredDevices.firstIndex(where: { $0.id == entry.id }) {
            discoveredDevices[idx] = entry
        } else {
            discoveredDevices.append(entry)
            log("Wykryto: \(name) (\(rssiInt) dBm)")
        }

        if looksLikeBuWizz && targetPeripheral == nil && !isConnected {
            connect(to: entry)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log("didConnect: \(peripheral.name ?? "BLE")")
        startServiceDiscovery(for: peripheral)
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        serviceTimeoutTimer?.invalidate()
        isConnected = false
        targetPeripheral = nil
        connectionState = "Błąd połączenia"
        log("didFailToConnect: \(error?.localizedDescription ?? "brak")")
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        cancelAutoServoCalibration()
        serviceTimeoutTimer?.invalidate()
        isConnected = false
        txCharacteristic = nil
        targetPeripheral = nil
        connectionState = "Rozłączono"
        log("didDisconnect: \(error?.localizedDescription ?? "zakończono")")
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        serviceTimeoutTimer?.invalidate()
        if let error = error {
            connectionState = "Błąd usług BLE"
            log("Błąd usług: \(error.localizedDescription)")
            return
        }
        guard let services = peripheral.services, !services.isEmpty else {
            connectionState = "Brak usług BLE"
            log("Brak usług")
            return
        }

        log("Znaleziono usług: \(services.count)")
        for svc in services {
            log("Usługa: \(svc.uuid.uuidString)")
            peripheral.discoverCharacteristics(nil, for: svc)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        if let error = error {
            log("Błąd char (\(service.uuid.uuidString)): \(error.localizedDescription)")
            return
        }
        guard let chars = service.characteristics else { return }

        for ch in chars {
            log("Char \(ch.uuid.uuidString) props=\(ch.properties.rawValue)")
            let canWrite = ch.properties.contains(.write) || ch.properties.contains(.writeWithoutResponse)

            if isApplicationCharacteristic(ch.uuid) && canWrite {
                txCharacteristic = ch
                if ch.properties.contains(.notify) {
                    peripheral.setNotifyValue(true, for: ch)
                }
                isConnected = true
                connectionState = "Gotowy: \(peripheral.name ?? "BuWizz3")"
                log("Wybrano char: \(ch.uuid.uuidString)")
            }
        }
    }
}
