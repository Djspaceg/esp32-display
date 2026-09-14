# Rotation Capability Findings

## Result

The P4 USB quarter-turn defect is fixed in software.

- A verified P4 identity without `caps` no longer exposes 90/270 or permits
  `CFGROT` quarter turns.
- A verified P4 identity with `caps=00002000` still exposes all four rotations.
- Missing, short, over-wide, and non-hexadecimal capability values parse as no
  capability.
- An old-firmware SSID ending in `caps=00002000` cannot impersonate the absent
  extension field.
- Rectangular network geometry and unknown network geometry remain flip-only
  even if `CAP_ROTATE` is present.
- USB `CAP_ROTATE` without a known-square board identity remains flip-only.

## Red and Green

`firmware-dev/capability-red-green.log` contains both states:

- Red: the corrected old-firmware assertion failed twice against 997e4c1 at
  runtime, while the positive case passed.
- Green: the P4 cases, CFGSHOW present/absent/malformed parser cases,
  rectangular geometry, unknown geometry, and missing USB board identity all
  passed.

## Gate Comparison

Untouched baseline:

- `bash firmware/test/run_tests.sh`: passed, 104818 checks.
- `python3 tools/test_espdisp.py`: failed because the committed manifest names
  missing build-212 firmware artifacts.
- `swift test`: failed on the same missing build-212 firmware artifacts.

Post-change:

- Firmware host tests passed with 104818 checks.
- C6, S3, and P4 exact compile lanes passed.
- The tool and full Swift lanes retained the same dangling-manifest baseline
  failure. This change does not repair or alter that separate branch issue.
- Focused Swift contract tests passed.

One intermediate focused rerun reused a Swift module cache through a moved
symlink and crashed before tests with duplicate module-cache paths. The next
run used a fresh `--scratch-path` under `/Users/stepblk/Source` and passed all
54 selected tests; the failed infrastructure attempt remains visible in the
same red/green log.

## Backward Compatibility

The CFGSHOW change is additive. Old app and tool consumers continue parsing
their named fields and ignore `caps`. New app code accepts old firmware replies
but treats omitted or invalid `caps` as no quarter-turn support. The firmware
version remains 1.5.0, so the capability report, not the version string,
distinguishes installed behavior.

## Hardware Limits

No board or `/dev/cu.*` path was touched. Hardware is still required to confirm:

- A real P4 on the older 1.5.0 firmware shows only 0/180.
- A P4 with firmware built from this change shows 0/90/180/270.
- Physical P4 90/270 rendering and touch behavior are correct.

## Scratch and Refused Cleanup

All generated trees are under `/Users/stepblk/Source`, beside the main checkout.
The accidentally in-worktree Swift tree was moved to
`/Users/stepblk/Source/esp32-display-rot-capability-swift-scratch-accidental`.

The environment refused this cleanup command and it was not retried:

`rm -rf /Users/stepblk/Source/esp32-display-rot-capability/esp32-display-rot-capability-swift-scratch`

## AutoSDE

Local AutoSDE session `ses-162d7ca54a7d` submitted the exact staged diff, then
returned `permission_denied`. It reported zero findings but did not complete a
successful analysis. No code review was created.
