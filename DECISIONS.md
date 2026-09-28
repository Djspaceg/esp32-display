# Integrated decisions (main)

Each finished branch keeps its own record below.

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

- The 3.4C (same PCB and JD9365) would detect as a 4C.
- Bootstrap cannot bring up a 4C.
- An unresolved P4 leaves the backlight lit.
- The Mac app picks the P4 image from chip alone (already on main).
- The timeout path is untested on hardware.
- The loopTask watchdog on a stuck hosted RPC is tracked on its own row.
