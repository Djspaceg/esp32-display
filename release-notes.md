# Release Notes

## 1.5.0

- Added family-universal c6, s3, and p4 firmware releases with runtime hardware-profile selection.
- Added initial ESP32-P4 and Waveshare 4B MIPI-DSI and GT911 bring-up; hosted WiFi, streaming, and OTA remain blocked pending coprocessor compatibility validation.
- Changed the macOS app to embed and safely select the canonical release catalog by family, chip, profile, and partition evidence.
- Changed S3 release compatibility to include verified 32 MiB CO5300 hardware while retaining the 8 MiB layout.
- Fixed large-tile validation so malformed records cannot advance frame completion before a valid retry.

## 1.4.2

- Added support for the Waveshare ESP32-S3-LCD-0.85 with its GC9107 display profile.
- Added canonical firmware release notes displayed in the Update firmware screen.
