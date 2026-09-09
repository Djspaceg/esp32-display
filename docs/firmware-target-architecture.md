# Firmware family architecture

**Current architecture and extension guide — September 2026**

The release surface contains exactly three firmware families: `c6`, `s3`, and
`p4`. Each `.espdispfw` file contains one family image. There is no combined or
screen-specific release artifact.

## Composition and ownership

Firmware keeps platform, build-target, panel, and carrier facts separate:

- `platform_config.h` owns chip runtime policy: memory, networking topology,
  serial transport, stable identity source, and compatibility tokens.
- `tools/espdisp.py` keeps chip/FQBN/silicon facts in `Platform` and exact
  selector/partition/library composition in `BuildTarget`.
- `panel_config.h` owns controller, bus, geometry, pixel/DSI timing, offsets,
  inversion, glass shape, and rotation support.
- `board_config.h` composes a platform and panel with carrier wiring and
  peripherals. `board::Variant` is the runtime physical profile.
- `targetToken()` reports only the release family. `variantToken()` reports the
  physical profile. `chipToken` and `partitionToken` provide independent
  compatibility evidence.

P4 retains this separation even though one P4 carrier is currently supported.
Its platform contains no ST7703 timing, GT911 behavior, or carrier GPIOs.

## Families and profiles

| Family | Chip | Runtime profiles | Partition compatibility |
| --- | --- | --- | --- |
| `c6` | `esp32c6` | `st7789`, `jd9853` | `default-8m` |
| `s3` | `esp32s3` | `gc9107`, `st7789-130`, `st7789-154`, `co5300`, `st77916` | `universal-8m-ota` |
| `p4` | `esp32p4` | `st7703-4b` | `p4-32m-ota` |

C6 probes its shared I2C bus before panel GPIO initialization. S3 uses 8 MiB
flash identity for the GC9107 carrier and distinct I2C buses on larger-flash
carriers. The `st7789-130` carrier is identified by its QMI8658A at `0x6B` on
GPIO47/48 and overrides the S3 platform's native-CDC default with its CH343
UART bridge on GPIO44/43. S3 accepts automatic detection only when exactly one
compatible profile is found. Zero or multiple candidates leave display and
networking disabled while serial `CFGBOARD` remains available as a recovery
override.

The S3 artifact uses the 8 MiB common-denominator dual-OTA layout and links the
Doom easter egg, runtime-gated to the `co5300` profile. An earlier attempt to
link Doom failed because its static globals consumed the internal RAM SPI DMA
rotation repaint needs; the engine's heavy renderer arrays and mutable tables
now allocate from PSRAM only when Doom starts, so normal streaming keeps its
internal-RAM headroom. Canonical artifacts contain Doom code but no WAD payload;
the WAD is read from a raw flash region on the 16/32 MiB CO5300 carrier.

P4 uses the Arduino `prev3` profile required by the attached revision-v1.3
silicon. `Platform("p4")` contains only reusable chip/toolchain facts; exact
build target `p4-4b` owns `ESPDISP_BOARD_P4_4B`, the 4B partition source, its
reliable CH343 upload speed, and the requirement for explicit `st7703-4b`
carrier evidence before USB writes.

## Runtime identity and selection

Current firmware publishes four independent fields through mDNS and `CFGSHOW`:

- `target=c6|s3|p4` — release family;
- `chip=esp32c6|esp32s3|esp32p4` — processor identity;
- `profile=<runtime profile>` — physical carrier/panel composition;
- `partition=<compatibility token>` — installed flash layout.

The app selects an embedded artifact only when all four fields are present and
agree with `firmware-releases/manifest.json`. Missing identity, unknown values,
wrong chip, wrong family, wrong profile, wrong partition, duplicate resources,
or stale size/hash metadata fail closed.

Blank or recovery USB flows may not have runtime metadata. They require an
explicit hardware-profile choice, then esptool independently verifies the chip
and hardware MAC before writing. P4 chip identity alone never selects the
compile-fixed 4B carrier. Flashing writes listed segments only; it does not
erase the whole chip unless a user explicitly chooses that separate action.

## Canonical release storage

`firmware-releases/manifest.json` is the release catalog. It lists exactly
`c6`, `s3`, and `p4`, with each latest SemVer, relative artifact path, SHA-256,
byte size, chip, runtime profiles, hardware mappings, flash capacities,
partition token, flash addresses, and required identity fields.

