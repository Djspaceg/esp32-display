# Code review records (integrated on main)

Each finished branch keeps its own review record below, whole.

## Code review: boot-mode menu (boot-mode-menu)

Reviewed diff: branch `boot-mode-menu` against its base. One round, by an
independent agent with none of the author's context, given the requirements but
not the author's reasoning. It was asked to hunt correctness bugs, regressions
of the previous Doom path, BOOT-only and touch-only operation, and test quality,
and to verify its claims rather than speculate.

Round 1 returned 2 blocking findings, 2 medium, 3 low, plus a list of things it
checked and found sound. Every finding is dispositioned below. No finding was
waived as wrong.

### Blocking

**R1-1 Any input reset the countdown to 15 s with no ceiling, so a board left
alone could never reach streaming. CONFIRMED by the reviewer's own probe: 200
stray taps outside every control, one every 14 s, held the menu open 47 minutes
and would have continued forever.** This defeated the branch's core requirement.
Scenarios named: a case or bezel pressing the glass, a noisy CST816/GT911
emitting phantom taps (this codebase already carries a wake-swallow mechanism
because of touch noise), a sticky BOOT button. Even one accidental brush turned
the advertised 3 s into 15 s.

FIXED. `bootmenu::Countdown` now keeps an absolute `openedAt_` alongside the
renewable window and expires on either, with `MAX_OPEN_MS` 60 s
(`boot_menu_model.h`). `secondsLeft()` reports the nearer deadline so the title
never promises time the ceiling will not give. Covered by
`strayInputCannotHoldTheMenuForEver` (integration, 200 stray taps) and a model
block that renews input every second for the whole minute and asserts expiry
anyway, including across millis() wrap.

**R1-2 The headline invariant was asserted nowhere. CONFIRMED by mutation: the
reviewer replaced the expiry branch with one that honours the highlight - so a
board left alone with DOOM highlighted boots Doom - and the whole suite still
passed.** Only the highlight-on-row-0 case was covered.

FIXED. `doomHighlightedButLeftAloneStillStreams` moves the highlight to DOOM
with a BOOT press, then idles past expiry and asserts no `doomonce`, no restart,
and `streaming (countdown ended)`. The reviewer's exact mutation now fails it.
Both mutations were re-run after the fix: mutation A (expiry honours highlight)
fails, mutation B (ceiling removed) fails.

A note on R1-2's second mutation: my first version of the stray-input test was
vacuous - its first tap landed at 5 s, after the 3 s window had already closed,
so the test passed with or without the ceiling. Caught by re-running the
reviewer's mutation against it rather than trusting a green. The taps now start
inside the opening window.

### Medium

**R1-3 The documented Quake extension point silently disables the whole menu.**
`bootMenuMayOfferGames()` returned `doomBuild && doomBoard` despite the plural
name, so a Quake-only build would open no menu and its triple press would be
dead; `quakeBuild`/`quakeBoard` were permanently dead fields; and the triple-press
refusal and its info bar sat inside `#if defined(ESPDISP_DOOM_RUNTIME)`, so a
non-Doom game build refused a press in total silence. Today's behaviour was
correct (Quake never appears) - a naming-versus-behaviour trap, not a live bug.

FIXED. `bootmenu::anyGameBuilt()` in the model answers for every game and is the
single place a Quake runtime adds its pair; `bootMenuMayOfferGames()` delegates
to it. The header now says the marker alone is not enough and names
`builtCapabilities()` too. A non-Doom refusal prints `button: no game available
(<reason>)` instead of nothing. Model test covers the Doom-only, Quake-only, and
neither cases, including Doom built but without its data.

This finding got more valuable mid-review: main gained a `quake_pak` partition in
the P4 layout while the review ran, so a Quake runtime is close.

**R1-4 The automatic timed menu is a large, hardware-unverified, user-visible
change on 10 of 13 board profiles.** It adds ~3 s before `WiFi.begin()` on every
power-on and reset, lights the panel at `BL_SURVEY` regardless of a saved low
backlight, and does a `doom_wad_preflight()` flash read and Serial line every
boot where it previously did so only on a triple press.

ACCEPTED, not changed, and surfaced to the human. The 3 s delay and the
preflight read are what an opt-out menu costs, and the brightness matches the
WiFi selector's own convention (that screen is the pattern this reuses). The
reviewer is right that this is the one place real verification is owed, which is
what the unverified residual in DECISIONS.md says; it now also names the per-boot
delay, the backlight, and the 128x128 knob's legibility explicitly. The renders
in boot-menu-screens.png cover every panel shape including that one, drawn by the
firmware's own pixel code, but no panel has shown them.

### Low

**R1-5 The menu-exit check sat after `serviceTouch()`, so one normal-path touch
pass could run before WiFi exists** - a gesture completing in that 10 ms window
would reach `showInfoBar` and `sendTouchEvent` pre-`WiFi.mode()`. Small blast
radius (`hbPort == 0` guards the send) but real. FIXED: the loop breaks between
`handleButton()` and `serviceTouch()` as well as after.

**R1-6 The request-save-failure path skips the signal-survey undo the refusal
path performs.** Correctly identified as pre-existing, not a regression. NOT
fixed as behaviour - it is a separate pre-existing gap and fixing it here would
widen this diff - but it is now covered, so it cannot silently get worse:
`menuRequestSaveFailureStaysNormal` asserts no restart and no flag, and
`doomSaveFailureKeepsTheMenuUp` asserts the menu shows SAVE FAILED and still
ends up streaming. Noted for the human as a residual.

**R1-7 Dead code, misleading names, and the C6's only cost.** All FIXED:
the unreachable C3 early-return in `drawBootMenuScreen` is gone (a C3 build has
no such function) with a comment saying why; `startStreaming()` renamed
`leaveMenuForStreaming()` because it does not start anything;
`runBootMenuIfDue()`'s comment now says "opened" rather than "drawn"; and
`boot_menu_model.h`'s include plus the `TriplePress` tracker - the only bytes the
94%-full C6 image paid - are now inside `#if defined(ESPDISP_BOOT_MENU_RUNTIME)`.
The unreachable `Mode::Quake` case stays: it is the slot the brief asked for.

### What the reviewer checked and found sound

Recorded because these are the properties most at risk in this change, and a
future reader should know they were examined rather than assumed:

- The `ea332f6` WAD-preflight refusal and its signal-survey undo survive intact;
  the 800 ms window is preserved, `surveyBeforeDouble` is still captured before
  `applyShortPressDecision`, and the ordering assertion genuinely constrains it.
- No Doom reboot loop: every automatic reset reason maps to no menu, and
  `doomonce` is still consumed before anything fallible, so a failed
  `initDisplay()` or a Doom panic lands on a normal menu-free boot.
- No watchdog interaction: the menu runs well before `esp_task_wdt_add(NULL)`,
  and its loop yields.
