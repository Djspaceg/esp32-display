# ADR: Declarative board descriptors

- Status: Accepted
- Date: 2026-09-15

## Context

Board facts were split across firmware tables, detector code, `tools/espdisp.py`,
the release catalog expectations, and Mac update/UI mappings. Adding a board
therefore required repeating identity and hardware facts in several languages.
The difficult values were also the least declarative: color order and byte
order, touch calibration, LED layout, gestures, orientation offsets, IMU axes,
reset topology, backlight polarity, power wiring, and USB/UART bridge details.

The release architecture still requires one artifact per CPU family. C6 and S3
resolve a physical profile before panel GPIO initialization. P4 remains
compile-fixed to one compatible carrier in this change.

## Decision

### Source and schema

One `boards/<board>.toml` file is the authoritative board record. Version 1 is
documented by `boards/schema-v1.json` and validated by
`tools/board_descriptor.py`. The validator also enforces constraints that JSON
Schema cannot express across files:

- board keys, variants, numeric variant values, config symbols, and the
  target/chip/profile/partition identity tuple are unique;
- no two boards claim the same complete detection signature;
- candidate order is unique inside a family and family resolution policy is
  consistent;
- each board's minimum flash is a supported family capacity and is not smaller
  than the family's common layout;
- malformed detection ranges, addresses, policies, and release behavior are
  refused with a named reason;
- exactly one proof board per family has a generated firmware `Config` during
  this staged migration.

The descriptor models fields even when their current consumer is not migrated:
RGB/BGR order, data endianness, pixel depth, touch calibration, LED channel
order/count, gesture thresholds, orientation offsets, mirror support,
quarter-turn support, IMU axes/signs, expander resets, backlight wiring, battery
ADC/AXP facts, and serial bridge facts. Those consumers continue using their
existing code in this pass.

### Generated outputs

Run:

```sh
python3 tools/generate_board_descriptors.py
```

The following files are generated and committed:

- `firmware/libraries/espdisp_board/src/generated_platform_config.h`
- `firmware/libraries/espdisp_board/src/generated_board_variants.h`
- `firmware/libraries/espdisp_board/src/generated_board_identity.h`
- `firmware/libraries/espdisp_board/src/generated_board_configs.h`
- `firmware/libraries/espdisp_board/src/generated_board_config_lookup.h`
- `firmware/libraries/espdisp_board/src/generated_board_detection.h`
- `firmware/libraries/espdisp_board/src/generated_p4_compile.h`
- `tools/generated_board_catalog.py`
- `mac/ESPDisplaySender/Sources/SenderProtocol/GeneratedBoardCatalog.swift`

`python3 tools/generate_board_descriptors.py --check` fails when any generated
file is stale. `python3 tools/test_espdisp.py` runs the same check, and every
`tools/espdisp.py` command refuses to proceed until validation and stale-file
checks pass. This catches a descriptor edit that was not regenerated in CI and
in the supported build path.

The proof conversion generates the JD9853 C6 config, the CO5300 S3 config, and
the P4 4B config. Other carrier `Config` rows remain on the legacy path for this
pass. Identity, detection, Python catalogs, and Mac catalogs are generated for
all boards now.

### Ownership boundaries

The ownership boundaries in `docs/firmware-target-architecture.md` remain:

- platform facts describe chip/runtime/build constraints;
- panel facts describe the controller, interface, geometry, and timing;
- carrier facts describe wiring and attached peripherals.

The descriptor unifies how those facts are expressed and validated; it does not
merge their conceptual ownership. Generated firmware still emits separate
`PlatformConfig`, `PanelConfig`, and carrier `Config` values.

### Detection

Descriptors declare ordered candidate rules, flash bounds, I2C buses and
addresses, reset timing, bus release behavior, tie-break policy, and fail-closed
behavior. `board_detection.h` is the one hardware-free evaluator.
`board_detect.h` only executes the generated electrical plans and records probe
evidence.

C6 retains this exact procedure:

- GPIO20 low for 20 ms, then high, then wait 100 ms;
- start GPIO18/19 at 100 kHz and scan `0x08..0x77`;
- any ACK or I2C-start failure selects JD9853/touch;
- a successful scan with no ACK selects ST7789/no-touch;
- the no-touch result ends `Wire` and floats GPIO18, GPIO19, and GPIO20.

