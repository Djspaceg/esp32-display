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

The board itself has two physical controls on its BOOT button: a short press
toggles backlight brightness between high and low, a long press flips the image
180° for upside-down mounting. Both are saved to the board's flash, so they
survive reboots and firmware reflashes — set the orientation once for how the
board is mounted and forget it. (A full flash erase does reset them.) The
manager's brightness slider covers the full range in between; the button's
toggle is the two ends of it.

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
| BOOT button         | GPIO9             | GPIO8                        |
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

- A Touch board mistaken for a non-touch one drives GPIO8 as an LED output, and
  GPIO8 is that board's BOOT button, switched to ground — a pressed button then
  shorts a driven pad. It would also contend with the IMU and touch interrupt
  lines on GPIO6 and GPIO21.
- A non-touch board mistaken for a Touch one writes the panel on the wrong SPI
  pins. The screen stays dark. Nothing is stressed, and USB still answers.

A dark screen is diagnosable and recoverable; a shorted pad is not. If detection
ever gets it wrong, `CFGBOARD st7789|jd9853|auto` over USB forces the answer.
Only an explicit override is stored — an auto-detected verdict is deliberately
not cached, so a single bad probe cannot become permanent.

Features that depend on hardware the board does not have degrade rather than
break. The Touch board has no addressable LED, so the WiFi-signal colour
indicator is simply absent there and `CFGLED` reports an error instead of
silently doing nothing. **Identify** works on both: it pulses the backlight,
which is visible from across a room, and additionally turns the LED blue on
boards that have one. Because identify keeps working everywhere, the capability
bits the panel advertises are unchanged — the Mac app needs no modification and
older senders keep working.

Touch input and the IMU are not used by this project. They are only read as the
signal that says which board this is.

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

Over USB serial (115200), the firmware also accepts configuration commands:
`CFGWIFI <base64 ssid> <base64 password>` saves credentials to NVS and
reboots, and `CFGWIFI <base64 ssid>` (password argument omitted) keeps the
password currently in use; `CFGNAME <base64 name>` sets the device name;
`CFGSHOW` reports the current network, name, IP, signal strength, the saved
orientation/brightness, and the detected board; `CFGFLIP 0|1` sets the 180° flip
without the button; `CFGLED <r> <g> <b>` shows a literal LED color for 10s on
boards that have an addressable LED and reports an error on those that do not;
`CFGBOARD st7789|jd9853|auto` overrides board auto-detection and reboots.

## Repo layout

| Path                                 | What                                                                                                      |
| ------------------------------------ | --------------------------------------------------------------------------------------------------------- |
| `firmware/display_stream/`           | The real firmware: WiFi, mDNS, UDP receiver, esp_lcd DMA, button and remote controls                      |
| `firmware/display_test/`             | Panel bring-up test on either board (colors, offsets, orientation, SPI timing benchmark)                  |
| `firmware/board_probe/`              | I2C-scan diagnostic reporting which board variant you have                                                |
| `firmware/libraries/espdisp_board/`  | Board variant table, runtime detection, and the panel bring-up shared by both sketches                    |
| `firmware/libraries/esp_lcd_jd9853/` | Vendored Apache-2.0 JD9853 esp_lcd driver (see its README for provenance)                                 |
| `mac/ESPDisplaySender/`              | Native manager app plus SwiftPM command-line workflows                                                    |
| `firmware/test/`                     | Host-side unit tests for the protocol, control-queue, board-table, and panel-state logic (`run_tests.sh`) |
| `mac/ESPDisplaySender/Tests/`        | Swift tests for the sender's protocol and application logic (`swift test`)                                |
| `tools/read_serial.py`               | Serial monitor with optional hard-reset (native USB-Serial/JTAG)                                          |
| `tools/sweep.py`                     | Pacing parameter sweep, measuring displayed fps from device stats                                         |
| `docs/`                              | Original project plan                                                                                     |

## Getting started

Firmware (needs [arduino-cli](https://arduino.github.io/arduino-cli/) and the
esp32 core with the espressif board manager URL):

```sh
cd firmware/display_stream
cp wifi_config.h.example wifi_config.h   # fill in your 2.4GHz network
arduino-cli compile -b "esp32:esp32:esp32c6:CDCOnBoot=cdc,FlashSize=8M" --libraries ../libraries .
arduino-cli upload  -b "esp32:esp32:esp32c6:CDCOnBoot=cdc,FlashSize=8M" -p /dev/cu.usbmodem* .
```

`--libraries ../libraries` puts the in-repo libraries on the search path: the
board table and shared panel bring-up, plus the vendored JD9853 esp_lcd driver
(the Arduino core ships an ST7789 driver but no JD9853 one). The same flag
applies to `display_test` and `board_probe`. It is a compile-only flag; `upload`
reuses the cached build. The binary is board-independent, so the same build runs
on either board.

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

### Firmware update status

Firmware 1.1 reports version and capability metadata, but it deliberately does
not advertise OTA support yet, so the manager does not offer a nonfunctional
update action. The remaining OTA stage needs an 8MB dual-partition layout,
reliable transfer, SHA-256 and signature verification, provisional boot health
validation, and automatic rollback. Until that is implemented and tested, USB
remains required for firmware installation and recovery.

Worth knowing before that work starts: carrying both panel drivers in one binary
puts the build at ~84% of the default 1.31MB app partition. A dual-partition OTA
layout needs a custom partition table regardless, so this is a sizing input
rather than a blocker — but the headroom on the current layout is thin.

The management datagrams are unauthenticated and intended for a trusted local
network. Pairing or authenticated control should accompany OTA before panels
are exposed to untrusted LAN clients.

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

On the ESP32-C6-LCD-1.47, the RGB LED behind the display glows with live WiFi
signal quality, updated every 2 seconds. The ESP32-C6-Touch-LCD-1.47 has no
addressable LED, so this indicator is absent there — use the status card or
`CFGSHOW` for signal strength on that board.

| Color           | Meaning                                             |
| --------------- | --------------------------------------------------- |
| Green           | Strong signal (-55 dBm or better)                   |
| Yellow → orange | Fading signal (-55 to -90 dBm, continuous gradient) |
| Red             | Very weak signal, or not connected                  |
