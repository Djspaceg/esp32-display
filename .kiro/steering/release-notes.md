# Firmware release notes

`release-notes.md` at the repository root MUST be the sole authored source of firmware release-note prose. Authors MUST update the section whose exact semantic version matches `FW_VERSION` before producing a bundle. Documentation, fixtures, tests, and source code MAY describe this contract but MUST NOT duplicate a release's prose.

The source MUST be LF-delimited UTF-8 with the exact first line `# Release Notes`. It MUST contain newest-first `## <SemVer 2.0.0>` headings with unique labels. Every release section MUST contain 1–32 single-line bullets. Each bullet MUST begin `- ` and its item text MUST contain 1–280 Unicode scalars, begin `Added`, `Changed`, `Fixed`, or `Removed` followed by a space, and end with `.`, `!`, or `?`. Item text MUST NOT have protocol whitespace at either edge or forbidden control/surrogate scalars. For example, `- Fixed a generic display timing issue.` is valid authoring syntax.

Current format-3 bundle writers MUST validate and embed a nonempty ordered `release_notes` array selected from the current firmware section before compiling. Readers MUST accept an absent key for legacy format-1, format-2, and historical field-free format-3 bundles. A present key MUST satisfy the same item contract; malformed present metadata MUST be rejected. Duplicate semantic JSON member names MUST be rejected. `bundle-info` MUST report only release-note availability or item count, never the prose itself.

The macOS app MUST render decoded notes as literal text with `Text(verbatim:)`; it MUST NOT render Markdown or HTML. The Update Firmware screen MUST provide accessible fallback text for legacy bundles and MUST NOT use release-note metadata to change transfer, target selection, signing, USB, OTA, or update-safety behavior.

Changes to this workflow MUST add focused Python source/parser/precompile and bundle reader/writer coverage, Swift reader and duplicate-key coverage, and Update Firmware presentation coverage. Verify a generated format-3 fixture can be read by Swift, run `python3 tools/test_espdisp.py`, run focused Swift tests, and inspect generated bundles with `bundle-info`.
