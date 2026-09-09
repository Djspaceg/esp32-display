# Firmware Family Releases — Final Report

## Result

Implemented family-universal firmware release infrastructure for exactly `c6`,
`s3`, and `p4`. Current writers emit one family per format-3 bundle. Historical
format-1, format-2, and multi-target format-3 readers remain supported.

Source/release review verdict: **pass**. Hardware verdict: **pass for S3
protocol/control evidence; conditional for P4 touch because GT911 detection was
intermittent on reboot**. Exact hardware limitations are listed below.

## Files changed

The implementation changed these groups:

- Release source and documentation: `.gitignore`, `README.md`, `To-do.md`,
  `release-notes.md`, `docs/code-structure.md`,
  `docs/firmware-target-architecture.md`, and `docs/tile-stream-plan.md`.
- Canonical storage: `firmware-releases/manifest.json` and the versioned c6,
  s3, and p4 `.espdispfw` files.
- Build/release tooling: `tools/espdisp.py`, `tools/test_espdisp.py`,
  `firmware/partitions_s3.csv`, and `firmware/partitions_p4_4b.csv`.
- Firmware family/profile selection: `firmware/display_stream/` identity,
  startup, frame pipeline, ETL1, networking, telemetry, serial configuration,
  input, display, and test modules.
- Platform/panel/carrier composition:
  `firmware/libraries/espdisp_board/src/platform_config.h`,
  `panel_config.h`, `board_config.h`, `board_detect.h`, display backends,
  touch/GT911 support, and library metadata.
- P4 panel driver: complete vendored `firmware/libraries/esp_lcd_st7703/`,
  including full Apache-2.0 terms and provenance.
- macOS protocol/core: strict `FirmwareReleaseCatalog.swift`, extended
  `FirmwareBundle.swift`, `BundledFirmware.swift`, discovery identity,
  onboarding/update preflight, update presentation, and direct canonical
  resource loading.
- macOS packaging: `mac/embed-firmware-bundle.sh`, `mac/make-app.sh`, and the
  Xcode project build phase.
- Coverage: firmware host tests, Python source/parser/writer/catalog tests,
  Swift bundle/catalog/duplicate-key/update/onboarding tests, ETL1 tests, and
  generated-release Swift cross-read coverage.

The exact tracked inventory is available from:

```sh
git -P diff --name-only origin/main...HEAD
```

`.agents/` remains intentionally uncommitted.

## Canonical catalog schema

`firmware-releases/manifest.json` has schema `1` and exactly three family
members. Every member contains:

- `latest_version`, canonical relative `artifact`, full-file `sha256`, and
  `bytes`;
- `chip`, ordered `profiles`, and profile-to-hardware `hardware` mappings;
- `compatibility.flash_bytes`, `partition_scheme`, bootloader/partition/
  boot-app/app addresses, and required identity fields;
- required automatic-selection evidence: `family`, `chip`, `profile`, and
  `partition`.

Readers reject duplicate semantic JSON names, unknown/missing fields, missing or
extra families, invalid SemVer, path traversal/non-canonical filenames, stale
size/hash data, and family/chip/profile/partition disagreement.

| Family | Version | Artifact | Bytes | Full-file SHA-256 |
| --- | --- | --- | --- | --- |
| `c6` | `1.5.0` | `firmware-releases/c6/espdisp-c6-1.5.0.espdispfw` | 1,229,786 | `d440cd59bb441ae9804d94fbbc8555ea9e33fdd71a6319a93ba14cc2cb7863a8` |
| `s3` | `1.5.0` | `firmware-releases/s3/espdisp-s3-1.5.0.espdispfw` | 1,126,106 | `c855dd391de121f02ba5a8a866c02f0539991309baf68f212284344a738d72f7` |
| `p4` | `1.5.0` | `firmware-releases/p4/espdisp-p4-1.5.0.espdispfw` | 1,149,130 | `d25738918fbae0722aeb43bf23207da6a424821a1cc0b96adf98b47d0c6617fd` |

