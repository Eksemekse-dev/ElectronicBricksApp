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
