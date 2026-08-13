# esp32-display

A wireless second display for macOS, built from a $10 ESP32-C6 board with a
1.47" LCD. The Mac captures screen content with ScreenCaptureKit, streams raw
RGB565 pixels over WiFi, and the board pushes them to its ST7789 panel over
80MHz SPI with DMA. No compression, no video codecs — at 172×320 the whole
frame is 110KB, so the pipeline stays simple and the latency stays low.

Hardware: either of the two Waveshare 1.47" ESP32-C6 boards — the
[ESP32-C6-LCD-1.47](https://spotpear.com/shop/ESP32-C6-1.47-inch-LCD-Display-Screen-LVGL-SD-WIFI6-ST7789.html)
(ST7789 panel) or the
[ESP32-C6-Touch-LCD-1.47](https://www.waveshare.com/wiki/ESP32-C6-Touch-LCD-1.47)
(JD9853 panel, capacitive touch, IMU). Both are ESP32-C6, WiFi 6, 8MB flash,
1.47" 172×320 IPS. One firmware binary runs on both — see
[Supported boards](#supported-boards).

## What it does

Plug the board into USB power anywhere on your network. It joins WiFi,
announces itself over mDNS, and the Mac finds it automatically — no IP or
hostname to configure. Plug in a second board and it gets its own stream.

The native ESPDisplaySender manager lists discovered and previously known
panels with online state, IP address, RSSI, displayed frame rate, firmware
version, and diagnostics. Select a panel to choose its ScreenCaptureKit source,
pause or resume it, set brightness or orientation, give it something to show
while idle, identify it, restart it, or configure WiFi over USB. Device names
are static until you click the selected panel's title to enter explicit rename
mode. Anything you choose for a panel — its source, its idle text, its name,
its USB port — persists in
`~/Library/Application Support/ESPDisplaySender/panels.json`, so powered-off
panels remain visible as offline with their settings intact. Only your choices
are stored there; live telemetry is not, so a fresh launch shows a restored
panel as offline rather than replaying last week's RSSI as if it were current.

When something goes wrong the window says so. A denied Screen Recording
permission, an unreadable config file, or a panel that stopped answering each
raise a banner or a per-panel notice instead of only reaching
`/tmp/espdisplaysender.log`.

**Settings** (⌘,) exposes frame rate, packet pacing, and the identify duration,
stored in `settings.json` beside `panels.json`. The matching command-line flags
still work and override the stored values for that run only, so a one-off
`--fps 20` never quietly rewrites what the UI shows.

The app starts invisibly at login and owns no persistent menu bar item. Opening
it from Finder shows the manager and a Dock icon; closing the manager hides the
Dock icon again without stopping capture. macOS may still show its system
screen-sharing indicator while ScreenCaptureKit is active.

Each panel shows whatever you point it at:

- **A tiny extended desktop** — create a virtual display with
  [BetterDisplay](https://betterdisplay.dev) (free tier) and drag windows
  onto it.
- **A mirror of your screen** — use macOS's own "Entire Screen" mirroring;
  the sender follows the mirror relationship automatically.
- **A single window or app** — pick one in macOS's screen-sharing picker
  (Control Center), no configuration files or flags.

Use **Choose Source** in the manager to assign macOS's native display, window,
or application picker to the selected panel. That choice is remembered, so it
still applies after a relaunch; **Use Automatic** puts the panel back to
automatic selection. For unattended defaults on a panel you have never picked a
source for, you can still assign sources by device name in
`~/.config/espdisplay/devices.json` — one board mirrors a display while another
follows a specific app window:

```json
{
  "espdisplay-9050": { "display": "Tiny Monitor" },
  "espdisplay-abcd": { "window": "Music" }
}
```

Devices with no entry use automatic selection. A source chosen in the manager
wins over `devices.json`, since it is the more recent and more deliberate
instruction. Names default to `espdisplay-XXXX` (from the board's MAC); click
the selected panel's title to rename it over USB.

The panel follows macOS. Rotate the virtual display and the panel rotates
with it, re-laying-out in landscape or portrait. Change mirroring modes,
resize, close the window you were streaming — the sender notices within a
couple of seconds and reattaches on its own.

The board itself has three physical controls on its BOOT button, layered by
how long it is held: a short press toggles backlight brightness between high
and low, a long press (~0.6s) flips the image 180° for upside-down mounting,
and holding through a third threshold (~3s) turns the display off - the same
standing instruction the manager's Power switch and `CFGPOWER` set. All three
are saved to the board's flash, so they survive reboots and firmware reflashes
— set the orientation once for how the board is mounted and forget it. (A full
flash erase does reset them.) The manager's brightness slider covers the full
range in between; the button's toggle is the two ends of it. The long press and
the extra-long press compound rather than replace each other: holding past 3s
also fires the 180° flip on the way, since the flip already fires the instant
it is reached rather than waiting to see how long the button stays down.

A **Power** switch in the manager turns the panel's display off without
unplugging it — a standing instruction, independent of the automatic dimming
below, that persists across a reboot until switched back on. It is not the
same as `ESLP`/`EWAK`: those follow this Mac's own display sleep and clear the
moment a frame is drawn or the Mac wakes, while Power stays off until someone
turns it back on, on this Mac or another one entirely. The same switch is
reachable over USB with `CFGPOWER 0|1` or from the BOOT button's extra-long
press, and it applies to every board — there is no hardware gating, since
every panel here already has a backlight or an AMOLED panel-brightness
command to turn dark.

Square panels can be mounted at any quarter turn, not only upside down. A
panel whose glass is square advertises quarter-turn rotation, and the
manager's orientation control becomes a 0°/90°/180°/270° choice instead of the
180° toggle; the same rotation is reachable over USB with `CFGROT 0|1|2|3`,
and the BOOT long press still steps by 180° so it composes with a quarter turn
rather than erasing it. Rectangular panels deliberately keep only the 180°
flip — turning one of those 90° is what streaming it in landscape already
expresses, so the panel refuses quarter turns there rather than fighting the
sender about which way is up. Touch, where present, goes through the same
transform as the pixels, so gestures keep meaning the direction your finger
actually moved whichever way the panel is turned.

WiFi credentials live in the board's flash, not in the firmware — change
networks by plugging the board into the Mac over USB and choosing **Add…** or
**Edit…** beside the selected panel's saved WiFi network. The WiFi-only dialog
shows the current network and saves new credentials over serial. The
**USB device** setting under Connection defaults to automatic name matching;
choose a specific `cu.usbserial` or `cu.usbmodem` port there when more than one
device is connected or automatic matching cannot identify the panel. Manual
assignments persist with the known panel. No reflashing, and the recovery path
works even when the stored credentials are wrong. SSIDs with spaces, emoji, and
extended Unicode all work — everything crosses the wire base64-encoded.

## Supported boards

Two Waveshare boards share this form factor. They have the same MCU, the same
8MB flash, and the same 172×320 panel resolution — but not the same panel
controller or pin map:

|                     | ESP32-C6-LCD-1.47 | ESP32-C6-Touch-LCD-1.47      |
| ------------------- | ----------------- | ---------------------------- |
| Panel controller    | ST7789            | JD9853                       |
| SCLK / MOSI         | 7 / 6             | 1 / 2                        |
| CS / DC             | 14 / 15           | 14 / 15                      |
| RST / backlight     | 21 / 22           | 22 / 23                      |
| BOOT button         | GPIO9             | GPIO9 (see note)             |
| Addressable RGB LED | GPIO8             | none                         |
| Extras              | —                 | AXS5106L touch, QMI8658A IMU |

Because the resolution matches, nothing above the panel differs: the band
protocol, the buffers, the Mac app, and the advertised capabilities are
identical on both. Only the display half of the firmware is board-aware, so
**one binary serves both boards** and picks its pins and panel driver at boot.

Detection is an I2C scan of the shared bus on GPIO18/19. The Touch board's touch
controller and IMU answer there (0x63 and 0x6B); the non-touch board's bus is
silent. `firmware/libraries/espdisp_board/src/board_config.h` is the single
source of truth for the table above, and it is unit tested on the host.

An inconclusive probe resolves to the **Touch** board, which inverts this
project's historical default on purpose. The two possible misdetections are not
equally cheap:

- A Touch board mistaken for a non-touch one puts SPI clock and data on GPIO7 and
  GPIO6 and panel reset on GPIO21. On that board GPIO6 is the IMU's interrupt 2
  and GPIO21 is the touch controller's interrupt — both are chip _outputs_, so the
  ESP32 would be driving against two live drivers. It would also PWM GPIO22, which
  is that board's panel reset, and drive GPIO8, which has no LED and no known
  function there.
- A non-touch board mistaken for a Touch one writes the panel on GPIO1/GPIO2 and
  resets GPIO22 — pins of unknown function on that board, but none of them
  confirmed to be driven from the other end.

Only one of those directions is known to fight two chip outputs, so that is the
one the fallback avoids. If detection ever gets it wrong, `CFGBOARD
st7789|jd9853|auto` over USB forces the answer. Only an explicit override is
stored — an auto-detected verdict is deliberately not cached, so a single bad
probe cannot become permanent.

**Where the vendor documentation is wrong.** Waveshare's pinout table for the
Touch board lists the BOOT button on GPIO8 and omits GPIO9 entirely. It is
actually GPIO9, the same pin the non-touch board uses. Measured by holding both
candidates `INPUT_PULLUP` and watching which one moves: every press pulls GPIO9
low and GPIO8 never changes. Taking the table at its word shipped a firmware
whose short-press and long-press controls silently did nothing on this board, so
the board table now carries the measured value and a unit test pins it there.
What GPIO8 _is_ on the Touch board remains unknown — it reads high with a pull-up
and is not the button — which is why nothing drives it.

Features that depend on hardware the board does not have degrade rather than
break. The Touch board has no addressable LED, so the WiFi-signal colour
indicator is simply absent there and `CFGLED` reports an error instead of
silently doing nothing. **Identify** works on both: it pulses the backlight,
which is visible from across a room, and additionally turns the LED blue on
boards that have one. Because identify keeps working everywhere, the capability
bits the panel advertises are unchanged — the Mac app needs no modification and
older senders keep working.

The IMU is not used by this project; it is only read as part of the signal that
says which board this is.

Touch is read but not yet acted on. `firmware/libraries/espdisp_board` contains
the AXS5106L reader and the coordinate transform that puts a touch through the
same orientation and flip the pixels went through, and `firmware/display_test`
has an interactive mode that draws a marker where you touch so the transform can
be checked against a finger. The streaming firmware does not use touch yet.

**Battery reporting is 1.75C-only.** Of the supported boards, only the
ESP32-S3-Touch-AMOLED-1.75C has a power-management IC — an AXP2101 sharing the
touch I2C bus — so it is the only one with a battery to report. The two C6 boards
run straight off USB with no cell and no gauge, which makes this a per-board
capability rather than a firmware-wide one: the board table records the
controller, the firmware advertises `CAP_BATTERY` only after the chip actually
answers, and the Mac shows a battery row only for a panel advertising the bit. A
C6 shows no row rather than an empty or 0% one, and a 1.75C with a dead PMU is
treated the same way. The reader is a minimal five-register one in
`firmware/libraries/espdisp_board/src/board_power.h` rather than a vendored
XPowersLib; that file explains why, and marks what is still unverified for want
of hardware.

## Performance

The panel's SPI bus tops out around 41 fps for full-frame pushes, and the
pipeline reaches it: full-motion content streams at 25-38 fps depending on
WiFi conditions. For normal desktop content it does much better than that
suggests, because only changed regions go over the wire — the frame is tiled
into row bands and diffed against the last one sent. A mostly-static screen
with a clock or a scrolling log touches ~3-5% of bands per frame, roughly a
25× traffic reduction, with a full keyframe every 2 seconds to bound
staleness from any lost packets.

Send pacing tunes itself. The device reports its displayed-frame rate back
to the Mac once a second, and the sender hill-climbs its per-packet spacing
to maximize actually-delivered frames — so it finds the best operating point
for whatever your WiFi looks like today, and re-finds it when conditions
change.

## Resilience

Both ends assume the other will misbehave, because during development they
did. Everything below exists because the failure actually happened:

- **Device heartbeats** (1Hz, with delivery stats) let the Mac detect a
  rebooted or readdressed device and reconnect with fresh mDNS resolution —
  and if mDNS itself is down (multicast dies before unicast on weak links),
  it falls back to the device's last known IP.
- **A panel that stops answering parks its session.** After 30 seconds of
  silence the Mac stops capturing and sending for that panel and just keeps
  re-resolving it, resuming on the first reply. Before this, an unplugged panel
  cost a live capture stream and hundreds of thousands of send errors for as
  long as it stayed gone.
- **Display identity is anchored on the display UUID**, which survives the
  rotations, re-creations, and mirror-set changes that invalidate display
  IDs and NSScreen names. The UUID is cached to disk, so even a sender
  restart mid-mirror re-finds the display.
- **Discovery tolerates mDNS ghosts**: a renamed device leaves its old
  service name in caches until the TTL expires, resolving to nothing. Such
  a device is retired after a few attempts and retried later, rather than
  retrying forever.
- **Capture watchdogs** restart the stream when macOS kills it silently
  (display reconfiguration and sleep/wake both do this without firing the
  delegate error).
- **The firmware heals its own radio**: a WiFi association that has rotted
  (still connected, delivering nothing) is re-associated, then escalated to
  a clean reboot — which the Mac rides through automatically.
- **A task watchdog** panics and reboots the firmware on any unforeseen
  hang; serial writes never block (a stalled USB host once froze the whole
  loop); DMA completions that go missing are reclaimed instead of wedging
  the pipeline.
- **The reassembler tolerates real WiFi behavior**: late retransmitted
  packets, duplicates, reordering, and sender restarts all resync instead
  of thrashing. This logic is hardware-free and unit tested on the host
  (`firmware/test/run_tests.sh`), with matching Swift tests (`swift test`)
  sharing wire-format test vectors so both ends provably agree.

## How it works

```
[macOS display / window / picker selection]
   → ScreenCaptureKit capture, hardware-scaled to 172×320
   → BGRA → RGB565 (big-endian, panel byte order — the ESP32 never touches a pixel)
   → per-band diff against previous frame
   → dirty bands over UDP, paced, ~1.3KB per packet
   → ESP32-C6: reassemble into persistent framebuffer
   → coalesce dirty bands into strips, DMA to ST7789 at 80MHz SPI
```

Transport is UDP by design: a lost frame should be skipped, not replayed.
With band diffing, a lost band just stays stale until the next change or
keyframe touches it.

### Protocol (v2)

Each packet: `[frame_id u16][band_index u16][dirty_count u16][band payload]`,
little-endian, where bit 15 of `dirty_count` carries orientation. Bands are
orientation-native so they align to whole rows:

| Orientation       | Band          | Bands/frame | Packet size |
| ----------------- | ------------- | ----------- | ----------- |
| Portrait 172×320  | 4 rows × 344B | 80          | 1382B       |
| Landscape 320×172 | 2 rows × 640B | 86          | 1286B       |

### Tile streaming (square AMOLED panels)

The 466×466 AMOLED board advertises `CAP_TILE_STREAM` and speaks a
tile-based successor to the band protocol (`firmware/display_stream/
tile_protocol.h`, mirrored in `TileProtocol.swift`): the frame is a 30×30
grid of 16×16 tiles, only tiles that changed travel, and horizontally
adjacent dirty tiles merge into runs — one wire record and one panel draw
call each. Each run is encoded three ways — raw, RLE565, and BC1 (a fixed
4:1 lossy block codec, `bc1.h`/`BC1.swift`) — and the smallest wins,
subject to the quality setting in the app (Lossless only / Automatic /
Aggressive; Automatic keeps flat colors and gradients pixel-perfect and
compresses only textured content). Records pack greedily into 1472-byte
datagrams, because the panel's ceiling is datagrams per second, not bytes.

The win over bands is granularity: a small moving element dirties a few
512-byte tiles instead of full 932-byte rows, and photo or video content
BC1-compresses where RLE cannot. Measured against the same board on the
band protocol, light content went from ~29 fps at ~300 datagrams/s to
~35 fps at ~70 datagrams/s.

A panel advertising `CAP_ROUND_DISPLAY` gets one further saving that costs
nothing: its glass is round, so 181 of the 900 tiles lie entirely outside
the inscribed circle and are invisible forever. The sender never sends them
— not even on a keyframe, which covers 719 tiles rather than 900 — and
since the panel paints only what it is sent, a fifth of the QSPI paint time
goes with them (25.7 → 22.2 ms for a full frame). The mask is deliberately
conservative: a tile straddling the boundary is sent whole, because skipping
a tile that turns out to be visible would leave it permanently stale rather
than merely late. It was verified against the physical glass before being
switched on (`espdisp.py tile-test --round-mask` paints the skippable tiles
magenta and sends everything, so a wrong mask shows up as visible magenta
rather than as silence).

Tile packets claim bit 15 of the header's second field — the same bit
packed band packets use, and the two layouts are byte-ambiguous past it —
so a board advertises exactly ONE of `CAP_TILE_STREAM` /
`CAP_COMPRESSED_BANDS` and parses bit-15 packets as that one. The C6
boards keep packed bands byte-identically; classic unpacked band packets
(bit 15 clear) stay accepted everywhere, which is what keeps a tile panel
drivable by an older sender — slower, never wrong. Full design, budget
math, and measured numbers: `docs/tile-stream-plan.md`.

The device replies with a compatible 1Hz heartbeat (`EHB1` +
frame/drop/packet/heap counters) to whoever sent it packets last; the sender
emits a 2s `EPNG` keepalive so that address stays fresh through static screens.
Firmware 1.1 also sends versioned `EINF` telemetry every 2 seconds with firmware,
frame/control protocol versions, capabilities, stable hardware ID, uptime,
RSSI, brightness, orientation, and sleep state. Fixed-size `ECTL` commands and
`EACK` responses provide typed brightness (both a high/low toggle and an exact
1–255 level), flip, identify, and restart control without changing the frame or
legacy heartbeat formats. `ETXT` pushes up to four short ASCII lines for the
panel to show while idle.

`EBAT` reports the battery every 10 seconds, on the boards that have one: a
fixed 12-byte packet carrying whether a cell is attached, whether external USB
power is present, a 0–100 percentage (`0xFF` when the gauge has no opinion yet),
a charge state, and the cell voltage in millivolts. Charge state is one enum
rather than separate charging and discharging bits, so the packet cannot express
a contradictory state. It is its own packet rather than extra `EINF` fields
because a sender length-checks `EINF` exactly: appending fields there would make
an already-shipped sender reject _every_ `EINF` and lose the telemetry it
already had, while an unrecognised packet type is simply dropped. Advertised as
`CAP_BATTERY`, and only the ESP32-S3-Touch-AMOLED-1.75C ever sets it.

The Mac gates every control on the capability bits the panel advertises, so a
board running older firmware simply does not offer the newer controls rather
than sending commands it will reject. That is also why the continuous
brightness level arrived as a new capability bit instead of a protocol version
bump: a bump would have made every un-reflashed panel refuse _all_ controls.

The device name is also sent as the DHCP hostname (option 12), so the router
lists the board by name rather than `esp32c6-XXXXXX`, and — on routers that
register DHCP leases in their DNS — the plain name resolves on the LAN:

```
$ dig +short @192.168.1.1 blakes-teeny-screen
192.168.1.120
```

Note the hostname is latched when the WiFi interface enters station mode, so
the firmware sets it before `WiFi.mode()`; setting it later affects only
mDNS, not DHCP.

Devices advertise `_espdisp._udp` over mDNS with their name in a TXT record,
so the Mac browses for panels instead of resolving a fixed hostname, and
connects to the Bonjour endpoint directly (which re-resolves itself on every
reconnect — address changes need no bookkeeping).

The TXT records carry `name`, `res=WxH`, `fw` (the firmware version), `proto`
(the frame protocol version), `caps` (the capability bits as eight hex digits),
and `chip` — the chip this binary was built for, `esp32c6` or `esp32s3`, taken
from the IDF's own `CONFIG_IDF_TARGET`. `chip` is what tells a reader which
image out of a firmware bundle belongs to this panel. It is advertised rather
than worked out from `res`, because 172x320 meaning a C6 and 466x466 meaning an
S3 is a coincidence of the boards that exist today, and the firmware is
resolution-parametric precisely so that coincidence can end. A build that cannot
name its chip says `chip=unknown`, which means "could not tell" and not "some
other chip" — a reader treats it as missing information rather than as a
mismatch. This is a different record from the `board=` one discussed under OTA
below: that one belongs to the separate `_arduino._tcp` service and is published
by the core's own code. They spell the chip the same way on purpose; they do not
come from the same place.

The Mac app reads these records during discovery, which it did not always do —
it kept the service name and the endpoint and dropped the rest, so every panel
was streamed as though it were a 172×320 one. It now streams each panel at the
resolution that panel advertises, and falls back to 172×320 when `res` is
missing or is a size the band protocol cannot carry (a row has to fit one
packet, and the band count has to stay within the firmware's reassembly
bitmap). That includes region mode: the rectangle the presets frame, and the
size the 1×/2×/3× buttons describe, come from the panel's advertised geometry,
so a square panel is framed square rather than being handed a 172:320 crop
stretched to fit. `chip` is kept against the panel so a firmware bundle's images
can be matched to it. Reading TXT records at all requires browsing with
`bonjourWithTXTRecord`: Network.framework does not query for them by default,
so with a plain Bonjour browse every result's metadata is empty however much
the panel advertises.

Over USB serial (115200), the firmware also accepts configuration commands:
`CFGWIFI <base64 ssid> <base64 password>` saves credentials to NVS and
reboots, and `CFGWIFI <base64 ssid>` (password argument omitted) keeps the
password currently in use; `CFGNAME <base64 name>` sets the device name;
`CFGSHOW` reports the current network, name, IP, signal strength, the saved
orientation/brightness/power state, the detected board, the battery, and
whether OTA is enabled; `CFGFLIP 0|1` sets the 180° flip without the button;
`CFGROT 0|1|2|3` sets the quarter-turn rotation on square panels; `CFGPOWER
0|1` turns the display off or on, saved and applied immediately — the same
switch the manager's Power toggle uses; `CFGLED <r> <g> <b>` shows a literal
LED color for 10s on boards that have an addressable LED and reports an error
on those that do not; `CFGBOARD st7789|jd9853|auto` overrides board
auto-detection and reboots; `CFGOTAPW <base64 password>` sets the OTA password
(and `CFGOTAPW clear` removes it, turning OTA off again).

A panel that has an OTA password advertises `CAP_OTA` and a second mDNS service,
`_arduino._tcp`, which is what the OTA pusher browses for. Without a password it
advertises neither and does not listen — the bit means "a firmware push would be
accepted right now", not "this build has OTA code in it".

## Repo layout

| Path                                 | What                                                                                                                                      |
| ------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------- |
| `firmware/display_stream/`           | The real firmware: WiFi, mDNS, UDP receiver, esp_lcd DMA, button and remote controls                                                      |
| `firmware/display_test/`             | Panel bring-up test on either board (colors, offsets, orientation, SPI timing) plus interactive touch mapping                             |
| `firmware/board_probe/`              | I2C-scan diagnostic reporting which board variant you have                                                                                |
| `firmware/libraries/espdisp_board/`  | Board variant table, runtime detection, shared panel bring-up, touch reader, touch coordinate transform, AXP2101 battery reader           |
| `firmware/libraries/esp_lcd_jd9853/` | Vendored Apache-2.0 JD9853 esp_lcd driver (see its README for provenance)                                                                 |
| `mac/ESPDisplaySender/`              | Native manager app plus SwiftPM command-line workflows                                                                                    |
| `firmware/test/`                     | Host-side unit tests for the protocol, control-queue, board-table, and panel-state logic (`run_tests.sh`)                                 |
| `mac/ESPDisplaySender/Tests/`        | Swift tests for the sender's protocol and application logic (`swift test`)                                                                |
| `tools/espdisp.py`                   | Compile, flash over USB, push over WiFi, bundle a build, and configure from one command: holds the board table, refuses to guess the chip |
| `tools/test_espdisp.py`              | Tests for the CLI's decisions: chip and OTA-target refusals, password bounds, encodings, the bundle format (stdlib only, no framework)    |
| `tools/read_serial.py`               | Serial monitor with optional hard-reset (native USB-Serial/JTAG)                                                                          |
| `tools/sweep.py`                     | Pacing parameter sweep, measuring displayed fps from device stats                                                                         |
| `docs/`                              | Original project plan                                                                                                                     |

## Getting started

Firmware (needs [arduino-cli](https://arduino.github.io/arduino-cli/) and the
esp32 core with the espressif board manager URL):

```sh
cd firmware/display_stream
cp wifi_config.h.example wifi_config.h   # fill in your 2.4GHz network
arduino-cli compile -b "esp32:esp32:esp32c6:CDCOnBoot=cdc,FlashSize=8M" --libraries ../libraries .
arduino-cli upload  -b "esp32:esp32:esp32c6:CDCOnBoot=cdc,FlashSize=8M" -p /dev/cu.usbmodem* .
```

For the **ESP32-S3-Touch-AMOLED-1.75C** (466x466 QSPI AMOLED):

```sh
cd firmware/display_stream
cp wifi_config.h.example wifi_config.h   # fill in your 2.4GHz network
arduino-cli compile -b "esp32:esp32:esp32s3:CDCOnBoot=cdc,FlashSize=16M,PSRAM=opi" --libraries ../libraries .
arduino-cli upload  -b "esp32:esp32:esp32s3:CDCOnBoot=cdc,FlashSize=16M,PSRAM=opi" -p /dev/cu.usbmodem* .
```

The S3 board has 16MB flash and 8MB octal PSRAM (stacked on the ESP32-S3R8
module). `PSRAM=opi` enables the octal PSRAM interface, which is required
because the 466x466 frame buffers (~434KB each) do not fit internal SRAM and
are allocated from PSRAM instead.

`--libraries ../libraries` puts the in-repo libraries on the search path: the
board table and shared panel bring-up, plus the vendored JD9853 and CO5300
esp_lcd drivers (the Arduino core ships an ST7789 driver but neither of
these). The same flag applies to `display_test` and `board_probe`. It is a
compile-only flag; `upload` reuses the cached build. The C6 binary is
board-independent (one build runs on either 1.47" board); the S3 binary
serves only its own panel.

`tools/espdisp.py` runs exactly those commands for you, so the two FQBNs, the
`--libraries` flag, and the port glob stay out of your shell history:

```sh
tools/espdisp.py list                  # ports it can see, and the chip on each
tools/espdisp.py compile --board c6    # or --board s3
tools/espdisp.py flash                 # detect the chip, build, upload
tools/espdisp.py flash --board s3      # skip detection and build that target
tools/espdisp.py set-password          # store an OTA password (prompts for it)
tools/espdisp.py ota panel.local --board c6   # build, then push over WiFi
tools/espdisp.py bundle                # build both boards into one portable file
tools/espdisp.py bundle-info FILE      # verify a bundle and print what is in it
tools/espdisp.py config CFGSHOW        # send one CFG* line, print the reply
```

`tools/test_espdisp.py` covers what the tool decides — the chip and target
refusals, the password bounds, the base64 encoding, the espota command line, the
firmware bundle's byte layout and every way it can refuse a bundle — and
prints `OK: N checks passed` like `firmware/test/run_tests.sh`. Standard library
only, no test framework, run it by path.

`compile`, `flash`, `ota`, and `bundle` echo the `Sketch uses N bytes (P%)` line
at the end, so app-partition headroom is visible without hunting through
scrollback.

`flash` refuses rather than guesses when it cannot tell which chip is attached.
Both boards are native USB CDC at VID 0x303A PID 0x1001, so neither the port name
nor the VID/PID distinguishes a C6 from the S3. It asks arduino-cli first, then
the esptool bundled with the core, and if neither answers it stops and tells you
to pass `--board c6|s3`. More than one candidate port is likewise a refusal, not a
coin flip: pass `--port`.

That refusal buys a clear message rather than a rescue: the core's upload recipe
passes `--chip {build.mcu}` to esptool (`platform.txt` line 346), and esptool
refuses to talk to a chip that is not the one it was told to expect. So a
wrong-target USB flash ends in a refusal from one tool or the other — the point of
stopping early is that you find out before a full compile and with a message that
names the fix.

The script is standard-library Python 3 only: unlike the other `tools/` scripts
it does not need pyserial. The explicit `arduino-cli` commands above remain the
fallback if it ever misbehaves, and they document what it does.

### Updating over WiFi

Once per panel, over USB, give it an OTA password. Nothing listens until you do:

```sh
tools/espdisp.py set-password          # prompts, does not echo, and encodes for you
```

The panel takes the password base64-encoded (so it can contain any character a
space-delimited line would eat) while the pusher takes it as characters, and
`set-password` owns that conversion because doing it by hand has a trap in it: the
obvious `echo 'pw' | base64` appends a newline and stores a password one byte
longer than the one you typed, which then fails every push with an auth error and
no hint why. The equivalent by hand, if you want it, needs `printf`:

```sh
tools/espdisp.py config CFGOTAPW $(printf %s 'a-real-password' | base64)
```

The panel refuses a password below 8 bytes or above 64, and refuses one containing
a `0x00` byte — that last one would be stored truncated, so the length check would
stop describing the secret. `set-password` applies the same bounds locally, so a
password the panel would reject is refused before the round trip.

The panel reboots, advertises `_arduino._tcp` alongside `_espdisp._udp`, and from
then on takes pushes over the LAN:

```sh
export ESPDISP_OTA_PASSWORD='a-real-password'
tools/espdisp.py ota panel.local --board c6
```

`--board` is required here: over the network there is no chip to probe, so the tool
asks rather than assumes. It then checks the answer where it can. `arduino-cli`
already runs an mDNS discovery that browses `_arduino._tcp` — the service the panel
registers and `espota` pushes to — and the panel publishes `board=esp32c6` or
`board=esp32s3` in its TXT record, so a `--board` that contradicts the panel is
refused before the compile starts. A panel discovery cannot find is a note rather
than a refusal: mDNS not answering says nothing about the chip, and pushing to a
panel on another subnet has to keep working. `--discovery-timeout 0` skips the
check outright, and so does any negative value, since the check runs only for a
positive timeout: that is the override for this guard, and past it the panel
itself is the only thing left that will refuse a wrong-chip image.

A wrong-target push that does get through is refused by the panel, not fatal to it:
the ESP image header carries a `chip_id` (0x0D for the C6, 0x09 for the S3)
and `esp_ota_set_boot_partition` validates it through `esp_image_verify` before the
boot slot moves, so the image lands in the inactive slot, fails validation, and the
panel carries on running the firmware it booted with `bad image` on the glass. The
cost of getting `--board` wrong is a wasted compile and transfer. This chain was
read out of `Updater.cpp`, `esp_ota_ops.c` and `bootloader_common_loader.c`;
**UNVERIFIED** by an actual mismatched push, since no board is attached.

The password comes from `--password`, else `$ESPDISP_OTA_PASSWORD`, else a prompt;
it is never echoed, though the core's `espota.py` takes it as an argument, so it is
briefly visible in `ps` on a shared machine.

The panel shows a progress bar on the glass while it writes, then reboots itself
onto the new firmware. `tools/espdisp.py set-password --clear` disables OTA again.

**USB stays the recovery route**, and always works: OTA cannot replace the
bootloader or the partition table, and a panel that will not join WiFi cannot be
reached over WiFi. `tools/espdisp.py flash` is the way back from anything.

Mac app — the set-and-forget way:

```sh
mac/make-app.sh                 # builds ~/Applications/ESPDisplaySender.app
mac/install-launch-agent.sh     # starts hidden at login; restarts abnormal exits
open ~/Applications/ESPDisplaySender.app
```

`make-app.sh` builds the checked-in Xcode project and shared
`ESPDisplaySender App` scheme. The project uses automatic Apple Development
signing for the configured personal team, preserving its designated requirement
across rebuilds so macOS can retain Screen Recording and Local Network grants.
Xcode must be signed into that Apple Account and have an Apple Development
certificate before running the script on a new Mac.

Grant Local Network and Screen Recording when macOS asks. Logs land in
`/tmp/espdisplaysender.log`. A foreground launch opens the manager; closing its
window leaves streaming active in accessory mode. **Quit ESPDisplaySender**
stops it cleanly, and the LaunchAgent does not restart a clean exit until the
next login or foreground launch.

Leaving the USB WiFi password field blank keeps the password already saved on
the device. Joining a genuinely open network is an explicit checkbox, so a
blank field cannot silently replace a working password with an empty one.

The project remains usable directly from Xcode or SwiftPM:

```sh
cd mac/ESPDisplaySender
xcodebuild -project ESPDisplaySender.xcodeproj \
  -scheme "ESPDisplaySender App" -configuration Debug \
  -allowProvisioningUpdates build
swift test
swift build
./.build/debug/ESPDisplaySender                  # manager plus automatic capture
./.build/debug/ESPDisplaySender --background     # hidden background mode
./.build/debug/ESPDisplaySender --list-displays  # see what's capturable
./.build/debug/ESPDisplaySender --configure      # USB WiFi setup dialog
./.build/debug/ESPDisplaySender --help           # all options
```

For a deterministic SwiftUI preview, open `ManagerWindow.swift` in Xcode and
choose **Editor → Canvas**. The `Display Manager` preview uses sample online and
offline panels and does not read Keychain, probe USB, discover devices, or start
capture.

For the extended-desktop use case, create a virtual display in BetterDisplay
sized to a multiple of 172×320 (for example, 688×1280). The sender finds it by
name (default `Tiny Monitor`), learns its UUID, and tracks it from then on.

### Firmware bundles

`ota` pushes from the machine that compiled the firmware. A bundle is for the
other case: build here, update from there.

```sh
tools/espdisp.py bundle                        # both boards -> ./espdisp-firmware-1.2.0.espdispfw
tools/espdisp.py bundle --board c6 --output ~/fw.espdispfw
tools/espdisp.py bundle-info ~/fw.espdispfw    # check a file before handing it over
```

`bundle` compiles each board and writes one self-contained `.espdispfw` file
holding everything a board needs plus a manifest. Nothing is pushed and no
panel is contacted. The file is portable on purpose — it can be emailed, dropped in
a share, or carried on a stick to a Mac that has never seen this repo and has no
`arduino-cli`, where the app opens the file the user picks and pushes it itself.
That is why it is one file rather than a directory of images.

Per board it carries four payloads: the application image, which is what an
over-the-air update needs because it lands in an app slot, and the three things a
board that has never been flashed needs written to fixed flash addresses before
that image will boot at all — the second-stage bootloader, the partition table, and
`boot_app0.bin`, which initialises the OTA data so the bootloader starts the app
rather than an empty slot. The first two come out of the compile; `boot_app0.bin`
is the core's own copy, the same file `arduino-cli` writes when it uploads over USB.

Each payload's flash address travels in the file rather than being a constant in
whatever writes it. That matters because the address is per-chip data: `boards.txt`
puts the bootloader at `0x0` for both boards here and at `0x1000` on a classic
ESP32, so a hardcoded address would be wrong for some board later — and wrong
silently, because the flash would accept the write and the chip would then fail to
boot. The partition table travels beside the app for the same reason: it is the
table that decides the app lives at `0x10000`, so the two cannot drift apart.

The whole-flash `<sketch>.ino.merged.bin` is deliberately **not** carried. It is
padded to the full flash size — 8 MB for the C6 and 16 MB for the S3 — so a
two-board bundle would grow from about 2.2 MB to roughly 24 MB, almost all of it
padding, where the individual parts cost about 31 KB per board. It also describes a
whole-flash write, which would erase NVS, and NVS is where a panel's WiFi
credentials and its name live.

The manifest carries the firmware version, an ISO 8601 UTC build timestamp, the
commit it was built from and whether that tree was dirty, the tool that wrote it,
and for every image the board key, the chip token (`esp32c6` or `esp32s3`), the
FQBN it was compiled with, its size, its SHA-256, the flash address the application
image is written to, and the same details for each of its flash parts.
`bundle-info` prints all of that, including every part and the address it goes to,
and refuses the file if anything does not add up: bad magic, a manifest that
does not parse, offsets that are not contiguous, a payload running past the end of
the file, the same chip listed twice, a bundle missing one of the three parts a new
board needs, two payloads claiming one flash address, or a payload whose hash is not
the one the manifest claims. Payloads are stored raw, so every hash `bundle-info`
prints is the same number `shasum -a 256` gives for the file the compile produced.

Files written before this — generation 1, magic `ESPDISPFW1` — carried the
application images and nothing else. Both the CLI and the app still read one: it
cannot bring up a blank board, and it is a perfectly good over-the-air payload that
whoever holds it may have no way to rebuild. `bundle-info` says which of the two it
is looking at and says plainly when a file cannot set up a new board. An **older**
app meeting a generation-2 file refuses it and names the app as the side that is
behind, which is the honest answer: the generation was bumped rather than extended
because the checks that catch a truncated or concatenated file are exactly the
checks an extra payload would have had to be smuggled past.

The version is read out of the sketch (`FW_VERSION` in
`firmware/display_stream/display_stream.ino`) rather than passed in as a flag, so
the manifest cannot claim a version its images do not have — the app compares that
number against what a panel reports to decide whether to offer an update.

`--board` narrows the file to one image, and the summary says so plainly: a bundle
with only a C6 image has nothing to offer an S3 panel. Bundles are gitignored
(`*.espdispfw`), and the write is atomic, so an interrupted build leaves either the
previous file or no file rather than a half-written one.

**The app ships one.** `mac/make-app.sh` builds a bundle before it builds the app
and puts it in the app's Resources, which is what lets **Add Display over USB…**
work without a terminal — a `.espdispfw` can only come from `espdisp.py bundle`, so
an app that asked for a file would be asking you to open one. It is reused if it is
already there, since compiling both boards takes minutes:

```sh
mac/make-app.sh                                # reuse the bundle if present
ESPDISP_REBUILD_FIRMWARE=1 mac/make-app.sh     # rebuild it from the sketch
ESPDISP_SKIP_FIRMWARE=1 mac/make-app.sh        # ship without one
```

Two things follow from that, and neither is hidden: the `.app` grows by the
bundle's size (2.3MB for both boards today), and the firmware inside it is fixed
when the app is packaged. A board flashed from a six-month-old app gets six-month-old
firmware and can be brought up to date over the air immediately afterwards. To
refresh what the app carries, rebuild it with `ESPDISP_REBUILD_FIRMWARE=1`.

### Adding a board over USB

A board that has never been on your network cannot be discovered, so it cannot
appear in the sidebar, so nothing that starts with "select a display" can reach it.
The **+** at the top of the Displays list starts from the cable instead, and it is
the one control in the window that works with an empty sidebar (⌘N, or the button on
the empty detail pane, do the same thing).

Pick the board's USB serial device and press **Flash and Add**. What happens then:

1. The app asks the port whether it already speaks this firmware's config
   protocol. A board that answers is offered **Set Up WiFi only** — it already
   works, and what it is missing is credentials, so it is not re-flashed by
   default. Flashing it is still one radio button away.
2. For a blank board, the chip is read off it with esptool. You are never asked
   whether it is a C6 or an S3.
3. Everything a blank board needs is written in one esptool run — bootloader,
   partition table, boot_app0 and the application image, at the addresses the
   bundle carries. The partition table travels with the app deliberately: it is
   the table that says where the app lives, so writing one without the other puts
   an image where the old table thinks something else is.
4. The WiFi credentials go down the same cable, and the board saves them and
   restarts. A name is optional; if you give one it is sent first, so the last
   restart is the one that joins the network.
5. The board joins, announces `_espdisp._udp`, and arrives in the sidebar through
   the same discovery every other panel arrives through. Nothing is added to the
   list until it really is on the network.

**This path needs the esp32 core installed** (`arduino-cli core install
esp32:esp32`), because the app runs the esptool that comes with it rather than
reimplementing the serial bootloader protocol. That is a real dependency the
over-the-air path does not have, and the sheet says so by name when the tool is
missing, along with `tools/espdisp.py flash` as the route that works meanwhile. The
credentials are stored in your login Keychain, as they are everywhere else in the
app, and the port you picked is used and forgotten: `/dev/cu.usbmodem*` names are
not stable across a reset, so the app re-enumerates after each restart rather than
remembering one.

Erasing the whole chip first is offered and off by default. It takes NVS with it,
which is where a board keeps its network and its name.

### Updating a panel from the app

Select the panel in the manager window and choose **Update Firmware…** at the
bottom of the detail pane. Pick a `.espdispfw` file, check what the sheet says it
would do, type the OTA password, and confirm. No `arduino-cli` and no Python are
involved: the app speaks the `espota` protocol itself.

The file is one written by `tools/espdisp.py bundle` (see
[Firmware bundles](#firmware-bundles)), and it does not have to have been built on
the Mac doing the pushing — that is the point of it being one portable file. The
sheet reads the manifest and shows the version, when it was built, the commit it
came from and whether that tree was dirty, and the size of the image for this
panel's chip.

Then it says what pushing it would do, and the awkward answers are separate
answers rather than one refusal. The bundle can be newer (an update), the same
version (a reinstall, which is a reasonable way to recover a panel that is
misbehaving), or **older** — a downgrade, which is offered because going back after
a bad release is a real thing to want, but never labelled as an update. If either
version is not a dotted number the sheet says which way round they go cannot be
worked out rather than guessing. If the panel named a chip this bundle has no image
for, that is the one case that is simply the wrong file and it is refused. If the
panel did not name its chip at all — firmware older than the `chip` TXT record, or
a build that could not name its own — the push is still offered, with the image
chosen by hand and a warning saying so, for the same reason `--board` has an
override on the command line: not knowing is not the same as being wrong, and the
panel validates the image header's `chip_id` before it moves the boot slot, so the
wrong choice costs a transfer rather than the panel.

The password is the one set with `tools/espdisp.py set-password`. **Update
Firmware…** is greyed out until a panel advertises that OTA is listening, and the
tooltip says so and names that command. Ticking _Remember this password_ keeps it
in this Mac's Keychain, filed under the panel's hardware ID rather than its name so
renaming a panel does not lose it; unticking it forgets it. It is never written to
the app's settings file or its saved-panel records.

One thing to expect the first time: the panel connects **back** to the app to
collect the image, rather than the app sending it. That is how `espota` works — the
invitation on port 3232 carries a port for the Mac to be dialled back on — so the
app opens a short-lived listening port for the transfer. macOS may therefore put up
a firewall prompt for incoming connections; if the push sits at "waiting for the
panel to connect back", that is the thing to check. **UNVERIFIED**: no ESP32 board
is attached to the machine this was written on, so no panel has ever dialled back
and no prompt has been observed either way. For the same reason, no push has been
performed against real hardware — what is tested is the protocol arithmetic against
python3's `hashlib` and the whole exchange against a fake panel over loopback.

**USB stays the recovery route.** Everything in
[Updating over WiFi](#updating-over-wifi) about that applies here too: OTA cannot
replace the bootloader or the partition table, a panel that will not join WiFi
cannot be reached over WiFi, and `tools/espdisp.py flash` is the way back.

### Firmware update status

The firmware accepts a WiFi push (see [Updating over WiFi](#updating-over-wifi)),
on the LAN, with a password. This section is about what that does and does not
guarantee, because "it has OTA" covers a wide range.

**No partition table change was needed.** An earlier version of this section said
OTA required a custom 8MB dual-partition layout. That was wrong:
`tools/partitions/default.csv` in the esp32 core — which both targets already use
— has `otadata` at 0xe000 plus two 0x140000 app slots at 0x10000 and 0x150000.
The firmware has always been installed into an OTA-capable layout; nothing had to
move, and NVS (`0x9000`, `0x5000`) is untouched, so saved WiFi credentials, name,
orientation, and brightness all survive an update.

What this implementation provides:

- Transfer over the LAN, no cloud and no infrastructure, using `ArduinoOTA` on
  the panel and the core's `espota.py` on the Mac.
- Authentication. A challenge/response over PBKDF2-HMAC-SHA256; the panel stores
  only `SHA256(password)`, never the password. With no password set it does not
  listen and does not advertise `CAP_OTA`, so a panel is never remotely writable
  by accident — which is the state every panel ships in.
- An integrity check on the image. The pusher sends its MD5 and the `Update`
  library refuses to switch the boot slot unless what landed matches, so a
  truncated or mangled transfer never becomes the firmware that boots.
- A target check on the image, from the bootloader rather than from this project.
  `Update.end()` calls `esp_ota_set_boot_partition`, which runs `esp_image_verify`
  first, and that compares the image header's `chip_id` against the running chip
  (`bootloader_common_check_chip_validity`). An S3 image pushed to a C6 is
  therefore refused at exactly the same point a corrupt one is.
- Writes to the _inactive_ app slot. A failed or rejected push — bad password,
  lost transfer, wrong chip, failed MD5 — leaves the panel running exactly the
  firmware it booted; the failure reason appears on the glass.

What remains open, and would each be a real piece of work:

- **Image signing.** The core supports signature verification behind
  `UPDATE_SIGN` (`ArduinoOTA.setSignature()`), which needs a key pair and a
  signing step in the build. Not enabled: today the password is the only thing
  establishing that a push is legitimate.
- **Boot health validation and automatic rollback.** ESP-IDF can mark a new app
  provisional and roll back if it does not confirm itself, but that needs the
  rollback bootloader option and an explicit `esp_ota_mark_app_valid` once the
  panel decides it is healthy. Without it, firmware that transfers correctly but
  then crashes on boot leaves the task watchdog rebooting it, and USB is the fix.

**UNVERIFIED:** no push has been performed on hardware, successful or otherwise.
Every fact above about the protocol, the password handling, and the integrity and
target checks was read out of the core's `ArduinoOTA.cpp`, `Updater.cpp` and
`espota.py`, and out of ESP-IDF's `esp_ota_ops.c`, `esp_image_format.c` and
`bootloader_common_loader.c`; what has actually been exercised here is that both
targets compile, that the pusher builds the right command line, and that it fails
cleanly against a host that does not answer.

Sizing, which is the real constraint on the C6: the OTA code costs ~45KB, taking
that build from 85% to **89% of the 1.31MB app slot (1167976 bytes, 142744
free)**. The S3 sits at 80%. That still fits with room, and both slots are the
same size so an update is no tighter than an install — but the headroom is
finite, and carrying both panel drivers plus the PMU reader in one binary is what
spends it. The escape hatch, if a later feature stops fitting, is
`PartitionScheme=min_spiffs` on the FQBN: 1.9MB app slots, still two of them,
with NVS in the same place so settings survive. It would have to be applied
everywhere the FQBN appears (here, and `tools/espdisp.py`), and it needs one USB
flash to take effect because OTA cannot rewrite the partition table.

The management datagrams remain unauthenticated and intended for a trusted local
network — a forged `ECTL` can still dim a panel or reboot it. OTA is the one path
that now requires a secret, because it is the one where the consequence is
someone else's code running on the board.

## Status lights

The panel itself tells you where the firmware is: dark gray means alive and
waiting for WiFi, dark teal means connected and waiting for a stream, and dark
red means the WiFi connect attempt timed out — fix it with **Add…**/**Edit…**
beside the panel's saved WiFi network, over USB.

Dimming follows the Mac, never the picture. Unchanging content — a photo, a
dashboard, a paused video — stays at full brightness indefinitely:

| Condition                                   | Panel                         |
| ------------------------------------------- | ----------------------------- |
| Streaming, even perfectly static content    | Last frame, full brightness   |
| Mac's displays sleep, or screensaver        | Backlight off (`ESLP`)        |
| Mac system sleep                            | Backlight off (`ESLP`)        |
| Mac wakes                                   | Restored immediately (`EWAK`) |
| Sender gone ~45s (quit, crashed, WiFi down) | Dimmed status card            |

The status card shows whatever lines you gave the panel under **When Idle**,
followed by how long ago they arrived, then device name, IP, and WiFi strength
— all in outlined text over the last frame, repositioning every 30 seconds to
avoid burn-in. It means "nothing is driving this panel", so it keys off the
sender's 2-second keepalive rather than frame arrivals — with dirty-band diffing
a still image sends no frame data for minutes, and treating that as idleness
made the panel dim itself during normal use.

Idle text is up to four lines of 28 printable ASCII characters, pushed over the
network and re-sent whenever the panel reconnects. The age line is there because
the board has no clock of any kind — no RTC, no SNTP, only `millis()` — so it
cannot know whether "Build: green" is current. Saying "as of 4m ago" is honest
about that; showing the line alone would not be. Non-ASCII input is refused at
both ends rather than substituted, because the panel's font is an ASCII bitmap
and a row of blank glyphs looks like a bug.

The panel also saves the pushed template to its own flash, not just its RAM,
so a device reboot shows the user's own card immediately rather than falling
back to the built-in one until the Mac happens to reconnect and push again.
The save is checked once a minute rather than on every push: a template
built from live tokens like `{uptime}` or `{rssi}` produces different text on
nearly every 2-second keepalive by design, so reacting to each push would
still wear the same flash cells down for exactly the templates most likely to
be in real use — a periodic check is what actually bounds it. The age line
reads as time-since-boot after a restart rather than claiming a stale
template just arrived, since there is no clock to say otherwise.

On the ESP32-C6-LCD-1.47, the RGB LED behind the display glows with live WiFi
signal quality, updated every 2 seconds. The ESP32-C6-Touch-LCD-1.47 has no
addressable LED, so this indicator is absent there — use the status card or
`CFGSHOW` for signal strength on that board.

| Color           | Meaning                                             |
| --------------- | --------------------------------------------------- |
| Green           | Strong signal (-55 dBm or better)                   |
| Yellow → orange | Fading signal (-55 to -90 dBm, continuous gradient) |
| Red             | Very weak signal, or not connected                  |