- BOOT-alone and touch-alone both work; the screen shows `BOOT NEXT` /
  `HOLD START` when touch is absent. The new `selectorEntryHold` is correct and
  tested, and incidentally closes a narrow pre-existing WiFi-selector hole where
  holding BOOT past 3 s with no saved presets could toggle panel power.
- Wrap safety is real and tested at the wrap for both `Countdown` and
  `TriplePress`.
- The partially-filled `labels[MODE_MAX]` is never over-read; ASan/UBSan agree.
- Scope held: no wire-protocol, `CFG*`, or bundle-format change, no
  `FW_VERSION` bump, no release-note edit.

### Call sites

No `packages/*` component exists in this repository. Shared symbols this diff
touches, with every call site:

- `doom_check_triple_tap` (was `firmware/doom/src/doom_mode.{h,cpp}`): REMOVED.
  Its only production call site was `input_button.cpp`'s `handleShortRelease`,
  now `bootmenu::TriplePress`. Its only other reference was a fake in
  `test_doom_entry_gate.cpp`, removed with it. `DOOM_TRIPLE_TAP_WINDOW_MS` went
  the same way, its value preserved as `bootmenu::TRIPLE_PRESS_WINDOW_MS`.
  Verified no remaining references by `git grep`.
- `wifiselector::selectorLayout`, `selectorHitTest`, `movedIndex`: unchanged,
  and gain the boot menu as a second read-only caller beside the WiFi selector
  (`ui_screens.cpp` `drawBootMenuScreen`, `boot_menu.cpp` `handleBootMenuTap` and
  `moveBootMenu`). No behaviour change for the existing caller.
- `drawBootMenuScreen` (new, `ui_screens.cpp`): called only from
  `boot_menu.cpp`'s `drawBootMenu`.
- `boot_menu.h`'s entry points: `takeBootMenuRequest` and `runBootMenuIfDue`
  from `display_stream.ino`'s `setup()`; `bootMenuMayOfferGames`,
  `bootMenuOffered`, `requestBootMenuAndRestart`, `bootMenuActive`,
  `moveBootMenu`, `activateBootMenu` from `input_button.cpp`; `bootMenuActive`,
  `moveBootMenu`, `handleBootMenuTap` from `input_touch.cpp`.

### Rounds

1 round. It changed the code (R1-1, R1-3, R1-5, R1-7), the tests (R1-1, R1-2,
R1-6), and DECISIONS.md (D8 gained its measurement; the residual gained the
per-boot cost R1-4 named). No decision was reversed.

## Integration review of p4-hosted-rpc-offloop (on integrate-main-0928)

The branch was based on 93684af; main had since gained app-wifi-orientation, p4-4c-gaps, audio-enable-boards and app-layout-cleanup. Checked in the code before squashing, the branch's two High review findings:

- Fault-injection hook out of release builds: closed. `fault_inject.cpp` compiles its commands only when the gitignored `fault_inject_local.h` defines `ESPDISP_FAULT_INJECT 1`. `compile_board`, which `compile`, `bundle` and `release` all go through, leaves that header out of the staged sketch unless `ESPDISP_FAULT_INJECT=1` is in the environment, and warns when it is in. The integration worktree has no such header.
- Silent-C6 recovery not defeated by its own reconnect: closed. `Supervisor::update` returns on `CoprocessorSilent` before any reconnect branch, so no reconnect restarts its clock; the one restart comes `RADIO_FAULT_RESTART_MS` later. The loop maps a silent C6 to that state ahead of Connected and the disconnected states.

| # | Severity | Finding | Disposition |
|---|----------|---------|-------------|
| I2 | High | app-wifi-orientation's mDNS `ssid` record calls `WiFi.SSID()` on loopTask: in `addMdnsService` (every announce and re-announce) and in `mdnsSsidIsCurrent`, which the loop runs every 5 s while connected. On P4 that is a hosted RPC that can wait 5 s, so two in one pass reach the 10 s loop watchdog, the reboot this branch fixes. The branch's `test_hosted_rpc_budget` failed on the merged tree (mdns_announce.cpp:71 and :117). | Fixed in the squash. `wifi_worker` reads the SSID once per association and after each reconnect or reassociate it runs, only right after an RSSI answer (a silent C6 is not asked), retrying a failed read after `SSID_POLL_MS`; `wifiworker::ssid()` returns that cache. mDNS reads only the cache, and no reading yet counts as current, so the worker's first reading triggers the existing re-announce. Before the worker starts (setup's first announce), `ssid()` reads WiFi.SSID() on the caller, as the worker's requests already do. The budget test went from red to green, plus `testMdnsReadsTheWorkersSsid` (no SSID RPC or wait on the announce, check or restart path; one read per association; silent C6 not asked; failed read retried on the interval, not every pass). |
| I3 | Medium | audio-enable-boards' identity seam test links `telemetry.cpp` without `wifi_worker.cpp`; this branch makes telemetry call `wifiworker::rssi()`, so `run_tests.sh` failed to link. | Fixed: the seam test links `wifi_worker.cpp`, as this branch already did for test_audio. |

Not verified on hardware: the integrated image has not run the 4C scan injection. That re-run is owed to the watchdog worker, which has the bench.

## Code review: loopTask off hosted WiFi RPCs (p4-hosted-rpc-offloop)

One adversarial round by an independent read-only reviewer agent. It had no serial port access and did no flashing; it ran only the host tests. It reviewed `git diff main...HEAD` at 9c3182d. Every finding was then addressed in a4d6e55 and re-verified with the host suite, a four-family compile, and the 4C scan and jam injections on the final build.

| # | Severity | Finding | Disposition |
|---|---|---|---|
| 1 | High | The bench fault hook was switched on just by the presence of the gitignored `fault_inject_local.h`. `espdisp.py` copies the whole sketch, and its dirty check ignores ignored files, so a release built from a bench checkout would quietly accept DIAGC6HOLD and the other commands. DIAGC6VER also made an RPC on loopTask. | Fixed. `staged_sketch_ignores()` leaves the header out unless `ESPDISP_FAULT_INJECT=1`, and the build warns when it is included (tested in `test_fault_inject_switch_stays_out_of_builds`). The source now checks the macro's value, the image prints a boot banner when the hook is in, and DIAGC6VER's RPC runs on a side task. Checked: the regenerated p4 bundle contains no DIAGC6HOLD string. |
| 2 | High | Silent-C6 recovery could be defeated. A reconnect the C6 still accepted cleared the radio fault and restarted the 60 s clock, so the board could loop without ever restarting. | Fixed. New supervisor state `CoprocessorSilent`: no reconnects while in it, a restart 60 s in, and in-flight reconnect results are ignored. Host tested in test_band_protocol.cpp (clock not reset by accepted results; one restart only; recovery clears it). On the 4C: silent at 70 s, restart at 130 s, C6 back afterwards. |
| 3 | Low | The cached RSSI survived a disconnect for up to 10 s, so the idle-reassociate check could act on the old link's reading. | Fixed. The worker drops its sample when not associated (tested). |
| 4 | Low | An unknown RSSI (0) was shown as a real reading, "0 dBm". | Fixed. EINF sends -127 (tested). The panel shows "wifi --", "--" and "no reading". CFGSHOW still prints rssi=0, which was already its failure value. |
| 5 | Low | If the worker failed to start, reconnect requests were dropped for the whole boot. | Fixed. Without a running worker, requests run on the caller, as before the change. The queue is deleted if creating the task fails. |
| 6 | Low | Source-scan gaps: multi-line calls, WiFi.STA and esp_hosted_ spellings, firmware/libraries not scanned, no self-test. | Fixed. The scan is now a regex over comment- and string-blanked text, covers display_stream and libraries, and tests its own matcher against hits and misses. Not done: a per-function allowlist; allowed files are listed with a reason. |
| 7 | Nit | The "other core" comment is wrong on single-core chips, and the survey meter dropped to 1 Hz. | Fixed. Comment corrected; RSSI is sampled every 500 ms. |

