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

struct DiscoveredBuWizz: Identifiable {
    let id: UUID
    let peripheral: CBPeripheral
    let name: String
    let rssi: Int
    var kind: HubKind = .buwizz
    var legoSystemType: UInt8? = nil
}

final class BuWizzController: NSObject, ObservableObject {
    @Published var connectionState = "Rozłączono"
    @Published var isConnected = false
    @Published var hubKind: HubKind = .buwizz
    @Published var portCount = 6
    @Published var batteryPercent: Int? = nil
    @Published var hasPad = false
    @Published var padLightSupported = false

    @Published var leftStickX: Double = 0.0
    @Published var leftStickY: Double = 0.0
    @Published var rightStickX: Double = 0.0
    @Published var rightStickY: Double = 0.0

    @Published var batteryVoltage: Double? = nil
    @Published var batteryLevelCode: Int? = nil
    @Published var isCharging: Bool = false
    @Published var lastFrameHex = "--"
    @Published var channelValuesPreview: [Int] = Array(repeating: 0, count: 6)

    // Pozycja enkodera (w stopniach) odczytana po połączeniu, traktowana jako punkt 0
    @Published var initialServoZeroAngleDeg: Int = 0
    @Published var servoAngleDegPreview: Int = 0

    @Published var lightLatched: [Bool] = Array(repeating: false, count: 6)
    @Published var indicatorLatched: [Bool] = Array(repeating: false, count: 6)

    @Published var discoveredDevices: [DiscoveredBuWizz] = []
    @Published var logs: [String] = []

    @Published var deadzone: Double = 0.10 {
        didSet { saveConfig() }
    }

    @Published var maxAngleDegrees: Double = 90.0 {
        didSet { saveConfig() }
    }

    @Published var servoPortIndex: Int = 0 {
        willSet {
            // Przed zmianą portu zatrzymaj silniki i wyśrodkuj stare serwo
            sendOutputs(Array(repeating: 0, count: 6), servoOffsetDeg: 0, force: true)
        }
        didSet {
            syncServoPortFlags()
            resetServoSetup() // ponowna konfiguracja przy następnym raporcie statusu
            saveConfig()
        }
    }

    @Published var ports: [PortAssignment] = [
        PortAssignment(portIndex: 0, source: .leftStickX, mode: .normal, powerLimitPercent: 80, invert: false, isServo: true),
        PortAssignment(portIndex: 1, source: .leftStickY, mode: .normal, powerLimitPercent: 100, invert: false, isServo: false),
        PortAssignment(portIndex: 2, source: .buttonX, mode: .frontLight, powerLimitPercent: 100, invert: false, isServo: false),
        PortAssignment(portIndex: 3, source: .buttonY, mode: .indicator, powerLimitPercent: 100, invert: false, isServo: false),
        PortAssignment(portIndex: 4, source: .none, mode: .normal, powerLimitPercent: 100, invert: false, isServo: false),
        PortAssignment(portIndex: 5, source: .none, mode: .normal, powerLimitPercent: 100, invert: false, isServo: false)
    ] {
        didSet { saveConfig() }
    }

    @Published var brakeMask: UInt8 = 0x00
    @Published var lutMask: UInt8 = 0x00

    private struct SavedConfig: Codable {
        var servoPortIndex: Int
        var deadzone: Double?
        var maxAngleDegrees: Double?
        var ports: [PortAssignment]
    }

    private let configKey = "BuWizzPad.Config.v9.initZero"
    private var central: CBCentralManager!
    private var targetPeripheral: CBPeripheral?
    private var txCharacteristic: CBCharacteristic?
    private var loopTimer: Timer?
    private var serviceTimeoutTimer: Timer?
    private var pulsePhase: Double = 0.0
    private var blinkCounter: Int = 0

    private enum ServoSetupState { case idle, configuring, ready }
    private var servoState: ServoSetupState = .idle
    private var servoSetupGeneration = 0
    private var motorPositions: [Int32] = [0, 0, 0, 0] // pozycje względne portów PU 1–4
    private var servoZeroPosition: Int32 = 0

    private var driver: HubDriver? // nil = BuWizz3
    private var legoSystemType: UInt8?

    /// Port serwa istniejący na aktualnym hubie (nil = brak serwa)
    private var activeServoPort: Int? {
        let limit = hubKind == .buwizz ? 4 : portCount
        return (0..<limit).contains(servoPortIndex) ? servoPortIndex : nil
    }
    private var prevTriggerPressed: [Bool] = Array(repeating: false, count: 6)

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