S3 compatibility includes verified 8, 16, and 32 MiB carriers while retaining
the common 8 MiB dual-OTA layout. Canonical S3 excludes developer-only Doom
code and WAD payloads; hardware smoke testing found that linking Doom consumed
internal RAM needed by SPI DMA rotation repaint.

Each artifact contains one image/target, three blank-device flash parts, and
five release-note items selected from root `release-notes.md`. `bundle-info`
reported only the item count.

## Validation

| Gate | Result |
| --- | --- |
| Firmware host ASan/UBSan | `OK: 104195 checks passed` |
| Python | `OK: 1255 checks passed` |
| Full Swift | 841 tests, 0 failures |
| Focused Swift catalog/bundle/update/onboarding | 158 tests, 0 failures |
| Generated release Swift cross-read | c6/s3/p4 passed |
| C6 compile | 1,195,906-byte sketch; 51,724 global bytes |
| S3 compile | 1,092,898-byte sketch; 126,480 global bytes |
| P4 compile | 1,114,240-byte sketch; 96,596 global bytes |
| `bundle-info` c6/s3/p4 | One family each; contiguous; all payload hashes match; five note items each |
| `git diff --check` | Clean |
| No-resource app build | `ESPDISP_SKIP_FIRMWARE=1 mac/make-app.sh` passed |
| Normal signed app build | Passed and installed |

Selection tests cover representative c6/s3/p4 identities, all runtime profile
mappings, complete family/profile conflict combinations, missing identity,
wrong family/chip/profile/partition, stale size/hash, path traversal, duplicate
catalog and bundle JSON names, duplicate/ambiguous resources, legacy bundle
reading, recovery profile choice, and literal/fallback release-note
presentation. Release-note metadata does not participate in selection or update
safety.

## Hardware flashes

No backups were taken. No whole-chip erase, fuse/security operation, or
calibration rewrite was issued. Both flashes wrote only bootloader, partition
table, `boot_app0`, and application segments, and esptool verified each segment
hash.

### Attached S3

- Port: `/dev/cu.usbmodem1101`.
- USB: VID/PID `303A:1001`; serial/MAC `80:45:6B:35:04:50`.
- Esptool: ESP32-S3 QFN56 revision v0.2, 8 MiB embedded PSRAM, 40 MHz crystal,
  flash manufacturer/device `c8:4019`, detected 32 MiB flash.
- Flash command:
  `python3 tools/espdisp.py flash --family s3 --port /dev/cu.usbmodem1101`.
- Writes: bootloader `0x0`, partitions `0x8000`, `boot_app0` `0xE000`, app
  `0x10000`; all verified.
- `CFGSHOW`: `id=80456b350450`, `target=s3`, `chip=esp32s3`,
  `board/profile=co5300`, `partition=universal-8m-ota`,
  `ip=192.168.8.135`, connected, OTA on.
- `CFGPOWER 0` and `CFGPOWER 1`: acknowledged.
- `CFGROT 0` and `CFGROT 1`: acknowledged and cached-frame application
  completed without the earlier DMA-allocation failure.
- Full/partial tile facade smoke: five datagrams; `frames=2`, `partial=1`,
  `packets=5`, `dropped=0`, `badlen=0`, `drawerr=0`; three draw passes and 35
  panel calls.
- The first Doom-linked trial reproduced SPI DMA private-buffer allocation
  failures. Canonical Doom linkage was removed, internal free heap rose, and the
  repeated rotation/draw test passed.

No independent visual observer was available, so literal displayed colors,
partial-rectangle placement, and visible orientation are not claimed despite
successful protocol/draw counters.

### Attached P4

