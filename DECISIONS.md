# Outcome

The Mac app gains Repair (Add Display > "Not listed? Repair a Board...", and Firmware Update > USB "Repair..."): pick the chip family, catch the board with a waiting esptool, write the bundled rescue image, then install the real firmware on the same screen. The rescue firmware now lights at 32/255 and holds the P4's C6 coprocessor in reset. Not yet run on hardware.

# Decisions to evaluate

D1 The install after a rescue is a firmware-only USB flash of the bundled release for the rescued board (hardware ID, esptool MAC and chip, write, CFGSHOW with fw=), not the Add Display onboarding. Why: a rescued board keeps its NVS, and an already-added display would be refused by onboarding. If overruled: route new boards through onboarding's flash-and-WiFi.
D2 Back in Add Display, the repaired port is selected, so WiFi setup is the next step there. Why: "continuing on the same screen". If overruled: close the sheet instead.
D3 While a repair runs, from Start until Start Over or close, the app's background CFGSHOW probe of new ports is held. Why: its 2 s poll would open the board at the same moment esptool does. If overruled: hold per stage only.
D4 esptool runs under a /bin/sh watchdog that hangs up its process group when the app's pipe closes. Supersedes: making the pty esptool's controlling terminal, because a test showed macOS posix_spawn does not do that. If overruled: kill in applicationWillTerminate only, which misses crashes.
D5 Install is disabled while the rescue image reports a stored CFGBOARD override, and "Clear Override" sends CFGBOARD auto. Why: the real firmware would force the profile again. If overruled: warn only, as the CLI does.
D6 Rescue backlight 32/255 on every path, set before the first draw on command-dimmed AMOLEDs. Why: the 4C's POWERON resets look like a power limit. If overruled: change rescuemodel::BACKLIGHT_LEVEL.
D7 The C6 is held in reset on BOARD_SDIO_ESP_HOSTED_RESET (GPIO54, core esp32p4 variant), only where the platform's WiFi is a hosted coprocessor. Why: it is the pin ESP-Hosted drives on the same boards. If overruled: leave the C6 running.
D8 Rescue images are rebuilt from 7203ccd (clean) and embedded in Resources/rescue/<family>/ by the existing embed build phase. Why: same path as release bundles. If overruled: n/a.

# Open questions

- Is GPIO54 the C6 reset on the new 4C board too? Default: assumed, because the stream firmware's ESP-Hosted uses it on every P4. Check on the 4C.
- An earlier capture of the Add Display sheet sent CFGSHOW (and possibly an esptool chip-id) to the attached P4 port around 00:24. Default: capture removed; the P4 worker was told. Confirm nothing on that board was disturbed.
- How logs reach the human (capture refuses this worktree): answered "Accept the attached summary".

# Gate facts

Publish: local branch usb-repair-flow only; GitHub remote, so no CR or AutoSDE; no push.
Call sites, packages/*: none touched. Shared enums changed in SenderProtocol: UsbFlashPhase gets .rescue and UsbFlashSession.Flow gets .repair. Every switch over them is listed in code-review.md.
Lanes, all green: swift test (swift-test.log: 421 + 673 tests), test_espdisp.py (python-test_espdisp.log: 1859 checks), run_tests.sh (firmware-run_tests.log: 476 rescue checks), compile x4 (compile-<family>.log), rescue-build x4 (rescue-build-<family>.log), app build (xcodebuild-app.log).
Adversarial-review rounds: 2. Round 1 changed D3 and D4; round 2 changed D6.

# Evidence

- gate-summary.md: each lane's verdict lines; full .log files in /Users/stepblk/Source/esp32-display-usb-repair-logs/.
- code-review.md: both review rounds and dispositions.
- repair-*.png in ../esp32-display-usb-repair-scratch/ux/: offscreen renders of the Repair screen; not capturable from this worktree.

# Residuals

- No hardware run yet: the catch window, esptool behaviour under the watchdog, the dimmer panel and C6 draw all need the board.
- The Repair model releases its probe hold only on close or Start Over; a view that never disappears would keep probes off until relaunch.
