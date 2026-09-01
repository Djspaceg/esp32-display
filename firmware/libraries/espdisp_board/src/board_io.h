// TCA9554-backed reset lines used by the ESP32-S3-Touch-LCD-1.85C.
#pragma once

#include <Arduino.h>
#include <Wire.h>

#include <board_config.h>

namespace boardio {

static const uint8_t TCA9554_ADDRESS = 0x20;
static const uint8_t OUTPUT_REG = 0x01;
static const uint8_t CONFIG_REG = 0x03;
static const uint32_t I2C_HZ = 400000;

inline bool readRegister(uint8_t reg, uint8_t &value) {
  Wire.beginTransmission(TCA9554_ADDRESS);
  Wire.write(reg);
  if (Wire.endTransmission() != 0) return false;
  Wire.requestFrom(TCA9554_ADDRESS, (size_t)1);
  if (Wire.available() != 1) return false;
  value = (uint8_t)Wire.read();
  return true;
}

inline bool writeRegister(uint8_t reg, uint8_t value) {
  Wire.beginTransmission(TCA9554_ADDRESS);
  Wire.write(reg);
  Wire.write(value);
  return Wire.endTransmission() == 0;
}

inline uint8_t bitForExio(uint8_t exio) {
  return exio >= 1 && exio <= 8 ? (uint8_t)(1u << (exio - 1)) : 0;
}

inline bool begin(const board::Config &cfg, bool verbose = true) {
  if (!cfg.hasExpanderReset()) return true;
  if (!Wire.begin(cfg.pinTouchSda, cfg.pinTouchScl, I2C_HZ)) {
    if (verbose) Serial.println("board io: ERROR I2C bus would not start");
    return false;
  }

  uint8_t output = 0;
  uint8_t config = 0;
  if (!readRegister(OUTPUT_REG, output) || !readRegister(CONFIG_REG, config)) {
    if (verbose) Serial.println("board io: ERROR no TCA9554 at 0x20");
    return false;
  }
  const uint8_t resets =
      (uint8_t)(bitForExio(cfg.panelResetExio) | bitForExio(cfg.touchResetExio));
  output |= resets;  // inactive high before the pins become outputs
  config &= (uint8_t)~resets;
  if (!writeRegister(OUTPUT_REG, output) || !writeRegister(CONFIG_REG, config)) {
    if (verbose) Serial.println("board io: ERROR reset outputs could not be configured");
    return false;
  }
  if (verbose) {
    Serial.printf("board io: TCA9554 ready (lcd reset EXIO%u, touch reset EXIO%u)\n",
                  cfg.panelResetExio, cfg.touchResetExio);
  }
  return true;
}

inline bool setExio(uint8_t exio, bool high) {
  const uint8_t bit = bitForExio(exio);
  if (bit == 0) return false;
  uint8_t output = 0;
  if (!readRegister(OUTPUT_REG, output)) return false;
  output = high ? (uint8_t)(output | bit) : (uint8_t)(output & ~bit);
  return writeRegister(OUTPUT_REG, output);
}

inline bool pulseReset(uint8_t exio, uint32_t lowMs = 10,
                       uint32_t recoveryMs = 50) {
  if (exio == 0) return true;
  if (!setExio(exio, false)) return false;
  delay(lowMs);
  if (!setExio(exio, true)) return false;
  delay(recoveryMs);
  return true;
}

}  // namespace boardio
