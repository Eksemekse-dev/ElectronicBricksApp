import Foundation
import CoreBluetooth
import GameController
import Combine

enum BuWizzSpec {
    static let serviceUUID = CBUUID(string: "936E67B1-1999-B388-8144-FB74D1920550")
    static let appCharShort = CBUUID(string: "2901")
    static let appCharLong = CBUUID(string: "00002901-0000-1000-8000-00805F9B34FB")
    static let cmdSetMotor: UInt8 = 0x30
}

struct DiscoveredBuWizz: Identifiable {
    let id: UUID
    let peripheral: CBPeripheral
    let name: String
    let rssi: Int
}

struct SteerProfile: Codable, Equatable {
    var leftLimit: Double = -0.75
    var centerOffset: Double = 0.0
    var rightLimit: Double = 0.75
    var deadzone: Double = 0.08

    func computeSteeringByte(stickX: Double) -> Int8 {
        let x = max(-1.0, min(1.0, stickX))
        if abs(x) < deadzone {
            return toInt8(centerOffset)
        }

        let target: Double
        if x < 0 {
            let ratio = (-x - deadzone) / max(0.001, (1.0 - deadzone))
            target = centerOffset + min(1.0, ratio) * (leftLimit - centerOffset)
        } else {
            let ratio = (x - deadzone) / max(0.001, (1.0 - deadzone))
            target = centerOffset + min(1.0, ratio) * (rightLimit - centerOffset)
        }
        return toInt8(target)
    }

    private func toInt8(_ v: Double) -> Int8 {
        let clamped = max(-1.0, min(1.0, v))
        return Int8((clamped * 127.0).rounded())
    }
}

final class BuWizzController: NSObject, ObservableObject {
    @Published var connectionState = "Rozłączono"
    @Published var isConnected = false
    @Published var hasPad = false
    @Published var stickX: Double = 0.0
    @Published var stickY: Double = 0.0
    @Published var lastFrameHex = "--"
    @Published var discoveredDevices: [DiscoveredBuWizz] = []
    @Published var logs: [String] = []
    @Published var profile = SteerProfile() {
        didSet { saveProfile() }
    }

    @Published var steerChannel = 0
    @Published var driveChannel = 1
    @Published var brakeMask: UInt8 = 0x00
    @Published var lutMask: UInt8 = 0x00

    private let profileKey = "BuWizzPad.SteerProfile.v1"
    private var central: CBCentralManager!
    private var targetPeripheral: CBPeripheral?
    private var txCharacteristic: CBCharacteristic?
    private var loopTimer: Timer?
    private var seenPeripherals: [UUID: CBPeripheral] = [:]

    override init() {
        super.init()
        loadProfile()
        central = CBCentralManager(delegate: self, queue: .main)
        registerPadNotifications()
        startControlLoop()
    }

    deinit {
        loopTimer?.invalidate()
    }

    private func log(_ msg: String) {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        logs.insert("[\(stamp)] \(msg)", at: 0)
        if logs.count > 40 {
            logs.removeLast()
        }
    }

    func scanAndConnect() {
        guard central.state == .poweredOn else {
            connectionState = "Bluetooth niegotowy (stan: \(central.state.rawValue))"
            log("BT state: \(central.state.rawValue)")
            return
        }
        discoveredDevices.removeAll()
        seenPeripherals.removeAll()
        connectionState = "Skanuję BLE..."
        log("Start skanowania (wszystkie urządzenia)")
        central.stopScan()
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    func connect(to item: DiscoveredBuWizz) {
        central.stopScan()
        targetPeripheral = item.peripheral
        item.peripheral.delegate = self
        connectionState = "Łączę z \(item.name)..."
        log("Łączenie z \(item.name) (\(item.id.uuidString.prefix(6)))")
        central.connect(item.peripheral, options: nil)
    }

    func disconnect() {
        stopMotorsNow()
        central.stopScan()
        if let p = targetPeripheral {
            log("Rozłączanie z \(p.name ?? "BuWizz3")")
            central.cancelPeripheralConnection(p)
        }
    }

    func setLeftLimitFromPad() {
        profile.leftLimit = max(-1.0, min(0.0, stickX))
    }

    func setCenterFromPad() {
        profile.centerOffset = max(-1.0, min(1.0, stickX))
    }

    func setRightLimitFromPad() {
        profile.rightLimit = max(0.0, min(1.0, stickX))
    }

    func resetProfile() {
        profile = SteerProfile()
    }

    private func loadProfile() {
        guard let data = UserDefaults.standard.data(forKey: profileKey),
              let decoded = try? JSONDecoder().decode(SteerProfile.self, from: data) else { return }
        profile = decoded
    }

    private func saveProfile() {
        guard let encoded = try? JSONEncoder().encode(profile) else { return }
        UserDefaults.standard.set(encoded, forKey: profileKey)
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
            self?.stickX = 0
            self?.stickY = 0
            self?.stopMotorsNow()
            self?.log("Pad rozłączony")
        }
    }

