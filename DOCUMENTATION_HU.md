# DsRS41Tracker 0.2.46 – dokumentáció

## 1. A projekt rendeltetése

A **DsRS41Tracker** Linuxon futó, többfolyamatos Vaisala RS41
rádiószonda-vevő, dekódoló, megjelenítő, naplózó és SondeHub-feltöltő
alkalmazás.

A rendszer képes:

- élő hangbemenetből RS41 adást feldolgozni;
- a nyers hangot WAV-fájlba menteni;
- az `rs41_mod` demodulátor RAW kimenetét naplózni;
- a RAW kereteket helyben dekódolni;
- a dekódolt adatokat JSON Lines formátumban naplózni;
- korábban mentett WAV-, RAW- és JSON-fájlokat visszajátszani;
- GTK3/WebKit2 alapú grafikus felületet biztosítani;
- Curses alapú terminálos felületet biztosítani;
- Bluetooth RFCOMM GPS-forrásból frissíteni a bázispozíciót;
- SondeHub telemetria- és listener-adatokat feltölteni;
- a bázis szonda távolságot, irányt és emelkedési szöget kiszámítani;

A projekt jelenlegi alapbeállítása Debian-alapú Linux rendszerre készült,
de a MAIN, GUI, TUI és a közös Perl-modulok belső folyamatkezelése
alapvetően POSIX-mechanizmusokra épül.

A platformfüggő részek elkülönülnek:

```text
pipeConnect.pl
    a Linux absztrakt UNIX socket megvalósítása

gps_bridge_bt.pl
    a Linux/BlueZ/RFCOMM Bluetooth GPS-réteg

rs41_mod vagy rs41_mod.py esetleg más demodulátor
    külön futtatható külső program

config.txt
    feldolgozási pipeline-ok, hangrendszer és workerindító parancsok

startGUI.sh / startTUI.sh
    launcher- és környezetfüggő folyamatindítás
```

A GUI hordozhatósága a Gtk3, Gtk3::WebKit2 és a használt terminálemulátor
elérhetőségétől függ. A TUI hordozhatósága a Perl Curses/ncurses modultól
és az adott curses-megvalósítástól függ.

---

## 2. Tervezési alapelvek

A program legfontosabb szerkezeti döntései:

1. A jelfeldolgozás és az alkalmazás logika a `rs41_main.pl` folyamatban van.
2. A GUI és a TUI csak frontend, nem végez párhuzamos dekódolást.
3. A main és a frontend kétirányú, soronkénti JSON IPC-vel kommunikál.
4. A normál napló- és hibaüzenetek STDERR-en haladnak, nem az IPC-csatornán.
5. Egyszerre csak egy FELV/WAV/RAW/JSON feldolgozási munkamenet futhat.
6. A GUI és TUI tényleges beállítási állapotának tulajdonosa a main.
7. A TUI és GUI nem olvassa közvetlenül a `config.txt` fájlt.
8. A pipeConnect.pl -R/-W` gyermekfolyamatokat használnak.
9. A futás közbeni beállítások nem íródnak vissza a `config.txt` fájlba.
10. A hiányos RS41 keretek részleges érték frissítést eredményeznek.

---

## 3. Magas szintű architektúra

### 3.1 GUI mód

```text
startGUI.sh
    │
    ├── rs41_main.pl
    │     ├── audio/fájl pipeline
    │     ├── RS41 dekódolás fogadása
    │     ├── statisztika és vektorszámítás
    │     ├── Bluetooth GPS szolgáltatás
    │     └── SondeHub szolgáltatás
    │
    └── rs41_gui.pl
          ├── dsPGtkGUI.pm
          ├── UI.glade
          ├── Gtk3
          ├── Gtk3::WebKit2
          └── UI.html
```

### 3.2 TUI mód

```text
startTUI.sh
    │
    ├── rs41_main.pl
    │     ├── audio/fájl pipeline
    │     ├── RS41 dekódolás fogadása
    │     ├── statisztika és vektorszámítás
    │     ├── Bluetooth GPS szolgáltatás
    │     └── SondeHub szolgáltatás
    │
    └── rs41_tui.pl
          ├── Curses / ncurses
          ├── billentyűzet
          ├── egér
          ├── beépített fájlválasztó
          └── beépített BT/SHUB szolgáltatásablak
```

### 3.3 Közös modulok

```text
RS41IPC.pm
    JSON IPC segédfüggvények

RS41FrontendData.pm
    közös GUI/TUI adatmodell és sticky mezők
```

### 3.4 Launcher által létrehozott csatornák

```text
rs41_main.pl STDOUT  ──────► frontend STDIN
rs41_main.pl STDIN   ◄────── frontend STDOUT

rs41_main.pl STDERR  ──────► launcher terminál
frontend STDERR      ──────► launcher terminál
```

A launcher ellenőrzi, hogy az STDOUT-on érkező sor valódi JSON
legyen. A `terminal` típusú IPC-üzeneteket nem továbbítja a másik
folyamatnak, hanem formázva STDERR-re írja.

---

## 4. A fő adatfeldolgozási útvonalak

A négy feldolgozási mód külön, konfigurálható shell-pipeline-t használ:

```text
PIPE_RECORD
PIPE_WAV
PIPE_RAW
PIPE_JSON
```

Ha valamelyik kulcs hiányzik, üres vagy kommentelt, a MAIN a programba
épített korábbi alapértelmezett pipeline-t használja.

A MAIN a tényleges parancsot sablonhelyettesítéssel állítja elő, majd
általános POSIX folyamatkezeléssel indítja:

```text
pipe
fork
POSIX::setsid
STDIN/STDOUT/STDERR átirányítás
exec sh -c
```

## 4.1 Élő vétel

Az élő feldolgozás két külön ágból áll.

### Hangfelvétel és helyi monitorozás

A külön monitorozó/WAV-mentő parancs:

```text
RECORD_MONITOR_COMMAND
```

A WAV-napló kapcsolója:

```text
WAV_LOG_ENABLED
```

Alapértéke:

```text
1
```

Ha a bejegyzés hiányzik, üres vagy kommentelt, a WAV-napló engedélyezett.

A `RECORD_MONITOR_COMMAND` a `{WAV_LOG_PIPE}` helyettesítőt használja:

```text
WAV_LOG_ENABLED=1:
    arecord ... | tee -- {WAV_FILE} | aplay -q

WAV_LOG_ENABLED=0:
    arecord ... | aplay -q
```

A WAV-fájl kikapcsolása tehát nem tiltja le a helyi hangmonitorozást.
Más platformon ezt a configsort kell az adott hangrendszerhez igazítani.

### Élő dekódoló pipeline

```text
PIPE_RECORD
```

Alapértelmezett logikai felépítése:

```text
hangforrás
    │
    ▼
{FILTER_COMMAND} {FILTER_ARGS}
    │
    ▼
{MOD_COMMAND} {MOD_ARGS}
    │
    ├── tee -a → Rlog
    ▼
{DECODER} --json
    │
    ├── tee -a → Jlog
    ▼
rs41_main.pl
```

## 4.2 WAV feldolgozás

A WAV-mód pipeline-ja:

```text
PIPE_WAV
```

Alapértelmezett felépítés:

```text
WAV fájl
    │
    ▼
sox
    │
    ▼
{FILTER_COMMAND} {FILTER_ARGS}
    │
    ▼
{MOD_COMMAND} {MOD_ARGS}
    │
    ▼
{DECODER} --json
    │
    ▼
rs41_main.pl
```

## 4.3 RAW feldolgozás

A RAW-mód pipeline-ja:

```text
PIPE_RAW
```

Alapértelmezett felépítés:

```text
.Rlog vagy .raw
    │
    ▼
cat
    │
    ▼
{DECODER} --json
    │
    ▼
{PIPE_DELAY}
    │
    ▼
rs41_main.pl
```

## 4.4 JSON visszajátszás

A JSON-mód pipeline-ja:

```text
PIPE_JSON
```

Alapértelmezett felépítés:

```text
.Jlog vagy .json
    │
    ▼
cat
    │
    ▼
{PIPE_DELAY}
    │
    ▼
rs41_main.pl
```

## 4.5 FILTER és MOD parancsok szétválasztása

A MAIN külön kezeli a programot és az aktuális argumentumokat:

```text
{FILTER_COMMAND}
{FILTER_ARGS}
{MOD_COMMAND}
{MOD_ARGS}
```

Jelenlegi beépített értékek:

```text
FILTER_COMMAND:
    ./rs41_filter_stream.py

FILTER_ARGS:
    -LF <aktuális LF>
    -HF <aktuális HF>
    -O  <aktuális szűrőrend>
    -P  <aktuális csúcsszint>
    -D  <aktuális késleltetés>
    -V

MOD_COMMAND:
    ./rs41_mod

MOD_ARGS:
    -vv
    -r
    [-i]
    /dev/stdin
```

Az `-i` csak akkor kerül a `MOD_ARGS` értékébe, ha az aktuális Inverz
beállítás aktív.

Ezért a configban a program szabadon cserélhető, miközben a változó
argumentumokat továbbra is a MAIN állítja elő. Példa:

```text
... | ./rs41_mod.py {MOD_ARGS} | ...
```

## 4.6 `rs41_mod` és `rs41_mod.py`

### Alapértelmezett demodulátor

A MAIN beépített alapértelmezése:

```text
MOD_COMMAND:
    ./rs41_mod

MOD_ARGS:
    -vv -r [-i] /dev/stdin
