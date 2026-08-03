# esp32-display

A wireless second display for macOS, built from a $10 ESP32-C6 board with a
1.47" LCD. The Mac captures screen content with ScreenCaptureKit, streams raw
RGB565 pixels over WiFi, and the board pushes them to its ST7789 panel over
80MHz SPI with DMA. No compression, no video codecs — at 172×320 the whole
frame is 110KB, so the pipeline stays simple and the latency stays low.

Hardware: [ESP32-C6-LCD-1.47](https://spotpear.com/shop/ESP32-C6-1.47-inch-LCD-Display-Screen-LVGL-SD-WIFI6-ST7789.html)
(Waveshare design — ESP32-C6, WiFi 6, 1.47" 172×320 IPS panel, ST7789 driver).

## What it does

Plug the board into USB power anywhere on your network. It joins WiFi,
announces itself over mDNS, and the Mac finds it automatically — no IP or
hostname to configure. Plug in a second board and it gets its own stream.

The native ESPDisplaySender manager lists discovered and previously known
panels with online state, IP address, RSSI, displayed frame rate, firmware
version, and diagnostics. Select a panel to choose its ScreenCaptureKit source,
pause or resume it, change brightness or orientation, identify it, restart it,
or open USB WiFi/name configuration. Known panels persist in
`~/Library/Application Support/ESPDisplaySender/panels.json`, so powered-off
panels remain visible as offline.

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
or application picker to the selected panel. For advanced unattended defaults,
you can still assign sources by device name in
`~/.config/espdisplay/devices.json` — one board mirrors a display while another
follows a specific app window:

```json
{
  "espdisplay-9050": { "display": "Tiny Monitor" },
  "espdisplay-abcd": { "window": "Music" }
}
```

Devices with no entry use automatic selection. Names default to
`espdisplay-XXXX` (from the board's MAC) and are changeable from the manager's
USB configuration action.

The panel follows macOS. Rotate the virtual display and the panel rotates
with it, re-laying-out in landscape or portrait. Change mirroring modes,
resize, close the window you were streaming — the sender notices within a
couple of seconds and reattaches on its own.

The board itself has two physical controls on its BOOT button: a short press
toggles backlight brightness, a long press flips the image 180° for
upside-down mounting. Both are saved to the board's flash, so they survive
reboots and firmware reflashes — set the orientation once for how the board
is mounted and forget it. (A full flash erase does reset them.)

WiFi credentials live in the board's flash, not in the firmware — change
networks by plugging the board into the Mac over USB and choosing **Configure
WiFi or Name over USB** in the manager. A dialog shows the current network
(fetched from the board) and saves new credentials over serial. No reflashing,
and the recovery path works even when the stored credentials are wrong. SSIDs
with spaces, emoji, and extended Unicode all work — everything crosses the
wire base64-encoded.

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

| Orientation | Band | Bands/frame | Packet size |
| --- | --- | --- | --- |
| Portrait 172×320 | 4 rows × 344B | 80 | 1382B |
| Landscape 320×172 | 2 rows × 640B | 86 | 1286B |

The device replies with a compatible 1Hz heartbeat (`EHB1` +
frame/drop/packet/heap counters) to whoever sent it packets last; the sender
emits a 2s `EPNG` keepalive so that address stays fresh through static screens.
Firmware 1.1 also sends versioned `EINF` telemetry every 2 seconds with firmware,
frame/control protocol versions, capabilities, stable hardware ID, uptime,
RSSI, brightness, orientation, and sleep state. Fixed-size `ECTL` commands and
`EACK` responses provide typed brightness, flip, identify, and restart control
without changing the frame or legacy heartbeat formats.

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
`CFGSHOW` reports the current network, name, IP, signal strength, and the
saved orientation/brightness; `CFGFLIP 0|1` sets the 180° flip without the
button; `CFGLED <r> <g> <b>` shows a literal LED color for 10s.

## Repo layout

| Path | What |
| --- | --- |
| `firmware/display_stream/` | The real firmware: WiFi, mDNS, UDP receiver, esp_lcd DMA, button and remote controls |
| `firmware/display_test/` | Standalone panel bring-up test (colors, offsets, SPI timing benchmark) |
| `firmware/board_probe/` | I2C-scan sketch that identifies which board variant you have |
| `mac/ESPDisplaySender/` | Native manager app plus SwiftPM command-line workflows |
| `firmware/test/` | Host-side unit tests for the protocol logic (`run_tests.sh`) |
| `mac/ESPDisplaySender/Tests/` | Swift tests for the sender's protocol logic (`swift test`) |
| `tools/read_serial.py` | Serial monitor with optional hard-reset (native USB-Serial/JTAG) |
| `tools/sweep.py` | Pacing parameter sweep, measuring displayed fps from device stats |
| `docs/` | Original project plan |

## Getting started

Firmware (needs [arduino-cli](https://arduino.github.io/arduino-cli/) and the
esp32 core with the espressif board manager URL):

```sh
cd firmware/display_stream
cp wifi_config.h.example wifi_config.h   # fill in your 2.4GHz network
arduino-cli compile -b "esp32:esp32:esp32c6:CDCOnBoot=cdc,FlashSize=8M" .
arduino-cli upload  -b "esp32:esp32:esp32c6:CDCOnBoot=cdc,FlashSize=8M" -p /dev/cu.usbmodem* .
```

Mac app — the set-and-forget way:

```sh
mac/make-app.sh                 # builds ~/Applications/ESPDisplaySender.app
mac/install-launch-agent.sh     # starts hidden at login; restarts abnormal exits
open ~/Applications/ESPDisplaySender.app
```

`make-app.sh` builds the checked-in Xcode project and shared
`ESPDisplaySender App` scheme. It uses ad-hoc signing by default. To preserve a
stable designated requirement and avoid repeatedly granting Screen Recording,
provide a signing identity installed in your keychain:

```sh
ESPDISPLAY_CODE_SIGN_IDENTITY="Developer ID Application: Example" mac/make-app.sh
```

Grant Local Network and Screen Recording when macOS asks. Logs land in
`/tmp/espdisplaysender.log`. A foreground launch opens the manager; closing its
window leaves streaming active in accessory mode. **Quit ESPDisplaySender**
stops it cleanly, and the LaunchAgent does not restart a clean exit until the
next login or foreground launch.

Leaving the USB configuration password field blank keeps the password already
saved on the device, so changing the network name or renaming the board doesn't
mean retyping it. Joining a genuinely open network is an explicit checkbox, so
a blank field cannot silently replace a working password with an empty one.

The project remains usable directly from Xcode or SwiftPM:

```sh
cd mac/ESPDisplaySender
xcodebuild -project ESPDisplaySender.xcodeproj \
  -scheme "ESPDisplaySender App" -configuration Debug \
  CODE_SIGNING_ALLOWED=NO build
swift test
swift build
./.build/debug/ESPDisplaySender                  # manager plus automatic capture
./.build/debug/ESPDisplaySender --background     # hidden background mode
./.build/debug/ESPDisplaySender --list-displays  # see what's capturable
./.build/debug/ESPDisplaySender --configure      # USB WiFi/name setup dialog
./.build/debug/ESPDisplaySender --help           # all options
```

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

The management datagrams are unauthenticated and intended for a trusted local
network. Pairing or authenticated control should accompany OTA before panels
are exposed to untrusted LAN clients.

## Status lights

The panel itself tells you where the firmware is: dark gray means alive and
waiting for WiFi, dark teal means connected and waiting for a stream.

Dimming follows the Mac, never the picture. Unchanging content — a photo, a
dashboard, a paused video — stays at full brightness indefinitely:

| Condition | Panel |
| --- | --- |
| Streaming, even perfectly static content | Last frame, full brightness |
| Mac's displays sleep, or screensaver | Backlight off (`ESLP`) |
| Mac system sleep | Backlight off (`ESLP`) |
| Mac wakes | Restored immediately (`EWAK`) |
| Sender gone ~45s (quit, crashed, WiFi down) | Dimmed status card |

The status card shows device name, IP, and WiFi strength in outlined text
over the last frame, repositioning every 30 seconds to avoid burn-in. It
means "nothing is driving this panel", so it keys off the sender's 2-second
keepalive rather than frame arrivals — with dirty-band diffing a still image
sends no frame data for minutes, and treating that as idleness made the
panel dim itself during normal use.

The RGB LED behind the display glows with live WiFi signal quality, updated
every 2 seconds:

| Color | Meaning |
| --- | --- |
| Green | Strong signal (-55 dBm or better) |
| Yellow → orange | Fading signal (-55 to -90 dBm, continuous gradient) |
| Red | Very weak signal, or not connected |
