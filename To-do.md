# To-do

- [ ] HIGH PRIORITY: Recover full-frame rate on the 466×466 panel. Full-frame
      updates deliver 1–4 fps because the panel absorbs only ~300 datagrams/s
      while painting (congestion collapse, docs/tile-stream-plan.md §17.3–17.4),
      and a full frame is 66 (BC1) to ~300 (raw) datagrams. Work these in order:
  - [x] Fix draw starvation by scheduling — MEASURED AND CLOSED (§18.2):
        priorities are not the fix. Raising the draw's priority flattens
        per-call cost to the quiet ~775 µs but delivers the FEWEST frames,
        because the receiver then starves instead — core 1 is oversubscribed
        at overload and priorities only choose which half starves. The boot
        arrangement stays. The real levers are cutting CPU per frame and
        adding a core (next two items).
    - [x] Make the two task priorities runtime-tunable via CFGTUNE (rxprio,
          loopprio) and build the interleaved-arm harness
          (tools/measure_sched_arms.py).
    - [x] Measure the arms at the collapse point (§18.2; the first attempt
          was radio-bound, §17.17).
  - [x] Let half-res carry full-frame motion: a half-res full frame is ~17
        datagrams → ~16 fps at the current absorbable rate (14.2 complete fps
        measured, §17.7).
    - [x] Verify the quality policy is not pinned to losslessOnly (settings
          hold tileQuality=auto).
    - [x] Ride interval keyframes at half-res while surrounding diffs are over
          budget (keyframeRidesHalfRes); quiet-screen keyframes stay lossless
          and the refresh timer heals a half-res screen back to full quality.
  - [ ] Cut draw CPU per frame: size-gate a direct-from-SRAM draw for large
        runs — records of at least N tiles draw straight from the decode
        scratch while still committing to bufA for persistence, deleting the
        gather that §18.2 measured at 30–40% of pass time under load. §17.16
        only tested and rejected the ungated per-record variant; needs a
        cross-task draw lock (receive task and loop() would both issue panel
        calls). Measure at the §18 operating point (half-res, 35 fps offered).
  - [ ] Stop sharing core 1: move the draw pass to its own task pinned to
        core 0 (WiFi/lwIP live there but their CPU work is bursty), so the
        two heavy loops stop arbitrating one core. §18.2 shows arbitration
        cannot win — parallelism might. Compile-time experiment; measure at
        the same operating point.
  - [x] Re-measure sender ceilings on the new firmware (§18.1) and retune:
        ingest now accepts ~600 datagrams/s and delivery peaks at ~450/s
        offered, so tileAbsorbablePacketsPerSecond moves 300 → 450. Repeat
        after each device-side win.
  - [ ] After contention is fixed, revisit per-call fixed costs: vertical run
        merging and CASET/RASET elimination, re-argued on the quiet ~900 µs
        per-call figure (§17.5).
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
