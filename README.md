# esp32-display

Turn supported ESP32 display boards into small wireless displays driven by a
native macOS app. The repository contains firmware, wire protocols, a signed-app
build, USB onboarding, OTA updates, and canonical precompiled releases.

## What it does

- Streams dirty RGB565 bands or tiles over UDP.
- Uses packed/RLE bands on smaller displays, tile codecs on the 466×466 round
  AMOLED, and capability-gated ETL1 large tiles on 720×720 P4.
- Discovers panels through `_espdisp._udp` mDNS records.
- Supports brightness, power, rotation, identify, restart, touch gestures,
  battery telemetry, status screens, and password-protected OTA.
- Onboards blank boards over USB with explicit identity checks.
- Packages current firmware as one artifact per chip family.

## Firmware families

Release families are exactly `c6`, `s3`, and `p4`. Every family is universal
within its currently supported chip-family profiles. Product names, panel names,
and internal build-target keys are not release names.

| Family | Chip | Runtime profiles | Canonical partition |
| --- | --- | --- | --- |
| `c6` | `esp32c6` | `st7789`, `jd9853` | `default-8m` |
| `s3` | `esp32s3` | `gc9107`, `st7789-130`, `st7789-154`, `co5300`, `st77916` | `universal-8m-doom-ota` |
| `p4` | `esp32p4` | `st7703-4b` | `p4-32m-ota` |

The S3 image uses an 8 MiB common-denominator dual-OTA layout and contains all
supported S3 panel, touch, power, and peripheral paths, including the
runtime-gated Doom easter egg for the CO5300 (`co5300`) profile. Doom's heavy
renderer state and mutable engine tables allocate from PSRAM only when it
starts, so normal streaming keeps the internal RAM its SPI DMA rotation repaint
needs. The canonical artifact and app resources carry Doom code but no WAD; the
WAD stays a developer-installed payload read from a raw flash region on the
16/32 MiB CO5300 carrier.

P4 keeps platform, internal build-target, panel, and carrier configuration
separate. The P4 platform owns chip/toolchain/memory/network facts; the current
internal composition owns its carrier selector and partition source; the ST7703
panel profile owns MIPI timing; and the carrier profile owns GPIOs, GT911, and
backlight wiring. The released artifact remains named only `p4`.

See [firmware family architecture](docs/firmware-target-architecture.md).

## Runtime profile selection

Profile selection occurs before panel GPIO initialization.

- C6 probes the shared GPIO18/19 I2C bus. A responding touch/motion path selects
  `jd9853`; a silent bus selects `st7789`. An inconclusive C6 probe uses the
  electrically safer profile.
- S3 identifies the 8 MiB GC9107 carrier by flash capacity, then probes distinct
  I2C buses on larger-flash carriers. The `st7789-130` profile uses the
  QMI8658A at `0x6B` on GPIO47/48 and routes CFG commands through its CH343
  UART bridge; existing S3 profiles retain native USB CDC. Exactly one
  compatible candidate is required.
- P4 currently has one compatible runtime profile. The internal carrier
  selector remains a build implementation detail and the artifact is `p4`.

Zero or multiple S3 candidates leave display, networking, and streaming
disabled. Serial remains active so `CFGBOARD <profile>` can provide an explicit
recovery override. `CFGBOARD auto` clears the override.

Current firmware reports independent identity evidence:

```text
target=c6|s3|p4
chip=esp32c6|esp32s3|esp32p4
profile=<runtime profile>
partition=<compatibility token>
```

The Mac app requires all four fields to auto-select embedded firmware. Missing,
unknown, conflicting, or stale evidence fails closed.

## Canonical releases

Canonical firmware is committed under `firmware-releases/`:

```text
firmware-releases/manifest.json
firmware-releases/c6/espdisp-c6-<version>.espdispfw
firmware-releases/s3/espdisp-s3-<version>.espdispfw
firmware-releases/p4/espdisp-p4-<version>.espdispfw
```

The catalog lists each latest SemVer, relative path, SHA-256, byte size, chip,
profiles, hardware mappings, flash capacities, partition compatibility, flash
addresses, and required identity fields. Catalog and bundle readers reject
duplicate JSON member names.

A current `.espdispfw` contains one family only. Historical multi-target bundles
remain readable but current writers never produce one.

Generate all three build-numbered development artifacts and their local catalog:

```sh
python3 tools/espdisp.py release
```

This writes under the ignored `firmware-dev/` root. Build-numbered firmware is
never allowed under `firmware-releases/`, so a development run cannot replace
the committed shipping catalog with paths to ignored artifacts. Shipping cuts
use bare versions under `firmware-releases/` after the user bumps `FW_VERSION`;
the current build-numbered writer is development-only.

Inspect each artifact independently:

```sh
python3 tools/espdisp.py bundle-info firmware-releases/c6/espdisp-c6-1.5.0.espdispfw
python3 tools/espdisp.py bundle-info firmware-releases/s3/espdisp-s3-1.5.0.espdispfw
python3 tools/espdisp.py bundle-info firmware-releases/p4/espdisp-p4-1.5.0.espdispfw
```

`bundle-info` reports release-note availability or count, never the prose.
`release-notes.md` at the repository root is the sole authored source for that
prose.

## Build firmware

Install `arduino-cli` and the Espressif Arduino core, then build by family:

```sh
python3 tools/espdisp.py compile --family c6
python3 tools/espdisp.py compile --family s3
python3 tools/espdisp.py compile --family p4
```

The CLI stages custom partition files in private temporary sketch copies. It
does not mutate `firmware/display_stream/partitions.csv`.

## Flash over USB

List connected ports and optionally probe chip identity:

```sh
python3 tools/espdisp.py list --probe
```

Flash one family. Supplying `--port` is required when more than one candidate is
connected:

```sh
python3 tools/espdisp.py flash --family s3 --port /dev/cu.usbmodem1101
python3 tools/espdisp.py flash --family p4 --profile st7703-4b \
  --port /dev/cu.usbmodem5B901669681
```

`flash` verifies `firmware-releases/manifest.json` and writes the selected
committed family artifact. It does not compile mutable local source; use
`compile` or `bundle` explicitly for development builds.

The normal flash path writes only the bootloader, partition table, OTA
initializer, and application segments. It does not issue a whole-chip erase,
change fuses/security settings, or rewrite calibration data.

## Serial configuration

Send one `CFG*` command with the stdlib-only CLI:

```sh
python3 tools/espdisp.py config --port /dev/cu.usbmodem1101 CFGSHOW
python3 tools/espdisp.py config --port /dev/cu.usbmodem1101 CFGBOARD co5300
python3 tools/espdisp.py config --port /dev/cu.usbmodem1101 CFGPOWER 0
python3 tools/espdisp.py config --port /dev/cu.usbmodem1101 CFGROT 2
python3 tools/espdisp.py config --port /dev/cu.usbmodem1101 CFGMIRRORX 1
python3 tools/espdisp.py config --port /dev/cu.usbmodem1101 CFGFIXEDBL 255
```

`CFGMIRRORX` persists a left/right reflection for prism installations.
`CFGFIXEDBL 1..255` locks every lit state at that level and stops advertising
brightness controls; `CFGFIXEDBL 0` restores normal brightness behavior.

WiFi and names use base64-safe helper flows in the app. OTA stays disabled until
a password is stored:

```sh
python3 tools/espdisp.py set-password --port /dev/cu.usbmodem1101
```

## OTA

OTA requires live mDNS evidence for matching family, chip, profile, and
partition. Discovery cannot be disabled for a family-safe push.

```sh
export ESPDISP_OTA_PASSWORD='<password>'
python3 tools/espdisp.py ota panel.local --family s3
```

OTA writes the inactive application slot. It does not replace bootloader or
partition metadata. USB remains the recovery path.

## macOS app

Build and install to `~/Applications/ESPDisplaySender.app`:

```sh
mac/make-app.sh
```

The Xcode build phase validates `firmware-releases/manifest.json` and copies
exactly its latest c6/s3/p4 artifacts directly into the app before signing. No
second repository copy exists under `mac/`.

A development fallback can build without firmware resources:

```sh
ESPDISP_SKIP_FIRMWARE=1 mac/make-app.sh
```

For a discovered panel, the update sheet auto-selects only from complete runtime
identity. For a blank/recovery board, the Add Display sheet requires an explicit
hardware-profile choice, then rechecks chip and MAC with esptool before writing.
Wrong family/chip/profile/partition, absent identity, ambiguous resources, and
catalog size/hash drift are refused.

Release notes are rendered as literal text. Legacy bundles receive accessible
fallback text, and note metadata never affects transfer or update-safety logic.

## Protocols

### Band stream

The classic six-byte header contains frame ID, band index/orientation flags, and
dirty count. Packed datagrams may carry multiple raw or RLE565 bands.

### Tile stream

The CO5300 profile uses 16×16 dirty tiles with raw, RLE565, BC1, and
half-resolution BC1 codecs. Visible-span records avoid transmitting hidden
pixels outside round glass.

### ETL1 large tiles

The P4 profile advertises `CAP_LARGE_TILE_STREAM`. ETL1 uses 16-bit tile indices
for grids too large for tile v1. Records are validated and decoded before
completion state is committed, so malformed records can be retried without
poisoning frame state.

## P4 measured state

Attached revision-v1.3 hardware identified as ESP32-P4, base MAC
`e8:f6:0a:e0:b5:5a`, with 32 MiB flash. Display diagnostics measured correct
RGB primaries, edges/corners, full and partial draws, four software transforms,
GT911 portrait markers/releases, BOOT rotation, and backlight controls with no
draw errors.

Hosted networking remains blocked at `Req_GetCoprocessorFwVersion` with the
factory C6 image. The C6 coprocessor has not been modified and is not
electrically accessible through the current authorized development path.
Reachable mDNS, ETL1 over WiFi, reconnect, OTA, motion tearing, and touch corners
in odd orientations remain unverified.

## Repository layout

| Path | Purpose |
| --- | --- |
| `firmware/display_stream/` | Main universal-family firmware |
| `firmware/libraries/espdisp_board/` | Platform/panel/carrier composition and display facade |
| `firmware/test/` | Hardware-free ASan/UBSan host tests |
| `tools/espdisp.py` | Build, release, inspect, flash, OTA, and serial CLI |
| `tools/test_espdisp.py` | Python source/parser/writer/catalog tests |
| `firmware-dev/` | Ignored build-numbered artifacts and local catalog |
| `firmware-releases/` | Canonical committed family artifacts and catalog |
| `mac/ESPDisplaySender/` | Native app, protocol readers, and Swift tests |
| `docs/firmware-target-architecture.md` | Family selection and extension rules |
| `docs/code-structure.md` | Module ownership |

## Validation

Run the complete source gate before release:

```sh
bash firmware/test/run_tests.sh
python3 tools/test_espdisp.py
python3 tools/espdisp.py compile --family c6
python3 tools/espdisp.py compile --family s3
python3 tools/espdisp.py compile --family p4
```

From `mac/ESPDisplaySender`, run `swift test`. After generating canonical
artifacts, run `bundle-info` on all three, cross-read them with Swift tests,
build/install the signed app, and compare every embedded size/hash to the
catalog.
