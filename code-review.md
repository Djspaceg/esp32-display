# Code review records (integrated on main)

Each finished branch keeps its own review record below, whole.

## Code review: boot-menu countdown fix (boot-mode-menu, follow-up)

The human found the first menu "dismisses in ~2 seconds so it's impossible to
meaningfully interact with". Required: the first touch or BOOT press cancels the
countdown and the menu then waits for a choice; the power-on countdown is 5 s
and visible; a triple-press menu has no countdown; the opening press is not
counted as input. Reviewed by independent agents with no context, read-only on
the repository, mutating only scratch copies.

### Round 1: nothing blocking; two real escapes

| ID | Finding | Verdict | Disposition |
| --- | --- | --- | --- |
| F1 | A BOOT press made late in the countdown, still down when 5 s ran out, escaped into the normal firmware: the menu streamed, then the release rotated (`rotation=2 (saved)`), dimmed, or powered off (`pwr=off (saved)`) the panel. | CONFIRMED (harness on real input_button.cpp + boot_menu.cpp) | FIXED. The countdown stops when a press goes DOWN: `bootMenuPressDown()` from the BOOT down edge in `handleButton` and from touch `pressStarted` in `serviceTouch`. That press's own completion is then spent on the cancel (`Countdown::onPressDown`, `cancelPending_`). Red first: `pressDownLateInTheCountdownStaysInTheMenu` failed on the pre-fix code with `streaming (countdown ended)` (red-first-review-findings.log). |
| F2 | A touch held 400-600 ms classifies as no gesture, and a long press is dropped on the menu, so a held touch never cancelled and the board streamed anyway. | CONFIRMED (trace) | FIXED by the same press-down hook. `touchHeldTooLongForATapStillCancels`, through the REAL `serviceTouch()`; the pre-fix touch path (mutation M1) fails it. |
| F3 | BOOT press times are on the FreeRTOS tick clock, the menu opened on `millis()`; ticks trail esp_timer, so a press just after the menu appeared was "ignored (began before the menu)". The fakes used one clock, so no test could see it. | PLAUSIBLE (offset assumed) | FIXED. Every menu time is on the tick clock (`menuClockMs`, exported as `bootMenuClockMs`). The fake tick clock now trails `millis()` by 700 ms, as on a board. Red first: `pressJustAfterTheMenuOpensCounts`, and an existing triple-press test, failed with `choose ignored (began before the menu)` (red-first-review-findings.log). |
| F4 | A fast knob turn of several detents both cancelled and moved the highlight (live on the Elecrow knob, which runs Doom). | CONFIRMED (trace) | FIXED. `turnBootMenu()`: one turn is one press, however many detents. `fastKnobTurnOnlyCancels` runs on the knob's real profile through its encoder interrupt and `applyEncoderTurn`; the pre-fix per-detent loop (M6) fails it. |
| F5 | Test gaps: the touch path was not compiled into any test (deleting the press-start line survived); the hold-path ignore was untested; no knob test; single-clock fakes. | CONFIRMED (mutation) | FIXED. `input_touch.cpp` is now compiled into test_doom_entry_gate against a fake controller (`fakes/doom_entry/board_touch.h`), with raw coordinates found by search through the board's real calibration. New: hold-path ignore, knob, touch hold. Mutations (mutations-review-round2.log): 6 of 7 caught. M3, stamping touch starts with `millis()`, survives and is equivalent: the controller is first polled inside the menu, so no touch can appear to begin before it opens, the only case the clock affects. |
| F6 | Misleading or dead text: an unused `now` parameter; "the tail of the press that opened it" (that case cannot reach a new boot: the triple press acts on its third release, then restarts); "Whatever is highlighted" at expiry (only an untouched menu expires). | CONFIRMED | FIXED: `onPress(pressStartedAt)` lost `now`; comments now name the real case (a press made during boot, after the BOOT interrupt is attached and before the menu opens); the expiry comment says the highlight is still STREAMING. |
| Risk | With the 60 s ceiling gone, a phantom touch, a stuck BOOT pressed after the menu opens, or an accidental triple press leaves the board on the menu until someone chooses. | Design | ACCEPTED as asked ("stays up until the user picks something"); recorded as a residual in DECISIONS.md D9. |

Checked and sound in round 1: the hold that cancels sets `selectorEntryHold`, so
its release does nothing; choosing STREAMING by a hold leaves no rotate or power
press; the WiFi selector is unchanged; wrap arithmetic is right; a board left
alone streams.

