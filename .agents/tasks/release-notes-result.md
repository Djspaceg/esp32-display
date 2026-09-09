# Firmware release-notes implementation result

## Final review

**Verdict:** APPROVED

The final review artifact is `.agents/tasks/impl-review.md`; its machine-readable verdict is `.agents/tasks/impl-review-verdict.json`. The sole recorded finding is non-blocking: live Dynamic Type, VoiceOver, and visual-wrapping inspection remains required before release sign-off.

## Commits

The implementation is contained in these two commits, oldest first:

1. `9a64ada41ff33874183e0028164a8f5f149b30f1` — `feat(updates): Add firmware release notes`
2. `f5257e37612f1b3e3f7afd81fbede462469ff29e` — `fix(updates): Cover release-note review gaps`

The commits form a feature commit followed by a fix-forward review-gap commit. Their parent chain retains the prior commits; no immutable predecessor was rewritten or otherwise modified.

## Committed file inventory

`git diff --name-status HEAD~2..HEAD` reports the following exact committed paths:

- Added `.kiro/steering/release-notes.md`
- Modified `README.md`
- Modified `mac/ESPDisplaySender/Package.swift`
- Modified `mac/ESPDisplaySender/Sources/SenderCore/FirmwareUpdateSheet.swift`
- Modified `mac/ESPDisplaySender/Sources/SenderProtocol/FirmwareBundle.swift`
- Modified `mac/ESPDisplaySender/Tests/SenderCoreTests/FirmwareUpdateTests.swift`
- Modified `mac/ESPDisplaySender/Tests/SenderProtocolTests/EsptoolCommandTests.swift`
- Modified `mac/ESPDisplaySender/Tests/SenderProtocolTests/FirmwareBundleTests.swift`
- Added `mac/ESPDisplaySender/Tests/SenderProtocolTests/Fixtures/release-notes-from-espdisp-v3.espdispfw`
- Modified `mac/ESPDisplaySender/Tests/SenderProtocolTests/UsbOnboardingTests.swift`
- Added `release-notes.md`
- Modified `tools/espdisp.py`
- Modified `tools/test_espdisp.py`

The range totals 13 files, 1,459 insertions, and 47 deletions. The implementation task artifacts are not part of this committed file list.

## Release-note authoring and format verification

`release-notes.md` is the sole authored source of the version-specific prose. It has the required exact first line, `# Release Notes`, and a single newest-first section labelled `## 1.4.2`. The validated section contains these two ordered items:

- Added support for the Waveshare ESP32-S3-LCD-0.85 with its GC9107 display profile.
- Added Update Firmware controls that validate an exact firmware target before transfer.

The parser enforces LF-delimited UTF-8, SemVer 2.0.0 headings, unique newest-first labels, one to 32 single-line bullets per section, accepted leading verbs, scalar and whitespace restrictions, and terminal punctuation. It validates the requested version before I/O, prioritizes carriage-return detection over UTF-8 decoding, and performs the documented cardinality, duplicate, ordering, and exact-version checks. Bundle preflight validates the sole firmware version declaration and release source before board resolution, provenance lookup, output creation, temporary-directory creation, or compilation.

The inspected declaration in `firmware/display_stream/app_state.cpp` remains firmware version **1.4.2**. No firmware-version change was made.

## Bundle and manifest behavior

New current format-3 bundle writers require a nonempty validated `release_notes` array selected from the `FW_VERSION` section and embed that ordered metadata before compilation. `bundle-info` reports only availability or count and never prints note prose.

Readers remain backward compatible: an absent `release_notes` key is accepted for legacy format-1, format-2, and historical field-free format-3 bundles. A present key must be a valid bounded ordered string list using the same release-item grammar; malformed present metadata is rejected.

Both Python and Swift readers structurally scan the framed manifest for duplicate semantic JSON member names. Duplicate detection handles either `release_notes` ordering, escape-equivalent names, nested names, control/backslash/supplementary diagnostic escaping, malformed-document precedence, and array-root precedence. After native JSON decoding accepts the full document, a duplicate is rejected before root-object, required-field, image, or payload validation. The deterministic diagnostic is `bundle manifest: duplicate key <key>`.

The recorded generated format-3 fixture was written by the Python tool, then inspected through `bundle-info`: firmware 1.4.2, two release-note items, contiguous payloads, and verified hashes. The fixture is also consumed by Swift reader and Update Firmware presentation tests.

## Update Firmware UI behavior

`FirmwareBundle.releaseNotes` is optional and is `nil` only when the manifest key is absent. `FirmwareUpdateSheet` creates available-notes, legacy-unavailable, and defensive-empty presentation states. It places the release-notes section between bundle information and the existing verdict.

Every available note is rendered with `Text(verbatim:)`, so notes are presented as literal text rather than Markdown or HTML. The visual heading is hidden from accessibility; the section is combined into one accessibility element with an exact composed accessible label. Legacy and empty metadata use separate readable fallback text. Release-note metadata is not used for transfer planning, target matching, eligibility, USB, OTA, signing, or any update-safety decision. Tests confirm a note-bearing bundle retains its ordinary update action and eligibility.

## Tests and recorded results

Tests added or expanded cover the Python release-source parser and diagnostics; firmware-version/release-note preflight precedence and no-side-effects behavior; writer and reader metadata validation; legacy manifests; duplicate-key rejection; deterministic Python-produced format-3 fixture handling; Swift protocol parsing; direct bundle constructor compatibility; and Update Firmware display and fallback presentation.

The requested `impl-status.md` file is not present at its specified path and no replacement was found under `.agents/tasks`. The following outcomes are therefore recorded evidence from the approved final review rather than a fresh execution in this reporting step:

- Python parser and bundle tests passed.
- Focused Swift tests and the full Swift test suite passed.
- Swift build passed.
- Xcode app build passed.
- A generated format-3 fixture was inspected by `bundle-info` with version 1.4.2, two items, contiguous payloads, and verified hashes.

No source files were changed while preparing this result artifact, and the validations were not rerun solely for this documentation update.

## Known unverified physical and visual limitations

Automated coverage does not replace a live macOS accessibility or visual review. The recorded outstanding limitation is that interactive text wrapping, Dynamic Type, and VoiceOver inspection has not been performed. Before release sign-off, perform that manual check in the app. Actual device display and end-to-end firmware transfer behavior were not physically verified by this artifact-writing step. macOS UI behavior also cannot be validated here through a live simulator session.

## Integrity confirmation

- Firmware version remains **1.4.2**.
- The root `release-notes.md` is the canonical release-prose source.
- The implementation commit range is limited to the 13 files listed above.
- The prior immutable commits were retained; no rewrite, amend, rebase, push, or source-file modification was performed for this result artifact.
