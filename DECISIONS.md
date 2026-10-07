# Integrated decisions (main)

Each finished branch keeps its own record below.

## Boot-mode menu (boot-mode-menu)

### Outcome

An on-glass menu picks Streaming (the default), Doom, or a reserved Quake slot,
replacing the hidden triple-press Doom handoff. After a user reset it counts down
5 s to streaming, shown on its title; the first touch or BOOT press stops the
countdown and the menu then waits for a choice. A triple press opens it with no
countdown. Left untouched, it streams. Driven by touch or by BOOT alone.

### Decisions to evaluate

D1 The menu wraps the existing one-shot handoff: same `doomonce` flag, same restart, so Doom still owns panel and PSRAM alone and a failed game returns to streaming. Why: that reboot boundary is worth keeping. If overruled: enter in-process, reintroducing teardown paths.
D2 A triple press of BOOT now requests the MENU (one-shot `bootmenu`), not Doom directly. Why: one gesture, one place, and the menu is where Quake will appear. If overruled: keep it a direct Doom entry, menu only at power-on.
D3 The timed menu opens only after a user-caused reset (power-on, external pin, USB), never after a software restart, panic, or watchdog. Why: a board left alone must come up streaming, and a Doom exit or crash must not loop back into a menu. If overruled: change `bootResetKind()`.
D4 Doom is offered only when its WAD passes the Doom boot's preflight, so a board with no WAD shows no menu and the triple press keeps the existing "full USB flash" refusal. Why: an entry that always fails is worse than none. Supersedes: offering Doom on build-and-board capability alone, which reintroduced the failure ea332f6 fixed. If overruled: list Doom and let it refuse on entry.
D5 A panel the user turned off (`pwroff`) gets no timed menu; a triple press still opens one. Why: a standing "stay dark" instruction should survive a reboot, but an explicit gesture overrides it. If overruled: always light the menu.
D6 The menu reuses the WiFi selector's layout, hit testing, and controls (`wifi_selector_model.h`). Why: one design, geometry already tested at every panel size. If overruled: give the menu its own layout.
D7 Quake occupies a real enum slot, label, and capability pair that nothing sets, so it never appears. Why: a clean slot the runtime author fills in one place. If overruled: drop the slot until a runtime exists.
D8 Menu, screen, and model compile only into images carrying a game runtime (`ESPDISP_BOOT_MENU_RUNTIME`, today from `ESPDISP_DOOM_RUNTIME`); other builds get inline no-op stubs, so call sites stay unconditional. Why: a C6 runs no game and its image is at 94% of flash. Measured: +5478 B unguarded, +76 B guarded. If overruled: compile everywhere and accept the bytes.
D9 The first press on a counting menu only stops the countdown (it does not also move or choose), and after that the menu stays until a choice, with no ceiling; a triple-press menu never counts down; a press that went down before the menu opened is ignored. Why: the human found the 3 s menu gone before it could be used, and asked for exactly these rules. Supersedes: input renewing a 15 s idle window under a 60 s ceiling, because that still dismissed a menu someone was reading. If overruled: restore a ceiling in bootmenu::Countdown.

### Open questions

- Doom's in-game BOOT tiers and controls are unchanged; the menu is the entry
  only. Default: left untouched.

### Gate facts