The round-1 fixes were committed to main as ac64531 by someone other than me (its
message says the human tested it on a board), before round 2 reported. The
round-2 fixes below are a follow-up commit on top of it.

### Round 2: one blocking finding; all fixed

| ID | Finding | Verdict | Disposition |
| --- | --- | --- | --- |
| R2-1 (blocking) | The touch controller is first polled inside the menu, so a finger already on the glass at power-on (a resting hand, a case pressing the panel) looked like a fresh press, cancelled the countdown, and with no ceiling the board never streamed. The probe was still on the menu at 120 s. | CONFIRMED (probe) | FIXED. `primeTouchForBootMenu()` reads the controller for 60 ms before the menu opens; a finger found down is ignored, every report, until it lifts. Red first: `touchAlreadyDownAtOpenStillStreams` hung on the round-1 code (red-first-review2.log). The test fake now reports a resting finger every 10 ms, as a polled GT911 does. |
| R2-2 | F4 was fixed only when every detent landed in one loop pass. A real flick spreads its detents over several passes, so it still cancelled and moved; so did press-and-turn. | CONFIRMED (probe) | FIXED. `Countdown::onTurn`: detents within 250 ms (`KNOB_GESTURE_MS`) are one gesture, and a turn while the cancelling BOOT or touch press is still down is spent. Red first: `knobFlickSpreadOverPassesOnlyCancels` and `knobPressAndTurnOnlyCancels` failed on the round-1 code; model rules red on the round-1 model. |
| R2-3 | A BOOT press could still leak into the normal press tiers by two routes: a touch choosing while BOOT was held, and a down edge arriving in the menu's last pass after its button handling. | CONFIRMED (harness) | FIXED. `swallowBootPressAcrossMenuEnd()`, called as the menu ends: a press already down, or one whose down edge is stamped at or before the end, is swallowed whole. Red first: `touchChoiceWhileBootHeldLeavesNoNormalPress` failed with `long press -> rotation=2 (saved)`. `bootDownInTheLastPassLeavesNoNormalPress` injects BOOT inside the last pass's touch poll and checks the next real press is normal again. |
| R2-4 | A menu left open 2^31 ms or more read every press as from before it (signed difference), and nothing ended it. | CONFIRMED (model) | FIXED. `tick()` retires the before-open test 10 min after opening (`BEFORE_OPEN_HORIZON_MS`); before that, an unsigned horizon test. Red first on the round-1 model. |
| R2-5 | The cancelling press was matched by timestamp alone, so a BOOT press and a tap in the same millisecond could swap roles; a pending cancel from a press that never completed stayed set. | CONFIRMED (probe) | FIXED. Matched by `PressSource` as well; a new press from the same source clears a stale pending cancel. Red first on the round-1 model. |
| R2-6 | Design risk: with no ceiling, any stray press during the countdown keeps the board off streaming. | PLAUSIBLE | ACCEPTED as the human's rule 1; R2-1, its concrete instance, is fixed. Residual in DECISIONS.md D9. |
| Nits | `ui_screens.cpp` comment "the title is the countdown"; code-review.md still describes `MAX_OPEN_MS`. | CONFIRMED | Comment FIXED. The `MAX_OPEN_MS` text is the record of the first review round and stays as history; D9 records the supersession. |

Also fixed, found while checking mutation R4: `surveyActive` leaked from an
earlier test (a double press turns the survey on), which made
`touchChoiceWhileBootHeldLeavesNoNormalPress` pass vacuously: its release took
the survey branch, so the rotate it guards could not happen. `resetObservations()`
now resets all shared button and display state.

Mutations after round 2 (mutations-review-round2.log): 13 of 14 caught. M3
(touch press starts on `millis()`) survives and is equivalent: the controller is
first read just before the menu opens and touches from before are filtered by
the prime, so no touch time can fall before the opening on either clock.

### Round 3: nothing confirmed blocking; two fixed, rest recorded

