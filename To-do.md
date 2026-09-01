# To-do

- [ ] HIGH PRIORITY: Recover full-frame rate on the 466×466 panel. Full-frame
      updates deliver 1–4 fps because the panel absorbs only ~300 datagrams/s
      while painting (congestion collapse, docs/tile-stream-plan.md §17.3–17.4),
      and a full frame is 66 (BC1) to ~300 (raw) datagrams. Work these in order:
  - [ ] Fix draw starvation: the draw loop (loopTask, priority 1) shares
        core 1 with udpReceiveTask (priority 9), and per-call draw cost inflates
        ~10x under load (§17.2).
    - [x] Make the two task priorities runtime-tunable via CFGTUNE (rxprio,
          loopprio) and build the interleaved-arm harness
          (tools/measure_sched_arms.py).
    - [ ] Measure the arms on a panel whose link carries 430+ datagrams/s
          (needs ~RSSI -60; silver-round at -78 to -86 was radio-bound and the
          arms were indistinguishable — §17.17).
  - [ ] Let half-res carry full-frame motion: a half-res full frame is ~17
        datagrams → ~16 fps at the current absorbable rate (14.2 complete fps
        measured, §17.7). Verify the panel is not pinned to losslessOnly, and
        extend the degradation ladder to keyframes (half-res keyframe plus a
        lossless settle pass) so the 2 s keyframe stops stalling the stream for
        ~220 ms of pacing budget.
  - [ ] Size-gate a direct-from-SRAM draw for large runs: records of at least
        N tiles draw straight from the decode scratch while still committing to
        bufA for persistence, halving PSRAM traffic in exactly the full-frame
        case. §17.16 only tested and rejected the ungated per-record variant.
  - [ ] After contention is fixed, revisit per-call fixed costs: vertical run
        merging and CASET/RASET elimination, re-argued on the quiet ~900 µs
        per-call figure (§17.5).
  - [ ] Re-measure sender ceilings after each device-side win:
        tileAbsorbablePacketsPerSecond, the spacing bounds, and the degradation
        ladder budget all encode today's collapse point and will hide any
        firmware improvement until retuned.
- [ ] Improve display streaming frame rate beyond the current implementation.
  - [x] Replace line-only diffs with 16×16 tiles and horizontally merged rectangular runs.
  - [x] Add tile compression, SRAM staging, merged panel writes, and backpressure handling.
  - [ ] Re-measure end-to-end frame rate on hardware and optimize only against an identified bottleneck.
- [x] Support rotation in 90-degree increments on square displays.
- [x] Keep region scale and rotation controls on the visible region overlay.
- [x] Show battery level and the best available charge state on each battery-capable touch device.
  - [x] Parse and show reported battery status in the macOS app.
  - [x] Verify each board's battery telemetry hardware and enable its implementation.
  - [x] Show battery level and the best available charge state in the on-device UI.
- [x] Allow the display to be turned off and on remotely.
- [x] Persist screensaver settings.
- [x] Show uptime and battery status with the primary streaming information.
- [x] Restore Wi-Fi information reported by the device into the macOS network selector.
- [x] Make the complete diagnostics disclosure header clickable and use normal macOS disclosure spacing.
- [x] Add appropriate horizontal padding to the window-header Pause button.
- [x] Expose touch controls for the 466×466 touch display.
- [x] Prevent frame backlog timestamp underflow from flashing the idle screen during updates.
- [x] Avoid transmitting pixels outside the visible circle of a round display.
  - [x] Skip tiles that are entirely outside the circle.
  - [x] Ignore changes that affect only invisible pixels in boundary tiles.
  - [x] Eliminate remaining invisible collateral in changed boundary blocks without corrupting BC1-visible pixels.
- [ ] Use the onboard accelerometer to keep content upright at cardinal orientations.
  - [x] Read and classify QMI8658/QMI8658A acceleration with hysteresis and dwell.
  - [x] Compose automatic orientation with the persisted manual mounting rotation.
  - [ ] Physically calibrate glass-relative axis signs on each IMU-equipped board in all edge-down positions.
  - [ ] Define correct 90-degree behavior for rectangular displays before enabling it there.
- [x] Add native Cocoa Scripting support for non-destructive app and display controls.
  - [x] Publish and package an AppleScript dictionary.
  - [x] Route script commands through `PanelManager`.
  - [x] Validate commands with a built app and `osascript`.
- [x] Add remote reboot.
- [x] Make the literal-overrun regression use an exactly sized heap destination under ASan/UBSan.
