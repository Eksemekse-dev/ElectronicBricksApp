# BuWizzPad - program dla huba z firmware Pybricks.
# Wgraj raz przez https://code.pybricks.com (uruchom, potem zatrzymaj),
# rozlacz Pybricks Code i polacz sie aplikacja BuWizzPad.
#
# WLASNE FUNKCJE: w sekcji "TWOJE FUNKCJE" nizej dopisz funkcje z dekoratorem
# @pad_function. Aplikacja pokaze je obok portow, a Ty przypiszesz do nich
# przycisk pada albo wylaczysz je ze sterowania. Po zmianie kodu wgraj program
# ponownie - lista w aplikacji odswiezy sie sama.
#
# Ramka mocy z aplikacji (11 znakow + "\n"):
#   0-5  moc portow A-F, kod = 80 + q, q w zakresie -45..45,
#        "~" = port niesterowany przez aplikacje (program go nie rusza)
#   6    port serwa: "0".."5" albo "-" (brak)
#   7-8  kat serwa + 180, jako dwie cyfry o podstawie 20 (od "0")
#   9    "1" = ustaw obecna pozycje serwa jako 0, inaczej "0"
#   10   suma kontrolna: 48 + (suma znakow 0-9) % 64
# Wywolanie funkcji (3 znaki + "\n"):
#   0    "F"
#   1    numer funkcji + 48 (kolejnosc z powitania)
#   2    suma kontrolna: 48 + (kod "F" + kod znaku 1) % 64
# Powitanie (co sekunde):
#   BP2,<liczba portow>,<napiecie mV>,<funkcja>;<funkcja>;...
from pybricks.hubs import ThisHub
from pybricks.parameters import Port, Color
from pybricks.pupdevices import Motor, DCMotor, Light
from pybricks.tools import read_input_byte, wait, StopWatch

FRAME_LENGTH = 11
CALL_LENGTH = 3
TIMEOUT_MS = 500  # brak ramek przez ten czas = stop wszystkiego
MAX_FUNCTIONS = 16
MAX_NAME_LENGTH = 24

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
free = [False] * len(devices)  # port zwolniony przez aplikacje


def device_at(port):
    """Urzadzenie na porcie "A".."F" (albo None), do uzycia w funkcjach."""
    index = "ABCDEF".index(port)
    if index >= len(devices):
        return None
    return devices[index][0]


# ---------------------------------------------------------------- funkcje

functions = []  # pary (nazwa, funkcja), numer = pozycja na liscie


def add_function(function, label):
    if len(functions) >= MAX_FUNCTIONS:
        return
    if label is None:
        try:
            label = function.__name__
        except AttributeError:
            label = "funkcja" + str(len(functions) + 1)
    label = str(label).replace(",", " ").replace(";", " ")[:MAX_NAME_LENGTH - 2]
    # Powtorzona nazwa dostaje numer, zeby ustawienia w aplikacji sie nie mieszaly
    unique = label
    number = 2
    while unique in [known for known, _ in functions]:
        unique = label + " " + str(number)
        number += 1
    functions.append((unique, function))


def pad_function(arg=None):
    """@pad_function albo @pad_function("Wlasna nazwa")"""
    if callable(arg):
        add_function(arg, None)
        return arg

    def register(function):
        add_function(function, arg)
        return function

    return register


# ================================================================
# TWOJE FUNKCJE
# Funkcja dziala, gdy nacisniesz przypisany do niej przycisk.
# Na czas jej dzialania program nie czyta nowych komend z aplikacji,
# wiec trzymaj je krotkie (albo uzywaj wait=False przy ruchach silnika).
# Porty uzywane w funkcjach ustaw w aplikacji na sterowanie "Brak",
# inaczej kolejna ramka z aplikacji je zatrzyma.
# ================================================================


@pad_function("Mrugnij swiatlem huba")
def blink_hub_light():
    hub.light.on(Color.GREEN)
    wait(200)
    hub.light.off()


# Przyklad z silnikiem na porcie C:
#
# @pad_function("Otworz drzwi")
# def open_door():
#     door = device_at("C")
#     if door is not None:
#         door.run_angle(300, 90, wait=False)

# ================================================================
# KONIEC TWOICH FUNKCJI
# ================================================================


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
            free[i] = False
            if zeros[i] is None or frame[9] == "1":
                zeros[i] = device.angle()
            device.track_target(zeros[i] + offset)
            continue
        if frame[i] == "~":
            # Port zwolniony: zatrzymaj raz, potem nie ruszaj
            if not free[i]:
                stop(device, kind)
                free[i] = True
            continue
        free[i] = False
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


def call_index(frame):
    """Numer funkcji z poprawnej ramki wywolania albo -1."""
    if len(frame) != CALL_LENGTH or frame[0] != "F":
        return -1
    if ord(frame[2]) != 48 + (ord(frame[0]) + ord(frame[1])) % 64:
        return -1
    return ord(frame[1]) - 48


def run_function(index):
    if index < 0 or index >= len(functions):
        return
    label, function = functions[index]
    try:
        function()
    except Exception as error:
        print("Blad funkcji", label, error, sep=": ")


def hello():
    names = ";".join([label for label, function in functions])
    print("BP2", len(devices), hub.battery.voltage(), names, sep=",")


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
            else:
                index = call_index(buffer)
                if index >= 0:
                    run_function(index)
                    last_frame.reset()
            buffer = ""
        elif len(buffer) <= FRAME_LENGTH:
            buffer += chr(byte)
        byte = read_input_byte()

    if active and last_frame.time() > TIMEOUT_MS:
        stop_all()
        active = False

    # Aplikacja steruje dopiero, gdy zobaczy to powitanie
    if last_hello.time() > 1000:
        hello()
        last_hello.reset()

    wait(10)