| ID | Finding | Verdict | Disposition |
| --- | --- | --- | --- |
| R3-1 | The prime only waited for reports, but the CST816 (three Doom boards: LcdSt77916, TouchSt7789, ElecrowKnob128) reports by interrupt and need not raise one for a finger holding still; `board_touch.h` reads it only when the flag is set. A finger resting since boot could slip past the prime, then a slight shift in the menu would cancel the countdown, and the board would never stream. | PLAUSIBLE (hardware-dependent) | FIXED. New `boardtouch::readNow()` reads the CST816 report register directly, whatever its interrupt says (a controller asleep with nothing on it reads as no report); other controllers fall through to `poll()`. The prime calls it first, then watches reports for 60 ms. Red first: `silentRestingFingerStillStreams` (finger down since boot, one report a second in) hung on the round-2 code (red-first-review3.log). The fake controller now knows where a finger is independent of its reports, so a direct read can be modelled. Unverified on CST816 hardware. |
| R3-2 | A press-and-turn's BOOT release never reaches the menu as a press, so the turn rule went on treating it as held and every later turn was spent: the knob went dead. Same after a touch held too long to be a tap. | CONFIRMED (probe) | FIXED. `onTurn(at, pressHeld)`: the caller says whether BOOT or a finger is physically down now (`gpio_get_level` on BOOT, `touchPressHeld()`); a pending cancel with nothing held has ended. Red first: `knobWorksAfterPressAndTurn` failed on the round-2 code; model cases for the BOOT and touch variants. |
| R3-3 | If a GT911 holds its last report until cleared, a tap during boot could be read at the prime as a resting finger, and the user's first real tap would only clear it. | PLAUSIBLE, minor | NOT CHANGED. The countdown still runs and the board still streams; the cost is one eaten tap. Residual. |
| R3-4 | `bootDownInTheLastPassLeavesNoNormalPress` depended on exact timing and could pass without its hook firing. | CONFIRMED | FIXED: the test now asserts the hook fired inside the menu. |
| R3-5 | The fake controller handed out every queued report with no gating, so a resting finger always had a stale report waiting; prime-length and lift-during-prime mutations survived. | CONFIRMED | FIXED in part: resting fingers now report every 10 ms like a polled GT911, a silent resting finger exists for the CST816 case, and `fingerLiftedDuringPrimeThenTapCounts` covers a lift during the prime. A 1 ms prime is still not distinguished in the fake (the direct read covers it); recorded. |
| Nits | Orphaned "one gate" comment; "a knob turn is one press" in `boot_menu.h` and `input_button.cpp`; dead `!= Knob` check. | CONFIRMED | FIXED. |
| Checked sound | Swallow: cleared by the first `handleButton()` after the menu, which nothing in setup calls earlier; a full long press during the WiFi wait still rotates; old-release/new-down/new-up queues are right; the WiFi selector is unaffected. Tick latch runs every pass. Source matching holds. M3 (touch on `millis()`) is equivalent. Non-game builds (no `ESPDISP_BOOT_MENU_RUNTIME`) syntax-check for plain, C6 and C3. | | |

Mutations after round 3 (mutations.log): 15 of 16 caught; M3 survives, equivalent.

Also found while gating: my build-wait loop (`while pgrep -f "arduino-cli compile"`)
matched another worker's identical loop, and theirs matched mine, so both waited
forever. My stale job was stopped (it predated round 3, so nothing was lost) and
the gate now waits on the exact process name (`pgrep -x arduino-cli`).

### Call sites (shared component)

`firmware/libraries/espdisp_board/src/board_touch.h` gains `boardtouch::readNow()`.
It is new; no existing caller changes. Its only caller is
`firmware/display_stream/input_touch.cpp` `primeTouchForBootMenu()`, which is
compiled only with `ESPDISP_BOOT_MENU_RUNTIME`. The library's other users
(`display_test`, `board_bootstrap`, `display_stream` beyond that function) do not
call it. `poll()`, `init()` and `available()` are unchanged.

### Rounds

3 independent rounds on the countdown fix. Round 1 changed the press semantics
(cancel on press-down, one clock). Round 2 added the touch prime, the BOOT
swallow, press sources, the tick latch and the knob gesture. Round 3 added
`readNow()` and the held-press flag for turns. No decision in DECISIONS.md was
reversed; D9 stands.

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

## Code review: USB keyboard and mouse for Doom (usb-input)

One adversarial round by an independent reviewer agent, read-only on the repo,
with no serial port and no flashing. It reviewed `git diff main...HEAD` at
2d6ad3c. It read the installed Arduino core 3.3.11 and its prebuilt TinyUSB and
usb archives, disassembled `usb_new_phy`, inspected both linked ELFs with `nm`,
ran the host suite and both family compiles, and independently re-read the 4B
and XC schematics. Every finding is addressed below; the suite afterwards goes
from 138 to 477 checks for this layer.

