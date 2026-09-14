# Rotation Capability Artifacts

All artifacts were built from source commit
`42a33ba71ac4f9cf86e940bdbf84b29f4fb9df99`.

## Runnable App

- Path:
  `/Users/stepblk/Source/esp32-display-rot-capability-xcode-derived/Build/Products/Release/ESPDisplaySender.app`
- Build: Release, universal `x86_64 arm64`
- Verification: `codesign --verify --deep --strict` passed.
- Executable size: 10,357,392 bytes.
- Executable SHA-256:
  `30319fb3ec24f42d81a27b44dcc31c34f819289eea4ee4abef8d2ed8f5651a37`
- Firmware resources: intentionally omitted with `ESPDISP_SKIP_FIRMWARE=1`
  because this branch's committed canonical manifest has the documented
  dangling build-212 baseline. The independently verified development firmware
  bundles below are the firmware deliverable.
- The app was built but not launched.

## Firmware

- C6:
  `firmware-dev/c6/espdisp-c6-1.5.0+235.g42a33ba.espdispfw`
  - Size: 1,248,891 bytes.
  - SHA-256:
    `6f7e503ad233ae93cc1d7350d10e339e2479cad650bf8d3835d08814c856be35`
- S3:
  `firmware-dev/s3/espdisp-s3-1.5.0+235.g42a33ba.espdispfw`
  - Size: 5,658,427 bytes.
  - SHA-256:
    `bac6d8874268dadff8eeaa897927ff23eb27e8efd0d202063b97edc6b646f255`
  - `doom_wad`: 4,196,020 bytes, SHA-256
    `1d7d43be501e67d927e415e0b8f3e29c3bf33075e859721816f652a526cac771`.
- P4:
  `firmware-dev/p4/espdisp-p4-1.5.0+235.g42a33ba.espdispfw`
  - Size: 5,669,162 bytes.
  - SHA-256:
    `ea9b3d037270f4a33921942b1b787d97c8a879f791e034c0a053fcc5599ca273`
  - `doom_wad`: 4,196,020 bytes, SHA-256
    `1d7d43be501e67d927e415e0b8f3e29c3bf33075e859721816f652a526cac771`.
- Catalog:
  `firmware-dev/manifest.json`
  - SHA-256:
    `949af446591091a19907e4bd160112c03fa6c00f5d15e692a36116aef1497f1d`

`espdisp.py bundle-info` verified every bundle's image hashes, flash parts,
family coverage, and contiguous layout.

## Logs

- App build: `firmware-dev/capability-app-build.log`
- Firmware artifacts: `firmware-dev/capability-artifacts.log`
- Red/green proof: `firmware-dev/capability-red-green.log`
- Required gate: `firmware-dev/capability-gate.log`
