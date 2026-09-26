# Code review: rescue image and `espdisp.py rescue`

Scope: `git diff main...add-rescue-firmware`. Three independent rounds. That covers `firmware/rescue/`,
`firmware/test/test_rescue_model.cpp`, the `run_tests.sh` hookup, the rescue
section plus `esptool_invocation` and `git_provenance` in `tools/espdisp.py`,
`tools/test_espdisp.py`, `README.md` and `firmware-rescue/`.

## Round 1: independent adversarial review

The reviewer read the esptool 5.3.1 sources (`__init__.py` `connect_loop`,
`loader.py` `get_usb_vid_pid`) against the tool, and checked every board config
against the firmware's pin plan.

| # | Severity | Finding | Disposition |
|---|---|---|---|
| 1 | Medium | With `open_port_attempts = 0`, esptool 5.3.1 retries connect failures forever and prints nothing. A wrong-family or non-Espressif port hung `rescue` silently, and the "relaunch on a miss" only covered failures during the write. | Fixed. After a port is linked, it is given 10 s (`RESCUE_CONNECT_TIMEOUT`) to reach "Connected to". If it doesn't, the link is removed, the port is named, and it is not linked again while it stays attached. Test: foreign port, then the real board. |
| 2 | Low-med | A port that dropped after esptool opened it cost 15 s of grace, during which new ports were ignored. | Fixed. The grace period is gone. A port that vanishes before "Connected to" is unlinked at once, and the same esptool keeps waiting. Only a failure after connecting ends esptool, and that triggers a relaunch. |
| 3 | Low | esptool retries every 0.1 s, not about once a second (1 s is the dot interval), so the staggered 4-esptool pool bought nothing. The `/dev/..` docstring was also wrong for 5.3.1. | Fixed. There is now one esptool; the pool, the phase tracking and their tests are removed. The docstring now says 5.3 resolves symlinks anywhere and 5.1 only under `/dev/`, which is why the spelling is kept. |
| 4 | Low | A waiting esptool was orphaned on SIGTERM. | Fixed. SIGTERM raises KeyboardInterrupt during `rescue`, so the `finally` kills esptool. `ESPTOOL_OPEN_PORT_ATTEMPTS` is pinned too, because the environment setting overrides the cfg file. |
| 5 | Low (design) | Detection can be wrong: C3 and P4 always match, and an S3 with 8 MB flash is treated as a GC9107. A misdetected board gets another board's non-USB panel pins driven. | Accepted, and the brief specifies it ("pins confirmed to belong to the detected board"). The USB-pin guard is the hard guarantee. It is listed under Residuals in DECISIONS.md. |
| 6 | Cosmetic | On the 1.3 the firmware logged "glass stays dark" and then "shows RESCUE". | Fixed. The dark-backlight path logs once and returns. |

Test gaps the reviewer raised, and what was done:
- The fake esptool now never exits on a connect failure, matching 5.3.1.
- There are new tests for the connect timeout, refusing the same port again, relaunching after a failure past the connect, and the "waiting again" announcement.
- The worker test now uses a buffered pipe, as Popen does.

Checked and found not to be bugs:
- No path drives S3 19/20, C3 18/19, C6 12/13 or P4 24/25. That covers the detection probes, panel init (including vendored driver reset lines, `board_io.h` and the DSI backlight/enable), the backlight and `Serial0`. The only collision is the 1.3 backlight on GPIO20, which is blocked.
- The pin plan covers every GPIO the init path drives.
- `drawScreen` DMA accounting is correct: one completion per band, and a buffer is kept rather than freed on timeout.
- The layout fits every one of the 10 profiles under ASan/UBSan.
- Non-blocking `BufferedReader.read` returns None, which is handled.
- The ready and connected markers match 5.3.1 output.
- A port attached before the start is never linked.
- There is no spawn storm.
- The argparse wiring is correct.
- Region addresses and partition, bootloader and boot_app0 bytes match the canonical releases.
- The CFGINFO fields match the stream firmware.

## Round 2: independent adversarial review of the merged branch

Scope: the whole branch after merging main (be0cca5, which added the 1.9). The
reviewer ran `test_espdisp.py` (1792 checks) and the rescue host test built
with ASan/UBSan (244 checks), and read the real device logs from the 1.9 rescue
and restore.