Reviewer's "checked and fine" list, kept here: no other hosted RPC remains on loopTask (WiFi.status and localIP are local; mDNS, ArduinoOTA and the CFG handlers make no esp_wifi calls). Calling STA methods from the worker is safe. Fully silent C6: it restarts once about 90 s in. Native-WiFi boards are unaffected. The hook compiles only on P4.

AutoSDE and CRUX were not used: GitHub remote, no CR (see DECISIONS.md, Gate facts).

## Code review: display window layout and reported firmware build (app-layout-cleanup)

Two rounds by an independent agent that did not write the change. Full round texts: code-review-round1.md and code-review-round2.md in the task evidence. Both rounds ran `swift test` (704, 0 failures) and `tools/test_espdisp.py` (1899 checks); round 2 formatted the worst-case CFGINFO line from the real format string (547 bytes).

Acceptance checklist, both rounds: all ten items met (hero density, Orientation with Source, uptime in hero, progress at the bottom of the floating footer, flash errors shown as they happen, ASCII bar gone, screen switch in the Brightness row, error text selectable app-wide, running build in Firmware, Update Firmware in Firmware). Standing rules met: every revision stays installable and labelled Upgrade/Reinstall/Downgrade; src= is ignored by old readers; FW_VERSION and release-notes.md unchanged.

| # | Severity | Finding | Disposition |
|---|----------|---------|-------------|
| R1-1 | Should-fix | Worst-case CFGINFO (~546 bytes) overran the 512-byte line buffer, trimming src= or reading a dirty build as clean. | Fixed: LINE_BYTES 768 (9db91bf); round 2 confirmed 215 bytes spare. |
| R1-2 | Should-fix | mDNS src then EINF of the new version cleared the build for good. | Fixed: build tied to the version it came with (`currentFirmwareSource`). |
| R1-3 | Should-fix | Screen-off footer said "long BOOT hold"; 600 ms rotates, 3 s toggles. | Fixed: wording names three seconds and the shorter hold's effect. |
| R1-4 | Should-fix | Board answering with a dirty build after a clean write passed. | Fixed; round 2 extended it: silence after writing a self-naming image also fails (5e859a1). |
| R1-5 | Should-fix | "Legacy firmware" wording lost for old firmware. | Fixed; round 2 found A below in the fix. |
| R2-A | Should-fix | "Heard from" used lastHeartbeatAt, set before any reply, so Legacy showed on every launch. | Fixed: requires an EINF (5e859a1). |
| R1-6 | Nit | src= spoofable through the SSID on old firmware. | Fixed: src= read only after the plain ssid=. |
| R1-8 | Nit | Repair error text could include esptool's ASCII bar. | Fixed in UsbRescue.lastError. |
| R1-10 | Nit | Add Display dropped a failure if closed mid-run. | Fixed: the manager alert is cleared only while the sheet shows it. |
| R1-7 | Nit | Bundled-firmware cache also caches a failed load. | Left: resources cannot change while the app runs. |
| R1-9 | Nit | Repair progress is not in the floating footer. | Left: it is the form's second section, on screen; DECISIONS D3. |
| R1-11 | Nit | Brightness cannot be changed while the screen is off. | Left on purpose (D2). |
| R1-12 | Nit | git_provenance reports clean when git status fails. | Left: pre-existing tool behaviour, outside this change. |
| R2-B | Nit | "Does not report which build" shows in the gap before the build report arrives. | Left: transient, seconds. |
| R2-C | Nit | A stale mDNS record can overwrite a newer USB answer for the same version. | Left: same version, next CFGSHOW corrects it. |
| R1/R2 | Unverified | Selectable text vs clicks on disclosure labels. | Labels opt out with `.textSelection(.disabled)`; not checked in a live app (none launched). |

## Code review: audio on every capable board (audio-enable-boards)

Two adversarial rounds, each by a separate read-only agent.

### Round 1 (93684af..3c70de2)

The reviewer ran the host tests, the generator `--check`, `test_espdisp.py`, and the p4 and s3 compiles, and re-fetched every pinned vendor source. It found no fail-open path. The wire protocol and the CFG surface are unchanged.

| ID | Severity | Where | Defect | Fate |
|---|---|---|---|---|
| F1 | Medium | `audio_backend.cpp` `start()` on the engine task | The chip-ID re-probe read `Wire` on the engine task, racing loopTask touch/IMU/AXP reads on the unlocked receive buffer. That could cause a phantom tap or rotation, or a stall of up to 1 s. | Fixed in 4edae16: start() uses the cached verdict and does no I2C read. The test failed before the fix. |
| F2 | Low, pre-existing | S3 detection probe on SDA 15 / SCL 14 | It pulled up GPIO15, the 1.85C V2's amp enable. | Fixed in a3d8873: the 1.85C bus is probed first, and the probe on GPIO15 is quietAfterMatch. The runtime test through the `runI2cProbes` seam failed before the fix. |
| F3 | Low | `board_descriptor.py` | A codec bus was accepted beside a touch bus. | Fixed in 4edae16, red-first. |
| F4 | Low | `s3-lcd-085.toml` | The second mic may not be fitted. | Open question: needs a 0.85 on the bench. |
| F5 | Nit | `audio_test.cpp` | The 1.85C CFGERR text is reused for any failed ID. | Kept: the CFG surface must not change. |
| F6 | Nit | `audio_config.h` | New fields were 0/0 when zero-initialized. | Fixed in 4edae16: they default to -1. |
| F7 | Nit | `_validate_audio` | Unverified rows skipped the control-bus pins. | Fixed in 4edae16. |

### Round 2 (a3d8873, the detection reorder)

The reviewer walked every S3 board through the new probe order: every board resolves as before, with no new electrical exposure. It mutation-tested the new tests (all three mutants fail) and reran the identity seam against 93684af (`FAIL ... !started`).

