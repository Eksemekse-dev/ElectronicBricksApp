import Foundation
import CoreBluetooth

enum HubKind: Equatable {
    case buwizz, lego, pybricks

    var title: String {
        switch self {
        case .buwizz: return "BuWizz3"
        case .lego: return "LEGO Powered Up"
        case .pybricks: return "Pybricks"
        }
    }
}

enum LegoSpec {
    static let serviceUUID = CBUUID(string: "00001623-1212-EFDE-1623-785FEABCD123")
    static let charUUID = CBUUID(string: "00001624-1212-EFDE-1623-785FEABCD123")
    // Move Hub, City Hub, Technic Hub (bez pilota i Mario)
    static let supportedSystemTypes: [UInt8] = [0x40, 0x41, 0x80]
    // Silniki z enkoderem, które mogą pracować jako serwo
    static let encoderMotorTypes: Set<UInt16> = [0x26, 0x27, 0x2E, 0x2F, 0x30, 0x31, 0x41, 0x4B, 0x4C]
}

enum PybricksSpec {
    static let serviceUUID = CBUUID(string: "C5F50001-8280-46DA-89F4-6D8051E4AEEF")
    static let charUUID = CBUUID(string: "C5F50002-8280-46DA-89F4-6D8051E4AEEF")
}

/// Sterownik huba innego niż BuWizz3. Kontroler zajmuje się BLE i padem, sterownik protokołem.
protocol HubDriver: AnyObject {
    var charUUID: CBUUID { get }
    var onLog: (String) -> Void { get set }
    var onPortCount: (Int) -> Void { get set }
    var onBattery: (_ percent: Int?, _ voltage: Double?) -> Void { get set }
    var onServoZero: (Int) -> Void { get set }
    var onState: (String) -> Void { get set }
    var write: ([UInt8]) -> Void { get set }

    /// Po włączeniu powiadomień
    func start()
    func handle(_ data: Data)
    /// power: -127...127 dla portów 1–6
    func send(power: [Int8], servoPort: Int?, servoOffsetDeg: Int, force: Bool)
    func recaptureZero()
    func writeCompleted()
}

private func int32LE(_ value: Int32) -> [UInt8] {
    withUnsafeBytes(of: value.littleEndian) { Array($0) }
}

// MARK: - LEGO Powered Up (LEGO Wireless Protocol 3.0)

final class LegoHubDriver: HubDriver {
    let charUUID = LegoSpec.charUUID
    var onLog: (String) -> Void = { _ in }
    var onPortCount: (Int) -> Void = { _ in }
    var onBattery: (Int?, Double?) -> Void = { _, _ in }
    var onServoZero: (Int) -> Void = { _ in }
    var onState: (String) -> Void = { _ in }
    var write: ([UInt8]) -> Void = { _ in }

    private var deviceTypes: [Int: UInt16] = [:]
    private var positions: [Int: Int32] = [:]
    private var servoPort: Int?
    private var servoZero: Int32?
    private var lastPower: [Int: Int8] = [:]
    private var lastTarget: Int32?

    func start() {
        // Aktualizacje poziomu baterii (Hub Properties 0x06)
        send([0x01, 0x06, 0x02])
    }

    // Nagłówek: długość, ID huba (0), typ wiadomości i dane
    private func send(_ body: [UInt8]) {
        write([UInt8(body.count + 2), 0x00] + body)
    }

    func handle(_ data: Data) {
        let b = [UInt8](data)
        guard b.count >= 5 else { return }
        let port = Int(b[3])

        switch b[2] {
        case 0x01: // Hub Properties
            if b.count >= 6 && b[3] == 0x06 && b[4] == 0x06 {
                onBattery(Int(b[5]), nil)
            }
        case 0x04: // Hub Attached I/O (porty zewnętrzne mają ID 0–3)
            guard port < 4 else { return }
            lastPower[port] = nil
            positions[port] = nil
            if port == servoPort {
                servoZero = nil
                lastTarget = nil
            }
            if b[4] == 0x01, b.count >= 7 {
                let type = UInt16(b[5]) | (UInt16(b[6]) << 8)
                deviceTypes[port] = type
                onLog("Port \(port + 1): urządzenie typu \(type)")
                if LegoSpec.encoderMotorTypes.contains(type) {
                    // Port Input Format Setup: tryb 2 (POS), delta 1, powiadomienia włączone
                    send([0x41, UInt8(port), 0x02, 0x01, 0x00, 0x00, 0x00, 0x01])
                }
            } else if b[4] == 0x00 {
                deviceTypes[port] = nil
                onLog("Port \(port + 1): odłączono")
            }
        case 0x45: // Port Value (pozycja enkodera Int32)
            guard port < 4, b.count >= 8 else { return }
            let raw = (0..<4).reduce(UInt32(0)) { $0 | (UInt32(b[4 + $1]) << (8 * $1)) }
            positions[port] = Int32(bitPattern: raw)
        case 0x05: // Generic Error
            onLog("Hub zgłosił błąd komendy \(b[3]): kod \(b[4])")
        default:
            break
        }
    }

