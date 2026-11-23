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

                Section("Port serwa i kalibracja") {
                    Picker("Port serwa", selection: $ctrl.servoPortIndex) {
                        ForEach(0..<6, id: \.self) { idx in
                            Text("Port \(idx + 1)").tag(idx)
                        }
                    }

                    Picker("Tryb serwa", selection: $ctrl.servoProtocolMode) {
                        ForEach(ServoProtocolMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(format: "Powrót na środek: %.0f%%", ctrl.profile.returnToCenterSmoothing * 100))
                            .font(.caption.monospacedDigit())
                        Slider(value: $ctrl.profile.returnToCenterSmoothing, in: 0.1...1.0, step: 0.05)
                    }

                    Text(ctrl.calibrationStatus)
                        .font(.footnote.bold())

                    Text(String(
                        format: "Lewo: %.2f  |  Środek: %+.2f  |  Prawo: %+.2f",
                        ctrl.profile.leftLimit,
                        ctrl.profile.centerOffset,
                        ctrl.profile.rightLimit
                    ))
                    .font(.footnote.monospacedDigit())

                    // Korekta krokowa -0.05 / +0.05 dla każdego punktu
                    HStack {
                        Text("Lewo:")
                            .font(.caption.monospaced())
                        Button("-0.05") { ctrl.nudgeLeftLimit(by: -0.05) }
                        Button("+0.05") { ctrl.nudgeLeftLimit(by: 0.05) }
                        Spacer()
                        Button("Z gałki") { ctrl.setLeftLimitFromCurrentServoStick() }
                    }
                    .buttonStyle(.bordered)
                    .font(.caption)

                    HStack {
                        Text("Środek:")
                            .font(.caption.monospaced())
                        Button("-0.05") { ctrl.nudgeCenter(by: -0.05) }
                        Button("+0.05") { ctrl.nudgeCenter(by: 0.05) }
                        Spacer()
                        Button("Z gałki") { ctrl.setCenterFromCurrentServoStick() }
                    }
                    .buttonStyle(.bordered)
                    .font(.caption)

                    HStack {
                        Text("Prawo:")
                            .font(.caption.monospaced())
                        Button("-0.05") { ctrl.nudgeRightLimit(by: -0.05) }
                        Button("+0.05") { ctrl.nudgeRightLimit(by: 0.05) }
                        Spacer()
                        Button("Z gałki") { ctrl.setRightLimitFromCurrentServoStick() }
                    }
                    .buttonStyle(.bordered)
                    .font(.caption)

                    HStack {
                        if ctrl.autoCalibrating {
                            Button("Złap Lewo") {
                                ctrl.captureCurrentSweepLeft()
                            }
                            .buttonStyle(.borderedProminent)

                            Button("Złap Prawo") {
                                ctrl.captureCurrentSweepRight()
                            }
                            .buttonStyle(.borderedProminent)

                            Button("Anuluj", role: .destructive) {
                                ctrl.cancelAutoServoCalibration()
                            }
                            .buttonStyle(.bordered)
                        } else {
                            Button("Auto-kalibracja") {
                                ctrl.startAutoServoCalibration()
                            }
                            .buttonStyle(.borderedProminent)

                            Button("Reset (-1/+1)") {
                                ctrl.resetProfile()
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }

                Section("Porty (1–6), tryby i limit mocy") {
                    ForEach($ctrl.ports) { $port in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(port.title)
                                    .font(.headline)
                                if port.portIndex == ctrl.servoPortIndex {
                                    Text("SERWO")
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