| ID | Severity | Where | Defect | Fate |
|---|---|---|---|---|
| R1 | Low-Medium | `board_detection.h` skip rule, `board_detect.h` | A 1.85C-bus ack now skips the 1.75C probe. A 1.75C touch-interrupt pulse on GPIO11 after the canary check could then read as a 1.85C where before it gave Unknown. | Fixed in 03596ad: the sequence moved into the `addressListEvidence` seam and re-checks the canary after its list. Its test failed at runtime before the trailing check. |
| R2 | Low | `board_descriptor.py` amp-pin rule | Audio boards with no probe (the 0.85) were exempt, so a future 8 MiB probe on GPIO7 would be silent. | Fixed in 03596ad: a probe on such a board's amp enable is refused when its flash range overlaps. The test failed without the rule. |
| R3 | Low | `variantFromS3Probe` | It ignored the skip rules, so a test pinned a both-ack Unknown that the device never produces. | Fixed in 03596ad: it runs `runI2cProbes`. Expectations were updated red-first, plus a check that two buses which each run their own probe still give Unknown. |
| R4 | Info, pre-existing | `espdisp_bootstrap.py` `_forbidden_drive_pins` | Operator bootstrap I2C discovery can still pull up amp enables. | Deferred: bootstrap asks the operator's consent first. Forbidding amp pins would also drop the 1.75C's own 15/14 bus from discovery, as touch-interrupt pins already drop 11/10. |

The reviewer also estimated that a released SDA sits near 0.6 V against R42, which is probably below the NS4150B's high threshold (unchecked against its datasheet). The reorder is kept regardless.

Final gate at bfae637 is green; see gate-full.log.

## Code review: board-reported WiFi and one capture orientation rule

Branch `app-wifi-orientation`, rebased onto main 696d0ae (capture-stall fix). Commits: db67796 fix, b5990f2 round-1 fixes, 697df1b residuals, 0ceed4f network name over WiFi, d85c9ab round-2 fixes, 02e0585 round-3 fixes. There were three adversarial rounds, each by a separate reviewer agent that only read files and ran grep; none opened a port, launched the app or flashed a board. An earlier round-1 run was lost when the app restarted and never reported.

### Causes

**WiFi.**
- `PanelManager.preferredSSID` fell back to `savedNames.first` (PanelManager.swift, `return savedNames.first ?? ""`).
- The only row was the saved-networks picker labelled "Saved WiFi", so the app's first Keychain entry read as the board's network.
- CFGSHOW's `connected=` was parsed but never shown.

**Orientation.**
- Capture.swift `start(display:)`, `start(window:)` and `start(contentFilter:)` set the landscape bit from the Mac source's own shape (`display.width > display.height`, `window.frame`, `contentRect`).
- DeviceSession `followWindow` re-oriented the stream on every window aspect flip.
- Region took the bit from its rectangle, which the app turns with the rotation.
- The firmware reads the bit as a quarter turn (`panelorient::quadrant`). So a wide Screen, Window or picker share arrived sideways at rotation 0, and so did any wide source on square glass.

### Rebase onto 696d0ae

Capture.swift and DeviceSession.swift conflicted, and so did this file and DECISIONS.md.
- **Stall monitor kept whole:** `withCaptureDeadline`, `markWedgedIfExpired`, the `_acceptedStream` gating, `markStreaming` and `TrackedWindow.onScreen` are all kept.
- **The shared reconfigure queue:** region drags and rotation reshapes go through one reconfigure queue. The deadline and the wedge marking now apply to that queue.
- **Window reorient:** reorienting a window's stream when its aspect flips is still removed, because the frame shape follows the rotation.
- **These two records:** in this file and DECISIONS.md, this section and the stall worker's were both new entries at the same point. Both are kept, this one first; taking only this one would have deleted the stall worker's record.
- **Stall tests:** they pass after the rebase.

### Round 1 (whole diff)

| # | Severity | Finding | Disposition |
|---|----------|---------|-------------|
| F1 | Near blocking | On rectangular glass at 0 or 180 degrees, a landscape region was letterboxed. The marquee's Rotate made it worse. | Fixed. `alignRegionToRotation` turns such a region upright, and the marquee hides Rotate on rectangular glass. Three tests. |
| F2 | Non-blocking | "Connected WiFi" kept the `connected=0` read at boot. | Fixed. Replies now decide the row; see R2-1 and R3-1. |
| F3 | Non-blocking | A rotation that changed the frame shape restarted capture. | Fixed. `DisplayCapture.reshape` reconfigures in place, with a restart only as the fallback. |
| F4 | Nit | The offline preview kept the old shape after a rotation reported over USB. | Fixed: the preview is refreshed after the USB ingest. |
| F5 | Nit | An empty `ssid64=` read "Unknown", an old name was never cleared, and three comments were out of date. | Fixed: it now reads "None configured". |
| F6 | Nit | The per-kind tests only checked one rule. | Fixed. Restart decision, alignment and drain tests were added in rounds 1 to 3. |
| F7 | Nit | Overlap with the capture-restart, banner and layout workers. | Accepted, because the fix needs it. The stall conflicts were resolved in the rebase above. |

### Residuals closed (697df1b, red first)

- **Unknown-size preview:** an offline panel whose size is not known now previews in the shape it streams. A region keeps the shape its rotation gave it; any other source uses the rectangular default. Once the size is known, the preview captures at the panel's own size.
- **Silent board:** a board that goes quiet over WiFi now reads "Not connected" (reworked in R2-1).

### Network name over WiFi (0ceed4f, human decision, red first)

- **Firmware:** the mDNS announcement gains an `ssid` entry set from `WiFi.SSID()`. The host fakes now record TXT entries, and `test_audio` checks it.
- **App:** `ServiceMetadata.ssid` is parsed and shown.
- **Rows:** the two rows moved into `WifiNetworkRows`, which is rendered offscreen to wifi-rows.png.

### Round 2 (0ceed4f)

| # | Severity | Finding | Disposition |
|---|----------|---------|-------------|
| R2-1 | Blocking | A reconnect refreshes `lastHeartbeatAt` without any reply, so a silent board flapped to "connected". | Fixed. `FrameSender.replyAge` counts only genuine replies and reaches `lastReplyAt`. Test: `testAReconnectWithNoReplyIsNotTheBoardBeingConnected`. |
| R2-2 | Non-blocking | A cached mDNS name overwrote a newer USB report and was never cleared. | Fixed. `announcedSSID` is a separate field, cleared when the service leaves. Two tests. |
| R2-3 | Non-blocking | A reshape was lost when a reconfigure failed without timing out. | Fixed. On failure the drain rolls back and stops the capture so it is rebuilt. Two tests. |
| R2-4 | Non-blocking | The first frame at the new size was dropped. | Fixed. The new size is expected before the call. Test: `testTheNewFrameSizeIsExpectedWhileTheReshapeIsApplied`. |
| R2-5 | Nit | The firmware comment was wrong, and a join after setup's announce left `ssid` empty. | Fixed. `mdnsSsidIsCurrent()` plus a 5-second re-announce check. Tested on the host. |
| R2-6 | Nit | The render test did not pin the rendering. | Fixed. Changing only the words must change the pixels. |
| R2-7 | Nit | Wording mixed the two sources. | Fixed: "set to" (USB) versus "last on" (announcement). |

