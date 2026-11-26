import SwiftUI

@main
struct BuWizzPadApp: App {
    var body: some Scene {
        WindowGroup {
            MainDriveView()
        }
    }
}

private func batteryText(_ hub: HubSession) -> String {
    if let percent = hub.batteryPercent {
        return "\(percent)%"
    }
    if let v = hub.batteryVoltage {
        return String(format: hub.isCharging ? "Ładowanie (%.2f V)" : "%.2f V", v)
    }
    if let lvl = hub.batteryLevelCode {
        return "Poziom \(lvl)/3"
    }
    return "Brak danych"
}

struct MainDriveView: View {
    @StateObject private var ctrl = BuWizzController()
    @StateObject private var camera = CameraReceiver()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            List {
                Section("Połączenie") {
                    LabeledContent("Status", value: ctrl.isScanning ? "Szukam hubów..." : ctrl.bluetoothState)
                    LabeledContent("Pad", value: ctrl.hasPad ? (ctrl.padLightSupported ? "Pad + dioda LED" : "Wykryty") : "Brak")
                    HStack {
                        Button("Skanuj i połącz") {
                            ctrl.scanAndConnect()
                        }
                        .buttonStyle(.borderedProminent)

                        Spacer()

                        Button("Rozłącz wszystkie", role: .destructive) {
                            ctrl.disconnectAll()
                        }
                        .buttonStyle(.bordered)
                        .disabled(ctrl.sessions.isEmpty)
                    }
                    Button("STOP wszystkie silniki", role: .destructive) {
                        ctrl.stopAll()
                    }
                    .disabled(ctrl.sessions.isEmpty)
                }

                Section {
                    NavigationLink("Kamera z auta") {
                        CameraView(camera: camera)
                    }
                }

                Section("Połączone huby (\(ctrl.sessions.count))") {
                    if ctrl.sessions.isEmpty {
                        Text("Włącz huby i naciśnij „Skanuj i połącz”.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(ctrl.sessions) { hub in
                        NavigationLink {
                            HubDetailView(ctrl: ctrl, hub: hub)
                        } label: {
                            HubRow(hub: hub)
                        }
                    }
                }

                let available = ctrl.discoveredDevices.filter { !ctrl.isInUse($0) }
                if !available.isEmpty {
                    Section("Wykryte urządzenia BLE (dotknij, aby dodać)") {
                        ForEach(available) { dev in
                            Button {
                                ctrl.connect(to: dev)
                            } label: {
                                HStack {
                                    Text(dev.kind == .buwizz ? dev.name : "\(dev.name) (\(dev.kind.title))")
                                    Spacer()
                                    Text("\(dev.rssi) dBm")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                Section("Telemetria i logi") {
                    Text(String(
                        format: "L: (%+.2f, %+.2f) | P: (%+.2f, %+.2f)",
                        ctrl.leftStickX, ctrl.leftStickY, ctrl.rightStickX, ctrl.rightStickY
                    ))
                    .font(.caption.monospaced())

                    ForEach(Array(ctrl.logs.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption2.monospaced())
                    }
                }
            }
            .navigationTitle("BuWizzPad")
        }
        .onChange(of: scenePhase) { phase in
            // iOS usypia aplikację w tle, więc najpierw zatrzymujemy silniki
            if phase != .active {
                ctrl.stopAll()
            }
        }
    }
}

struct HubRow: View {
    @ObservedObject var hub: HubSession

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(hub.displayName)
                .font(.headline)
            Text("\(hub.connectionState) · \(batteryText(hub))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct FunctionRow: View {
    let name: String
    @Binding var setting: FunctionSetting
    let onRun: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(name)
                    .font(.headline)
                Spacer()
                Toggle("Aktywna", isOn: $setting.enabled)
                    .labelsHidden()
                Text("Aktywna")
                    .font(.caption)
            }

            Picker("Sterowanie", selection: $setting.source) {
                ForEach(PadInputSource.allCases) { src in
                    Text(src.rawValue).tag(src)
                }
            }
            .disabled(!setting.enabled)

            HStack {
                if !setting.enabled {
                    Text("Wyłączona ze sterowania")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Uruchom teraz") {
                    onRun()
                }
                .buttonStyle(.bordered)
                .font(.caption)
                .disabled(!setting.enabled)
            }
        }
        .padding(.vertical, 4)
    }
}

struct HubDetailView: View {
    let ctrl: BuWizzController
    @ObservedObject var hub: HubSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
            List {
                Section("Hub") {
                    TextField("Własna nazwa (np. Wywrotka)", text: $hub.nickname)
                    LabeledContent("Status", value: hub.connectionState)
                    LabeledContent("Typ", value: hub.hubKind.title)
                    LabeledContent("Bateria", value: batteryText(hub))
                    if hub.isConnected && hub.hubKind == .pybricks {
                        Button("Uruchom program na hubie") {
                            hub.startPybricksProgram()
                        }
                        .buttonStyle(.bordered)
                    }
                    HStack {
                        Button("Ponów usługi") {
                            hub.retryDiscoverServices()
                        }
                        .buttonStyle(.bordered)

                        Spacer()

                        Button("Rozłącz", role: .destructive) {
                            ctrl.disconnect(hub)
                            dismiss()
                        }
                        .buttonStyle(.bordered)
                    }
                }

                Section("Serwo PU Pozycja (punkt 0 po połączeniu)") {
                    Picker("Port serwa", selection: $hub.servoPortIndex) {
                        Text("Brak serwa").tag(-1)
                        ForEach(0..<(hub.hubKind == .buwizz ? 4 : hub.portCount), id: \.self) { idx in
                            Text("Port \(idx + 1)").tag(idx)
                        }
                    }

                    LabeledContent("Punkt 0 po połączeniu", value: "\(hub.initialServoZeroAngleDeg)°")
                    LabeledContent("Aktualna pozycja", value: "\(hub.servoAngleDegPreview)°")

                    Button("Ustaw obecne jako 0") {
                        hub.recaptureCurrentServoAsZero()
                    }
                    .buttonStyle(.bordered)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(format: "Martwa strefa (powrót do 0): %.0f%%", hub.deadzone * 100))
                            .font(.caption.monospacedDigit())
                        Slider(value: $hub.deadzone, in: 0.0...0.35, step: 0.02)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(format: "Zakres kąta PU: ±%.0f°", hub.maxAngleDegrees))
                            .font(.caption.monospacedDigit())
                        Slider(value: $hub.maxAngleDegrees, in: 30...180, step: 5)
                    }

                    Text("Po połączeniu apka wyznacza początkową pozycję jako 0 i po każdym skręcie wraca do tej pozycji.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Porty (A = 1, B = 2 …), tryby i limit mocy") {
                    ForEach($hub.ports) { $port in
                        if port.portIndex < hub.portCount {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(port.title)
                                    .font(.headline)
                                if port.portIndex == hub.servoPortIndex {
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
                                    let isOn = hub.lightLatched[port.portIndex]
                                    Text("Światło przednie: \(isOn ? "WŁĄCZONE" : "WYŁĄCZONE")")
                                        .font(.caption.bold())
                                    Spacer()
                                    Button(isOn ? "Wyłącz" : "Włącz") {
                                        hub.togglePortLatchManually(portIndex: port.portIndex)
                                    }
                                    .buttonStyle(.bordered)
                                    .font(.caption)
                                }
                            } else if port.mode == .indicator {
                                HStack {
                                    let isOn = hub.indicatorLatched[port.portIndex]
                                    Text("Kierunkowskaz: \(isOn ? "MIGA" : "WYŁĄCZONY")")
                                        .font(.caption.bold())
                                    Spacer()
                                    Button(isOn ? "Wyłącz" : "Włącz") {
                                        hub.togglePortLatchManually(portIndex: port.portIndex)
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
                }

                if hub.hubKind == .pybricks && !hub.hubFunctions.isEmpty {
                    Section("Funkcje z programu na hubie") {
                        ForEach(Array(hub.hubFunctions.enumerated()), id: \.offset) { _, name in
                            FunctionRow(
                                name: name,
                                setting: Binding(
                                    get: { hub.functionSettings[name] ?? FunctionSetting() },
                                    set: { hub.functionSettings[name] = $0 }
                                ),
                                onRun: { hub.callFunction(named: name) }
                            )
                        }

                        Text("Funkcja uruchamia się raz po naciśnięciu przypisanego przycisku (gałka: po wychyleniu powyżej 50%). Lista odświeża się sama po wgraniu zmienionego programu.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Telemetria") {
                    Text("Kanały 1–6: " + hub.channelValuesPreview.map { String($0) }.joined(separator: ", "))
                        .font(.caption.monospaced())

                    Text("Ramka: \(hub.lastFrameHex)")
                        .font(.caption.monospaced())
                }
            }
            .navigationTitle(hub.displayName)
    }
}
