import SwiftUI
import UIKit

struct HubScript: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var code: String
}

/// Skrypty zapisane w telefonie (tylko dla hubów Pybricks)
final class ScriptStore: ObservableObject {
    private static let key = "BuWizzPad.Scripts"

    @Published var scripts: [HubScript] = [] {
        didSet {
            if let data = try? JSONEncoder().encode(scripts) {
                UserDefaults.standard.set(data, forKey: Self.key)
            }
        }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([HubScript].self, from: data) {
            scripts = saved
        } else {
            scripts = [HubScript(name: "Jazda + funkcje", code: ScriptTemplate.drive)]
        }
    }

    func add(name: String, code: String) {
        scripts.append(HubScript(name: name, code: code))
    }
}

enum ScriptTemplate {
    static let loop = """
from pybricks.hubs import ThisHub
from pybricks.parameters import Color
from pybricks.tools import wait

hub = ThisHub()

while True:
    hub.light.on(Color.BLUE)
    wait(500)
    hub.light.on(Color.RED)
    wait(500)
"""

    static let drive = #"""
    # BuWizzPad - skrypt dla huba Pybricks.
    # Wlasne funkcje dopisz w sekcji TWOJE FUNKCJE i przypisz do przyciskow.
    # Nie usuwaj petli na dole, jesli chcesz sterowac padem z aplikacji.
    from pybricks.hubs import ThisHub
    from pybricks.parameters import Port, Color
    from pybricks.pupdevices import Motor, DCMotor, Light
    from pybricks.tools import read_input_byte, wait, StopWatch

    FRAME_LENGTH = 11
    TIMEOUT_MS = 500  # brak ramek przez ten czas = stop wszystkiego

    hub = ThisHub()


    def open_device(port):
        for kind in (Motor, DCMotor, Light):
            try:
                return kind(port), kind
            except OSError:
                pass
        return None, None


    devices = []
    for name in "ABCDEF":
        port = getattr(Port, name, None)
        if port is None:
            break
        devices.append(open_device(port))

    zeros = [None] * len(devices)


    def silnik(litera):
        # silnik("A") zwraca urzadzenie z portu A (albo None)
        return devices["ABCDEF".index(litera)][0]


    def stop(device, kind):
        if kind is Light:
            device.off()
        elif device is not None:
            device.stop()


    def stop_all():
        for device, kind in devices:
            stop(device, kind)


    def apply(frame):
        servo = ord(frame[6]) - 48
        offset = (ord(frame[7]) - 48) * 20 + (ord(frame[8]) - 48) - 180
        for i in range(len(devices)):
            device, kind = devices[i]
            if device is None:
                continue
            if i == servo and kind is Motor:
                if zeros[i] is None or frame[9] == "1":
                    zeros[i] = device.angle()
                device.track_target(zeros[i] + offset)
                continue
            q = ord(frame[i]) - 80
            duty = abs(q) * 100 // 45
            if q < 0:
                duty = -duty
            if duty == 0:
                stop(device, kind)
            elif kind is Light:
                device.on(abs(duty))
            else:
                device.dc(duty)


    # ============ TWOJE FUNKCJE ============

    def trabka():
        hub.light.on(Color.RED)
        wait(300)
        hub.light.on(Color.GREEN)
        print("Funkcja dziala!")


    # Przycisk pada -> funkcja. Dostepne nazwy:
    # A B X Y L1 R1 UP DOWN LEFT RIGHT
    FUNKCJE = {
        "A": trabka,
    }

    # =======================================


    def run(name):
        function = FUNKCJE.get(name)
        if function is None:
            return
        stop_all()  # funkcja dostaje zatrzymany model
        try:
            function()
        except Exception as error:
            print("Blad w funkcji", name, ":", error)


    def valid(frame):
        if len(frame) != FRAME_LENGTH:
            return False
        total = 0
        for i in range(10):
            total += ord(frame[i])
        return ord(frame[10]) == 48 + total % 64


    buffer = ""
    last_frame = StopWatch()
    last_hello = StopWatch()
    active = False

