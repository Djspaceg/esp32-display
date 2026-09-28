# Outcome

Repair (on main as e95e38e) now has the independent review's findings 1, 2, 3, 5 and 6 fixed on usb-repair-flow. Finding 4 is left as is (unverified on the 4C); 7 and 8 are left as they are. Not yet run on hardware.

# Decisions to evaluate

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

# Open questions

- Is GPIO54 the C6 reset on the 4C, and is st7703-4b right for it? Default: unchanged and unverified; the P4 rescue image still assumes the 4B (finding 4).
- An early capture sent CFGSHOW (maybe an esptool chip-id) to the P4 port around 00:24 on Sep 26. Default: capture removed, P4 worker told. Confirm nothing was disturbed.
- How logs reach the human: answered "Accept the attached summary".

# Gate facts

Publish: local branch usb-repair-flow on main e95e38e, linear; GitHub remote, no CR/AutoSDE, no push.
Call sites, packages/*: none touched. UsbRescue.identity(forPort:devices:) callers: UsbRescuer.run only (plus tests); usb_identity_for_port callers: run_rescue only.
Lanes (red then green in the same log): swift-test.log (421 + 680), python-test_espdisp.log (1865), firmware-run_tests.log (476 rescue checks), compile-<family>.log x4, xcodebuild-app.log.
Adversarial-review rounds: 2 own + 1 independent; the independent one changed D7-D11.

# Evidence

- gate-summary.md: verdict lines; full logs in /Users/stepblk/Source/esp32-display-usb-repair-logs/.
- code-review.md: all review rounds and dispositions.

# Residuals

- No hardware run: catch window, watchdog, dim panel, C6 draw, wrong-chip text from a real esptool.
- tools/espdisp.py rescue still retries a wrong chip forever and has no write limit (findings 2 and 6 fixed in the app only).
