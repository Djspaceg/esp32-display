# P4 + 4B implementation status

## Result

Implemented ESP32-P4 and Waveshare ESP32-P4-WIFI6-Touch-LCD-4B support with separate platform, panel, and carrier ownership. `platform_config.h` owns P4 runtime policy; `panel_config.h` owns ST7703 720×720 MIPI-DSI timing; `board_config.h` composes those with the 4B GPIO, GT911, backlight, and BOOT wiring. Display operations use the shared SPI/QSPI/DSI facade.

Added GT911 polling, eFuse-base identity, hosted-WiFi platform selection, MIPI-DSI/ST7703 support, capability-gated ETL1 large-tile streaming, dual-OTA P4 packaging, and macOS bundle/update handling. Malformed ETL1 payloads are decoded before reassembly state is committed, so a valid retry is not poisoned as a duplicate. The latest runtime-family refactor now emits family targets `c6`, `s3`, and `p4`, with the P4 physical profile reported separately as `st7703-4b`.

Fixed the latest P4 boot regression found during hardware validation: generic frame-pipeline initialization rejected 720×720 because it is not band-streamable. The initializer now accepts a valid ETL1 geometry while retaining a legacy-band reassembler that rejects incompatible old packets safely.

Review fixes also move P4 FQBN/chip/silicon facts into the platform catalog, include the complete Apache-2.0 license text for the ST7703 adaptation, cover every internal selector conflict, and remove the flagged terminology from the task plan.

## Files

Created or added major support under:

- `firmware/libraries/espdisp_board/src/platform_config.h`
- `firmware/libraries/espdisp_board/src/panel_config.h`
- `firmware/libraries/espdisp_board/src/display_backend.h`
- `firmware/libraries/espdisp_board/src/panel_init_spi.h`
- `firmware/libraries/espdisp_board/src/panel_init_dsi.h`
- `firmware/libraries/espdisp_board/src/gt911_protocol.h`
- `firmware/libraries/esp_lcd_st7703/`
- `firmware/display_stream/large_tile_protocol.h`
- `firmware/partitions_p4_4b.csv`
- `firmware/partitions_s3.csv`
- `mac/ESPDisplaySender/Sources/SenderProtocol/LargeTileProtocol.swift`
- `mac/ESPDisplaySender/Tests/SenderProtocolTests/LargeTileProtocolTests.swift`

Modified board detection/composition, frame/display/network/touch paths, diagnostics, CLI family builds and bundles, Swift sender/update safety, focused tests, documentation, To-do status, and the canonical `release-notes.md` 1.5.0 section. No commit, push, CR, `.git` edit, whole-chip erase, fuse/security operation, or C6 coprocessor write was performed.

## Automated validation

- `bash firmware/test/run_tests.sh` → `OK: 104183 checks passed` under ASan/UBSan.
- `python3 tools/test_espdisp.py` → `OK: 1224 checks passed`; expected argparse refusal text is emitted by negative CLI tests.
- `swift test --quiet` from `mac/ESPDisplaySender` → 836 tests, 0 failures.
- `git diff --check` → success.
- `python3 tools/espdisp.py compile --family c6` → success; final release compile used 1,195,906 sketch bytes.
- `python3 tools/espdisp.py flash --family s3 --port /dev/cu.usbmodem1101` → compile and verified upload success; 1,092,810 sketch bytes in the flash build.
- `python3 tools/espdisp.py compile --family p4` → success before hardware upload.
- `python3 tools/espdisp.py release --output-root /tmp/espdisp-p4-release-validation` → created independent format-3 C6, S3, and P4 artifacts plus a canonical catalog.
- Final release compiles: C6 1,195,906 bytes; S3 1,092,882 bytes; P4 1,114,216 bytes.
- `python3 tools/espdisp.py release-info /tmp/espdisp-p4-release-validation/manifest.json` → verified paths for all three family artifacts.
- `python3 tools/espdisp.py bundle-info /tmp/espdisp-p4-release-validation/p4/espdisp-p4-1.5.0.espdispfw` → one P4 image and three flash parts verified, contiguous, with matching hashes; release-note count only.
- P4 artifact: app 1,114,480 bytes, SHA-256 `da44ac8448a4bb8d05edfe743fbfd42fc80fb66841f27b06e2486a7f5fc8402d`.
- P4 addresses: bootloader `0x2000`, partitions `0x8000`, OTA data/boot_app0 `0xE000`, app `0x10000`; the partition table retains equal 8 MiB OTA slots.
- Independent Swift read → `Swift read format 3, 1 image, release notes 4, P4 bootloader 0x2000, profiles st7703-4b`.