    func send(power: [Int8], servoPort newServoPort: Int?, servoOffsetDeg: Int, force: Bool) {
        if newServoPort != servoPort {
            servoPort = newServoPort
            servoZero = nil
            lastTarget = nil
            lastPower.removeAll()
        }

        for (port, type) in deviceTypes where port < power.count {
            if port == servoPort && LegoSpec.encoderMotorTypes.contains(type) {
                // Czekamy na pierwszy odczyt pozycji, zanim ruszymy serwo
                guard let position = positions[port] else { continue }
                if servoZero == nil {
                    servoZero = position
                    onServoZero(Int(position))
                    onLog("Serwo gotowe na porcie \(port + 1)")
                }
                let target = (servoZero ?? position) &+ Int32(servoOffsetDeg)
                if force || target != lastTarget {
                    lastTarget = target
                    lastPower[port] = nil
                    // GotoAbsolutePosition: pozycja, prędkość 100, moc 100, trzymaj (126), bez profilu
                    send([0x81, UInt8(port), 0x11, 0x0D] + int32LE(target) + [100, 100, 126, 0x00])
                }
            } else {
                let percent = Int8((Double(power[port]) * 100.0 / 127.0).rounded())
                if force || lastPower[port] != percent {
                    lastPower[port] = percent
                    // WriteDirectModeData, tryb 0 = moc silnika / jasność świateł
                    send([0x81, UInt8(port), 0x11, 0x51, 0x00, UInt8(bitPattern: percent)])
                }
            }
        }
    }

    func recaptureZero() {
        guard let port = servoPort, let position = positions[port] else {
            onLog("Brak odczytu pozycji serwa")
            return
        }
        servoZero = position
        lastTarget = nil
        onServoZero(Int(position))
    }

    func writeCompleted() {}

    /// Liczba portów na podstawie typu systemu z rozgłoszenia BLE
    func configure(systemType: UInt8?) {
        onPortCount(systemType == 0x41 ? 2 : 4)
    }
}

// MARK: - Pybricks (wymaga programu pybricks/buwizzpad_hub.py na hubie)

final class PybricksHubDriver: HubDriver {
    let charUUID = PybricksSpec.charUUID
    var onLog: (String) -> Void = { _ in }
    var onPortCount: (Int) -> Void = { _ in }
    var onBattery: (Int?, Double?) -> Void = { _, _ in }
    var onServoZero: (Int) -> Void = { _ in }
    var onState: (String) -> Void = { _ in }
    var write: ([UInt8]) -> Void = { _ in }

    private var programReady = false
    private var writePending = false
    private var recaptureRequested = false
    private var stdoutLine = ""

    func start() {
        onState("Uruchom program BuWizzPad na hubie")
    }

    /// Komenda 0x01: start programu zapisanego na hubie
    func startProgram() {
        write([0x01])
    }

    func handle(_ data: Data) {
        let b = [UInt8](data)
        guard let event = b.first else { return }

        if event == 0x00, b.count >= 5 {
            // Raport statusu: bit 6 = program działa
            if b[1] & (1 << 6) == 0 && programReady {
                programReady = false
                writePending = false
                onState("Program na hubie zatrzymany")
            }
        } else if event == 0x01 {
            for byte in b.dropFirst() {
                if byte == 10 {
                    handleLine(stdoutLine.trimmingCharacters(in: .whitespacesAndNewlines))
                    stdoutLine = ""
                } else if stdoutLine.count < 120 {
                    stdoutLine.append(Character(UnicodeScalar(byte)))
                }
            }
        }
    }

    // Powitanie "BP1,<liczba portów>,<napięcie mV>"
    private func handleLine(_ line: String) {
        let parts = line.split(separator: ",")
        guard parts.count == 3, parts[0] == "BP1",
              let ports = Int(parts[1]), let millivolts = Int(parts[2]) else {
            if !line.isEmpty { onLog("Hub: \(line)") }
            return
        }
        onPortCount(ports)
        onBattery(nil, Double(millivolts) / 1000.0)
        if !programReady {
            programReady = true
            writePending = false
            onState("Gotowy")
            onLog("Program na hubie odpowiada")
        }
    }

    func send(power: [Int8], servoPort: Int?, servoOffsetDeg: Int, force: Bool) {
        // Nie kolejkujemy ramek: nowa idzie dopiero po potwierdzeniu poprzedniej
        guard programReady, force || !writePending else { return }
        writePending = true
        let frame = Self.frame(power: power, servoPort: servoPort,
                               servoOffsetDeg: servoOffsetDeg, recapture: recaptureRequested)
        recaptureRequested = false
        write([0x06] + frame) // 0x06 = zapis na stdin
    }

    // Format opisany w pybricks/buwizzpad_hub.py
    static func frame(power: [Int8], servoPort: Int?, servoOffsetDeg: Int, recapture: Bool) -> [UInt8] {
        var chars: [UInt8] = (0..<6).map { i -> UInt8 in
            let value = i < power.count ? Double(power[i]) : 0
            let q = max(-45, min(45, Int((value * 45.0 / 127.0).rounded())))
            return UInt8(80 + q)
        }
        if let port = servoPort, (0..<6).contains(port) {
            chars.append(UInt8(48 + port))
        } else {
            chars.append(UInt8(ascii: "-"))
        }
        let angle = max(-180, min(180, servoOffsetDeg)) + 180
        chars.append(UInt8(48 + angle / 20))
        chars.append(UInt8(48 + angle % 20))
        chars.append(UInt8(ascii: recapture ? "1" : "0"))
        let sum = chars.reduce(0) { $0 + Int($1) }
        chars.append(UInt8(48 + sum % 64))
        chars.append(10)
        return chars
    }

    func recaptureZero() {
        recaptureRequested = true
        onServoZero(0)
    }

    func writeCompleted() {
        writePending = false
    }
}
