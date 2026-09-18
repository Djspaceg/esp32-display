// Minimal QMI8658/QMI8658A accelerometer reader for automatic orientation.
#pragma once

#include <Arduino.h>
#include <Wire.h>
#include <math.h>

#include <board_config.h>

namespace boardmotion {

static const uint8_t I2C_ADDR = 0x6B;
static const uint8_t REG_WHO_AM_I = 0x00;
static const uint8_t REG_CTRL1 = 0x02;
static const uint8_t REG_CTRL2 = 0x03;
static const uint8_t REG_CTRL7 = 0x08;
static const uint8_t REG_ACCEL_X_LOW = 0x35;
static const uint8_t REG_RESET = 0x60;
static const uint8_t WHO_AM_I = 0x05;
static const uint32_t I2C_HZ = 400000;
// The old 20ms was marginal: the part ACKs while still settling, so the config
// writes that followed could be dropped without any error. Waveshare's own board
// packages wait far longer than this.
static const uint32_t RESET_SETTLE_MS = 60;
static const uint32_t CONFIG_SETTLE_MS = 20;
static const uint8_t CONFIG_ATTEMPTS = 3;

struct Sample {
  int16_t x;
  int16_t y;
  int16_t z;
};

// Shared across translation units: setup initializes the QMI8658 from the
// sketch TU, while orientation.cpp samples it after the firmware module split.
// Namespace-static state would leave the sampler's private copy disabled.
inline bool enabled = false;

inline bool writeRegister(uint8_t reg, uint8_t value) {
  Wire.beginTransmission(I2C_ADDR);
  Wire.write(reg);
  Wire.write(value);
  return Wire.endTransmission() == 0;
}

inline bool readRegisters(uint8_t reg, uint8_t *out, size_t len) {
  Wire.beginTransmission(I2C_ADDR);
  Wire.write(reg);
  if (Wire.endTransmission() != 0) return false;
  Wire.requestFrom(I2C_ADDR, len);
  if (Wire.available() != (int)len) return false;
  Wire.readBytes(out, len);
  return true;
}

// Whether a sample could be gravity at rest. At +/-4g the scale is 8192 counts
// per g, so a stationary board reads about 8192 total however it is oriented. A
// generous band still rejects the failure seen in the field: one channel pegged
// at the int16 floor puts the total near 4.6g, and a dead-silent channel set puts
// it near zero.
inline bool read(Sample &out);

inline bool plausibleSample() {
  Sample s;
  for (uint8_t i = 0; i < 4; i++) {
    if (read(s)) {
      const float mag = sqrtf((float)s.x * s.x + (float)s.y * s.y +
                              (float)s.z * s.z);
      if (mag > 2048.0f && mag < 20480.0f) return true;
    }
    delay(30);
  }
  return false;
}

inline bool init(const board::Config &cfg, bool verbose = true) {
  enabled = false;
  if (!cfg.hasMotion()) {
    if (verbose) Serial.printf("motion: not present on %s\n", cfg.name);
    return false;
  }
  if (cfg.motion != board::MotionController::Qmi8658) {
    if (verbose) Serial.printf("motion: unsupported controller on %s\n", cfg.name);
    return false;
  }
  if (!Wire.begin(cfg.pinTouchSda, cfg.pinTouchScl, I2C_HZ)) {
    if (verbose) Serial.println("motion: ERROR I2C bus would not start");
    return false;
  }

  // QMI8658 soft reset used by both Waveshare board support packages. The reset
  // also clears CTRL1, CTRL2 and CTRL7, and the part keeps ACKing while it is
  // still settling - so a config write issued too early is accepted on the wire
  // and silently dropped, leaving the accelerometer DISABLED with its output
  // registers holding constant undefined values. That failure looks like a
  // working sensor: the identity read succeeds, this function logs "ready", and
  // the samples are stable rather than noisy, which is why it read as a rotation
  // fault instead of an init fault. It survives a chip reset because this board
  // carries a battery, so nothing here ever power-cycles the sensor.
  //
  // Hence: wait properly after the reset, read the configuration back rather than
  // trusting the ACK, and refuse to report ready on a sample that cannot be
  // gravity.
  if (!writeRegister(REG_RESET, 0xB0)) {
    if (verbose) Serial.println("motion: ERROR reset write failed");
    return false;
  }
  delay(RESET_SETTLE_MS);

  uint8_t identity = 0;
  if (!readRegisters(REG_WHO_AM_I, &identity, 1) || identity != WHO_AM_I) {
    if (verbose) {
      Serial.printf("motion: ERROR QMI8658 identity 0x%02X (expected 0x%02X)\n",
                    identity, WHO_AM_I);
    }
    return false;
  }

  // CTRL1 = 0x40: address auto-increment ONLY. Bit 5 is BE, big-endian output,
  // and read() below decodes little-endian, so BE must stay clear. It used to be
  // set (CTRL1 = 0x60), which byte-swapped every sample: one axis pegged at
  // 0x8000 while the others jittered at plausible-looking magnitudes. That bug
  // hid behind the settle-time bug above - whenever this write was dropped, BE
  // kept its default 0 and the decode was accidentally correct, which is why
  // orientation worked on some boots and not others.
  // CTRL2 +/-4g at 1kHz, CTRL7 accelerometer only.
  for (uint8_t attempt = 1; attempt <= CONFIG_ATTEMPTS; attempt++) {
    bool ok = writeRegister(REG_CTRL1, 0x40);
    ok = writeRegister(REG_CTRL2, 0x13) && ok;
    ok = writeRegister(REG_CTRL7, 0x01) && ok;
    if (!ok) {
      if (verbose) Serial.println("motion: ERROR configuration write failed");
      return false;
    }
    delay(CONFIG_SETTLE_MS);

    // Read the two registers that decide whether samples mean anything, because
    // the ACK above does not prove they stuck.
    uint8_t ctrl1 = 0, ctrl2 = 0, ctrl7 = 0;
    const bool readback = readRegisters(REG_CTRL1, &ctrl1, 1) &&
                          readRegisters(REG_CTRL2, &ctrl2, 1) &&
                          readRegisters(REG_CTRL7, &ctrl7, 1);
    // Byte order is checked too: a set BE bit silently corrupts every sample.
    if (readback && (ctrl1 & 0x20) == 0 && ctrl2 == 0x13 &&
        (ctrl7 & 0x01) != 0) {
      // The configuration being right does not mean the samples are. A channel
      // can come up saturated - AX reading a constant 0x8000 with a total
      // magnitude of 4.6g at rest was observed on white-cube-154 - and the soft
      // reset above does not clear it. Cycling the accelerometer off and on
      // powers its analog front end down, which the reset does not, so try that
      // before accepting a reading that cannot be gravity.
      enabled = true;
      if (plausibleSample()) {
        if (verbose) {
          Serial.printf(
              "motion: QMI8658 ready at 0x%02X (sda=%d scl=%d, +/-4g, attempt %u)\n",
              I2C_ADDR, cfg.pinTouchSda, cfg.pinTouchScl, (unsigned)attempt);
        }
        return true;
      }
      enabled = false;
      if (verbose) {
        Serial.printf(
            "motion: sample cannot be gravity, cycling the accelerometer "
            "(attempt %u of %u)\n",
            (unsigned)attempt, (unsigned)CONFIG_ATTEMPTS);
      }
      writeRegister(REG_CTRL7, 0x00);
      delay(CONFIG_SETTLE_MS);
      writeRegister(REG_CTRL1, 0x01);  // sensorDisable: power the front end down
      delay(RESET_SETTLE_MS);
      writeRegister(REG_CTRL1, 0x40);
      delay(CONFIG_SETTLE_MS);
      continue;
    }
    if (verbose) {
      Serial.printf(
          "motion: configuration did not stick (ctrl1=0x%02X ctrl2=0x%02X "
          "ctrl7=0x%02X), retrying %u of %u\n",
          ctrl1, ctrl2, ctrl7, (unsigned)attempt, (unsigned)CONFIG_ATTEMPTS);
    }
    delay(RESET_SETTLE_MS);
  }
  // Leave the part configured and sampling even though we are giving up on it.
  // Reporting unavailable is about not feeding a bad channel to the orientation
  // classifier; it is not a reason to hand back a powered-down sensor, and a
  // later reader or a replacement board should find it in a working state.
  writeRegister(REG_CTRL1, 0x40);
  writeRegister(REG_CTRL2, 0x13);
  writeRegister(REG_CTRL7, 0x01);
  if (verbose) {
    Serial.println(
        "motion: ERROR accelerometer never produced a plausible sample; "
        "automatic orientation is off and manual rotation still works");
  }
  return false;
}

// One-shot dump of everything that decides what a sample means, printed once at
// init. Added because three successive theories about why this sensor returned
// implausible values were each wrong: the identity read succeeds, the config
// readback passes, and the samples still cannot be gravity, so the remaining
// unknowns are the control bank and the raw bytes before this file interprets
// them. Guessing at those cost a day; reading them costs one flash.
inline void dumpState(const board::Config &cfg) {
  if (!cfg.hasMotion()) return;
  uint8_t ctrl[10] = {0};
  for (uint8_t i = 0; i < sizeof(ctrl); i++) {
    readRegisters((uint8_t)(0x00 + i), &ctrl[i], 1);
  }
  Serial.print("motion-dump: reg00..09 =");
  for (uint8_t i = 0; i < sizeof(ctrl); i++) Serial.printf(" %02X", ctrl[i]);
  Serial.println();

  // Status and the whole output block, including temperature and the timestamp
  // that says whether the part is producing new data at all.
  uint8_t status[4] = {0};
  readRegisters(0x2D, status, sizeof(status));
  Serial.printf("motion-dump: statusint/status0/status1 = %02X %02X %02X\n",
                status[0], status[1], status[2]);
  for (uint8_t pass = 0; pass < 3; pass++) {
    uint8_t block[10] = {0};
    if (!readRegisters(0x30, block, sizeof(block))) {
      Serial.println("motion-dump: read of 0x30..0x39 failed");
      break;
    }
    Serial.printf(
        "motion-dump: ts=%02X%02X%02X temp=%02X%02X ax=%02X%02X ay=%02X%02X "
        "az=%02X%02X\n",
        block[2], block[1], block[0], block[4], block[3], block[6], block[5],
        block[8], block[7], block[9], block[9]);
    delay(120);
  }
}

inline bool available() { return enabled; }

inline bool read(Sample &out) {
  if (!enabled) return false;
  uint8_t data[6] = {0};
  if (!readRegisters(REG_ACCEL_X_LOW, data, sizeof(data))) return false;
  out.x = (int16_t)((uint16_t)data[0] | ((uint16_t)data[1] << 8));
  out.y = (int16_t)((uint16_t)data[2] | ((uint16_t)data[3] << 8));
  out.z = (int16_t)((uint16_t)data[4] | ((uint16_t)data[5] << 8));
  return true;
}

}  // namespace boardmotion
