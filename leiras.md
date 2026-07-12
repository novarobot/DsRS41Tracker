# DsRS41Tracker rádiószonda-vevő és követőrendszer

Aktuális rendszer-, felhasználói-, üzemeltetési és fejlesztői dokumentáció
Állapot: 2026. július 12.
Célrendszer: Debian-alapú Linux
Fő kezelőfelület: Perl + GTK3 + WebKit2GTK
Demodulátor: helyi `./rs41_mod` futtatható állomány

## 1. A dokumentum célja

A leírás egyszerre szolgál telepítési útmutatóként, felhasználói kézikönyvként, üzemeltetési dokumentációként és fejlesztői áttekintésként.
A rendszer célja Vaisala RS41 típusú rádiószondák rádiójelének valós idejű vétele, szűrése, demodulálása, dekódolása, megjelenítése és követése.
A dokumentum külön ismerteti a grafikus kezelőfelületet, a parancssori segédprogramokat, a Bluetooth GPS-hidat és az Android alkalmazást.

## 2. A rendszer célja és feladata

- A rádió vagy hangkártya kimenetéről érkező hangjel rögzítése.
- A vett hang digitális előfeldolgozása.
- A hasznos frekvenciatartomány kiemelése.
- A túl alacsony és túl magas frekvenciák csillapítása.
- A jelszint automatikus vagy félautomatikus normalizálása.
- A szűrt hangfolyam átadása a helyi demodulátornak.
- Az RS41 moduláció demodulálása.
- A nyers RS41 keretek előállítása.
- A kereten belüli részcsomagok felismerése.
- A részcsomagok CRC-ellenőrzése.
- A GPS-adatok kinyerése.
- A szondaazonosító kinyerése.
- A telepfeszültség kinyerése.
- A keretszámláló feldolgozása.
- A kalibrációs részkeretek összegyűjtése.
- A hőmérséklethez kapcsolódó nyers adatok feldolgozása.
- A páratartalomhoz kapcsolódó nyers adatok feldolgozása.
- A nyomásérzékelő adatainak feldolgozása, ha rendelkezésre állnak.
- A GPS-magasságból becsült légnyomás előállítása.
- A szonda koordinátáinak térképes megjelenítése.
- A bázispont koordinátáinak kézi kezelése.
- A bázispont koordinátáinak telefonról történő frissítése.
- A telefon irányszögének megjelenítése.
- A szonda mozgási irányának megjelenítése.
- A vett hang WAV-mentése.
- A teljes feldolgozási lánc grafikus indítása és leállítása.
- A parancssori programok önálló tesztelhetőségének megtartása.

## 3. A rendszer fő komponensei

### `rs41_gui.pl`
A Perl/GTK3 alapú grafikus kezelőfelület.

### `rs41_filter_stream.py`
A valós idejű hangszűrő és jelszint-előkészítő.

### `rs41_mod`
A projekt helyi könyvtárában található RS41 demodulátor.

### `rs41_raw_decode_fixed_fields.pl`
A nyers RS41 kereteket feldolgozó Perl-dekóder.

### `gps_bridge_bt.pl`
A telefon és a GUI közötti Bluetooth GPS-híd.

### `sondehub_upload.pl`
A dekódolt szonda- és bázisadatokat ellenőrző, majd a SondeHub API felé továbbító Perl-program.

### `pipe_delay.pl`
Opcionális sorsebesség-korlátozó segédprogram csővezetékek és napló-visszajátszás teszteléséhez.

### `config.txt`
A GUI, a Bluetooth-híd és a SondeHub-feltöltő közös, egyszerű `MEZŐ=érték` formátumú konfigurációs fájlja.

### Android GPS Bridge alkalmazás
A telefon GPS- és szenzoradatainak gyűjtője és továbbítója.

### `arecord`
Az ALSA szabványos hangrögzítő programja.

### `tee`
A nyers hangfolyam elágaztatására és WAV-fájlba mentésére használható program.

### WebKit2GTK térképnézet
A bázis és a szonda térképes megjelenítésére szolgáló HTML/JavaScript réteg.

## 4. Magas szintű rendszerarchitektúra

A rádiószonda-adatfolyam fő útvonala:

```text
Rádió vagy hangkártya
        |
        v
     arecord
        |
        v
rs41_filter_stream.py
        |
        v
   ./rs41_mod
        |
        v
rs41_raw_decode_fixed_fields.pl
        |
        v
      GUI
```

A telefonos bázisadat útvonala:

```text
Android telefon
        |
        | Bluetooth SPP / RFCOMM
        v
 gps_bridge_bt.pl
        |
        v
      GUI
```

A két adatút egymástól függetlenül működik.
A GUI a két adatforrást közös állapotmodellben egyesíti.
A szonda helyzetét a rádiós dekóder adja.
A bázis helyzetét és tájolását az Android telefon adja.

## 5. Támogatott operációs rendszer

- A rendszer elsődleges célplatformja Linux.
- A fejlesztési és üzemi környezet Debian 12 vagy Debian 13.
- A program nem igényel natív Windows környezetet.
- A grafikus felület X11 alatt használható.
- Wayland alatt a működés a GTK3 és a terminálemulátor támogatásától függ.
- A Bluetooth funkciók a BlueZ rendszerre épülnek.
- A hangrögzítés az ALSA rendszerre épül.
- A térképnézet WebKit2GTK beágyazott böngészőmotort használ.

## 6. Könyvtárstruktúra

```text
DsRS41Tracker/
├── config.txt
├── rs41_gui.pl
├── rs41_filter_stream.py
├── rs41_mod
├── rs41_raw_decode_fixed_fields.pl
├── gps_bridge_bt.pl
├── sondehub_upload.pl
├── pipe_delay.pl
├── leiras.md
└── SRC/
    └── RS/
```

