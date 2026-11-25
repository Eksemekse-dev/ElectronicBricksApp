import SwiftUI

@main
struct BuWizzPadApp: App {
    var body: some Scene {
        WindowGroup {
            MainDriveView()
        }
    }
}

struct MainDriveView: View {
    @StateObject private var ctrl = BuWizzController()

    private var batterySummaryText: String {
        if ctrl.isCharging {
            if let v = ctrl.batteryVoltage {
                return String(format: "Ładowanie – pulsuje (%.2f V)", v)
            }
            return "Ładowanie – pulsuje"
        }
        if let v = ctrl.batteryVoltage {
            return String(format: "%.2f V", v)
        }
        if let lvl = ctrl.batteryLevelCode {
            return "Poziom \(lvl)/3"
        }
        return "Brak danych"
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Połączenie i Bateria (Dioda PS4)") {
                    LabeledContent("Status", value: ctrl.connectionState)
                    LabeledContent("Pad", value: ctrl.hasPad ? (ctrl.padLightSupported ? "Pad + dioda LED" : "Wykryty") : "Brak")
                    LabeledContent("Bateria BuWizz3", value: batterySummaryText)
                    HStack {
                        Button("Skanuj i połącz") {
                            ctrl.scanAndConnect()
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Ponów usługi") {
                            ctrl.retryDiscoverServices()
                        }
                        .buttonStyle(.bordered)

                        Spacer()

                        Button("Rozłącz", role: .destructive) {
                            ctrl.disconnect()
                        }
                        .buttonStyle(.bordered)
                        .disabled(ctrl.connectionState == "Rozłączono")
                    }
                }

                Section("Serwo PU Pozycja (punkt 0 po połączeniu)") {
                    Picker("Port serwa", selection: $ctrl.servoPortIndex) {
                        ForEach(0..<4, id: \.self) { idx in
                            Text("Port \(idx + 1)").tag(idx)
                        }
                    }

                    LabeledContent("Punkt 0 po połączeniu", value: "\(ctrl.initialServoZeroAngleDeg)°")
                    LabeledContent("Aktualna pozycja", value: "\(ctrl.servoAngleDegPreview)°")

                    Button("Ustaw obecne jako 0") {
                        ctrl.recaptureCurrentServoAsZero()
                    }
                    .buttonStyle(.bordered)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(format: "Martwa strefa (powrót do 0): %.0f%%", ctrl.deadzone * 100))
                            .font(.caption.monospacedDigit())
                        Slider(value: $ctrl.deadzone, in: 0.0...0.35, step: 0.02)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(format: "Zakres kąta PU: ±%.0f°", ctrl.maxAngleDegrees))
                            .font(.caption.monospacedDigit())
                        Slider(value: $ctrl.maxAngleDegrees, in: 30...180, step: 5)
                    }

                    Text("Po połączeniu apka wyznacza początkową pozycję jako 0 i po każdym skręcie wraca do tej pozycji.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Porty (1–6), tryby i limit mocy") {
                    ForEach($ctrl.ports) { $port in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(port.title)
                                    .font(.headline)
                                if port.portIndex == ctrl.servoPortIndex {
                                    Text("PU SERWO -> 0")
                                        .font(.caption2.bold())
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.blue.opacity(0.15))
                                        .cornerRadius(4)
                                }
                                Spacer()
                                Toggle("Odwróć", isOn: $port.invert)
                                    .labelsHidden()
                                Text("Odwróć")
                                    .font(.caption)
                            }

                            Picker("Tryb pracy", selection: $port.mode) {
                                ForEach(PortOperatingMode.allCases) { m in
                                    Text(m.rawValue).tag(m)
                                }
                            }

                            Picker("Sterowanie", selection: $port.source) {
                                ForEach(PadInputSource.allCases) { src in
                                    Text(src.rawValue).tag(src)
                                }
                            }

                            if port.mode == .frontLight {
                                HStack {
                                    let isOn = ctrl.lightLatched[port.portIndex]
                                    Text("Światło przednie: \(isOn ? "WŁĄCZONE" : "WYŁĄCZONE")")
                                        .font(.caption.bold())
                                    Spacer()
                                    Button(isOn ? "Wyłącz" : "Włącz") {
                                        ctrl.togglePortLatchManually(portIndex: port.portIndex)
                                    }
                                    .buttonStyle(.bordered)
                                    .font(.caption)
                                }
                            } else if port.mode == .indicator {
                                HStack {
                                    let isOn = ctrl.indicatorLatched[port.portIndex]
                                    Text("Kierunkowskaz: \(isOn ? "MIGA" : "WYŁĄCZONY")")
                                        .font(.caption.bold())
                                    Spacer()
                                    Button(isOn ? "Wyłącz" : "Włącz") {
                                        ctrl.togglePortLatchManually(portIndex: port.portIndex)
                                    }
                                    .buttonStyle(.bordered)
                                    .font(.caption)
                                }
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text(String(format: "Limit mocy: %.0f%%", port.powerLimitPercent))
                                    .font(.caption.monospacedDigit())
                                Slider(value: $port.powerLimitPercent, in: 0...100, step: 5)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section("Telemetria i logi") {
                    Text(String(
                        format: "L: (%+.2f, %+.2f) | P: (%+.2f, %+.2f)",
                        ctrl.leftStickX, ctrl.leftStickY, ctrl.rightStickX, ctrl.rightStickY
                    ))
                    .font(.caption.monospaced())

                    Text("Kanały 1–6: " + ctrl.channelValuesPreview.map { String($0) }.joined(separator: ", "))
                        .font(.caption.monospaced())

                    Text("Ramka: \(ctrl.lastFrameHex)")
                        .font(.caption.monospaced())

                    ForEach(ctrl.logs, id: \.self) { line in
                        Text(line)
                            .font(.caption2.monospaced())
                    }
                }

                if !ctrl.discoveredDevices.isEmpty {
                    Section("Wykryte urządzenia BLE") {
                        ForEach(ctrl.discoveredDevices) { dev in
                            Button {
                                ctrl.connect(to: dev)
                            } label: {
                                HStack {
                                    Text(dev.name)
                                    Spacer()
                                    Text("\(dev.rssi) dBm")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("BuWizzPad")
        }
    }
}
