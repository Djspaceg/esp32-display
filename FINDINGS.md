# Orientation Findings

## Claims

| Claim | Basis | Confidence | Falsifier status |
| --- | --- | --- | --- |
| Rectangular automatic orientation can no longer commit rotation 1 or 3. | LIVE: `AutomaticMode::FlipOnly` returns `INVALID_ROTATION` for side cardinals, and the runtime test covers both sides plus tracker dwell. | High | Not falsified by host tests. A device log showing `auto=1` or `auto=3` on a non-square panel would falsify it. |
| Square automatic orientation still supports all four cardinals. | LIVE: the four-way classifier and tracker tests cover 0, 1, 2, and 3. | High | Not falsified by host tests. Missing one cardinal after six-position calibration would falsify it. |
| Manual orientation is retained as a persisted base rotation, with automatic correction added transiently. | LIVE: `compose(manual, automatic)` remains additive modulo four; only `panelRotation` is persisted. | High | Not falsified by host tests. A reboot that persists `automaticRotation`, or an automatic update that changes `panelRotation`, would falsify it. |
| Side gravity on a rectangular panel holds the last stable 0/180 state until gravity settles into an up/down bucket for 500 ms. | LIVE: flip-only side samples are invalid, which clears candidates without changing the stable rotation; up/down samples use the existing dwell and hysteresis. | High | Not falsified by host tests. A side hold that changes the stable rotation would falsify it. |
| The P4 DSI orientation path is now reachable from the app. | LIVE: `PANEL_ST7703_720X720.supportsCommandRotation` is true, firmware advertises `CAP_ROTATE`, and the verified-USB board list includes `st7703-4b`. | High for software reachability | Physical q=1/q=3 behavior is not falsified or confirmed here because boards were not touched. |
| Wrong axis signs produce a wrong but stable orientation rather than classifier chatter. | INFERRED from the classifier's dominance thresholds, hysteresis, and 500 ms dwell. | Medium-high | Host tests prove stability mechanics, but six-position hardware calibration is still required to falsify wrong signs per profile. |

## Profile Matrix

| Profile | Family | Panel | Square | IMU | Automatic behavior | Manual app choices | Axis evidence |
| --- | --- | ---: | --- | --- | --- | --- | --- |
| `st7789` | C6 | 172x320 | No | No | None | 0/180 | N/A |
| `jd9853` | C6 | 172x320 | No | Yes | Flip-only | 0/180 | Identity axes from vendor examples only; no six-position field evidence |
| `gc9107` | S3 | 128x128 | Yes | No | None | 0/90/180/270 | N/A |
| `st7789-130` | S3 | 240x240 | Yes | Yes | Four-way | 0/90/180/270 | Identity axes from vendor examples only; no six-position field evidence |
| `st7789-154` | S3 | 240x240 | Yes | Yes | Four-way | 0/90/180/270 | Identity axes from vendor examples only; no six-position field evidence |
| `co5300` | S3 | 466x466 | Yes | Yes | Four-way | 0/90/180/270 | Field evidence for X=+1, Y=-1 |
| `st77916` | S3 | 360x360 | Yes | No | None | 0/90/180/270 | N/A |
| `st7703-4b` | P4 | 720x720 | Yes | No | None | 0/90/180/270 | N/A |

The source-of-truth `PanelConfig` describes `st7703-4b` as 720x720, so the backlog wording that calls it rectangular does not match the current board table.

## Validation

- Untouched baseline: firmware tests and all three family compiles passed.
- Untouched baseline failures: `tools/test_espdisp.py` and `swift test` both failed on deleted build-212 release artifacts.
- After change: firmware tests and all three family compiles passed; tool and Swift failure sets matched the baseline.
- Focused app test: verified-USB P4 exposes quarter-turn orientation.
- Release rehearsal: C6, S3, and P4 bundles validated; S3 and P4 each carried a 4,196,020-byte `doom_wad`.
- No boards, serial devices, or foreground app windows were touched.