    func togglePortLatchManually(portIndex: Int) {
        guard ports.indices.contains(portIndex) else { return }
        switch ports[portIndex].mode {
        case .frontLight:
            lightLatched[portIndex].toggle()
        case .indicator:
            indicatorLatched[portIndex].toggle()
        case .normal:
            break
        }
    }

    // Ręczne ustawienie obecnej (zmierzonej) pozycji jako nowego 0
    func recaptureCurrentServoAsZero() {
        if let driver = driver {
            driver.recaptureZero()
            return
        }
        guard servoState == .ready, let port = activeServoPort else {
            log("Serwo jeszcze niegotowe")
            return
        }
        servoZeroPosition = motorPositions[port]
        initialServoZeroAngleDeg = Int(servoZeroPosition)
        servoAngleDegPreview = 0
        log("Zaktualizowano punkt 0 serwa: \(initialServoZeroAngleDeg)°")
    }

    // MARK: - Tryb PU Pozycja (0x50 + 0x53 + 0x52)

    private func resetServoSetup() {
        servoSetupGeneration += 1 // unieważnia trwającą sekwencję
        servoState = .idle
        servoAngleDegPreview = 0
    }

    // Wywoływane po pierwszym raporcie statusu, gdy znamy już faktyczną pozycję silnika
    private func configureServo() {
        servoState = .configuring
        servoSetupGeneration += 1
        var functions = [UInt8](repeating: BuWizzSpec.puFuncSimplePWM, count: 4)
        guard let idx = activeServoPort else {
            // Bez serwa: wszystkie porty PU w trybie PWM
            runServoSetup([[BuWizzSpec.cmdSetPUPortFunction] + functions], generation: servoSetupGeneration)
            return
        }
        servoZeroPosition = motorPositions[idx]
        initialServoZeroAngleDeg = Int(servoZeroPosition)
        functions[idx] = BuWizzSpec.puFuncPositionServo

        var refs: [Int32] = [0, 0, 0, 0]
        refs[idx] = servoZeroPosition
        let reference = servoReferenceCommand(refs)

        var steps: [[UInt8]] = [
            [BuWizzSpec.cmdSetMotorRamp] + [UInt8](repeating: 0, count: 12),
            reference
        ]
        // 0x31 bez ruchu: serwo trzyma punkt 0, pozostałe porty stoją
        var idle: [UInt8] = [BuWizzSpec.cmdSetMotorExtended]
        refs.forEach { appendLittleEndian($0, to: &idle) }
        idle += [0, 0, brakeMask, lutMask]

        // BuWizz3 potrafi nie przyjąć trybu za pierwszym razem, więc powtarzamy
        for _ in 0..<4 {
            steps.append([BuWizzSpec.cmdSetPUPortFunction] + functions)
            steps.append(pidCommand(portIndex: idx))
            steps.append(reference)
            steps.append(idle)
        }

        log("Konfiguruję serwo na porcie \(idx + 1), punkt 0 = \(initialServoZeroAngleDeg)°")
        runServoSetup(steps, generation: servoSetupGeneration)
    }

    private func runServoSetup(_ steps: [[UInt8]], generation: Int) {
        guard generation == servoSetupGeneration, isConnected else { return }
        guard let step = steps.first else {
            servoState = .ready
            log("BuWizz3 skonfigurowany")
            return
        }
        sendRawBytes(step, preferResponse: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.runServoSetup(Array(steps.dropFirst()), generation: generation)
        }
    }

    private func servoReferenceCommand(_ refs: [Int32]) -> [UInt8] {
        var bytes: [UInt8] = [BuWizzSpec.cmdSetServoRef]
        refs.forEach { appendLittleEndian($0, to: &bytes) }
        return bytes
    }

    // Domyślne parametry PID serwa (takie jak w BrickController2)
    private func pidCommand(portIndex: Int) -> [UInt8] {
        var bytes: [UInt8] = [BuWizzSpec.cmdSetPIDParams, UInt8(portIndex)]
        // outLP, D_LP, speed_LP, Kp, Ki, Kd, Liml, limit zmiany referencji
        let params: [Float] = [0, 0, 0.6, 0.5, 0.01, -1, 20, 50]
        params.forEach { appendLittleEndian($0.bitPattern, to: &bytes) }
        // limOut, DeadbandOut, DeadbandOutBoost, tryb
        bytes += [127, 5, 10, BuWizzSpec.puFuncPositionServo]
        return bytes
    }

