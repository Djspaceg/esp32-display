# Orientation Call Sites

## Shared Model

Changed API: `motionorient::classify`, `motionorient::Tracker::update`, and new `motionorient::automaticModeForPanel` in `firmware/libraries/espdisp_board/src/motion_orientation.h`.

Every production call site:

- `firmware/display_stream/orientation.cpp`
  - Selects four-way or flip-only from `PanelConfig.width == PanelConfig.height`.
  - Calls `Tracker::update` at 10 Hz.
  - Applies the committed automatic correction through existing `compose`.

Every test call site:

- `firmware/test/test_band_protocol.cpp`
  - Calls `automaticModeForPanel` for square and rectangular dimensions.
  - Calls `classify` for thresholds, calibration, four-way cardinals, and flip-only side rejection.
  - Calls `Tracker::update` for dwell, candidate reset, touch blocking, rollover, and flip-only stability.

Repository search found no other `motionorient::classify`, `Tracker::update`, or `automaticModeForPanel` consumers.

## P4 Rotation Capability

Changed data: `PANEL_ST7703_720X720.supportsCommandRotation`.

Every reader of `PanelConfig.supportsCommandRotation`:

- `firmware/display_stream/control_apply.cpp`: accepts or refuses network `Rotate` values.
- `firmware/display_stream/serial_config.cpp`: accepts or refuses USB `CFGROT` values.
- `firmware/display_stream/telemetry.cpp`: advertises `CAP_ROTATE`.
- `firmware/test/test_band_protocol.cpp`: asserts P4 enables the capability.

The resulting app path:

- `mac/ESPDisplaySender/Sources/SenderCore/PanelManager+DeviceControls.swift`
  - `supportsQuarterTurnRotation` requires known square geometry for network
    `CAP_ROTATE`, or the complete verified USB gate below.
  - `usbDevice(..., reports: .quarterTurn)` requires a rotation status field,
    USB-reported `CAP_ROTATE`, and `usbBoardSupportsQuarterTurns`.
  - `ManagerWindow` shows the existing four-way picker when `supportsQuarterTurnRotation` is true.
  - `setRotation` sends network `Rotate` or USB `CFGROT`.
- `mac/ESPDisplaySender/Sources/SenderCore/WifiConfigUI.swift`
  - `usbIdentity` parses the additive CFGSHOW `caps=` bitset only after the exact
    `ssid64`/`ssid` boundary; absent, spoof-like, or malformed values remain nil.
- `mac/ESPDisplaySender/Tests/SenderCoreTests/PanelManagerTests.swift`
  - Verifies `st7703-4b` stays flip-only without USB-reported `CAP_ROTATE` and
    exposes quarter turns only when the capability is present.
- `mac/ESPDisplaySender/Tests/SenderCoreTests/WifiConfigTests.swift`
  - Verifies valid, absent, and malformed CFGSHOW capability values.

## Profile Impact

- `st7789`: no IMU, rectangular, manual 0/180 unchanged.
- `jd9853`: IMU, rectangular, automatic changes from disabled to flip-only.
- `gc9107`: no IMU, square, manual four-way unchanged.
- `st7789-130`: IMU, square, automatic four-way unchanged.
- `st7789-154`: IMU, square, automatic four-way unchanged.
- `co5300`: IMU, square, automatic four-way unchanged.
- `st77916`: no IMU, square, manual four-way unchanged.
- `st7703-4b`: no IMU, square, manual four-way newly enabled through the repaired DSI path.
