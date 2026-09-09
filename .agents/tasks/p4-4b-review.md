# ESP32-P4 platform and Waveshare 4B support with family releases

The firmware adds a stronger P4 display path: platform, panel, and carrier data are separated in firmware, while the ST7703 DSI backend, GT911 polling, inverted PWM backlight, eFuse identity, and ETL1 transactional decode have source and attached-board evidence. The prior ETL1 state-poisoning, selector-conflict, license, and S3 hardware-smoke findings were addressed. The implementation is not ready to ship because hosted WiFi cannot associate, the build platform embeds the 4B carrier selector and can infer that carrier from an arbitrary P4 chip, the default macOS package has no canonical release resources to embed, and the universal S3 release removes existing `s3-175` Doom behavior. Watch for: hosted networking unavailable (**confirmed**), P4 chip-only selection of a compile-fixed 4B carrier (**confirmed**), missing canonical app resources (**confirmed**), and the S3-175 Doom regression (**confirmed**).

**Verdict**: NEEDS_CHANGES

## High-level view

The firmware-side ownership split mostly meets the architecture criterion. `platform_config.h` contains runtime chip policy without panel timing or pins, `panel_config.h` owns ST7703 geometry and timing, and `board_config.h` owns GPIO27/26/33/35 plus GT911 GPIO7/8. The build catalog breaks that boundary by storing `-DESPDISP_BOARD_P4_4B` and `partitions_p4_4b.csv` on `Platform("p4")`, then allowing `resolve_family` to choose that compile-fixed image from chip identity alone.

The P4 display, touch, backlight, identity, and ETL1 paths have useful hardware and automated evidence. Hosted C6 communication fails before association, so the central wireless-display path—mDNS, ETL1 over WiFi, reconnect, and OTA—remains unavailable and unvalidated.

The family-release packaging design requires a checked-in catalog and three artifacts for a normal app build. None of those current resources exists in `firmware-releases/`; the only file there is an untracked legacy S3 1.3.0 bundle, so the default `make-app.sh` path fails before Xcode runs.

The universal S3 image compiles all current panel drivers and the recorded CO5300 hardware run exercises shared drawing, orientation, brightness, and power. It also compiles without `ESPDISP_DOOM_S3_175` and installs a partition table without `doom_wad`, removing the existing triple-tap Doom feature from the canonical `s3-175` path. Other S3 profile hardware paths lack current runtime evidence, and the new CO5300 detector omits the controller’s actual `0x5A` address.

<details>
<summary>Issues (7)</summary>

1. **Hosted networking unavailable** — The P4 cannot associate through the factory C6, leaving mDNS, ETL1 over WiFi, reconnect, and OTA blocked (**confirmed**). Establish a compatible, recoverable P4/C6 pairing and complete the network hardware matrix.
2. **P4 platform aliases the 4B carrier** — `Platform("p4")` owns the 4B selector and partition source, and the CLI chooses that compile-fixed carrier from chip identity alone (**confirmed**). Move carrier facts to an exact profile/build layer and require explicit profile evidence until P4 is genuinely runtime-universal.
3. **Canonical app resources missing** — The normal app build requires a catalog plus C6/S3/P4 artifacts, but the repository contains none of the current resources (**confirmed**). Add and verify the canonical 1.5.0 release set, then run the default packaging path.
4. **S3-175 Doom regression** — The universal S3 image omits the Doom selector, entry code, and partition, so triple-tap activation no longer works on the existing CO5300 target (**confirmed**). Preserve the profile behavior or obtain an explicit acceptance-criteria change.
5. **CO5300 detector uses the wrong touch address** — The detector probes `0x15` instead of the CST9217’s `0x5A` on GPIO15/14 (**confirmed**). Correct the signature and add focused address-set coverage.
6. **S3 runtime evidence incomplete** — Only CO5300 has current runtime telemetry, without an independent visual observer; the other three runtime-selected profiles have no current hardware evidence (**confirmed**). Record visible smoke coverage where hardware exists and retain explicit residual gaps elsewhere.
7. **Dead Python safety tests** — Several retained target, flash-part, and preflight tests are no longer invoked and contradict the active family model (**confirmed**). Port or remove them and keep one executable P4 selection contract.

</details>

<details>
<summary>Details</summary>

### P4 build selection still aliases the platform to the 4B carrier

