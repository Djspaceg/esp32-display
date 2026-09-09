# Firmware release notes through packaging and Update Firmware

This change makes root `release-notes.md` the validated source for the firmware version and carries its selected items in current format-3 bundles. The Python writer performs firmware-version and release-note preflight before board resolution, provenance lookup, output creation, or compilation; both Python and Swift readers preserve legacy absent-key behavior while rejecting malformed present metadata. Each reader scans the raw framed manifest for duplicate semantic JSON keys but only acts after native JSON decoding succeeds, preserving malformed-JSON precedence. The Update Firmware sheet presents the validated strings as literal text with a combined accessibility element and does not feed the metadata into update decisions. **Watch for:** the recorded validation lacks an interactive Dynamic Type and VoiceOver session (**confirmed**).

**Verdict**: APPROVED

## High-level view

`release-notes.md` is the only changed file containing the 1.4.2 release prose. Its LF-only, SemVer-ordered source format is enforced by a deterministic parser with stable diagnostic reasons and a defined preflight ordering, so an invalid source fails before compilation can produce a bundle without the corresponding notes.

The manifest remains backward-compatible: no `release_notes` member is interpreted as legacy metadata, while every present member must be a bounded ordered string list following the same item grammar. Duplicate member checking operates independently of the platform decoders and uses a shared safe display convention, preventing first- or last-key decoder behavior from changing a security-relevant validation result.

The app carries notes as optional validated model data and limits their use to the existing sheet. The sheet builds a single literal-text section with an accessible fallback for legacy bundles; plan construction, target matching, USB, OTA, signing, and transfer paths remain outside the metadata flow.

<details>
<summary>Issues (1)</summary>

1. **Interactive accessibility evidence** — the status records that live wrapping, Dynamic Type, and VoiceOver inspection was not performed (**confirmed**). Perform that manual check before release sign-off; no implementation change is indicated by the source or automated fixture coverage.

</details>

<details>
<summary>Details</summary>

### Canonical release source gates bundle creation

The committed root source has the required exact title, a single newest-first `## 1.4.2` heading, LF framing, and two valid release bullets. It is the sole changed source of the release prose; README and steering describe the contract without copying either bullet. `release_notes_for_version` checks requested-version SemVer before I/O, gives CR bytes precedence over UTF-8 decoding, validates the document in line order, and applies cardinality, duplicate-label, ordering, then exact-version selection in the documented order. The `cmd_bundle` preflight validates the sole `FW_VERSION` declaration before opening the release source and completes both validations before any board, provenance, path, temporary-directory, or compiler work.

The Python test additions assert each finite source reason and its complete envelope, the source-precedence conflicts, quoting of hostile scalar values, SemVer prerelease and build-metadata behavior, and the no-side-effects preflight barrier. The inspected firmware declaration remains `1.4.2`.

### Duplicate-safe release metadata across both readers

The Python writer requires nonempty valid notes for new format-3 manifests. Its reader accepts missing metadata in v1, v2, and historical field-free v3 bundles, but validates every present array and item before payload validation. `bundle-info` derives only a count or legacy-unavailable status and never includes release-note prose.

Python and Swift independently perform iterative structural scans of the framed manifest, track decoded names per object, and render duplicate keys with the same safe escapes. Both defer a discovered candidate until their native decoder accepts the complete document, then reject it before root-object, required-field, image, or payload checks. The focused tests cover both `release_notes` duplicate orders, escape-equivalent keys, nested keys, safe control/backslash/supplementary diagnostics, array-root precedence, and malformed-document precedence. The complete duplicate diagnostic is deterministic in both implementations: `bundle manifest: duplicate key <key>`.

### Literal, accessible notes remain outside update safety logic

`FirmwareBundle.releaseNotes` is `nil` only when the manifest key is absent. `FirmwareUpdateSheet` transforms it into available, legacy-unavailable, or defensive-empty presentation copy, inserts the section between bundle information and the existing verdict, and renders every available item through `Text(verbatim:)`. It hides the visual section heading from accessibility, combines the content into one element, and supplies the exact composed accessible label; legacy and empty cases use distinct readable fallback strings.

The Swift fixture is generated byte-for-byte by the Python writer, holds firmware 1.4.2 and ordered generic notes, and is read again by both protocol and Update Firmware presentation tests. The presentation test also confirms a note-bearing bundle retains its normal update action and eligibility. **Not tested:** a live app session for wrapping, Dynamic Type, and VoiceOver; the implementation status explicitly records this as outstanding (**confirmed**).

### Recorded validation and scope

The implementation status records passing Python parser/bundle tests, focused and full Swift tests, Swift build, Xcode app build, and a generated format-3 bundle inspected by `bundle-info` with version 1.4.2, two items, contiguous payloads, and verified hashes. Per the requested review constraints, these runs were inspected rather than repeated.

The two commits are a conventional feature commit followed by a conventional fix-forward commit. Their parent chain retains both protected predecessor commits, no implementation artifact or task file appears in the committed diff, and no staged implementation files were present when the hygiene check was performed. The changed surface is limited to release-note authoring, documentation, bundle parsing/writing, protocol and UI presentation, the fixture, and their tests.

</details>

<details>
<summary>File map</summary>

- `.kiro/steering/release-notes.md` — release-note authoring and compatibility policy.
- `release-notes.md` — canonical 1.4.2 release prose.
- `README.md` — bundle metadata and version-source documentation.
- `tools/espdisp.py` — source parser, preflight, metadata validation, duplicate detection, and count-only reporting.
- `tools/test_espdisp.py` — parser, precedence, manifest, fixture, and preflight coverage.
- `mac/ESPDisplaySender/Package.swift` — protocol-test fixture resource registration.
- `mac/ESPDisplaySender/Sources/SenderProtocol/FirmwareBundle.swift` — optional notes model, validation, and duplicate-key enforcement.
- `mac/ESPDisplaySender/Sources/SenderCore/FirmwareUpdateSheet.swift` — literal accessible Update Firmware presentation.
- `mac/ESPDisplaySender/Tests/SenderProtocolTests/FirmwareBundleTests.swift` — reader, duplicate, legacy, and fixture coverage.
- `mac/ESPDisplaySender/Tests/SenderProtocolTests/EsptoolCommandTests.swift` — direct bundle constructors updated for optional notes.
- `mac/ESPDisplaySender/Tests/SenderProtocolTests/UsbOnboardingTests.swift` — direct bundle constructor updated for optional notes.
- `mac/ESPDisplaySender/Tests/SenderCoreTests/FirmwareUpdateTests.swift` — 1.4.2 fixture-to-presentation and fallback coverage.
- `mac/ESPDisplaySender/Tests/SenderProtocolTests/Fixtures/release-notes-from-espdisp-v3.espdispfw` — deterministic Python-produced v3 fixture.

Full diff: `git -C /Users/stepblk/Source/esp32-display -P diff HEAD~2`.

</details>