| # | Severity | Finding | Disposition |
|---|---|---|---|
| 1 | High | **The wrong USB PHY was brought up, and it would have seized the panel's pins.** `USB_PHY_TARGET_INT` is the P4's full-speed FSLS PHY, not the UTMI one belonging to the high-speed OTG controller on rhport 1. `usb_new_phy` promotes INT to UTMI only when `otg_mode == USB_OTG_MODE_DEVICE` (shown in the disassembly of `usb_phy.c.obj` in `libusb.a`), so in host mode it stayed INT and no device could ever enumerate -- silently, since the call still returns `ESP_OK`. That path also calls `gpio_set_drive_capability` on the OTG internal PHY's fixed pads, `USB_INT_PHY1_DM/DP` = GPIO26/GPIO27, which are `pin_bl` and `pin_rst` on all three P4 carriers. | Fixed: `USB_PHY_TARGET_UTMI`. Confirmed independently here from `usb_phy_types.h` (INT is documented "internal FSLS PHY"), from the same disassembly (`USB_OTG_MODE_DEVICE == 2`, and the branch at `usb_new_phy+0x1a` leaves host mode on the non-promotion path), and from `io_mux_reg.h` (`USB_OTG_INT_PHY_DM/DP` = 26/27) against the three board descriptors (`pin_rst = 27`, `pin_bl = 26`). The reason is now written into the code so it cannot be "simplified" back. |
| 2 | High | **A key held across the gameplay/menu boundary was left stuck down forever** -- the exact failure the comment claimed to prevent. `apply()` rebuilt the held set from the current context each report, so W pressed in play was released as `'w'` while `KEY_UPARROW` stayed down and the player walked forever. The existing test only covered the case where the release report is the first one seen in the new context, which worked either way. | Fixed: a new `keyFor()` carries the engine key an id was *pressed* as, so a release always matches its press. `testMenuContextTypesLetters` now walks the real sequence (hold W, press Escape, menu opens, release Escape, release W). Verified load-bearing: reinstating the old behaviour fails at that assertion. |
| 3 | Medium | Reports already queued when a device is unplugged were replayed after `releaseAll()`, pressing keys again that nothing was left to release. | Fixed: `ReportQueue::dropDevice()` on unmount, before the release. Host tested, including that the other device's reports survive in order. |
| 4 | Medium | A full ring dropped the newest report; the stated reason was backwards. A boot report is an absolute set, not a transition, so the newest is authoritative and a dropped key-up is never resent. Reachable: one queue shared by keyboard and mouse, drained once per engine poll while a 1 kHz mouse fills it. | Fixed: the oldest is dropped. The comment now says why. Host tested at capacity and across a wrap. |
| 5 | Medium | A USB key held while the touch or tilt path released the same engine key went dead until physically re-pressed: `dg_release_gameplay_keys()` pushes those keys up, and a keyboard sends no report while its key set is unchanged. | Fixed: `doom_usb_input_reassert()`, called from `process_usb_input` whenever the touch or tilt path released a shared key (leaving gameplay, or lifting the second finger that holds Run). Re-pressing a key the engine thinks is down is harmless because gameplay reads held state. |
| 6 | Medium | "a save name can still be typed" was false: only w, a, s and d were mapped at all. | Fixed: inside a menu every letter is itself, which also makes the engine's own y/n prompts work. In play only the movement four are mapped, so stray typing still cannot reach a cheat code -- both halves tested over the whole alphabet. |
| 7 | Low-Med | Undocumented dependency on the P4 FQBN's USB menu defaults: enabling CDC, MSC or DFU on boot would have the core take the same PHY in device mode first and the feature would silently vanish. Verified no conflict today. | Fixed: a `#error` on that combination, so it is a build failure rather than a silent loss. |
| 8 | Low | The one-poll wheel hold was unnecessary -- `G_Responder` latches `next_weapon` from the key-down event, not from `gamekeydown[]` -- and it let the next poll cancel a real `/` press. The wheel accumulator was also unbounded, so one scroll cycled weapons for seconds. | Fixed both: a notch is a press and release in one poll, and the queue is bounded (`MOUSE_MAX_WHEEL_QUEUE`). Confirmed the event path independently at `g_game.c.inc:797-807`. One notch per poll is kept, because the engine can only act on one change per tic. |
| 9 | Low | Vertical movement was capped at 160 while `forward` saturates at `MAXPLMOVE` (50), so any ordinary flick was full run speed, and nothing tied the constants to anything. | Fixed: `MOUSE_MAX_TURN_DELTA` 160 (matching the touch joystick) and `MOUSE_MAX_WALK_DELTA` 50 (citing MAXPLMOVE), both asserted by value in the test rather than against themselves. |
| 10 | Low | Four factual errors in the comments: the high-speed pads are package pins 49 (DM) and 50 (DP), not 50/51 (51 is VCCA); what holds the 4B's pass FET off is its gate circuit, not only the body diode; `CFG_TUH_HID` is `3 * CFG_TUH_DEVICE_MAX` = 21 stack-wide, not 3 per device; and the XC carries three USB connectors, not two. | All four fixed, in the code comments and in `docs/usb-host-ports.md`. Pin numbers re-read from the 4B schematic's own pin list (`GPIO24 52, VCCA 51, DP 50, DM 49`). |
| 11 | Low | The model pointed at `DECISIONS.md` for evidence that was not there, and `firmware/doom/README.md`'s Controls table had no keyboard or mouse rows and no power caveat. | Fixed: the comment points at `docs/usb-host-ports.md` (committed in this branch), and the README gained a USB section including that the 4B supplies no 5 V. |
| 12 | Low | `doom_usb_input_device_present()` and the `s_mounted` counter it existed for had no caller. | Fixed: both removed. |
| 13 | Low | Test gaps: the whole glue file untested, the clamp asserted against its own constant, the undersized-buffer truncation path unexercised, `doomKeyForModifier` never called with an unmapped bit, and the variant list hand-written against a generated enum. | Fixed: the report queue moved into the host-tested model (push, pop, oversize, ignored device, capacity, wrap, `dropDevice`); the caps asserted by value; an undersized buffer now refused outright and tested; unmapped modifier bits tested; the variant check sweeps the whole enum range so a future variant defaults to unsupported in both arms. |