```

Ez érvényes akkor is, ha:

- a `PIPE_RECORD` vagy `PIPE_WAV` bejegyzés hiányzik;
- a releváns configbejegyzés üres;
- a releváns configbejegyzés kommentelt;
- a pipeline a `{MOD_COMMAND} {MOD_ARGS}` helyettesítőket használja.

A mellékelt `config.txt` ezért alapértelmezetten ismét ezt használja:

```text
| {MOD_COMMAND} {MOD_ARGS} |
```

### Python demodulátor

Az `rs41_mod.py` WAV/PCM adatfolyamot olvas STDIN-ről, megkeresi az RS41
GFSK kereteket, elvégzi a dewhitening műveletet és a két interleavelt
RS(255,231) Reed–Solomon hibajavítást. A kimenet 320 bájtos,
hexadecimális RS41 keret soronként.

A Python változat configból így választható:

```text
PIPE_RECORD=... | {FILTER_COMMAND} {FILTER_ARGS} | ./rs41_mod.py | ...
PIPE_WAV=... | {FILTER_COMMAND} {FILTER_ARGS} | ./rs41_mod.py | ...
```

Az `rs41_mod.py` nem igényli az eredeti C `rs41_mod` kapcsolóit, ezért
mellé nem szükséges a `{MOD_ARGS}`.

### Automatikus polaritásfelismerés

Az `rs41_mod.py` a fejléc-korreláció előjeléből automatikusan felismeri,
hogy az adott keret normál vagy invertált polaritású.

Ezért Python demodulátor használatakor:

```text
AUDIO_INVERT
```

beállításának nincs gyakorlati hatása. Az invertált és nem invertált jelet
ugyanaz a program automatikusan kezeli.

### Dekódolási eredmény

Az `rs41_mod.py` átlagosan körülbelül:

```text
12%
```

több érvényes csomagot dekódol, mint az eredeti `rs41_mod`.

A mért javulási tartomány:

```text
6–18%
```

A jobb találati arány ára a nagyobb CPU-terhelés és a hosszabb
feldolgozási idő.

### Bemeneti követelmények

```text
RIFF/WAVE PCM
48 000 Hz
8 vagy 16 bites egész PCM
legalább egy csatorna
```

Többcsatornás bemenetnél az első csatorna kerül feldolgozásra.

## 4.7 Visszajátszási sebesség

A `pipe_delay.pl` jelenlegi korlátja:

```text
100 sor/másodperc
```

---

## 5. Folyamat- és munkamenet

A main állapotai:

```text
idle
starting
running
stopping
idle
```

Egyszerre csak egy feldolgozási munkamenet lehet aktív:

```text
record
wav
raw
json
```

Új munkamenet nem indulhat, ha:

- egy másik feldolgozás fut;
- egy korábbi folyamat leállóban van;
- még nyitva van a feldolgozó kimeneti pipe;
- a recorder vagy processor gyermekfolyamat még aktív.

### 5.1 Folyamatcsoportok

A main a feldolgozási pipeline-okat `setsid` segítségével külön
folyamatcsoportban indítja. Leállításkor:

1. leválasztja a processor kimenetét az `IO::Select` objektumról;
2. TERM jelet küld a teljes folyamatcsoportra;
3. vár a szabályos kilépésre;
4. szükség esetén KILL jelet küld;
5. `waitpid()` segítségével begyűjti a gyermekfolyamatot;
6. `running_state=0` üzenetet küld a frontendnek.

### 5.2 Pipeline-generáció

A `pipeline_generation` számláló megakadályozza, hogy egy korábbi,
elavult munkamenet későn érkező eseménye egy új feldolgozást vezéreljen.

### 5.3 Automatikus befejezés

Ha a feldolgozó pipe EOF-ot ad, a main befejezi a munkamenetet, leállítja a
hozzá tartozó folyamatcsoportokat, majd `running_state=0` állapotot küld.

A TUI erre teljes fizikai képernyő-újrarajzolással reagál.

---

## 6. FRISSÍT és ALKALMAZ

A projekt két külön beállítási műveletet használ.

## 6.1 FRISSÍT

IPC:

```text
settings_apply_requested
```

Csak ezeket módosítja:

```text
bázis szélesség
bázis hosszúság
bázis magasság
bázis irányszög
vételi / SondeHub frekvencia
SondeHub MEGOSZTÁS állapot
SondeHub MOBIL állapot
```

A FRISSÍT:

- nem módosít audio- vagy szűrőparamétert;
- nem módosít LOG mappát;
- nem indítja újra a FELV/WAV/RAW/JSON feldolgozási pipeline-t;
- újraszámítja a bázis–szonda vektoradatokat;
- aktív SondeHub szolgáltatásnál új bázisadatot adhat át;
- MEGOSZTÁS vagy MOBIL változásakor automatikusan újraindítja kizárólag a `sondehub_upload.pl` POSIX pipe worker folyamatot;
- `settings_state` üzenettel visszaküldi a tényleges állapotot.

A SondeHub worker újraindítása közben megmarad mindkét irány
`pipeConnect.pl` folyamata, a kapcsolati ID-k, a MAIN–UI JSON
vezérlőcsatorna és a már megnyitott szolgáltatásablak. Csak a
`sondehub_upload.pl` gyermekfolyamat, valamint annak STDIN/STDOUT pipe-ja
cserélődik.

## 6.2 ALKALMAZ

IPC:

```text
settings_save_requested
```

Az összes beállítást átadja a mainnek.

Ha nincs aktív feldolgozás:

```text
FRISSÍT
    → main beállításállapot frissítése
    → settings_state
```

Ha FELV/WAV/RAW/JSON feldolgozás fut:

```text
FRISSÍT
    → aktuális mód és fájlútvonal megjegyzése
    → pipeline szabályos leállítása
    → összes beállítás alkalmazása
    → ugyanazon munkamenet újraindítása
    → settings_state
