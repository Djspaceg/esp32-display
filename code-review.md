# Code review: in-app USB Repair flow and low-power rescue image

Branch `usb-repair-flow`, `git diff main...HEAD` (main = e229bff). Two adversarial rounds, each run by a read-only reviewer agent (git and file reads only; no builds, no ports).

## Round 1 (whole diff)

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

## Round 2 (a116dcf, f533b55, 0407b20)

| # | Severity | Finding | Disposition |
|---|----------|---------|-------------|
| 1 | Low-med | The CO5300 AMOLED leaves its init at 0x51 0xFF and was dimmed only after a successful draw. | Fixed in 7203ccd: dimmed to BACKLIGHT_LEVEL before the draw, and set to 0 if the draw fails; a host test checks the order. Images rebuilt from 7203ccd (6646068). |
| 2 | Low | Stop during Clearing reported "did not answer" after the override had in fact been cleared. | Fixed: after the send, a cancelled run returns "Stopped - override cleared, not re-read". |
| 3 | Low | After a failed clear, the advice said Start Over while the button said Clear Override. | Fixed: the clear failure carries its own next action. |
| 4 | Hardening | No release in `deinit`; `deinit` kill can block; pipe CLOEXEC is not atomic. | Deferred, recorded in DECISIONS.md Residuals (the first); the other two are negligible in practice. |

Round 2 checked the watchdog script in full, the fd lifecycle, hold balance, the safety of GPIO54 on the only P4 profile (pins 27/26/35/7/8/33), `analogWrite` behind the USB-pin guard, and image provenance (source_commit clean, hashes match).

## Call sites of the shared enums changed (SenderProtocol)

`UsbFlashPhase` (+ `.rescue`), `UsbFlashSession.Flow` (+ `.repair`):
- `UsbFlashPhase.title`, `.detail`, `.fraction` (UsbFlashProgress.swift)
- `UsbFlashSession.fail` step, `lastSeen`, `defaultNextAction` including its inner `Flow` switch
- `AddDeviceSheet.isWritingFlash` (default arm; that monitor never sees rescue phases)
- `FirmwareUpdateSheet.isWaitingForResult` (`if case`, unaffected)
- `UsbFlashStatusView` (reads title/detail/fraction only)
- `UsbRepairModel.canStop`, `UsbRepairModel.headline`
- `EsptoolCommand.rescueWriteFlash` is new; `writeFlash` is unchanged and still validates it.

## Process note

An early UX capture rendered `AddDeviceSheet`, whose `onAppear` refreshes USB. It auto-selected the attached P4 port and began its CFGSHOW inspection. That capture was removed; the capture test now renders only `UsbRepairView`, which does no USB I/O.
