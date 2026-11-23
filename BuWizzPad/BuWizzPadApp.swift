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

    var body: some View {
        NavigationStack {
            List {
                Section("Połączenie") {
                    LabeledContent("Status", value: ctrl.connectionState)
                    LabeledContent("Pad", value: ctrl.hasPad ? "Wykryty" : "Brak")
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

                    Text(ctrl.calibrationStatus)
                        .font(.footnote.bold())

                    Text(String(
                        format: "Lewo: %.2f  |  Środek: %.2f  |  Prawo: %.2f",
                        ctrl.profile.leftLimit,
                        ctrl.profile.centerOffset,
                        ctrl.profile.rightLimit
                    ))
                    .font(.footnote.monospacedDigit())

                    HStack {
                        if ctrl.autoCalibrating {
                            Button("Anuluj auto", role: .destructive) {
                                ctrl.cancelAutoServoCalibration()
                            }
                            .buttonStyle(.borderedProminent)
                        } else {
                            Button("Auto-kalibracja") {
                                ctrl.startAutoServoCalibration()
                            }
                            .buttonStyle(.borderedProminent)
                        }

                        Button("Reset") {
                            ctrl.resetProfile()
                        }
                        .buttonStyle(.bordered)
                    }

                    HStack {
                        Button("Ręcz. Lewo") { ctrl.setLeftLimitFromCurrentServoStick() }
                        Button("Środek") { ctrl.setCenterFromCurrentServoStick() }
                        Button("Ręcz. Prawo") { ctrl.setRightLimitFromCurrentServoStick() }
                    }
                    .buttonStyle(.bordered)
                    .font(.caption)
                }

                Section("Przypisanie portów (1–6) i limit mocy") {
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

                            Picker("Sterowanie", selection: $port.source) {
                                ForEach(PadInputSource.allCases) { src in
                                    Text(src.rawValue).tag(src)
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