### Round 3 (d85c9ab)

| # | Severity | Finding | Disposition |
|---|----------|---------|-------------|
| R3-1 | Medium | Only the 5-second status report recorded replies, so the row said "not connected" while capture waited for its source. | Fixed. Every device event records a reply. Test: `testAHeartbeatEventAloneShowsTheBoardOnWiFi`. |
| R3-2 | Medium | A reshape queued behind a failing region update was dropped. | Fixed. A pending shape change also stops the capture. Test: `testAReshapeQueuedBehindAFailingRegionUpdateStopsTheCapture`. |
| R3-3 | Low | A drain that outlived `stop()` reported success. | Fixed. The stream is read on each pass. Test: `testADrainWithNoStreamLeftDoesNotReportSuccess`. |
| R3-4 | Low | While the board replied, a stale announcement beat a newer USB report. | Fixed. `announcedAt` is stamped only when the value changes. Test: `testAUSBReportNewerThanTheAnnouncementWinsWhileReplying`. |

Every round-3 finding was red before its fix and green after. No fourth round was run on 02e0585.

### Gate at f8e99dd

- **`swift test`:** 742 tests, 0 failures. swift-test.log holds five red runs before the green run: the two bugs, the residuals, the name over WiFi, round 2 and round 3.
- **Firmware host tests:** pass, with two red runs first.
- **Firmware compile:** c3, c6, s3 and p4 all exit 0. c6 is at 93% of its app partition.
- **Tools and bundles:** `tools/test_espdisp.py` passes 1889 checks. The 1.5.0 bundles were regenerated from clean 98e75c7 (firmware.log).
- **Release app build:** succeeded and embeds the new p4 bundle (release-build.log).
- **On the 4C under the port lock** (hardware.log):
  - The board flashed and joined WiFi.
  - Its mDNS record now carries `ssid`, which it did not before.
  - The canonical reflash succeeded.
- **Not confirmed on the app side:** the running app, build 342, had not heard from the board since 14:47.
- **Logs:** in /Users/stepblk/Source/esp32-display-wifi-orient-logs/.
- **After hand-off:** an independent agent must still review this.

## Code review: capture stall detection and restart (capture-stall-restart)

Branch `capture-stall-restart`, `git diff 93684af..HEAD`. One adversarial round by a separate read-only reviewer agent (file reads, `swift build`, `swift test` only; no app launch, no ports) against 9c8d7f2. Every finding was addressed in 5a851cd, and the one gap left in finding 4 in bd068f8. An independent agent must still perform the post-handoff review. This file is the only review artifact: no CRUX, AutoSDE or pull request is used for this repository.

Gate at bd068f8: `swift test` 705 tests, 0 failures (capture-stall-swift-test.log); Release app build succeeded and codesign verifies (capture-stall-release-build.log). Red-first: 7eaba9d fails 12 assertions in 5 tests (capture-stall-red-test.log), and three mutations of the final code each turn the guarding test red (capture-stall-mutation-red.log). The application-filter fix has its own red-first commit, 683e237 (capture-stall-app-filter-red.log). Logs: /Users/stepblk/Source/esp32-display-capture-stall-scratch/.

| # | Severity | Finding | Disposition |
|---|----------|---------|-------------|
| 1 | Blocking (as the incident fix) | The 5 s refresh repaint in `FrameSender.startRefreshTimer` checked only `parked`. While the Mac's displays slept and the system did not (pmset: display off Sep 26 03:17 to Sep 28 09:15, no system sleep), it re-sent the last frame, and the firmware's "a drawn frame implies the Mac is awake" rule relit the panel on the pre-sleep picture. The repaint also ignored pause. | Fixed: `refreshAllowed` skips the repaint while parked, paused, or between ESLP and EWAK. `testRefreshRepaintStopsWhileDisplaysSleepOrPaused`, red under the old gate. The firmware rule is unchanged (residual). |
| 2 | Should-fix | A timed-out ScreenCaptureKit lookup is swallowed by `try?`: it showed "Waiting for the display", dropped a still-valid picker selection after 3 timeouts, restarted a healthy stream as a "display change", and could close a followed window. | Fixed: `DisplayCapture.isUnresponsive` is set by a timed-out fetch. Missing-source paths show `.failed("Screen capture is not responding...")`, a timeout does not count toward `pickerFailures`, is not a display change, and keeps the window stream. |
| 3 | Should-fix | Probe restarts about every 62 s forever on a static source. | Fixed in part: each probe that proves the screen static doubles the wait, 60 s up to 300 s, and activity resets it (asserted in the static-screen test). A screenshot-compare probe was not adopted: it adds a second capture path to keep in sync with the stream's filter and region. |
| 4 | Should-fix | False failures where a fresh stream gives no first frame: locked screen, off-console session, off-screen window, and so on. | Fixed: not live while the session is locked or off console (`CGSessionCopyCurrentDictionary`), or the followed window is not on screen. The stall log line records the last sample's status, sample age and frame count, so the first-frame premise is measured on the first real stall. An application-only picker filter is held while none of its applications owns an on-screen window (bd068f8, red-first in 683e237: `testApplicationWithNoOnScreenWindowRaisesNoFailure`); a failed window lookup counts as visible, so an unresponsive ScreenCaptureKit is still reported. |
| 5 | Should-fix | An `updateRegion`/`reorient`/`retarget` that times out leaves the stream and the capture's sizes out of step, and nothing rebuilds it. | Fixed: a deadline expiry marks the capture stopped, so the watchdog rebuilds it on its next tick. |
| 6 | Should-fix | Tests covered only the model; the static-screen test built its premise into the fake. | Fixed: the fake counts frames through the real `DisplayCapture.carriesNewFrame`, and a fresh stream sends one `.started` then only `.idle`. With the old filter (`.complete` only) that test fails with a false failure (mutation log). Session wiring is now `isCaptureLive` and `stallResponse`, both tested, plus a filter table test. |
| 7 | Nit | A failure stays on screen through a display sleep or pause although nothing is retrying. | Fixed: holding clears it (`.recovered`), the stream stays on probation, and the failure returns after the 10 s grace if still dead. `testHoldClearsAFailureAndItReturnsAfterWake`, red under the old hold. The short "panel answered again" / "Reconnecting" states after a park or a stream death stay until the first frame or the next probation verdict (at most one retry delay); accepted. |
| 8 | Nit | A picker display filter used the main display for the sleep check. | Fixed: the filter's own display ID is used. |
| 9 | Nit | The monitor used the wall clock. | Fixed: `ProcessInfo.systemUptime`. |
| 10 | Nit | A wedged ScreenCaptureKit leaks one task per expired call. | Fixed: after a timed-out fetch, lookups fail fast for 30 s, so at most one call is outstanding per 30 s. |
| 11 | Nit | `withCaptureDeadline` and `DisplayCapture.stream` would not pass Swift 6 strict concurrency. | Not changed: the package is on the 5.9 language mode, and the `stream` access pattern predates this branch. It belongs to the Swift 6 migration. |
| 12 | Nit | A marquee drag during a capture start is overwritten by the start's region, now once a minute. | Fixed: `noteRegionApplied(_:requested:)` keeps a newer `_region` and runs the drain loop to catch up with it. |
| 13 | Nit | Doc comments on `lastSampleAt` and `CaptureStatus.failed` were wrong. | Fixed. |

