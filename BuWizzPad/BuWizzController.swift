import Foundation
import CoreBluetooth
import GameController
import Combine

enum BuWizzSpec {
    static let serviceUUID = CBUUID(string: "500592D1-74FB-4481-88B3-9919B1676E93")
    static let appCharPrefix = "50052901"
    static let appCharShort = CBUUID(string: "2901")
    static let appCharLong = CBUUID(string: "00002901-0000-1000-8000-00805F9B34FB")
    static let cmdSetMotorExtended: UInt8 = 0x31
    static let cmdSetMotorRamp: UInt8 = 0x33
    static let cmdSetPIDParams: UInt8 = 0x53
    static let cmdSetPUPortFunction: UInt8 = 0x50
    static let cmdSetServoRef: UInt8 = 0x52
    static let puFuncPositionServo: UInt8 = 0x15
    static let puFuncSimplePWM: UInt8 = 0x10
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
    case buttonA = "Przycisk A (krzyżyk / toggle)"
    case buttonB = "Przycisk B (kółko / toggle)"
    case buttonX = "Przycisk X (kwadrat / toggle)"
    case buttonY = "Przycisk Y (trójkąt / toggle)"
    case none = "Brak / wyłączone"

    var id: String { rawValue }
}

enum PortOperatingMode: String, CaseIterable, Identifiable, Codable {
    case normal = "Normalny"
    case indicator = "Kierunkowskazy (toggle)"
    case frontLight = "Światło przednie (toggle)"

    var id: String { rawValue }
}

struct PortAssignment: Identifiable, Codable, Equatable {
    var id: Int { portIndex }
    let portIndex: Int
    var source: PadInputSource
    var mode: PortOperatingMode
    var powerLimitPercent: Double
    var invert: Bool
    var isServo: Bool

    var title: String { "Port \(portIndex + 1)" }
}

extension PortAssignment {
    static let defaults: [PortAssignment] = [
        PortAssignment(portIndex: 0, source: .leftStickX, mode: .normal, powerLimitPercent: 80, invert: false, isServo: true),
        PortAssignment(portIndex: 1, source: .leftStickY, mode: .normal, powerLimitPercent: 100, invert: false, isServo: false),
        PortAssignment(portIndex: 2, source: .buttonX, mode: .frontLight, powerLimitPercent: 100, invert: false, isServo: false),
        PortAssignment(portIndex: 3, source: .buttonY, mode: .indicator, powerLimitPercent: 100, invert: false, isServo: false),
        PortAssignment(portIndex: 4, source: .none, mode: .normal, powerLimitPercent: 100, invert: false, isServo: false),
        PortAssignment(portIndex: 5, source: .none, mode: .normal, powerLimitPercent: 100, invert: false, isServo: false)
    ]
}

struct DiscoveredBuWizz: Identifiable {
    let id: UUID
    let peripheral: CBPeripheral
    let name: String
    let rssi: Int
    var kind: HubKind = .buwizz
    var legoSystemType: UInt8? = nil
}

/// Zarządza Bluetoothem, padem i wszystkimi połączonymi hubami.
final class BuWizzController: NSObject, ObservableObject {
    @Published var bluetoothState = "Bluetooth..."
    @Published var isScanning = false
    @Published var sessions: [HubSession] = []
    @Published var hasPad = false
    @Published var padLightSupported = false

    @Published var leftStickX: Double = 0.0
    @Published var leftStickY: Double = 0.0
    @Published var rightStickX: Double = 0.0
    @Published var rightStickY: Double = 0.0

    @Published var discoveredDevices: [DiscoveredBuWizz] = []
    @Published var logs: [String] = []