## 7. Telepítési függőségek

### 7.1. Alapcsomagok Debian alatt

```bash
sudo apt update

sudo apt install \
	perl \
	python3 \
	python3-pip \
	alsa-utils \
	bluez \
	rfkill \
	libgtk3-perl \
	libgtk3-webkit2-perl \
	libjson-perl \
	libipc-run-perl \
	libproc-processtable-perl \
	gnome-terminal \
	xterm
```

### 7.2. Python csomagok

```bash
sudo apt install \
	python3-numpy \
	python3-scipy
```

### 7.3. Perl modulok

- `strict`
- `warnings`
- `POSIX`
- `IO::Handle`
- `IO::Select`
- `File::Spec`
- `File::Basename`
- `FindBin`
- `Time::HiRes`
- `Getopt::Long`
- `IPC::Open3`
- `Fcntl`
- `JSON` vagy `JSON::PP`
- `Gtk3`
- `Gtk3::WebKit2`

A legtöbb alapmodul a Perl része.
A GTK3 és WebKit2 Perl-kötéseket külön Debian csomagok telepítik.

### 7.4. ALSA függőségek

Az `arecord` program az `alsa-utils` csomag része.
```bash
arecord --version
arecord -l
arecord -L
```

A GUI által használt bemeneti eszköz lehet például `default` vagy egy konkrét `hw:X,Y` eszköz.

### 7.5. Bluetooth függőségek

- `bluetoothctl`
- `bluetoothd`
- `rfcomm`
- `btmgmt`
- `rfkill`
- `systemctl`
```bash
bluetoothctl --version
rfcomm --help
rfkill list bluetooth
systemctl status bluetooth
```

### 7.6. Terminálemulátor

A `gps_bridge_bt.pl` külön terminálablakot nyit.
Támogatható terminálok:
- gnome-terminal
- xfce4-terminal
- mate-terminal
- konsole
- xterm

### 7.7. Helyi `rs41_mod` program

A `rs41_mod` nem rendszeresen telepített parancs.
A bináris a projekt mappájában található. Ezt külön kell fordítani a SRC/RS mappában lévő projektből!
```bash
ls -l ./rs41_mod
file ./rs41_mod
chmod +x ./rs41_mod
./rs41_mod --help
```

## 8. Fájljogosultságok

```bash
chmod +x \
	./rs41_gui.pl \
	./rs41_filter_stream.py \
	./rs41_mod \
	./rs41_raw_decode_fixed_fields.pl \
	./gps_bridge_bt.pl \
	./sondehub_upload.pl \
	./pipe_delay.pl
```

A Perl programok első sora:
```perl
#!/usr/bin/env perl
```

A Python program első sora:
```python
#!/usr/bin/env python3
```

## 9. Telepítés utáni ellenőrzés

- Az `arecord` elérhető.
- A Python 3 elérhető.
- A Perl elérhető.
- A GTK3 Perl-kötés betölthető.
- A WebKit2GTK Perl-kötés betölthető.
- A `./rs41_mod` létezik.
- A `./rs41_mod` futtatható.
- A Perl scriptek szintaktikailag hibátlanok.
- A Python szűrő lefordítható bytecode-ra.
- A Bluetooth adapter látható.
```bash
which arecord
which python3
which perl

perl -MGtk3 -e 'print "Gtk3 OK\n"'
perl -MGtk3::WebKit2 -e 'print "WebKit2 OK\n"'

test -x ./rs41_mod && echo "./rs41_mod OK"

perl -c ./rs41_gui.pl
perl -c ./rs41_raw_decode_fixed_fields.pl
perl -c ./gps_bridge_bt.pl
perl -c ./sondehub_upload.pl
perl -c ./pipe_delay.pl

python3 -m py_compile ./rs41_filter_stream.py
```

## 10. A GUI indítása

```bash
./rs41_gui.pl
```

A GUI lehetőleg a saját fájljának könyvtárából képezze a helyi segédprogramok abszolút elérési útját.
A javasolt Perl-megoldás a `FindBin` modul használata.
```perl
use FindBin qw($Bin);

my $filter_path  = "$Bin/rs41_filter_stream.py";
my $mod_path     = "$Bin/rs41_mod";
my $decode_path  = "$Bin/rs41_raw_decode_fixed_fields.pl";
my $gps_path     = "$Bin/gps_bridge_bt.pl";
```

Ezzel a GUI más munkakönyvtárból indítva is megtalálja a helyi komponenseket.

## 11. A grafikus kezelőfelület áttekintése

- Felső vezérlősor a vétel indításához és leállításához.
- Bluetooth kapcsolat gomb a Leállítás gomb jobb oldalán.
- Bázispont koordináta- és iránymezők.
- Hang- és szűrőparaméterek.
- Szondaadat-mezők.
- Térképes megjelenítés.
- Alsó terminál- vagy naplóterület.
- Állapotjelzők.

## 12. Első vezérlősor

- Indítás gomb.
- Leállítás gomb.
- Bluetooth kapcsolat gomb.
- WAV-mentés kapcsoló.
- WAV-kimeneti könyvtár vagy fájlnév.
- Hangbemenet kiválasztása.
- Feldolgozási állapot.

### 12.1. Indítás gomb