    private func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to bytes: inout [UInt8]) {
        withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
    }

    // MARK: - BLE, Pad i dioda PS4

    func scanAndConnect() {
        guard central.state == .poweredOn else {
            connectionState = "Bluetooth niegotowy (stan: \(central.state.rawValue))"
            log("BT state: \(central.state.rawValue)")
            return
        }
        serviceTimeoutTimer?.invalidate()
        isConnected = false
        resetHub()
        initialServoZeroAngleDeg = 0
        txCharacteristic = nil
        targetPeripheral = nil
        batteryVoltage = nil
        batteryLevelCode = nil
        isCharging = false
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
        if let old = targetPeripheral, old.identifier != item.id {
            stopAllPortsNow()
            central.cancelPeripheralConnection(old)
        }
        isConnected = false
        txCharacteristic = nil
        batteryVoltage = nil
        batteryLevelCode = nil
        isCharging = false
        resetHub()
        legoSystemType = item.legoSystemType
        targetPeripheral = item.peripheral
        item.peripheral.delegate = self
        connectionState = "Łączę z \(item.name)..."
        log("Łączenie z \(item.name)")
        central.connect(item.peripheral, options: nil)
    }

    func disconnect() {
        serviceTimeoutTimer?.invalidate()
        stopAllPortsNow()
        central.stopScan()
        if let p = targetPeripheral {
            log("Rozłączanie z \(p.name ?? "hub")")
            central.cancelPeripheralConnection(p)
        }
    }

    private func loadConfig() {
        guard let data = UserDefaults.standard.data(forKey: configKey),
              let decoded = try? JSONDecoder().decode(SavedConfig.self, from: data) else {
            syncServoPortFlags()
            return
        }
        servoPortIndex = max(-1, min(5, decoded.servoPortIndex))
        if let dz = decoded.deadzone {
            deadzone = max(0.0, min(0.35, dz))
        }
        if let deg = decoded.maxAngleDegrees {
            maxAngleDegrees = max(30.0, min(180.0, deg))
        }
        if decoded.ports.count == 6 {
            ports = decoded.ports
        }
        syncServoPortFlags()
    }

    private func saveConfig() {
        let cfg = SavedConfig(
            servoPortIndex: servoPortIndex,
            deadzone: deadzone,
            maxAngleDegrees: maxAngleDegrees,
            ports: ports
        )
        guard let encoded = try? JSONEncoder().encode(cfg) else { return }
        UserDefaults.standard.set(encoded, forKey: configKey)
    }

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
            guard self.isConnected else { return }
            self.transmitAllPorts()
        }
    }

    private func updatePadLight() {
        let controllers = GCController.controllers()
        padLightSupported = controllers.contains { $0.light != nil }

        let baseRGB: (r: Float, g: Float, b: Float)
        if !isConnected {
            baseRGB = (0.15, 0.25, 0.85)
        } else {
            let ratio = batteryNormalizedRatio()
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
        if isConnected && isCharging {
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

    private func batteryNormalizedRatio() -> Double {
        if let percent = batteryPercent {
            return max(0.0, min(1.0, Double(percent) / 100.0))
        }
        // Skala napięcia poniżej dotyczy tylko BuWizz3
        if hubKind == .buwizz, let v = batteryVoltage {
            return max(0.0, min(1.0, (v - 9.0) / 6.35))
        }
        if let lvl = batteryLevelCode {
            return max(0.0, min(1.0, Double(lvl) / 3.0))
        }
        return 0.75
    }

    // Raport statusu (0x01) z BuWizz3: bajt 1 = flags, bajt 2 = napięcie, opcjonalnie kolejne bajty przy połączeniu
    private func handleStatusReport(_ data: Data) {
        guard data.count >= 3, data[0] == 0x01 else { return }
        let flags = data[1]
        let chargingBit = (flags & (1 << 6)) != 0
        let levelBits = Int((flags >> 4) & 0x03)

        let voltRaw = Double(data[2])
        let volts = 9.0 + voltRaw * 0.05

        isCharging = chargingBit
        batteryLevelCode = levelBits
        batteryVoltage = volts

        // Bajty 22–53: 4 x (typ, prędkość, pozycja absolutna Int16, pozycja względna Int32)
        let bytes = [UInt8](data)
        guard bytes.count >= 54 else { return }
        for port in 0..<4 {
            let offset = 22 + port * 8 + 4
            let raw = (0..<4).reduce(UInt32(0)) { $0 | (UInt32(bytes[offset + $1]) << (8 * $1)) }
            motorPositions[port] = Int32(bitPattern: raw)
        }

        if isConnected && servoState == .idle {
            configureServo()
        }
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
        case .buttonA:
            return Double(pad.buttonA.value)
        case .buttonB:
            return Double(pad.buttonB.value)
        case .buttonX:
            return Double(pad.buttonX.value)
        case .buttonY:
            return Double(pad.buttonY.value)
        case .none:
            return 0.0
        }
    }

    private func updateToggleTriggerForPort(_ port: PortAssignment, rawValue: Double) {
        let idx = port.portIndex
        guard (0..<6).contains(idx) else { return }
        let pressedNow = abs(rawValue) > 0.5
        let wasPressed = prevTriggerPressed[idx]
        prevTriggerPressed[idx] = pressedNow

        if pressedNow && !wasPressed {
            switch port.mode {
            case .frontLight:
                lightLatched[idx].toggle()
            case .indicator:
                indicatorLatched[idx].toggle()
            case .normal:
                break
            }
        }
    }

    private func stopAllPortsNow() {
        for i in 0..<6 {
            lightLatched[i] = false
            indicatorLatched[i] = false
            prevTriggerPressed[i] = false
        }
        // Silniki stop, serwo wraca do punktu 0
        sendOutputs(Array(repeating: 0, count: 6), servoOffsetDeg: 0, force: true)
    }

    private func transmitAllPorts() {
        var channelBytes: [Int8] = Array(repeating: 0, count: 6)
        let blinkOn = ((blinkCounter / 16) % 2) == 0
        var activeServoNorm: Double = 0.0

        for port in ports where (0..<6).contains(port.portIndex) {
            let idx = port.portIndex
            let rawInput = readSourceValue(port.source)
            updateToggleTriggerForPort(port, rawValue: rawInput)

            var effectiveInput = rawInput
            if port.invert {
                effectiveInput = -effectiveInput
            }

            let powerRatio = max(0.0, min(1.0, port.powerLimitPercent / 100.0))

            if idx == servoPortIndex || port.isServo {
                if abs(effectiveInput) < deadzone {
                    // Powrót do punktu 0
                    activeServoNorm = 0.0
                } else {
                    activeServoNorm = max(-1.0, min(1.0, effectiveInput * powerRatio))
                }
                channelBytes[idx] = doubleToInt8(activeServoNorm)
                continue
            }

            switch port.mode {
            case .normal:
                channelBytes[idx] = computeLinearMotorByte(
                    rawValue: effectiveInput,
                    powerRatio: powerRatio
                )

            case .frontLight:
                if lightLatched[idx] {
                    let sign: Double = port.invert ? -1.0 : 1.0
                    channelBytes[idx] = doubleToInt8(sign * powerRatio)
                } else {
                    channelBytes[idx] = 0
                }

            case .indicator:
                if indicatorLatched[idx] && blinkOn {
                    let sign: Double = port.invert ? -1.0 : 1.0
                    channelBytes[idx] = doubleToInt8(sign * powerRatio)
                } else {
                    channelBytes[idx] = 0
                }
            }
        }

        channelValuesPreview = channelBytes.map { Int($0) }

        // Wysyłka co 100 ms (co 4. takt), żeby nie zapchać kolejki komend BuWizz3
        if blinkCounter % 4 == 0 {
            sendOutputs(channelBytes, servoOffsetDeg: Int32((activeServoNorm * maxAngleDegrees).rounded()))
        }
    }

    private func computeLinearMotorByte(rawValue: Double, powerRatio: Double) -> Int8 {
        let v = max(-1.0, min(1.0, rawValue))
        if abs(v) < deadzone {
            return 0
        }
        return doubleToInt8(v * powerRatio)
    }

    private func doubleToInt8(_ value: Double) -> Int8 {
        let clamped = max(-1.0, min(1.0, value))
        return Int8((clamped * 127.0).rounded())
    }

    private func sendOutputs(_ channels: [Int8], servoOffsetDeg: Int32, force: Bool = false) {
        if let driver = driver {
            guard isConnected else { return }
            servoAngleDegPreview = Int(servoOffsetDeg)
            driver.send(power: channels, servoPort: activeServoPort,
                        servoOffsetDeg: Int(servoOffsetDeg), force: force)
        } else {
            sendMotors0x31(channels, servoOffsetDeg: servoOffsetDeg)
        }
    }

    // MARK: - Huby PU i Pybricks

    private func resetHub() {
        resetServoSetup()
        driver = nil
        hubKind = .buwizz
        portCount = 6
        batteryPercent = nil
    }

    private func attachDriver(_ newDriver: HubDriver, kind: HubKind) {
        driver = newDriver
        hubKind = kind
        newDriver.onLog = { [weak self] in self?.log($0) }
        newDriver.onPortCount = { [weak self] in self?.portCount = max(1, min(6, $0)) }
        newDriver.onBattery = { [weak self] percent, voltage in
            self?.batteryPercent = percent
            self?.batteryVoltage = voltage
        }
        newDriver.onServoZero = { [weak self] in self?.initialServoZeroAngleDeg = $0 }
        newDriver.onState = { [weak self] state in
            self?.connectionState = "\(kind.title): \(state)"
        }
        newDriver.write = { [weak self] in self?.sendRawBytes($0, updateLastFrame: true) }
        if let lego = newDriver as? LegoHubDriver {
            lego.configure(systemType: legoSystemType)
        } else {
            portCount = 6
        }
    }

    func startPybricksProgram() {
        (driver as? PybricksHubDriver)?.startProgram()
    }

    // 0x31: porty 1–4 jako Int32 (PWM albo kąt serwa), porty 5–6 jako Int8
    private func sendMotors0x31(_ chValues: [Int8], servoOffsetDeg: Int32) {
        guard servoState == .ready else { return }
        var packet: [UInt8] = [BuWizzSpec.cmdSetMotorExtended]
        for port in 0..<4 {
            let value: Int32 = port == servoPortIndex
                ? servoZeroPosition &+ servoOffsetDeg
                : Int32(chValues[port])
            appendLittleEndian(value, to: &packet)
        }
        packet.append(UInt8(bitPattern: chValues[4]))
        packet.append(UInt8(bitPattern: chValues[5]))
        packet.append(brakeMask)
        packet.append(lutMask)
        servoAngleDegPreview = Int(servoOffsetDeg)
        sendRawBytes(packet, updateLastFrame: true)
    }

    private func sendRawBytes(_ bytes: [UInt8], updateLastFrame: Bool = false, preferResponse: Bool = false) {
        guard let peripheral = targetPeripheral,
              let char = txCharacteristic else { return }

        let payload = Data(bytes)
        if updateLastFrame {
            lastFrameHex = payload.map { String(format: "%02X", $0) }.joined(separator: " ")
        }

        let useResponse = !char.properties.contains(.writeWithoutResponse)
            || (preferResponse && char.properties.contains(.write))
        peripheral.writeValue(payload, for: char, type: useResponse ? .withResponse : .withoutResponse)
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
            resetServoSetup()
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

        if autoConnect && targetPeripheral == nil && !isConnected {
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
        if let target = targetPeripheral, target.identifier != peripheral.identifier { return }
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
        // Spóźnione zdarzenie od poprzedniego huba nie może rozłączyć nowego
        if let target = targetPeripheral, target.identifier != peripheral.identifier { return }
        serviceTimeoutTimer?.invalidate()
        isConnected = false
        resetHub()
        txCharacteristic = nil
        targetPeripheral = nil
        batteryVoltage = nil
        batteryLevelCode = nil
        isCharging = false
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
        // Rodzaj huba rozpoznajemy po usługach (pewniejsze niż rozgłoszenie)
        driver = nil
        hubKind = .buwizz
        portCount = 6
        if services.contains(where: { $0.uuid == PybricksSpec.serviceUUID }) {
            attachDriver(PybricksHubDriver(), kind: .pybricks)
        } else if services.contains(where: { $0.uuid == LegoSpec.serviceUUID }) {
            attachDriver(LegoHubDriver(), kind: .lego)
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
            if let driver = driver {
                if ch.uuid == driver.charUUID {
                    txCharacteristic = ch
                    peripheral.setNotifyValue(true, for: ch)
                }
                continue
            }
            let canWrite = ch.properties.contains(.write) || ch.properties.contains(.writeWithoutResponse)

            if isApplicationCharacteristic(ch.uuid) && canWrite {
                txCharacteristic = ch
                if ch.properties.contains(.notify) {
                    peripheral.setNotifyValue(true, for: ch)
                }
                isConnected = true
                connectionState = "Gotowy: \(peripheral.name ?? "BuWizz3")"
                log("Wybrano char: \(ch.uuid.uuidString)")
                // Serwo konfiguruje się po pierwszym raporcie statusu (handleStatusReport)
            }
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard error == nil, let value = characteristic.value else { return }
        if let driver = driver {
            if characteristic.uuid == driver.charUUID {
                driver.handle(value)
            }
        } else if isApplicationCharacteristic(characteristic.uuid) {
            handleStatusReport(value)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard let driver = driver, characteristic.uuid == driver.charUUID else { return }
        if let error = error {
            log("Błąd powiadomień: \(error.localizedDescription)")
            return
        }
        isConnected = true
        connectionState = "\(hubKind.title): \(peripheral.name ?? "hub")"
        driver.start()
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error = error {
            log("Błąd zapisu: \(error.localizedDescription)")
        }
        driver?.writeCompleted()
    }
}