On the per-board claims, the reviewer independently confirmed from the
schematics: the high-speed pads reach a connector on both board families; that
connector is the 4B's H2 and the XC's J3, both silkscreened USB-OTG; both
families flash and log through a separate CH343P on a separate connector; the
4B's H2 is sink-only (R2/R3 5.1K, no Rp, no CC controller) with no boost, load
switch or VBUS GPIO; and the XC's VBUS_OUT comes from U10 DIO7003HEST5 with its
enable pulled up through R12 and R53 unpopulated. What remains a graphical read
rather than a settled netlist, and what would need a meter, is now listed under
"What was not read" in `docs/usb-host-ports.md`.

Checked and not defects: the `#define CFG_TUSB_MCU 907` hack is necessary, not
cosmetic (without it a sketch TU silently builds as an ESP32-S2 with the
high-speed macros flipped off), it wins over `tusb_config.h`, and no
sketch-visible struct layout depends on it, so there is no ABI hazard against
the prebuilt archive; rhport 1 is the high-speed OTG core; the no-locking
assumption holds because TinyUSB's host core spawns no task of its own and every
call site is on loopTask, which is also where `tusb_init` is called as
`usbh.h` requires; one poll of hold is enough for `gamekeydown` given
`I_StartTic` then `D_ProcessEvents` then `G_BuildTiccmd`; the mouse sign
conventions are right on both axes; `process_touch_input` zeroes the shared
delta first, so touch and mouse add rather than cancel; the S3 image links no
`tuh_`, `hidh_` or `usbh_` symbol at all; and nothing runs outside a Doom
session.

Nothing in this review or these fixes was verified on hardware. No board was
flashed, no serial port opened, no Mac app launched. The two findings the
reviewer would fix before touching hardware were 1 and 2, and both are fixed.

## Code review: retry the USB identity check (usb-identify-retry)

Reviewer: a separate review agent, read-only, two rounds. Scope: mac/ESPDisplaySender only (AddDeviceSheet, PanelManager, PanelManager+UsbDevices, PanelManager+DeviceControls, WifiConfigUI, two new test files). No firmware touched.