Artifacts are versioned and stored by family:

```text
firmware-releases/c6/espdisp-c6-1.5.0.espdispfw
firmware-releases/s3/espdisp-s3-1.5.0.espdispfw
firmware-releases/p4/espdisp-p4-1.5.0.espdispfw
```

`tools/espdisp.py release --output-root firmware-releases` builds the three
files independently and writes the catalog last. Catalog parsing rejects
duplicate JSON members, extra/missing families or fields, invalid SemVer,
non-canonical or escaping paths, incompatible chip/profile/partition metadata,
and stale file size/hash data.

The macOS build copies the catalog and its three referenced files directly from
this directory before signing. It does not build firmware or maintain a second
binary copy under `mac/`.

## Bundle compatibility

Current format-3 writers emit one image with one family target per file. Readers
continue accepting historical format-1, format-2, and multi-target format-3
files so existing OTA/recovery files remain inspectable. Legacy readability
does not permit current writers to produce combined artifacts.

Every current bundle embeds the ordered nonempty release-note items selected
from the root `release-notes.md` section matching `FW_VERSION`. `bundle-info`
reports only availability or item count.

## P4 measured state and limitations

Attached P4 revision-v1.3 testing measured successful full and partial MIPI-DPI
draws, correct RGB primaries and edge/corner placement, four software
transforms, GT911 portrait corner markers/releases, BOOT-driven rotation, and
backlight control. Registering the DPI completion callback before panel
initialization was required to release the first draw buffer; GT911 point
records begin at `0x814F`.

Hosted networking remains blocked before association because Arduino-ESP32
3.3.11 (`esp_hosted` 2.12.11 and `esp_wifi_remote` 1.6.3) receives no response
to `Req_GetCoprocessorFwVersion` from the factory C6. The C6 module exposes a
separate 3.3 V UART on four programming pads; that programmer is not connected
to this host, and the P4 UART cannot recover or identify the C6 image. No C6
write was attempted. ETL1 over WiFi, reachable mDNS, reconnect, OTA, tearing
under motion, and odd-orientation touch corners remain unverified.

## S3 runtime evidence

| Profile | Current evidence | Residual gap |
| --- | --- | --- |
| `co5300` | Runtime detection, frame counters, two rotations, brightness, and power on attached hardware | No independent visual observer for the latest image |
| `gc9107` | Family compile and host profile tests | No attached carrier for current visible smoke testing |
| `st7789-130` | Attached carrier chip/flash probe, unique QMI8658A detection on GPIO47/48, production `CFGSHOW` over CH343, motion initialization, and WiFi association | Visual RGB/offset/backlight/rotation, battery with an attached cell, and sustained streaming checks pending |
| `st7789-154` | Family compile and host profile tests | No attached carrier for current runtime testing |
| `st77916` | Family compile and host profile tests | No attached carrier for current runtime testing |

## Extension rules

1. Add platform facts only to `platform_config.h`, panel facts only to
   `panel_config.h`, and carrier wiring only to `board_config.h`.
2. Add a runtime profile to an existing family only when it can be identified
   before conflicting pins are driven and the universal artifact fits every
   supported flash/memory budget.
3. Return `Unknown` on absent or ambiguous evidence. Keep `CFGBOARD` as an
   explicit recovery override; never choose a profile by resolution.
4. Add profile mappings to both release-catalog implementations and cover every
   conflict pair in host and Swift tests.
5. If a future chip family needs incompatible build or partition facts, add a
   new family only through an explicit release-format decision. Do not encode a
   product or screen size into a release family.

## Verification

Before publishing:

- run `bash firmware/test/run_tests.sh`;
- run `python3 tools/test_espdisp.py`;
- run full Swift tests in `mac/ESPDisplaySender`;
- compile `--family c6`, `--family s3`, and `--family p4`;
- generate the canonical release and inspect every artifact independently with
  `bundle-info`;
- cross-read generated format-3 files in Swift;
- build/install the app, verify its signature, and compare all embedded
  resources to the canonical catalog;
- flash only authorized attached hardware without whole-chip erase, security
  changes, fuse changes, or calibration rewrites;
- record exact hardware evidence and every unverified item.