**High — `tools/espdisp.py`, `firmware/libraries/espdisp_board/src/board_config.h`, `tools/test_espdisp.py`, `release-notes.md` — confirmed.** `PLATFORMS["p4"]` owns both `partitions_p4_4b.csv` and `("-DESPDISP_BOARD_P4_4B",)`, and `Family.extra_flags` forwards that platform value into every P4 build. Firmware resolves `COMPILED_VARIANT` directly to `P4_4B`. `resolve_family` probes an unknown USB device, maps `esp32p4` to the sole `p4` family, and authorizes the same compile-fixed image without carrier/profile evidence.

A future non-4B P4 board is therefore unsafe on the CLI path: the tool can select an image that initializes the 4B reset, backlight, BOOT, and GT911 pins solely because esptool reported an ESP32-P4. Adding a second P4 carrier also requires editing the platform row, contrary to the acceptance criterion. The macOS recovery flow requires an explicit profile, but that does not compensate for the CLI.

Move carrier selectors and carrier-specific partition choices out of `Platform`. Keep P4 FQBN/chip/silicon facts at the platform layer, compose the 4B selector at an exact profile/build-target layer, and require explicit `st7703-4b` evidence whenever the artifact is not genuinely runtime-universal. Update the 1.5.0 bullet only in canonical `release-notes.md` if runtime P4 profile selection remains unimplemented.

### Hosted C6 incompatibility leaves the wireless product path unavailable

**Critical — `.agents/tasks/p4-4b-impl-status.md`, `README.md`, `docs/firmware-target-architecture.md`, `To-do.md` — confirmed.** The attached P4 logs `Response not received for [0x15e](Req_GetCoprocessorFwVersion)` and never associates. No evidence exists for reachable mDNS, ETL1 streaming over the actual transport, reconnect, OTA, packet-loss healing, throughput, or DSI tearing under network motion. The limitation is reported accurately and the C6 was left untouched, but wireless display support remains an unmet acceptance criterion.

Establish a compatible and recoverable P4/C6 pairing under separate write authorization, then record association, DHCP/DNS/mDNS, ETL1 motion/loss recovery, reconnect, OTA/update recovery, and throughput/tearing results. Until then, keep the P4 feature blocked rather than presenting working wireless support.

### Canonical firmware resources required by the app are absent

**High — `firmware-releases/`, `mac/make-app.sh`, `mac/embed-firmware-bundle.sh`, `README.md`, `.gitignore` — confirmed.** The normal app build requires `firmware-releases/manifest.json`, validates it with `release-info`, and embeds exactly the catalog’s C6, S3, and P4 artifacts. The worktree has no manifest or current family artifacts; it contains only untracked `firmware-releases/espdisp-firmware-1.3.0-s3.espdispfw`. The status generated valid output under `/tmp`, but did not populate the source-controlled location or record a default app build. `ESPDISP_SKIP_FIRMWARE=1` is a fallback, not the documented release path.

Generate and add the canonical manifest and all three 1.5.0 artifacts, verify their hashes against the catalog, and run normal app packaging. Remove or deliberately migrate the stale 1.3.0 bundle, and collapse the duplicated `firmware-releases` unignore rules in `.gitignore`.

### Universal S3 packaging removes the existing CO5300 Doom path

**High — `tools/espdisp.py`, `firmware/libraries/espdisp_board/src/board_config.h`, `firmware/display_stream/input_button.cpp`, `firmware/partitions_s3.csv`, `firmware/doom/README.md` — confirmed.** The canonical S3 family has no extra compile flags, `board_config.h` rejects `ESPDISP_DOOM_S3_175` on a universal S3 build, and the triple-tap branch is compiled only when that marker exists. The common S3 partition table also has no `doom_wad` entry. Preserving bytes above the first 8 MiB does not restore activation because the running image contains no entry path.

The new Doom README accurately reclassifies the feature as a separate manual developer build, but that remains a functional regression from the existing `s3-175` target. Preserve the profile behavior through an approved runtime/profile packaging design, or obtain an explicit product decision allowing the canonical S3 release to drop it and update the acceptance criteria.

### The CO5300 runtime detector ignores its touch controller address

**Medium — `firmware/libraries/espdisp_board/src/board_detect.h`, `firmware/libraries/espdisp_board/src/board_touch.h` — confirmed.** The CO5300 profile’s CST9217 is defined and used at `0x5A`, but `probeS3` checks `{0x15, 0x34, 0x6A, 0x6B}` on GPIO15/14. `0x15` belongs to the CST816 profiles. The attached CO5300 detected through its PMU or IMU, but a valid `0x5A` touch response alone cannot identify the board, while an unrelated `0x15` response can count toward the wrong profile signature.

