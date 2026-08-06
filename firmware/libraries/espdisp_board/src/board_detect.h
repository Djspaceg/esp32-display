// Runtime board detection: probe the shared I2C bus, decide which of the two
// Waveshare 1.47" ESP32-C6 boards this binary is running on.
//
// The decision rule itself lives in board_config.h (variantFromI2cProbe) so it
// can be unit tested on the host. This file is only the hardware half: bring up
// the bus, count what answers, hand the count to the rule.
//
// ORDERING IS SAFETY-CRITICAL. This must run before anything drives GPIO8 or
// the panel pins. On the Touch board GPIO8 is the BOOT button, switched to
// ground; the non-touch board drives an addressable LED there. Configuring that
// pin before knowing which board this is can short a driven pad against a
// pressed button.
#pragma once

#include <Arduino.h>
#include <Wire.h>

#include <board_config.h>

namespace boarddetect {

/// I2C addresses seen on a real ESP32-C6-Touch-LCD-1.47: 0x63 is the AXS5106L
/// touch controller, 0x6B the QMI8658A IMU. Only used to annotate the log - the
/// verdict deliberately keys off "anything answered" rather than an address
/// allowlist, so a board revision that moves an address still detects correctly.
inline const char *knownDeviceHint(uint8_t address) {
  if (address == 0x63 || address == 0x51) return " (AXS5106L touch)";
  if (address == 0x6B || address == 0x6A) return " (QMI8658A IMU)";
  return "";
}

/// Probe the bus and return the detected variant.
///
/// Never returns Unknown: an unusable bus resolves to the Touch variant, which
/// is the electrically safe guess (see board_config.h resolve()).
///
/// verbose logging goes to Serial, which the caller is expected to have started.
inline board::Variant probe(bool verbose = true, int *outFoundCount = nullptr) {
  // Release the touch controller from reset first. A touch chip held in reset
  // would not answer, and a silent bus is exactly the signal we read as "this
  // is the non-touch board" - the one misdetection that has electrical
  // consequences. On the non-touch board this pin is not wired to anything we
  // can disturb.
  pinMode(board::PIN_PROBE_TP_RST, OUTPUT);
  digitalWrite(board::PIN_PROBE_TP_RST, LOW);
  delay(20);
  digitalWrite(board::PIN_PROBE_TP_RST, HIGH);
  delay(100);

  bool busOk = Wire.begin(board::PIN_PROBE_SDA, board::PIN_PROBE_SCL, 100000);
  int found = 0;
  if (busOk) {
    for (uint8_t addr = 0x08; addr < 0x78; addr++) {
      Wire.beginTransmission(addr);
      if (Wire.endTransmission() == 0) {
        found++;
        if (verbose) {
          Serial.printf("board: I2C device at 0x%02X%s\n", addr,
                        knownDeviceHint(addr));
        }
      }
    }
  } else if (verbose) {
    Serial.println("board: WARN I2C bus would not start - assuming Touch board");
  }

  board::Variant variant = board::variantFromI2cProbe(busOk, found);

  // On the non-touch board nothing of ours lives on these pins, so hand them
  // back rather than leaving three pins driven for the rest of the run.
  if (variant == board::Variant::LcdSt7789) {
    Wire.end();
    pinMode(board::PIN_PROBE_SDA, INPUT);
    pinMode(board::PIN_PROBE_SCL, INPUT);
    pinMode(board::PIN_PROBE_TP_RST, INPUT);
  }

  if (outFoundCount != nullptr) *outFoundCount = found;
  if (verbose) {
    Serial.printf("board: %d I2C device(s) -> %s\n", found,
                  board::configFor(variant).name);
  }
  return variant;
}

}  // namespace boarddetect
