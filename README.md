# DsRS41Tracker

### EN
Linux-based RS41 radiosonde tracking, decoding and SondeHub upload application that processes an audio source, is also compatible with the Quansheng / IJV 3.60 radio, and provides both graphical and console interfaces.

### HU
Hang forrásból dolgozó Quansheng / IJV 3.60 rádióval (is) kompatibilis Linuxos RS41 rádiószonda-követő, dekódoló és SondeHub feltöltő alkalmazás grafikus és konzolos felülettel.

## GUI
![DsRS41Tracker screenshot](https://github.com/novarobot/DsRS41Tracker/blob/main/sampleGUI.png?raw=true)

## TUI
![DsRS41Tracker screenshot](https://github.com/novarobot/DsRS41Tracker/blob/main/sampleTUI.png?raw=true)

## Tested hardware and software environment /Tesztelt hardver- és szoftverkörnyezet

### EN
DsRS41Tracker was tested with a Quansheng UV-K5 radio running IJV 3.60 firmware in BPY mode under Debian 12.

The radio was connected according to the following wiring diagram (the UART connection is optional):

### HU
A DsRS41Tracker szoftver Quansheng UV-K5 rádióval, IJV 3.60 firmware-rel, BPY módban, Debian 12 alatt lett tesztelve.

A rádió csatlakoztatása az alábbi bekötés szerint történt (az UART bekötése opcionális):

![Quansheng UV-K5 connection diagram](https://github.com/novarobot/DsRS41Tracker/blob/main/PinoutJACKfix.png?raw=true)

## English

DsRS41Tracker is a Linux-based application for receiving, decoding, tracking and displaying telemetry data from Vaisala RS41 radiosondes.

The project's graphical interface controls the complete signal-processing chain, including audio recording, filtering, RS41 demodulation, raw-frame decoding and live telemetry display. The decoded radiosonde position and flight path are displayed on an embedded map.

The application can also upload the decoded telemetry data and receiver-station data to SondeHub. With the separate Bluetooth GPS bridge, an Android phone can be used as a mobile base-position and orientation sensor.

Main features:

- live reception of RS41 radiosondes from an ALSA audio input
- recording of the received signal in WAV format
- configurable real-time audio filtering
- use of the local `rs41_mod` demodulator
- decoding of raw RS41 frames and CRC checking
- display of position, altitude, speed, direction and PTU data
- interactive map with radiosonde track and base position
- SondeHub telemetry and receiver-station upload
- Bluetooth RFCOMM connection to the GPSBridge Android application
- playback and processing of saved WAV, RAW and JSON logs
- separate PRC and JSON diagnostic views
- configurable receiver, antenna, audio and map settings

The project is intended primarily for Debian-based Linux systems and uses Perl, GTK3, WebKit2GTK, Python, ALSA and BlueZ components.

### Author

**Bálint Juhász**  
GitHub: `novarobot`  
Callsign: `HA0JSB`

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

### Szerző

**Juhász Bálint**  
GitHub: `novarobot`  
Hívójel: `HA0JSB`