```

WAV, RAW és JSON esetén ugyanaz a fájl indul újra.

Élő felvételnél új időbélyeges WAV/Rlog/Jlog fájlok készülnek, ezzel az eddig megszerzett keretek is 0-ról indulnak újra!

## 6.3 Kompatibilitási üzenetek

A main a korábbi frontendelemekkel való kompatibilitás miatt ezeket is
teljes mentésként kezeli:

```text
settings_changed
processing_settings_changed
```

---

## 7. Main–frontend JSON IPC

Az IPC newline-delimited JSON:

```text
egy sor = egy teljes JSON objektum
```

A kódolás UTF-8.

## 7.1 Frontend → main

Fő üzenetek:

| Típus | Jelentés |
| --- | --- |
| `frontend_ready` | A frontend készen áll |
| `settings_apply_requested` | Bázis és frekvencia alkalmazása |
| `settings_save_requested` | Minden beállítás mentése |
| `start_recording_requested` | Élő felvétel indítása |
| `play_wav_requested` | WAV feldolgozása |
| `play_raw_requested` | RAW feldolgozása |
| `play_json_requested` | JSON visszajátszása |
| `stop_requested` | Feldolgozás leállítása |
| `bt_start_requested` | Bluetooth GPS szolgáltatás indítása |
| `bt_stop_requested` | Bluetooth GPS szolgáltatás leállítása |
| `sondehub_start_requested` | SondeHub szolgáltatás indítása |
| `sondehub_stop_requested` | SondeHub szolgáltatás leállítása |
| `window_close_requested` | A frontend közös leállítást kér |
| `terminal` | Launcher termináljára szánt állapotüzenet |

## 7.2 Main → frontend

| Típus | Jelentés |
| --- | --- |
| `initialize` | Kezdeti settings és HTML-konfiguráció |
| `settings_state` | Main által ténylegesen használt beállítások |
| `receiver_update` | Egy dekódolt RS41 objektum |
| `runtime_statistics` | Csomag- és repülési statisztika |
| `calculated_fields` | Távolság, irány, emelkedési szög |
| `base_position_update` | BT GPS által frissített bázis |
| `running_state` | Feldolgozás fut/áll |
| `append_log` | PRC vagy JSON napló |
| `clear_logs` | Frontendnaplók és megjelenítési állapot törlése |
| `service_opened` | BT/SHUB szolgáltatás megnyílt; MAIN fogadó ID |
| `bt_state` | Bluetooth szolgáltatás állapota |
| `sondehub_state` | SondeHub szolgáltatás állapota |
| `terminal` | Launcher termináljára szánt üzenet |
| `shutdown` | Frontend leállítása |

## 7.3 `initialize`

Példa:

```json
{
	"type": "initialize",
	"settings": {
		"work_dir": "/projekt/log",
		"device": "default",
		"sample_rate": "48000",
		"lf": "525",
		"hf": "14000",
		"order": "1",
		"peak": "0.75",
		"delay": "0.1",
		"invert": 1,
		"frequency": "403.700",
		"share": 1,
		"mobile": 0,
		"base": {
			"latitude": "47.49786",
			"longitude": "19.04022",
			"altitude": "110",
			"angle": "0"
		}
	},
	"html_config": {
		"...": "..."
	}
}
```

## 7.4 `settings_state`

Minden ALKALMAZ és MENTÉS után a main teljes állapotot küld:

```json
{
	"type": "settings_state",
	"settings": {
		"...": "a tényleges main-értékek"
	},
	"html_config": {
		"...": "a térkép beállításai"
	}
}
```

A GUI és TUI ezt tekinti végleges állapotnak.

## 7.5 Launcher eseménykérések

A launcherek `frontend_event_request` objektumokat küldenek.

Példák:

```json
{"type":"frontend_event_request","event":"start_recording"}
{"type":"frontend_event_request","event":"open_wav","path":"/abszolút/fájl.wav"}
{"type":"frontend_event_request","event":"set_bt","active":true}
```

Az eseményeket a launcher csak a main `initialize` üzenete után küldi el.

---

## 8. RS41IPC.pm

Az `RS41IPC.pm` közös IPC-segédréteg.

Exportálható függvényei:

```text
json_codec
configure_json_stdio
send_json_message
decode_json_line
extract_json_messages
make_frontend_event_request
is_frontend_event_request
```

Feladatai:

- kanonikus `JSON::PP` codec létrehozása;
- UTF-8 STDIN/STDOUT konfiguráció;
- egy objektum JSON-sorként történő elküldése;
- egy teljes sor dekódolása;
- részleges, nem blokkoló bemeneti puffer kezelése;
- launcher eseménykérések felismerése.

---

## 9. RS41FrontendData.pm

A modul közös GUI/TUI frontend-adatmodellt biztosít.

Fő függvényei:

```text
new_frontend_state
reset_frontend_state
apply_receiver_update
apply_runtime_statistics
apply_calculated_fields
packet_summary_text
packet_ratio_text
frontend_table_values
```

### 9.1 Sticky mezők

A dekódolt `PARTIAL` és `INVALID` csomagokban több mező lehet `null`.

A közös adatmodell csak a definiált új értékeket fésüli be. Emiatt egy
hiányos keret nem törli például:

- a szondaazonosítót;
- a keretszámot;
- a GPS-pozíciót;
- a sebességet;
- a hőmérsékletet;
- a nyomást;
- a kalibrációs állapotot.

A TUI a keretszámot és műholdszámot külön közvetlen sticky mezőként is
kezeli, hogy numerikus vagy hiányos JSON-érték ne okozzon villogást.

---

## 10. Vektorszámítás és statisztika

A main számítja:

```text
3D távolság
földfelszíni nagy kör távolság
irány / bearing
emelkedési szög
megtett összút
csúcsmagasság
csúcsmagasság ideje
utolsó VALID keret kora
VALID / PARTIAL / INVALID darabszám
```

A bázis és a szonda között:

1. WGS84 szélesség/hosszúság alapján nagy kör távolság készül;
2. a magasságkülönbségből 3D távolság készül;
3. a kezdőirányból bearing készül;
4. `atan2()` alapján emelkedési szög készül.

A main külön összefésült szondapozíciót tart fenn. Csak érvényes, numerikus
szélesség, hosszúság és magasság írhatja felül. Emiatt a számított mezők nem
tűnnek el egy hiányos keret után.

---

## 11. Grafikus frontend

A grafikus felület fő fájlja:

```text
rs41_gui.pl
```

Technológiák:

```text
Perl
Gtk3
Gtk3::WebKit2
Glib
Glade XML
HTML/CSS/JavaScript
```

## 11.1 GUI felépítése

A widgeteket a `UI.glade` írja le.

A Glade főablak címe: `RS41 vevő GUI v0.2.46`. A `dsPGtkGUI.pm`:

- inicializálja a Gtk3-at;
- betölti a Glade XML-t;
- összegyűjti a widgetazonosítókat;
- a signal handlereket a főcsomag függvényeihez köti;
- elindítja és leállítja a GTK főciklust.

## 11.2 GUI funkciók

- élő felvétel;
- WAV megnyitása;
- RAW megnyitása;
- JSON megnyitása;
- feldolgozás leállítása;
- Bluetooth GPS kapcsoló;
- SondeHub kapcsoló;
- bázispozíció szerkesztése;
- vételi frekvencia szerkesztése;
- audio- és szűrőparaméterek szerkesztése;
- LOG mappa kiválasztása;
- pozíciómegosztás és mobil mód;
- térképközépre követés;
- PRC és JSON napló;
- WebKit térkép;
- külön szolgáltatásterminál.

## 11.3 GUI Frissít

Az Frissít gomb:

```text
bázis latitude
bázis longitude
bázis altitude
bázis angle
frequency
share
mobile
```

értékeket küldi `settings_apply_requested` üzenetben.

A MEGOSZTÁS vagy MOBIL kapcsoló átváltása automatikusan meghívja
ugyanezt az Frissít műveletet. A FELV/WAV/RAW/JSON pipeline nem indul
újra, de aktív SondeHub szolgáltatásnál a MAIN automatikusan újraindítja a
`sondehub_upload.pl` workerét. A kétirányú `pipeConnect.pl` csatorna és a
szolgáltatásterminál közben megmarad.

## 11.4 GUI Alkalmaz

A Alkalmaz gomb az összes mezőt `settings_save_requested` üzenetben küldi.

Aktív pipeline esetén a main ugyanazt a munkamenetet újraindítja.

Fontos hogy élő vétel esetén új WAV / LOG állományok kezdődnek, és újra összekel gyűjteni az 51 kalibrációs keretet!

## 11.5 Mezők szerkeszthetősége

A fő `GtkEntry` mezők:

- `editable=TRUE`;
- `can-focus=TRUE`.

A GUI induláskor programból is biztosítja ezeket a tulajdonságokat.

## 11.6 Fájlválasztók

WAV:

```text
*.wav
*.WAV
```

RAW:

```text
*.Rlog
*.rlog
*.raw
*.RAW
*.txt
```

JSON:

```text
*.Jlog
*.jlog
*.json
*.JSON
*.txt
```

A kiválasztott fájl útvonalát a GUI ellenőrzi és abszolút útvonallá
alakítja.

---

## 12. WebKit térkép és adatpanel

A `UI.html` önálló HTML/CSS/JavaScript felület.

A fájl tartalmaz egy beépített, minimális Leaflet-kompatibilis
megvalósítást. Emiatt külső Leaflet JavaScript vagy CSS fájl betöltése nem
szükséges.

Fő képességek:

- csempés térkép;
- egérrel húzható térkép;
- görgős zoom;
- zoomgombok;
- bázisirány-jelölő;
- szondairány-jelölő;
- nyomvonal;
- nyomvonalpontok;
- automatikus szondakövetés;
- bázis és szonda együttes illesztése;
- 28 mezős adatpanel;
- összecsukható adatpanel;
- függőlegesen átméretezhető térkép/adat határ.

A HTML sablon helyettesítői:

```text
__BASE_ARROW_COLOR__
__SONDE_ARROW_COLOR__
__TRACK_COLOR__
__TILE_SERVER__
__MAP_START_LAT__
__MAP_START_LON__
__MAP_START_ZOOM__
__TRACK_WIDTH__
__TRACK_OPACITY__
__TRACK_POINT_RADIUS__
```

A tile képek a konfigurált csempeszerverről érkeznek. Az alapbeállítás
OpenStreetMap.

A WebKit cache helye a projekt saját `cache` könyvtára.

---

## 13. Terminálos frontend

Technológia:

```text
Perl Curses / ncurses
UTF-8 terminál
billentyűzet
ncurses egérkezelés
```

## 13.1 Minimális terminálméret

```text
132 × 45 karakter
```

Kisebb terminálnál a teljes elrendezés nem fér el.

## 13.2 Menü

```text
1  FELV
2  WAV
3  RAW
4  JSON
5  ÁLLJ
6  BT
7  SHUB
8  BEÁLL.
q  KILÉP
```

Jelölések:

```text
[_] inaktív
[#] aktív
<| ... |> kiválasztott
```

Vezérlés:

```text
Bal/Jobb       menüpontváltás
Enter/Space    aktiválás
1–8            közvetlen parancs
q              kilépés
```

## 13.3 Főképernyő

A TUI fő részei:

1. menüsor;
2. bázisadatok;
3. vételi adatok;
4. számított vektoradatok;
5. audio- és szűrőbeállítások;
6. csomagstatisztika;
7. 28 mezős RS41 adattábla;
8. diagnosztikai panel.

## 13.4 Beállításállapotok

A TUI két külön hash-t tart:

```text
%config
    main által visszaküldött tényleges állapot

%settings_draft
    beállításablak szerkesztési másolata
```

A beállításablak megnyitásakor:

```text
%config → %settings_draft
```

A mezőszerkesztés kizárólag a draft állapotot módosítja. A főképernyő csak
mainből érkező `initialize`, `settings_state` vagy `base_position_update`
üzenetből változik.

## 13.5 TUI beállítások

Szerkeszthető:

```text
Bázis / Szélesség
Bázis / Hosszúság
Bázis / Magasság
Bázis / Szög
Vétel / Frekvencia MHz
SondeHub / Pozíció megosztása
SondeHub / Mobil bázis
Audio / Eszköz
Audio / Hz
Szűrő / LF
Szűrő / HF
Szűrő / O
Szűrő / P
Szűrő / D
Szűrő / Inverz
Rendszer / LOG mappa
```

Mezőszerkesztés:

```text
Bal/Jobb       kurzormozgatás
Home/End       sor eleje/vége
Backspace      előző karakter törlése
Delete         aktuális karakter törlése
Enter          érték elfogadása a draftba
Esc            mezőszerkesztés elvetése
```

## 13.6 Beállításablak bezárása

Ha nincs FELV/WAV/RAW/JSON feldolgozás:

```text
Esc
    → settings_apply_requested
    → settings_save_requested
    → settings_state
```

Ha feldolgozás fut:

```text
Esc
    → csak settings_apply_requested
    → settings_state
```

Futó feldolgozás közben tehát:

- a bázis frissülhet;
- a frekvencia frissülhet;
- a MEGOSZTÁS állapot frissülhet;
- a MOBIL állapot frissülhet;
- az audio-, szűrő- és LOG-mappa draft nem mentődik;
- a FELV/WAV/RAW/JSON pipeline nem indul újra;
- aktív SondeHub szolgáltatásnál MEGOSZTÁS vagy MOBIL változásakor csak a `sondehub_upload.pl` POSIX pipe worker indul újra.

## 13.7 TUI fájlválasztó

A TUI csak az aktuális LOG mappa közvetlen fájljait mutatja.

WAV:

```text
*.wav
```

RAW:

```text
*.rlog
*.raw
```

JSON:

```text
*.jlog
*.json
```

Vezérlés:

```text
Fel/Le         választás
PageUp/Down    lapozás
Home/End       első/utolsó elem
Enter          megnyitás
Esc            bezárás
```

Nincs könyvtárváltás és nincs rekurzív keresés.

## 13.8 Egérkezelés

Kattintható:

- a főmenü;
- a beállítások sorai;
- a fájlválasztó sorai;
- a beállításablak Enter és Esc vezérlője;
- a fájlválasztó Enter és Esc vezérlője;
- a szolgáltatásablak HOME és END vezérlője.

A Perl Curses `getmouse()` egy bináris MEVENT skalárt ad. A TUI ezt a
Linux/ncurses struktúrának megfelelően bontja ki.

## 13.9 Kényszerített teljes újrarajzolás

A TUI teljes fizikai képernyő-újrarajzolást kér:

- fájlválasztó bezárásakor;
- BT/SHUB szolgáltatásablak elrejtésekor;
- BT/SHUB kapcsolat lezárásakor;
- beállításablak bezárásakor;
- ÁLLJ menü aktiválásakor;
- a main `running_state=0` üzeneténél;
- a feldolgozási pipe megszűnése után.

Az újrarajzolás:

```text
clearok(window, 1)
touchwin(window)
window->clear()
window->erase()
teljes draw_screen()
refresh
```

Ez megakadályozza, hogy popupkeret, hibaüzenet vagy eltűnt menüsor maradjon
a terminálban.

---

## 14. RS41 demodulátorok

A projekt két RS41 GFSK demodulátort tartalmaz:

```text
rs41_mod
rs41_mod.py
```

Az `rs41_mod` a korábbi, x86-64 Linux bináris demodulátor. Az
`rs41_mod.py` a projekt saját Python nyelvű RS41 GFSK demodulátora és
Reed–Solomon keretjavítója.

### 14.1 `rs41_mod`

Eredeti forrás: https://github.com/rs1729/RS , a konkrét felhasznált verzió forrása az SRC mappán belül megtalálható!

A main alapértelmezett használata:

```bash
./rs41_mod -vv -r -i /dev/stdin
```

Az `-i` csak akkor kerül a parancsba, ha az `AUDIO_INVERT` be van
kapcsolva.

A demodulátor RAW hexadecimális keretsorokat ad a Perl dekódernek.

A binárisnak futtathatónak kell lennie:

```bash
chmod +x rs41_mod
```

Az `rs41_mod` továbbra is használható, de az `rs41_mod.py` miatt már nem
kötelező projektfüggőség.

### 14.2 `rs41_mod.py`

Az `rs41_mod.py` a projekt saját RS41 GFSK demodulátora. WAV/PCM
adatfolyamot olvas STDIN-ről, felismeri az RS41 kereteket, elvégzi a
dewhitening műveletet, majd a két interleavelt RS(255,231)
Reed–Solomon-kódszó hibajavítását.

Kimenete a Perl dekóder által közvetlenül feldolgozható, soronként egy
320 bájtos hexadecimális RS41 keret.

A jelenlegi mérések alapján az `rs41_mod.py` azonos hangforrásból
átlagosan körülbelül 12% több érvényes RS41 csomagot képes dekódolni, mint az eredeti rs41_mod`. A mért javulás a vételi körülményektől függően 6–18% .`

A jobb dekódolási arány (illetve a Python használatának) ára:

- lassabb feldolgozás;
- nagyobb CPU-terhelés;
- hosszabb teljes feldolgozási idő.

### 14.3 Automatikus invertáltjel-felismerés

Az `rs41_mod.py` automatikusan felismeri, hogy a bemeneti jel normál vagy
invertált polaritású.

Ezért `rs41_mod.py` használatakor:

```text
AUDIO_INVERT
```

beállításának nincs hatása. A Python demodulátor nem veszi figyelembe az
invertált kapcsolót, mert minden keretnél automatikusan meghatározza a
helyes polaritást.

Az `rs41_mod.py` mellé nem kell megadni az eredeti `rs41_mod`
parancssori kapcsolóit, tehát a `{MOD_ARGS}` helyettesítőt sem kell
használni.

### 14.4 Demodulátor kiválasztása a `config.txt` fájlban

A projekt alapértelmezett pipeline-ja az eredeti bináris demodulátort
használja:

```text
| {MOD_COMMAND} {MOD_ARGS} |
```

A MAIN beépített alapértékei:

```text
MOD_COMMAND:
    ./rs41_mod

MOD_ARGS:
    -vv -r [-i] /dev/stdin
```

Ez az alapértelmezés akkor is érvényes, ha a `PIPE_RECORD` vagy
`PIPE_WAV` configbejegyzés hiányzik, üres vagy kommentelt.

Az `rs41_mod.py` használatához a `config.txt` fájlban a
`PIPE_RECORD` és `PIPE_WAV` sorok demodulátorrészét erre kell cserélni:

```text
| ./rs41_mod.py |
```

Élő vételhez:

```text
PIPE_RECORD=arecord -D {AUDIO_DEVICE} -t wav -f S16_LE -r {AUDIO_SAMPLE_RATE} -c 1 -q | {FILTER_COMMAND} {FILTER_ARGS} | ./rs41_mod.py | tee -a {RLOG_FILE} | {DECODER} --json | tee -a {JLOG_FILE}
```

WAV-feldolgozáshoz:

```text
PIPE_WAV=sox -- {INPUT_FILE} -t wav -b 16 -e signed-integer -c 1 -r {AUDIO_SAMPLE_RATE} - | {FILTER_COMMAND} {FILTER_ARGS} | ./rs41_mod.py | {DECODER} --json
```

Fontos:

```text
rs41_mod:
    | {MOD_COMMAND} {MOD_ARGS} |

rs41_mod.py:
    | ./rs41_mod.py |
```

Az `rs41_mod.py` sorában ne szerepeljen a `{MOD_ARGS}`, mert a Python
demodulátor nem használja az eredeti bináris `-vv`, `-r`, `-i` és
`/dev/stdin` argumentumait.

A Python demodulátorhoz szükséges:

```bash
chmod +x rs41_mod.py
sudo apt install python3 python3-numpy
```
---

## 15. Audio-szűrés

A `rs41_filter_stream.py` folyamatos WAV-stream szűrő.

Bemenet:

```text
PCM
S16_LE
mono
RIFF/WAVE
```

Kimenet:

```text
folyamatos PCM S16_LE mono WAV
```

Fő műveletek:

- WAV fejléc értelmezése;
- formátumellenőrzés;
- magasáteresztő Butterworth szűrő;
- aluláteresztő Butterworth szűrő;
- `scipy.signal.sosfiltfilt`;
- blokkos feldolgozás;
- csúcsszint-alapú AGC;
- maximális erősítés korlátozása;
- 16 bites PCM visszaírás;
- streaming WAV fejléc.

Kapcsolók:

| Kapcsoló | Jelentés |
| --- | --- |
| `-LF`, `--low-frequency` | Alsó vágási frekvencia |
| `-HF`, `--high-frequency` | Felső vágási frekvencia |
| `-O`, `--order` | Butterworth rend |
| `-P`, `--peak` | AGC célcsúcsszint |
| `-D`, `--delay` | Blokkméret és késleltetés |
| `-MG`, `--max-gain` | Legnagyobb AGC erősítés |
| `-NA`, `--no-agc` | AGC kikapcsolása |
| `-V`, `--verbose` | Paraméterek STDERR-re |

A main minden fontos szűrőparamétert explicit átad, ezért a Python fájl
önálló alapértékei normál projektindításkor nem mérvadók.

Érvényességi feltételek:

```text
LF > 0
HF > LF
HF < mintavétel / 2
order >= 1
0 < peak <= 1
delay >= 0.1
max_gain > 0
```

---

## 16. RS41 RAW dekóder

A dekóder:

```text
rs41_raw_decode_fixed_fields.pl
```

Bemenet:

```text
rs41_mod -r sorformátum
legalább 640 hexadecimális karakter
opcionális [OK] vagy [NO]
opcionális további állapotszöveg
```

Kapcsolók:

```text
--json
--no-raw
--calibration
--only-valid
--help
```

## 16.1 Érvényességi szintek

```text
VALID
    fejléc rendben, minden vizsgált részcsomag CRC-helyes

PARTIAL
    fejléc rendben, legalább egy részcsomag CRC-helyes

INVALID
    fejléc hibás vagy nincs használható részcsomag
```

## 16.2 Vizsgált részcsomagok

```text
frame
ptu
gps1
gps2
gps3
end
```

## 16.3 Dekódolt adatok

- keretszám;
- szondaazonosító;
- akkumulátorfeszültség;
- kalibrációs keret indexe;
- GPS hét és TOW;
- UTC-szerű GPS-idő;
- ECEF pozíció;
- WGS84 szélesség, hosszúság, magasság;
- ECEF sebesség;
- ENU sebesség;
- vízszintes sebesség;
- irány;
- függőleges sebesség;
- műholdszám;
- SACC;
- PDOP;
- nyers PTU mérések;
- hőmérséklet;
- páraszenzor-hőmérséklet;
- relatív páratartalom;
- empirikus páratartalom;
- nyomás;
- magasságból becsült nyomás;
- kalibrációs lefedettség;
- teljes kalibráció CRC;
- frekvencia- és modellkonfiguráció.

## 16.4 Kalibráció

A dekóder szondánként külön állapotot tart:

```text
szonda ID
kalibrációs részkeretek
megérkezett indexek
hiányzó indexek
összefűzött kalibrációs bájtmező
```

A PTU számítások csak a szükséges kalibrációs részkeretek megérkezése után
aktiválódnak.

---

## 17. Bluetooth GPS Bridge

A Bluetooth worker:

```text
gps_bridge_bt.pl
```

Feladata:

1. szükséges parancsok ellenőrzése;
2. Bluetooth szolgáltatás elindítása;
3. RFKill tiltás feloldása;
4. adapter bekapcsolása;
5. párosítható és látható mód;
6. eszközkeresés;
7. előnyben részesített MAC kiválasztása vagy interaktív választás;
8. szükség esetén párosítás;
9. SDP szolgáltatás és RFCOMM csatorna megkeresése;
10. `/dev/rfcommN` kapcsolat létrehozása;
11. GPS JSON sorok továbbítása;
12. leálláskor RFCOMM és Bluetooth takarítás.

Szükséges parancsok:

```text
bluetoothctl
rfcomm
sdptool
systemctl
sudo
rfkill
```

A worker SIGINT, SIGTERM, SIGHUP, SIGQUIT és SIGPIPE esetén takarít.

## 17.1 Main általi GPS-feldolgozás

A main a worker teljes terminálforgalmát továbbíthatja a frontend
szolgáltatásablakába, de bázisfrissítésként csak érvényes JSON objektumot
fogad el.

Elvárt mezők:

```text
lat
lon
alt
heading_true vagy heading_mag vagy course
```

Sikeres frissítéskor:

```text
base_position_update
calculated_fields
opcionális SondeHub base update
```

---

## 18. SondeHub feltöltő

A worker:

```text
sondehub_upload.pl
```

Protokollverzió:

```bash
./sondehub_upload.pl --protocol-version
```

Kimenet:

```text
2
```

Kapcsolók:

```text
--dev
--help
--protocol-version
```

## 18.1 Bemeneti üzenetek

```text
message_type = sonde
message_type = base
```

A bemenet soronként egy JSON objektum.

## 18.2 Telemetria küldési feltételei

A main csak akkor továbbít `message_type=sonde` objektumot, ha egyszerre teljesül:

```text
a SondeHub worker aktív
élő record munkamenet fut
a keret VALID
calibration.complete = true
calibration.seen_count >= 51
```

WAV-, RAW- és JSON-visszajátszásból nem történik telemetriafeltöltés. Az 51 kalibrációs részkeret a `0x00–0x32` tartományt jelenti.

## 18.3 Telemetria kötegelése

A worker a telemetriát a `SONDEHUB_TELEMETRY_INTERVAL_S` szerint kötegeli, HTTP PUT kéréssel küldi, opcionálisan gzip tömörítést használ, és minden payloadot `.Slog` fájlba ír.

## 18.4 Valódi periodikus listener-frissítés

A bázisfeltöltés csak aktív MEGOSZTÁS mellett történik. A worker két állapotot tart:

```text
latest_base
    a legutóbb beérkezett bázispozíció

pending_base
    a következő listener PUT-ra váró pozíció
```

Sikeres listener PUT után a `latest_base` automatikusan visszakerül `pending_base` állapotba. Emiatt a következő listener-frissítés új GPS-esemény nélkül is megtörténik.

Időzítés:

```text
fix állomás: SONDEHUB_FIXED_BASE_INTERVAL_S
mobil állomás: SONDEHUB_MOBILE_BASE_INTERVAL_S
mozgási küszöb: SONDEHUB_BASE_MOVE_DISTANCE_M
minimális próbálkozási idő: SONDEHUB_BASE_MIN_INTERVAL_S
```

Példa:

```text
SONDEHUB_MOBILE_BASE_INTERVAL_S=120
SONDEHUB_BASE_MOVE_DISTANCE_M=100
SONDEHUB_BASE_MIN_INTERVAL_S=30
```

Ekkor 100 méternél kisebb mozgásnál 120 másodpercenként történik listener PUT. Legalább 100 méteres mozgásnál soron kívüli PUT válik esedékessé, de az előző próbálkozás óta legalább 30 másodpercnek el kell telnie.

## 18.5 MEGOSZTÁS/MOBIL változás és automatikus Open2 újraindítás

A GUI és a TUI ALKALMAZ művelete a bázis és frekvencia mellett a `share` és `mobile` értéket is továbbítja. A GUI a kapcsolók átváltásakor automatikusan ALKALMAZ kérést küld.

A main összehasonlítja a régi és új állapotot. Ha a MEGOSZTÁS vagy MOBIL érték megváltozott és a SondeHub szolgáltatás aktív, akkor kizárólag a worker folyamatot indítja újra:

```text
stop_service_worker('sondehub')
start_service_worker('sondehub')
```

Megmarad:

```text
service_pipe{sondehub} állapotobjektum
absztrakt UNIX socket
listener socket
frontend klienssocket
endpoint
token
GUI/TUI szolgáltatásablak
```

Csak a `sondehub_upload.pl` Open2 folyamat és annak STDIN/STDOUT pipe-ja cserélődik. Az új worker ugyanabba a már meglévő csatornába kerül vissza, ezért a frontendnek nem kell új terminált nyitnia vagy újracsatlakoznia.

## 18.6 Dev mód

```bash
./sondehub_upload.pl --dev
```

A payload létrejön és naplózódik, de tényleges HTTP feltöltés nem történik. A periodikus listener-újraütemezés dev módban is működik.

## 18.7 Naplózás

```text
sondehub_YYYY-MM-DD_HH-MM-SS.Slog
```

## 18.8 Teszt- és éles végpontok

Helyi teszt:

```text
SONDEHUB_TELEMETRY_API_URL=http://127.0.0.1:8080/sondes/telemetry
SONDEHUB_LISTENER_API_URL=http://127.0.0.1:8080/listeners
```

Éles SondeHub:

```text
https://api.v2.sondehub.org/sondes/telemetry
https://api.v2.sondehub.org/listeners
```

---

## 19. pipeConnect szolgáltatásarchitektúra

A MAIN, GUI, TUI és `terminal_service.pl` nem használ közvetlenül UNIX
socket API-t. A socketkezelés kizárólag a következő külön programban van:

```text
pipeConnect.pl
```

## 19.1 Fogadó mód

```bash
./pipeConnect.pl -R
```

Működés:

1. létrehoz egy véletlen Linux absztrakt UNIX socketet;
2. az stdout első sorában visszaadja a fogadó ID-t;
3. az első sor után az stdout változtatás nélküli RAW bájtfolyam.

## 19.2 Író mód

```bash
./pipeConnect.pl -W FOGADÓ_ID
```

A stdin RAW bájtfolyamát változtatás nélkül továbbítja.

## 19.3 Kétirányú kapcsolat

```text
UI → MAIN:
    UI:   pipeConnect.pl -W MAIN_ID
    MAIN: pipeConnect.pl -R

MAIN → UI:
    MAIN: pipeConnect.pl -W UI_ID
    UI:   pipeConnect.pl -R
```

A két irány külön absztrakt UNIX socketet használ.

## 19.4 Indítási kézfogás

1. Az UI elindít egy `pipeConnect.pl -R` folyamatot.
2. Beolvassa az UI fogadó ID-t.
3. A BT/SHUB kérésben elküldi ezt a MAIN-nek.
4. A MAIN létrehozza a saját `pipeConnect.pl -R` fogadóját.
5. A MAIN elindítja a `pipeConnect.pl -W UI_ID` írót.
6. A MAIN POSIX `fork/pipe/setsid/exec` mechanizmussal elindítja a workert.
7. A worker stdout-ja a MAIN UI felé író pipe-jára kerül.
8. A MAIN UI felől fogadó pipe-ja a worker stdin-jére kerül.
9. A MAIN `service_opened` üzenetben visszaküldi a saját fogadó ID-jét.
10. Az UI elindítja a `pipeConnect.pl -W MAIN_ID` írót.

## 19.5 GUI szolgáltatásterminál

A GUI a `terminal_service.pl` programot külön terminálban indítja. A
terminálsegéd adat- és vezérlőcsatornái egyaránt `pipeConnect.pl -R/-W`
folyamatokat használnak.

## 19.6 TUI szolgáltatásablak

A TUI közvetlenül tartja a saját `pipeConnect.pl -R/-W`
gyermekfolyamatait.

## 19.7 SondeHub worker újraindítása

MEGOSZTÁS vagy MOBIL változásakor kizárólag ez cserélődik:

```text
sondehub_upload.pl
worker STDIN pipe
worker STDOUT pipe
worker folyamatcsoport
```

Megmarad:

```text
MAIN pipeConnect -R
MAIN pipeConnect -W
UI pipeConnect -R
UI pipeConnect -W
MAIN–UI JSON vezérlőcsatorna
GUI/TUI szolgáltatásablak
```

A kontrollált újraindítás alatt egy régi worker EOF vagy írási hiba nem
bonthatja le a teljes szolgáltatáskapcsolatot.

## 19.8 Portabilitási határ

Az absztrakt UNIX socket Linux-specifikus részlete kizárólag a
`pipeConnect.pl` fájlban található. BSD vagy Hurd port esetén a főprogram
változtatása nélkül egy azonos `-R/-W` felületű másik implementáció
készíthető.

---

## 20. terminal_service.pl

A GUI külön termináljának kliense.

Kapcsolók:

```text
--endpoint NÉV
--token TOKEN
--service bt|sondehub
```

Működés:

1. absztrakt UNIX socket megnyitása;
2. `RS41_ATTACH` sor elküldése;
3. terminál raw módba állítása;
4. echo és kanonikus mód kikapcsolása;
5. XON/XOFF és CR-átalakítás kikapcsolása;
6. STDIN ↔ socket kétirányú relay;
7. terminál helyreállítása kilépéskor.

A GUI a következő terminálokat próbálja sorrendben:

```text
gnome-terminal
mate-terminal
xfce4-terminal
konsole
xterm
```

---

## 21. Indítás

## 21.1 Futtathatóság

A script- és bináris fájloknak futtathatóknak kell lenniük:

```bash
chmod +x \
	startGUI.sh \
	startTUI.sh \
	rs41_main.pl \
	rs41_gui.pl \
	rs41_tui.pl \
	rs41_filter_stream.py \
	rs41_raw_decode_fixed_fields.pl \
	gps_bridge_bt.pl \
	sondehub_upload.pl \
	pipe_delay.pl \
	terminal_service.pl \
	rs41_mod
```

## 21.2 GUI

```bash
./startGUI.sh
```

## 21.3 TUI

```bash
./startTUI.sh
```

## 21.4 Közvetlen indítási módok

```bash
./startGUI.sh -FELV
./startTUI.sh -FELV

./startGUI.sh -WAV="./log/felvetel.wav"
./startTUI.sh -WAV="./log/felvetel.wav"

./startGUI.sh -RAW="./log/felvetel.Rlog"
./startTUI.sh -RAW="./log/felvetel.Rlog"

./startGUI.sh -JSON="./log/felvetel.Jlog"
./startTUI.sh -JSON="./log/felvetel.Jlog"

./startGUI.sh -BT
./startTUI.sh -BT

./startGUI.sh -SHUB
./startTUI.sh -SHUB
```

Elfogadott aliasok:

```text
-FELV
--FELV
-RECORD
--RECORD

-BT
--BT

-SHUB
--SHUB
-SONDEHUB
--SONDEHUB
```

A FELV, WAV, RAW és JSON közül egyszerre csak egy indítási mód adható meg.

BT és SHUB bármelyikkel kombinálható.

Példa:

```bash
./startTUI.sh -FELV -BT -SHUB
```

## 21.5 Relatív fájlutak

A launcher a fájlutat ahhoz a könyvtárhoz képest oldja fel, ahonnan a
parancsot kiadták, majd abszolút útvonallá alakítja.

A fájlnak már launcherindításkor léteznie kell.

---

## 22. Konfigurációs rendszer

A `config.txt` formátuma:

```text
NÉV=érték
```

Prioritás:

```text
launcher ENV
    ↓
config.txt
    ↓
programba épített alapérték
```

## 22.1 Feldolgozási pipeline-ok

```text
PIPE_RECORD
PIPE_WAV
PIPE_RAW
PIPE_JSON
```

Hiányzó vagy üres kulcsnál a MAIN a beépített alapértéket használja.

## 22.2 Pipeline-helyettesítők

```text
{AUDIO_DEVICE}
{AUDIO_SAMPLE_RATE}
{AUDIO_LF}
{AUDIO_HF}
{AUDIO_ORDER}
{AUDIO_PEAK}
{AUDIO_DELAY}
{AUDIO_INVERT_ARG}
{FILTER}
{FILTER_COMMAND}
{FILTER_ARGS}
{RS41_MOD}
{MOD_COMMAND}
{MOD_ARGS}
{DECODER}
{PIPE_DELAY}
{INPUT_FILE}
{WAV_FILE}
{WAV_LOG_PIPE}
{RLOG_FILE}
{JLOG_FILE}
{PERL}
{PROJECT_DIR}
```

## 22.3 FILTER/MOD program és argumentum

```text
{FILTER_COMMAND}
    csak a szűrőprogram

{FILTER_ARGS}
    az aktuális szűrőparaméterek

{MOD_COMMAND}
    csak a demodulátor program

{MOD_ARGS}
    az aktuális demodulátor-paraméterek
```

Így az `rs41_mod` és `rs41_mod.py` között configszinten lehet választani,
miközben az Inverz opció dinamikusan bekerül a `MOD_ARGS` értékébe.

## 22.4 Élő monitorozó és WAV-napló ág

```text
WAV_LOG_ENABLED
RECORD_MONITOR_COMMAND
```

A `WAV_LOG_ENABLED` alapértéke `1`. Hiányzó, üres vagy kommentelt
bejegyzésnél a WAV-napló engedélyezett.

A `RECORD_MONITOR_COMMAND` új helyettesítője:

```text
{WAV_LOG_PIPE}
```

Értéke:

```text
WAV_LOG_ENABLED=1:
    | tee -- {WAV_FILE}

WAV_LOG_ENABLED=0:
    üres
```

Ez külön konfigurálható, mert az alapértelmezett `arecord/aplay` Linux
ALSA-függő.

## 22.5 BT és SondeHub workerindítás

```text
BT_WORKER_COMMAND
SONDEHUB_WORKER_COMMAND
```

A MAIN ezeket általános POSIX folyamatindítással futtatja.

A jelenlegi Linux alapértékek:

```text
BT_WORKER_COMMAND:
    script -qefc "exec {PERL} {BT_WORKER} 2>&1" /dev/null

SONDEHUB_WORKER_COMMAND:
    exec {PERL} {SONDEHUB_WORKER} 2>&1
```

A platformfüggő PTY-wrapper kizárólag a `BT_WORKER_COMMAND` értékben
szerepel.

## 22.6 Launcher config-felülbírálás

A `startGUI.sh` és `startTUI.sh` nem használ config-név whitelistet.
Minden olyan configbeállítás átadható, amelynek neve csak ezt tartalmazza:

```text
A–Z
0–9
_
```

Példák:

```bash
./startGUI.sh -WAV_LOG_ENABLED=0
./startTUI.sh -WAV_LOG_ENABLED=1
./startGUI.sh -PIPE_RECORD='egyedi parancs'
./startTUI.sh -SONDEHUB_MOBILE_BASE_INTERVAL_S=120
```

A `CONFIG:` és `CFG:` előtag is használható:

```bash
./startGUI.sh -CONFIG:WAV_LOG_ENABLED=0
./startTUI.sh -CFG:WAV_LOG_ENABLED=0
```

A launcher az értékeket környezeti változóként adja át. A prioritás:

```text
launcher paraméter / ENV
    ↓
config.txt
    ↓
beépített alapérték
```

Szóközt vagy shell-speciális karaktert tartalmazó értéknél a teljes
argumentumot shell-idézőjelbe kell tenni.

Az ellenőrzés szerint a jelenlegi `config.txt` összes
config-beállításneve megfelel ennek a névformátumnak, ezért mindegyik
felülbírálható mindkét launcherrel.

## 22.7 Futás közbeni állapot

A GUI és TUI nem írja vissza automatikusan a `config.txt` fájlt. A futás
közbeni settings állapot tulajdonosa a MAIN.

---

## 23. Konfigurációs felelősség

A `config.txt` fájlt közvetlenül ezek olvassák:

```text
rs41_main.pl
gps_bridge_bt.pl
sondehub_upload.pl
```

Nem olvassa közvetlenül:

```text
rs41_gui.pl
rs41_tui.pl
startGUI.sh
startTUI.sh
rs41_filter_stream.py
rs41_raw_decode_fixed_fields.pl
terminal_service.pl
```

A TUI a kezdeti beállításokat a main `initialize` üzenetéből kapja.

A GUI szintén a main állapotát használja.

A GUI és TUI futás közbeni változtatásai nem írják át a `config.txt`
fájlt.

---

## 24. Konfigurációs kulcsok

## 24.1 SondeHub API és azonosítás

| Kulcs | Beépített alapérték | Jelentés |
| --- | --- | --- |
| `SONDEHUB_TELEMETRY_API_URL` | hivatalos telemetry URL | Telemetria PUT végpont |
| `SONDEHUB_LISTENER_API_URL` | hivatalos listener URL | Listener PUT végpont |
| `SONDEHUB_SOFTWARE_NAME` | `DsRS41Tracker` | Jelentett szoftvernév |
| `DSRS41TRACKER_VERSION` | `0.2.46` | Teljes alkalmazásverzió |
| `SONDEHUB_SOFTWARE_VERSION` | `0.2.46` | Jelentett verzió |
| `SONDEHUB_UPLOADER_CALLSIGN` | `SWL` | Feltöltő azonosító |
| `SONDEHUB_MANUFACTURER` | `Vaisala` | Gyártó |
| `SONDEHUB_TYPE` | `RS41` | Főtípus |
| `SONDEHUB_SUBTYPE` | `RS41-SGP` | Altípus |
| `SONDEHUB_RECEIVER` | `UNDEFINED` | Rádióvevő |
| `SONDEHUB_RECEIVER_FIRMWARE` | `UNDEFINED` | Firmware |
| `SONDEHUB_ANTENNA` | `UNDEFINED` | Antenna |

## 24.2 SondeHub működés

| Kulcs | Alapérték | Jelentés |
| --- | ---: | --- |
| `SONDEHUB_SHARE` | `0` | Bázispozíció megosztása |
| `SONDEHUB_MOBIL` | `0` | Mobil listener |
| `SONDEHUB_HTTP_TIMEOUT_S` | `15` | HTTP időkorlát |
| `SONDEHUB_FREQUENCY_MHZ` | `400.000` | Vételi frekvencia |
| `SONDEHUB_TELEMETRY_INTERVAL_S` | `30` | Telemetriaköteg időköze |
| `SONDEHUB_FIXED_BASE_INTERVAL_S` | `21600` | Fix bázis időköze |
| `SONDEHUB_MOBILE_BASE_INTERVAL_S` | `600` | Mobil bázis időköze |
| `SONDEHUB_BASE_MIN_INTERVAL_S` | `30` | Minimális próbálkozási idő |
| `SONDEHUB_BASE_MOVE_DISTANCE_M` | `100` | Soron kívüli elmozdulás |
| `SONDEHUB_GZIP_ENABLED` | `0` | HTTP gzip |

A csatolt configban a frekvencia aktív értéke:

```text
403.700 MHz
```

A mobil bázis aktív időköze:

```text
60 másodperc
```

## 24.3 Naplózás

| Kulcs | Alapérték | Jelentés |
| --- | --- | --- |
| `LOG_DIRECTORY` | `./log` | WAV/Rlog/Jlog/Slog mappa |

A main abszolút útvonallá alakítja. Ha a mappa nem létezik, a projekt
könyvtárára eshet vissza.

## 24.4 Bluetooth

| Kulcs | Alapérték | Jelentés |
| --- | --- | --- |
| `RFCOMM_DEVICE_NUMBER` | `0` | RFCOMM sorszám |
| `RFCOMM_DEVICE_PATH` | `/dev/rfcomm0` | Eszközút |
| `GPS_SERVICE_NAME` | `GPS Bridge` | SDP szolgáltatásnév |
| `SCAN_TIME_SECONDS` | `15` | Keresési idő |
| `PREFERRED_DEVICE_MAC` | üres | Automatikusan választandó MAC |

## 24.5 Bázis

| Kulcs | Alapérték |
| --- | ---: |
| `BASE_LAT` | `47.49786` |
| `BASE_LON` | `19.04022` |
| `BASE_ALT` | `110` |
| `BASE_ANGLE` | `0` |

## 24.6 Térkép

| Kulcs | Alapérték |
| --- | --- |
| `MAP_START_LAT` | `47.49786` |
| `MAP_START_LON` | `19.04022` |
| `MAP_START_ZOOM` | `9` |
| `TILE_SERVER` | OpenStreetMap |
| `BASE_ARROW_COLOR` | `#42c9ff` |
| `SONDE_ARROW_COLOR` | `#e3a52b` |
| `TRACK_COLOR` | `#e3a52b` |
| `TRACK_WIDTH` | `4` |
| `TRACK_POINT_RADIUS` | `3` |
| `TRACK_OPACITY` | `0.9` |

A csatolt config aktív eltérései:

```text
TRACK_WIDTH=1
TRACK_POINT_RADIUS=2
```

## 24.7 Audio és demoduláció

| Kulcs | Main alapérték | Jelentés |
| --- | ---: | --- |
| `AUDIO_DEVICE` | `default` | ALSA eszköz |
| `AUDIO_SAMPLE_RATE` | `48000` | Mintavétel |
| `AUDIO_LF` | `525` | Magasáteresztő vágás |
| `AUDIO_HF` | `14000` | Aluláteresztő vágás |
| `AUDIO_ORDER` | `1` | Butterworth rend |
| `AUDIO_PEAK` | `0.75` | AGC célcsúcs |
| `AUDIO_DELAY` | `0.1` | Feldolgozási blokk |
| `AUDIO_INVERT` | `1` | Demodulátor invertálás |
| `WAV_LOG_ENABLED` | `1` | Élő WAV-napló engedélyezése |

---

## 25. Függőségek és Debian telepítés

A következő parancsok nem használnak automatikus `-y` kapcsolót.

## 25.1 Perl alap és TUI

```bash
sudo apt install \
	perl \
	libcurses-perl \
	libio-compress-perl
```

A Perl alaprendszer biztosítja többek között a `JSON::PP`, `IO::Select`,
`IPC::Open2`, `Time::HiRes`, `File::Spec`, `POSIX` és `Fcntl` modulokat.

## 25.2 GTK3/WebKit2 GUI

```bash
sudo apt install \
	libgtk3-perl \
	libglib-perl \
	libglib-object-introspection-perl \
	libgtk3-webkit2-perl
```

A `libgtk3-webkit2-perl` a `Gtk3::WebKit2` Perl-kötést biztosítja Debian
Bookworm és Trixie rendszeren.

## 25.3 Python szűrő és Python demodulátor

```bash
sudo apt install \
	python3 \
	python3-numpy \
	python3-scipy
```

Az `rs41_mod.py` közvetlen függősége Python 3 és NumPy. A
`rs41_filter_stream.py` SciPy-t is használ.

## 25.4 Audio és feldolgozás

```bash
sudo apt install \
	alsa-utils \
	sox \
	util-linux
```

A `sox` kötelező a WAV-visszajátszási pipeline alapértelmezett
megvalósításához.

Az `alsa-utils` biztosítja az alapértelmezett Linux konfigurációban
használt `arecord` és `aplay` programokat.

## 25.5 Bluetooth GPS

```bash
sudo apt install \
	bluez \
	rfkill \
	util-linux \
	sudo
```

A Bluetooth worker ezen kívül a rendszer `systemctl`, `bluetoothctl`,
`rfcomm` és `sdptool` programjait használja.

## 25.6 GUI terminál

Legalább egy támogatott terminálemulátor szükséges. Például:

```bash
sudo apt install xterm
```

Támogatott lehet még:

```text
gnome-terminal
mate-terminal
xfce4-terminal
konsole
xterm
```


---

## 26. Projektfájlok

| Fájl | Sor/méret | Szerep |
| --- | ---: | --- |
| `config.txt` | 194 sor | Teljes konfiguráció |
| `dsPGtkGUI.pm` | 194 sor | Gtk3/Glade segédmodul |
| `gps_bridge_bt.pl` | 988 sor | Bluetooth RFCOMM GPS worker |
| `pipe_delay.pl` | 62 sor | RAW/JSON sebességkorlát |
| `rs41_filter_stream.py` | 430 sor | Audio szűrés és AGC |
| `rs41_mod.py` | – | Python GFSK demodulátor és RS hibajavító |
| `RS41_MOD_PYTHON.md` | – | Python demodulátor mérési dokumentációja |
| `rs41_gui.pl` | 774 sor | GTK3/WebKit2 frontend |
| `rs41_main.pl` | 1776 sor | Központi backend |
| `rs41_mod` | 114240 byte | x86-64 RS41 demodulátor |
| `rs41_raw_decode_fixed_fields.pl` | 972 sor | RAW dekóder |
| `rs41_tui.pl` | 3450 sor | Curses frontend |
| `RS41FrontendData.pm` | 339 sor | Közös frontend-adatmodell |
| `RS41IPC.pm` | 110 sor | JSON IPC |
| `sondehub_upload.pl` | 913 sor | SondeHub worker |
| `startGUI.sh` | 352 sor | GUI launcher |
| `startTUI.sh` | 349 sor | TUI launcher |
| `terminal_service.pl` | 108 sor | GUI szolgáltatásterminál-kliens |
| `UI.glade` | 840 sor | GTK felületleírás |
| `UI.html` | 882 sor | Térkép és webes adatpanel |

---

## 27. Fájlok részletes kapcsolata

### `rs41_main.pl`

A rendszer központja:

- config betöltés;
- ENV felülbírálás;
- pipeline indítás/leállítás;
- gyermekfolyamatok;
- RAW/JSON sorok fogadása;
- statisztika;
- sticky számítási pozíció;
- távolság/bearing/elevation;
- GUI/TUI IPC;
- ALKALMAZ/MENTÉS;
- pipeline-újraindítás;
- BT GPS;
- SondeHub;
- közvetlen szolgáltatássocket;
- teljes leállítás.

### `rs41_gui.pl`

- GUI widgetek;
- felhasználói események;
- fájlválasztók;
- beállítási draft;
- ALKALMAZ és MENTÉS;
- WebKit JavaScript;
- map és adatpanel;
- külön BT/SHUB terminál.

### `rs41_tui.pl`

- TUI elrendezés;
- menü;
- 28 értékes táblázat;
- beállítási draft;
- fájlválasztó;
- billentyűzet;
- egér;
- közvetlen main szolgáltatáskapcsolat;
- teljes újrarajzolás;
- diagnosztika.

### `UI.glade`

A GTK widgethierarchia és signalnevek forrása.

### `UI.html`

A beágyazott térkép és webes adatpanel.

### `dsPGtkGUI.pm`

A Glade betöltés és automatikus signal-kapcsolás általános rétege.

### `RS41IPC.pm`

A main és frontend közös JSON protokollrétege.

### `RS41FrontendData.pm`

A GUI és TUI közös megjelenítési logikája.

### `terminal_service.pl`

A GUI által megnyitott külön terminál közvetlen kliensprogramja.

---

## 28. Normál használati folyamat

### Élő vétel

1. Csatlakoztasd a rádió audio kimenetét.
2. Ellenőrizd az ALSA eszközt.
3. Indítsd a GUI-t vagy TUI-t.
4. Állítsd be a frekvenciát és bázist.
5. Aktiváld a FELV menüt.
6. Figyeld a VALID/PARTIAL/INVALID arányt.
7. Szükség esetén indíts BT GPS-t.
8. Éles SondeHub URL mellett indíts SHUB-ot.
9. Leállításhoz aktiváld az ÁLLJ menüt.
10. Frontendbezáráskor a main minden szolgáltatást leállít.

### Korábbi felvétel

```text
WAV
    teljes újrafeldolgozás

RAW
    újradekódolás

JSON
    dekódolt események visszajátszása
```

---

## 29. Tesztelés

## 29.1 Perl szintaxis

```bash
perl -I. -c rs41_main.pl
perl -I. -c rs41_gui.pl
perl -I. -c rs41_tui.pl
perl -I. -c gps_bridge_bt.pl
perl -I. -c rs41_raw_decode_fixed_fields.pl
perl -I. -c sondehub_upload.pl
perl -I. -c terminal_service.pl
```

A GUI-hoz Gtk3/WebKit2, a TUI-hoz Curses szükséges már a fordítási
ellenőrzéshez is.

## 29.2 Python

```bash
python3 -m py_compile rs41_filter_stream.py
```

## 29.3 TUI verzió

```bash
./rs41_tui.pl --version
```

## 29.4 Demodulátor

```bash
file rs41_mod
./rs41_mod --help
```

## 29.5 RAW dekóder

```bash
cat -- ./log/minta.Rlog \
	| ./rs41_raw_decode_fixed_fields.pl --json
```

## 29.6 JSON visszajátszás

```bash
./startTUI.sh -JSON="./log/minta.Jlog"
```

## 29.7 WAV feldolgozás

```bash
./startGUI.sh -WAV="./log/minta.wav"
```

## 29.8 ALKALMAZ

1. Indíts FELV vagy WAV feldolgozást.
2. Módosíts bázispozíciót vagy frekvenciát.
3. Nyomd meg az ALKALMAZ gombot.
4. Ellenőrizd, hogy a pipeline nem indul újra.
5. Ellenőrizd a `settings_state` visszatöltést.

## 29.9 MENTÉS

1. Indíts WAV vagy RAW feldolgozást.
2. Módosíts audio- vagy szűrőértéket.
3. Nyomd meg a MENTÉS gombot.
4. Ellenőrizd a szabályos leállást.
5. Ellenőrizd, hogy ugyanaz a fájl újraindul.

## 29.10 TUI bezárási szabály

Álló helyzetben:

```text
BEÁLL. → módosítás → Esc
```

Elvárt:

```text
ALKALMAZ + MENTÉS
```

Futó helyzetben:

```text
FELV/WAV/RAW/JSON → BEÁLL. → módosítás → Esc
```

Elvárt:

```text
csak ALKALMAZ
```

## 29.11 SondeHub worker automatikus újraindítás

1. Indítsd el a SondeHub szolgáltatást.
2. Jegyezd fel az endpointot és a megnyitott terminált.
3. Változtasd meg a MEGOSZTÁS vagy MOBIL állapotot.
4. Ellenőrizd az POSIX pipe worker újraindítási üzenetet.
5. Ellenőrizd, hogy a szolgáltatásablak nyitva maradt.
6. Ellenőrizd, hogy az endpoint és token nem változott.
7. Ellenőrizd, hogy az új worker listener PUT üzenetet küld.

## 29.12 Periodikus mobil listener teszt

```text
SONDEHUB_MOBILE_BASE_INTERVAL_S=120
SONDEHUB_BASE_MIN_INTERVAL_S=30
SONDEHUB_BASE_MOVE_DISTANCE_M=100
```

1. Kapcsold be a MEGOSZTÁS és MOBIL állapotot.
2. Küldj egy érvényes bázispozíciót.
3. Ellenőrizd az első listener PUT-ot.
4. Ne küldj újabb GPS-pozíciót.
5. Ellenőrizd, hogy körülbelül 120 másodperc után újabb PUT történik.
6. Küldj legalább 100 méterrel eltérő pozíciót.
7. Ellenőrizd, hogy a következő PUT legkorábban 30 másodperc után történik.

## 29.13 TUI redraw

Tesztelendő:

- fájlválasztó Esc;
- fájl Enter;
- BT HOME;
- BT END;
- SHUB HOME;
- SHUB END;
- beállításablak Esc;
- ÁLLJ;
- természetes pipe EOF.

A menüsornak és minden panelnek azonnal teljesen helyre kell állnia.

---

### 29.14 Hibakeresés

#### A GUI nem indul

Ellenőrizd:

```text
Gtk3 Perl modul
Gtk3::WebKit2 Perl modul
UI.glade
UI.html
dsPGtkGUI.pm
DISPLAY / grafikus munkamenet
```

#### A TUI nem indul

Ellenőrizd:

```text
libcurses-perl
UTF-8 locale
legalább 132×45 terminál
RS41IPC.pm
RS41FrontendData.pm
```

#### A menüsor eltűnik ÁLLJ után

A 0.2.46 verzió `running_state=0` esetén `clearok()`, `touchwin()` és teljes
újrarajzolást használ. Ellenőrizd:

```bash
./rs41_tui.pl --version
```

#### Nincs hang

```bash
arecord -l
arecord -D default -t wav -f S16_LE -r 48000 -c 1 /tmp/test.wav
aplay /tmp/test.wav
```

#### A szűrő leáll

Ellenőrizd:

```text
LF > 0
HF > LF
HF < sample_rate / 2
order >= 1
peak 0 és 1 között
delay >= 0.1
NumPy és SciPy telepítve
```

#### A WAV nem indul

Ellenőrizd:

- olvasható fájl;
- SoX telepítve;
- nincs másik munkamenet;
- a fájl WAV formátumú;
- a fájlútvonal nem tartalmaz sortörést vagy NUL-t.

#### RAW nem dekódolódik

Ellenőrizd:

- az Rlog valódi `rs41_mod -r` sorokat tartalmaz;
- legalább 640 hex karakter van soronként;
- a dekóder futtatható;
- a fájl nem bináris.

#### Bluetooth nem indul

Ellenőrizd:

```text
bluez
rfkill
sudo
bluetooth.service
RFCOMM kernelmodul
GPS Bridge SDP szolgáltatás
terminálos jelszóbevitel
```

#### SondeHub nem tölt fel

Elsőként ellenőrizd, hogy a config nem localhost teszt URL-t használ-e.

Telemetria esetén ellenőrizd:

```text
élő record munkamenet
VALID keret
calibration.complete = true
calibration.seen_count >= 51
```

Listener esetén ellenőrizd:

```text
SONDEHUB_SHARE = 1
MOBIL állapot bekerült-e a settings_state válaszba
a SondeHub worker újraindult-e a kapcsolóváltás után
a worker terminálja továbbra is csatlakoztatva van-e
latest_base és pending_base periodikus újraütemezése működik-e
```

További ellenőrzés:

```text
internet
TLS tanúsítványok
hívójel
SONDEHUB_SHARE
HTTP státusz
.Slog fájl
```

#### A távolság vagy irány eltűnik

A main csak teljes, numerikus szondapozíciót fésül be. Ellenőrizd, hogy a
futtatott `rs41_main.pl` a jelenlegi verzió, és nem egy régi másolat van a
PATH-ban vagy más könyvtárban.

#### A szolgáltatásterminál nem nyílik meg

Ellenőrizd:

- `terminal_service.pl` futtatható;
- legalább egy támogatott terminál telepítve;
- a frontend megkapta a `service_opened` üzenetet;
- a token és endpoint nem üres;
- Linux absztrakt UNIX socket támogatott.

---

## 30. Biztonsági és adatvédelmi megjegyzések

- A Bluetooth worker `sudo` parancsokat használ.
- A sudo jelszó a PTY terminálon kerül bekérésre.
- A main szolgáltatássocket helyi és tokennel védett, de nem hálózati
  hitelesítési rendszer.
- A SondeHub szolgáltatás pozíciót és telemetriát küld külső szerverre.
- A `SONDEHUB_SHARE=1` bázispozíció-megosztást jelent.
- Mobil módnál a listener pozíció gyakrabban frissülhet.
- A `.Slog` fájl feltöltési payloadokat tartalmaz.
- A configban szereplő hívójel, rádió és antenna publikus payloadba kerülhet.
- A futás közbeni beállítások csak memóriában élnek, nem kerülnek
  automatikusan tartós mentésre.

---

## 31. Rövid referencia

### Indítás

```bash
./startGUI.sh
./startTUI.sh
```

### Élő vétel

```bash
./startTUI.sh -FELV
```

### WAV

```bash
./startGUI.sh -WAV="./log/minta.wav"
```

### RAW

```bash
./startTUI.sh -RAW="./log/minta.Rlog"
```

### JSON

```bash
./startTUI.sh -JSON="./log/minta.Jlog"
```

### BT + SondeHub

```bash
./startTUI.sh -FELV -BT -SHUB
```

### TUI verzió

```bash
./rs41_tui.pl --version
```

### Feldolgozás leállítása

```text
GUI: ÁLLJ gomb
TUI: 5 vagy ÁLLJ menü
```

### Beállítások

```text
ALKALMAZ
    bázis + frekvencia
    nincs pipeline-restart

MENTÉS
    minden beállítás
    aktív pipeline újraindulhat
```

---

## 32. Összefoglalás

A DsRS41Tracker jelenlegi változata egy központi main folyamat köré épülő,
kétfrontendes RS41 feldolgozó rendszer.

A GUI és TUI:

- ugyanazt a dekódolt adatot használja;
- ugyanazt a beállításállapotot kapja;
- ugyanazt az ALKALMAZ/MENTÉS protokollt használja;
- ugyanazokat a BT és SondeHub szolgáltatásokat vezérli.

A main:

- kizárólagosan kezeli a pipeline-t;
- biztosítja a folyamatcsoportok szabályos leállítását;
- újraindítja a feldolgozást teljes mentés után;
- MEGOSZTÁS/MOBIL változáskor automatikusan újraindítja kizárólag a SondeHub POSIX pipe workert;
- az POSIX pipe worker cseréje közben megtartja a meglévő socketet, tokent és frontendkapcsolatot;
- kezeli a közös statisztikát és vektorszámítást;
- saját absztrakt UNIX socketen szolgálja ki az interaktív szolgáltatásokat;
- a frontendeknek mindig visszaküldi a tényleges beállításállapotot.

A SondeHub worker csak élő, VALID és teljes 51 keretes kalibrációjú telemetriát továbbít, a listener pozíciót sikeres feltöltés után automatikusan újraütemezi, és együtt alkalmazza a fix/mobil időközt, a mozgási küszöböt és a minimális próbálkozási időt.

A TUI 0.2.46 teljes újrarajzolási mechanizmusa a popupok és a feldolgozási
pipe lezárása után is helyreállítja a teljes képernyőt.

