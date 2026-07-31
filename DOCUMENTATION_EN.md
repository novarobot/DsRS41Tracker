# DsRS41Tracker 0.2.46 – Documentation

## 1. Purpose of the project

**DsRS41Tracker** is a multi-process Linux application for receiving,
decoding, displaying, logging and uploading telemetry from Vaisala RS41
radiosondes to SondeHub.

The system can:

- process RS41 transmissions from a live audio input;
- save the raw audio signal to a WAV file;
- log the RAW output of the `rs41_mod` demodulator;
- decode RAW frames locally;
- log decoded data in JSON Lines format;
- replay previously saved WAV, RAW and JSON files;
- provide a GTK3/WebKit2-based graphical interface;
- provide a Curses-based terminal interface;
- update the base position from a Bluetooth RFCOMM GPS source;
- upload SondeHub telemetry and listener data;
- calculate base-to-sonde distance, direction and elevation angle;

The current default configuration targets Debian-based Linux systems, but the
internal process handling of MAIN, GUI, TUI and the shared Perl modules is
fundamentally based on POSIX mechanisms.

Platform-dependent parts are separated:

```text
pipeConnect.pl
    Linux abstract UNIX socket implementation

gps_bridge_bt.pl
    Linux/BlueZ/RFCOMM Bluetooth GPS layer

rs41_mod or rs41_mod.py, or another demodulator
    separately executable external program

config.txt
    processing pipelines, audio system and worker launch commands

startGUI.sh / startTUI.sh
    launcher- and environment-dependent process startup
```

GUI portability depends on the availability of Gtk3, Gtk3::WebKit2 and the
selected terminal emulator. TUI portability depends on the Perl
Curses/ncurses module and the particular curses implementation.

---

## 2. Design principles

The most important structural decisions of the program are:

1. Signal processing and application logic run in the `rs41_main.pl` process.
2. The GUI and TUI are only frontends and do not perform parallel decoding.
3. MAIN and the frontend communicate through bidirectional, line-oriented JSON
   IPC.
4. Normal log and error messages travel on STDERR, not through the IPC channel.
5. Only one RECORD/WAV/RAW/JSON processing session can run at a time.
6. MAIN owns the effective configuration state used by the GUI and TUI.
7. The TUI and GUI do not read `config.txt` directly.
8. They use `pipeConnect.pl -R/-W` child processes.
9. Runtime setting changes are not written back to `config.txt`.
10. Incomplete RS41 frames result in partial value updates.

---

## 3. High-level architecture

### 3.1 GUI mode

```text
startGUI.sh
    │
    ├── rs41_main.pl
    │     ├── audio/file pipeline
    │     ├── receiving RS41 decoding output
    │     ├── statistics and vector calculations
    │     ├── Bluetooth GPS service
    │     └── SondeHub service
    │
    └── rs41_gui.pl
          ├── dsPGtkGUI.pm
          ├── UI.glade
          ├── Gtk3
          ├── Gtk3::WebKit2
          └── UI.html
```

### 3.2 TUI mode

```text
startTUI.sh
    │
    ├── rs41_main.pl
    │     ├── audio/file pipeline
    │     ├── receiving RS41 decoding output
    │     ├── statistics and vector calculations
    │     ├── Bluetooth GPS service
    │     └── SondeHub service
    │
    └── rs41_tui.pl
          ├── Curses / ncurses
          ├── keyboard
          ├── mouse
          ├── built-in file selector
          └── built-in BT/SHUB service window
```

### 3.3 Shared modules

```text
RS41IPC.pm
    JSON IPC helper functions

RS41FrontendData.pm
    shared GUI/TUI data model and sticky fields
```

### 3.4 Channels created by the launcher

```text
rs41_main.pl STDOUT  ──────► frontend STDIN
rs41_main.pl STDIN   ◄────── frontend STDOUT

rs41_main.pl STDERR  ──────► launcher terminal
frontend STDERR      ──────► launcher terminal
```

The launcher verifies that every line arriving on STDOUT is valid JSON.
IPC messages of type `terminal` are not forwarded to the other process; they
are formatted and written to STDERR instead.

---

## 4. Main data-processing paths

The four processing modes use separate configurable shell pipelines:

```text
PIPE_RECORD
PIPE_WAV
PIPE_RAW
PIPE_JSON
```

If a key is missing, empty or commented out, MAIN uses the previous built-in
default pipeline.

MAIN constructs the actual command by template substitution, then starts it
using general POSIX process handling:

```text
pipe
fork
POSIX::setsid
STDIN/STDOUT/STDERR redirection
exec sh -c
```

## 4.1 Live reception

Live processing consists of two separate branches.

### Audio recording and local monitoring

The separate monitoring/WAV-saving command is:

```text
RECORD_MONITOR_COMMAND
```

The WAV logging switch is:

```text
WAV_LOG_ENABLED
```

Its default value is:

```text
1
```

If the entry is missing, empty or commented out, WAV logging is enabled.

`RECORD_MONITOR_COMMAND` uses the `{WAV_LOG_PIPE}` placeholder:

```text
WAV_LOG_ENABLED=1:
    arecord ... | tee -- {WAV_FILE} | aplay -q

WAV_LOG_ENABLED=0:
    arecord ... | aplay -q
```

Disabling the WAV file therefore does not disable local audio monitoring.
On other platforms, this configuration line must be adapted to the relevant
audio system.

### Live decoder pipeline

```text
PIPE_RECORD
```

Default logical structure:

```text
audio source
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

## 4.2 WAV processing

The WAV-mode pipeline is:

```text
PIPE_WAV
```

Default structure:

```text
WAV file
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

## 4.3 RAW processing

The RAW-mode pipeline is:

```text
PIPE_RAW
```

Default structure:

```text
.Rlog or .raw
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

## 4.4 JSON replay

The JSON-mode pipeline is:

```text
PIPE_JSON
```

Default structure:

```text
.Jlog or .json
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

## 4.5 Separating FILTER and MOD commands

MAIN handles the executable and its current arguments separately:

```text
{FILTER_COMMAND}
{FILTER_ARGS}
{MOD_COMMAND}
{MOD_ARGS}
```

Current built-in values:

```text
FILTER_COMMAND:
    ./rs41_filter_stream.py

FILTER_ARGS:
    -LF <current LF>
    -HF <current HF>
    -O  <current filter order>
    -P  <current peak level>
    -D  <current delay>
    -V

MOD_COMMAND:
    ./rs41_mod

MOD_ARGS:
    -vv
    -r
    [-i]
    /dev/stdin
```

`-i` is added to `MOD_ARGS` only when the current Invert setting is enabled.

This allows the program to be replaced freely in the configuration while MAIN
continues to generate the variable arguments. Example:

```text
... | ./rs41_mod.py {MOD_ARGS} | ...
```

## 4.6 `rs41_mod` and `rs41_mod.py`

### Default demodulator

The built-in MAIN default is:

```text
MOD_COMMAND:
    ./rs41_mod

MOD_ARGS:
    -vv -r [-i] /dev/stdin
```

This also applies when:

- the `PIPE_RECORD` or `PIPE_WAV` entry is missing;
- the relevant configuration entry is empty;
- the relevant configuration entry is commented out;
- the pipeline uses the `{MOD_COMMAND} {MOD_ARGS}` placeholders.

The supplied `config.txt` therefore uses this again by default:

```text
| {MOD_COMMAND} {MOD_ARGS} |
```

### Python demodulator

`rs41_mod.py` reads a WAV/PCM stream from STDIN, searches for RS41 GFSK
frames, performs dewhitening and applies Reed–Solomon correction to the two
interleaved RS(255,231) codewords. Its output is one 320-byte hexadecimal RS41
frame per line.

The Python version can be selected in the configuration as follows:

```text
PIPE_RECORD=... | {FILTER_COMMAND} {FILTER_ARGS} | ./rs41_mod.py | ...
PIPE_WAV=... | {FILTER_COMMAND} {FILTER_ARGS} | ./rs41_mod.py | ...
```

`rs41_mod.py` does not require the command-line switches of the original C
`rs41_mod`, so `{MOD_ARGS}` is not required next to it.

### Automatic polarity detection

`rs41_mod.py` automatically detects whether a frame has normal or inverted
polarity from the sign of the header correlation.

Therefore, when the Python demodulator is used:

```text
AUDIO_INVERT
```

has no practical effect. The same program handles both inverted and
non-inverted signals automatically.

### Decoding result

On average, `rs41_mod.py` decodes approximately:

```text
12%
```

more valid packets than the original `rs41_mod`.

The measured improvement range is:

```text
6–18%
```

The price of the better recovery rate is higher CPU usage and longer
processing time.

### Input requirements

```text
RIFF/WAVE PCM
48,000 Hz
8- or 16-bit integer PCM
at least one channel
```

For multichannel input, only the first channel is processed.

## 4.7 Replay speed

The current limit of `pipe_delay.pl` is:

```text
100 lines/second
```

---

## 5. Process and session handling

MAIN states:

```text
idle
starting
running
stopping
idle
```

Only one processing session can be active at a time:

```text
record
wav
raw
json
```

A new session cannot start when:

- another processing session is running;
- a previous process is still stopping;
- the processor output pipe is still open;
- the recorder or processor child process is still active.

### 5.1 Process groups

MAIN starts processing pipelines in separate process groups using `setsid`.
During shutdown it:

1. removes the processor output from the `IO::Select` object;
2. sends TERM to the entire process group;
3. waits for clean termination;
4. sends KILL if necessary;
5. reaps the child process with `waitpid()`;
6. sends `running_state=0` to the frontend.

### 5.2 Pipeline generation

The `pipeline_generation` counter prevents a late event from an obsolete
session from controlling a newly started processing session.

### 5.3 Automatic completion

If the processor pipe reaches EOF, MAIN completes the session, stops the
associated process groups, then sends `running_state=0`.

The TUI responds with a complete physical screen redraw.

---

## 6. REFRESH and APPLY

The project uses two separate settings operations.

## 6.1 REFRESH

IPC:

```text
settings_apply_requested
```

It changes only:

```text
base latitude
base longitude
base altitude
base heading
reception / SondeHub frequency
SondeHub SHARE state
SondeHub MOBILE state
```

REFRESH:

- does not modify audio or filter parameters;
- does not modify the LOG directory;
- does not restart the RECORD/WAV/RAW/JSON processing pipeline;
- recalculates base-to-sonde vector data;
- may send updated base data to an active SondeHub service;
- automatically restarts only the `sondehub_upload.pl` POSIX-pipe worker when
  SHARE or MOBILE changes;
- sends the effective state back in a `settings_state` message.

During the SondeHub worker restart, both `pipeConnect.pl` directions, the
connection IDs, the MAIN–UI JSON control channel and the already opened service
window are preserved. Only the `sondehub_upload.pl` child process and its
STDIN/STDOUT pipes are replaced.

## 6.2 APPLY

IPC:

```text
settings_save_requested
```

It passes all settings to MAIN.

If no processing session is active:

```text
REFRESH
    → update MAIN settings state
    → settings_state
```

If RECORD/WAV/RAW/JSON processing is running:

```text
REFRESH
    → remember the current mode and file path
    → stop the pipeline cleanly
    → apply all settings
    → restart the same session
    → settings_state
```

For WAV, RAW and JSON, the same file is restarted.

During live recording, new timestamped WAV/Rlog/Jlog files are created, and
all previously collected calibration frames start again from zero.

## 6.3 Compatibility messages

For compatibility with older frontend elements, MAIN also treats these as full
settings saves:

```text
settings_changed
processing_settings_changed
```

---

## 7. MAIN–frontend JSON IPC

IPC uses newline-delimited JSON:

```text
one line = one complete JSON object
```

Encoding is UTF-8.

## 7.1 Frontend → MAIN

Main messages:

| Type | Meaning |
| --- | --- |
| `frontend_ready` | The frontend is ready |
| `settings_apply_requested` | Apply base and frequency settings |
| `settings_save_requested` | Save all settings |
| `start_recording_requested` | Start live recording |
| `play_wav_requested` | Process a WAV file |
| `play_raw_requested` | Process a RAW file |
| `play_json_requested` | Replay a JSON file |
| `stop_requested` | Stop processing |
| `bt_start_requested` | Start Bluetooth GPS service |
| `bt_stop_requested` | Stop Bluetooth GPS service |
| `sondehub_start_requested` | Start SondeHub service |
| `sondehub_stop_requested` | Stop SondeHub service |
| `window_close_requested` | Request coordinated frontend shutdown |
| `terminal` | Status message intended for the launcher terminal |

## 7.2 MAIN → frontend

| Type | Meaning |
| --- | --- |
| `initialize` | Initial settings and HTML configuration |
| `settings_state` | Settings actually used by MAIN |
| `receiver_update` | One decoded RS41 object |
| `runtime_statistics` | Packet and flight statistics |
| `calculated_fields` | Distance, direction and elevation angle |
| `base_position_update` | Base position updated by BT GPS |
| `running_state` | Processing running/stopped state |
| `append_log` | PRC or JSON log entry |
| `clear_logs` | Clear frontend logs and display state |
| `service_opened` | BT/SHUB service opened; MAIN receive ID |
| `bt_state` | Bluetooth service state |
| `sondehub_state` | SondeHub service state |
| `terminal` | Message intended for the launcher terminal |
| `shutdown` | Shut down the frontend |

## 7.3 `initialize`

Example:

```json
{
	"type": "initialize",
	"settings": {
		"work_dir": "/project/log",
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

After every APPLY and SAVE operation, MAIN sends the complete state:

```json
{
	"type": "settings_state",
	"settings": {
		"...": "the effective MAIN values"
	},
	"html_config": {
		"...": "map settings"
	}
}
```

The GUI and TUI treat this as the final authoritative state.

## 7.5 Launcher event requests

Launchers send `frontend_event_request` objects.

Examples:

```json
{"type":"frontend_event_request","event":"start_recording"}
{"type":"frontend_event_request","event":"open_wav","path":"/absolute/file.wav"}
{"type":"frontend_event_request","event":"set_bt","active":true}
```

The launcher sends these events only after MAIN has emitted `initialize`.

---

## 8. RS41IPC.pm

`RS41IPC.pm` is the shared IPC helper layer.

Exportable functions:

```text
json_codec
configure_json_stdio
send_json_message
decode_json_line
extract_json_messages
make_frontend_event_request
is_frontend_event_request
```

Responsibilities:

- create a canonical `JSON::PP` codec;
- configure UTF-8 STDIN/STDOUT;
- send an object as one JSON line;
- decode a complete line;
- manage partial, non-blocking input buffers;
- recognize launcher event requests.

---

## 9. RS41FrontendData.pm

This module provides the shared GUI/TUI frontend data model.

Main functions:

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

### 9.1 Sticky fields

Decoded `PARTIAL` and `INVALID` packets may contain several `null` fields.

The shared data model merges only defined new values. Therefore an incomplete
frame does not clear, for example:

- sonde ID;
- frame number;
- GPS position;
- speed;
- temperature;
- pressure;
- calibration state.

The TUI also keeps the frame number and satellite count in separate direct
sticky fields so that numeric or missing JSON values do not cause flicker.

---

## 10. Vector calculations and statistics

MAIN calculates:

```text
3D distance
great-circle ground distance
direction / bearing
elevation angle
total travelled path
peak altitude
time of peak altitude
age of the last VALID frame
VALID / PARTIAL / INVALID counts
```

Between the base and the sonde:

1. great-circle distance is calculated from WGS84 latitude/longitude;
2. 3D distance is calculated from the altitude difference;
3. bearing is calculated from the initial direction;
4. elevation angle is calculated with `atan2()`.

MAIN maintains a separately merged sonde position. Only valid numeric latitude,
longitude and altitude values may overwrite it. As a result, calculated fields
do not disappear after an incomplete frame.

---

## 11. Graphical frontend

The main GUI file is:

```text
rs41_gui.pl
```

Technologies:

```text
Perl
Gtk3
Gtk3::WebKit2
Glib
Glade XML
HTML/CSS/JavaScript
```

## 11.1 GUI structure

Widgets are described by `UI.glade`.

The Glade main-window title is `RS41 receiver GUI v0.2.46`. `dsPGtkGUI.pm`:

- initializes Gtk3;
- loads the Glade XML;
- collects widget identifiers;
- connects signal handlers to functions in the main package;
- starts and stops the GTK main loop.

## 11.2 GUI functions

- live recording;
- open WAV;
- open RAW;
- open JSON;
- stop processing;
- Bluetooth GPS toggle;
- SondeHub toggle;
- edit base position;
- edit reception frequency;
- edit audio and filter parameters;
- select LOG directory;
- position sharing and mobile mode;
- follow map center;
- PRC and JSON logs;
- WebKit map;
- separate service terminal.

## 11.3 GUI Refresh

The Refresh button sends these values in a `settings_apply_requested` message:

```text
base latitude
base longitude
base altitude
base angle
frequency
share
mobile
```

Switching SHARE or MOBILE automatically invokes the same Refresh operation.
The RECORD/WAV/RAW/JSON pipeline is not restarted, but when the SondeHub
service is active, MAIN automatically restarts its `sondehub_upload.pl`
worker. The bidirectional `pipeConnect.pl` channel and service terminal remain
open.

## 11.4 GUI Apply

The Apply button sends all fields in a `settings_save_requested` message.

When a pipeline is active, MAIN restarts the same session.

Important: during live reception, new WAV/LOG files are started and all 51
calibration frames must be collected again.

## 11.5 Field editability

The main `GtkEntry` fields have:

- `editable=TRUE`;
- `can-focus=TRUE`.

The GUI also enforces these properties programmatically during startup.

## 11.6 File selectors

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

The GUI validates the selected path and converts it to an absolute path.

---

## 12. WebKit map and data panel

`UI.html` is a standalone HTML/CSS/JavaScript interface.

It contains a built-in minimal Leaflet-compatible implementation, so no
external Leaflet JavaScript or CSS files are required.

Main capabilities:

- tiled map;
- mouse dragging;
- wheel zoom;
- zoom buttons;
- base heading marker;
- sonde heading marker;
- track line;
- track points;
- automatic sonde following;
- fitting base and sonde together;
- 28-field data panel;
- collapsible data panel;
- vertically resizable map/data boundary.

HTML template placeholders:

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

Tile images are loaded from the configured tile server. The default is
OpenStreetMap.

The WebKit cache is stored in the project's own `cache` directory.

---

## 13. Terminal frontend

Technology:

```text
Perl Curses / ncurses
UTF-8 terminal
keyboard
ncurses mouse handling
```

## 13.1 Minimum terminal size

```text
132 × 45 characters
```

The complete layout does not fit in a smaller terminal.

## 13.2 Menu

```text
1  RECORD
2  WAV
3  RAW
4  JSON
5  STOP
6  BT
7  SHUB
8  SETTINGS
q  EXIT
```

Indicators:

```text
[_] inactive
[#] active
<| ... |> selected
```

Controls:

```text
Left/Right     change menu item
Enter/Space    activate
1–8            direct command
q              exit
```

## 13.3 Main screen

The main TUI sections are:

1. menu bar;
2. base data;
3. reception data;
4. calculated vector data;
5. audio and filter settings;
6. packet statistics;
7. 28-field RS41 data table;
8. diagnostics panel.

## 13.4 Settings state

The TUI keeps two separate hashes:

```text
%config
    effective state returned by MAIN

%settings_draft
    editable copy used by the settings window
```

When the settings window opens:

```text
%config → %settings_draft
```

Field editing changes only the draft state. The main screen changes only in
response to `initialize`, `settings_state` or `base_position_update` messages
from MAIN.

## 13.5 TUI settings

Editable fields:

```text
Base / Latitude
Base / Longitude
Base / Altitude
Base / Angle
Reception / Frequency MHz
SondeHub / Share position
SondeHub / Mobile base
Audio / Device
Audio / Hz
Filter / LF
Filter / HF
Filter / O
Filter / P
Filter / D
Filter / Invert
System / LOG directory
```

Field editing:

```text
Left/Right     move cursor
Home/End       start/end of line
Backspace      delete previous character
Delete         delete current character
Enter          accept value into draft
Esc            discard field edit
```

## 13.6 Closing the settings window

If no RECORD/WAV/RAW/JSON processing is active:

```text
Esc
    → settings_apply_requested
    → settings_save_requested
    → settings_state
```

If processing is active:

```text
Esc
    → only settings_apply_requested
    → settings_state
```

While processing is running:

- the base may be updated;
- the frequency may be updated;
- SHARE may be updated;
- MOBILE may be updated;
- audio, filter and LOG-directory draft values are not saved;
- the RECORD/WAV/RAW/JSON pipeline is not restarted;
- when SondeHub is active, only the `sondehub_upload.pl` POSIX-pipe worker is
  restarted after a SHARE or MOBILE change.

## 13.7 TUI file selector

The TUI shows only direct files in the current LOG directory.

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

Controls:

```text
Up/Down        selection
PageUp/Down    page navigation
Home/End       first/last item
Enter          open
Esc            close
```

There is no directory navigation and no recursive search.

## 13.8 Mouse handling

Clickable elements:

- main menu;
- settings rows;
- file-selector rows;
- Enter and Esc controls in the settings window;
- Enter and Esc controls in the file selector;
- HOME and END controls in the service window.

Perl Curses `getmouse()` returns a binary MEVENT scalar. The TUI decodes it
according to the Linux/ncurses structure.

## 13.9 Forced full redraw

The TUI requests a full physical screen redraw:

- when the file selector closes;
- when a BT/SHUB service window is hidden;
- when a BT/SHUB connection closes;
- when the settings window closes;
- when the STOP menu is activated;
- when MAIN sends `running_state=0`;
- after the processing pipe ends.

Redraw sequence:

```text
clearok(window, 1)
touchwin(window)
window->clear()
window->erase()
complete draw_screen()
refresh
```

This prevents popup borders, error messages or a missing menu bar from
remaining on the terminal.

---

## 14. RS41 demodulators

The project includes two RS41 GFSK demodulators:

```text
rs41_mod
rs41_mod.py
```

`rs41_mod` is the earlier x86-64 Linux binary demodulator. `rs41_mod.py` is
the project's own Python RS41 GFSK demodulator and Reed–Solomon frame
corrector.

### 14.1 `rs41_mod`

Original source: https://github.com/rs1729/RS . The source of the specific
version used by this project can be found inside the `src` directory.

Default use by MAIN:

```bash
./rs41_mod -vv -r -i /dev/stdin
```

`-i` is included only when `AUDIO_INVERT` is enabled.

The demodulator emits RAW hexadecimal frame lines to the Perl decoder.

The binary must be executable:

```bash
chmod +x rs41_mod
```

`rs41_mod` remains supported, but because `rs41_mod.py` is included, it is no
longer a mandatory project dependency.

### 14.2 `rs41_mod.py`

`rs41_mod.py` is the project's own RS41 GFSK demodulator. It reads a WAV/PCM
stream from STDIN, detects RS41 frames, performs dewhitening and corrects the
two interleaved RS(255,231) Reed–Solomon codewords.

Its output can be processed directly by the Perl decoder: one 320-byte
hexadecimal RS41 frame per line.

According to current measurements, `rs41_mod.py` can decode approximately 12%
more valid RS41 packets from the same audio source than the original
`rs41_mod`. Depending on reception conditions, the measured improvement is
6–18%.

The cost of the better decoding rate, and of using Python, is:

- slower processing;
- higher CPU usage;
- longer total processing time.

### 14.3 Automatic inverted-signal detection

`rs41_mod.py` automatically detects whether the input signal has normal or
inverted polarity.

Therefore, when `rs41_mod.py` is used:

```text
AUDIO_INVERT
```

has no effect. The Python demodulator ignores the invert switch because it
automatically determines the correct polarity for each frame.

The original `rs41_mod` command-line options do not need to be supplied to
`rs41_mod.py`, so the `{MOD_ARGS}` placeholder must not be used with it.

### 14.4 Selecting the demodulator in `config.txt`

The project's default pipeline uses the original binary demodulator:

```text
| {MOD_COMMAND} {MOD_ARGS} |
```

Built-in MAIN defaults:

```text
MOD_COMMAND:
    ./rs41_mod

MOD_ARGS:
    -vv -r [-i] /dev/stdin
```

This default also applies when the `PIPE_RECORD` or `PIPE_WAV` configuration
entry is missing, empty or commented out.

To use `rs41_mod.py`, replace the demodulator part of the `PIPE_RECORD` and
`PIPE_WAV` lines in `config.txt` with:

```text
| ./rs41_mod.py |
```

For live reception:

```text
PIPE_RECORD=arecord -D {AUDIO_DEVICE} -t wav -f S16_LE -r {AUDIO_SAMPLE_RATE} -c 1 -q | {FILTER_COMMAND} {FILTER_ARGS} | ./rs41_mod.py | tee -a {RLOG_FILE} | {DECODER} --json | tee -a {JLOG_FILE}
```

For WAV processing:

```text
PIPE_WAV=sox -- {INPUT_FILE} -t wav -b 16 -e signed-integer -c 1 -r {AUDIO_SAMPLE_RATE} - | {FILTER_COMMAND} {FILTER_ARGS} | ./rs41_mod.py | {DECODER} --json
```

Important:

```text
rs41_mod:
    | {MOD_COMMAND} {MOD_ARGS} |

rs41_mod.py:
    | ./rs41_mod.py |
```

Do not include `{MOD_ARGS}` on the `rs41_mod.py` line, because the Python
demodulator does not use the original binary's `-vv`, `-r`, `-i` and
`/dev/stdin` arguments.

The Python demodulator requires:

```bash
chmod +x rs41_mod.py
sudo apt install python3 python3-numpy
```

---

## 15. Audio filtering

`rs41_filter_stream.py` is a continuous WAV-stream filter.

Input:

```text
PCM
S16_LE
mono
RIFF/WAVE
```

Output:

```text
continuous PCM S16_LE mono WAV
```

Main operations:

- parse WAV header;
- validate format;
- high-pass Butterworth filter;
- low-pass Butterworth filter;
- `scipy.signal.sosfiltfilt`;
- block-based processing;
- peak-based AGC;
- maximum gain limiting;
- write 16-bit PCM;
- streaming WAV header.

Options:

| Option | Meaning |
| --- | --- |
| `-LF`, `--low-frequency` | Lower cutoff frequency |
| `-HF`, `--high-frequency` | Upper cutoff frequency |
| `-O`, `--order` | Butterworth order |
| `-P`, `--peak` | AGC target peak |
| `-D`, `--delay` | Block size and delay |
| `-MG`, `--max-gain` | Maximum AGC gain |
| `-NA`, `--no-agc` | Disable AGC |
| `-V`, `--verbose` | Print parameters to STDERR |

MAIN passes every important filter parameter explicitly, so the Python file's
standalone defaults are not normally relevant when started through the
project.

Validity conditions:

```text
LF > 0
HF > LF
HF < sample_rate / 2
order >= 1
0 < peak <= 1
delay >= 0.1
max_gain > 0
```

---

## 16. RS41 RAW decoder

Decoder:

```text
rs41_raw_decode_fixed_fields.pl
```

Input:

```text
rs41_mod -r line format
at least 640 hexadecimal characters
optional [OK] or [NO]
optional additional status text
```

Options:

```text
--json
--no-raw
--calibration
--only-valid
--help
```

## 16.1 Validity levels

```text
VALID
    header is valid and every examined subpacket has a valid CRC

PARTIAL
    header is valid and at least one subpacket has a valid CRC

INVALID
    header is invalid or no usable subpacket exists
```

## 16.2 Examined subpackets

```text
frame
ptu
gps1
gps2
gps3
end
```

## 16.3 Decoded data

- frame number;
- sonde ID;
- battery voltage;
- calibration-frame index;
- GPS week and TOW;
- UTC-like GPS time;
- ECEF position;
- WGS84 latitude, longitude and altitude;
- ECEF velocity;
- ENU velocity;
- horizontal speed;
- heading;
- vertical speed;
- satellite count;
- SACC;
- PDOP;
- raw PTU measurements;
- temperature;
- humidity-sensor temperature;
- relative humidity;
- empirical humidity;
- pressure;
- pressure estimated from altitude;
- calibration coverage;
- complete calibration CRC;
- frequency and model configuration.

## 16.4 Calibration

The decoder keeps separate state for each sonde:

```text
sonde ID
calibration subframes
received indexes
missing indexes
concatenated calibration byte field
```

PTU calculations become active only after the required calibration subframes
have been received.

---

## 17. Bluetooth GPS Bridge

Bluetooth worker:

```text
gps_bridge_bt.pl
```

Tasks:

1. check required commands;
2. start the Bluetooth service;
3. unblock RFKill;
4. enable the adapter;
5. enable pairable and discoverable mode;
6. scan for devices;
7. select the preferred MAC or ask interactively;
8. pair if necessary;
9. locate the SDP service and RFCOMM channel;
10. create the `/dev/rfcommN` connection;
11. forward GPS JSON lines;
12. clean up RFCOMM and Bluetooth on shutdown.

Required commands:

```text
bluetoothctl
rfcomm
sdptool
systemctl
sudo
rfkill
```

The worker performs cleanup on SIGINT, SIGTERM, SIGHUP, SIGQUIT and SIGPIPE.

## 17.1 GPS processing by MAIN

MAIN may forward the worker's complete terminal traffic to the frontend
service window, but it accepts only valid JSON objects as base updates.

Expected fields:

```text
lat
lon
alt
heading_true or heading_mag or course
```

After a successful update:

```text
base_position_update
calculated_fields
optional SondeHub base update
```

---

## 18. SondeHub uploader

Worker:

```text
sondehub_upload.pl
```

Protocol version:

```bash
./sondehub_upload.pl --protocol-version
```

Output:

```text
2
```

Options:

```text
--dev
--help
--protocol-version
```

## 18.1 Input messages

```text
message_type = sonde
message_type = base
```

The input contains one JSON object per line.

## 18.2 Conditions for telemetry upload

MAIN forwards a `message_type=sonde` object only if all of the following are
true:

```text
the SondeHub worker is active
a live record session is running
the frame is VALID
calibration.complete = true
calibration.seen_count >= 51
```

No telemetry is uploaded from WAV, RAW or JSON replay. The 51 calibration
subframes correspond to the `0x00–0x32` range.

## 18.3 Telemetry batching

The worker batches telemetry according to `SONDEHUB_TELEMETRY_INTERVAL_S`,
sends it with HTTP PUT, optionally uses gzip compression, and writes every
payload to an `.Slog` file.

## 18.4 True periodic listener updates

Base uploads occur only when SHARE is active. The worker keeps two states:

```text
latest_base
    most recently received base position

pending_base
    position waiting for the next listener PUT
```

After a successful listener PUT, `latest_base` is automatically returned to
`pending_base`. Therefore, the next listener update also occurs without a new
GPS event.

Timing:

```text
fixed station: SONDEHUB_FIXED_BASE_INTERVAL_S
mobile station: SONDEHUB_MOBILE_BASE_INTERVAL_S
movement threshold: SONDEHUB_BASE_MOVE_DISTANCE_M
minimum retry interval: SONDEHUB_BASE_MIN_INTERVAL_S
```

Example:

```text
SONDEHUB_MOBILE_BASE_INTERVAL_S=120
SONDEHUB_BASE_MOVE_DISTANCE_M=100
SONDEHUB_BASE_MIN_INTERVAL_S=30
```

With movement below 100 metres, a listener PUT occurs every 120 seconds. With
movement of at least 100 metres, an out-of-schedule PUT becomes due, but at
least 30 seconds must have passed since the previous attempt.

## 18.5 SHARE/MOBILE changes and automatic Open2 restart

The GUI and TUI APPLY operation forwards `share` and `mobile` in addition to
base and frequency. The GUI automatically sends an APPLY request when either
switch changes.

MAIN compares the old and new state. If SHARE or MOBILE changes while the
SondeHub service is active, it restarts only the worker process:

```text
stop_service_worker('sondehub')
start_service_worker('sondehub')
```

Preserved:

```text
service_pipe{sondehub} state object
abstract UNIX socket
listener socket
frontend client socket
endpoint
token
GUI/TUI service window
```

Only the `sondehub_upload.pl` Open2 process and its STDIN/STDOUT pipes are
replaced. The new worker is attached to the existing channel, so the frontend
does not need to open a new terminal or reconnect.

## 18.6 Development mode

```bash
./sondehub_upload.pl --dev
```

The payload is created and logged, but no real HTTP upload is performed.
Periodic listener rescheduling also works in development mode.

## 18.7 Logging

```text
sondehub_YYYY-MM-DD_HH-MM-SS.Slog
```

## 18.8 Test and production endpoints

Local test:

```text
SONDEHUB_TELEMETRY_API_URL=http://127.0.0.1:8080/sondes/telemetry
SONDEHUB_LISTENER_API_URL=http://127.0.0.1:8080/listeners
```

Production SondeHub:

```text
https://api.v2.sondehub.org/sondes/telemetry
https://api.v2.sondehub.org/listeners
```

---

## 19. pipeConnect service architecture

MAIN, GUI, TUI and `terminal_service.pl` do not use the UNIX-socket API
directly. Socket handling exists exclusively in:

```text
pipeConnect.pl
```

## 19.1 Reader mode

```bash
./pipeConnect.pl -R
```

Operation:

1. create a random Linux abstract UNIX socket;
2. return the receive ID in the first line of stdout;
3. after the first line, stdout carries an unchanged RAW byte stream.

## 19.2 Writer mode

```bash
./pipeConnect.pl -W RECEIVE_ID
```

The RAW byte stream from stdin is forwarded unchanged.

## 19.3 Bidirectional connection

```text
UI → MAIN:
    UI:   pipeConnect.pl -W MAIN_ID
    MAIN: pipeConnect.pl -R

MAIN → UI:
    MAIN: pipeConnect.pl -W UI_ID
    UI:   pipeConnect.pl -R
```

The two directions use separate abstract UNIX sockets.

## 19.4 Startup handshake

1. UI starts a `pipeConnect.pl -R` process.
2. UI reads its receive ID.
3. UI sends this ID to MAIN in the BT/SHUB request.
4. MAIN creates its own `pipeConnect.pl -R` receiver.
5. MAIN starts a `pipeConnect.pl -W UI_ID` writer.
6. MAIN starts the worker with POSIX `fork/pipe/setsid/exec`.
7. Worker stdout is connected to MAIN's writer toward the UI.
8. MAIN's reader from the UI is connected to worker stdin.
9. MAIN sends its receive ID in a `service_opened` message.
10. UI starts a `pipeConnect.pl -W MAIN_ID` writer.

## 19.5 GUI service terminal

The GUI starts `terminal_service.pl` in a separate terminal. Both its data and
control channels use `pipeConnect.pl -R/-W` processes.

## 19.6 TUI service window

The TUI directly owns its `pipeConnect.pl -R/-W` child processes.

## 19.7 Restarting the SondeHub worker

When SHARE or MOBILE changes, only these are replaced:

```text
sondehub_upload.pl
worker STDIN pipe
worker STDOUT pipe
worker process group
```

Preserved:

```text
MAIN pipeConnect -R
MAIN pipeConnect -W
UI pipeConnect -R
UI pipeConnect -W
MAIN–UI JSON control channel
GUI/TUI service window
```

During a controlled restart, EOF or a write error from the old worker cannot
tear down the complete service connection.

## 19.8 Portability boundary

The Linux-specific abstract UNIX socket implementation exists only in
`pipeConnect.pl`. For BSD or Hurd, another implementation with the same
`-R/-W` interface can be provided without changing the main program.

---

## 20. terminal_service.pl

Client for the GUI's separate terminal.

Options:

```text
--endpoint NAME
--token TOKEN
--service bt|sondehub
```

Operation:

1. open abstract UNIX socket;
2. send `RS41_ATTACH` line;
3. switch terminal to raw mode;
4. disable echo and canonical mode;
5. disable XON/XOFF and CR conversion;
6. relay STDIN ↔ socket bidirectionally;
7. restore terminal on exit.

The GUI tries the following terminal emulators in order:

```text
gnome-terminal
mate-terminal
xfce4-terminal
konsole
xterm
```

---

## 21. Startup

## 21.1 Executable permissions

Scripts and binaries must be executable:

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

## 21.4 Direct startup modes

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

Accepted aliases:

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

Only one of RECORD, WAV, RAW and JSON may be specified at a time.

BT and SHUB may be combined with any of them.

Example:

```bash
./startTUI.sh -FELV -BT -SHUB
```

## 21.5 Relative file paths

The launcher resolves file paths relative to the directory from which the
command was issued, then converts them to absolute paths.

The file must already exist when the launcher starts.

---

## 22. Configuration system

`config.txt` format:

```text
NAME=value
```

Priority:

```text
launcher ENV
    ↓
config.txt
    ↓
built-in default
```

## 22.1 Processing pipelines

```text
PIPE_RECORD
PIPE_WAV
PIPE_RAW
PIPE_JSON
```

For a missing or empty key, MAIN uses the built-in default.

## 22.2 Pipeline placeholders

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

## 22.3 FILTER/MOD program and arguments

```text
{FILTER_COMMAND}
    filter program only

{FILTER_ARGS}
    current filter parameters

{MOD_COMMAND}
    demodulator program only

{MOD_ARGS}
    current demodulator parameters
```

This allows selection between `rs41_mod` and `rs41_mod.py` in the
configuration, while the Invert option is dynamically inserted into
`MOD_ARGS`.

## 22.4 Live monitoring and WAV-log branch

```text
WAV_LOG_ENABLED
RECORD_MONITOR_COMMAND
```

The default value of `WAV_LOG_ENABLED` is `1`. WAV logging is enabled when the
entry is missing, empty or commented out.

New `RECORD_MONITOR_COMMAND` placeholder:

```text
{WAV_LOG_PIPE}
```

Value:

```text
WAV_LOG_ENABLED=1:
    | tee -- {WAV_FILE}

WAV_LOG_ENABLED=0:
    empty
```

This is independently configurable because the default `arecord/aplay`
implementation depends on Linux ALSA.

## 22.5 BT and SondeHub worker startup

```text
BT_WORKER_COMMAND
SONDEHUB_WORKER_COMMAND
```

MAIN executes these through general POSIX process handling.

Current Linux defaults:

```text
BT_WORKER_COMMAND:
    script -qefc "exec {PERL} {BT_WORKER} 2>&1" /dev/null

SONDEHUB_WORKER_COMMAND:
    exec {PERL} {SONDEHUB_WORKER} 2>&1
```

The platform-dependent PTY wrapper appears only in `BT_WORKER_COMMAND`.

## 22.6 Launcher configuration overrides

`startGUI.sh` and `startTUI.sh` do not use a configuration-name whitelist.
Any setting can be passed when its name contains only:

```text
A–Z
0–9
_
```

Examples:

```bash
./startGUI.sh -WAV_LOG_ENABLED=0
./startTUI.sh -WAV_LOG_ENABLED=1
./startGUI.sh -PIPE_RECORD='custom command'
./startTUI.sh -SONDEHUB_MOBILE_BASE_INTERVAL_S=120
```

The `CONFIG:` and `CFG:` prefixes are also accepted:

```bash
./startGUI.sh -CONFIG:WAV_LOG_ENABLED=0
./startTUI.sh -CFG:WAV_LOG_ENABLED=0
```

The launcher passes the values as environment variables. Priority:

```text
launcher parameter / ENV
    ↓
config.txt
    ↓
built-in default
```

If a value contains spaces or shell-special characters, the complete argument
must be quoted for the shell.

All current configuration names in `config.txt` satisfy this naming rule, so
every one of them can be overridden by either launcher.

## 22.7 Runtime state

The GUI and TUI do not automatically write back to `config.txt`. MAIN owns the
runtime settings state.

---

## 23. Configuration responsibility

The following programs read `config.txt` directly:

```text
rs41_main.pl
gps_bridge_bt.pl
sondehub_upload.pl
```

The following do not read it directly:

```text
rs41_gui.pl
rs41_tui.pl
startGUI.sh
startTUI.sh
rs41_filter_stream.py
rs41_raw_decode_fixed_fields.pl
terminal_service.pl
```

The TUI receives initial settings through MAIN's `initialize` message.

The GUI also uses MAIN's state.

Runtime changes made by the GUI and TUI do not modify `config.txt`.

---

## 24. Configuration keys

## 24.1 SondeHub API and identification

| Key | Built-in default | Meaning |
| --- | --- | --- |
| `SONDEHUB_TELEMETRY_API_URL` | official telemetry URL | Telemetry PUT endpoint |
| `SONDEHUB_LISTENER_API_URL` | official listener URL | Listener PUT endpoint |
| `SONDEHUB_SOFTWARE_NAME` | `DsRS41Tracker` | Reported software name |
| `DSRS41TRACKER_VERSION` | `0.2.46` | Complete application version |
| `SONDEHUB_SOFTWARE_VERSION` | `0.2.46` | Reported version |
| `SONDEHUB_UPLOADER_CALLSIGN` | `SWL` | Uploader identifier |
| `SONDEHUB_MANUFACTURER` | `Vaisala` | Manufacturer |
| `SONDEHUB_TYPE` | `RS41` | Main type |
| `SONDEHUB_SUBTYPE` | `RS41-SGP` | Subtype |
| `SONDEHUB_RECEIVER` | `UNDEFINED` | Radio receiver |
| `SONDEHUB_RECEIVER_FIRMWARE` | `UNDEFINED` | Firmware |
| `SONDEHUB_ANTENNA` | `UNDEFINED` | Antenna |

## 24.2 SondeHub operation

| Key | Default | Meaning |
| --- | ---: | --- |
| `SONDEHUB_SHARE` | `0` | Share base position |
| `SONDEHUB_MOBIL` | `0` | Mobile listener |
| `SONDEHUB_HTTP_TIMEOUT_S` | `15` | HTTP timeout |
| `SONDEHUB_FREQUENCY_MHZ` | `400.000` | Reception frequency |
| `SONDEHUB_TELEMETRY_INTERVAL_S` | `30` | Telemetry-batch interval |
| `SONDEHUB_FIXED_BASE_INTERVAL_S` | `21600` | Fixed-base interval |
| `SONDEHUB_MOBILE_BASE_INTERVAL_S` | `600` | Mobile-base interval |
| `SONDEHUB_BASE_MIN_INTERVAL_S` | `30` | Minimum retry interval |
| `SONDEHUB_BASE_MOVE_DISTANCE_M` | `100` | Out-of-schedule movement |
| `SONDEHUB_GZIP_ENABLED` | `0` | HTTP gzip |

Active frequency in the supplied configuration:

```text
403.700 MHz
```

Active mobile-base interval:

```text
60 seconds
```

## 24.3 Logging

| Key | Default | Meaning |
| --- | --- | --- |
| `LOG_DIRECTORY` | `./log` | WAV/Rlog/Jlog/Slog directory |

MAIN converts it to an absolute path. If the directory does not exist, it may
fall back to the project directory.

## 24.4 Bluetooth

| Key | Default | Meaning |
| --- | --- | --- |
| `RFCOMM_DEVICE_NUMBER` | `0` | RFCOMM device number |
| `RFCOMM_DEVICE_PATH` | `/dev/rfcomm0` | Device path |
| `GPS_SERVICE_NAME` | `GPS Bridge` | SDP service name |
| `SCAN_TIME_SECONDS` | `15` | Scan duration |
| `PREFERRED_DEVICE_MAC` | empty | MAC to select automatically |

## 24.5 Base

| Key | Default |
| --- | ---: |
| `BASE_LAT` | `47.49786` |
| `BASE_LON` | `19.04022` |
| `BASE_ALT` | `110` |
| `BASE_ANGLE` | `0` |

## 24.6 Map

| Key | Default |
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

Active differences in the supplied configuration:

```text
TRACK_WIDTH=1
TRACK_POINT_RADIUS=2
```

## 24.7 Audio and demodulation

| Key | MAIN default | Meaning |
| --- | ---: | --- |
| `AUDIO_DEVICE` | `default` | ALSA device |
| `AUDIO_SAMPLE_RATE` | `48000` | Sample rate |
| `AUDIO_LF` | `525` | High-pass cutoff |
| `AUDIO_HF` | `14000` | Low-pass cutoff |
| `AUDIO_ORDER` | `1` | Butterworth order |
| `AUDIO_PEAK` | `0.75` | AGC target peak |
| `AUDIO_DELAY` | `0.1` | Processing block |
| `AUDIO_INVERT` | `1` | Demodulator inversion |
| `WAV_LOG_ENABLED` | `1` | Enable live WAV logging |

---

## 25. Dependencies and Debian installation

The following commands do not use the automatic `-y` option.

## 25.1 Perl base and TUI

```bash
sudo apt install \
	perl \
	libcurses-perl \
	libio-compress-perl
```

The base Perl installation provides, among others, `JSON::PP`, `IO::Select`,
`IPC::Open2`, `Time::HiRes`, `File::Spec`, `POSIX` and `Fcntl`.

## 25.2 GTK3/WebKit2 GUI

```bash
sudo apt install \
	libgtk3-perl \
	libglib-perl \
	libglib-object-introspection-perl \
	libgtk3-webkit2-perl
```

`libgtk3-webkit2-perl` provides the `Gtk3::WebKit2` Perl binding on Debian
Bookworm and Trixie.

## 25.3 Python filter and Python demodulator

```bash
sudo apt install \
	python3 \
	python3-numpy \
	python3-scipy
```

The direct dependencies of `rs41_mod.py` are Python 3 and NumPy.
`rs41_filter_stream.py` also uses SciPy.

## 25.4 Audio and processing

```bash
sudo apt install \
	alsa-utils \
	sox \
	util-linux
```

`sox` is required by the default WAV-replay pipeline implementation.

`alsa-utils` provides the `arecord` and `aplay` programs used by the default
Linux configuration.

## 25.5 Bluetooth GPS

```bash
sudo apt install \
	bluez \
	rfkill \
	util-linux \
	sudo
```

The Bluetooth worker also uses the system's `systemctl`, `bluetoothctl`,
`rfcomm` and `sdptool` programs.

## 25.6 GUI terminal

At least one supported terminal emulator is required. For example:

```bash
sudo apt install xterm
```

Other supported options may include:

```text
gnome-terminal
mate-terminal
xfce4-terminal
konsole
xterm
```

---

## 26. Project files

| File | Lines/size | Role |
| --- | ---: | --- |
| `config.txt` | 194 lines | Complete configuration |
| `dsPGtkGUI.pm` | 194 lines | Gtk3/Glade helper module |
| `gps_bridge_bt.pl` | 988 lines | Bluetooth RFCOMM GPS worker |
| `pipe_delay.pl` | 62 lines | RAW/JSON rate limiting |
| `rs41_filter_stream.py` | 430 lines | Audio filtering and AGC |
| `rs41_mod.py` | – | Python GFSK demodulator and RS corrector |
| `RS41_MOD_PYTHON.md` | – | Python demodulator measurement documentation |
| `rs41_gui.pl` | 774 lines | GTK3/WebKit2 frontend |
| `rs41_main.pl` | 1776 lines | Central backend |
| `rs41_mod` | 114240 bytes | x86-64 RS41 demodulator |
| `rs41_raw_decode_fixed_fields.pl` | 972 lines | RAW decoder |
| `rs41_tui.pl` | 3450 lines | Curses frontend |
| `RS41FrontendData.pm` | 339 lines | Shared frontend data model |
| `RS41IPC.pm` | 110 lines | JSON IPC |
| `sondehub_upload.pl` | 913 lines | SondeHub worker |
| `startGUI.sh` | 352 lines | GUI launcher |
| `startTUI.sh` | 349 lines | TUI launcher |
| `terminal_service.pl` | 108 lines | GUI service-terminal client |
| `UI.glade` | 840 lines | GTK UI description |
| `UI.html` | 882 lines | Map and web data panel |

---

## 27. Detailed file relationships

### `rs41_main.pl`

Central component of the system:

- configuration loading;
- ENV overrides;
- pipeline startup/shutdown;
- child processes;
- receiving RAW/JSON lines;
- statistics;
- sticky calculation position;
- distance/bearing/elevation;
- GUI/TUI IPC;
- APPLY/SAVE;
- pipeline restart;
- BT GPS;
- SondeHub;
- direct service socket;
- complete shutdown.

### `rs41_gui.pl`

- GUI widgets;
- user events;
- file selectors;
- settings draft;
- APPLY and SAVE;
- WebKit JavaScript;
- map and data panel;
- separate BT/SHUB terminal.

### `rs41_tui.pl`

- TUI layout;
- menu;
- 28-value table;
- settings draft;
- file selector;
- keyboard;
- mouse;
- direct MAIN service connection;
- full redraw;
- diagnostics.

### `UI.glade`

Source of the GTK widget hierarchy and signal names.

### `UI.html`

Embedded map and web data panel.

### `dsPGtkGUI.pm`

General layer for loading Glade and automatically connecting signals.

### `RS41IPC.pm`

Shared JSON protocol layer for MAIN and frontend.

### `RS41FrontendData.pm`

Shared display logic for GUI and TUI.

### `terminal_service.pl`

Direct client program for the separate terminal opened by the GUI.

---

## 28. Normal usage workflow

### Live reception

1. Connect the radio's audio output.
2. Verify the ALSA device.
3. Start the GUI or TUI.
4. Set the frequency and base position.
5. Activate the RECORD menu.
6. Monitor the VALID/PARTIAL/INVALID ratio.
7. Start BT GPS if necessary.
8. Start SHUB when production SondeHub URLs are configured.
9. Activate STOP to end processing.
10. Closing the frontend causes MAIN to stop every service.

### Previous recording

```text
WAV
    complete reprocessing

RAW
    decode again

JSON
    replay decoded events
```

---

## 29. Testing

## 29.1 Perl syntax

```bash
perl -I. -c rs41_main.pl
perl -I. -c rs41_gui.pl
perl -I. -c rs41_tui.pl
perl -I. -c gps_bridge_bt.pl
perl -I. -c rs41_raw_decode_fixed_fields.pl
perl -I. -c sondehub_upload.pl
perl -I. -c terminal_service.pl
```

Gtk3/WebKit2 is required even for syntax checking the GUI, and Curses is
required for the TUI.

## 29.2 Python

```bash
python3 -m py_compile rs41_filter_stream.py
```

## 29.3 TUI version

```bash
./rs41_tui.pl --version
```

## 29.4 Demodulator

```bash
file rs41_mod
./rs41_mod --help
```

## 29.5 RAW decoder

```bash
cat -- ./log/sample.Rlog \
	| ./rs41_raw_decode_fixed_fields.pl --json
```

## 29.6 JSON replay

```bash
./startTUI.sh -JSON="./log/sample.Jlog"
```

## 29.7 WAV processing

```bash
./startGUI.sh -WAV="./log/sample.wav"
```

## 29.8 APPLY

1. Start RECORD or WAV processing.
2. Change the base position or frequency.
3. Press APPLY.
4. Verify that the pipeline does not restart.
5. Verify that `settings_state` is loaded back.

## 29.9 SAVE

1. Start WAV or RAW processing.
2. Change an audio or filter value.
3. Press SAVE.
4. Verify clean shutdown.
5. Verify that the same file restarts.

## 29.10 TUI closing rule

While stopped:

```text
SETTINGS → change → Esc
```

Expected:

```text
APPLY + SAVE
```

While running:

```text
RECORD/WAV/RAW/JSON → SETTINGS → change → Esc
```

Expected:

```text
APPLY only
```

## 29.11 Automatic SondeHub worker restart

1. Start the SondeHub service.
2. Note the endpoint and opened terminal.
3. Change SHARE or MOBILE.
4. Verify the POSIX-pipe worker restart message.
5. Verify that the service window remains open.
6. Verify that the endpoint and token do not change.
7. Verify that the new worker sends a listener PUT message.

## 29.12 Periodic mobile-listener test

```text
SONDEHUB_MOBILE_BASE_INTERVAL_S=120
SONDEHUB_BASE_MIN_INTERVAL_S=30
SONDEHUB_BASE_MOVE_DISTANCE_M=100
```

1. Enable SHARE and MOBILE.
2. Send a valid base position.
3. Verify the first listener PUT.
4. Do not send another GPS position.
5. Verify that another PUT occurs after approximately 120 seconds.
6. Send a position at least 100 metres away.
7. Verify that the next PUT occurs no earlier than 30 seconds later.

## 29.13 TUI redraw

Test:

- file selector Esc;
- file Enter;
- BT HOME;
- BT END;
- SHUB HOME;
- SHUB END;
- settings-window Esc;
- STOP;
- natural pipe EOF.

The menu bar and every panel must be restored immediately and completely.

---

### 29.14 Troubleshooting

#### GUI does not start

Check:

```text
Gtk3 Perl module
Gtk3::WebKit2 Perl module
UI.glade
UI.html
dsPGtkGUI.pm
DISPLAY / graphical session
```

#### TUI does not start

Check:

```text
libcurses-perl
UTF-8 locale
at least a 132×45 terminal
RS41IPC.pm
RS41FrontendData.pm
```

#### Menu bar disappears after STOP

Version 0.2.46 uses `clearok()`, `touchwin()` and a full redraw after
`running_state=0`. Check:

```bash
./rs41_tui.pl --version
```

#### No audio

```bash
arecord -l
arecord -D default -t wav -f S16_LE -r 48000 -c 1 /tmp/test.wav
aplay /tmp/test.wav
```

#### Filter stops

Check:

```text
LF > 0
HF > LF
HF < sample_rate / 2
order >= 1
peak between 0 and 1
delay >= 0.1
NumPy and SciPy installed
```

#### WAV does not start

Check:

- file is readable;
- SoX is installed;
- no other session is running;
- file is actually WAV;
- file path contains no newline or NUL character.

#### RAW does not decode

Check:

- the Rlog contains genuine `rs41_mod -r` lines;
- each line has at least 640 hexadecimal characters;
- the decoder is executable;
- the file is not binary.

#### Bluetooth does not start

Check:

```text
bluez
rfkill
sudo
bluetooth.service
RFCOMM kernel module
GPS Bridge SDP service
terminal password entry
```

#### SondeHub does not upload

First check whether the configuration still uses localhost test URLs.

For telemetry, check:

```text
live record session
VALID frame
calibration.complete = true
calibration.seen_count >= 51
```

For listener uploads, check:

```text
SONDEHUB_SHARE = 1
whether MOBILE appears in the settings_state response
whether the SondeHub worker restarted after the switch change
whether the worker terminal is still connected
whether periodic latest_base and pending_base rescheduling works
```

Also check:

```text
internet
TLS certificates
callsign
SONDEHUB_SHARE
HTTP status
.Slog file
```

#### Distance or direction disappears

MAIN merges only complete numeric sonde positions. Verify that the current
`rs41_main.pl` is running and that an older copy is not being picked up from
the PATH or another directory.

#### Service terminal does not open

Check:

- `terminal_service.pl` is executable;
- at least one supported terminal emulator is installed;
- the frontend received `service_opened`;
- token and endpoint are not empty;
- Linux abstract UNIX sockets are supported.

---

## 30. Security and privacy notes

- The Bluetooth worker uses `sudo` commands.
- The sudo password is requested in the PTY terminal.
- MAIN's service socket is local and token-protected, but it is not a network
  authentication system.
- The SondeHub service sends position and telemetry to an external server.
- `SONDEHUB_SHARE=1` means sharing the base position.
- In mobile mode, listener position may be updated more frequently.
- `.Slog` files contain upload payloads.
- Callsign, radio and antenna values from the configuration may appear in
  public payloads.
- Runtime settings exist only in memory and are not automatically saved
  persistently.

---

## 31. Quick reference

### Startup

```bash
./startGUI.sh
./startTUI.sh
```

### Live reception

```bash
./startTUI.sh -FELV
```

### WAV

```bash
./startGUI.sh -WAV="./log/sample.wav"
```

### RAW

```bash
./startTUI.sh -RAW="./log/sample.Rlog"
```

### JSON

```bash
./startTUI.sh -JSON="./log/sample.Jlog"
```

### BT + SondeHub

```bash
./startTUI.sh -FELV -BT -SHUB
```

### TUI version

```bash
./rs41_tui.pl --version
```

### Stop processing

```text
GUI: STOP button
TUI: 5 or STOP menu
```

### Settings

```text
APPLY
    base + frequency
    no pipeline restart

SAVE
    all settings
    active pipeline may restart
```

---

## 32. Summary

The current DsRS41Tracker version is a dual-frontend RS41 processing system
built around a central MAIN process.

The GUI and TUI:

- use the same decoded data;
- receive the same settings state;
- use the same APPLY/SAVE protocol;
- control the same BT and SondeHub services.

MAIN:

- exclusively manages the pipeline;
- ensures clean shutdown of process groups;
- restarts processing after a full save;
- automatically restarts only the SondeHub POSIX-pipe worker when SHARE or
  MOBILE changes;
- preserves the existing socket, token and frontend connection while replacing
  the POSIX-pipe worker;
- manages shared statistics and vector calculations;
- serves interactive services through its own abstract UNIX socket;
- always sends the effective settings state back to the frontends.

The SondeHub worker forwards only live, VALID telemetry with a complete
51-frame calibration, automatically reschedules listener position after a
successful upload, and jointly applies fixed/mobile intervals, movement
threshold and minimum retry interval.

The TUI 0.2.46 full-redraw mechanism restores the complete screen after popups
and processing-pipe closure.
