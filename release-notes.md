# Release Notes

## 1.5.0

- Added family-universal c6, s3, and p4 firmware releases with runtime hardware-profile selection.
- Added support for the Waveshare ESP32-S3-LCD-1.3 family with ST7789V2 display, QMI8658A detection, battery telemetry, RGB LED, and CH343 serial configuration.
- Added initial ESP32-P4 and Waveshare 4B MIPI-DSI and GT911 bring-up; hosted WiFi, streaming, and OTA remain blocked pending coprocessor compatibility validation.
- Changed the macOS app to embed and safely select the canonical release catalog by family, chip, profile, and partition evidence.
- Changed S3 release compatibility to include verified 32 MiB CO5300 hardware while retaining the 8 MiB layout.
- Fixed large-tile validation so malformed records cannot advance frame completion before a valid retry.
- Fixed the triple-press BOOT Doom easter egg on the CO5300 silver-round S3, restoring it to the canonical S3 build.
- Fixed flashing a blank ESP32-C6 from Add Display, which had stopped offering the bundled image.
- Fixed bundled-firmware preselection so a detected C6, S3, or P4 chip preselects its image before full runtime identity is known.
- Fixed OTA updates for universal C6 and S3 releases: the Update Firmware modal readies from the reported chip alone, the panel exchange runs over compatible UDP and TCP transports, and the failure details shown in the sheet are selectable.

## 1.4.2

- Added support for the Waveshare ESP32-S3-LCD-0.85 with its GC9107 display profile.
- Added canonical firmware release notes displayed in the Update firmware screen.
