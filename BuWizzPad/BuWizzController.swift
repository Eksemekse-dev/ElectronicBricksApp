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

enum AutoCalPhase: String {
    case idle = "Gotowy"
    case sweepingLeft = "Ruch w lewo – kliknij 'Złap Lewo' na oporze"
    case centering = "Powrót na środek (0.0)..."
    case sweepingRight = "Ruch w prawo – kliknij 'Złap Prawo' na oporze"
    case finished = "Zakończono kalibrację PU"
}

struct ServoCalibrationData: Codable, Equatable {
    var leftLimit: Double = -1.0   // -1.0 ... 0.0 (skaluje max wychylenie w lewo)
    var centerOffset: Double = 0.0 // 0.0 = środek po puszczeniu skrętu
    var rightLimit: Double = 1.0  // 0.0 ... +1.0 (skaluje max wychylenie w prawo)
    var maxAngleDegrees: Double = 90.0

    func computeNormalizedPosition(input: Double, deadzone: Double, powerRatio: Double) -> Double {
        let v = max(-1.0, min(1.0, input))
        let limit = max(0.0, min(1.0, powerRatio))

        if abs(v) < deadzone {
            return max(-1.0, min(1.0, centerOffset * limit))
        }

        let target: Double
        if v < 0 {
            let ratio = min(1.0, (-v - deadzone) / max(0.001, (1.0 - deadzone)))
            target = centerOffset + ratio * (leftLimit - centerOffset)
        } else {
            let ratio = min(1.0, (v - deadzone) / max(0.001, (1.0 - deadzone)))
            target = centerOffset + ratio * (rightLimit - centerOffset)
        }

        return max(-1.0, min(1.0, target * limit))
    }
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
}

final class BuWizzController: NSObject, ObservableObject {
    @Published var connectionState = "Rozłączono"
    @Published var isConnected = false
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
    @Published var servoAngleDegPreview: Int = 0

    @Published var lightLatched: [Bool] = Array(repeating: false, count: 6)
    @Published var indicatorLatched: [Bool] = Array(repeating: false, count: 6)

    @Published var discoveredDevices: [DiscoveredBuWizz] = []
    @Published var logs: [String] = []

    @Published var deadzone: Double = 0.10 {
        didSet { saveConfig() }
    }

    @Published var servoPortIndex: Int = 0 {
        didSet {
            syncServoPortFlags()
            applyPUPositionServoModeIfConnected()
            saveConfig()
        }
    }

    @Published var servoCal = ServoCalibrationData() {
        didSet { saveConfig() }
    }

