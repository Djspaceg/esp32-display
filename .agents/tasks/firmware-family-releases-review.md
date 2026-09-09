# C6 catalog repair aligns canonical and installed family artifacts

The repair commit regenerates the family bundles and updates the catalog so the C6 entry no longer points at stale bytes. Direct size, digest, parser, installed-resource, signature, and process checks pass, and the coder’s report records the broader validation without another full-suite run. The commit is conventionally named and limited to the manifest and three bundles. Watch for: the tracked working tree is not clean and changed during review, so the required clean-state gate fails (**confirmed, blocking**).

**Verdict**: NEEDS_CHANGES

## High-level view

The manifest contains exactly `c6`, `s3`, and `p4`. Each size and SHA-256 matches its artifact, `release-info` resolves the three canonical paths, and `bundle-info` validates every bundle while printing only a five-item release-note count.

The installed app embeds byte-identical copies of the manifest and all three artifacts. Deep strict code-sign verification succeeds, and the expected installed executable is running.

Root `release-notes.md` remains the authored prose source. Its 1.5.0 items follow the steering contract, exact-text searches find no authored duplicates, and the final report records the required Python, Swift, generated cross-read, app-build, and bundle-inspection evidence.

HEAD contains only the intended four release files; `.agents/` is untracked and absent from the commit. The handoff is nevertheless dirty: eight tracked files are modified but unstaged, and one appeared between status snapshots.

<details>
<summary>Issues (1)</summary>

1. **Dirty tracked handoff** — Eight tracked files have unstaged modifications, and `AddDeviceSheet.swift` appeared during the review (**confirmed, blocking**). Preserve those changes in their intended commit or worktree and restore a clean tracked state before rerunning final review.

</details>

<details>
<summary>Details</summary>

### Canonical C6/S3/P4 catalog integrity

`wc -c` reports 1,229,786 bytes for C6, 1,126,106 for S3, and 1,149,130 for P4, exactly matching `firmware-releases/manifest.json`. SHA-256 also matches: C6 is `d440cd59bb441ae9804d94fbbc8555ea9e33fdd71a6319a93ba14cc2cb7863a8`, S3 is `c855dd391de121f02ba5a8a866c02f0539991309baf68f212284344a738d72f7`, and P4 is `d25738918fbae0722aeb43bf23207da6a424821a1cc0b96adf98b47d0c6617fd`. The manifest hash is `6db9bbd348e4837891a1ced7c698c52ed2d7470633a485e065276e33d86027b2`, also matching the final report.

`python3 tools/espdisp.py release-info firmware-releases/manifest.json` exits successfully and emits exactly the C6, S3, and P4 artifact paths. Separate `bundle-info` inspections validate one family image, three blank-device flash parts, contiguous payloads, and nested hashes for each bundle. Each prints `release notes: 5 item(s)` without prose.

### Installed app identity, signature, and running state

`diff -q` succeeds for the source/installed manifest and all three artifact pairs; paired SHA-256 output is identical. `codesign --verify --deep --strict /Users/stepblk/Applications/ESPDisplaySender.app` exits successfully. `pgrep -fl ESPDisplaySender` reports PID 97222 at `/Users/stepblk/Applications/ESPDisplaySender.app/Contents/MacOS/ESPDisplaySender`.

### Release-note source and validation evidence

Root `release-notes.md` starts with exact line `# Release Notes`, has newest-first 1.5.0 and 1.4.2 sections, and gives all five 1.5.0 bullets allowed prefixes and terminal punctuation. Searches for each current item outside the root source return no authored duplicate.

`.agents/tasks/firmware-family-releases-final.md` records 1,255 Python checks, focused Swift bundle/catalog/cross-read/update runs with zero failures, C6/S3/P4 compiles, bundle inspection, independent size and hash checks, signed app installation, byte comparisons, and the running PID. This review repeated only the explicitly requested catalog, bundle, installed-resource, signing, process, and repository-state checks.

### Repair commit is narrow but the tracked handoff is dirty

HEAD `9a455e7` uses Conventional Commits subject `fix(release): Update C6 release catalog to match regenerated bundle`. It contains only `firmware-releases/manifest.json` and the C6, S3, and P4 `.espdispfw` files. `git diff --cached --name-only` is empty, and `.agents/` remains untracked.

The clean-state check fails (**confirmed, blocking**). The final `git status --short` reports modifications to `firmware/display_stream/frame_pipeline.cpp`, `firmware/libraries/espdisp_board/src/panel_init_dsi.h`, `mac/ESPDisplaySender/Sources/SenderCore/AddDeviceSheet.swift`, `mac/ESPDisplaySender/Sources/SenderCore/FirmwareUpdateSheet.swift`, `mac/ESPDisplaySender/Sources/SenderProtocol/FirmwareBundle.swift`, `mac/ESPDisplaySender/Sources/SenderProtocol/UsbOnboarding.swift`, `tools/espdisp.py`, and `tools/test_espdisp.py`. The first snapshot had seven modified tracked files; `AddDeviceSheet.swift` appeared by the second.

</details>

<details>
<summary>File map</summary>

- `firmware-releases/manifest.json` — refreshed catalog metadata.
- `firmware-releases/c6/espdisp-c6-1.5.0.espdispfw` — regenerated C6 bundle.
- `firmware-releases/s3/espdisp-s3-1.5.0.espdispfw` — regenerated S3 bundle.
- `firmware-releases/p4/espdisp-p4-1.5.0.espdispfw` — regenerated P4 bundle.

Full diff: `git -C /Users/stepblk/Source/esp32-display -P diff HEAD^..HEAD`.

</details>