Call sites checked (round 1, re-checked round 2): refreshUSBPorts callers (2 s timer, releaseUSBProbes, refreshUSBDevices, configureUSB, onboarding end, FirmwareUpdates x2, AddDeviceSheet after a run) all reach identifyUSBPorts; every probeUSBDevice caller (background identify, sheet inspection via probeExistingFirmwareReport, control reprobe, finishUSBFlash reprobe, onboarding) feeds the retry schedule on silence; probePort callers (probeUSBDevice, UsbOnboarder.probeExistingFirmware and settle) get the lock check and the CFGINFO-only rule.

### Round 1

Verdict: correct for the bug, nothing blocking. Findings and dispositions:

- R1-1 (non-blocking) A port that never answers gets CFGSHOW every 30 s forever, including while another program (esptool from Terminal, a serial monitor) drives it. FIXED: probePort opens with refuseIfLocked and tests flock(LOCK_EX|LOCK_NB) before any termios or modem change, sending nothing to a locked port. esptool 5.3.1 was shown to hold that lock (esptool-lock-check.log). A monitor that takes no lock is still asked at most every 30 s (D1).
- R1-2 (non-blocking) Hold-off misses some USB writers; a setter's CFGOK read by a retry was taken as an identity with no hardware ID, wiping the board's identity and ending retries. FIXED: probePort accepts only CFGINFO; performUSBControl counts usbControlsInFlight into the hold-off; retries skip a board verified at this connection unless it is restarting, the only kind the synchronous rename/WiFi/OTA setters will drive. Tests: testACFGOKIsNotAnIdentity, testAProbeSendsNothingToAPortAnotherProgramHasLocked (both red on HEAD, usb-retry-review-red-green.log).
- R1-3 (non-blocking) A restarting board whose tty survives the restart is never asked again. FIXED: markUSBRestarting seeds a retry. Test: testARestartingBoardIsAskedAgainWithoutANewPort.
- R1-4 (nit) Add sheet could adopt an answer from before its inspection. FIXED: the sheet records the device at inspection and adopts only a changed verifiedGeneration or serialStatus.
- R1-5 (nit) hold/release not paired with defer. FIXED.
- R1-6 (nit) schedule on wall clock. FIXED: systemUptime.
- R1-7 (nit) timing-dependent schedule test. FIXED: delays set to [60] there.
- R1-8 (nit) hold-off branches untested. FIXED for control writes, preset sheet, preset sync, brightness; the sheet's adoption logic stays in the View, untested (residual).

### Round 2

Verdict: the R1 fixes are correct; no blocking regression. R1-1 partly fixed (N1, N2), R1-2 to R1-8 verified fixed; usbControlsInFlight balanced; the answered-board filter is correct for the setter race. New findings and dispositions:

- N1 (non-blocking) Every unrelated USB serial device (Arduino, printer, another project) was probed every 30 s while plugged in, switching a foreign session's baud and modem lines each time. FIXED: a port that no display record points at (by reported hardware ID or saved path) is let go after 7 unanswered asks, about 2 minutes; a display's own port, or a restarting one, is asked until it answers or is unplugged. Opening the Add sheet on a port starts its schedule again. Test: testOnlyADisplaysOwnPortIsAskedForever.
- N2 (non-blocking) esptool run against /dev/tty.X locks that node, not /dev/cu.X. Fix attempted (open and test the tty sibling), then REVERTED in round 3 (R3-1): with our cu.X open the driver refuses tty.X with EBUSY, so every real port looked busy. A program holding tty.X already makes our cu.X open fail with EBUSY, so the case is covered without the sibling.
- N3 (non-blocking, partly pre-existing) Probes took any CFGINFO (CFGINFO wifi, pmu, lowms, rxyield) as the identity and stopped at the first non-identity reply. FIXED: sendCommand takes an accepts predicate; probePort accepts only WifiConfigUI.isIdentityReply (CFGINFO, not "CFGINFO wifi ", carrying id=, ssid64=, ssid= or name64=) and reads on past anything else. Checked against every CFGINFO the stream and rescue firmware print. Test: testAProbeSkipsAnotherCommandsCFGINFO.
- N4 (nit) A board with no display record that answered and then went quiet was never retried. FIXED: an unanswered probe clears the earlier answer for a port no display owns (no setter can be driving it). Test: testAnUnownedBoardThatGoesQuietIsAskedAgain.
- N5 (nit) A restart left an existing far-off retry in place. FIXED: the restart pulls it forward to 2 s. Test: testARestartBringsAFarOffRetryForward.
- N6 (nit) Comment overstated that the lock test never keeps anyone out. FIXED: the comment states the microsecond window and that the other program is told the port is busy.