Publish: committed straight to local main, GitHub remote, no push. Developed on
a worktree, then carried onto main 2b3ba03 (after the P4 quake_pak layout) and
gated again in the main checkout.
packages/*: none touched. Shared symbols and their every call site: see the call
sites section of code-review.md.
Lanes, run in the main checkout with the usb-input worker's uncommitted files
present: gate-run_tests.log exit 0 (107256 + 164 boot-menu/Doom-entry checks);
gate-test_espdisp.log exit 0, 1973 checks; gate-compile-{c6,s3,p4}.log exit 0. Bundles are
regenerated from the boot-menu commit (release-shipping.log). C6 flash +76 B
over main, 94% either way.
Red first: red-first-boot-menu.log, a runtime assertion failure against main's
code (a triple press set doomonce and rebooted straight into Doom, no menu).
Review rounds: 1 independent; 2 blocking findings, both fixed (code-review.md).

### Evidence

- gate-lanes.log and gate-*.log: the gate lanes and their verdicts.
- red-first-boot-menu.log: the new assertions against pre-change code.
- boot-menu-screens.png: the menu drawn by the firmware's own pixel code at every
  panel shape, touch and BOOT-only.
- code-review.md: the independent review and its dispositions.

### Residuals

Unverified on glass, and this is where verification is owed: the menu adds about
3 s before WiFi on every power-on and reset of the 10 game-capable profiles,
lights the panel at the survey brightness whatever level is saved, and reads the
WAD once per boot. Also unverified: countdown timing, touch coordinates, and
legibility on the 128x128 knob. Renders are host-side.
Pre-existing and untouched: a triple press whose NVS write fails leaves the
survey toggle from presses one and two in place (now covered by a test).
- With no ceiling, a touch controller that reports a phantom press at boot leaves
  the menu up until someone chooses; the board does not stream until then.
- A finger already on the glass when the menu opens is read just before it
  opens and ignored until lifted. On CST816 boards that read is a direct register
  read (`boardtouch::readNow`), unverified on that hardware.
- If a GT911 holds a boot-time tap as a resting finger, the first real tap on the
  menu only clears it; the countdown still runs.

## P4 hosted-WiFi RPC watchdog (p4-hosted-rpc-offloop)

### Outcome

The P4 watchdog reboots are fixed. The 4C reproduced the reboot on demand: a side task kept the C6 busy, loopTask's RSSI read waited, and the watchdog fired. The fixed build survives the same injection. Confidence is HIGH. Code and bundles are at 6298050 on branch p4-hosted-rpc-offloop, not pushed.

### Decisions to evaluate

D1 One worker task (wifi_worker, core 0) owns every WiFi driver call after setup(). loopTask reads a cached RSSI, sampled every 500 ms and reported as unknown after 10 s, and posts reconnects. Why: covers every hosted RPC reachable from loopTask, not only RSSI. If overruled: gate the calls per site instead.
D2 If the C6 stops answering for 30 s while associated, the supervisor restarts the board once, 60 s later, and sends no reconnects. Why: the old watchdog reboot was what recovered a stuck C6, and an accepted reconnect kept restarting the fault clock. If overruled: change COPROCESSOR_SILENT_MS or RADIO_FAULT_RESTART_MS.
D3 The falsifier is a blocking C6 scan, not a C6 reset on GPIO54. Why: holding GPIO54 low breaks the SDIO link, and ESP-Hosted then restarts the host at once (SW_CPU_RESET, no watchdog), which never exercises the 5 s RPC wait. If overruled: none; the GPIO54 result is recorded.
D4 The bench fault hook is committed but off: it needs a gitignored header plus ESPDISP_FAULT_INJECT=1 at build time, and it prints a boot banner when present. Why: repeatable falsifier. If overruled: drop fault_inject.* before merge.
D5 An unknown RSSI is sent in EINF as -127 and shows as "wifi --" on the panel. Why: a 0 dBm reading looked like perfect signal. If overruled: send 0.

### Open questions

- C6 co-processor firmware: the host library is ESP-Hosted 2.12.11 and expects a C6 on 2.12.11. The C6 never answers the version request (Req_GetCoprocessorFwVersion, ESP_FAIL after 1 s, every boot), so its version reads 0.0.0. The inference is that it predates that request, so it is older than 2.6.0, the oldest version the Arduino core recognises. That is a competing reason for the C6 going quiet. Default: the C6 image is untouched (your call).
- The soak ran with no stream. The app has not sent to the 4C since 14:47 local (panels.json lastSeen). Default: soak recorded as idle-only; re-soak once the app is streaming.
- After a scan, the C6 stays silent until a host reboot (the rescue restart). Default: rely on the D2 restart.

### Gate facts

Publish: local branch only, GitHub remote, no CR/AutoSDE, no push.
Call sites, packages/*: none touched. wifiworker::rssi() callers: telemetry.cpp EINF, display_stream.ino status line / idle reassociate / link heal, ui_screens.cpp status card / survey / info bar, signal_led.cpp, serial_config.cpp CFGSHOW. requestReconnect: supervisor retry. requestReassociate: idle reassociate, link heal.
Lanes (all at a4d6e55): gate-run_tests.log exit 0; gate-test_espdisp.log 1895 OK; gate-compile-{p4,s3,c6,c3}.log exit 0; release-shipping.log exit 0 (bundles from a4d6e55, hook absent).
Red first: red-first-hosted-rpc-budget.log (pre-fix code: 4 FAIL over 15 loopTask sites).
Adversarial review rounds: 1 independent; it changed D2, D4 and D5.

### Evidence

- baseline-scan-falsify.log: current code, task_wdt loopTask at 10.8 s.
- baseline-falsify.log: GPIO54 hold gives an SDIO restart, not a watchdog.
- final-scan-falsify.log, final-jam-falsify.log: fixed build, no watchdog; silent-C6 restart at 130 s.
- soak-15min.log: 889 s, 180 status lines, 0 resets, idle.
- code-review.md: the review and its dispositions.

### Residuals

- Soak without streaming (above). Only the 4C was run; the 4B shares the code (inferred).
- A POWERON reset follows the software restart on the 4C (the known power issue, not investigated).

## Layout cleanup (app-layout-cleanup)

### Outcome

The display window is reordered (what is changed first, read-only last), the hero carries board model, USB device and identity, network, uptime and battery, and the Firmware section shows the build on the board, matched to the bundled release. The firmware reports that build as a new optional field, verified on the 4C. Rebased onto main 0140c45.

### Decisions to evaluate

D1 The board reports its build as a new optional CFGINFO `src=` (last field) and mDNS TXT `src`, value `<40-hex commit>[-dirty]` from the same git provenance as the bundle manifest; EINF is untouched. Why: fits as a field old readers ignore. If overruled: drop src= and match by version only.
D2 The Power switch is the Screen switch at the leading end of the Brightness row; the slider rests while the screen is off. Why: pwr= is a standing screen-off (backlight 0, plus the panel's display-off command where supported; the 4C's panel refuses it), board still on WiFi. If overruled: separate row named "Screen".
D3 Flash progress and failure sit under the buttons in the floating footer of the update and Add Display sheets; the transcript stays in the form. Repair keeps its progress as its first section. If overruled: move Repair's into its footer too.
D4 Text is selectable at the root of every form and footer; disclosure labels opt out so they still open. If overruled: per-message modifiers.
D5 The installed revision is marked "- Installed"; the verb stays the version comparison, so every revision stays installable. If overruled: none needed for the standing rule.
D6 A USB write fails when the board restarts into a different or dirty build, or answers without a build after an image that names itself. If overruled: version-only check.
D7 Serial line buffer 512 -> 768 bytes so src= is never trimmed off the longest CFGINFO. If overruled: move src= earlier in the line.
D8 1.5.0 shipping bundles regenerated from 367ddd3 (on main 0140c45) under the same version. If overruled: bump FW_VERSION, which was not asked for.
D9 The hero placeholder and region footer use the panel's own mounted shape, not PixelConvert's 172x320; that was a code bug, not the fixture. If overruled: revert to the fixed aspect.

### Open questions

- Does selecting text in the detail pane get in the way of any click in the running app? Default: disclosure labels opt out; not checked in the live app (no app launched).
- Copying evidence into the main checkout to capture it: answered "Copy in briefly, then delete". Done each time; main status left clean.
- 4C power: answered "I will power it properly". Done; the board held steady for the flash and tests.

### Gate facts

- Publish: local commits on app-layout-cleanup only; not pushed, no CR cut.
- packages/* call sites: none touched.
- Lanes (gate-*.log): swift test, firmware run_tests, test_espdisp, generate --check, release-info, compile c3/c6/s3/p4, bundle regeneration, Release xcodebuild (derived data /Users/stepblk/Source/esp32-display-layout-build; /tmp tree deleted).
- 4C hardware (hw-*.log): banner and CFGSHOW report src=367ddd3; CFGPOWER 0 gave pwr=off, then CFGPOWER 1 gave pwr=on. The panel's display-off command returned err=262 on this board. Backlight level unverified by serial: the firmware prints no level.
- Adversarial review: 2 rounds (code-review.md); every should-fix fixed.

### Evidence

- 1-detail-top.png, 2-detail-full.png, 3-detail-screen-off-other-build.png: detail pane.
- 4-update-writing.png, 5-update-failed.png, 6-update-ready.png: update sheet footer.
- gate-*.log: gate lanes; hw-*.log: 4C flash and serial captures (SSID redacted).

### Residuals

- Captures draw glass opaque (glass is not composited offscreen), so the prominent button's label is invisible in them.
- The human's look at the dark 4C screen was requested; no answer is recorded here.

## Audio on every capable board (audio-enable-boards)

### Outcome

Audio runs on the seven boards whose vendor hardware has it: 1.75C, 1.85C V2, S3-LCD-0.85, S3-Touch-LCD-1.54, P4 4B, 4C and 3.4C. The other six have none. Rebased onto main 0140c45. The 4C speaker is verified: the human heard its tone. S3 detection no longer pulls up the 1.85C V2 amp enable before identification.

### Decisions to evaluate

D1 Audio turns on only after ES8311 reads 83 11 and ES7210 reads 72 10 over I2C at boot (read-only, retried once, cached per boot); the amp pin is driven low at that moment. Why: an ACK alone could be another device; this also tells 1.85C V2 from V1. If overruled: trust the descriptor alone.
D2 A failed ID on any board returns the existing 1.85C CFGERR text. Why: the CFG surface stays unchanged. If overruled: a new string.
D3 The 0.85's codec bus (SDA 42 / SCL 41) goes in optional `audio.pin_control_sda/scl`, which are refused beside a touch bus. Why: one Wire bus. If overruled: a second Wire port.
D4 Two-slot 16 kHz I2S capture (MIC1/MIC2) on every board, not the vendors' 4-slot TDM. Why: one backend sequence; no protocol change. If overruled: TDM and echo cancellation.
D5 start() checks the cached verdict and never re-probes. Supersedes: re-probing in start(), because review found that it races touch/IMU reads on the shared Wire buffer.
D6 The 1.85C bus is probed before the 1.75C's; a probe on any audio board's amp enable runs only while no earlier bus has answered. Why: the 1.75C's SDA is the 1.85C V2's GPIO15 amp enable. Trade-off: a board answering on both buses now resolves as the 1.85C, not Unknown, so each probe re-checks the canary after its list. If overruled: keep the old order and accept the pull-up.
D7 The amp is not driven low before identification. Why: until the IDs are read, GPIO15 may be V1's mic clock; the V2's 10K pull-down (R42) holds it low from reset. If overruled: drive GPIO15 low on every S3 boot.
D8 The 3.4C gets the 4C's audio row without a hardware check. Why: its wiki links the same XC schematic, and the XC BSP's audio pins do not depend on the panel. If overruled: mark its audio unknown until a 3.4C is tested.

### Open questions

- Tone heard? Answered by the human, "yes and yes": 16:23 PDT, clean and steady for about 5 s.
- How to attach logs? Answered by the human: copy one into main, capture, delete. Done each time; sha256 matched and main stayed clean.
- Is the 0.85's second mic fitted? Default: 2 channels, as on the schematic.

### Gate facts

Publish: local branch `audio-enable-boards`, rebased onto main 0140c45; the old tip is kept as local branch `audio-enable-boards-pre-rebase`. Intermediate bundle and rescue commits were dropped and rebuilt once. Nothing pushed, no PR, no CR (GitHub remote).
Call sites, packages/*: none touched. Shared symbols changed:
- `RevisionNotApproved` was renamed `HardwareNotIdentified`: `audio_test.cpp`, `test_audio.cpp`.
- `boardAudioStatus()` gates transport, engine, `audio_test.cpp` and backend `start()`.
- New seams `runI2cProbes` and `addressListEvidence` serve `probeS3`, `collectI2cEvidence` and `variantFromS3Probe`.
- `I2cProbePlan.quietAfterMatch` is emitted by the generator and read by `shouldRunProbe`.

Lanes at 389b0c6, all green (gate-full.log):
- `run_tests.sh`: 107006 checks, plus 835 audio, 4 seam and 554 rescue
- `test_espdisp.py`: 1930 checks
- compile c6, s3, p4, c3
- descriptor `--check`
- `swift test`: 745 tests

Review rounds: 2. Round 1 changed D5; round 2 added D6's canary re-check. The one deferred finding is in code-review.

### Evidence

- gate-full.log: every lane.
- red-first: the probe loop pulled GPIO15 on a simulated 1.85C; the identity seam against 93684af started I2S for an impostor at 0x18/0x40 (a V1 cannot show this red: the old gate refused all 1.85C); canary, validator and F1/F3 reds.
- hw-4c-serial: chip-ID boot line, caps 003967ef, tone test.

### Residuals

- Unverified: the 4C mic (app only). Not attached: 4B, 3.4C, 1.75C, 1.85C V1 and V2, 0.85, 1.54. A USB watcher is armed for them.

## Board WiFi report and capture orientation (app-wifi-orientation)

### Outcome

The settings window shows the network the board reports ("Connected WiFi") apart from the Mac's saved list ("Saved on this Mac"). Boards announce their joined network over WiFi, and the 4C did so on hardware. Every capture source streams upright. Rebased onto 696d0ae with the stall monitor intact; 1.5.0 bundles regenerated. Gates pass.

### Decisions to evaluate

D1 The board names its joined network in an mDNS `ssid` record (WiFi.SSID()), shown without USB; USB still names the network it is set to join. EINF is unchanged. Why: the sender parses EINF by exact length. Supersedes: showing the name over USB only, because the human chose "Add the network name". If overruled: drop the record and the row says "Connected (name not reported)".
D2 The saved picker preselects nothing unless the board reported a saved network or the user picked one. Supersedes: falling back to the first saved name, because that was the bug. If overruled: restore the fallback.
D3 One rule for every source: landscape exactly when the glass is rectangular and at 90 or 270. The source is fitted in, so a wide display on a portrait panel at 0 is letterboxed but upright. If overruled: crop to fill.
D4 On rectangular glass the marquee has no Rotate, and a region of the wrong shape is turned to match. If overruled: change the rotation to match the region instead.
D5 A shape-changing rotation reshapes the running stream; a failed reshape stops capture for a rebuild. Why: a picker share may not survive a rebuild. If overruled: always restart.
D6 "Connected" comes from genuine replies within 10 s, else the newest of reply-silence and the USB report. Why: reconnects refresh the heartbeat without a reply. If overruled: use Online status.

### Open questions

- A sideways panel using a landscape region at 0 degrees gets it stood upright on upgrade. Default: stood upright; 90 or 270 restores it.
- The 4C was running the audio worker's build (audio records, caps 003967ef) before this check; it now runs this branch's canonical p4 bundle, with audio off. Default: left on canonical as instructed; the audio worker reflashes when it needs it.
- Record conflict: this file and code-review.md keep both this section and the stall worker's. Default: both kept.

### Gate facts

- Publish settings: local commits only; no push, no PR, no review service.
- Call sites: no packages/* symbol touched.
- swift test at f8e99dd: 742 tests, 0 failures, five red runs first. Log: swift-test.log.
- Firmware host tests pass (two red runs first); compile c3, c6, s3, p4 exit 0 (c6 93%); test_espdisp 1889 checks OK; release --shipping --regenerate-existing 1.5.0 from clean 98e75c7, p4 sha256 9f21c9f4. Log: firmware.log.
- Release app build at f8e99dd succeeded; it embeds the new p4 bundle. Log: release-build.log.
- 4C under the port lock: flash exit 0 (MAC e8:f6:0a:e0:a0:e4), WiFi up, mDNS `ssid` present (absent before), canonical reflash exit 0. Log: hardware.log.
- Adversarial review: 3 rounds, 18 findings; 17 fixed, 1 accepted.

### Evidence

- wifi-rows.png: the two rows rendered offscreen in six states.
- hardware.log: the locked flash, boot log, mDNS records before and after, reflash.
- swift-test.log, firmware.log, release-build.log: gate runs with red runs.
- code-review.md: causes, rebase and every finding.

### Residuals

- App side unconfirmed: the running app (build 342, before this change) has not heard from the board since 14:47, and the announced name is not saved to panels.json. Needs a relaunch of this build.
- CFGSHOW got no reply within 6 s right after the serial capture; the boot log showed WiFi up.

## Capture stall restart (capture-stall-restart)

### Outcome

A capture stream that stops delivering frames on a live panel is now restarted within about a minute, shows a failure in the window if restarts do not bring it back, and clears when frames return. The periodic repaint no longer relights a panel on a stale picture while the Mac's displays sleep. Cause of the Sep 25-28 stall: not proven; see Open questions.

### Decisions to evaluate

D1 Liveness is judged by real frames, not samples; 60 s without one probes with a restart, backed off to 300 s while probes keep proving the screen static. Why: idle/blank status samples kept the old 120 s any-sample check happy on a dead stream. If overruled: change CaptureStallMonitor.stallAfter / maxStallAfter.
D2 A failure is shown only after a restarted stream gives no frame in 10 s (retries back off to 120 s). Why: every routine restart flagged would train the user to ignore it. If overruled: change firstFrameGrace, or show on the first probe.
D3 Every ScreenCaptureKit call is bounded at 10 s, and lookups fail fast for 30 s after a timeout. Why: one call that never returned wedged the watchdog. If overruled: change DisplayCapture.callDeadline / unresponsiveRetry.
D4 Silence is not judged while paused, the captured display sleeps, the session is locked or off console, a followed window is off screen, or no application of an app-only picker selection has an on-screen window; a failure shown then is cleared and returns after wake if still dead. If overruled: edit DeviceSession.isCaptureLive.
D5 The refresh repaint is skipped between ESLP and EWAK and while paused; the firmware's wake-on-drawn-frame rule is unchanged. Why: app-only fix, no firmware release. If overruled: also gate it in firmware.

### Open questions

- How the raw test log reaches the evidence (the capture tool reads only the main checkout). Answered by the human: copy it in, attach, delete at once. Done; the main checkout was left clean and nothing was committed there.
- Which path stalled build 336? Default: two confirmed-in-code candidates, neither observed: status-only samples fooling the any-sample check, or a wedged ScreenCaptureKit await (low confidence either way). The display slept Sep 26 03:17 to Sep 28 09:15 with no system sleep; the repaint explains the stale lit picture during that window (confirmed in code), but frames=5 in 900 s after wake means capture itself had also stopped. The new stall log line (sample age, last status, frame count) names the path next time.

### Gate facts

Publish: local branch capture-stall-restart on main 93684af; GitHub remote, no CR/AutoSDE/PR, nothing pushed or merged.
Call sites, packages/*: none touched. Changed internal symbols: shareableContent (9 lookups in Capture.swift); noteRegionApplied(_:requested:) (2 region starts in DeviceSession.run); FrameSender.refreshAllowed (refresh timer only).
Lanes at bd068f8: swift test 705/0 (capture-stall-swift-test.log); Release xcodebuild + codesign (capture-stall-release-build.log); red-first 7eaba9d (capture-stall-red-test.log) and 683e237 (capture-stall-app-filter-red.log); mutations (capture-stall-mutation-red.log).
Adversarial-review rounds: 1 (separate agent); it added D4 and D5 and changed D1's backoff.

### Evidence

- code-review.md: the round's 13 findings and dispositions.
- Logs above, in /Users/stepblk/Source/esp32-display-capture-stall-scratch/.
- No screenshot: the human is at the screen; the visible change is one status line.

### Residuals

- Not run live or on hardware; the live run is the human's own use after the Project Agent installs the merged app.
- Built app, not installed: /Users/stepblk/Source/esp32-display-capture-stall-scratch/dd/Build/Products/Release/ESPDisplaySender.app

## USB Repair (usb-repair-flow)

### Outcome

Repair (on main as e95e38e) now has the independent review's findings 1, 2, 3, 5 and 6 fixed on usb-repair-flow. Finding 4 is left as is (unverified on the 4C); 7 and 8 are left as they are. Not yet run on hardware.

### Decisions to evaluate

D1 After a rescue, Install is a firmware-only USB flash of the bundled release (hardware ID, esptool MAC and chip, write, CFGSHOW with fw=), not onboarding. Why: NVS survives, and onboarding refuses an already-added display. If overruled: route new boards through onboarding.
D2 Back in Add Display, the repaired port is selected, so WiFi is next. If overruled: close the sheet.
D3 Background CFGSHOW probes are held from Start until Start Over or close. Why: the 2 s poll would open the board at the same moment esptool does. If overruled: hold per stage.
D4 esptool runs under a /bin/sh watchdog that hangs up its group when the app's pipe closes. Supersedes: making the pty the controlling terminal, because macOS posix_spawn does not. If overruled: kill on quit only.
D5 Install is disabled while a stored CFGBOARD override is reported; Clear Override sends CFGBOARD auto. If overruled: warn only.
D6 Rescue backlight 32/255, set before the first draw on command-dimmed AMOLEDs; the P4's C6 is held on GPIO54. If overruled: change rescuemodel::BACKLIGHT_LEVEL or the hold.
D7 A new port's USB device is taken from the IORegistry (IOSerialBSDClient up to IOUSBHostDevice); the name is parsed only as a fallback, with the real rules usbmodem<serial>N and usbmodem<location without trailing zero nibbles>NN (also in tools/espdisp.py). If overruled: names only.
D8 A port is refused after 3 failed writes in a row, or at once on esptool's "Wrong --chip argument?", with "is it an ESP32-X board?". If overruled: change UsbRescue.failuresBeforeRefusal.
D9 A board the rescue image did not identify (profile=auto target=unknown) gets no Install, and the message names the family chosen. Supersedes: falling back to the chosen family, because the family alone does not say which display it is. If overruled: install the family's universal image.
D10 esptool gets 120 s after "Connected to"; a hung write is killed and counts as a failed write. If overruled: change UsbRescue.writeTimeout.
D11 Boards attached at Start stay ignored for the whole run; the start message now says so and names them, instead of "unplug it now". If overruled: forget ports that vanish during start-up.

### Open questions

- Is GPIO54 the C6 reset on the 4C, and is st7703-4b right for it? Default: unchanged and unverified; the P4 rescue image still assumes the 4B (finding 4).
- An early capture sent CFGSHOW (maybe an esptool chip-id) to the P4 port around 00:24 on Sep 26. Default: capture removed, P4 worker told. Confirm nothing was disturbed.
- How logs reach the human: answered "Accept the attached summary".

### Gate facts

Publish: local branch usb-repair-flow on main e95e38e, linear; GitHub remote, no CR/AutoSDE, no push.
Call sites, packages/*: none touched. UsbRescue.identity(forPort:devices:) callers: UsbRescuer.run only (plus tests); usb_identity_for_port callers: run_rescue only.
Lanes (red then green in the same log): swift-test.log (421 + 680), python-test_espdisp.log (1865), firmware-run_tests.log (476 rescue checks), compile-<family>.log x4, xcodebuild-app.log.
Adversarial-review rounds: 2 own + 1 independent; the independent one changed D7-D11.

### Evidence

- gate-summary.md: verdict lines; full logs in /Users/stepblk/Source/esp32-display-usb-repair-logs/.
- code-review.md: all review rounds and dispositions.

### Residuals

- No hardware run: catch window, watchdog, dim panel, C6 draw, wrong-chip text from a real esptool.
- tools/espdisp.py rescue still retries a wrong chip forever and has no write limit (findings 2 and 6 fixed in the app only).

## P4 4C board (board-p4-lcd-4c)

### Outcome

Adds the Waveshare ESP32-P4-WIFI6-Touch-LCD-4C (JD9365, 720x720 round) to the P4 image. P4 now detects its carrier at boot, verified on a real 4B too. The attached 4C resolves to `jd9365-4c` and gets WiFi on the final 1.5.0 bundle. It no longer loses power; the separately tracked hosted-WiFi watchdog restarted it twice in the first 40 s, then 180 s ran clean.

### Decisions to evaluate

D1 P4 stops being compile-fixed: both carriers share one image and are detected at boot. Why: one artifact per family, and the 4C's I2C bus (0x14/0x5D, 0x18, 0x40) answers exactly like the 4B's. If overruled: a second P4 artifact.
D2 A carrier needs two agreeing signals: 4C = DCS 0x04 ID 93 65 04 (measured) + GPIO52 low; 4B = GPIO52 high (its PHY's 1.5K MDIO pull-up) + any other completed read. Else Unknown (CFGBOARD recovery). Why: never mistake one board for the other on one signal. Supersedes: ID-only with a 4B catch-all, because review found that a corrupted 4C read would become a 4B. If overruled: match the 4B's measured 38 21 1F exactly.
D3 The ID read runs in a task with a 1 s deadline. Why: the SDK read never times out, so an absent panel would hang boot. If overruled: poll the DSI host directly.
D4 P4 USB writes still require `--profile`, now either carrier. Why: the image drives the DSI PHY and reset of any P4. Supersedes: dropping the requirement, because that widened a destructive write. If overruled: family alone.
D5 JD9365 is a vendored adapter (`esp_lcd_jd9365`) with the BSP's 4-inch table, like `esp_lcd_st7703`. Why: no new dependencies. If overruled: pull the Espressif component.
D6 Vendor timing kept: 1500 Mbps, 80 MHz pclk, porches 20/20/40 and 12/4/24. Audio stays off, as on the 4B (ES8311, ES7210, NS4150B present). If overruled: lower pclk; enable P4 audio.
D7 The board's brightness was set to 128 over serial (`CFGBRIGHT`) after flashing. Why: the human chose this port plus lower brightness; at 217 it dies before WiFi. The app has since set 96. If overruled: reset in the app.
D8 The 3.4C is its own profile, `jd9365-34c`, told from the 4C only by the GT9271's stored config resolution (register 0x8048, read-only): 720x720 measured on the 4C, 800x800 inferred for the 3.4C. The JD9365 table differs in one byte (page 1 reg 0x40). Why: same PCB, same panel ID, no strap. If overruled: drop the profile and pin 3.4Cs with CFGBOARD.
D9 The 4B requires its measured ID 38 21 1F plus GPIO52 high. Supersedes: D2's any-other-read rule for the 4B, because the human asked for the measured ID. If overruled: restore dsi_panel_id_other.
D10 An unresolved P4 drives BL_EN GPIO33 low and PWM GPIO26 high, only because every P4 carrier wires them alike. If overruled: leave the pins alone.
D11 The Mac chip-only fallback, the Repair flow and `espdisp.py rescue` all require a named P4 carrier; Repair refuses to install when the rescue image reports a different one. If overruled: family alone.

### Open questions

- Is a 4B log needed before shipping? Answered: test on a 4B first. Done on e8:f6:0a:e0:b5:5a: GPIO52 high, ST7703 ID 38 21 1F, probe verdict st7703-4b, and the bundle boots with CFGSHOW `board=st7703-4b` (4b-probe.log, 4b-boot.log, 4b-identity.log). Nothing blocks shipping.

### Gate facts

Publish: local branch `board-p4-lcd-4c` only; nothing pushed, no PR, no CR (GitHub remote).
Log capture: the capture tool reads only the main checkout, so per the human's answer gate-firmware-tests.log was copied there, captured and deleted at once; the other logs are pasted as notes.
Call sites, packages/*: none touched. Shared symbols changed:
- `detectFromEvidence`/`evaluate` gain an optional panel-ID argument; only P4 callers (`probeP4`, `variantFromP4PanelId`) pass it.
- `required_profile` was renamed `required_profiles`; its one reader is `_validate_flash_profile`.

Lanes at 13e19e0 (rebased onto main e95e38e), all green:
- `run_tests.sh` (gate-firmware-tests.log)
- `test_espdisp.py` (gate-test-espdisp.log)
- `generate_board_descriptors.py --check` (gate-descriptor-check.log)
- `compile --family p4|s3|c6|c3` (gate-compile-<family>.log)
- `swift test`, 673 tests (gate-swift-test.log)
- app build (app-build.log)

Adversarial-review rounds: 2. Round 1 changed D2 and D4 and added D3.

### Evidence

- code-review.md: both rounds and each finding's fate.
- device-boot.log, device-identity.log: final bundle boots as jd9365-4c, and CFGSHOW answers. EINF has no serial reply (it is UDP).
- device-soak-final-120s.log, device-soak-final-180s.log: no USB drop or power loss; 2 then 0 watchdog restarts.
- diag-power-isolation.log: power loss needs backlight 217 and WiFi together.

### Residuals

Closed on branch p4-4c-gaps (aab2d3a): the 3.4C profile (D8), bootstrap accepts jd9365, backlight off when unresolved (D10), carrier guards (D11), the timeout path (proven on the 4C: read failed after 0.93 s, CFGBOARD recovery), the exact 4B ID (D9), and the CFGBOARD hint (now `st7703-4b|jd9365-4c|jd9365-34c|auto` on P4). Remaining:
- EINF over UDP is still not witnessed. The firmware now logs `net: EINF <n> bytes to <ip>:<port>` when its sender changes, but the running app sent the 4C nothing during the tests.
- The 3.4C profile has not run on 3.4C hardware; the 4B has not run the touch-config read.
- The loopTask watchdog on a stuck hosted RPC and P4 audio are tracked on their own rows.

## USB keyboard and mouse for Doom (usb-input)

### Outcome

A USB keyboard and mouse now drive Doom alongside touch, tilt and BOOT, on the
three P4 carriers only. The hardware question is settled from the schematics:
the 4C and 3.4C power a device from a USB type A port; the 4B hosts one but
supplies no 5 V, so a keyboard there needs a powered hub or its own supply; no
S3 board can host, because its one USB pair is the connector it is flashed and
logged through. Unverified on hardware: nothing was flashed and no port opened.

### Decisions to evaluate

D1 USB input lives only inside a Doom session, brought up by DG_Init. Why: Doom is entered by a one-shot reboot, so normal streaming never installs the host stack and a board with nothing plugged in is unchanged. If overruled: the host stack would have to run during streaming and share loopTask with the frame path.
D2 Enabled on the 4B even though it cannot power a device, with a serial line saying so. Why: it can host a self-powered keyboard or a powered hub, and it is the only board attached. If overruled: the 4B refuses and the feature is untestable here.
D3 The per-board gate is a hand-written table in the Doom platform layer, not a new board-descriptor capability. Why: the descriptor schema and catalog format are reserved. If overruled: add a capability key and regenerate the board headers.
D4 In a menu every letter is itself; in play only W/A/S/D are mapped. Why: save names and the engine's y/n prompts need letters, while mapping them in play would turn stray typing into cheat codes. If overruled: map letters everywhere, or nowhere.
D5 Mouse buttons become engine key events (Fire, Use) rather than Doom's mouse-button bitmask. Why: the key path already holds, releases and reaches menus, and the touch code drives Fire the same way. If overruled: route data1 through DG_GetMouse instead.
D6 Vertical mouse movement walks, not looks. Why: Doom has no free look. If overruled: nothing in the engine to change.

### Open questions

- Does a real keyboard enumerate on the 4B through a powered hub? Default: shipped unverified; the human will try one. Nothing was flashed, and the only board was in use by another worker.
- Is the 4B's H2 VBUS truly dead when the board is powered through H1? Read from the AO3401 symbol and its gate circuit, not measured. Default: assume dead and say so on serial. A diode test on that contact, or reading it while powered through H1, settles it.
- Keyboards with no boot HID interface are ignored with a serial line rather than having their report descriptor parsed. Default: boot protocol only.

### Gate facts

Publish: committed to local main (1db3a9e, bundles 55f6d5b); GitHub remote, no CR/AutoSDE, no push.
Call sites, packages/*: none touched; this repo has no packages/ tree.
Lanes, gate-usb-input.log, all exit 0: run_tests.sh (test_usb_input 477) and test_espdisp.py at 04ac678; compile --family p4, s3, c3, c6 in the main checkout; release --shipping --regenerate-existing 1.5.0 from a clean tree at 04ac678.
Red first: red-first-usb-input.log fails at runtime on the old behaviour; the stuck-key fix was shown load-bearing by reinstating the bug.
Adversarial review rounds: 1 independent; 2 High and 11 lesser findings, all fixed. It changed D4 and the vertical mouse cap.

### Evidence

- usb-host-hardware.md: which board can host and power a device, from the schematics, with the residual doubts named. Committed as docs/usb-host-ports.md.
- gate-usb-input.log: the four lanes with their own exit codes, and the symbol check showing the S3 image links no host stack.
- red-first-usb-input.log: the suite failing on the old behaviour.
- code-review.md: the adversarial round and every disposition.

### Residuals

No hardware verification and no UX capture: the visible surface needs a flashed
board and a real keyboard. The S3 half is reasoned from seven schematics, not
measured. A scratch clone at /private/tmp/usb-bundle-clone is left behind; its
deletion was refused by the permission policy.

## P4 power cycling and dead WiFi (p4-power-cycling)

### Outcome

No power loss reproduced in 30+ min of USB logging. The rst:0x1 "power-on" resets were the serial
capture: pyserial with DTR/RTS set low resets a CH343 board 4 times out of 4, and leaving the lines
alone resets it 0 times out of 4. The real fault is the C6 WiFi link dying seconds into each stream. The cause is ESP-Hosted
2.12.11 in core 3.3.11, which deadlocks after one failed DMA allocation. Core 3.3.12 fixes it but is
the human's call. Committed: audio no longer leaks its I2S channel or retries every 120 ms, and the
P4's audio jitter buffer moves to PSRAM (+16 KB DMA RAM).

### Decisions to evaluate

D1 Free a channel the core's I2SClass leaks after a failed begin() ourselves: delete it, then rebuild the object in place. Why: the core's end() bails before deleting a never-enabled channel. If overruled: patch the core, which is the human's.
D2 Back off failed audio starts 1 s doubling to 16 s, muted, never holding video. Why: each retry ran I2C and I2S work on the engine core and flooded serial. If overruled: change StartBackoff in audio_engine_model.h.
D3 P4 audio jitter buffer in PSRAM first. Why: P4 internal RAM is all DMA-capable and the C6 link needs it. If overruled: one #if in audio_engine.cpp.
D4 No socket-buffer caps committed. Why: capping the P4 sockets only delayed the stall (34 to 724 packets) and costs burst tolerance. If overruled: 12 KB video, 16 KB audio on P4 was the tested value.

### Open questions

- Upgrade the project to Espressif core 3.3.12 (ESP-Hosted 2.12.13)? Raised to the human. Default: stay on 3.3.11, so P4 WiFi still drops seconds into a stream.
- Does the speaker amp brown out the board? Default: no. No reset occurred with the backend running, but no on-demand amp test was possible while the Mac streamed audio.

### Gate facts

Publish: committed to local main; GitHub remote, so no CR or AutoSDE; no push.
Call sites, packages/*: none touched; this repo has no packages/ tree.
Lanes, in a clean export of HEAD plus this change (gate-p4-power.log): run_tests.sh exit 0; compile p4, s3, c6, c3 exit 0. test_espdisp.py exit 1, only on its 4 rescue-image freshness checks: they diff firmware/rescue and firmware/libraries, which this change does not touch, and HEAD's board_touch.h edit (b8b7789) makes them stale.
Red first: red-audio-tests.log. Adversarial review rounds: 1, no blocking findings, 4 hardening findings fixed.

### Evidence

- serial-open-resets-p4.md: the open-recipe reset counts.
- c6-link-stall-core-3.3.12.md: runs on both cores, the memory, the upstream fix.
- serial-4c-final.log: the 4C up 148 s on 3.3.12 with WiFi connected.
- code-review.md: the review and its dispositions.

### Residuals

The 4C runs a scratch 3.3.12 build of this commit, not a project build; on 3.3.11 it restarts every
~110 s. One real USB drop, both boards together but not their hub, at 17:15 before logging began,
is unexplained. The human's bench bridge had switched itself onto the 4C's port; the human stopped it. Rescue images are stale on HEAD (the boot-menu worker's b8b7789). The scratch folder
/Users/stepblk/Source/powerloss-scratch holds a 5.5 GB core install.