Az Indítás gomb létrehozza a teljes rádiószonda-feldolgozási láncot.
A gomb megnyomásakor a GUI ellenőrzi a szükséges programokat.
A GUI ellenőrzi a helyi `./rs41_mod` fájlt.
A GUI létrehozza a pipe kapcsolatokat.
A GUI elindítja az `arecord` programot.
A GUI elindítja a `rs41_filter_stream.py` programot.
A GUI elindítja a `./rs41_mod` programot.
A GUI elindítja a `rs41_raw_decode_fixed_fields.pl` programot.
A GUI megkezdi a kimenet nem blokkoló olvasását.
Az Indítás gomb futás közben letiltható.

### 12.2. Leállítás gomb

- A teljes folyamatcsoport leállítása.
- A pipe-ok lezárása.
- Az IO watcherek eltávolítása.
- A gyermekfolyamatok bevárása.
- A gombállapotok visszaállítása.
- A szűrő és a demodulátor leállásának ellenőrzése.
- A `tee` leállítása, ha WAV-mentés aktív.

### 12.3. Bluetooth gomb

- A gomb a Leállítás gomb jobb oldalán található.
- Kikapcsolt állapotban elindítja a `gps_bridge_bt.pl` programot.
- Aktív állapotban jelzi, hogy a Bluetooth-híd fut.
- A híd leállásakor a gomb automatikusan visszaáll.
- Ismételt megnyomással a híd leállítható.
- A GUI a gyermekfolyamat tényleges állapotát figyeli.

## 13. Bázispont mezők

### Bázis szélesség
WGS84 földrajzi szélesség fokban.

### Bázis hosszúság
WGS84 földrajzi hosszúság fokban.

### Bázis magasság
A telefon vagy a felhasználó által megadott magasság méterben.

### Bázis irány
A valódi északi irányhoz viszonyított tájolás fokban.

A mezők kézzel is kitölthetők.
Bluetooth GPS-adat érkezésekor automatikusan frissülnek.
A térképen a bázispont kék jelölőként vagy kék nyílként jelenik meg.

A kiadott `config.txt` alapértelmezett koordinátái Budapest 0. kilométerkövének nyilvános helyét adják meg. Ezek bemutató- és indulóértékek, nem egy privát vételi állomás koordinátái.

## 14. Hang- és szűrőparaméterek

### ALSA eszköz
A hangbemenet neve, például `default` vagy `hw:1,0`.

### Mintavételi frekvencia
Jellemzően 48000 Hz.

### Alsó vágási frekvencia
A magasáteresztő szűrő határfrekvenciája.

### Felső vágási frekvencia
Az aluláteresztő szűrő határfrekvenciája.

### Szűrőrend
A digitális szűrő meredekségét befolyásolja.

### Cél csúcsszint
A normalizált kimenet maximális célértéke.

### Blokkhossz vagy késleltetés
A feldolgozási blokk hozzávetőleges időtartama.

### Invertálás
A demoduláció polaritásának megfordítása.

### Részletes kimenet
Diagnosztikai információk megjelenítése.

## 15. Javasolt szűrőbeállítások

```text
LF = 525 Hz
HF = 12000 Hz
O  = 1
P  = 0.75
D  = 0.5 s
```

- A megfelelő érték függ a rádió hangátvitelétől.
- A megfelelő érték függ a hangkártya bemenetétől.
- A megfelelő érték függ a hangerőtől.
- A megfelelő érték függ a zajszinttől.
- A megfelelő érték függ a rádió belső hangszűrőitől.

## 16. Térképes megjelenítés

- A központi térkép WebKit2GTK nézetben jelenik meg.
- A HTML és JavaScript réteg a Perl GUI-tól elkülönül.
- A szonda jelölője a dekóder koordinátáit követi.
- A bázis jelölője a telefon vagy a kézi mezők koordinátáit követi.
- A bázisnyíl iránya a `heading_true` mezőből származik.
- A szondanyíl iránya a `D` mezőből származik.
- A térkép a két pont közötti távolságot is kiszámíthatja.
- A térkép automatikusan középre igazítható.

## 17. Terminál- és diagnosztikai terület

- Az `arecord` hibái.
- A szűrő diagnosztikai sorai.
- A `./rs41_mod` diagnosztikai sorai.
- A nyers dekóder fő sorai.
- A PTU RAW sorok.
- A CRC-hibák.
- A kalibrációs állapot.
- A Bluetooth JSON-sorok.
- A Bluetooth kapcsolati állapot.
- A folyamatok kilépési kódjai.

## 18. A GUI használatának folyamata

1. A rádió hangkimenetének csatlakoztatása.
2. A megfelelő ALSA bemenet kiválasztása.
3. A rádió frekvenciájának beállítása.
4. A hangerő és a jelszint beállítása.
5. A szűrőparaméterek ellenőrzése.
6. A WAV-mentés be- vagy kikapcsolása.
7. A bázisadatok kézi megadása vagy a Bluetooth-híd indítása.
8. Az Indítás gomb megnyomása.
9. A terminálkimenet figyelése.
10. A VALID keretek megjelenésének ellenőrzése.
11. A térképi pozíció ellenőrzése.
12. A folyamat Leállítás gombbal történő befejezése.

## 19. Hangbemenet tesztelése

```bash
arecord \
	-D default \
	-t wav \
	-f S16_LE \
	-r 48000 \
	-c 1 \
	-d 10 \
	test.wav

aplay test.wav
```

- A jel legyen jól hallható.
- Ne legyen erős clipping.
- Ne legyen túl alacsony a szint.
- A zajzár ne vágja le a szonda jelét.
- A rádió hangfeldolgozása ne torzítsa túl erősen az FSK jelet.

## 20. Élő feldolgozás parancssorból

