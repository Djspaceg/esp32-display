# Independent adversarial review: CrowPanel 1.28 rotary knob support

Branch `add-board-elecrow-s3-rotary-128`. It replaces the previous
`code-review.md`, which covered the C3 round-panel branch. That review is still
in git history at `784b845` and `2f0420f`.

An independent reviewing agent read commit `db98e5e` without edit access. It
checked the code against ELECROW's Eagle schematic, the factory sketch and the
EC3501 datasheet at Elecrow-RD commit `4c4d893`, and ran both host suites.
It found no Critical or High defects. The dispositions below are the authoring
session's. A post-handoff independent review of the final tip is still owed.

## Findings and dispositions

1. **Medium: the detent model contradicted the EC3501-C15H30 datasheet.**
   The datasheet gives 30 detents per 15 pulses, with A stable at each detent,
   but the decoder assumed one full cycle per detent.
   **Fixed** in `5496324`: one step per A edge, with direction from B. Tests
   cover chatter on B, bounce on A and two-line jumps. The click count per step
   is still unmeasured on hardware.
2. **Medium: turn direction was the opposite of ELECROW's clockwise.**
   **Fixed** in `5496324`: A changing to differ from B is +1, as in the vendor
   table.
3. **Medium: the bootstrap tool's forbidden-drive list omitted the encoder
   lines.** A 1.54 template session drove DC on GPIO45.
   **Fixed** in `5496324`: both lines are forbidden, and a refusal test covers
   it.
4. **Low-Medium: the knob probe pulsed GPIO1 on every other 16 MB S3 board.**
   On the 1.54 that is the battery sense, and every boot paid about 320 ms.
   **Fixed** in `5496324`: a probe with a reset line runs only if no earlier
   probe answered (`boarddetectmodel::shouldRunProbe`, host-tested).
5. **Low: the rail floats after the probe, and the comments overstated it.**
   **Fixed (comments)** in `5496324`. Behaviour is unchanged: the rail is
   re-driven before the panel is reset, and touch re-pulses its own reset. It
   is verified on hardware (touch reads chip B6).
6. **Low: the probe waits 300 ms but touch init waits 50 ms.**
   **No change.** On hardware, touch init read the CST816D at 50 ms.
7. **Low: the validator did not check optional pins against touch, power or
   audio wiring.**
   **Fixed** in `5496324`: optional pins are checked against all non-detection
   wiring and included in the audio collision check, with tests.
8. **Low: press-and-turn fired the press action, and steps were applied one at
   a time.**
   **Fixed** in `5496324`: a turn cancels that press's action, and the net
   turn is applied once per pass (the selector moves at most 4 rows).
9. **Info: the IRAM comments were inaccurate.** The core dispatches GPIO
   interrupts from flash.
   **Fixed**: the IRAM claims are gone and the decoder is plain inline code.
10. **Info: side effects of the regeneration on other boards.** The rows only
    gain `-1` fields, and the probe count goes from 4 to 5.
    **Acknowledged.** The expected merge conflicts with the Waveshare branch
    are noted in `DECISIONS.md`.

## Found on hardware after the review

- **High (fixed in `8673c39`): the knob board false-matched the 1.85C and
  halted.** The 1.85C probe on SDA 11 / SCL 10 saw ACKs because the unpowered
  GC9A01 clamps GPIO11 low (`device-boot.log`). The firmware then stopped at
  `FATAL: display init failed` without servicing serial, which explains the
  earlier hung serial writes.
  **Fix:** address-list probes also address reserved 0x7F and discard ACKs
  from a bus that answers it.
  **Verified:** `device-boot-dev-canary.log` shows the knob detected, the panel
  up and touch ready. The user confirmed it working on glass.
