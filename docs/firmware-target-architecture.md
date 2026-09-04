# Firmware family architecture

**Current architecture and extension guide — September 2026**

The release surface contains exactly three firmware families: `c6`, `s3`, and
`p4`. Each `.espdispfw` file contains one family image. There is no combined or
screen-specific release artifact.

## Composition and ownership

Firmware keeps platform, panel, and carrier facts separate:

- `platform_config.h` owns chip, build profile, flash/partition identity,
  memory, networking topology, serial transport, and device identity source.
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
| `s3` | `esp32s3` | `gc9107`, `st7789-154`, `co5300`, `st77916` | `universal-8m-ota` |
| `p4` | `esp32p4` | `st7703-4b` | `p4-32m-ota` |

C6 probes its shared I2C bus before panel GPIO initialization. S3 uses 8 MiB
flash identity for the GC9107 carrier and distinct I2C buses on 16 MiB
carriers. S3 accepts automatic detection only when exactly one compatible
profile is found. Zero or multiple candidates leave display and networking
disabled while serial `CFGBOARD` remains available as a recovery override.

The S3 artifact uses the 8 MiB common-denominator dual-OTA layout. Profile-only
payloads that do not fit every S3 carrier, including the large Doom WAD
partition, are not part of canonical releases.

P4 uses the Arduino `prev3` profile required by the attached revision-v1.3
silicon. Its internal 4B carrier selector is a build implementation detail, not
a release family or filename.

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
and hardware MAC before writing. Flashing writes listed segments only; it does
not erase the whole chip unless a user explicitly chooses that separate action.

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
3.3.11 receives no response to `Req_GetCoprocessorFwVersion` from the factory
C6. The coprocessor was not modified. ETL1 over WiFi, reachable mDNS, reconnect,
OTA, tearing under motion, and odd-orientation touch corners remain unverified.
The C6 coprocessor is not electrically accessible through the currently
authorized development path, so its firmware version and compatibility remain
blocked rather than awaited.

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
