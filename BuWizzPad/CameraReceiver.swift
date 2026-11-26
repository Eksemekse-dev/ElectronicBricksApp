import SwiftUI
import UIKit
import CoreBluetooth

enum CameraSpec {
    static let service = CBUUID(string: "7A1C0001-5B0A-4F6E-9D3A-0C5A11CA3E01")
    static let psmCharacteristic = CBUUID(string: "7A1C0002-5B0A-4F6E-9D3A-0C5A11CA3E01")
    static let dataCharacteristic = CBUUID(string: "7A1C0003-5B0A-4F6E-9D3A-0C5A11CA3E01")
    static let wifiPort = 8080
}

enum CameraMode: String, CaseIterable, Identifiable {
    case wifi = "Wi-Fi"
    case ble = "Bluetooth"

    var id: String { rawValue }
}

/// Odbiera obraz z aplikacji CarCam na Androidzie: po Wi-Fi (HTTP) albo po Bluetooth (kanał L2CAP).
final class CameraReceiver: NSObject, ObservableObject {
    @Published var mode: CameraMode = CameraMode(rawValue: UserDefaults.standard.string(forKey: "Camera.mode") ?? "") ?? .wifi {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: "Camera.mode")
            if oldValue != mode { stop() }
        }
    }
    @Published var host: String = UserDefaults.standard.string(forKey: "Camera.host") ?? "192.168.43.1" {
        didSet { UserDefaults.standard.set(host, forKey: "Camera.host") }
    }
    @Published var image: UIImage?
    @Published var status = "Zatrzymano"
    @Published var fps = 0
    @Published var isRunning = false

    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var channel: CBL2CAPChannel?
    private var dataCharacteristic: CBCharacteristic?
    private var buffer = Data()
    private var frameCount = 0
    private var fpsTimer: Timer?

    // MARK: - Start / stop

    func start() {
        stop()
        isRunning = true
        image = nil
        frameCount = 0
        fpsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.fps = self.frameCount
            self.frameCount = 0
        }
        switch mode {
        case .wifi: startWifi()
        case .ble: startBLE()
        }
    }

    func stop() {
        isRunning = false
        fpsTimer?.invalidate()
        fpsTimer = nil
        task?.cancel()
        task = nil
        session?.invalidateAndCancel()
        session = nil
        central?.stopScan()
        closeChannel()
        if let p = peripheral {
            central?.cancelPeripheralConnection(p)
        }
        peripheral = nil
        dataCharacteristic = nil
        buffer.removeAll()
        fps = 0
        status = "Zatrzymano"
    }

    private func show(_ jpeg: Data) {
        guard let picture = UIImage(data: jpeg) else { return }
        image = picture
        frameCount += 1
        if status != "Odbieram obraz" {
            status = "Odbieram obraz"
        }
    }

    // MARK: - Wi-Fi

    private func startWifi() {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let url = URL(string: "http://\(trimmed):\(CameraSpec.wifiPort)/raw") else {
            status = "Zły adres"
            isRunning = false
            return
        }
        status = "Łączę z \(trimmed)..."
        buffer.removeAll()

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 24 * 3600
        let newSession = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        session?.invalidateAndCancel()
        session = newSession
        task = newSession.dataTask(with: url)
        task?.resume()
    }

    /// Strumień: [nagłówki części z Content-Length] [JPEG] ...
    private func parseStream() {
        let separator = Data([13, 10, 13, 10])
        while let headerEnd = buffer.range(of: separator) {
            let header = String(decoding: buffer.subdata(in: 0..<headerEnd.lowerBound), as: UTF8.self)
            guard let label = header.range(of: "Content-Length:", options: .caseInsensitive) else {
                // Nagłówek odpowiedzi HTTP, bez obrazu
                buffer.removeSubrange(0..<headerEnd.upperBound)
                continue
            }
            let digits = header[label.upperBound...]
                .prefix { $0 == " " || $0.isNumber }
                .trimmingCharacters(in: .whitespaces)
            guard let length = Int(digits), length > 0, length < 4_000_000 else {
                buffer.removeAll()
                return
            }
            let bodyEnd = headerEnd.upperBound + length
            guard buffer.count >= bodyEnd else { return }
            show(buffer.subdata(in: headerEnd.upperBound..<bodyEnd))
            buffer.removeSubrange(0..<bodyEnd)
        }
        if buffer.count > 4_000_000 {
            buffer.removeAll()
        }
    }

    // MARK: - Bluetooth

    private func startBLE() {
        status = "Szukam kamery..."
        buffer.removeAll()
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main)
        } else {
            beginScan()
        }
    }

    private func beginScan() {
        guard isRunning, mode == .ble, let central = central, central.state == .poweredOn else { return }
        status = "Szukam kamery..."
        central.scanForPeripherals(withServices: [CameraSpec.service], options: nil)
    }

    private func retryBLE() {
        guard isRunning, mode == .ble else { return }
        status = "Połączenie przerwane, ponawiam..."
        peripheral = nil
        dataCharacteristic = nil
        buffer.removeAll()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.beginScan()
        }
    }

    private func closeChannel() {
        guard let channel = channel else { return }
        for stream in [channel.inputStream as Stream, channel.outputStream as Stream] {
            stream.delegate = nil
            stream.close()
            stream.remove(from: .main, forMode: .default)
        }
        self.channel = nil
    }

    /// Ramki: 4 bajty długości (little-endian) + JPEG
    private func parseBLE() {
        while buffer.count >= 4 {
            let length = Int(buffer[0]) | (Int(buffer[1]) << 8) | (Int(buffer[2]) << 16) | (Int(buffer[3]) << 24)
            if length <= 0 || length > 1_000_000 {
                buffer.removeAll()
                return
            }
            guard buffer.count >= 4 + length else { return }
            show(buffer.subdata(in: 4..<(4 + length)))
            buffer.removeSubrange(0..<(4 + length))
        }
    }
}

