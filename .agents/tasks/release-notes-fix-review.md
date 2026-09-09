# Corrected 1.4.2 release-note wording

The correction changes only the second 1.4.2 release-note item, which now exactly matches the required authored sentence and punctuation. A repository-wide exact-text search places that authored prose only in `release-notes.md`; the other match is the task result artifact that records the verification input, not source, documentation, or a fixture. The recorded validation reports all 1,292 Python checks passing and a format-3 C6 bundle whose `bundle-info` output identifies firmware 1.4.2 with two release-note items. The new commit is directly above the two required prior commits and contains only `release-notes.md`; `FW_VERSION` remains 1.4.2. Watch for: No unaddressed behavioral risk is identified in this single-file correction; the bundle validation is assessed from the recorded result artifact as requested.

**Verdict**: APPROVED

## High-level view

The change leaves one canonical authored 1.4.2 section; no source, fixture, or documentation copy carries the corrected prose.

Recorded parser and format-3 bundle validation remain aligned with the unchanged firmware version. The one-file commit boundary preserves the preceding release-note implementation history.

<details>
<summary>Issues (0)</summary>

No actionable findings.

</details>

<details>
<summary>Details</summary>

## Canonical 1.4.2 release-note text

`release-notes.md` has `## 1.4.2` followed by two bullets. The second is exactly `- Added canonical firmware release notes displayed in the Update firmware screen.` It has no extra whitespace, no wording variation, and the required period.

The exact-text scan returned `release-notes.md` and the requested result artifact only. The artifact embeds the finalized section as validation evidence; it is not source code, a test fixture, or authored documentation. No other source, fixture, or documentation file duplicates the 1.4.2 authored text.

## Format-3 release-note embedding

The result artifact records `python3 tools/test_espdisp.py` passing 1,292 checks, generation of `/tmp/espdisp-1.4.2-c6.espdispfw` as a format-3 bundle, and successful `bundle-info` inspection. That inspection reports version `1.4.2` and `release notes: 2 item(s)`, tying the corrected source section to the expected bundle metadata.

## Release-note-only commit atop preserved history

`git -P diff HEAD~1 --name-only` returns only `release-notes.md`. The recent log is `e47b7b2 fix(release): Correct 1.4.2 release notes`, followed by `f5257e3 fix(updates): Cover release-note review gaps` and `9a64ada feat(updates): Add firmware release notes`.

This linear sequence puts the correction commit on top of `f5257e3`, with both specified predecessor commits present. The observed topology and result artifact provide no indication of a push, amend, rebase, reset, or force operation.

## Firmware version remains aligned

`firmware/display_stream/app_state.cpp` still defines `const char *FW_VERSION = "1.4.2";`. The version reported by the recorded bundle inspection is the same value, so the corrected release-note heading remains aligned with the firmware version selection.

</details>

<details>
<summary>File map</summary>

- `release-notes.md` — Corrects the canonical second bullet under the 1.4.2 release section.

Full diff: `git -C /Users/stepblk/Source/esp32-display -P diff HEAD~1 -- release-notes.md`.

</details>