Replace `0x15` with `0x5A` for the CO5300 bus and pin the actual per-profile address sets in focused tests. Keep the exactly-one-candidate refusal for conflicting buses.

### Current S3 evidence does not cover every changed runtime profile

**Medium — `.agents/tasks/p4-4b-impl-status.md`, `firmware/libraries/espdisp_board/src/board_detect.h`, `firmware/libraries/espdisp_board/src/panel_init.h` — confirmed.** The universal S3 build succeeds, and the CO5300 run reports frame counters, two orientations, brightness acknowledgements, and power control. It had no independent visual observer, and no current runtime evidence covers GC9107, ST7789-240, or ST77916 detection, panel output, touch, orientation, or brightness after exact builds were replaced by one runtime-selected image.

Record the available S3 hardware matrix, including visible full/partial draws and controls on CO5300 and runtime detection/output on other available profiles. Keep unavailable profiles as explicit residual gaps rather than treating one universal compile as functional evidence for every carrier.

### Passing Python output excludes stale but relevant regression tests

**Low — `tools/test_espdisp.py` — confirmed.** `main()` no longer invokes retained functions including `test_board_table`, `test_resolve_board`, `test_collect_flash_parts`, and `test_bundle_release_notes_preflight_barriers`. Several reference the removed `espdisp.BOARDS` API and contradict the active family contract; one asserts that P4 chip identity never auto-selects a target while the active replacement asserts the opposite. The reported 1,224 checks cover only invoked functions.

Delete or port dead exact-target tests, restore active flash-part and preflight-side-effect coverage against `Family`, and keep one executable statement of the intended P4 selection policy.

### Validation, documentation, and repository assessment

This review used the recorded evidence and did not rerun builds, tests, flash operations, or network operations. The status records 104,183 firmware host checks under ASan/UBSan, 1,224 invoked Python checks, 836 Swift tests, successful C6/S3/P4 family compiles, a generated three-family release catalog, Python bundle inspection, and an independent Swift P4 bundle read. P4 addresses are bootloader `0x2000`, partition `0x8000`, OTA data `0xE000`, and application `0x10000`; the partition table has equal 8 MiB OTA slots.

Attached-board evidence covers ST7703 initialization at 720×720/38 MHz, RGB565 color and edge placement, partial draws, four software transforms, GT911 at `0x5D`, portrait press/release, BOOT rotation, eFuse identity, and backlight power control. ETL1 decodes into scratch before committing reassembly state and has a 40 ms partial-draw path, resolving the prior malformed-retry and complete-frame freeze findings. Quarter-turn capability remains withheld, matching the unverified odd-orientation touch corners.

`FW_VERSION` and the newest release section both use 1.5.0. The four bullets satisfy the source format and their exact prose appears only in `release-notes.md`; `bundle-info` remains count-only. The first bullet’s runtime P4 profile-selection claim is inaccurate until the compile-fixed 4B binding is resolved. No new prohibited terminology was found in implementation-authored source or current plan content; third-party and historical occurrences are outside this change.

</details>

<details>
<summary>File map</summary>

- `platform_config.h`, `panel_config.h`, and `board_config.h` define firmware platform, panel, and carrier composition.
- `display_backend.h`, `panel_init_dsi.h`, and `esp_lcd_st7703/` implement the display facade and P4 MIPI-DPI path.
- `board_touch.h`, `gt911_protocol.h`, and `touch_map.h` implement GT911 probing, polling, release handling, and transforms.
- `large_tile_protocol.h`, `frame_pipeline.cpp`, `net_link.cpp`, and `FrameSender.swift` implement capability-gated ETL1 reassembly, partial drawing, and sending.
- `tools/espdisp.py`, partition CSV files, release-catalog code, and macOS bundle/update sources implement build, packaging, and update selection.
- `board_detect.h`, universal S3 panel linking, and Doom gates contain S3 regression-sensitive changes.
- `README.md`, `docs/`, `To-do.md`, and `release-notes.md` describe architecture, validation, limitations, and canonical release prose.

Full diff: `git -C /Users/stepblk/Source/esp32-display -P diff`, plus untracked files listed by `git status --short --untracked-files=all`.

</details>
