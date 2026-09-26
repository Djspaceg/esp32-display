# Outcome

Adds the ELECROW CrowPanel 1.28" ESP32-S3 rotary knob as S3 runtime profile
`gc9a01-knob-128`. The user confirmed it online and working on glass. Knob
turn and press are wired but still need their own mapping.

# Decisions to evaluate

D1 The knob push switch (GPIO41) is the board's BOOT button, and GPIO0 is left unassigned. Why: the firmware has exactly one button input. If overruled: set `pin_boot = 0` and the knob press does nothing.
D2 An encoder detent steps the existing button controls: it moves the WiFi selector, and otherwise picks the high or low backlight preset. Why: the brief forbids new wire or CFG commands. If overruled: the follow-up knob-mapping task replaces `applyEncoderTurn`.
D3 The encoder is decoded one step per A edge, direction from B, per the EC3501-C15H30 datasheet (30 detents per 15 pulses); clockwise follows ELECROW's decoder. Supersedes: a full-cycle-per-detent decoder, because the datasheet says half-cycle. If overruled: restore the full-cycle model in `rotary_encoder_model.h`.
D4 GPIO1, which switches the LCD rail, becomes the new optional `carrier.pin_panel_power`. The encoder lines become `pin_encoder_a` and `pin_encoder_b`. All three default to -1. Why: other descriptors, including the parallel Waveshare board, stay valid unchanged. If overruled: make them required and add them to every descriptor.
D5 The S3 knob probe power-cycles GPIO1 as its reset line, and runs only when no earlier probe answered. Why: the CST816D is unpowered otherwise, and other S3 boards keep their GPIO1 undriven. If overruled: reorder the probes.
D6 Address-list probes ignore a bus that acknowledges reserved 0x7F. Why: on this board the unpowered GC9A01 clamps GPIO11 low, which false-matched the 1.85C and halted boot. If overruled: detection returns to the 1.85C false match.
D7 The panel reuses the C3 board's `PANEL_GC9107_240X240` at 40 MHz; the vendor runs 80 MHz. Why: one shared panel profile. If overruled: fork the panel profile at 80 MHz.
D8 Variant 11, catalog and detection order 70. Why: this leaves 10 and 60 for the Waveshare worker. If overruled: renumber.
D9 The bootstrap tool now refuses to drive GPIO41, 42 and 45 while the knob is a possible S3 candidate. This blocks the 1.3" and 1.54" templates. Why: those pins are switch contacts to ground. If overruled: drop them from `_forbidden_drive_pins`.

# Open questions

- Knob and click usefulness: the default is D2 until the separate mapping task.
- Encoder clicks per step and direction are unmeasured; the default is D3.
- Touch corner mapping is unmeasured; the default is raw axes, as ELECROW ships them.
- The 5-LED ring (GPIO48) and power LED (GPIO40) are left undriven; the default is off.

# Gate facts

Publish settings: local branch only, no push, PR, CR or merge. The user merges.
Call sites, packages/*: none touched.
Adversarial-review rounds: 1 independent round, which changed D3, D5 and D9.
Every lane below passed on the final HEAD:
- descriptor check: `gate-descriptor-check.log`
- firmware host tests: `gate-firmware-tests.log`
- `test_espdisp.py`: `gate-test-espdisp.log`
- S3 compile: `gate-compile-s3.log`
- `swift test`: `gate-swift-test.log`
- macOS app build: `app-build.log`

# Evidence

- `device-flash.log`: canonical S3 bundle regions written to 68:EE:8F:5D:AC:8C, verified, no erase.
- `device-boot.log`: the false 1.85C match that D6 fixes.
- `device-flash-dev-canary.log`: dev app with the fix, app region only.
- `device-boot-dev-canary.log`: the knob detected, panel and touch up.
- `device-identity-dev-canary.log`: the CFGSHOW reply.
- `code-review.md`: the review and what became of each finding.

# Residuals

- The final bundle commit was not re-flashed, per instruction; the board runs the equivalent dev build of `0803984`.
- No knob turn or press events were captured.
- EINF is UDP only and the board has no WiFi.
- Merging with the Waveshare branch will conflict in the S3 probe table, the descriptor count and the bundles. Re-run the generator and the release after merging.