| # | Severity | Finding | Disposition |
|---|---|---|---|
| F1 | Medium | On the 10 s connect timeout the tool only removed the link. An esptool part-way through a connect pass (about 2.4 s each) still held the port open. It could then write a board the user had just been told to unplug. Or it could exit 0 while unlinked and be reported as fatal. | Fixed. On timeout, esptool is killed and a fresh one is spawned; the port stays refused while attached. The test asserts that the esptool that gave up is killed and that a new esptool flashes the next board. |
| F2 | Low | `connect_attempts = 3` means a USB-UART board never got esptool's fourth reset sequence (the longer ClassicReset), because every pass starts the cycle over. | Fixed. It is now `connect_attempts = 4`, which covers all four bridge sequences in each pass. |
| F3 | Low | Nothing checked that the committed images still matched their sources, which is how pre-merge images saw a 1.9 as a 1.3. | Fixed. `test_rescue_images` now runs `git diff --quiet <source_commit> -- firmware/rescue firmware/libraries <partition csv>` for each family and fails with the `rescue-build` command to run. Red-green check: a one-line edit to `rescue.ino` made all four families fail; reverting it passed. Byte-reproducibility across different checkout paths, which comes from absolute `__FILE__` paths, is left as a residual. |
| R1 | Low | README said rescue writes "the same four regions as flash", but s3/p4 `flash` also writes the Doom WAD. It also didn't mention the 1.3's dark panel. | Fixed. The README now lists exactly what rescue writes, says the WAD survives, and notes the 1.3. |
| M1 | Minor | `last_error()` picked esptool's generic pySerial driver note instead of the actual error. | Fixed. It now prefers lines that name an error, skipping the "Note:" and troubleshooting lines. A test was added. |

Checked by round 2 and found not to be bugs:
- No unguarded pin drive in any of the 11 profiles; the 1.9 sense pin GPIO4 is covered by a test.
- The 1.9 config, sense detection and active-low backlight work inside the rescue image. The boot log shows 309 mV → st7789-190.
- DMA band lifetime.
- The image layout matches the 1.5.0 bundles; no erase and no eFuse writes.
- A port attached before start-up is never linked, even if it appears in the same poll as the ready line.
- Output markers match 5.3.1.
- SIGTERM cleanup.
- P4 UART bridge and DSI.
- All round-1 fixes are still in place.

## Round 3: independent review (independent-review.md, at 5c9d998)

No P0s. The reviewer ran esptool against a nonexistent port path, with no USB
involved, to show that the process tree survives a plain kill.

| # | Severity | Finding | Disposition |
|---|---|---|---|
| F1 | Medium | On the connect timeout the tool only removed the link. An esptool holding the port could still write a refused board, or exit 0 and be reported against the wrong port. The "Connected to" line is also printed unflushed. | Fixed. On timeout esptool is killed and relaunched on a fresh link. It now runs on a pty, so the line-buffered "Connected to" is seen at once. Tests: a board whose connect lands at 10.4 s is never written, and an unflushed "Connected to" from a real child process is seen while it still runs. Both are red on 5c9d998 / ef5ca1d and green after. |
| F2 | Medium | `Popen.kill` stopped only the PyInstaller bootloader; the real esptool (its child) survived, still held the port, followed the same link, and leaked a 20 MB `_MEI` directory. | Fixed. esptool runs with `start_new_session=True`. `kill()` sends `killpg` SIGTERM, waits, sends SIGKILL if anything survives, closes the pty and removes the link. Each spawn gets its own `port-<n>` link (`rescue_spawner`). Tests: a real parent/child fake tree dies completely (red before), and two spawns get distinct links with the full argv and environment checked. The pty dry run with the real esptool shows no process, link or `_MEI` directory left. |
| F3 | Medium | A stored CFGBOARD override survives rescue, and the follow-up `flash` forces it again (for example, st7789-130 on a 1.9 re-bricks USB). | Fixed. The rescue image reads NVS `espdisp/board`, reports the profile the stream firmware would force as `cfgboard=` in CFGINFO and as a red `CFGBOARD <profile>` line on the glass, and answers the existing `CFGBOARD auto` by removing only that key. `rescue` reads CFGSHOW from the port it just flashed and prints the exact `config --port <p> CFGBOARD auto` command. The host tests cover `effectiveOverride` with the stream firmware's rules, the warning fitting all 11 panels, and the tool warning with retry. |
| F4 | Low | The baseline was by port name only, so a re-enumerated attached board could look new. | Fixed. The baseline also records USB identity (location, serial) from `ioreg -d 1`, which takes about 20 ms. A new port whose device matches by serial or location is ignored and reported. The live read-only check mapped `/dev/cu.usbmodem1312201` to (0x131220, `1C:DB:D4:7B:5B:94`). An unresolved port falls back to the name check. |
| F5 | Low | The fakes encoded the F1/F2 assumptions, and nothing tied `planPins` to what bring-up drives. | Fixed. The fakes now hold an open port across an unlink for one connect pass, and the tree and flush tests use real processes. The firmware test scans `panel_init.h`, `panel_init_dsi.h`, `board_io.h`, `display_backend.h` and `rescue.ino` for every `.pin*`/`->pin*` they read, requires each to be in the plan's field lists, and moves each listed field onto a USB pad to check that it really blocks the panel. |

Red and green for every item: rescue-red-green.log. The red runs used the new
tests against ef5ca1d, which has the round-2 fixes including the F1
timeout-kill, and against the reviewed 5c9d998 itself. The green run is at the
fix commit. Two caveats. The identity test's port names were made realistic
after the red run; it was red only because the API was missing. The F5 firmware
scan is a new guard with nothing to fix, so it has no red.

## Local analyzers

AutoSDE and `cr` were not run. The repository's only remote is GitHub, and the
brief forbids pushing, PRs and any other publishing, so no diff was sent
off-host.