Checked and held up (reviewer): `break watchdog` label, `withCaptureDeadline` single resume, stale-stream sample and error filtering, late-start cleanup, `stallMonitor` touched only from `run()`, no status flicker on routine probes, and that PanelManager.swift, PanelManager+WifiPresetAutoSync.swift and AppFeedback.swift are untouched.

Not verified: no hardware or live-app run (the human is at the screen). The fix is shown by tests and mutations, not by reproducing the stall.

## Integration review of app-error-banner-auto-clear (on integrate-main-0928)

Independent read of `git diff main...app-error-banner-auto-clear` (main = e95e38e) by the integrator, who did not write it. Checked: every sync, retry, recheck and resolve key is the canonical hardware ID (`usbDevices[].hardwareID` is set canonical; `stableHardwareID` canonicalizes); `forget` cancels the sync and recheck before resolving, and the new `!Task.isCancelled` guard stops a cancelled run from clearing a newer registration; a retry or recheck that finds the board held off waits again; the untagged `report(_:detail:)` callers (`.screenRecording`, `.deviceConfig`) still clear through `resolve(_:)`.

| # | Severity | Finding | Disposition |
|---|----------|---------|-------------|
| I1 | Low | Deleting every saved network while a copy was still running (its last retry, or a write the board refused) let that copy report afterwards. The banner then named a collection that no longer exists, and nothing cleared it: rechecks stop at the empty collection, and only Dismiss removed it. | Fixed in its own commit on integrate-main-0928: a failed copy that finds the collection empty reports nothing. `testACopyFailingAfterEveryNetworkIsDeletedIsNotReported`, red before the fix and green after. |

Not changed: after a reported silence, a board that is unplugged keeps its banner until it is replugged and copies, or is dismissed. This is the branch's stated design.

## Code review: issue banners clear on recovery; slow boards are waited out

Branch `app-error-banner-auto-clear`, `git diff main...HEAD` (main = e95e38e). One adversarial round by a read-only reviewer agent (file reads and `swift test --filter` only; no ports, no app launch). It found no blocking issues. It checked that report and resolve use the same canonical hardware ID, that no second sync can start alongside a retry wait, how flashes interleave with retries, the `!Task.isCancelled` guard, that CFGWIFIUSE is never sent, and all six persistence call sites.

Gate at 6b1784c: `swift test` 421 + 684 tests, 0 failures (swift-test.log); Release app build succeeded (xcodebuild-release.log). Logs are in /Users/stepblk/Source/esp32-display-banner-logs/.

An independent agent must still perform the post-handoff review. This file is the only review artifact: no CRUX, AutoSDE or pull request is used for this repository.

| # | Severity | Finding | Disposition |
|---|----------|---------|-------------|
| 1 | Should-fix | After the last retry fails, nothing tries an attached board again, so a board that recovers later keeps its banner until it is replugged. | Fixed: after a reported silent failure the board is checked again every 60 s while it stays verified, and a success clears the banner. `testABoardThatComesGoodAfterTheReportClearsItsBanner`. |
| 2 | Should-fix | Forgetting a display record leaves its banner entry with no way to clear. | Fixed: `forget` cancels the board's sync and resolves its source. `testForgettingTheRecordWithdrawsItsBanner`. |
| 3 | Should-fix | Timed retries can talk over the preset sheet on the same port, and they ignore repair probe holds. | Fixed: the sheet's read and write mark the board busy. `wifiPresetSyncDevice` returns nil while the board is busy or `usbProbeHolds > 0`, and a waiting retry or recheck waits again rather than being used up. `testARetryWaitsWhileThePresetSheetHasTheBoard`. A sync that was already mid-I/O when the sheet opened still overlaps it (existing behaviour; there is no port lock). |
| 4 | Should-fix | A read failure is cleared by the first save, which overwrites the unreadable file, hiding that its data was lost. | Fixed: read failures have their own sources (`display records (read)`, `app settings (read)`) that only Dismiss clears. |
| 5 | Nit | A retry is lost if the record is renamed during the wait. | Fixed: retries and rechecks look the record up by hardware ID when they fire. |
| 6 | Nit | Failures that cannot succeed are retried, delaying the banner by about a minute. | Fixed: only silence is retried, meaning a send with no CFG reply. A CFGERR refusal or a readback mismatch is reported at once, with no retry or recheck. The test fake now refuses with a CFGERR line, as `sendCommand` does. `testARefusalIsReportedWithoutRetrying`. |
| 7 | Nit | The banner cannot clear once no networks are saved. | Fixed: `syncWifiPresetsToAttachedDevices` resolves `.wifiPresetSync` when the collection is empty. |
| 8 | Nit | Dismiss removes every source at once. | Accepted: it matches the one-button banner, and with 2 fixed no entry needs Dismiss to go away. |
| 9 | Should-fix (test) | The unplug-during-wait test could pass without testing the wait, and it bypassed the real unplug path. | Fixed: it polls until the retry is waiting, then unplugs through `updateUSBPorts([])`. |
| 10 | Nit (tests) | No tests for a flash during a wait, a collection change during a wait, or two boards through the real path. The retry window comment understated the time. | Partly: the comment now says 45 s of waiting, about a minute including timeouts. The reviewer checked (a) and (b) by reading the code; no tests were added for them. |
| 11 | Nit (speculative) | `.screenRecording` resolves only at launch. | Not changed: macOS applies a new grant only after a relaunch, and the banner says to relaunch. `.deviceConfig` is read only at launch, so there is no recovery to detect. |

Not verified: the 4C board (`big-round`) was not opened because another worker holds its port, and the app was not launched. The fix is shown by the red tests (4f1900b, which reproduce the reported banner text) turning green, not by the real board.

## Code review: in-app USB Repair flow and low-power rescue image

Branch `usb-repair-flow`, `git diff main...HEAD` (main = e229bff). Two adversarial rounds by read-only reviewer agents (git and file reads only; no builds, no ports), then one independent review of the squash on main.

