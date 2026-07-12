 External source components and provenance

This document records the origin, version, repository information and license of the external source components included with the project.

The source archives contain the corresponding source code and license text for each component. Original copyright notices, source-file headers and license terms must be preserved.

---

## RS radiosonde decoder

### Package

```text
RS.tar.gz
```

### Original project

```text
https://github.com/rs1729/RS
```

### Original Git repository

```text
https://github.com/rs1729/RS.git
```

### Branch

```text
master
```

### Exact commit

```text
15659617bfe9ad7f63d4442f8b79b8870f16da6d
```

Short commit identifier:

```text
1565961
```

Commit message:

```text
dft_detect: add --exclude-types option
```

Commit author:

```text
Zilog80 / rs1729
```

Commit date:

```text
2026-06-27
```

The archive does not correspond to a separate version tag. It contains the state of the `master` branch at the exact commit shown above.

### License

```text
GNU General Public License version 3
SPDX: GPL-3.0-only
```

The complete license text is included in the root of the archive:

```text
RS/LICENSE
```

### Use in DsRS41Tracker

DsRS41Tracker uses the RS project's RS41 demodulator source to build the local `rs41_mod` executable.

The compiled binary and any modified version derived from this source must be distributed under the terms of the GNU GPL v3.

### Modifications

The included `RS.tar.gz` archive contains the source associated with the upstream commit identified above.

If the RS source is modified for a DsRS41Tracker release:

- the modified status must be clearly stated;
- original copyright and license notices must be preserved;
- the date and nature of the modifications must be documented;
- the complete modified source code must be made available;
- all scripts and build files required to compile the modified version must also be provided.

Modification status for this release:

```text
No documented modifications to the upstream source.
```

---

## GPSBridge

### Package

```text
GPSBridge-v0.1.0.tar.gz
```

### Original project

```text
https://github.com/novarobot/GPSBridge
```

### Original release

```text
https://github.com/novarobot/GPSBridge/releases/tag/0.1.0
```

### Version tag

```text
0.1.0
```

### Exact commit

```text
e6c3d7d3b92a189a7b81099eca6d7a29bc3e8480
```

Short commit identifier:

```text
e6c3d7d
```

Commit message:

```text
Initial release v0.1.0
```

### Author

```text
Juhász Bálint / novarobot
```

### License

```text
GNU General Public License version 3
SPDX: GPL-3.0-only
```

The complete license text is included in the root of the archive:

```text
GPSBridge/LICENSE
```

### Use in DsRS41Tracker

GPSBridge is a separate Android application that sends the phone's GPS, compass and orientation data to the DsRS41Tracker computer-side component over a Bluetooth RFCOMM connection.

GPSBridge is distributed as a separate executable program with its own source code and GNU GPL v3 license.

### Modifications

The included source archive corresponds to the official `0.1.0` release.

Modification status for this release:

```text
No modifications.
```

---

## License compliance notes

Both source components are licensed under the GNU General Public License version 3.

When redistributing these components:

1. the complete GNU GPL v3 license text must be preserved;
2. original copyright notices must be preserved;
3. the corresponding source code must be made available;
4. modifications must be clearly documented;
5. the complete, buildable modified source must also be provided;
6. the source version corresponding to any distributed binary must be included or otherwise made available in accordance with the license;
7. the original project names and authors must not be represented as the distributor's own work.

The license of the DsRS41Tracker main project must not override or restrict the rights granted by the GNU GPL v3 for the RS and GPSBridge components.

---

# Külső forráskomponensek és származásuk

Ez a dokumentum a projekthez mellékelt külső forráskomponensek eredetét, verzióját, repository-adatait és licencét rögzíti.

A forrásarchívumok az adott komponensekhez tartozó forráskódot és licencszöveget tartalmazzák. Az eredeti szerzői jogi megjegyzéseket, forrásfájl-fejléceket és licencfeltételeket meg kell őrizni.

---

## RS rádiószonda-dekóder

### Csomag

```text
RS.tar.gz
```

### Eredeti projekt

```text
https://github.com/rs1729/RS
```

### Eredeti Git repository

```text
https://github.com/rs1729/RS.git
```