The round-2 tests exercise new API (the cap, isIdentityReply, usbPortBelongsToADisplay), so they have no red run against the earlier code; R1's red runs are in usb-retry-red-green.log and usb-retry-review-red-green.log.

### Round 3

Scope: the N1-N5 fixes. The reviewer read Apple's IOSerialBSDClient open and close paths for N2. Verdict: not ready because of R3-1; the rest are non-blocking. N3's identity rule was checked against every CFGSHOW answer in the firmware's history and every test fixture, and passed. N4 was checked for mid-onboarding effects and is clean.

- R3-1 (blocking) The N2 sibling check opened /dev/tty.X while our /dev/cu.X was open; the driver returns EBUSY for that whoever else is there, so every real board would have read as busy and never been identified. The pty tests could not see it (no cu/tty pair). FIXED: the sibling check is removed and only our own descriptor's lock is tested. Opening the sibling first instead would raise and then drop DTR/RTS and reset an ESP32, so that is not done either. The flock test on a real cu node was exercised on both P4 boards (board-serial-reads.log: read-board.py takes the lock and gets CFGINFO).
- R3-2 (non-blocking) The restart pull-forward kept a high attempt count, so a miss mid-reboot waited 30 s. FIXED: a restart starts the schedule at attempt 0. Asserted in testARestartBringsAFarOffRetryForward.
- R3-3 (nit) A stale saved path keeps a foreign device on the endless schedule. NOT TAKEN: a silent board has reported no hardware ID, so a record's saved path is the only link from it to its display. The reported 4C record has both an ID and a saved path, and under the suggested rule it would have been capped. The cost is at most one CFGSHOW every 30 s on a reused path.
- R3-4 (nit) The comment said restarting boards count as owned, but the code did not check. FIXED: a restarting record's device path counts.

### Round 4

Scope: the round-3 changes only. Verdict: approved, no new findings.

- R3-1 verified. Nothing opens a /dev/tty.* node any more. The lock test runs before any termios or DTR/RTS change, and a refused open writes nothing.
- R3-2 verified. A restart resets the schedule to attempt 0. A probe that was already in flight when the reset happened leaves the fresh schedule alone.
- R3-3: the reviewer agrees it should not be taken. The saved path is the only link from a silent board to its display.
- R3-4 verified. There is no recursion. The new clause runs on the main actor and is harmless.

Final gate on this code: swift test 822 tests 0 failures; run_tests.sh exit 0; test_espdisp.py 1980 checks passed (gate-*.log).

## P4 backlight floor (p4-display-goes-black)

Two rounds by an independent review agent (read-only; no builds, flashing or
serial). Full texts: review-round1.md and review-round2.md in the scratch folder
/Users/stepblk/Source/esp32-display-p4dark. No CR: this repo is not a CRUX
package, so there is no AutoSDE session.

### Round 1 (on a remap of 1-255 onto [47%, full])

| Finding | Severity | Disposition |
|---|---|---|
| F1 not checked on glass; 47% margin thin | blocking | Carried into round 2 (R2-1); verified on hardware after the floor change. |
| F2 every P4 level brighter, more LED current on boards with POWERON history | non-blocking | Fixed: the curve is now a clamp, max(floor, old linear duty), so levels that already lit keep their duty. DECISIONS D1. |
| F3 rescue-image staleness gate red | non-blocking | Planned: artifacts-only second commit built from a clean clone of the fix commit (D5). |
| F4 4C/3.4C descriptor floor not tied to their hand-written configs | non-blocking | Fixed: test_espdisp parses board_config.h and compares both floors with the descriptors (mutation-checked by the reviewer). |
| F5 bootstrap drafts inherit an unmeasured floor | non-blocking | Fixed: the draft builder pops floor_permille. |
| F6 only p4 compiled after display_power.cpp changed | non-blocking | Fixed: p4, s3, c6, c3 compiled on the final sources; both suites re-run. |
| F7 nothing guards rescue's floor reset | nit | Fixed: test_rescue_model checks rescue.ino zeroes the floor and uses its copy. |
| F8 rescue says "shows RESCUE" on a P4 whose glass is dark | nit | Accepted as a residual (pre-existing darkness, unchanged by design). |
| F9 three stale comments | nit | Fixed. |