// MARK: - Wi-Fi: delegat sesji

extension CameraReceiver: URLSessionDataDelegate {
    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard dataTask === task else { return }
        buffer.append(data)
        parseStream()
    }

    func urlSession(_ session: URLSession, task finished: URLSessionTask, didCompleteWithError error: Error?) {
        guard finished === task, isRunning, mode == .wifi else { return }
        status = "Połączenie przerwane, ponawiam..."
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self = self, self.isRunning, self.mode == .wifi else { return }
            self.startWifi()
        }
    }
}

// MARK: - Bluetooth: delegaty

extension CameraReceiver: CBCentralManagerDelegate, CBPeripheralDelegate, StreamDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            beginScan()
        } else if isRunning && mode == .ble {
            status = "Bluetooth niedostępny"
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        status = "Łączę z kamerą..."
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        status = "Pobieram kanał obrazu..."
        peripheral.discoverServices([CameraSpec.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        retryBLE()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral === self.peripheral else { return }
        closeChannel()
        retryBLE()
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == CameraSpec.service }) else {
            status = "Brak usługi kamery"
            return
        }
        peripheral.discoverCharacteristics([CameraSpec.psmCharacteristic, CameraSpec.dataCharacteristic], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristic = service.characteristics?.first(where: { $0.uuid == CameraSpec.psmCharacteristic }) else {
            status = "Brak kanału obrazu"
            return
        }
        dataCharacteristic = service.characteristics?.first(where: { $0.uuid == CameraSpec.dataCharacteristic })
        peripheral.readValue(for: characteristic)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let value = characteristic.value else { return }

        if characteristic.uuid == CameraSpec.dataCharacteristic {
            // Tryb powiadomień (starszy Android): kawałki ramki
            buffer.append(value)
            parseBLE()
            return
        }

        guard characteristic.uuid == CameraSpec.psmCharacteristic, value.count >= 2 else { return }
        let psmValue = UInt16(value[0]) | (UInt16(value[1]) << 8)
        if psmValue > 0 {
            status = "Otwieram kanał obrazu..."
            peripheral.openL2CAPChannel(CBL2CAPPSM(psmValue))
        } else if let data = dataCharacteristic {
            // Telefon bez L2CAP: odbieramy obraz w powiadomieniach GATT
            status = "Czekam na pierwszą klatkę (wolniejszy tryb)..."
            peripheral.setNotifyValue(true, for: data)
        } else {
            status = "Telefon nie udostępnia kanału obrazu"
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
        guard let channel = channel, error == nil else {
            status = "Nie udało się otworzyć kanału"
            if let p = self.peripheral {
                central?.cancelPeripheralConnection(p)
            }
            return
        }
        self.channel = channel
        channel.inputStream.delegate = self
        channel.inputStream.schedule(in: .main, forMode: .default)
        channel.outputStream.schedule(in: .main, forMode: .default)
        channel.inputStream.open()
        channel.outputStream.open()
        status = "Czekam na pierwszą klatkę..."
    }

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .hasBytesAvailable:
            guard let input = aStream as? InputStream else { return }
            var chunk = [UInt8](repeating: 0, count: 4096)
            while input.hasBytesAvailable {
                let count = input.read(&chunk, maxLength: chunk.count)
                if count <= 0 { break }
                buffer.append(chunk, count: count)
            }
            parseBLE()
        case .endEncountered, .errorOccurred:
            closeChannel()
            if let p = peripheral {
                central?.cancelPeripheralConnection(p)
            }
        default:
            break
        }
    }
}

// MARK: - Widok

struct CameraView: View {
    @ObservedObject var camera: CameraReceiver

    var body: some View {
        VStack(spacing: 12) {
            Picker("Połączenie", selection: $camera.mode) {
                ForEach(CameraMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if camera.mode == .wifi {
                TextField("Adres telefonu w aucie (np. 192.168.43.1)", text: $camera.host)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.numbersAndPunctuation)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Text("Połącz iPhone'a z hotspotem telefonu w aucie. Adres pokaże aplikacja CarCam.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Bluetooth daje mały obraz i kilka klatek na sekundę, ale nie wymaga Wi-Fi.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ZStack {
                Color.black
                if let image = camera.image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    Text("Brak obrazu")
                        .foregroundStyle(.secondary)
                }
            }
            .aspectRatio(4.0 / 3.0, contentMode: .fit)

            Text("\(camera.status) · \(camera.fps) kl./s")
                .font(.caption.monospacedDigit())

            Button(camera.isRunning ? "Stop" : "Start") {
                if camera.isRunning {
                    camera.stop()
                } else {
                    camera.start()
                }
            }
            .buttonStyle(.borderedProminent)

            Spacer()
        }
        .padding()
        .navigationTitle("Kamera z auta")
    }
}