```bash
arecord \
	-D default \
	-t wav \
	-f S16_LE \
	-r 48000 \
	-c 1 \
	-q |
./rs41_filter_stream.py \
	-LF 525 \
	-HF 12000 \
	-O 1 \
	-P 0.75 \
	-D 0.5 \
	-V |
./rs41_mod \
	-vv \
	-r \
	/dev/stdin |
./rs41_raw_decode_fixed_fields.pl
```

## 21. WAV-mentés élő feldolgozás közben

```bash
WAV_FILE="$(date '+%Y-%m-%d_%H-%M-%S').wav"

arecord \
	-D default \
	-t wav \
	-f S16_LE \
	-r 48000 \
	-c 1 \
	-q |
tee "$WAV_FILE" |
./rs41_filter_stream.py \
	-LF 525 \
	-HF 12000 \
	-O 1 \
	-P 0.75 \
	-D 0.5 \
	-V |
./rs41_mod \
	-vv \
	-r \
	/dev/stdin |
./rs41_raw_decode_fixed_fields.pl
```

A `tee` a szűrés előtti eredeti WAV-adatfolyamot menti.
Ez lehetővé teszi a későbbi újrafeldolgozást.

## 22. Mentett WAV újrafeldolgozása

```bash
./rs41_filter_stream.py \
	-LF 525 \
	-HF 12000 \
	-O 1 \
	-P 0.75 \
	-D 0.5 \
	-V \
	< ./MyRecTest6.wav |
./rs41_mod \
	-vv \
	-r \
	/dev/stdin |
./rs41_raw_decode_fixed_fields.pl
```

## 23. Az `arecord` működése

- Az ALSA bemeneti eszköz megnyitása.
- A mintavételi frekvencia beállítása.
- A mintaméret beállítása.
- A csatornaszám beállítása.
- A WAV fejléc létrehozása.
- A PCM minták folyamatos kiírása.
- A kimenet átadása a szűrőnek.

## 24. Az `arecord` fontos kapcsolói

### `-D default`
A kiválasztott ALSA eszköz.

### `-t wav`
WAV kimeneti formátum.

### `-f S16_LE`
16 bites előjeles little-endian PCM.

### `-r 48000`
48 kHz mintavétel.

### `-c 1`
Monó hang.

### `-q`
Csendes működés.

## 25. A `rs41_filter_stream.py` feladata

- A WAV fejléc beolvasása.
- A bemeneti formátum ellenőrzése.
- A mintavételi frekvencia meghatározása.
- A PCM minták blokkos olvasása.
- A minták lebegőpontos tartományra alakítása.
- Magasáteresztő szűrés.
- Aluláteresztő szűrés.
- Jelszintmérés.
- AGC vagy normalizálás.
- Clipping elleni korlátozás.
- A PCM adatok visszaalakítása.
- A kimeneti WAV-adat továbbítása.

## 26. A szűrő parancssori kapcsolói

### `-LF`
Alsó vágási frekvencia hertzben.

### `-HF`
Felső vágási frekvencia hertzben.

### `-O`
Szűrőrend.

### `-P`
Cél csúcsszint 0 és 1 között.

### `-D`
Feldolgozási blokk időtartama másodpercben.

### `-V`
Részletes diagnosztikai kimenet.

## 27. A szűrő belső működése

1. Inicializálja az argumentumfeldolgozót.
2. Ellenőrzi a numerikus paramétereket.
3. Beolvassa a WAV fejlécet.
4. Ellenőrzi a PCM formátumot.
5. Kiszámítja a blokkméretet.
6. Létrehozza a magasáteresztő szűrő együtthatóit.
7. Létrehozza az aluláteresztő szűrő együtthatóit.
8. Inicializálja a szűrőállapotot.
9. Blokkonként mintákat olvas.
10. Állapottartó módon megszűri a blokkot.
11. Meghatározza a blokk csúcsszintjét.
12. Kiszámítja az erősítési tényezőt.
13. Korlátozza az erősítés túl gyors változását.
14. Alkalmazza az erősítést.
15. Levágja a túlcsorduló értékeket.
16. Visszaalakítja 16 bites PCM-re.
17. Kiírja a blokkot.
18. Kiüríti a kimeneti puffert.
19. EOF esetén szabályosan lezár.
20. BrokenPipe esetén csendesen kilép.

## 28. A `./rs41_mod` szerepe

- A szűrt hangfolyam demodulálása.
- A szimbólumidőzítés felismerése.
- Az FSK jel állapotainak meghatározása.
- A bitfolyam előállítása.
- A keretszinkron felismerése.
- A whitening visszafejtése.
- A Reed–Solomon hibajavítás elvégzése.
- A nyers RS41 keret összeállítása.
- A nyers keret kiírása a Perl-dekóder számára.

## 29. A `./rs41_mod` kapcsolói

### `-v`
Részletesebb információ.

### `-vx`
Kibővített diagnosztika.

### `-vv`
Még részletesebb információ és konfiguráció.

### `-r` vagy `--raw`
Nyers keretkimenet.

### `-i` vagy `--invert`
A demoduláció polaritásának invertálása.

A ténylegesen támogatott kapcsolókat mindig a helyi program segítségével kell ellenőrizni.
```bash
./rs41_mod --help
```

## 30. A `./rs41_mod` helyi elhelyezésének követelménye

- A program a projekt könyvtárában található.
- A program nincs a PATH-ban.
- A programot `./rs41_mod` néven kell meghívni.
- A GUI a saját könyvtárából képzett abszolút elérési utat használhat.
- A fájlnak végrehajtható jogosultsággal kell rendelkeznie.
- A program elérhetőségét nem `which` paranccsal kell ellenőrizni.

## 31. A `rs41_raw_decode_fixed_fields.pl` feladata

