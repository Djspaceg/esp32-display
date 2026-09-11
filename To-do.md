# To-do

- [ ] Complete attached 4B hardware validation: display colors, edges, four
  transforms, portrait touch corners/releases, BOOT rotation, and backlight
  controls now pass. Hosted-C6 compatibility, odd-orientation touch corners,
  reconnect, ETL1 streaming/loss recovery, tearing, and OTA recovery remain
  blocked until compatible C6 firmware is established.
- [ ] HIGH PRIORITY: Recover full-frame rate on the 466×466 panel. Full-frame
  updates deliver 1–4 fps because the panel absorbs only ~300 datagrams/s while
  painting (congestion collapse, docs/tile-stream-plan.md §17.3–17.4), and a
  full frame is 66 (BC1) to ~300 (raw) datagrams. Work these in order:
  - [ ] Stop sharing core 1: §18.2 and §18.4 both show same-core shuffling
    cannot win — parallelism is the remaining device-side lever.
    - [X] Build the reboot-swappable mechanism: CFGRXCORE <0|1> pins the
      receive task's core, NVS-persisted so an A/B arm swap is a 5-second reboot
      (§18.6). Both arms verified swapping live.
    - [ ] Measure the arms once the link carries the §18 operating point again
      (`ping -s 1450` under ~15 ms; it sat at 328 ms idle when the mechanism was
      built). Interleave CFGRXCORE 0/1 under tile-motion half-res 25 and 35 fps;
      if core 0 wins it becomes the default.
  - [ ] Fewer, larger records: §18.4's record-count finding re-opens
    vertical/multi-row coalescing on the SENDER side (more tiles per record
    within the 32-tile and datagram limits), which §17.5 deferred on draw-call
    grounds — the win now shows up in receive-path decode cost, not draw calls.
  - [ ] After contention is fixed, revisit per-call fixed costs: vertical run
    merging and CASET/RASET elimination, re-argued on the quiet ~900 µs per-call
    figure (§17.5).
- [ ] Improve display streaming frame rate beyond the current implementation.
  - [ ] Re-measure end-to-end frame rate on hardware and optimize only against
    an identified bottleneck.
- [ ] Use the onboard accelerometer to keep content upright at cardinal
  orientations.
  - [ ] Physically calibrate glass-relative axis signs on each IMU-equipped
    board in all edge-down positions.
  - [ ] Define correct 90-degree behavior for rectangular displays before
    enabling it there.
- [ ] tripple-press boot button no longer activates doom
- [ ] c6 boards aren't flashable any more
- [x] when i choose to flash a device, for everything except s3, the firmware
  isn't pre-selected.
- [ ] OTA updates are broken
- [ ] tripple-tap and double-tap boot on the 185-v2 displays don't actually do
  anything, just toggle brightness.
- [x] We need more states for paused, connecting, streaming.
- [ ] Change between saved WiFi presets from the device itself. Open the signal
  survey, then hold BOOT or touch to open the selector; move with a short
  BOOT press or swipe, and select with a BOOT hold or tap.
- [x] The list needs to be alphabetically sorted, and ideally would have
  user-selectable, remembered, sort orders: alphabetical, by date added, by
  astatus (subsorted alphabetically), etc.ß
