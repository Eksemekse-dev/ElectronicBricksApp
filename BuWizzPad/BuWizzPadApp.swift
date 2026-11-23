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
                    LabeledContent("BuWizz3", value: ctrl.connectionState)
                    LabeledContent("Pad", value: ctrl.hasPad ? "Wykryty" : "Brak")
                    HStack {
                        Button("Skanuj i połącz") {
                            ctrl.scanAndConnect()
                        }
                        .buttonStyle(.borderedProminent)

                        Spacer()

                        Button("Rozłącz", role: .destructive) {
                            ctrl.disconnect()
                        }
                        .buttonStyle(.bordered)
                        .disabled(!ctrl.isConnected)
                    }
                }

                Section("Kanały silników (1–6)") {
                    Picker("Kanał skrętu", selection: $ctrl.steerChannel) {
                        ForEach(0..<6, id: \.self) { idx in
                            Text("Kanał \(idx + 1)").tag(idx)
                        }
                    }
                    Picker("Kanał gazu", selection: $ctrl.driveChannel) {
                        ForEach(0..<6, id: \.self) { idx in
                            Text("Kanał \(idx + 1)").tag(idx)
                        }
                    }
                }

                Section("Kalibracja skrętu") {
                    Text(String(
                        format: "Lewo: %.2f  |  Środek: %.2f  |  Prawo: %.2f",
                        ctrl.profile.leftLimit,
                        ctrl.profile.centerOffset,
                        ctrl.profile.rightLimit
                    ))
                    .font(.footnote.monospacedDigit())

                    HStack {
                        Button("Max Lewo") { ctrl.setLeftLimitFromPad() }
                        Button("Środek") { ctrl.setCenterFromPad() }
                        Button("Max Prawo") { ctrl.setRightLimitFromPad() }
                    }
                    .buttonStyle(.bordered)

                    Button("Reset kalibracji", role: .destructive) {
                        ctrl.resetProfile()
                    }
                    .font(.footnote)
                }

                Section("Telemetria lokalna") {
                    Text(String(format: "Gałka X: %+.2f | Gałka Y: %+.2f", ctrl.stickX, ctrl.stickY))
                        .font(.footnote.monospaced())
                    Text("Ramka: \(ctrl.lastFrameHex)")
                        .font(.caption.monospaced())
                }
            }
            .navigationTitle("BuWizzPad")
        }
    }
}