    private var central: CBCentralManager!
    private var loopTimer: Timer?
    private var scanTimer: Timer?
    private var pulsePhase: Double = 0.0
    private var blinkCounter: Int = 0

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
        registerPadNotifications()
        startControlLoop()
    }

    deinit {
        loopTimer?.invalidate()
        scanTimer?.invalidate()
    }

    private func log(_ msg: String) {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        logs.insert("[\(stamp)] \(msg)", at: 0)
        if logs.count > 60 {
            logs.removeLast()
        }
    }

    // MARK: - Huby

    private func session(for peripheral: CBPeripheral) -> HubSession? {
        sessions.first { $0.id == peripheral.identifier }
    }

    func isInUse(_ device: DiscoveredBuWizz) -> Bool {
        sessions.contains { $0.id == device.id }
    }

    /// Szuka przez 10 s i dołącza kolejne huby; istniejące połączenia zostają
    func scanAndConnect() {
        guard central.state == .poweredOn else {
            log("Bluetooth niegotowy (stan: \(central.state.rawValue))")
            return
        }
        stopScan()
        discoveredDevices.removeAll()
        isScanning = true
        log("Start skanowania BLE")
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        scanTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: false) { [weak self] _ in
            self?.stopScan()
        }
    }

    func stopScan() {
        scanTimer?.invalidate()
        if isScanning {
            central.stopScan()
            isScanning = false
        }
    }

    func connect(to item: DiscoveredBuWizz) {
        guard !isInUse(item) else { return }
        let hub = HubSession(device: item) { [weak self] in self?.log($0) }
        sessions.append(hub)
        log("Łączenie z \(item.name)")
        central.connect(item.peripheral, options: nil)
    }

    func disconnect(_ hub: HubSession) {
        hub.stopAllPorts()
        log("Rozłączanie z \(hub.displayName)")
        remove(hub)
        central.cancelPeripheralConnection(hub.peripheral)
    }

    func disconnectAll() {
        stopScan()
        sessions.forEach { disconnect($0) }
    }

    func stopAll() {
        sessions.forEach { $0.stopAllPorts() }
    }

    private func remove(_ hub: HubSession) {
        hub.invalidate()
        sessions.removeAll { $0 === hub }
    }

    // MARK: - Pad i dioda PS4

    private func registerPadNotifications() {
        updatePadFlag()
        updatePadLight()
        NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updatePadFlag()
            self?.updatePadLight()
            self?.log("Pad podłączony")
        }
        NotificationCenter.default.addObserver(
            forName: .GCControllerDidDisconnect,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updatePadFlag()
            self?.resetSticksToZero()
            self?.stopAll()
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
        let controllers = GCController.controllers()
        hasPad = !controllers.isEmpty
        padLightSupported = controllers.contains { $0.light != nil }
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

    private func startControlLoop() {
        loopTimer = Timer.scheduledTimer(withTimeInterval: 0.025, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.pulsePhase += 0.14
            self.blinkCounter += 1
            self.pollPad()
            self.updatePadLight()
            let pad = GCController.controllers().first?.extendedGamepad
            for hub in self.sessions {
                hub.tick(pad: pad, blinkCounter: self.blinkCounter)
            }
        }
    }

    private func updatePadLight() {
        let controllers = GCController.controllers()
        padLightSupported = controllers.contains { $0.light != nil }

        let baseRGB: (r: Float, g: Float, b: Float)
        // Dioda pokazuje najsłabszą baterię ze wszystkich hubów
        let connected = sessions.filter { $0.isConnected }
        let charging = connected.contains { $0.isCharging }
        if connected.isEmpty {
            baseRGB = (0.15, 0.25, 0.85)
        } else {
            let ratio = connected.compactMap { $0.batteryRatio }.min() ?? 0.75
            if ratio > 0.65 {
                baseRGB = (0.0, 1.0, 0.15)
            } else if ratio > 0.35 {
                baseRGB = (1.0, 0.85, 0.0)
            } else if ratio > 0.15 {
                baseRGB = (1.0, 0.35, 0.0)
            } else {
                baseRGB = (1.0, 0.05, 0.05)
            }
        }

        let brightness: Float
        if charging {
            let wave = 0.5 + 0.5 * sin(pulsePhase)
            brightness = Float(0.12 + 0.88 * wave)
        } else {
            brightness = 1.0
        }

        let gcColor = GCColor(
            red: baseRGB.r * brightness,
            green: baseRGB.g * brightness,
            blue: baseRGB.b * brightness
        )

        for ctrl in controllers {
            ctrl.light?.color = gcColor
        }
    }

}

extension BuWizzController: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            bluetoothState = "Bluetooth gotowy"
        case .poweredOff:
            bluetoothState = "Bluetooth wyłączony"
        case .unauthorized:
            bluetoothState = "Brak uprawnień Bluetooth"
        default:
            bluetoothState = "Status BT: \(central.state.rawValue)"
        }
        log(bluetoothState)
        if central.state != .poweredOn {
            stopScan()
            sessions.forEach { remove($0) }
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

        var kind = HubKind.buwizz
        var systemType: UInt8? = nil
        if advUUIDs.contains(PybricksSpec.serviceUUID) {
            kind = .pybricks
        } else if advUUIDs.contains(LegoSpec.serviceUUID) {
            kind = .lego
            // Dane producenta: ID firmy (2 bajty), stan przycisku, typ systemu
            if let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data, data.count >= 4 {
                systemType = [UInt8](data)[3]
            }
        }
        let autoConnect = looksLikeBuWizz
            || kind == .pybricks
            || (systemType.map { LegoSpec.supportedSystemTypes.contains($0) } ?? false)

        let entry = DiscoveredBuWizz(
            id: peripheral.identifier,
            peripheral: peripheral,
            name: name,
            rssi: rssiInt,
            kind: kind,
            legoSystemType: systemType
        )

        if let idx = discoveredDevices.firstIndex(where: { $0.id == entry.id }) {
            discoveredDevices[idx] = entry
        } else {
            discoveredDevices.append(entry)
            log("Wykryto: \(name) (\(rssiInt) dBm)")
        }

        // Podczas skanowania łączymy się z każdym rozpoznanym hubem
        if autoConnect && isScanning && session(for: peripheral) == nil {
            connect(to: entry)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        session(for: peripheral)?.didConnect()
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        guard let hub = session(for: peripheral) else { return }
        log("\(hub.displayName): błąd połączenia: \(error?.localizedDescription ?? "brak")")
        remove(hub)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        // Spóźnione zdarzenie nie może usunąć świeżo wznowionego połączenia
        guard peripheral.state == .disconnected, let hub = session(for: peripheral) else { return }
        log("\(hub.displayName): rozłączono: \(error?.localizedDescription ?? "zakończono")")
        remove(hub)
    }
}
