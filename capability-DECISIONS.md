# Rotation Capability Decisions

1. Reuse `CAP_ROTATE`; do not allocate a new capability bit.

   `CAP_ROTATE` already means that the installed firmware accepts quarter-turn
   rotation, while `CAP_FLIP` means only the historical 0/180 control. Network
   EINF and mDNS already report this distinction. The USB path now reports the
   same bitset instead of deriving command support from the board token.

2. Add one strictly additive CFGSHOW field: `caps=%08lx`.

   The field name is `caps`. Its value is the existing unsigned 32-bit
   `DeviceProtocol.Capabilities` bitset as exactly eight lowercase hexadecimal
   digits. For example, `caps=00002000` reports `CAP_ROTATE` (bit 13). The field
   is appended after the human-readable `ssid=` value with the existing
   `bllevel=` and `fw=` extension fields.

   Firmware built from this change onward emits `caps`. `FW_VERSION` remains
   `1.5.0`, so an earlier 1.5.0 image may omit it and a later 1.5.0 image may
   include it. Version comparison is intentionally not used as a capability
   substitute.

3. Treat valid, absent, and malformed USB capability reports differently and
   fail closed.

   - Present and valid: parse exactly eight hexadecimal digits into the
     capability bitset. Quarter turns still require `CAP_ROTATE`.
   - Absent: leave USB capabilities nil. The app offers only 0/180.
   - Malformed, non-hexadecimal, or not exactly eight digits: leave USB
     capabilities nil. The app offers only 0/180.

   The parser decodes `ssid64`, consumes the exact matching human-readable
   `ssid=` value, and accepts `caps=` only as the first extension token after
   that boundary. An old-firmware SSID containing text that resembles `caps=`
   therefore cannot supply capabilities even though the legacy human-readable
   field is not escaped.

4. Keep existing CFGSHOW consumers backward compatible.

   The firmware only appends a new space-delimited key/value token; no existing
   token is renamed, reordered, or reinterpreted. Existing app consumers select
   only the fields they need (`ssid64`, name, ID, target, board, chip, partition,
   status, brightness, and firmware version) and ignore unknown tokens. The
   command-line tooling recognizes the `CFGINFO` prefix and does not require an
   exact token count. New app code also accepts old replies because missing
   `caps` parses as nil.

5. Require capability plus independent shape/identity evidence.

   The network path requires live `CAP_ROTATE` and known square geometry. Missing
   or rectangular geometry never enables quarter turns. The USB path requires a
   reported rotation/flip status, reported `CAP_ROTATE`, and the existing
   known-square board allowlist. Board identity alone is insufficient, and a
   capability report with a missing or unknown board token is insufficient.

6. Preserve rectangular behavior.

   A rectangular panel remains 0/180 even if it incorrectly reports
   `CAP_ROTATE`. This is enforced in app availability in addition to firmware's
   existing dimension and `supportsCommandRotation` checks.

7. Hardware confirmation remains separate.

   No serial device was opened and no board was flashed. A real P4 running the
   older 1.5.0 image should now show only 0/180 in the updated app, but that
   specific UI observation still requires a connected old-firmware P4.

## Call Sites

- `serialcfg::formatShowExtension` formats `caps`, brightness, and firmware
  version; `serial_config.cpp` is its production caller.
- `deviceCapabilities()` remains the single firmware source for EINF, mDNS, and
  now CFGSHOW capability values.
- `WifiConfigUI.usbIdentity` parses CFGSHOW into `USBStatus.capabilities`.
- `PanelManager.supportsQuarterTurnRotation` selects the four-way UI.
- `PanelManager.usbDevice(..., reports: .quarterTurn)` gates USB command
  availability.
- `PanelManager.availablePaths` requires square geometry for network rotate
  commands.
- `ManagerWindow` and Cocoa/app rotation actions continue through those shared
  availability gates.