    @Published var autoCalibrating = false
    @Published var autoCalPhase: AutoCalPhase = .idle
    @Published var liveSweepValue: Double = 0.0
    @Published var calibrationStatus = "Gotowy (PU Pozycja 0x50+0x52)"

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
        var servoCal: ServoCalibrationData?
        var ports: [PortAssignment]
    }

    private let configKey = "BuWizzPad.Config.v8.puPosition"
    private var central: CBCentralManager!
    private var targetPeripheral: CBPeripheral?
    private var txCharacteristic: CBCharacteristic?
    private var loopTimer: Timer?
    private var serviceTimeoutTimer: Timer?
    private var calibrationTask: Task<Void, Never>?
    private var overrideServoNormalized: Double? = nil
    private var pulsePhase: Double = 0.0
    private var blinkCounter: Int = 0
    private var prevTriggerPressed: [Bool] = Array(repeating: false, count: 6)
    private var capturedLeftDuringSweep: Double? = nil
    private var capturedRightDuringSweep: Double? = nil

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

    // MARK: - Tryb PU Pozycja (0x50 + 0x52)

    func applyPUPositionServoModeIfConnected() {
        guard isConnected, servoPortIndex < 4 else { return }
        var functions: [UInt8] = [
            BuWizzSpec.puFuncSimplePWM,
            BuWizzSpec.puFuncSimplePWM,
            BuWizzSpec.puFuncSimplePWM,
            BuWizzSpec.puFuncSimplePWM
        ]
        functions[servoPortIndex] = BuWizzSpec.puFuncPositionServo
        let cmd: [UInt8] = [BuWizzSpec.cmdSetPUPortFunction] + functions
        sendRawBytes(cmd)
        log("Ustawiono 0x50 PU Position Servo (0x15) na Porcie \(servoPortIndex + 1)")
    }

    // MARK: - Auto-kalibracja serwa w trybie PU Pozycja

    func captureCurrentSweepLeft() {
        let val = min(-0.05, liveSweepValue)
        capturedLeftDuringSweep = val
        servoCal.leftLimit = max(-1.0, min(0.0, val))
        calibrationStatus = String(format: "Złapano Lewo: %.2f", servoCal.leftLimit)
        log(String(format: "Auto-kalibracja: złapano Lewo = %.2f", servoCal.leftLimit))
    }

    func captureCurrentSweepRight() {
        let val = max(0.05, liveSweepValue)
        capturedRightDuringSweep = val
        servoCal.rightLimit = max(0.0, min(1.0, val))
        calibrationStatus = String(format: "Złapano Prawo: %+.2f", servoCal.rightLimit)
        log(String(format: "Auto-kalibracja: złapano Prawo = %+.2f", servoCal.rightLimit))
    }

    func resetServoCalibration() {
        cancelAutoServoCalibration()
        servoCal = ServoCalibrationData()
        calibrationStatus = "Reset kalibracji: L -1.00 | C 0.00 | P +1.00"
    }

    func startAutoServoCalibration() {
        guard !autoCalibrating else { return }
        calibrationTask?.cancel()
        capturedLeftDuringSweep = nil
        capturedRightDuringSweep = nil
        autoCalibrating = true
        autoCalPhase = .sweepingLeft
        liveSweepValue = 0.0
        calibrationStatus = AutoCalPhase.sweepingLeft.rawValue
        log("Start auto-kalibracji PU serwa na Porcie \(servoPortIndex + 1)")

        let powerRatio: Double = {
            if ports.indices.contains(servoPortIndex) {
                let lim = ports[servoPortIndex].powerLimitPercent / 100.0
                return max(0.25, min(1.0, lim > 0 ? lim : 1.0))
            }
            return 1.0
        }()

        calibrationTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            defer {
                self.overrideServoNormalized = nil
                self.liveSweepValue = 0.0
                self.autoCalibrating = false
                if self.autoCalPhase != .finished {
                    self.autoCalPhase = .idle
                }
            }

            // 1. Skanowanie w lewo (do -powerRatio lub przerwanie przez "Złap Lewo")
            let steps = 20
            for step in 1...steps {
                if Task.isCancelled { return }
                if self.capturedLeftDuringSweep != nil { break }
                let frac = Double(step) / Double(steps)
                let val = -frac * powerRatio
                self.liveSweepValue = val
                self.overrideServoNormalized = val
                self.calibrationStatus = String(format: "Lewo: %.2f (lub kliknij Złap Lewo)", val)
                try? await Task.sleep(nanoseconds: 130_000_000)
            }
            let finalLeft = self.capturedLeftDuringSweep ?? self.liveSweepValue
            self.servoCal.leftLimit = max(-1.0, min(0.0, finalLeft))

            // 2. Powrót na środek (0.0)
            self.autoCalPhase = .centering
            self.liveSweepValue = 0.0
            self.overrideServoNormalized = 0.0
            self.calibrationStatus = "Powrót na środek (0.0)..."
            try? await Task.sleep(nanoseconds: 450_000_000)

            // 3. Skanowanie w prawo (do +powerRatio lub przerwanie przez "Złap Prawo")
            self.autoCalPhase = .sweepingRight
            for step in 1...steps {
                if Task.isCancelled { return }
                if self.capturedRightDuringSweep != nil { break }
                let frac = Double(step) / Double(steps)
                let val = frac * powerRatio
                self.liveSweepValue = val
                self.overrideServoNormalized = val
                self.calibrationStatus = String(format: "Prawo: %+.2f (lub kliknij Złap Prawo)", val)
                try? await Task.sleep(nanoseconds: 130_000_000)
            }
            let finalRight = self.capturedRightDuringSweep ?? self.liveSweepValue
            self.servoCal.rightLimit = max(0.0, min(1.0, finalRight))

            // 4. Powrót na środek (0.0)
            self.servoCal.centerOffset = 0.0
            self.overrideServoNormalized = 0.0
            self.liveSweepValue = 0.0
            self.autoCalPhase = .finished
            self.calibrationStatus = String(
                format: "Gotowe! L: %.2f | C: 0.00 | P: %+.2f",
                self.servoCal.leftLimit,
                self.servoCal.rightLimit
            )
            self.log(String(format: "Auto-kalibracja OK: L=%.2f, P=%+.2f", self.servoCal.leftLimit, self.servoCal.rightLimit))
        }
    }

    func cancelAutoServoCalibration() {
        calibrationTask?.cancel()
        overrideServoNormalized = nil
        liveSweepValue = 0.0
        autoCalibrating = false
        autoCalPhase = .idle
        calibrationStatus = "Anulowano kalibrację"
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
        if let dz = decoded.deadzone {
            deadzone = max(0.0, min(0.4, dz))
        }
        if let cal = decoded.servoCal {
            servoCal = cal
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
            servoCal: servoCal,
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
        if let v = batteryVoltage {
            return max(0.0, min(1.0, (v - 9.0) / 6.35))
        }
        if let lvl = batteryLevelCode {
            return max(0.0, min(1.0, Double(lvl) / 3.0))
        }
        return 0.75
    }

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
        overrideServoNormalized = nil
        for i in 0..<6 {
            lightLatched[i] = false
            indicatorLatched[i] = false
            prevTriggerPressed[i] = false
        }
        sendServoPosition0x52(portIndex: servoPortIndex, normalized: 0.0)
        sendMotorBytes0x30(Array(repeating: 0, count: 6))
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
                if let forced = overrideServoNormalized {
                    activeServoNorm = max(-1.0, min(1.0, forced))
                } else {
                    activeServoNorm = servoCal.computeNormalizedPosition(
                        input: effectiveInput,
                        deadzone: deadzone,
                        powerRatio: powerRatio
                    )
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
        sendServoPosition0x52(portIndex: servoPortIndex, normalized: activeServoNorm)
        sendMotorBytes0x30(channelBytes)
    }

    private func sendServoPosition0x52(portIndex: Int, normalized: Double) {
        guard (0..<4).contains(portIndex) else { return }
        let clamped = max(-1.0, min(1.0, normalized))
        let angleDeg = Int32((clamped * servoCal.maxAngleDegrees).rounded())
        servoAngleDegPreview = Int(angleDeg)

        var refs: [Int32] = [0, 0, 0, 0]
        refs[portIndex] = angleDeg

        var bytes: [UInt8] = [BuWizzSpec.cmdSetServoRef]
        for r in refs {
            var le = r.littleEndian
            withUnsafeBytes(of: &le) { rawBuf in
                bytes.append(contentsOf: rawBuf)
            }
        }
        sendRawBytes(bytes)
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

    private func sendMotorBytes0x30(_ chValues: [Int8]) {
        var packet: [UInt8] = [BuWizzSpec.cmdSetMotor]
        packet.append(contentsOf: chValues.prefix(6).map { UInt8(bitPattern: $0) })
        packet.append(brakeMask)
        packet.append(lutMask)
        sendRawBytes(packet, updateLastFrame: true)
    }

    private func sendRawBytes(_ bytes: [UInt8], updateLastFrame: Bool = false) {
        guard let peripheral = targetPeripheral,
              let char = txCharacteristic else { return }

        let payload = Data(bytes)
        if updateLastFrame {
            lastFrameHex = payload.map { String(format: "%02X", $0) }.joined(separator: " ")
        }

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
                applyPUPositionServoModeIfConnected()
            }
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard error == nil, let value = characteristic.value else { return }
        if isApplicationCharacteristic(characteristic.uuid) {
            handleStatusReport(value)
        }
    }
}
