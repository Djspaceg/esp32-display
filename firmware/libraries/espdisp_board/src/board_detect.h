// Runtime profile detection performed before any panel GPIO is configured.
//
// C6 probes its shared discriminator bus. S3 uses the 8 MiB flash identity for
// the GC9107 carrier and profile-specific I2C buses on 16 MiB hardware. S3
// accepts exactly one candidate; zero or multiple candidates remain Unknown so
// the firmware can stay serial-only until an operator uses CFGBOARD.
#pragma once

#include <Arduino.h>
#include <Wire.h>

#include <board_config.h>

namespace boarddetect {

inline const char *knownC6DeviceHint(uint8_t address) {
  if (address == 0x63 || address == 0x51) return " (AXS5106L touch)";
  if (address == 0x6B || address == 0x6A) return " (QMI8658A IMU)";
  return "";
}

inline board::Variant probeC6(bool verbose = true,
                              int *outFoundCount = nullptr) {
  pinMode(board::PIN_PROBE_TP_RST, OUTPUT);
  digitalWrite(board::PIN_PROBE_TP_RST, LOW);
  delay(20);
  digitalWrite(board::PIN_PROBE_TP_RST, HIGH);
  delay(100);

  const bool busOk = Wire.begin(
      board::PIN_PROBE_SDA, board::PIN_PROBE_SCL, 100000);
  int found = 0;
  if (busOk) {
    for (uint8_t address = 0x08; address < 0x78; ++address) {
      Wire.beginTransmission(address);
      if (Wire.endTransmission() == 0) {
        ++found;
        if (verbose) {
          Serial.printf("board: I2C device at 0x%02X%s\n", address,
                        knownC6DeviceHint(address));
        }
      }
    }
  } else if (verbose) {
    Serial.println("board: WARN C6 discriminator bus would not start");
  }

  const board::Variant variant =
      board::variantFromI2cProbe(busOk, found);
  if (variant == board::Variant::LcdSt7789) {
    Wire.end();
    pinMode(board::PIN_PROBE_SDA, INPUT);
    pinMode(board::PIN_PROBE_SCL, INPUT);
    pinMode(board::PIN_PROBE_TP_RST, INPUT);
  }
  if (outFoundCount != nullptr) *outFoundCount = found;
  if (verbose) {
    Serial.printf("board: C6 probe found %d device(s) -> %s\n", found,
                  board::configFor(variant).name);
  }
  return variant;
}

inline bool probeExpectedI2c(int8_t sda, int8_t scl,
                             const uint8_t *addresses, size_t addressCount,
                             const char *profile, bool verbose) {
  bool matched = false;
  if (Wire.begin(sda, scl, 100000)) {
    for (size_t i = 0; i < addressCount; ++i) {
      Wire.beginTransmission(addresses[i]);
      if (Wire.endTransmission() == 0) {
        matched = true;
        if (verbose) {
          Serial.printf("board: S3 %s signal at 0x%02X on SDA=%d SCL=%d\n",
                        profile, addresses[i], sda, scl);
        }
      }
    }
    Wire.end();
  } else if (verbose) {
    Serial.printf("board: WARN S3 %s probe bus would not start\n", profile);
  }
  pinMode(sda, INPUT);
  pinMode(scl, INPUT);
  return matched;
}

inline board::Variant probeS3(bool verbose = true,
                              int *outCandidateCount = nullptr) {
  const uint32_t flashBytes = ESP.getFlashChipSize();
  bool co5300 = false;
  bool st77916 = false;
  bool st7789 = false;
  if (flashBytes > 8u * 1024u * 1024u) {
    co5300 = probeExpectedI2c(
        15, 14, board::S3_CO5300_PROBE_ADDRESSES,
        sizeof(board::S3_CO5300_PROBE_ADDRESSES), "co5300", verbose);
    st77916 = probeExpectedI2c(
        11, 10, board::S3_ST77916_PROBE_ADDRESSES,
        sizeof(board::S3_ST77916_PROBE_ADDRESSES), "st77916", verbose);
    st7789 = probeExpectedI2c(
        42, 41, board::S3_ST7789_154_PROBE_ADDRESSES,
        sizeof(board::S3_ST7789_154_PROBE_ADDRESSES), "st7789-154", verbose);
  }
  const int candidates =
      (flashBytes > 0 && flashBytes <= 8u * 1024u * 1024u ? 1 : 0) +
      (co5300 ? 1 : 0) + (st77916 ? 1 : 0) + (st7789 ? 1 : 0);
  if (outCandidateCount != nullptr) *outCandidateCount = candidates;
  const board::Variant variant = board::variantFromS3Probe(
      flashBytes, co5300, st77916, st7789);
  if (verbose) {
    if (variant == board::Variant::Unknown) {
      Serial.printf("board: S3 detection found %d compatible profiles; "
                    "serial-only until CFGBOARD resolves one\n", candidates);
    } else {
      Serial.printf("board: S3 detection -> %s\n",
                    board::configFor(variant).name);
    }
  }
  return variant;
}

inline board::Variant probe(bool verbose = true,
                            int *outFoundCount = nullptr) {
#if defined(CONFIG_IDF_TARGET_ESP32P4)
  if (outFoundCount != nullptr) *outFoundCount = 1;
  return board::Variant::P4_4B;
#elif defined(CONFIG_IDF_TARGET_ESP32S3)
  return probeS3(verbose, outFoundCount);
#else
  return probeC6(verbose, outFoundCount);
#endif
}

}  // namespace boarddetect
