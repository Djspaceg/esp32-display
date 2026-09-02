# Code structure

**Module layout and decomposition rules — September 2026**

This document records how the firmware sketch and the Mac app are split into
modules, what each module owns, and the rules that keep the split sound. It
complements `docs/firmware-target-architecture.md`, which owns targets,
profiles, and flashing; this one owns file and type boundaries.

## Firmware: `firmware/display_stream/`

The sketch used to be one 4,300-line `display_stream.ino`. It is now a set of
`.h`/`.cpp` modules in the sketch folder plus a thin `.ino` that owns only
`setup()` and `loop()`'s scheduling skeleton. Two rules made the split safe and
keep it that way:

1. **Decision logic lives in Arduino-free headers; hardware and state glue
   lives in `.cpp` files.** The pure headers (`band_protocol.h`,
   `tile_protocol.h`, `device_protocol.h`, `panel_state.h`, `ota_policy.h`,
   `control_queue.h`, `band_compress.h`, `bc1.h`, `chip_identity.h`,
   `glyph_draw.h`) compile in one hardware-free translation unit and are unit
   tested on the host by `firmware/test/run_tests.sh`. A module whose logic
   deserves a test keeps that logic in such a header.
2. **A mutex moves with all the state it guards.** `drawMux`, `dmaCountMux`,
   and `controlMux` each live in exactly one module together with every
   variable they protect; no critical section spans modules.

### Module map

| Module                  | Owns                                                                                                                                                                                                                                   |
| ----------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `display_stream.ino`    | `setup()`, `loop()`'s scheduling skeleton (timers, failsafes, the link-heal state machine), and the Doom one-shot boot path                                                                                                            |
| `app_state.h/.cpp`      | Read-mostly identity: WiFi credentials, device name, `FW_VERSION`, MAC-derived `deviceId`, board variant/config, compile-time panel geometry, the `esp_lcd` panel handle, peripheral availability flags, and the shared stats counters |
| `glyph_draw.h`          | Pure 5×7 text rasterization over a caller-supplied RGB565 buffer (host-tested)                                                                                                                                                         |
| `dma_gate.h/.cpp`       | `dmaInFlight` + `dmaCountMux`, the DMA-complete ISR, mark/unmark, spin/wait helpers, and the 500 ms stall reclaim                                                                                                                      |
| `display_power.h/.cpp`  | The backlight/visibility state machine: user level, manual off, sleep, idle, touch-wake, survey flag, identify pulse; every path to the brightness sink                                                                                |
| `orientation.h/.cpp`    | Manual and gravity-derived rotation, MADCTL application, and the 10 Hz motion poll                                                                                                                                                     |
| `frame_pipeline.h/.cpp` | Frame buffers, band/tile reassembly state and appliers, `drawMux` and the pending bitmaps, the draw pass, and `fillPanel`                                                                                                              |
| `net_link.h/.cpp`       | Per-chip inbound UDP transport, the reply endpoint, inbound dispatch (`EPNG`/`ESLP`/`EWAK`/`ETXT`/`ECTL`/frames), and `sendToSender`                                                                                                   |
| `control_apply.h/.cpp`  | `controlMux`, the control queue, idle-text RAM state, and applying queued ECTL commands on the loop task                                                                                                                               |
| `telemetry.h/.cpp`      | Capability/flag derivation and the outbound EINF, EHB1, EBAT, and EACK packets, plus the battery reading cache                                                                                                                         |
| `mdns_announce.h/.cpp`  | The `_espdisp._udp` service, its TXT records, and OTA's `_arduino._tcp`                                                                                                                                                                |
| `ota_service.h/.cpp`    | ArduinoOTA bring-up, its progress callbacks, and the OTA state flags                                                                                                                                                                   |
| `ui_screens.h/.cpp`     | The idle/status card, the signal survey, the quick info bar, and the OTA progress screen                                                                                                                                               |
| `input_button.h/.cpp`   | BOOT button tiers: short, double, long, extra-long, and the Doom triple-tap                                                                                                                                                            |
| `input_touch.h/.cpp`    | Touch polling, wake-consumption, gesture forwarding                                                                                                                                                                                    |
| `serial_config.h/.cpp`  | The `CFG*` serial command surface                                                                                                                                                                                                      |
| `tile_bench.h/.cpp`     | `CFGBENCH` microbenchmarks (S3 only)                                                                                                                                                                                                   |
| `signal_led.h/.cpp`     | The addressable LED: WiFi-signal color, identify and `CFGLED` overrides                                                                                                                                                                |
| `prefs_store.h/.cpp`    | Every NVS read and write: display prefs, idle text, boot-time load                                                                                                                                                                     |
| `doom_bridge.cpp`       | The two `extern "C"`/global symbols the Doom library links against (gated on `ESPDISP_DOOM_S3_175`)                                                                                                                                    |