S3 reads flash capacity first. At 8 MiB or less it selects GC9107 without
probing. Larger flash executes the four current 100 kHz probe plans, closes and
floats each bus, and accepts exactly one candidate. Zero or multiple candidates
return `Unknown`, leaving serial-only recovery that accepts `CFGBOARD`.

The generated maximum probe count sizes evidence storage. Adding a C6 or S3
board that reuses supported controllers and buses is therefore a data change,
not an evaluator or lookup change.

### Capacity

One artifact per CPU family remains absolute. A descriptor whose
`capacity.minimum_flash_bytes` is smaller than
`family.common_layout_bytes` is rejected before the supported compile command
runs. The refusal includes the board source, its minimum capacity, the family,
and the common layout size.

### P4 compile-fixed exception

P4 remains compile-fixed. `board_config.h` keeps the existing selector count,
compatible-selector, Doom selector, and family cross-selector `#error` guards.
Inside the accepted P4 4B branch, the generated header emits exactly:

- `ESPDISP_PANEL_ST7703_720X720`
- `ESPDISP_LARGE_TILE_STREAM`
- `COMPILED_VARIANT = Variant::P4_4B`

Runtime P4 composition is not part of this decision.

### Persisted override precedence

Descriptors provide hardware and behavior defaults. Persisted user settings
remain a later layer:

1. The compiled CPU family is the outer constraint. P4 also has a fixed
   compiled carrier.
2. NVS is read before detection and before profile-dependent GPIO setup.
3. On C6/S3, a nonzero `CFGBOARD` value that belongs to the compiled family
   wins over probing.
4. A cross-family stored value is ignored and probing proceeds.
5. `CFGBOARD auto` stores zero and restores automatic detection.
6. Compile-fixed P4 rejects `CFGBOARD`.
7. An unresolved S3 profile initializes no panel, network, or peripheral GPIO
   and accepts only `CFGBOARD` in serial recovery.
8. After profile resolution, `CFGROT` overrides the descriptor orientation
   default; legacy `CFGFLIP` is read only when `rot` is absent.
9. `CFGMIRRORX` remains persisted and DSI continues rejecting it.
10. `CFGFIXEDBL`, `CFGBRIGHT`, and `CFGPOWER` retain their current interaction:
    fixed brightness overrides normal brightness while manual-off/sleep may
    still darken the panel.
11. `CFGRXCORE` remains an S3 receive-task preference, independent of board
    detection.
12. `CFGNAME` and `CFGOTAPW` remain device/user settings layered after board
    defaults. WiFi credential settings are likewise not board facts.

### Identity and adversarial verification

The four firmware identity fields, target/chip/profile/partition, are generated
from descriptors and keep exact fail-closed matching.

Generation does not make update authorization tautological:

- `firmware-releases/manifest.json` remains a separately committed release
  snapshot. This generator neither writes nor updates it.
- `FirmwareReleaseCatalog.swift` compares that committed manifest against the
  generated expected family/chip/profile/flash/partition inputs. A stale or
  contradictory manifest still fails.
- bundle payload size, SHA-256, flash-part roles, addresses, and partition
  layout are verified from the artifact bytes and are not accepted merely
  because a descriptor names the board;
- runtime mDNS/`CFGSHOW` identity comes from the running firmware and is
  compared with the selected committed manifest entry;
- immediately before a USB write, the Mac app still rechecks USB path
  generation, hardware ID, `CFGSHOW` target/chip/profile/partition, esptool
  chip, and esptool MAC. Those observations come from the connected device and
  remain independent of the generated catalog inputs.

The descriptor supplies admissible facts. The committed release artifact and
the device observed at write time must still independently agree with them.

## Consequences

The generated firmware tables are compact constexpr data and a small linear
lookup/evaluator. S3 size is measured before and after this change with the same
Arduino core and compile command; the result is recorded in task evidence.

Adding a supported-family board no longer requires duplicating its identity,
detection signature, Python family catalog, and Swift catalog mappings. A new
controller or backend still requires implementation code, and the remaining
legacy firmware configs and modeled consumer fields will migrate in follow-up
changes.

This change has no user-visible Mac UI change, so no screenshot is required.

No hardware was accessed. Panel bring-up, touch calibration, IMU axes,
backlight polarity, and detection uniqueness on real boards remain unverified
on-device for this change.