### Round 1 (whole diff)

| # | Severity | Finding | Disposition |
|---|----------|---------|-------------|
| 1 | High | esptool, in its own session and retrying forever, outlives the app if it quits or crashes mid-repair, and keeps opening its link's port. | Fixed: esptool runs under a `/bin/sh` watchdog whose watcher reads a pipe that only the app holds. EOF means `kill -HUP 0` on the group. First tried making the pty the controlling terminal; `testTheAppGoingAwayStopsTheWholeTree` showed macOS does not, so that was replaced. |
| 2 | Medium | Probe holds were released between stages, so a background CFGSHOW could collide with Clear Override or Install. | Fixed: `UsbRepairModel` holds probes from Start until Start Over or close. Clear Override is offered again from the failed stage. |
| 3 | Low-med | `kill()` re-signals a reaped pid, reaps once without blocking, and the second-kill test only tested the fake. | Fixed: `finished` guard, bounded reap loop, reap in `deinit`, and the fake records every attempt. |
| 4 | Low | The rescue index accepted an extra role-less region. | Fixed: exact count plus a string role for every entry, as the CLI checks; tested. |
| 5 | Low | The probe-hold test passed without the hold. | Fixed: `portsToIdentify` seam; the test covers two holds and one release. |
| 6 | Low | Returning from Repair reset the Firmware Update form. | Fixed: `prepared` guard, as in AddDeviceSheet. |
| 7 | Low | "Nothing was written" was shown after a partial rescue write; the failure text for a board that was written but lost was wrong. | Fixed: the texts now say the rescue image is safe to rewrite, and to replug then Start Over. |
| 8 | Minor | Clearing could not be stopped. | Fixed: Stop is enabled in `.clearing` and cancellation is forwarded. |

Round 1 found the port-selection loop matches `run_rescue` step for step, and the argv, environment, spawn flags, threading, install checks and embed script sound.

### Round 2 (a116dcf, f533b55, 0407b20)

| # | Severity | Finding | Disposition |
|---|----------|---------|-------------|
| 1 | Low-med | The CO5300 AMOLED leaves its init at 0x51 0xFF and was dimmed only after a successful draw. | Fixed in 7203ccd: dimmed to BACKLIGHT_LEVEL before the draw, and set to 0 if the draw fails; a host test checks the order. Images rebuilt from 7203ccd (6646068). |
| 2 | Low | Stop during Clearing reported "did not answer" after the override had in fact been cleared. | Fixed: after the send, a cancelled run returns "Stopped - override cleared, not re-read". |
| 3 | Low | After a failed clear, the advice said Start Over while the button said Clear Override. | Fixed: the clear failure carries its own next action. |
| 4 | Hardening | No release in `deinit`; `deinit` kill can block; pipe CLOEXEC is not atomic. | Deferred, recorded in DECISIONS.md Residuals (the first); the other two are negligible in practice. |

Round 2 checked the watchdog script in full, the fd lifecycle, hold balance, the safety of GPIO54 on the only P4 profile (pins 27/26/35/7/8/33), `analogWrite` behind the USB-pin guard, and image provenance (source_commit clean, hashes match).

### Independent review of e95e38e (independent-review.md)

| # | Severity | Finding | Disposition |
|---|----------|---------|-------------|
| 1 | Medium | The same-device guard missed real macOS names (usbmodem5B901700691 by serial; usbmodem101 / 1101 / 14101 by location with trailing zero nibbles dropped), so a pre-attached board moved to another socket was written. Tests used made-up names. | Fixed (cf1ab30, 0d46cfe): the IORegistry is asked which USB device publishes the port (`UsbRescuer.usbDevice(forPort:)`); the name fallback uses the real rules, in Swift and in tools/espdisp.py. Red then green: `testRealMacOSPortNamesMapToTheirDevice`, `testARenamedPortOfAnAttachedBoardIsNotNew` (real names), `test_rescue_usb_identity_real_names`; plus `testTheRegistrysDeviceForAPortIsUsedBeforeItsName`. |
| 2 | Medium | A wrong chip family fails fast and relaunched forever, resetting the board every few seconds. | Fixed: 3 failed writes in a row on one port, or esptool's "Wrong --chip argument?" once, refuses the port with "is it an ESP32-X board?". Red then green: `testAWrongChipFamilyIsGivenUpInsteadOfResetForever`, `testRepeatedWriteFailuresOnOnePortAreGivenUp`. |
| 3 | Medium | An unidentified board reports profile=auto target=unknown; Install was refused while comment and test claimed a fall-back, and the test fed profile=unknown. | Fixed: refused on purpose with `RepairInstallError.boardNotIdentified`, naming the family chosen; comment and test agree; the test feeds the image's real reply. Red then green: `testAnUnidentifiedBoardIsRefusedAndSaysSo`. |
| 4 | Low-Med | The P4 rescue image assumes the 4B (variant, pins, GPIO54 hold, st7703-4b). | Left unchanged by instruction; unverified on the 4C (DECISIONS.md open question). |
| 5 | Low | "Unplug it now" at Start contradicted the loop, which ignores every board attached at Start. | Fixed: the message says to keep the board unplugged until "Plug the board in now", names the ports left alone, and a port appearing during start-up is reported as ignored. `testTheStartMessageSaysBoardsAttachedNowAreLeftAlone` (red then green). |
| 6 | Low | No limit once esptool had connected. | Fixed: `UsbRescue.writeTimeout` (120 s); a hung write is killed and counts as a failed write. `testAHungWriteIsGivenUpAfterTheWriteLimit` (red then green). |
| 7 | Low | Firmware low-power tests match source text. | Left as is by instruction. |
| 8 | Low | The two-new-ports refusal depends on both appearing in one poll. | Left as is by instruction. |

Not changed and reported: tools/espdisp.py `rescue` still has findings 2 and 6 (only the app was asked for).

### Call sites of the shared enums changed (SenderProtocol)

`UsbFlashPhase` (+ `.rescue`), `UsbFlashSession.Flow` (+ `.repair`):
- `UsbFlashPhase.title`, `.detail`, `.fraction` (UsbFlashProgress.swift)
- `UsbFlashSession.fail` step, `lastSeen`, `defaultNextAction` including its inner `Flow` switch
- `AddDeviceSheet.isWritingFlash` (default arm; that monitor never sees rescue phases)
- `FirmwareUpdateSheet.isWaitingForResult` (`if case`, unaffected)
- `UsbFlashStatusView` (reads title/detail/fraction only)
- `UsbRepairModel.canStop`, `UsbRepairModel.headline`
- `EsptoolCommand.rescueWriteFlash` is new; `writeFlash` is unchanged and still validates it.

### Process note

An early UX capture rendered `AddDeviceSheet`, whose `onAppear` refreshes USB. It auto-selected the attached P4 port and began its CFGSHOW inspection. That capture was removed; the capture test now renders only `UsbRepairView`, which does no USB I/O.