- A `./rs41_mod` nyers kimenetének olvasása.
- A diagnosztikai és nyers sorok megkülönböztetése.
- A hexadecimális adatok bájttömbbé alakítása.
- A kerethossz ellenőrzése.
- A részcsomagok bejárása.
- A részcsomag-azonosítók felismerése.
- A CRC ellenőrzése.
- A GPS-adatok kinyerése.
- A státuszadatok kinyerése.
- A kalibrációs részkeretek tárolása.
- A PTU nyers adatok feldolgozása.
- A fizikai mennyiségek kiszámítása.
- A fix mezőszerkezetű kimenet előállítása.

## 32. A dekóder feldolgozási folyamata

1. Sor olvasása az STDIN-ről.
2. Üres sor kihagyása.
3. Diagnosztikai sor felismerése.
4. Nyers hexadecimális keret felismerése.
5. Hexadecimális karakterek tisztítása.
6. Bájttömb létrehozása.
7. Kerethossz ellenőrzése.
8. Fejléc ellenőrzése.
9. Részcsomagok kezdőpozícióinak meghatározása.
10. Részcsomag-típus kiolvasása.
11. Részcsomaghossz kiolvasása.
12. Határellenőrzés.
13. CRC kiszámítása.
14. CRC összehasonlítása.
15. Érvényes csomag adatainak feldolgozása.
16. Érvénytelen csomag megjelölése.
17. Szondaállapot frissítése.
18. Kimeneti mezők összeállítása.
19. Hiányzó értékek `?` karakterrel való feltöltése.
20. VALID vagy más állapotú sor kiírása.

## 33. Fix kimeneti formátum

```text
[VALID] frame=5205 id=X4312092 batt=2.6V time=2026-07-02T12:21:48.003Z packets=6/6 upstream=OK lat=47.47797 lon=19.34436 alt=21547.76 vH=10.4 D=308.1 vV=4.8 sats=10 T=? TH=? RH=? RHemp=? P=? Pest=42.93hPa cal=?
```

A mezők száma és sorrendje állandó.
A hiányzó értékeket `?` jelöli.

## 34. A kimeneti mezők sorrendje

1. Érvényességi állapot.
2. `frame`.
3. `id`.
4. `batt`.
5. `time`.
6. `packets`.
7. `upstream`.
8. `lat`.
9. `lon`.
10. `alt`.
11. `vH`.
12. `D`.
13. `vV`.
14. `sats`.
15. `T`.
16. `TH`.
17. `RH`.
18. `RHemp`.
19. `P`.
20. `Pest`.
21. `cal`.

## 35. PTU RAW kimenet

```text
PTU RAW: T=?/?/? H=?/?/? TH=?/?/? P=?/?/? Ptemp=?
```

Példa rendelkezésre álló értékekkel:
```text
PTU RAW: T=143457/134131/194785 H=551078/486833/556896 TH=130208/134132/194786 P=355336/287417/412217 Ptemp=-1279
```

## 36. Kimeneti mezők részletes jelentése

### VALID állapot
A feldolgozott keret megfelelt a dekóder érvényességi feltételeinek.

### frame
A szonda keretszámlálója.

### id
A szonda azonosítója.

### batt
A szonda telepfeszültsége.

### time
UTC idő ISO 8601 formátumban.

### packets
A megtalált és elvárt részcsomagok száma.

### upstream
A megelőző feldolgozási szakasz állapota.

### lat
Földrajzi szélesség WGS84 rendszerben.

### lon
Földrajzi hosszúság WGS84 rendszerben.

### alt
Magasság méterben.

### vH
Vízszintes sebesség.

### D
Mozgási irány fokban.

### vV
Függőleges sebesség.

### sats
A GPS-megoldásban használt műholdak száma.

### T
Külső hőmérséklet.

### TH
A páratartalom-érzékelőhöz kapcsolódó hőmérséklet.

### RH
Korrigált relatív páratartalom.

### RHemp
Empirikus vagy köztes páratartalomérték.

### P
Közvetlen nyomásérték, ha a szonda támogatja.

### Pest
GPS-magasságból becsült légnyomás.

### cal
A kalibrációs adatok állapota.

## 37. Kalibrációs részkeretek

- Az RS41 kalibrációs adatai több keretben érkeznek.
- A dekóder 51 kalibrációs részkeretet gyűjt.
- A részkereteket index szerint kell tárolni.
- A részkereteket szondaazonosító szerint el kell különíteni.
- A hiányzó kalibráció miatt egyes fizikai értékek még nem számíthatók.
- Ilyenkor a megfelelő kimeneti mező értéke `?`.
- A teljes kalibráció után újraszámíthatók a PTU értékek.

## 38. GPS-feldolgozás

- GPS hét feldolgozása.
- GPS idő feldolgozása.
- UTC idő előállítása.
- Koordináták skálázása.
- Előjeles értékek helyes kezelése.
- Endian sorrend helyes kezelése.
- Magasság feldolgozása.
- Sebességvektor feldolgozása.
- Vízszintes sebesség számítása.
- Függőleges sebesség számítása.
- Mozgási irány számítása.
- Műholdszám feldolgozása.

## 39. Becsült légnyomás

- A `Pest` nem közvetlen szenzormérés.
- A `Pest` a GPS-magasságból származik.
- A számítás szabványos légköri modellt használhat.
- Nagy magasságban réteges légköri modell indokolt.
- A becsült értéket nem szabad a közvetlen `P` mezővel összekeverni.

## 40. A `gps_bridge_bt.pl` célja

