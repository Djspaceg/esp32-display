# Firmware target architecture

**Current architecture and extension guide — August 31, 2026**

This document defines how the project represents hardware, selects firmware,
packages release artifacts, and prevents an image for one display from reaching
another display that uses the same microcontroller. It is the source of truth
for adding a board, display, or microcontroller target. Historical design notes
under `docs/` explain how individual features evolved; they do not replace this
guide.

## The short version

The project distributes precompiled firmware. It does not compile a custom
image on an end user's Mac.

A release contains one or more images. Each image claims one or more exact
target keys such as `c6`, `s3-085`, `s3-154`, `s3-175`, or `s3-185`. The
command-line interface (CLI) or Mac app determines the exact target, selects its
image, and flashes the parts already stored in the bundle.

One image may support multiple hardware profiles when the firmware can detect
them safely at runtime. This is why one `c6` image supports both 1.47-inch C6
boards. Hardware that shares a chip but cannot be distinguished safely uses
separate exact targets. This is why the four S3 displays use `s3-085`,
`s3-154`, `s3-175`, and `s3-185`, even though all four report `esp32s3`.

## Vocabulary and ownership

The architecture separates four concepts even though the current
`board::Config` structure stores several of them together:

- **Microcontroller platform** identifies the processor and build environment:
  the Espressif chip token, fully qualified board name (FQBN), flash layout,
  pseudo-static random-access memory (PSRAM) mode, and compiler flags.
- **Display profile** describes the controller, native geometry, bus type,
  pixel clock, offsets, inversion, backlight behavior, and glass shape.
- **Carrier profile** describes how the microcontroller, display, touch
  controller, power controller, motion sensor, reset expander, buttons, and
  status light are wired on one physical product.
- **Exact target** is the stable compatibility key for a precompiled firmware
  artifact. A target is a validated composition of one microcontroller
  platform and one or more safely distinguishable carrier/display profiles.

`board::Variant` and `board::Config` currently represent the validated physical
profile as one composition. This is intentional. Separate conceptual entities
do not imply that every microcontroller can be combined with every display.
Only measured and tested compositions become targets.

An image may serve more than one profile only when it can identify the profile
before it drives pins that conflict, construct the correct controller, derive
its geometry, and remain within the artifact's memory and flash budgets. If any
of those conditions is false, create a separate exact target.

## Current targets

| Target   | Alias | Chip      | Runtime profile(s)         | Geometry | Controller and bus        | Selector                                                   |
| -------- | ----- | --------- | -------------------------- | -------- | ------------------------- | ---------------------------------------------------------- |
| `c6`     | —     | `esp32c6` | `LcdSt7789`, `TouchJd9853` | 172×320  | ST7789 or JD9853 over SPI | USB chip detection, then firmware I2C probe                |
| `s3-085` | —     | `esp32s3` | `LcdGc9107`                | 128×128  | GC9107 over SPI           | User choice when blank; reported exact target when running |
| `s3-154` | —     | `esp32s3` | `TouchSt7789`              | 240×240  | ST7789 over SPI           | User choice when blank; reported exact target when running |
| `s3-175` | `s3`  | `esp32s3` | `AmoledCo5300`             | 466×466  | CO5300 over QSPI          | User choice when blank; reported exact target when running |
| `s3-185` | —     | `esp32s3` | `LcdSt77916`               | 360×360  | ST77916 over QSPI         | User choice when blank; reported exact target when running |

The `s3` alias is compatibility syntax for `s3-175`. It never means any S3
board and must not be used in new automation or documentation.

### Why C6 shares one image

Both C6 products use the same chip, flash layout, and 172×320 protocol
geometry. Before panel initialization, firmware probes the shared I2C bus on
GPIO18/19. A responding touch controller or motion sensor selects
`TouchJd9853`; a silent bus selects `LcdSt7789`. An inconclusive probe resolves
to the touch profile because that direction avoids driving pins known to be
outputs on the touch product. `CFGBOARD st7789|jd9853|auto` provides a measured
recovery override.

This runtime detector is specific to these profiles. It is not a generic rule
that same-chip products should share an image.

### Why S3 uses four images

The S3 products differ in panel geometry, controller, SPI mode or bus shape,
touch wiring, reset topology, power hardware, and memory use. Esptool can
identify the `esp32s3` chip, but it cannot identify the product soldered around
it. No safe runtime probe currently distinguishes the four products before
display pins must be configured.

The build therefore produces four S3 artifacts. `s3-175` links only the CO5300
path. `s3-185` is compiled with `-DESPDISP_BOARD_S3_185` and links only the
ST77916 path. `s3-085` is compiled with `-DESPDISP_BOARD_S3_085` and links only
the GC9107 path. `s3-154` is compiled with `-DESPDISP_BOARD_S3_154` and links
the core ST7789 driver with its 240×240 mode-3 profile. The `s3-085`, `s3-154`,
and `s3-185` targets use the standard partition scheme and no Doom library.
Chip identity alone cannot authorize a flash among them because all four ESP
image headers contain the same `esp32s3` chip identifier.