Compile guards are unchanged by the split: S3-only code stays inside
`CONFIG_IDF_TARGET_ESP32S3`, the 1.85 board inside `ESPDISP_BOARD_S3_185`, and
Doom inside `ESPDISP_DOOM_S3_175`, whichever file it lives in. The C6 image
runs near its flash ceiling, so the split is code motion, not new abstraction:
no virtual dispatch, no wrapper layers.

Code shared with `display_test` or `board_probe` belongs in
`firmware/libraries/espdisp_board`, not the sketch folder — that boundary is
unchanged.

## Mac app: `mac/ESPDisplaySender/`

Target layout is unchanged: `SenderProtocol` (pure wire formats and policies,
no AppKit), `SenderCore` (application layer), and a thin executable. What
changed is inside `SenderCore`: `PanelManager` used to be a 3,100-line god
object; it is now a facade over focused collaborators, and its value types
live in their own files.

### `PanelManager` and its concern files

`PanelManager` remains the single `@MainActor ObservableObject` the UI
observes, keeps every `@Published` property, both initializers, and the public
method surface — views, Cocoa scripting, `AppMain`, and the tests are unchanged
by the split. Its 3,100 lines are now one core file plus one
`extension PanelManager` file per concern:

| File                                 | Owns                                                                                                                                                                                                                                |
| ------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `PanelManager.swift`                 | Stored state, both initializers and their wiring, settings, issue/outcome plumbing, the nonisolated statics, and the core mutation trio (`updatePanel` / `sortPanels` / `persistIfNeeded`, including the 30 s persistence throttle) |
| `PanelSnapshot.swift`                | The published value type and its presentation helpers                                                                                                                                                                               |
| `AppFeedback.swift`                  | `OperationOutcome`, `AppIssue`, `ReportedIssue`                                                                                                                                                                                     |
| `PanelManager+Records.swift`         | Record lifecycle: discovery, session registration, hardware-ID identity binding and service-name migration (including the one-shot provisional-pause lift), and removal                                                             |
| `PanelManager+SessionIngest.swift`   | `DeviceSession.Status` and `FrameSender.DeviceEvent` ingestion, guarded by session ID and superseded-name checks                                                                                                                    |
| `PanelManager+DeviceControls.swift`  | Capability gating and the brightness/flip/rotate/power/identify/restart/idle-text commands, including brightness echo suppression                                                                                                   |
| `PanelManager+CaptureSources.swift`  | Display list, region marquee, live preview, and the macOS picker                                                                                                                                                                    |
| `PanelManager+Gestures.swift`        | Gesture dedup and preset dispatch (pause, media keys, window/source cycling)                                                                                                                                                        |
| `PanelManager+UsbDevices.swift`      | USB device inventory, coalesced identity probes, and path generations                                                                                                                                                               |
| `PanelManager+FirmwareUpdates.swift` | OTA/USB readiness preflight, `PanelManager.FirmwareUpdateTarget` gathering, remembered OTA passwords, and both push paths                                                                                                           |
| `PanelManager+UsbConfig.swift`       | Serial configuration (rename, WiFi, OTA password) and USB onboarding — the only path that creates a sidebar record                                                                                                                  |

Extensions were chosen over collaborator objects deliberately: SwiftUI
observation forces one `ObservableObject`, and nearly every concern reads
`panels`, `sessions`, and the outcome plumbing — collaborator classes would
each have held an `unowned` manager reference and reached back for
everything, adding ceremony without decoupling. Swift stored properties
cannot live in extensions, so all stored state stays declared in
`PanelManager.swift`, grouped and documented by the concern that owns it.

Because `private` is file-scoped in Swift, members used across concern files
are `internal` (and the `@Published` collections are `internal(set)`); the
module boundary is the real wall — none of this is visible outside
`SenderCore`. Nested type names such as `PanelManager.FirmwareUpdateTarget`
are preserved, so call sites and tests never renamed anything.

### `tools/espdisp.py`

Deliberately not split. It is a single-file, stdlib-only CLI so it can be run
by path with no packaging, and it is organized by section markers with its own
test suite (`tools/test_espdisp.py`). Its size is inventory (the board table,
the bundle format, esptool plumbing), not tangling.

## Verification

Any change to these boundaries runs the same gate as a feature:

- `bash firmware/test/run_tests.sh`
- `python3 tools/test_espdisp.py`
- `swift test` in `mac/ESPDisplaySender`
- `python3 tools/espdisp.py compile --board c6|s3-175|s3-185`