- A Linux és az Android telefon közötti Bluetooth kapcsolat kezelése.
- A telefon kiválasztása.
- A párosítás kezelése.
- A trust állapot beállítása.
- Az RFCOMM csatorna létrehozása.
- A JSON-sorok olvasása.
- A JSON-sorok továbbítása a GUI felé.
- A kapcsolati napló külön terminálban való megjelenítése.
- A kilépéskori takarítás.

## 41. A Bluetooth-híd használata

```bash
./gps_bridge_bt.pl
```

1. A Bluetooth adapter ellenőrzése.
2. A blokkolt adapter feloldása.
3. A Bluetooth szolgáltatás ellenőrzése.
4. Eszközkeresés.
5. Telefon kiválasztása.
6. Párosítás.
7. Megbízható eszközzé jelölés.
8. RFCOMM kapcsolat létrehozása.
9. JSON-sorok fogadása.
10. Adatok továbbítása a GUI felé.

## 42. A Bluetooth-híd belső felépítése

### Konfigurációs réteg
A parancsok, időkorlátok és fájlutak tárolása.

### Környezeti ellenőrzés
A BlueZ programok és a terminálemulátor ellenőrzése.

### Adapterkezelő
A Bluetooth adapter állapotának kezelése.

### Eszközkereső
A látható telefonok összegyűjtése.

### Párosítási vezérlő
A párosítási és trust műveletek kezelése.

### RFCOMM-kezelő
A soros kapcsolat létrehozása és bontása.

### Worker folyamat
A kapcsolat fenntartása és az adatok olvasása.

### FIFO vagy pipe réteg
A worker és a GUI közötti adatátadás.

### JSON-ellenőrző
A beérkező sorok szintaktikai ellenőrzése.

### Takarítási réteg
Az ideiglenes folyamatok és fájlok megszüntetése.

## 43. FIFO és worker működés

```text
GUI
 |
 +-- gps_bridge_bt.pl vezérlő
       |
       +-- FIFO vagy pipe
       |
       +-- külön terminál
             |
             +-- gps_bridge_bt.pl --worker
                   |
                   +-- RFCOMM
                         |
                         +-- Android telefon
```

- A FIFO megnyitási sorrendje blokkolást okozhat.
- Az olvasó- és íróoldal indulását össze kell hangolni.
- A worker indulását állapotjelzéssel kell visszaigazolni.
- A terminál hibás indulását kezelni kell.
- A GUI leállásakor a workert is le kell állítani.

## 44. Bluetooth leállítás és ellenőrzés

```bash
pgrep -af gps_bridge_bt.pl
pgrep -af rfcomm
rfcomm show
bluetoothctl show
```

Szükség esetén:
```bash
sudo rfcomm release all
```

- A híd leállása nem azonos a Bluetooth adapter kikapcsolásával.
- Az RFCOMM kapcsolat bontása külön művelet.
- A script csak azt az állapotot állítsa vissza, amelyet maga módosított.
- Ha az adapter a script előtt is aktív volt, nem célszerű kikapcsolni.

## 45. Android alkalmazás célja

- A telefon GPS-koordinátáinak továbbítása.
- A telefon magasságának továbbítása.
- A GPS pontosság továbbítása.
- A sebesség továbbítása.
- A mozgási irány továbbítása.
- A mágneses irányszög továbbítása.
- A valódi északi irányszög továbbítása.
- A pitch és roll továbbítása.
- A tájolási pontosság továbbítása.

## 46. Android jogosultságok

- Pontos helyhozzáférés.
- Bluetooth kapcsolat.
- Közeli eszközök elérése.
- Bluetooth keresés, ha szükséges.
- Háttérbeli helyhozzáférés az Android-verziótól függően.
- Értesítési jogosultság foreground service esetén.

## 47. Android által küldött JSON

```json
{
	"time": "2026-07-04T19:43:40.291Z",
	"lat": 47.53767212,
	"lon": 19.18883477,
	"alt": 200,
	"gps_accuracy": 12.86400032043457,
	"speed": 0,
	"course": null,
	"location_time_ms": 1783194221000,
	"provider": "gps",
	"heading_mag": 299.8042655993028,
	"heading_true": 305.22518311028915,
	"pitch": -27.863191520913198,
	"roll": -26.507226508389124,
	"heading_accuracy": 3
}
```

Minden mérés külön sorban kerül elküldésre.
A formátum newline-delimited JSON, röviden NDJSON vagy JSONL.

## 48. Android JSON mezők

### `time`
A mérés vagy továbbítás UTC ideje ISO 8601 formátumban.

### `lat`
Földrajzi szélesség.

### `lon`
Földrajzi hosszúság.

### `alt`
GPS-magasság méterben.

### `gps_accuracy`
Becsült vízszintes pontosság méterben.

### `speed`
A helyszolgáltató által adott sebesség.

### `course`
GPS-alapú mozgási irány vagy null.

### `location_time_ms`
A helymérés időpontja milliszekundumban.

### `provider`
A helyzet forrása, például gps.

### `heading_mag`
Mágneses északi irányhoz viszonyított tájolás.

### `heading_true`
Valódi északi irányhoz viszonyított tájolás.

### `pitch`
Előre-hátra dőlés.

### `roll`
Oldalirányú dőlés.

### `heading_accuracy`
A tájolás pontossági besorolása.

## 49. Android alkalmazás használata

1. Az APK telepítése.
2. Az ismeretlen forrásból történő telepítés engedélyezése, ha szükséges.
3. A Bluetooth bekapcsolása.
4. A helymeghatározás bekapcsolása.
5. Az alkalmazás elindítása.
6. A jogosultságok megadása.
7. A foreground service elindítása.
8. A Linux oldali Bluetooth-híd elindítása.
9. A telefon kiválasztása.
10. A párosítás befejezése.
11. A JSON-adatfolyam ellenőrzése.

