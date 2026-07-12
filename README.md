# DsRS41Tracker
Linux-based RS41 radiosonde tracking, decoding and SondeHub upload application with a graphical interface.

Linuxos RS41 rádiószonda-követő, dekódoló és SondeHub feltöltő alkalmazás grafikus felülettel.

![DsRS41Tracker screenshot](https://github.com/novarobot/DsRS41Tracker/blob/main/sample.png?raw=true)

## Author

**Bálint Juhász**  
GitHub: `novarobot`  
callsign: `HA0JSB`

## Szerző

**Juhász Bálint**  
GitHub: `novarobot`  
Hívójel: `HA0JSB`

## Tested hardware and software environment

DsRS41Tracker was tested with a Quansheng UV-K5 radio running IJV 3.60 firmware in BPY mode under Debian 12.

The radio was connected using the following wiring diagram:

## Tesztelt hardver- és szoftverkörnyezet

A DsRS41Tracker szoftver Quansheng UV-K5 rádióval, IJV 3.60 firmware-rel, BPY módban, Debian 12 alatt lett tesztelve.

A rádió csatlakoztatása az alábbi bekötés szerint történt:

![Quansheng UV-K5 connection diagram](https://github.com/novarobot/DsRS41Tracker/blob/main/PinoutJACKfix.png?raw=true)

## English

DsRS41Tracker is a Linux-based application for receiving, decoding, tracking and displaying Vaisala RS41 radiosonde telemetry.

The project provides a graphical interface that controls the complete signal-processing chain, including audio capture, filtering, RS41 demodulation, raw-frame decoding and live telemetry display. The decoded radiosonde position and flight path are shown on an embedded map.

The application can also send decoded telemetry and receiver information to SondeHub. A separate Bluetooth GPS bridge can use an Android phone as a mobile base-position and orientation sensor.

Main features:

- live RS41 radiosonde reception from an ALSA audio input
- WAV recording of the received signal
- configurable real-time audio filtering
- local `rs41_mod` demodulator integration
- raw RS41 frame decoding and CRC validation
- display of position, altitude, speed, direction and PTU data
- interactive map with radiosonde track and base position
- SondeHub telemetry and listener upload support
- Bluetooth RFCOMM connection to the GPSBridge Android application
- playback and processing of saved WAV, RAW and JSON logs
- separate PRC and JSON diagnostic views
- configurable receiver, antenna, audio and map settings

The project is intended for Debian-based Linux systems and uses Perl, GTK3, WebKit2GTK, Python, ALSA and BlueZ.

## Magyar

A DsRS41Tracker egy Linux-alapú alkalmazás Vaisala RS41 rádiószondák telemetriaadatainak vételére, dekódolására, követésére és megjelenítésére.

A projekt grafikus felülete a teljes jelfeldolgozási láncot vezérli, beleértve a hangrögzítést, a szűrést, az RS41 demodulációt, a nyers keretek dekódolását és az élő telemetria megjelenítését. A dekódolt rádiószonda pozíciója és repülési útvonala beágyazott térképen jelenik meg.

Az alkalmazás a dekódolt telemetriaadatokat és a vevőállomás adatait SondeHubra is képes feltölteni. A külön Bluetooth GPS-híd segítségével egy Android telefon mobil bázispozíció- és irányérzékelőként használható.

Főbb funkciók:

- RS41 rádiószondák élő vétele ALSA hangbemenetről
- a vett jel WAV formátumú rögzítése
- konfigurálható, valós idejű hangszűrés
- a helyi `rs41_mod` demodulátor használata
- nyers RS41 keretek dekódolása és CRC-ellenőrzése
- pozíció, magasság, sebesség, irány és PTU-adatok megjelenítése
- interaktív térkép szondanyomvonallal és bázispozícióval
- SondeHub telemetria- és vevőállomás-feltöltés
- Bluetooth RFCOMM kapcsolat a GPSBridge Android alkalmazással
- mentett WAV-, RAW- és JSON-naplók visszajátszása és feldolgozása
- külön PRC és JSON diagnosztikai nézet
- konfigurálható vevő-, antenna-, hang- és térképbeállítások

A projekt elsősorban Debian-alapú Linux rendszerekhez készült, és Perl, GTK3, WebKit2GTK, Python, ALSA és BlueZ komponenseket használ.
