# ESPDisplaySender — Improvement Backlog

The capture → diff → stream pipeline from `esp32-wireless-display-plan.md` is
done, including both of its stretch goals (dirty-band diffing, adaptive
pacing). What remains falls into three themes:

1. The app does not tell you when it is broken.
2. The panel is useless without the Mac.
3. The application layer is untestable, so only the protocol layer is covered.

Items reference files and symbol names rather than line numbers where
possible, since line numbers drift. Ordered roughly by value per unit of work.

**Status:** everything below is implemented except real OTA (Deferred) and the
`--port` half of the fps/pacing item, which is blocked on the firmware side.
Coverage went from 20 Swift tests and 140 host checks to 198 and 280.

## Tier 1 — Fix what actively misleads

- [x] **Surface failures that currently only reach the log.**
  Several failure modes are written to stderr or swallowed entirely, so the UI
  keeps claiming everything is fine. Worst case: Screen Recording permission
  is denied, `main.swift` writes to stderr, and the panel still shows "Online"
  with a source description while zero frames flow.
  - `PanelSnapshot` has no error/health field, so per-panel failure cannot be
    rendered even when it is known. Add one.
  - Silent paths to fix: Screen Recording denial (`main.swift`, capture
    preflight), malformed `~/.config/espdisplay/devices.json`
    (`DeviceSourceConfig.parse` call site), device retired as unreachable
    (`PanelManager.retire` — sidebar shows "Offline" with no reason), and
    `panels.json` read/write, where both sides use `try?` and discard all
    errors (`PanelManager.persistIfNeeded`, `loadPersistedPanels`). A corrupt
    file currently means "no known panels" with no explanation.
  - Done when: each of those five conditions is visible in the window without
    opening `/tmp/espdisplaysender.log`.

- [x] **Unify error reporting.**
  There are two mechanisms: `PanelManager.operationError` shown by the single
  `.alert` in `ManagerWindow.swift`, and `WifiConfigUI`'s own `NSAlert` calls
  (rename failed, configuration failed, no device found). `PanelManager.rename`
  discards failure by returning nil; `applySavedNetwork`'s `Bool` result is
  dropped with `_ =`.
  - Also note 4 of the 7 `operationError` messages are unreachable, because the
    capability-gated controls that would set them are `.disabled` by
    `canControl`. Either drop those messages or stop double-gating.

- [x] **Stop the offline send path from burning work.**
  Observed live: with the panel gone, the session kept capturing and sending at
  ~1.5 fps and accumulated over 213,000 send errors while `FrameSender.reconnect`
  retried every 15s. Nothing pauses the pipeline when the device is not
  answering.
  - Park the session on sustained heartbeat loss (`DeviceSession` supervisor
    already tracks `heartbeatAge`): stop capture and frame sends, keep
    re-resolution alive, resume on the first heartbeat.
  - Suspend ScreenCaptureKit entirely while no panel is online. This is real
    battery on a laptop.
  - Done when: an offline panel produces a flat send-error count and no
    per-frame log spam.

- [x] **Separate persisted settings from live telemetry in `panels.json`.**
  `PanelSnapshot` is `Codable` over every stored property, so RSSI, uptime,
  free heap, pacing, brightness, flipped, sleeping, idle, `paused`, and
  `sourceDescription` are all written to disk. `PanelManager.init` resets only
  `discovered`, `lastHeartbeatAt`, and `displayFPS` on load, so a fresh launch
  renders stale telemetry as if current until the first `EINF` arrives.
  - `paused` is the clearest bug: it persists, but sessions always start
    unpaused, so the restored value can contradict reality.
  - Split into a persisted record (service name, display name, `hardwareID`,
    `usbPort`, address) and a runtime snapshot.

- [x] **Remove the dead OTA button.**
  `ManagerWindow.swift` gates "Install Firmware Update…" on
  `panel.capabilities.contains(.ota)`, and `showOTANotice()` can only report
  that no firmware bundle is installed. Firmware deliberately omits `CAP_OTA`
  (`DEVICE_CAPABILITIES` = 0x6F), so it is unreachable against real hardware —
  but `PanelManager.preview` unions `.ota` in, so the SwiftUI preview shows a
  button that cannot work. Delete it until real OTA exists (see Deferred).

- [x] **Derive the mDNS `caps` TXT record from `DEVICE_CAPABILITIES`.**
  `display_stream.ino` hardcodes the literal `"0000006f"` in two places
  (initial announce in `setup()`, and the re-announce after a WiFi heal). It is
  not computed from the constant it is supposed to mirror, so it will drift the
  first time a capability is added.

- [x] **Make the "WiFi up" fill honest.**
  The dark teal `fillPanel(0x0210)` in `setup()` runs unconditionally. The WiFi
  wait is bounded to 30s and falls through on timeout, so a board that never
  associated still paints the "connected, waiting for stream" colour. Gate it
  on `WiFi.status()`, or use a distinct colour for the timeout case.

## Tier 2 — Better to use

- [x] **Persist the per-panel capture source.**
  The biggest day-to-day gap. `PanelManager.applyPickerSelection` stores only a
  description *string*; the `SCContentFilter` itself is never saved. After a
  restart every panel falls back to `devices.json` or automatic selection, so
  "show Music on this panel" does not survive a reboot. The UI neither reads
  nor writes `~/.config/espdisplay/devices.json`, so durable per-device sources
  require hand-editing JSON.
  - Done when: a source chosen in the picker still applies after relaunch, with
    no manual file editing.