## 50. Android alkalmazás belső felépítése

### Felhasználói felület
Az állapot, kapcsolat és engedélyek megjelenítése.

### Helyzetkezelő
GPS-frissítések és pontosság kezelése.

### Szenzorkezelő
Gyorsulásmérő, magnetométer vagy rotációs vektor kezelése.

### Tájolásszámító
Heading, pitch és roll előállítása.

### Deklinációs korrekció
A mágneses és valódi észak közötti eltérés kezelése.

### Bluetooth szolgáltatás
Az RFCOMM vagy SPP kapcsolat fenntartása.

### JSON-generátor
A legutóbbi értékekből JSON-sor készítése.

### Foreground service
A háttérbeli folyamatos működés biztosítása.

### Hibakezelő
A kapcsolatvesztés és érzékelőhibák kezelése.

## 51. A valódi északi irány számítása

- A telefon magnetométere mágneses északhoz viszonyított irányt ad.
- A mágneses deklináció hely- és időfüggő.
- A `heading_true` a mágneses irány és a deklináció összegeként állítható elő.
- Az eredményt 0 és 360 fok közé kell normalizálni.
- A GUI a `heading_true` mezőt használja a bázisnyíl forgatására.

## 52. A GUI belső felépítése

### Konfiguráció
Alapértelmezett utak, eszközök és paraméterek.

### GTK inicializálás
A főablak és a widgetek létrehozása.

### Eseménykezelés
Gombok és mezők callback függvényei.

### Folyamatkezelő
A gyermekfolyamatok indítása és leállítása.

### Pipe-kezelő
A folyamatok közötti adatcsatornák kezelése.

### Dekóderkimenet-értelmező
A fix kulcs-érték sorok feldolgozása.

### GPS JSON-értelmező
A telefonadatok dekódolása.

### Állapotmodell
A bázis és a szonda aktuális adatainak tárolása.

### Térképvezérlő
JavaScript hívások és jelölőfrissítés.

### Naplózó
A terminál- és diagnosztikai sorok megjelenítése.

### Leállítási vezérlő
A folyamatcsoportok és IO watcherek takarítása.

## 53. GUI állapotváltozók

```perl
my $receiver_running = 0;
my $gps_bridge_running = 0;

my $receiver_pid;
my $receiver_pgid;
my $gps_bridge_pid;

my $receiver_stdout;
my $receiver_stderr;
my $gps_stdout;

my %sonde_data;
my %base_data;
```

## 54. Helyi programutak a GUI-ban

```perl
use FindBin qw($Bin);

my $filter_path = "$Bin/rs41_filter_stream.py";
my $mod_path = "$Bin/rs41_mod";
my $decode_path = "$Bin/rs41_raw_decode_fixed_fields.pl";
my $gps_bridge_path = "$Bin/gps_bridge_bt.pl";
```

Ez a megoldás megszünteti a PATH-függőséget.
A `rs41_mod` mindenkor a GUI könyvtárából kerül betöltésre.

## 55. Programfájlok ellenőrzése a GUI-ban

```perl
sub require_executable
{
	my ($path, $name) = @_;

	die "Nem található: $name ($path)\n"
		if !-e $path;

	die "Nem szabályos fájl: $name ($path)\n"
		if !-f $path;

	die "Nem futtatható: $name ($path)\n"
		if !-x $path;
}
```

A GUI induláskor vagy a vétel indításakor hívhatja ezt az ellenőrzést.

## 56. Folyamatindítás a GUI-ban

- A shell-stringes indítás egyszerű, de kevésbé biztonságos.
- A külön `fork` és explicit pipe kezelés robusztusabb.
- A folyamatokat közös folyamatcsoportba célszerű tenni.
- A GUI minden gyermek PID-jét vagy a csoportazonosítót tárolja.
- A STDERR kimenetet is be kell gyűjteni.

## 57. Folyamatcsoport kezelése

```perl
setpgrp(0, 0);
```

Leállításkor:
```perl
kill 'TERM', -$receiver_pgid;
```

Szükség esetén később:
```perl
kill 'KILL', -$receiver_pgid;
```

## 58. Nem blokkoló IO a GTK mellett

- A GTK fő eseményciklusát nem szabad blokkolni.
- A pipe olvasása Glib IO watcherrel végezhető.
- A részleges sorokat pufferelni kell.
- A HUP és ERR eseményeket kezelni kell.
- A watcher az EOF után eltávolítandó.

## 59. Dekódersorok feldolgozása

```perl
while ($line =~ /([A-Za-z][A-Za-z0-9_]*)=([^\s]+)/g)
{
	$fields{$1} = $2;
}
```

- A `?` értéket nem szabad számmá konvertálni.
- A hiányzó kulcsot külön kell kezelni.
- A VALID sor frissíti a szondaállapotot.
- A PTU RAW sor külön naplózható.
- A hibás sor nem állíthatja le a GUI-t.

## 60. GPS JSON feldolgozás a GUI-ban

```perl
my $gps = eval
{
	decode_json($line);
};

return if !$gps;
return if !defined $gps->{lat};
return if !defined $gps->{lon};

$base_data{lat} = $gps->{lat};
$base_data{lon} = $gps->{lon};
$base_data{alt} = $gps->{alt};
$base_data{heading} = $gps->{heading_true};
```

## 61. Térképi adatátadás

```perl
my $json = encode_json(
	{
		base => \%base_data,
		sonde => \%sonde_data
	}
);
```

