# BuWizzPad - program dla huba z firmware Pybricks.
# Wgraj raz przez https://code.pybricks.com (uruchom, potem zatrzymaj),
# rozlacz Pybricks Code i polacz sie aplikacja BuWizzPad.
#
# Ramka z aplikacji (11 znakow + "\n"):
#   0-5  moc portow A-F, kod = 80 + q, q w zakresie -45..45
#   6    port serwa: "0".."5" albo "-" (brak)
#   7-8  kat serwa + 180, jako dwie cyfry o podstawie 20 (od "0")
#   9    "1" = ustaw obecna pozycje serwa jako 0, inaczej "0"
#   10   suma kontrolna: 48 + (suma znakow 0-9) % 64
from pybricks.hubs import ThisHub
from pybricks.parameters import Port
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
            if valid(buffer):
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
