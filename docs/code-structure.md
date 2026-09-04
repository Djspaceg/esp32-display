# Code structure

**Module layout and decomposition rules — September 2026**

This document records file ownership. Firmware-family composition and release
selection are defined in `docs/firmware-target-architecture.md`.

## Firmware

`firmware/display_stream/display_stream.ino` owns `setup()` and `loop()`
scheduling. Hardware-free decisions stay in headers tested by
`firmware/test/run_tests.sh`; hardware/state glue stays in `.cpp` modules. A
mutex lives with all state it protects.

| Module | Owns |
| --- | --- |
| `app_state.h/.cpp` | Identity, runtime geometry, active profile/config, panel handle, availability flags, and shared counters |
| `frame_pipeline.h/.cpp` | Buffers, band/tile/ETL1 reassembly, pending bitmaps, draws, and fills |
| `net_link.h/.cpp` | Inbound UDP transports, dispatch, and sender reply endpoint |
| `display_power.h/.cpp` | Brightness, manual power, sleep, idle, identify, and display visibility |
| `orientation.h/.cpp` | Manual/gravity rotation and panel transform application |
| `control_apply.h/.cpp` | Control queue, idle-text RAM state, and loop-task application |
| `telemetry.h/.cpp` | Capabilities and EINF/EHB1/EBAT/EACK output |
| `mdns_announce.h/.cpp` | `_espdisp._udp`, `_arduino._tcp`, and identity TXT records |
| `serial_config.h/.cpp` | `CFG*`, including family/profile/chip/partition identity |
| `input_button.h/.cpp` | BOOT press tiers and profile-gated developer behavior |
| `input_touch.h/.cpp` | Touch polling, wake consumption, and gestures |
| `ui_screens.h/.cpp` | Status, signal survey, info bar, and OTA progress screens |
| `dma_gate.h/.cpp` | Transfer completion accounting and stall recovery |
| `ota_service.h/.cpp` | ArduinoOTA lifecycle and progress |
| `prefs_store.h/.cpp` | NVS reads and writes |
| `signal_led.h/.cpp` | Addressable status/identify output |
| `tile_bench.h/.cpp` | S3 measurement commands |

`firmware/libraries/espdisp_board/` owns reusable hardware composition:

| File | Owns |
| --- | --- |
| `platform_config.h` | Chip, build/partition identity, memory, network, serial, and identity source |
| `panel_config.h` | Controller, bus, geometry, timing, offsets, inversion, and shape |
| `board_config.h` | Runtime variants and carrier wiring/peripherals |
| `board_detect.h` | C6/S3 pre-panel profile probes and fail-closed ambiguity handling |
| `display_backend.h` | Bus-neutral init, drawing, transform, and brightness facade |
| `panel_init.h` | Runtime SPI/QSPI controller construction |
| `panel_init_dsi.h` | P4 MIPI-DSI implementation |

P4-specific SDK guards may select MIPI APIs, but platform configuration must not
contain 4B panel timing or carrier pins. The S3 family build links all supported
S3 controller paths and chooses one runtime `Config` before geometry and buffers
are initialized.

## macOS app

SwiftPM targets remain:

- `SenderProtocol`: bundle/catalog readers and pure protocol/policy types;
- `SenderCore`: discovery, selection, update safety, app state, and UI;
- `ESPDisplaySender`: executable entry point.

`FirmwareReleaseCatalog.swift` strictly parses the canonical three-family
catalog and validates complete family/chip/profile/partition identity.
`FirmwareBundle.swift` verifies bundle bytes and retains legacy readers.
`BundledFirmware.swift` loads exactly the catalog's three resources, rejects
extras/duplicates/stale metadata, and selects one family.

`PanelManager` remains the observed facade. Concern extensions own record
lifecycle, session ingest, device controls, capture sources, gestures, USB
inventory, firmware updates, and USB configuration. Discovery-scoped family,
profile, and partition evidence lives in `PanelSnapshot`; it is cleared when a
service disappears and is not persisted as authorization for a future device.

## Build and release tools

`tools/espdisp.py` remains a stdlib-only single-file CLI. Its `Platform` rows own
build facts; `Family` rows own release-family profile/hardware mappings. The
current commands are:

```sh
python3 tools/espdisp.py compile --family c6
python3 tools/espdisp.py compile --family s3
python3 tools/espdisp.py compile --family p4
python3 tools/espdisp.py bundle --family s3
python3 tools/espdisp.py release --output-root firmware-releases
```

`mac/embed-firmware-bundle.sh` validates the canonical catalog and copies its
three artifacts into the app before signing. `mac/make-app.sh` never compiles or
duplicates firmware.

## Verification

Run:

- `bash firmware/test/run_tests.sh`
- `python3 tools/test_espdisp.py`
- `swift test` from `mac/ESPDisplaySender`
- all three family compiles
- independent `bundle-info` inspection of c6/s3/p4
- a signed app build plus embedded-resource comparison