A JSON-adat a WebKit JavaScript rétegének adható át.
A HTML-oldal egyetlen frissítő függvényt is biztosíthat.
```javascript
window.updateTrackingData(data);

A ténylegesen megjelenített HTML / CSS /JS kód szöveges adatként van a PERL kódban tárolva. a Késöbbi OFFLINE térkép CACHE miatt ki lesz szervezve a "WEB" tartalom a RES mappába. Így egyáltalán nem kell majd NET a futtatáshoz.
Offline futtatás esetén a térkép részletessége a letöltött térkép adatokon múlik.

A JElen verzióban még benne maradt online függőségek miatt a térkép modul OFFLINE egyáltalán nem fut!
```

## 62. Naplózás

- GUI napló.
- Szűrő diagnosztikai napló.
- `./rs41_mod` diagnosztikai napló.
- Dekóder napló.
- Bluetooth napló.
- GPS JSONL napló.
- WAV-archívum.

## 63. Fájlnévkonvenciók

- `2026-07-04_20-15-32.wav`
- `2026-07-04_20-15-32_decode.log`
- `2026-07-04_20-15-32_gps.jsonl`
- `2026-07-04_20-15-32_gui.log`

## 64. WAV tárhelyigény

- 48 000 minta másodpercenként.
- 2 bájt mintánként.
- 1 csatorna.
- Körülbelül 96 000 bájt másodpercenként.
- Körülbelül 345,6 MB óránként.

## 65. Hibakezelési alapelvek

- A GUI ne omoljon össze egyetlen hibás dekódersor miatt.
- A hibás JSON-sor kihagyható.
- A hiányzó program neve jelenjen meg.
- A gyermekfolyamat kilépési kódja naplózandó.
- A BrokenPipe ne okozzon hosszú Python tracebacket.
- A Bluetooth kapcsolatvesztés állítsa vissza a gombot.
- A hiányzó kalibráció normál állapotként kezelendő.

## 66. Gyakori hanghibák

### Nincs hang
Hibás ALSA eszköz, kábel vagy rádiókimenet.

### Túl halk jel
Alacsony rádióhangerő vagy bemeneti erősítés.

### Clipping
Túl magas hangerő vagy mikrofon boost.

### Erős zaj
Nyitott zajzár, gyenge jel vagy földhurok.

### Keskeny sáv
A rádió hangszűrője levágja az FSK hasznos komponenseit.

### Szakadozás
ALSA underrun, CPU-terhelés vagy hibás USB hangkártya.

## 67. Gyakori demodulációs hibák

- Nincs keretszinkron.
- Csak hibás CRC-jű csomagok.
- Fordított polaritás.
- Nem megfelelő szűrőparaméterek.
- Túlvezérelt hang.
- Túl alacsony szint.
- Rádió hangprocesszor okozta torzítás.
- Nem megfelelő mintavételi frekvencia.

## 68. Gyakori Bluetooth hibák

### Adapter blokkolva
Az `rfkill unblock bluetooth` szükséges lehet.

### Nincs bluetoothd
A BlueZ szolgáltatás nem fut.

### Telefon nem látható
A telefon vagy a PC nem kereshető.

### Párosítás sikertelen
Régi párosítás törlése vagy agent probléma.

### RFCOMM foglalt
Régi kapcsolat maradt aktív.

### Kapcsolat megszakad
Android energiatakarékosság vagy rádiós távolság.

### Nincs JSON
Az Android alkalmazás nem küld vagy rossz csatornához csatlakozott.

## 69. Gyakori Android hibák

### Nincs GPS-frissítés
A helyhozzáférés hiányzik vagy nincs műholdvétel.

### Nincs heading
A készülék nem ad megfelelő szenzoradatot.

### Heading ugrál
Mágneses zavar vagy rossz kalibráció.

### Háttérben leáll
Nincs foreground service vagy akkukímélő tiltás.

### Bluetooth bont
A rendszer lezárja a háttérkapcsolatot.

### course null
Álló helyzetben vagy elégtelen GPS sebességnél normális.

## 70. Diagnosztikai parancsok

```bash
arecord -l
```

```bash
arecord -L
```

```bash
pgrep -af arecord
```

```bash
pgrep -af rs41_filter_stream.py
```

```bash
pgrep -af rs41_mod
```

```bash
pgrep -af rs41_raw_decode_fixed_fields.pl
```

```bash
pgrep -af gps_bridge_bt.pl
```

```bash
rfkill list bluetooth
```

```bash
bluetoothctl show
```

```bash
rfcomm show
```

```bash
journalctl -u bluetooth
```

## 71. Kézi komponensvizsgálat

- A szűrő önálló tesztje mentett WAV-val.
- A `./rs41_mod` önálló tesztje szűrt WAV-val.
- A dekóder önálló tesztje mentett nyers kimenettel.
- A Bluetooth-híd önálló tesztje GUI nélkül.
- A térkép HTML önálló megnyitása.

## 72. Szűrő önálló tesztje

```bash
./rs41_filter_stream.py \
	-LF 525 \
	-HF 12000 \
	-O 1 \
	-P 0.75 \
	-D 0.5 \
	-V \
	< input.wav \
	> filtered.wav
```

## 73. `./rs41_mod` önálló tesztje

```bash
./rs41_mod 	-vv 	-r 	filtered.wav
```

## 74. Dekóder önálló tesztje

```bash
./rs41_mod 	-vv 	-r 	filtered.wav |
./rs41_raw_decode_fixed_fields.pl
```

## 75. GPS JSON naplózása

```bash
./gps_bridge_bt.pl |
tee "gps_$(date '+%Y-%m-%d_%H-%M-%S').jsonl"