## Selection and flashing flow

Selection uses the strongest evidence available. It never derives the target
from display resolution and never treats a chip token as an exact S3 target.

### Blank board over USB

1. The Mac app or `tools/espdisp.py` asks esptool for the connected chip and
   hardware identity.
2. `esp32c6` maps unambiguously to target `c6`. After boot, the shared image
   probes which C6 profile is present.
3. `esp32s3` maps to `s3-085`, `s3-154`, `s3-175`, and `s3-185`. The user
   must choose the product model because the blank device has no trustworthy
   display identity.
4. The selected format-3 bundle image supplies the bootloader, partition table,
   OTA initializer, application, and every flash address. The app writes those
   parts in one esptool operation.
5. The app reconnects to the same physical device, sends its name and WiFi
   credentials, and creates a persistent record keyed by the MAC-derived
   hardware ID.

The app selects a prebuilt image; it does not run Arduino compilation during
onboarding. The app still needs the installed ESP32 core because it uses that
core's esptool executable for the serial protocol.

### Board already running this firmware

Current firmware reports three different identities because they answer
separate questions:

- `chip=esp32c6|esp32s3` identifies the processor and cross-checks the ESP image
  header.
- `target=c6|s3-085|s3-154|s3-175|s3-185` identifies the compatible firmware
  artifact.
- `board=st7789|jd9853|gc9107|st7789-154|co5300|st77916` identifies the active
  runtime hardware profile.

The `_espdisp._udp` multicast Domain Name System (mDNS) record carries `chip`
and `target`; `CFGSHOW` exposes the same target plus the active board profile.
The Mac app cross-checks target, chip, physical USB identity, and saved hardware
ID before it authorizes a write. A service disappearing clears its live target
evidence so stale metadata cannot authorize a later update.

### Over-the-air update

An over-the-air (OTA) update writes only the application image. The running
firmware keeps its bootloader, partition table, OTA data, non-volatile storage,
name, and WiFi credentials.

The exact target chooses the application payload. The chip is an independent
cross-check, not the selector. For S3, the CLI and app fail closed when they
cannot discover both a matching exact target and chip, or when discovery is
disabled. This protects `s3-085`, `s3-154`, `s3-175`, and `s3-185` from one
another. The ESP image header protects only cross-chip mistakes such as C6
versus S3; it cannot protect images that share the same S3 chip.

USB remains the recovery path because OTA cannot replace the bootloader or
partition table and cannot reach a board that no longer joins the network.

### Future automatic S3 detection

A future bootstrap or probe image could remove the manual S3 choice only if it
can identify the attached product safely. The probe must run before conflicting
panel pins are driven and must use evidence unique to the carrier or display,
such as a readable controller identifier, an expander, or dedicated straps.
The project must verify that evidence on each supported product and define a
safe inconclusive result. Until then, explicit model selection is safer than a
chip-based guess.

## Firmware bundle format 3

A format-3 `.espdispfw` file starts with `ESPDISPFW3\n` and a fixed 22-byte
header, followed by a JSON manifest and contiguous raw payloads. Readers verify
all offsets, sizes, addresses, and SHA-256 hashes before exposing an image.

Each image carries:

- its build key and chip token;
- `targets`, the exact target keys the image claims;
- the OTA application payload and its flash address;
- the bootloader, partition table, and `boot_app0.bin` parts needed for a blank
  board;
- build metadata including firmware version, timestamp, source commit, dirty
  state, FQBN, and tool version.

Format 3 allows multiple images for one chip because `s3-085`, `s3-175`, and
`s3-185` are all `esp32s3`. Every exact target may be claimed by only one image. One image
may claim multiple targets when those targets have been validated as
byte-for-byte compatible; no format change is needed for that future case.

Compatibility behavior is deliberate:

| Format | Contents                                                   | Supported use                                                |
| ------ | ---------------------------------------------------------- | ------------------------------------------------------------ |
| 1      | Application images selected by chip                        | OTA only                                                     |
| 2      | Application and blank-board parts selected by chip         | USB or OTA where one image per chip is sufficient            |
| 3      | Application and blank-board parts selected by exact target | Current USB and OTA flow, including multiple images per chip |

Current readers accept formats 1, 2, and 3. Legacy `s3` input resolves only to
`s3-175`. New bundles and user interfaces must use exact target keys.

The app package runs `bundle-info --require-all-targets` before embedding a
bundle. A release bundle is incomplete unless it claims `c6`, `s3-085`,
`s3-175`, and `s3-185` exactly once and every payload hash verifies.

## Implementation map

