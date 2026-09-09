# Universal c6/s3/p4 firmware releases and catalog-driven app selection

This change replaces screen-specific release artifacts with independent `c6`, `s3`, and `p4` format-3 bundles, a strict canonical catalog, and catalog-driven macOS resource selection. The artifacts, installed resources, P4 configuration split, transactional ETL1 receiver, release-note workflow, and reported validation evidence are substantially complete. Automatic bundled selection checks family, chip, profile, and partition, but manually chosen bundle paths bypass profile/partition checks for OTA and Add Display USB writes. The final report also conflicts with the authored release limitations by claiming P4 association and mDNS after the release notes and documentation declare hosted networking blocked.

Watch for: manual OTA and onboarding compatibility bypasses (**confirmed, blocking**), public exposure of internal `p4-4b` (**confirmed, blocking**), contradictory P4 networking evidence (**confirmed, blocking**), and unreachable Doom helper code left from the prior review (**confirmed, non-blocking**).

**Verdict**: NEEDS_CHANGES

## High-level view

The catalog, canonical directories, filenames, and sole target inside each current bundle use `c6`, `s3`, or `p4`. Direct inspection confirms current file sizes and SHA-256 values match the catalog and installed app byte-for-byte. An internal P4 build key still leaks through a CLI error and architecture documentation.

The automatic catalog path fails closed on incomplete or contradictory identity, hash, size, and resource-set evidence. Choosing a file manually drops the profile/partition checks: OTA reverts to family/chip checks, while Add Display drops the chosen profile and re-probes only family/chip/MAC before writing.

P4 platform policy, ST7703 timing, and 4B carrier wiring remain separate. Selector conflict coverage, the complete Apache-2.0 license, and ETL1 validation-before-commit with corrected-retry coverage satisfy the corresponding prior requirements.

The final report contains the requested USB, flash, runtime, app-install, resource, selection, and test evidence. Its P4 association/mDNS/UDP claim conflicts with release notes and documentation that keep hosted WiFi/mDNS/ETL1/OTA blocked pending C6 compatibility validation.

<details>
<summary>Issues (5)</summary>

1. **Manual OTA compatibility bypass** — Manually selected bundles check only family/chip, so profile or partition mismatches can bypass automatic refusal (**confirmed, blocking**). Apply the full identity predicate to manual bundles and add mismatch tests.
2. **Add Display compatibility bypass** — The USB onboarding request and final write gate discard selected or re-probed profile/partition evidence (**confirmed, blocking**). Carry those fields through preflight and reject incompatible current images.
3. **Public internal P4 name** — CLI and architecture documentation expose `p4-4b` despite the family-only naming requirement (**confirmed, blocking**). Keep the key internal and use `p4` plus profile `st7703-4b` publicly.
4. **Contradictory P4 network status** — The final report claims association/mDNS/UDP while release sources keep hosted networking blocked (**confirmed, blocking**). Align the report with the blocked limitation or update the release source, regenerate artifacts, and revalidate.
5. **Obsolete Doom helper path** — Removed `flash-wad` parser wiring left unreachable helpers that reference deleted exact-target APIs (**confirmed, non-blocking**). Delete the block or redesign it for family/profile semantics.

</details>

<details>
<summary>Details</summary>

### Verification checklist