- Port: `/dev/cu.usbmodem5B901669681`.
- USB bridge: VID/PID `1A86:55D3`, serial `5B90166968`.
- Esptool: ESP32-P4 revision v1.3, MAC `e8:f6:0a:e0:b5:5a`, 40 MHz crystal,
  flash manufacturer/device `c8:4019`, detected 32 MiB flash.
- Final flash command:
  `python3 tools/espdisp.py flash --family p4 --profile st7703-4b --port /dev/cu.usbmodem5B901669681`.
- Writes: bootloader `0x2000`, partitions `0x8000`, `boot_app0` `0xE000`, app
  `0x10000`; all verified at 460800 baud.
- Boot: ST7703 MIPI-DSI 720×720 initialized, backlight configuration completed,
  and the application continued after an ESP-Hosted
  `Req_GetCoprocessorFwVersion` warning.
- Later boot output printed an address, RSSI, mDNS announcement, and UDP receiver
  start. Those lines are recorded as diagnostics only: hosted association and
  reachable network behavior were not validated because coprocessor compatibility
  remained unresolved.
- `CFGSHOW`: `id=e8f60ae0b55a`, `target=p4`, `chip=esp32p4`,
  `board/profile=st7703-4b`, `partition=p4-32m-ota`, connected, OTA off.
- `CFGPOWER 0` and `CFGPOWER 1`: acknowledged.
- GT911 was detected at `0x5D` on an earlier boot, but one final boot reported
  no GT911 at `0x5D` or `0x14`; final physical touch behavior is therefore an
  intermittent unresolved limitation rather than a pass claim.

### C6 coprocessor

The P4 carrier's C6 coprocessor was not backed up, flashed, erased, or otherwise
modified. It is not electrically accessible through the current authorized
development path. Its exact firmware version remains unverified. Boot output
printed later network-start lines, but those are not accepted as validation of
hosted association, mDNS reachability, or UDP traffic while the
coprocessor-version request remains unresolved.

A standalone c6-family board was not attached or flashed; c6 validation is
compile, host test, bundle inspection, and Swift cross-read only.

## C6 catalog repair evidence

The canonical `release` command rebuilds every family before writing
`manifest.json`. The post-review S3 capacity and release-note metadata change
therefore regenerated C6 from source commit
`caa793925ad552a4dd4a35ac523c594020a2dd7b`; the artifact grew from 1,229,782
to 1,229,786 bytes and its SHA-256 changed to
`d440cd59bb441ae9804d94fbbc8555ea9e33fdd71a6319a93ba14cc2cb7863a8`.
The catalog now matches that canonical on-disk artifact. No binary bytes were
manually patched and no additional bundle regeneration was performed during
the repair verification.

- `python3 tools/espdisp.py bundle-info` passed separately for c6, s3, and p4.
  Each reported format 3, one family image, five release-note items, contiguous
  payloads, and verified nested SHA-256 values.
- `python3 tools/espdisp.py release-info firmware-releases/manifest.json`
  returned exactly the c6, s3, and p4 canonical artifact paths.
- Independent `wc -c` and `shasum -a 256` checks matched every catalog size and
  digest in the table above.
- Final manifest SHA-256:
  `6db9bbd348e4837891a1ced7c698c52ed2d7470633a485e065276e33d86027b2`.
- `python3 tools/test_espdisp.py` passed with 1,255 checks.
- Focused Swift runs passed: `FirmwareBundleTests` 57 tests,
  `FirmwareReleaseCatalogTests` 4 tests, `GeneratedReleaseCrossReadTests` 1
  test, and `FirmwareUpdateTests` 35 tests, all with zero failures.
- `mac/make-app.sh` completed with `BUILD SUCCEEDED`, installed the Release app,
  and Apple Development signing passed strict verification.
- `cmp` returned success for the installed manifest and all three installed
  artifacts against `firmware-releases/`; paired `shasum -a 256` output matched
  for every source/installed file.
- `/usr/bin/codesign -vv --deep --strict` reported the installed app valid on
  disk and satisfying its designated requirement.
