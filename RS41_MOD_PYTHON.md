# `rs41_mod.py` – rövid dokumentáció

## Áttekintés

Az `rs41_mod.py` egy RS41 rádiószonda GFSK demodulátor és keretjavító program.

A program WAV/PCM adatfolyamot olvas a szabványos bemenetről, felismeri az RS41
kereteket, elvégzi a dewhitening műveletet, majd Reed–Solomon hibajavítással
320 bájtos RS41 kereteket ír a szabványos kimenetre hexadecimális formában.

A program a DsRS41Tracker feldolgozási pipeline részeként használható az
eredeti `rs41_mod` helyett.

## Bemenet

- RIFF/WAVE PCM adatfolyam a szabványos bemeneten
- 48 000 Hz mintavételi frekvencia
- 8 vagy 16 bites egész PCM
- legalább 1 csatorna; többcsatornás bemenetnél az első csatornát használja

Példa:

```bash
cat felvetel.wav | ./rs41_mod.py
```

A projektben tipikusan:

```bash
sox -- felvetel.wav -t wav -b 16 -e signed-integer -c 1 -r 48000 - | ./rs41_filter_stream.py -LF 525 -HF 14000 -O 1 -P 0.75 -D 0.1 -V | ./rs41_mod.py | ./rs41_raw_decode_fixed_fields.pl --json
```

## Kimenet

A program minden felismert keretet egy sorban ír ki:

```text
<320 bájtos hexadecimális keret> [OK] (hibajavítások száma)
```

vagy javíthatatlan Reed–Solomon állapot esetén:

```text
<320 bájtos hexadecimális keret> [NO] (+-)
```

A két jel a két interleavelt RS(255,231) kódszó állapotát mutatja.

## Inverz és nem invertált jel

A bemeneti jel polaritását nem kell kézzel megadni.

A program a fejléc-korreláció előjeléből automatikusan felismeri, hogy az adott
keret normál vagy invertált polaritású, majd ennek megfelelően dekódolja.

Ezért az `AUDIO_INVERT` beállításnak ennél a Python demodulátornál nincs
gyakorlati jelentősége: invertált és nem invertált bemenettel is működik.

## Dekódolási módszer

A program keretenként:

1. Gaussian matched-filter segítségével megkeresi az RS41 fejlécet;
2. automatikusan meghatározza a polaritást;
3. több mintavételi fázist próbál ki;
4. kis órajel-eltéréseket is tesztel;
5. a belső RS41 CRC-k alapján kiválasztja a legjobb jelöltet;
6. lefuttatja a két interleavelt RS(255,231) Reed–Solomon javítást.

Ez a többjelöltes feldolgozás lassabb az eredeti C programnál, viszont zajosabb
felvételeknél több helyes keretet képes visszanyerni.

## Eredmény az eredeti `rs41_mod` programhoz képest

A jelenlegi tesztek alapján a Python változat átlagosan körülbelül **12%-kal**
több érvényes RS41 csomagot dekódol, mint az eredeti `rs41_mod`.

A mért javulás felvételtől és vételi minőségtől függően körülbelül:

```text
6–18%
```

A jobb találati arány ára a nagyobb CPU-terhelés és a hosszabb feldolgozási idő.

## Függőségek

- Python 3
- NumPy

Telepítés Debian/Ubuntu rendszeren:

```bash
sudo apt install python3 python3-numpy
```

## Projektintegráció

A jelenlegi konfigurációban a program közvetlenül szerepel a feldolgozási
pipeline-ban:

```ini
PIPE_RECORD=... | ./rs41_mod.py | ...
PIPE_WAV=... | ./rs41_mod.py | ...
```

A program nem igényli az eredeti `rs41_mod` parancssori kapcsolóit.
