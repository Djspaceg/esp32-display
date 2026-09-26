# Outcome

Adds `espdisp.py rescue --family <c3|c6|s3|p4>` and per-family images in `firmware-rescue/`. On the 1.9 it caught the first plug-in, detected st7789-190, and the user saw RESCUE on the glass; 1.5.0 was restored with NVS intact.

# Decisions to evaluate

D1 Built on main with be0cca5 merged in, so the S3 rescue image detects the 1.9 as st7789-190. Why: the user answered "Build on main - everything should be on main, so i can use it". If overruled: n/a. Supersedes: pre-merge images that saw a 1.9 as a 1.3.
D2 The rescue firmware never drives the chip's USB Serial/JTAG pads, so a real 1.3 shows a drawn but unlit panel. Why: it cannot tell a correct detection from a misdetection. If overruled: allow GPIO19/20 on UART-bridge carriers.
D3 One esptool waits on a symlink `/dev/../<tmp>/port`, pointed at the only port new since start-up. Supersedes: a pool of four, because esptool 5.3 retries every 0.1 s. If overruled: n/a.
D4 A linked port not connected within 10 s is refused while attached; esptool's whole process group is killed (SIGTERM, then SIGKILL) and a new one gets a new link. Why: esptool retries silently forever, and its PyInstaller child outlives a plain kill. If overruled: change `RESCUE_CONNECT_TIMEOUT`.
D5 A port seen before "Plug the board in now", or a new port whose USB device (serial or location, from ioreg) was attached then, is never touched. Why: never touch another board. If overruled: a board plugged in too early must be replugged after Ctrl-C.
D6 Rescue images are raw region files plus `rescue.json`, not `.espdispfw` bundles; partition table, bootloader and boot_app0 match the release byte for byte (tested). Why: never look like a release; NVS survives. If overruled: bundles.
D7 CFGSHOW gets a CFGINFO reply with id, board, profile, target, chip, partition and a new cfgboard= field, and no fw=. Why: parsers look fields up by name; a rescue image must not claim a release. If overruled: add fw=.
D8 An unidentified S3 also answers on UART0 (GPIO43/44), like the stream firmware. Why: the 1.3's bridge and the ROM console. If overruled: USB CDC only.
D9 A host test fails when `firmware/rescue`, `firmware/libraries` or a partition CSV changed since a family's `rescue.json` commit. Why: stale images misread new boards. If overruled: a printed warning.
D10 The rescue image reads the stored CFGBOARD key, shows a forced profile in red and in cfgboard=, and `CFGBOARD auto` removes only that key; `rescue` warns with the exact command. Why: the real firmware would force it again and re-brick USB. If overruled: have `flash` clear it.

# Open questions

- None. D1 was answered by the user (build on main).

# Gate facts

Publish: local branch `add-rescue-firmware` only; no push/PR/CR/merge, no AutoSDE or cr (GitHub remote).
Call sites, packages/*: none touched. Shared tool functions changed:
- `esptool_invocation` gains optional `connect`/`tool`; callers `part_matches_device`, `write_bundle_over_usb` (unchanged), `rescue_spawner`.
- `git_provenance` ignores `firmware-rescue/`; callers: bundle/release manifests and `write_rescue_images`.

Lanes, all green: `run_tests.sh` (firmware-tests.log), `test_espdisp.py` (py-tests.log), `compile --family` x4 (compile-<family>.log), `rescue-build` x4 (rescue-build-<family>.log).
Swift unchanged. Adversarial-review rounds: 3. Round 1 changed D3 and D4; round 2 added D9; round 3 changed D4, D5 and D7 and added D10.

# Evidence

- code-review.md: all three review rounds and each finding's fate.
- device-rescue-{flash,boot}-1_9.log: rescue on the 1.9 (1c:db:d4:7b:5b:94), boot as st7789-190.
- device-restore-{flash,boot}-1_9.log: 1.5.0 restored, board=st7789-190 fw=1.5.0.
- rescue-red-green.log: new tests red on ef5ca1d and 5c9d998, green after the fix.
- rescue-pty-dryrun.log: real esptool on a pty; timeout kills the tree, nothing left.

# Residuals

- Detection can be wrong (C3/P4 always match; an 8 MB S3 is a GC9107); only the USB-pin guard is absolute.
- Images rebuilt from another checkout path differ byte-wise (absolute `__FILE__` paths).