### Round 2 (on the clamp at 470)

| Finding | Severity | Disposition |
|---|---|---|
| R2-1 the card sits exactly on the single 47% reading | blocking | Fixed: floor 510 (51%, the 4B's own level 130, seen lit). DECISIONS D2. Verified on both boards' glass by the human (see DECISIONS evidence). |
| R2-2 the bootstrap inert check passed with or without the fix | non-blocking | Fixed: the synthetic session's template now carries floor 300; with the pop removed the check fails ("got 300, want 0"). |
| R2-3 DECISIONS draft described the remap | non-blocking | Fixed: D1/D2 rewritten to the clamp with its visible costs. |
| R2-4 host suite log older than the last test edit | nit | Fixed: run_tests.sh re-run on the final tree. Compiles in the shared tree included another worker's edits; the clean-clone release build is the authoritative one. |
| R2-5 hand-written floor check covers 4C/3.4C only | nit | Accepted: the 4B is generated, and another check pins the set of boards with a floor. |

### After commit

| Finding | Severity | Disposition |
|---|---|---|
| The screensaver worker's swift test at d767428: 16 assertions in 10 tests pinned to a 1.5.0-only shipping catalog | blocking for the release cut | The human chose "Ship 2.0.0 now". Six test files now expect 2.0.0 and 1.5.0 together; the app's own behavior (2.0.0 Upgrade, 1.5.0 Reinstall, a refused newest revision listed with its reason) was correct and is unchanged. swift test 1301 / 0 on 094ec7d plus the fix. |

The reviewer confirmed the clamp math for every floor 0..65535 at 8 and 10 bit
(monotonic, 255 is full, floor 0 byte-identical to the old duty, no overflow),
the Config initializers, rescue's config copy, and that brightness reporting
(EINF/EACK, CFGSHOW) still reports the level.

### Call sites

Every backlight writer in firmware/, with its verdict under the final clamp
(floor 510 on P4 = 522/1023; floor 0 everywhere else, byte-identical).

Sinks:
- libraries/espdisp_board/src/panel_init_dsi.h boardpaneldsi::setBrightness (ledc_set_duty): floored, floor latched at init. The only LEDC writer.
- panel_init_dsi.h ledc_channel_config duty 0: initial off, unaffected.
- libraries/espdisp_board/src/display_backend.h boarddisplay::setBrightness: DSI to the floored path; CO5300 panel command unfloored (validator forbids a floor there).
- display_stream/display_power.cpp driveBrightness: DSI branch floored; analogWrite branch floored at 8 bit, inverted after the curve.
- libraries/espdisp_board/src/board_detect.h darkenUnresolvedBacklight: digital off, unaffected.

display_stream (all through driveBrightness/applyBacklight, so floored on P4):
- display_stream.ino boot screen applyBacklight, driveBrightness(0) before and after panel init, ESLP/EWAK, status card on/off: floored; the card is the fix.
- display_power.cpp DISPOFF driveBrightness(0), applyBacklight, updateIdentify (255 vs BL_LOW, now 1023 vs 522 on P4).
- control_apply.cpp brightness, level, power; input_touch.cpp touch-wake start/expiry (the reported "dark again after 10 s" path); input_button.cpp BOOT/knob; frame_pipeline.cpp first frame; ota_service.cpp; serial_config.cpp CFGFIXEDBL, CFGPOWER, CFGBRIGHTLEVELS, CFGBRIGHT; boot_menu.cpp; ui_screens.cpp selector, menu and survey at BL_SURVEY 255 (full either way).
- doom and quake bridges: no backlight writes; a game boot sets BL_HIGH 128, 513/1023 linear, so 522 on a P4.

Other sketches:
- rescue/rescue.ino setBrightness(32/0) and analogWrite(backlightDuty): floor zeroed in rescueConfig, so 128/1023 as before (D4).
- display_test/display_test.ino setBrightness(128) on DSI: 513 linear, raised to 522; analogWrite(128) non-DSI raw.
- board_bootstrap/board_bootstrap.ino setBrightness on candidateConfig ({} so floor 0) and analogWrite: raw, by design for a measuring tool.
- tools/espdisp_bootstrap.py: drafts drop floor_permille; retune keeps it.

No stream-firmware path writes a lit duty below the floor on a P4.