    while True:
        byte = read_input_byte()
        while byte is not None:
            if byte == 10:
                if buffer.startswith("*"):
                    run(buffer[1:])
                    last_frame.reset()
                    last_hello.reset()
                    print("BP1", len(devices), hub.battery.voltage(), sep=",")
                elif valid(buffer):
                    apply(buffer)
                    last_frame.reset()
                    active = True
                buffer = ""
            elif len(buffer) <= FRAME_LENGTH:
                buffer += chr(byte)
            byte = read_input_byte()

        if active and last_frame.time() > TIMEOUT_MS:
            stop_all()
            active = False

        # Aplikacja steruje dopiero, gdy zobaczy to powitanie
        if last_hello.time() > 1000:
            print("BP1", len(devices), hub.battery.voltage(), sep=",")
            last_hello.reset()

        wait(10)
    """#
}

/// Pole na kod: bez autokorekty i bez zamiany cudzysłowów na „drukarskie”
struct CodeEditor: UIViewRepresentable {
    @Binding var text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.spellCheckingType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.text = $text
        if view.text != text {
            view.text = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textViewDidChange(_ textView: UITextView) {
            text.wrappedValue = textView.text
        }
    }
}

struct ScriptListView: View {
    @ObservedObject var ctrl: BuWizzController
    @ObservedObject var store: ScriptStore

    var body: some View {
        List {
            Section("Zapisane skrypty") {
                ForEach(store.scripts) { script in
                    NavigationLink(script.name) {
                        ScriptEditorView(ctrl: ctrl, store: store, scriptID: script.id)
                    }
                }
                .onDelete { store.scripts.remove(atOffsets: $0) }
            }
            Section("Nowy skrypt") {
                Button("Jazda padem + własne funkcje") {
                    store.add(name: "Nowa jazda", code: ScriptTemplate.drive)
                }
                Button("Pętla while True") {
                    store.add(name: "Nowa pętla", code: ScriptTemplate.loop)
                }
                Button("Wklej ze schowka") {
                    store.add(name: "Wklejony skrypt", code: UIPasteboard.general.string ?? "")
                }
            }
        }
        .navigationTitle("Skrypty Pybricks")
    }
}

struct ScriptEditorView: View {
    @ObservedObject var ctrl: BuWizzController
    @ObservedObject var store: ScriptStore
    let scriptID: UUID

    private func binding(_ keyPath: WritableKeyPath<HubScript, String>) -> Binding<String> {
        Binding(
            get: { store.scripts.first { $0.id == scriptID }?[keyPath: keyPath] ?? "" },
            set: { value in
                if let index = store.scripts.firstIndex(where: { $0.id == scriptID }) {
                    store.scripts[index][keyPath: keyPath] = value
                }
            }
        )
    }

    var body: some View {
        VStack(spacing: 8) {
            TextField("Nazwa skryptu", text: binding(\.name))
                .textFieldStyle(.roundedBorder)

            CodeEditor(text: binding(\.code))
                .border(Color.secondary.opacity(0.3))

            let hubs = ctrl.sessions.filter { $0.hubKind == .pybricks }
            if hubs.isEmpty {
                Text("Połącz hub Pybricks, aby uruchomić skrypt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    ForEach(hubs) { hub in
                        ScriptRunPanel(hub: hub, code: binding(\.code).wrappedValue)
                    }
                }
                .frame(maxHeight: 190)
            }
        }
        .padding()
        .navigationTitle("Edytor")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Uruchamianie na jednym hubie i podgląd tego, co hub wypisuje
struct ScriptRunPanel: View {
    @ObservedObject var hub: HubSession
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(hub.displayName)
                    .font(.headline)
                Spacer()
                Button("Uruchom") {
                    hub.runScript(code)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!hub.isConnected)

                Button("Stop", role: .destructive) {
                    hub.stopScript()
                }
                .buttonStyle(.bordered)
                .disabled(!hub.isConnected)
            }
            Text(hub.connectionState)
                .font(.caption)
            ForEach(Array(hub.console.suffix(8).enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.caption2.monospaced())
            }
        }
    }
}