- [x] **Continuous brightness.**
  The firmware is binary: `BL_HIGH = 128`, `BL_LOW = 24` (plus `BL_IDLE = 10`).
  But `EINF` already carries a full 0–255 brightness byte and
  `PanelSnapshot.brightness` already stores an `Int`, so the protocol is
  already shaped for it. Add a control opcode with a 0–255 range (extend
  `validControlValue` in `device_protocol.h`) and replace the high/low toggle
  with a slider.

- [x] **Expose fps, pacing, and port in the UI.**
  `--fps`, `--spacing-us`, `--fixed-pacing`, and `--port` are CLI-only, and the
  app actually runs from a LaunchAgent, so in practice they are unreachable
  once installed. Per-panel fps starts to matter when one panel is on weak
  WiFi. Note `UDP_PORT` is hardcoded in firmware, so port is only meaningful if
  the device side becomes configurable too.
  - Done for fps, pacing, and adaptive pacing, via a ⌘, Settings sheet backed
    by `settings.json`. Port was deliberately left out: exposing a control that
    cannot work against the current firmware is the same mistake as the OTA
    button above.

- [x] **Expose the identify duration.**
  Firmware validates 1–30 seconds, but the UI sends a single fixed value from
  one button.

## Tier 3 — Make the panel useful on its own

- [x] **Give the idle panel something worth showing.**
  With the Mac asleep the panel shows a three-line card — name, IP, RSSI — at
  backlight 10, after `SENDER_GONE_MS` (45s). That is a diagnostic, not a
  display. There is no time source in the firmware at all (only `millis()`; no
  SNTP or RTC), and no protocol path for the Mac to push text, since the only
  pixel input is band frames.
  Two options, second preferred:
  1. Add SNTP plus a local clock/status face.
  2. Add a small text/stat push command so the Mac can send a compact payload
     (build status, CPU, next meeting) that the panel keeps rendering after the
     Mac goes away.
  Option 2 is closer to the "system stats dashboard" idea already in the plan
  doc, and it reuses `font5x7.h`, which today has exactly one caller
  (`drawIdleScreen`).

## Tier 4 — Make the core testable

- [x] **Extract a `SenderCore` library target.**
  `Package.swift` declares the whole app as an `executableTarget` with no test
  target depending on it (`SenderProtocolTests` depends only on
  `SenderProtocol`). Everything in the application layer is therefore
  untestable as configured, not merely untested. Move the logic into a library
  and leave `main` thin.
  - Highest-value tests unlocked, in order:
    - `PixelConvert` BGRA→RGB565BE conversion. This decides whether every pixel
      on the panel is correct and is currently verified only by eye.
    - `PanelManager.reconcilePanelIdentity` — intricate state juggling across
      `panels`, `sessions`, `supersededServiceNames`, and `selectedServiceName`.
    - `panels.json` encode/decode round-trip and the load-time field reset.
    - `WifiConfigUI.matchingPort` / `validate` port disambiguation, and
      `normalizedDeviceName` (the firmware's equivalent sanitizer in
      `processConfigLine` is also untested).
    - `canControl` capability gating.
  - For reference, the protocol layer was already well covered when this was
    written: 20 Swift tests plus 140 host-compiled firmware checks. It is now
    198 Swift tests and 280 host checks across both layers.

- [x] **Consider host-testing firmware logic that currently lives in the `.ino`.**
  `band_protocol.h` and `device_protocol.h` are host-tested; the sketch is not.
  Untested sketch logic includes the ECTL dedupe rings and control queue, NVS
  load/save, the `CFG*` serial parser, button handling, the WiFi heal state
  machines, the DMA-stall failsafe, and `currentDeviceFlags` /
  `currentBrightness` — the last two feed every `EINF` and `EACK` the Mac
  trusts. Moving them into headers would bring them into `run_tests.sh`.
  - Done for the parts whose rules are worth asserting: the control queue and
    dedupe rings are now `control_queue.h`, and `currentDeviceFlags` /
    `currentBrightness` are now `panel_state.h`. The rest (NVS, `CFG*` parsing,
    buttons, WiFi heal, DMA failsafe) is left in the sketch because it is
    mostly sequencing against hardware, where a host test would assert the
    shape of the mock rather than anything real.

## Deferred

- [ ] **Real OTA firmware update.**
  Not implemented anywhere on the device: no `esp_ota_*`, no `ArduinoOTA`, no
  `Update.begin`, no partition-table work. USB is the only install and recovery
  path. Doing it properly means a partition table, signed bundles, and
  rollback, and it only pays off once panels are mounted somewhere awkward to
  reach with a cable. Until then, keep the button deleted (Tier 1) rather than
  advertising a capability that cannot work.

## Unused protocol surface (context, not tasks)

- `CAP_SLEEP_SYNC` and `CAP_TELEMETRY` are advertised by the firmware but never
  read by the Mac; sleep/wake sending and `EINF` parsing happen
  unconditionally, so both bits are decorative.
- `CFGFLIP` (redundant with the ECTL flip opcode) and `CFGLED` are serial-only
  with no UI.
- There is no network opcode for name, WiFi, or orientation — those are
  USB-serial only.
