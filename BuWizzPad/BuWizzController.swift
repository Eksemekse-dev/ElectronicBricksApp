import Foundation
import CoreBluetooth
import GameController
import Combine

enum BuWizzSpec {
    static let serviceUUID = CBUUID(string: "936E67B1-1999-B388-8144-FB74D1920550")
    static let appCharUUID = CBUUID(string: "00002901-0000-1000-8000-00805F9B34FB")
    static let cmdSetMotor: UInt8 = 0x30
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
    @Published var profile = SteerProfile() {
        didSet { saveProfile() }
    }

    // Domyślnie kanał 0 = skręt, kanał 1 = gaz (do zmiany w razie potrzeby)
    @Published var steerChannel = 0
    @Published var driveChannel = 1
    @Published var brakeMask: UInt8 = 0x00
    @Published var lutMask: UInt8 = 0x00

    private let profileKey = "BuWizzPad.SteerProfile.v1"
    private var central: CBCentralManager!
    private var targetPeripheral: CBPeripheral?
    private var txCharacteristic: CBCharacteristic?
    private var loopTimer: Timer?

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

    func scanAndConnect() {
        guard central.state == .poweredOn else {
            connectionState = "Włącz Bluetooth na iPhonie"
            return
        }
        connectionState = "Szukam BuWizz3..."
        central.scanForPeripherals(withServices: [BuWizzSpec.serviceUUID], options: nil)
    }

    func disconnect() {
        stopMotorsNow()
        if let p = targetPeripheral {
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
            char.properties.contains(.withoutResponse) ? .withoutResponse : .withResponse
        peripheral.writeValue(payload, for: char, type: writeType)
    }
}

extension BuWizzController: CBCentralManagerDelegate, CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            connectionState = "Gotowy (BT włączony)"
        case .poweredOff:
            connectionState = "Bluetooth wyłączony"
            isConnected = false
        default:
            connectionState = "Status BT: \(central.state.rawValue)"
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        central.stopScan()
        targetPeripheral = peripheral
        peripheral.delegate = self
        connectionState = "Łączę z \(peripheral.name ?? "BuWizz3")..."
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectionState = "Pobieram usługi..."
        peripheral.discoverServices([BuWizzSpec.serviceUUID])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        isConnected = false
        connectionState = "Błąd połączenia"
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        isConnected = false
        txCharacteristic = nil
        connectionState = "Rozłączono"
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil,
              let svc = peripheral.services?.first(where: { $0.uuid == BuWizzSpec.serviceUUID }) else {
            connectionState = "Brak usługi BuWizz3"
            return
        }
        peripheral.discoverCharacteristics([BuWizzSpec.appCharUUID], for: svc)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard error == nil,
              let ch = service.characteristics?.first(where: { $0.uuid == BuWizzSpec.appCharUUID }) else {
            connectionState = "Brak charakterystyki 2901"
            return
        }
        txCharacteristic = ch
        if ch.properties.contains(.notify) {
            peripheral.setNotifyValue(true, for: ch)
        }
        isConnected = true
        connectionState = "Połączono z \(peripheral.name ?? "BuWizz3")"
    }
}
