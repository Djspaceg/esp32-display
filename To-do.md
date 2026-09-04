# To-do

- [x] Publish universal `c6`, `s3`, and `p4` firmware-family infrastructure:
      single-family format-3 writers, canonical release catalog/storage,
      fail-closed app selection, and direct app resource embedding.
- [x] Add the reusable ESP32-P4 platform, ST7703 MIPI-DSI panel profile, and
      Waveshare 4B carrier profile with capability-gated ETL1 streaming.
- [ ] Complete attached 4B hardware validation: display colors, edges, four
      transforms, portrait touch corners/releases, BOOT rotation, and backlight
      controls now pass. Hosted-C6 compatibility, odd-orientation touch corners,
      reconnect, ETL1 streaming/loss recovery, tearing, and OTA recovery remain
      blocked until compatible C6 firmware is established.

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
  - [x] Size-gated direct-from-SRAM draw — BUILT, MEASURED, REMOVED (§18.4):
        lost 30–60% complete fps in every interleaved sample, because the
        CASET/queue work it moves onto the receive task stalls the drain
        loop and drops datagrams. On one oversubscribed core, work moved
        between tasks is not work removed. Side discovery worth more than
        the feature: tile-motion emitted per-tile records (719/frame) where
        the real sender merges runs (44–92); fixing the tool nearly doubled
        baseline delivery (7.3 → 12.8 complete fps at the same offered pixel
        load), so per-record cost is first-order and §18.1's sweep
        understated real-traffic capacity.
  - [ ] Stop sharing core 1: §18.2 and §18.4 both show same-core shuffling
        cannot win — parallelism is the remaining device-side lever.
    - [x] Build the reboot-swappable mechanism: CFGRXCORE <0|1> pins the
          receive task's core, NVS-persisted so an A/B arm swap is a
          5-second reboot (§18.6). Both arms verified swapping live.
    - [ ] Measure the arms once the link carries the §18 operating point
          again (`ping -s 1450` under ~15 ms; it sat at 328 ms idle when the
          mechanism was built). Interleave CFGRXCORE 0/1 under tile-motion
          half-res 25 and 35 fps; if core 0 wins it becomes the default.
  - [ ] Fewer, larger records: §18.4's record-count finding re-opens
        vertical/multi-row coalescing on the SENDER side (more tiles per
        record within the 32-tile and datagram limits), which §17.5 deferred
        on draw-call grounds — the win now shows up in receive-path decode
        cost, not draw calls.
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