| Responsibility                                                                | Canonical implementation                                                                                                                                          |
| ----------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| CLI target catalog, aliases, compile flags, bundle validation, OTA safeguards | `tools/espdisp.py`: `Board`, `BOARDS`, `BOARD_ALIASES`, `canonical_board_key`, `resolve_board`, `compile_board`, `validate_target_claims`, `verify_ota_target`    |
| Runtime profiles and target tokens                                            | `firmware/libraries/espdisp_board/src/board_config.h`: `Variant`, `Config`, `COMPILED_VARIANT`, `configFor`, `variantFromI2cProbe`, `variantToken`, `targetToken` |
| Per-artifact linked panel drivers                                             | `firmware/libraries/espdisp_board/src/panel_init.h`                                                                                                               |
| Geometry and device identity                                                  | `firmware/display_stream/app_state.h/.cpp` and `chip_identity.h`                                                                                                  |
| Startup selection                                                             | `setup()` in `firmware/display_stream/display_stream.ino`                                                                                                         |
| `CFGSHOW`                                                                     | `firmware/display_stream/serial_config.cpp`                                                                                                                       |
| mDNS metadata                                                                 | `firmware/display_stream/mdns_announce.cpp` (records) and `telemetry.cpp` (capability bits)                                                                       |
| Bundle parsing and exact-target image selection                               | `FirmwareBundle.swift`: `Image.targets`, `image(forTarget:)`, `payload(forTarget:)`, `flashPlan(forTarget:)`                                                      |
| USB request planning                                                          | `UsbOnboarding.swift`: `Request.target`, `UsbOnboardingPlan.make`                                                                                                 |
| User target choice and compatible target filtering                            | `AddDeviceSheet.swift`: `selectedTarget`, `compatibleTargets`                                                                                                     |
| USB and OTA preflight checks                                                  | `PanelManager.swift`: `USBOnboardRequest.target` and CFGSHOW/esptool validation                                                                                   |
| Required app resources                                                        | `mac/make-app.sh`: `bundle-info --require-all-targets`                                                                                                            |

## Extension recipes

Choose the smallest recipe whose safety conditions hold. Do not add a
microcontroller × display Cartesian product. Add only a composition that exists,
has a verified pin map, and can pass the checks below.

### Add a runtime profile to an existing target

Use this path only when the existing artifact can distinguish the new profile
safely at boot and can carry every required driver within its flash and memory
budgets.

1. Add a `board::Variant` and complete `board::Config` entry in
   `board_config.h`. Include geometry, controller, bus, pins, reset topology,
   touch, power, motion, offsets, inversion, and glass shape.
2. Extend `configFor`, storage parsing, operator parsing, and `variantToken`.
   Keep `targetToken` mapped to the existing exact target.
3. Extend the runtime detector. Define the evidence, ordering, timeout, and safe
   inconclusive result. Detection must finish before any profile-specific pin is
   driven.
4. Add or include the panel driver in `panel_init.h`. Keep compile guards narrow
   enough that unrelated fixed targets do not link it.
5. Verify that `PANEL_GEOMETRY`, capabilities, touch transforms, battery data,
   rotation, and mDNS metadata derive from the selected config.
6. Add host tests for the table, detector, tokens, and all safety fallbacks.
7. Compile every profile-sharing target and confirm flash and memory headroom.

No new bundle target or app choice is needed when the image and exact target
remain the same.

### Add an exact target on an existing chip

Use this path when the chip is already supported but runtime detection is unsafe
or the artifact needs different compile-time drivers, geometry, partitions, or
memory settings.

1. Add a canonical `Board` entry to `BOARDS` in `tools/espdisp.py`. Give it a
   stable target key, existing chip token, FQBN, compile flags, and expected
   blank-board parts. Add an alias only for compatibility with shipped syntax.
2. Add the physical `Variant` and `Config` in `board_config.h`. Select it through
   `COMPILED_VARIANT` using a target-specific compiler define and return its
   exact key from `targetToken`.