- Relaunched process PID `27214` runs
  `/Users/stepblk/Applications/ESPDisplaySender.app/Contents/MacOS/ESPDisplaySender`.
- The second-iteration clean-state gate found no staged or modified tracked
  files on `main`; `.agents/` remains the only untracked path. Concurrent,
  unrelated work was preserved without entering the release commit in local
  worktrees `/Users/stepblk/Source/esp32-display-review-handoff`,
  `/Users/stepblk/Source/esp32-display-review-handoff-2`, and
  `/Users/stepblk/Source/esp32-display-review-handoff-3`.

## Installed app

- Path: `~/Applications/ESPDisplaySender.app`.
- App version/build: `1.1` / `2`.
- Identifier: `com.espdisplay.sender`.
- Signature: Apple Development; `make-app.sh` verification reported valid on
  disk and satisfying its designated requirement.
- Resources: `manifest.json`, exactly the latest c6/s3/p4 `.espdispfw` files,
  plus the app icon and scripting definition. No default combined bundle.
- The installed catalog and three artifacts compare byte-for-byte with
  `firmware-releases/`.
- Installed artifact hashes/sizes equal the table above.

The pure selection suite verifies automatic matching for complete c6/s3/p4
runtime identities and refusal for absent, wrong, stale, duplicate, or
ambiguous evidence. Attached S3 and P4 `CFGSHOW` identities match their embedded
family/profile/partition mappings. Manual UI interaction with the installed
Update Firmware sheet was not performed.

## Review findings

- Platform build facts: owned by `Platform`; exact carrier selectors and
  partition sources remain in internal build/carrier configuration.
- Malformed ETL1 completion poisoning: fixed with validation-before-commit and
  retry coverage.
- Selector conflicts: complete family/profile conflict coverage added.
- ST7703 license: full Apache-2.0 terms included.
- Inclusive wording: authored change set scan found no prohibited terms.
- S3 display-facade smoke: completed; discovered and fixed canonical Doom-linked
  DMA headroom regression; repeated smoke passed.

Review verdict: **source, catalog, packaging, and S3 runtime evidence pass**.
P4 touch remains conditional due intermittent GT911 detection. Physical visual
checks remain unverified where no observer was available.

## Commits

Key task commits, newest last:

- `bf7be87` — `feat(release): Add universal firmware families`
- `5f6adc7` — `test(release): Cross-read family artifacts`
- `f74b6b7` — `fix(release): Complete universal build profiles`
- `becf4a4` — `test(release): Align universal release coverage`
- `fec7358` — `test(release): Update family refusal docs`
- `2e91693` — `fix(release): Preserve S3 DMA headroom`
- `97b9f5e` — `fix(release): Exclude Doom from canonical S3`
- `7ae26c3` — `docs(release): Clarify P4 profile safety`
- `80572c3` — `chore(release): Refresh 1.5.0 family artifacts`
- `caa7939` — `fix(release): Add verified S3 flash capacity`
- `9a455e7` — `fix(release): Update C6 release catalog to match regenerated bundle`

Final bundle source provenance is `caa793925ad552a4dd4a35ac523c594020a2dd7b`.
Final artifact commit is `9a455e741318cd88d44c35728c04fe465aa5256a`.

## Exact unverified items

- Physical visual confirmation of the latest S3 full/partial pattern, color
  order, rectangle placement, and orientation.
- P4 GT911 reliability and touch mapping on the final boot, especially odd
  quarter-turn corners.
- P4 hosted WiFi association, reachable mDNS, UDP receive, ETL1 streaming,
  packet-loss recovery, reconnect behavior, sustained motion tearing, and
  end-to-end app-driven frame updates.
- P4 OTA update/recovery; OTA was off on the observed device.
- Exact P4 C6 coprocessor firmware version and direct coprocessor recovery path.
- Standalone c6-family hardware flashing and physical profile detection.