## Hardware validation

Detected devices:

- P4: `/dev/cu.usbmodem5B901669681`, CH343 VID/PID `1A86:55D3`, serial `5B90166968`.
- S3-175: `/dev/cu.usbmodem1101`, VID/PID `303A:1001`, MAC `80:45:6b:35:04:50`.

Esptool 5.3.1 identified the P4 as ESP32-P4 revision v1.3 with 40 MHz crystal, base MAC `e8:f6:0a:e0:b5:5a`, flash ID `c8:4019`, and 32 MB flash. The current P4 development image was written without a whole-chip erase. One 921600-baud upload lost the serial link 16 KiB into the app write; recovery rebuilt and validated the same image, then rewrote the app at 460800 baud. The complete write and hash verification succeeded.

Fresh P4 boot log after the frame-geometry fix:

- Firmware 1.5.0, frame protocol 2, control protocol 1.
- Frame buffers initialized with 344,348 bytes free heap at that point.
- Runtime identity: family `p4`, profile `st7703-4b`, chip `esp32p4`, partition `p4-32m-ota`.
- ST7703 MIPI-DSI initialized at 720×720, 38 MHz DPI clock.
- GT911 initialized at `0x5D`, product ID `911`, polling mode.
- `CFGSHOW` returned `id=e8f60ae0b55a`, `board/profile=st7703-4b`, `target=p4`.
- `CFGPOWER 0` and `CFGPOWER 1` succeeded; final persisted state is power on.
- Previous diagnostic validation on this attached panel confirmed RGB primaries, edges/corners, partial rectangles, touch press/release markers, BOOT rotation, and four software display transforms. Odd-quarter-turn touch corners remain unverified, so rotate capability remains withheld.

The attached S3-175 was backed up before flashing. A physical 32 MB read encountered serial corruption at 6.35 MB without writing flash. A complete 16 MB logical-profile rollback image then succeeded at `/tmp/s3-175-pre-p4-facade-16m-20260904.bin`, SHA-256 `c4a9c5cef421ffd6b6e7b7535c99b7fca6340711e62528667b75731f524ff706`.

Current S3 hardware regression evidence:

- Runtime detection selected CO5300 and reported firmware 1.5.0, family `s3`, profile `co5300`, chip `esp32s3`, partition `universal-8m-ota`.
- A five-second 719-visible-tile motion run offered 12 fps and achieved 9.8 complete fps plus 22.5 partial draws/s while accepting 785 datagrams/s.
- A second run after switching from rotation 1 to rotation 3 achieved 6.0 complete fps plus 24.0 partial draws/s, proving the facade redraw path at the alternate quarter turn.
- Network brightness low/high commands returned successful acknowledgements with reported levels 24 and 128.
- Serial power off/on commands succeeded.
- Original settings were restored: rotation 1, high brightness, power on, connected WiFi, name `silver-round`.
- The existing Doom WAD region was not erased by the family flash.

## Remaining issues and limitations

Hosted WiFi remains blocked by the unchanged factory C6 firmware. Arduino-ESP32 3.3.11 logs `Response not received for [0x15e](Req_GetCoprocessorFwVersion)` before association. Per user direction, the C6 was not flashed. P4 network association, reachable mDNS, ETL1 streaming over WiFi, reconnect, OTA, and tearing/throughput under network motion remain unverified.

The current worktree’s concurrent family refactor identifies update compatibility as `target=p4` plus physical `profile=st7703-4b`, replacing the earlier exact artifact token `p4-4b`. Review should evaluate this current family/profile contract rather than the superseded six-exact-target bundle model in the original plan.

S3 facade behavior is supported by runtime telemetry, accepted control acknowledgements, and frame counters. This iteration did not have an independent visual observer for the S3 screen.