| # | Requirement | Result | Evidence |
| --- | --- | --- | --- |
| 1 | Family names | **FAIL** | Artifacts, directories, filenames, bundle targets, and manifest keys are exactly `c6`, `s3`, and `p4`, but `tools/espdisp.py:604` emits internal `p4-4b` in a user-visible error and `docs/firmware-target-architecture.md:50` publishes it. |
| 2 | One family per artifact | **PASS** | `bundle-info` reports one image and one family for each current file; the writer requires exactly one `--family`. |
| 3 | Manifest/artifact hash consistency | **PASS** | C6: 1,229,786 bytes / `d440cd59bb441ae9804d94fbbc8555ea9e33fdd71a6319a93ba14cc2cb7863a8`; S3: 1,126,106 / `c855dd391de121f02ba5a8a866c02f0539991309baf68f212284344a738d72f7`; P4: 1,149,130 / `d25738918fbae0722aeb43bf23207da6a424821a1cc0b96adf98b47d0c6617fd`. |
| 4 | Canonical-copy uniqueness | **PASS** | The three 1.5.0 releases exist only under `firmware-releases/`; the generic Swift parser fixture is not a release copy, and `.build` entries are generated resources. |
| 5 | App resource embedding | **PASS** | The build phase validates the canonical catalog and copies its three references. Installed catalog and artifacts match canonical files byte-for-byte. |
| 6 | Safe auto-selection | **FAIL** | Automatic catalog selection is strict, but manual OTA ignores profile/partition at `FirmwareUpdateSheet.swift:631` and `:879`; Add Display drops those fields before the write gate at `PanelManager+UsbConfig.swift:309`. |
| 7 | P4 platform/panel/carrier separation | **PASS** | Platform facts, ST7703 timing, carrier wiring, and build composition occupy separate layers. |
| 8 | ETL1 transactional validity | **PASS** | `onRecordIfValid` validates before mutating completion state; coverage rejects a malformed record, accepts its retry, and completes after the next valid tile. |
| 9 | Release-note compliance | **PASS** | Root `release-notes.md` satisfies the source contract with no prose duplication. Bundles contain five ordered items, `bundle-info` prints counts only, and reported Swift coverage includes literal rendering, legacy fallback, and duplicate-key rejection. |
| 10 | Hardware evidence | **PASS** | The report records S3/P4 ports, USB identities, chip/MAC/flash facts, exact flash commands and addresses, verification, CFGSHOW identity, runtime behavior, and residual limitations. |
| 11 | Build/install evidence | **PASS** | The report records `~/Applications/ESPDisplaySender.app`, version 1.1/build 2, signing, resources, and selection results; installed resources match the final canonical set. |
| 12 | Test evidence | **PASS** | The report records firmware host 104,195 checks, Python 1,255 checks, focused Swift 158 tests, full Swift 841 tests, generated c6/s3/p4 cross-read, three compiles, and per-artifact `bundle-info`. No suite or build was rerun in this pass. |
| 13 | Inclusive language | **PASS** | A changed-source scan found no prohibited terms. |
| 14 | Prior review fixes | **PASS** | Platform facts, complete selector conflicts, full ST7703 license terms, and S3 facade smoke evidence are present; the smoke drove removal of canonical Doom linkage. |
| 15 | Commits | **PASS** | All 11 task subjects follow Conventional Commits. The branch remains ahead of `origin/main`; no push or amended remote history is evidenced. |
| 16 | Known limitations | **FAIL** | Final-report lines 155–170 claim P4 association, mDNS, and UDP, while `release-notes.md:6`, `README.md:229`, and To-do keep hosted networking blocked and WiFi/mDNS/ETL1/OTA unverified pending C6 compatibility. |

### Manual OTA selection drops profile and partition safety

**High — confirmed, blocking.** Automatic loading uses `ReleaseSet.select`, but `chooseFile` reads a bundle directly; `plan(_:)` and `startPush` then verify only family and chip. A profile or partition mismatch rejected automatically can therefore be accepted after selecting the same file manually. For OTA, the partition token is evidence that the running layout can accept the application image. Route manual current-format bundles through the family/chip/profile/partition predicate and add tests proving the file picker cannot override either refusal.

### Add Display discards explicit and detected compatibility evidence

**High — confirmed, blocking.** The bundled recovery UI collects `selectedProfile`, but `USBOnboardRequest` carries only bundle, target, chip, and MAC. Manual files clear `bundledReleases`, hide the profile picker, and may use a current device's family to select an image. The final gate checks target/chip/flash parts but discards re-probed CFGSHOW profile/partition, so a compile-fixed P4 image can be written to a same-family device that automatic selection would reject. Carry explicit recovery profile evidence into the request, retain CFGSHOW profile/partition through the last pre-write probe, enforce current image metadata, and cover both mismatch cases.

### Internal P4 build key leaks through public surfaces

**Medium — confirmed, blocking.** `BuildTarget("p4-4b")` may remain internal, but `_validate_flash_profile` includes it in a user-visible refusal and the architecture guide names it. Change the diagnostic to say family `p4` requires profile `st7703-4b`, and describe the documentation layer without publishing the internal key.

### P4 networking status is internally contradictory

**Medium — confirmed, blocking.** The final report says P4 associated at `192.168.8.195`, announced mDNS, and started UDP after the coprocessor-version warning, then omits hosted WiFi and mDNS from its exact-unverified list. The release note embedded in all three artifacts and the README/To-do state that hosted networking remains blocked. Under the checklist, record those log lines without treating them as validated availability and keep C6-hosted WiFi, mDNS, ETL1, reconnect, and OTA blocked/unverified. If the behavior is now supported, update the sole release-note source and all limitation documentation, regenerate the bundles, and repeat required validation.

### Removed flash-wad command still leaves broken dead code

**Low — confirmed, non-blocking.** The prior review issue remains: `flash-wad` is absent from the parser, but `cmd_flash_wad` reads nonexistent `args.board`, compares a family key with removed `s3-175`, and `_verify_installed_doom_partition` indexes nonexistent `FAMILIES["s3-175"]`. Delete the unreachable block or redesign it around family `s3`, explicit `co5300` evidence, and the developer-only partition contract.

</details>

<details>
<summary>File map</summary>

- `tools/espdisp.py`, `tools/test_espdisp.py`, and `firmware-releases/` — family builds, writers, catalog validation, and artifacts.
- Board and ETL1 firmware/tests — runtime profile selection, P4 composition, and transactional receive state.
- Swift catalog/update/onboarding code and tests — resource selection and USB/OTA preflight.
- App build scripts and Xcode project — canonical embedding and installation.
- Release notes, documentation, and final report — public naming, evidence, and limitations.

Full diff: `git -C /Users/stepblk/Source/esp32-display -P diff e47b7b2..HEAD`.

</details>