### Ág

```text
master
```

### Pontos commit

```text
15659617bfe9ad7f63d4442f8b79b8870f16da6d
```

Rövid commitazonosító:

```text
1565961
```

Commitüzenet:

```text
dft_detect: add --exclude-types option
```

A commit szerzője:

```text
Zilog80 / rs1729
```

A commit dátuma:

```text
2026-06-27
```

Az archívum nem külön verziótaghez tartozik. A `master` ág fent megadott konkrét commitjának állapotát tartalmazza.

### Licenc

```text
GNU General Public License version 3
SPDX: GPL-3.0-only
```

A teljes licencszöveg az archívum gyökerében található:

```text
RS/LICENSE
```

### Felhasználás a DsRS41Tracker projektben

A DsRS41Tracker az RS projekt RS41 demodulátorának forrását használja a helyi `rs41_mod` futtatható állomány elkészítéséhez.

A lefordított bináris és az ebből a forrásból származó bármely módosított változat terjesztése a GNU GPL v3 feltételei szerint történik.

### Módosítások

A mellékelt `RS.tar.gz` archívum a fent azonosított upstream commithoz tartozó forrást tartalmazza.

Ha a DsRS41Tracker valamely kiadásához módosul az RS forrása:

- egyértelműen jelezni kell, hogy módosított változatról van szó;
- meg kell őrizni az eredeti szerzői jogi és licencmegjelöléseket;
- dokumentálni kell a módosítás dátumát és jellegét;
- elérhetővé kell tenni a teljes módosított forráskódot;
- mellékelni kell minden, a fordításhoz szükséges scriptet és buildfájlt.

A jelen kiadás módosítási állapota:

```text
Nincs dokumentált módosítás az upstream forráson.
```

---

## GPSBridge

### Csomag

```text
GPSBridge-v0.1.0.tar.gz
```

### Eredeti projekt

```text
https://github.com/novarobot/GPSBridge
```

### Eredeti kiadás

```text
https://github.com/novarobot/GPSBridge/releases/tag/0.1.0
```

### Verziótag

```text
0.1.0
```

### Pontos commit

```text
e6c3d7d3b92a189a7b81099eca6d7a29bc3e8480
```

Rövid commitazonosító:

```text
e6c3d7d
```

Commitüzenet:

```text
Initial release v0.1.0
```

### Szerző

```text
Juhász Bálint / novarobot
```

### Licenc

```text
GNU General Public License version 3
SPDX: GPL-3.0-only
```

A teljes licencszöveg az archívum gyökerében található:

```text
GPSBridge/LICENSE
```

### Felhasználás a DsRS41Tracker projektben

A GPSBridge egy külön Android-alkalmazás, amely a telefon GPS-, iránytű- és helyzetadatait Bluetooth RFCOMM kapcsolaton keresztül továbbítja a DsRS41Tracker számítógépes komponensének.

A GPSBridge külön futtatható programként, saját forráskóddal és GNU GPL v3 licenccel kerül terjesztésre.

### Módosítások

A mellékelt forrásarchívum a hivatalos `0.1.0` kiadáshoz tartozik.

A jelen kiadás módosítási állapota:

```text
Nincs módosítás.
```

---

## Licencmegfelelési megjegyzések

Mindkét forráskomponens a GNU General Public License 3-as verziója alatt érhető el.

A komponensek továbbterjesztésekor:

1. meg kell őrizni a teljes GNU GPL v3 licencszöveget;
2. meg kell őrizni az eredeti szerzői jogi megjegyzéseket;
3. elérhetővé kell tenni a megfelelő forráskódot;
4. a módosításokat egyértelműen dokumentálni kell;
5. a teljes, lefordítható módosított forrást is biztosítani kell;
6. minden terjesztett binárishoz biztosítani kell a hozzá tartozó forrásverziót a licenc előírásainak megfelelően;
7. az eredeti projektek nevét és szerzőit nem szabad a terjesztő saját munkájaként feltüntetni.

A DsRS41Tracker főprojekt licence nem írhatja felül és nem korlátozhatja az RS és a GPSBridge komponensekre vonatkozó GNU GPL v3 által biztosított jogokat.
