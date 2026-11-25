# ElectronicBricksApp

BuWizzPad: sterowanie klockami z iPhone'a za pomocą pada przez Bluetooth.

## Obsługiwane huby

| Hub | Firmware | Uwagi |
|---|---|---|
| BuWizz3 | fabryczny | serwo na portach PU 1–4 |
| City Hub, Technic Hub, Move Hub | LEGO | łączy się bez przygotowań |
| Huby z Pybricks | Pybricks | wymaga programu z `pybricks/` |

Port 1 w aplikacji to port A na hubie, port 2 to B itd.
Serwo wymaga silnika z enkoderem. Pozycja w chwili uruchomienia serwa to punkt 0.
Dla pociągów i modeli bez serwa wybierz "Brak serwa".

Hub LEGO: włącz go zielonym przyciskiem i naciśnij "Skanuj i połącz".

## Kilka hubów naraz

"Skanuj i połącz" przez 10 s dołącza każdy rozpoznany hub. Kolejne skanowanie
dodaje następne. Każdy hub ma własne ustawienia portów i serwa (zapamiętywane),
a jeden pad steruje wszystkimi jednocześnie. Aplikacja nie ogranicza liczby
hubów, ale iPhone i zasięg Bluetooth tak.

## Pybricks - jednorazowe przygotowanie

1. Na komputerze otwórz https://code.pybricks.com i połącz się z hubem.
2. Wgraj `pybricks/buwizzpad_hub.py`, uruchom go, a potem zatrzymaj.
3. Rozłącz Pybricks Code (hub przyjmuje jedno połączenie naraz).
4. W aplikacji naciśnij "Skanuj i połącz", wejdź w hub, a potem "Uruchom program na hubie"
   (albo przycisk na hubie).

Program zatrzymuje silniki, gdy przez 0,5 s nie dostaje komend.

## Własne funkcje w programie Pybricks

W `pybricks/buwizzpad_hub.py`, w sekcji "TWOJE FUNKCJE", dopisz funkcje z dekoratorem
`@pad_function`. Nazwa funkcji (albo tekst podany w dekoratorze) pojawi się w aplikacji
w ekranie huba, w sekcji "Funkcje z programu na hubie", zaraz pod portami:

```python
@pad_function("Otworz drzwi")
def open_door():
    door = device_at("C")
    door.run_angle(300, 90, wait=False)

@pad_function
def blink_hub_light():
    ...
```

Dla każdej funkcji w aplikacji możesz:

- przypisać przycisk pada (albo gałkę, spust, bark) - funkcja uruchamia się raz po naciśnięciu,
- wyłączyć ją ze sterowania przełącznikiem "Aktywna" (ustawienie jest zapamiętywane),
- uruchomić ją ręcznie przyciskiem "Uruchom teraz".

Po zmianie kodu wgraj program ponownie przez Pybricks Code, uruchom go i zatrzymaj, a potem połącz
się aplikacją. Lista funkcji pobiera się z huba, więc odświeża się sama.

Uwagi:

- Na czas działania funkcji program nie czyta komend z aplikacji, więc funkcje powinny być krótkie
  (przy ruchu silnika użyj `wait=False`). Błąd w funkcji trafia do logów aplikacji, a program działa dalej.
- Porty używane w funkcjach ustaw w aplikacji na sterowanie "Brak". Port bez sterowania
  program na hubie zatrzymuje jeden raz i dalej go nie rusza.
- Funkcje działają dopiero z nową wersją programu (powitanie `BP2` z listą funkcji zastąpiło `BP1`).
  Starszy program na hubie nadal steruje silnikami, ale bez funkcji, więc wgraj `buwizzpad_hub.py` ponownie.