## Code review: ESP32-P4-WIFI6-Touch-LCD-4C board support

Scope: `git diff main...board-p4-lcd-4c`. Two independent adversarial rounds,
each run by a separate reviewer that read the diff against Waveshare's XC BSP
3.0.1, Espressif's JD9365 component 2.0.2, both board schematics, the
disassembled ESP-IDF 3.3.11 DSI read path, and the 4C boot logs. Neither
reviewer modified the worktree, opened a port or flashed anything.

### Round 1 (reviewed e5c96f1)

| # | Severity | Finding | Disposition |
|---|---|---|---|
| C1 | Critical | `firmware-releases/manifest.json`, the bundles and the rescue images were stale, so the catalog listed P4 with one profile and every flash and the Mac catalog failed. | Fixed. Rescue images and 1.5.0 bundles regenerated from committed HEAD (a9afe57, 2d6422d); Python and Swift suites green. |
| H1 | High | The SDK's DCS read has no timeout, so an absent panel hangs boot before serial recovery. | Fixed (5702333). The read runs in a helper task with a 1 s deadline; timeout counts as a failed read and boot reaches CFGBOARD recovery. |
| H2 | High | The 4B path rests on the ST7703's unmeasured ID; a blank reply would make every 4B Unknown. | Mitigated (5702333). The 4B is identified by its GPIO52 MDIO pull-up, and any completed read is accepted. Still unmeasured on a real 4B: raised to the human. |
| H3 | High | Any ID other than 93 65 04 became a 4B (catch-all), including a corrupted 4C read. | Fixed (5702333). Each carrier needs two agreeing signals: 4C = 93 65 04 + GPIO52 low; 4B = GPIO52 high + any other completed read. Everything else is Unknown. |
| H4 | High | P4 USB writes no longer required carrier evidence. | Fixed (5702333). `--profile st7703-4b|jd9365-4c` is required again. |
| M1 | Medium | A 3.4C (same PCB and JD9365) would be taken for a 4C. | Deferred: unsupported board; residual in DECISIONS.md. |
| M2 | Medium | Bootstrap now asks for the P4 carrier but its firmware accepts only st7703. | Deferred: bootstrap protocol change out of scope; residual. |
| M3 | Medium | No 4C log came from the committed build, and the board was power-cycling. | Resolved. Power loss isolated (backlight 217 + WiFi radio exceed the port); brightness lowered per the human's decision; final image logs captured. |
| L1 | Low | An unresolved P4 leaves the backlight lit by its hardware pull-up. | Deferred: existing unresolved-S3 behavior; residual. |
| L2 | Low | CFGBOARD error hint omits the P4 profiles. | Deferred: CFG strings are out of scope. |
| L3 | Low | board_probe banner says "no display writes". | No change: the probe still writes nothing to the panel; its header comment now says it reads the ID over DSI. |
| L4 | Low | Panel-ID kinds ignored leftover I2C and flash fields. | Fixed (5702333) with validator tests. |

Checked and not defects: the JD9365 table matches the BSP's 4-inch branch byte
for byte (197 entries); controller preamble and reset timing match Espressif's
driver; timing, pins and backlight polarity match the BSP and schematic; the
ID read releases what it acquired; probing at 480 Mbps returns the same ID the
factory image read at 1500 Mbps; the two detection kinds cannot both match.

### Round 2 (reviewed 5702333)

| # | Severity | Finding | Disposition |
|---|---|---|---|
| N1 | Medium | The timeout path has never run on hardware. | Deferred: needs the 4C booted with its panel ribbon unplugged; residual. |
| N2 | High | A 4B updated over the air goes serial-only if GPIO52 does not read high on it. | Raised to the human (no 4B attached). |
| N3 | Medium | The Mac app (already on main) picks the P4 image from chip identity alone; `rescue` writes the P4 rescue image without `--profile`. | Deferred: pre-existing on main; residual. |
| N4 | Low | The rescue closing hint omitted `--profile`. | Fixed (b28f2b9). |
| N5 | Low | A 4C header HAT pulling GPIO52 high turns it Unknown. | Documented (b28f2b9): README tells the owner to send `CFGBOARD jd9365-4c`. |
| N6 | Nit | `panelIdTask` was `static` in a header used by `inline` code. | Fixed (b28f2b9). |
| - | Latent | A read finishing just after its deadline leaves the semaphore given. | Fixed (b28f2b9): cleared before each read. |

Checked and not defects: deleting the read task mid-spin is safe (no locks,
critical sections or disabled interrupts in the SDK path); worst core-0 stall
about 0.87 s, under the 5 s watchdog; the GPIO52 read is input-only with the
pull-down and nothing else uses GPIO52 on either board; misidentification now
needs two independent faults.

No AutoSDE or CRUX: the remote is GitHub, and nothing was pushed.

## Code review: P4 and 4C gap fixes (p4-4c-gaps)

Scope: `git diff main...p4-4c-gaps`, one independent adversarial round on 5d97e2d. The reviewer built P4 firmware and rescue, and ran the host, Python and Swift suites, in its own scratch tree.

| # | Severity | Finding | Disposition |
|---|---|---|---|
| F1 | High | The Mac app admitted only 720x720 for ETL1, so a 3.4C's `res=800x800` was never streamable. | Fixed (5e7c5b3): admits exactly the catalog's large-tile panels, generated from the P4 descriptors; tests for 800x800 and refused sizes. |
| F2 | Medium | `testUpdatePreselectionFallsBackFromAChipOnlyP4USBProbe` still expected a chip-only P4 fallback. | Fixed: inverted, and it now covers a named carrier. |
| F3 | Low-Med | `resolveFamilyForUpdate` had no carrier guard; the Add Display footer promised a chip-only P4 image. | Fixed: same guard; footer reworded. |
| F4 | Low | The validator accepted two boards sharing a panel ID with only one naming a touch resolution. | Fixed: all boards sharing an ID must declare one; test added. |
| F5 | Low | The exact 4B ID and the touch-config read rest on one 4B unit and no 4B run of the new read. | Accepted; residual in DECISIONS.md. |
| F6 | Low | 3.4C = 800x800 is an inference from the vendor driver. | Accepted; a mismatch leaves the board Unknown (safe); residual. |
| F7 | Low | No test tied LARGE_MAX_WIDTH to the catalog. | Fixed: Python test. |
| Info | - | Rescue hint lists all carriers; bootstrap picks glass by width; EINF log may once pair a stale IP and port; backlight helper also reaches C3. | Left as is: harmless. |

Checked and not defects: the touch-config I2C read (repeated start, address order, bus handed back); JD9365 page tracking (only page-1 0x40 overridden); large-tile buffer sizes and init order; the backlight helper never touches a USB pad; `formatProfileHint` bounds under ASan; the Repair and rescue CLI guards; generator, validator and schema consistency.
