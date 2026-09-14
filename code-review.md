# Self-Review

Adversarial self-review. The repository has no `/code-review` tool available, and the task explicitly prohibits CRUX/CR creation.

## Findings

No blocking code finding remains.

## Checks Performed

- Confirmed flip-only classification cannot return 1 or 3 from a new sample.
- Confirmed the production tracker begins at 0 and the panel mode is fixed after board selection, so a rectangular profile cannot inherit an odd stable state.
- Confirmed side samples clear candidates without changing the stable 0/180 correction.
- Confirmed touch blocking still clears candidates and preserves the stable correction.
- Confirmed manual rotation remains persisted and automatic rotation remains RAM-only.
- Confirmed no-IMU profiles never enter `serviceAutoRotation`.
- Confirmed all changed shared-model call sites were updated and enumerated in `CALL_SITES.md`.
- Confirmed P4 network and USB capability paths both reach the existing four-way app picker.
- Confirmed P4 DSI shared orientation state is covered by the merged linkage test.
- Confirmed no firmware version, release-note prose, committed release artifact, credential, serial device, or board was changed.

## Residual Risks

- `jd9853`, `st7789-130`, and `st7789-154` still need six-position axis calibration. A wrong sign will be stable but can select the wrong cardinal.
- P4 90/270 behavior is compiled and linkage-tested but not physically observed in this task.
- The repository's committed build-212 catalog references deleted artifacts, so the full tool and Swift suites retain their baseline failures until the separate manifest work lands.

## Hardware Expectations

- Square IMU panel: after 500 ms at each edge-down cardinal, content reorients through all four positions. The saved app orientation remains an additive mounting offset.
- Rectangular IMU panel: upright and upside-down flip after 500 ms; holding either side does nothing and keeps the previous stable orientation.
- No-IMU panel: rotating the board does nothing automatically; app orientation continues to work. P4 now shows the four-way picker.