    private func updatePadFlag() {
        hasPad = !GCController.controllers().isEmpty
    }

    private func pollPad() {
        guard let pad = GCController.controllers().first?.extendedGamepad else {
            stickX = 0
            stickY = 0
            return
        }
        stickX = Double(pad.leftThumbstick.xAxis.value)
        stickY = Double(pad.leftThumbstick.yAxis.value)
    }

    private func startControlLoop() {
        loopTimer = Timer.scheduledTimer(withTimeInterval: 0.025, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.pollPad()
            guard self.isConnected else { return }

            let steerByte = self.profile.computeSteeringByte(stickX: self.stickX)
            let driveByte = self.computeThrottleByte(stickY: self.stickY)
            self.transmitMotorPacket(steer: steerByte, drive: driveByte)
        }
    }

    private func computeThrottleByte(stickY: Double) -> Int8 {
        let y = max(-1.0, min(1.0, stickY))
        if abs(y) < profile.deadzone {
            return 0
        }
        return Int8((y * 127.0).rounded())
    }

    private func stopMotorsNow() {
        transmitMotorPacket(steer: 0, drive: 0)
    }

    private func transmitMotorPacket(steer: Int8, drive: Int8) {
        guard let peripheral = targetPeripheral,
              let char = txCharacteristic else { return }

        var chValues: [Int8] = Array(repeating: 0, count: 6)
        if (0..<6).contains(steerChannel) { chValues[steerChannel] = steer }
        if (0..<6).contains(driveChannel) { chValues[driveChannel] = drive }

        var packet: [UInt8] = [BuWizzSpec.cmdSetMotor]
        packet.append(contentsOf: chValues.map { UInt8(bitPattern: $0) })
        packet.append(brakeMask)
        packet.append(lutMask)

        let payload = Data(packet)
        lastFrameHex = payload.map { String(format: "%02X", $0) }.joined(separator: " ")

        let writeType: CBCharacteristicWriteType =
            char.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        peripheral.writeValue(payload, for: char, type: writeType)
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
        seenPeripherals[peripheral.identifier] = peripheral
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

        // Auto-łączenie, jeśli wygląda na BuWizz3 i jeszcze nie łączymy się z niczym
        if looksLikeBuWizz && targetPeripheral == nil && !isConnected {
            connect(to: entry)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectionState = "Połączono – szukam usług..."
        log("didConnect: \(peripheral.name ?? "BLE")")
        peripheral.discoverServices(nil)
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
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
        isConnected = false
        txCharacteristic = nil
        targetPeripheral = nil
        connectionState = "Rozłączono"
        log("didDisconnect: \(error?.localizedDescription ?? "zakończono")")
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
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
            let isAppChar = ch.uuid == BuWizzSpec.appCharShort || ch.uuid == BuWizzSpec.appCharLong
            let canWrite = ch.properties.contains(.write) || ch.properties.contains(.writeWithoutResponse)

            if isAppChar && canWrite {
                txCharacteristic = ch
                if ch.properties.contains(.notify) {
                    peripheral.setNotifyValue(true, for: ch)
                }
                isConnected = true
                connectionState = "Gotowy: \(peripheral.name ?? "BuWizz3")"
                log("Wybrano charakterystykę sterującą: \(ch.uuid.uuidString)")
            }
        }
    }
}