3. Update `panel_init.h` so the target links only the controller it can select.
4. Update startup code in `display_stream.ino`'s `setup()` and metadata code
   in `telemetry.cpp` / `mdns_announce.cpp` where the new composition needs
   distinct initialization or capabilities (see `docs/code-structure.md` for
   the sketch's module map).
5. Confirm generic Swift bundle and onboarding APIs accept the new target, then
   expose it in `AddDeviceSheet.compatibleTargets` for the detected chip.
6. Add the target to app bundle completeness checks and package resources.
7. Add CLI, Python, Swift, and firmware tests for same-chip disambiguation,
   wrong-target refusal, aliases, and bundle claims.
8. Compile the new target and all existing targets. Build a full format-3 bundle
   and verify that each exact target has one claimant.

`s3-185` is the reference implementation of this recipe: it shares
`esp32s3` with `s3-175` but uses `-DESPDISP_BOARD_S3_185` and a separate
ST77916-only artifact. `s3-085` follows the same recipe on the same chip: it
selects its profile under `CONFIG_IDF_TARGET_ESP32S3 && ESPDISP_BOARD_S3_085`,
links only the GC9107 path (the vendored `esp_lcd_gc9107` driver), and stays on
the standard partition scheme with no Doom library or WAD. `s3-154` uses the
same exact-target mechanism with `ESPDISP_BOARD_S3_154`, the core ST7789 driver,
and its own mode-3 240×240 carrier profile.

### Add a new chip and target

A new microcontroller requires the exact-target work above plus a verified
build platform.

1. Verify the Arduino core's chip token, FQBN, flash size, partition behavior,
   USB transport, PSRAM options, bootloader address, and esptool support from
   real installed sources.
2. Add the chip token and target to `tools/espdisp.py`. Never infer it from USB
   vendor/product IDs or panel resolution.
3. Confirm `chip_identity.h` obtains the token from `CONFIG_IDF_TARGET`. Add a
   fallback token and compile-time assertions only if the new build environment
   needs them.
4. Add the validated carrier/display `Config`, panel driver, target token,
   compile guards, and startup path.
5. Confirm the app's esptool discovery maps the chip to the new compatible exact
   target set and that USB preflight checks the expected physical identity.
6. Build a format-3 bundle and verify all per-chip flash addresses from build
   output rather than copying an address from C6 or S3.
7. Exercise USB onboarding and OTA on hardware, including wrong-chip and
   wrong-target refusals.

#### Example: ESP32-P4 with ST77916

Treat a P4 plus ST77916 product as a new validated composition, not as
`s3-185` with a different processor.

- Create a stable target such as `p4-185` after the product name, geometry,
  wiring, memory, and transport are confirmed.
- Add a P4 `Board` entry with the core's exact `esp32p4` token, FQBN, flash
  parts, and any required compile flags.
- Add a separate `board::Variant` and `Config` even if the glass and controller
  match `LcdSt77916`; the carrier pins, reset expander, pixel clock, USB path,
  and memory behavior are independent facts.
- Reuse the ST77916 driver only after its interface and P4 compatibility have
  been compiled and tested. Do not reuse the S3 pin table.
- Report `chip=esp32p4`, `target=p4-185`, and a distinct board profile token.
- Add `p4-185` to bundle completeness, Mac target selection, and USB/OTA
  preflight tests.
- Verify bootloader and partition addresses from the P4 build output. Never
  assume the C6/S3 addresses apply.

If a second P4 carrier later uses the same artifact and has a safe detector, it
may become another runtime profile under `p4-185`. If it needs a different
artifact, give it another exact target.

## Verification checklist

Complete all applicable checks before publishing an artifact:

- Run `firmware/test/run_tests.sh`.
- Run `python3 tools/test_espdisp.py`.
- Run `swift test` in `mac/ESPDisplaySender`.
- Compile `c6`, `s3-085`, `s3-154`, `s3-175`, `s3-185`, and every new target
  independently.
- Record application size and confirm OTA-slot headroom for each target.
- Build a format-3 bundle; run `bundle-info --require-all-targets`; verify target
  claims, part addresses, sizes, and hashes.
- Package the app and verify that its embedded bundle is the validated file.
- On hardware, test blank-board USB onboarding, runtime profile detection,
  CFGSHOW identity, mDNS `chip` and `target`, and reconnection by hardware ID.
- On hardware, test OTA success and each refusal: missing target evidence,
  exact-target mismatch, chip mismatch, and same-chip wrong target.
- Keep USB recovery available while testing new boot, partition, or panel code.

A host test can validate policy and byte layout. Only hardware evidence can
validate pins, controller identity, reset sequencing, flash behavior, and the
safety of a runtime detector.

## Compatibility and documentation checklist

- Treat canonical target keys as persisted protocol values. Do not rename or
  repurpose them after release.
- Keep aliases narrow and one-way. `s3` means only `s3-175`.
- Keep `chip`, `target`, and `board` semantically distinct in code, UI, logs,
  CFGSHOW, and mDNS.
- Do not authorize same-chip OTA from an ESP image header; it lacks display
  identity.
- Keep format-1 and format-2 readers until an explicit compatibility decision
  removes them. Write format 3 for current releases.
- Use `Image.targets` when one image supports multiple exact targets instead of
  adding a duplicate payload or changing the bundle format.
- Update the current-target table in this guide, the summary in `README.md`, CLI
  help, app labels, and test fixtures in the same change.
- Label research plans and performance diaries by scope; do not let them become
  competing target catalogs.

The architecture should continue to compose hardware facts, but releases should
remain conservative: share an image only where detection is safe and verified;
otherwise publish another exact target and require explicit evidence to select
it.
