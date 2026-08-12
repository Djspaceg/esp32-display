// Reading the capacitive touch controller: AXS5106L on the
// ESP32-C6-Touch-LCD-1.47, CST9217 on the ESP32-S3-Touch-AMOLED-1.75C. The
// coordinate transform is in touch_map.h; this file only gets numbers off
// the chip, and only exposes one Sample/poll() API regardless of which chip
// answered - the caller never branches on board::TouchController.
//
// Every entry point is a no-op unless the board actually has touch. On the
// C6 pair this matters because the interrupt pin (GPIO21) is LCD_RST on the
// non-touch board - attaching an interrupt to, and pulsing, the other
// board's panel reset line is the same class of mistake as driving its BOOT
// button, so it is gated the same way.
//
// WHY NOT VENDOR LIBRARIES: Waveshare's Arduino esp_lcd_touch_axs5106l is
// where the AXS5106L register map and reset timing below come from, and
// lewisxhe's SensorLib (TouchDrvCST92xx, used by Waveshare's own
// 10_Touch_CST9217 example) is where the CST9217 register map and touch
// report layout below come from - cross-checked against ESPHome's
// independently-written cst9220 component, which agrees on every register
// address, the ACK byte, and the per-point layout. Neither is vendored, for
// the same reason both times: what this project needs is small (liveness
// check, one finger's coordinates, and - critically - a report that
// distinguishes press from release) and the vendor libraries wrap it in
// machinery (multi-touch, bootloader mode, factory calibration commands)
// this project never uses. AXS5106L's vendor read path in particular sets
// touch_num = 0 both when the finger has lifted and when no interrupt has
// fired since the last call, which makes press and release indistinguishable
// - and release timing is exactly what a long-press or swipe gesture needs.
// Reimplementing each is well under a hundred lines and gets that right.
//
// AXS5106L register map and reset timing: Waveshare ESP32-C6-Touch-LCD-1.47
// demo, Arduino/libraries/esp_lcd_touch_axs5106l.
//
// CST9217 register map, ACK byte, and touch report layout: lewisxhe/SensorLib
// TouchDrvCST92xx.cpp (github.com/lewisxhe/SensorLib), the driver behind
// Waveshare's own 10_Touch_CST9217 Arduino example for this board
// (github.com/waveshareteam/ESP32-S3-Touch-AMOLED-1.75), cross-checked
// against ESPHome's independent cst9220_touchscreen.cpp component. STATUS:
// bring-up (chip ID 0x9217) and the touch-report path (taps and swipes
// registering with in-range coordinates, classifying into the right gesture
// shapes) are confirmed on an ESP32-S3-Touch-AMOLED-1.75C. The axis
// calibration (which raw axis is mirrored) is NOT independently confirmed -
// see touch_map.h's CST9217_ON_CO5300 STATUS note for why and what to do if
// it turns out wrong.
#pragma once

#include <Arduino.h>
#include <Wire.h>

#include <board_config.h>

namespace boardtouch {

static const uint8_t AXS5106L_ADDR = 0x63;  // matches what board_detect sees
static const uint8_t AXS5106L_REG_ID = 0x08;        // 3 bytes
static const uint8_t AXS5106L_REG_TOUCH_DATA = 0x01;

/// The controller reports 6 bytes per point after a 2-byte header. We read two
/// points' worth, matching the vendor driver, but only use the first: this
/// project needs one finger, and reading less would not make it faster in any
/// way that matters at 400kHz.
static const size_t AXS5106L_READ_BYTES = 14;

/// CST9217/CST9220 family: 16-bit big-endian register addresses, one I2C
/// device address for both chips. MAX_TOUCHES is the family's own limit
/// (SensorLib and ESPHome agree); this project reads only the first point.
static const uint8_t CST9217_ADDR = 0x5A;
static const uint16_t CST9217_REG_TOUCH_DATA = 0xD000;
static const uint16_t CST9217_REG_CMD_MODE = 0xD101;
static const uint16_t CST9217_REG_CHECKCODE = 0xD1FC;
static const uint16_t CST9217_REG_CHIP_INFO = 0xD204;
static const uint8_t CST9217_TOUCH_ACK = 0xAB;
static const uint8_t CST9217_EVENT_DOWN = 0x06;
static const uint16_t CST9220_CHIP_ID = 0x9220;
static const uint16_t CST9217_CHIP_ID = 0x9217;
static const uint8_t CST9217_MAX_TOUCHES = 2;
static const size_t CST9217_READ_BYTES = CST9217_MAX_TOUCHES * 5 + 5;

/// Touch bus speed. Detection probes at 100kHz because it is only looking for
/// ACKs; the vendor uses 400kHz for touch, and the largest read here (15
/// bytes, CST9217) at that rate is well under a millisecond, which matters
/// because it happens on the same loop that services DMA and WiFi.
static const uint32_t I2C_HZ = 400000;

/// One report from the controller.
struct Sample {
  bool pressed;    ///< false means this report says the finger lifted
  uint16_t rawX;   ///< controller coordinates - run through touchmap to use them
  uint16_t rawY;
  uint8_t points;  ///< fingers the controller is reporting (0 on release)
};

// Set from the ISR, cleared by poll(). The ISR does nothing but raise this flag:
// an I2C transaction cannot run in interrupt context, and this loop already has
// a task watchdog watching it.
static volatile bool interruptFlag = false;
static bool enabled = false;
static bool pressed = false;
static board::TouchController activeController = board::TouchController::None;

static void IRAM_ATTR onTouchInterrupt() { interruptFlag = true; }

/// Write a CST9217/9220 16-bit register: [regHi][regLo][payload...].
inline bool cst9217WriteReg(uint16_t reg, const uint8_t *payload, size_t len) {
  Wire.beginTransmission(CST9217_ADDR);
  Wire.write((uint8_t)(reg >> 8));
  Wire.write((uint8_t)(reg & 0xFF));
  for (size_t i = 0; i < len; i++) Wire.write(payload[i]);
  return Wire.endTransmission() == 0;
}

/// Read len bytes from a CST9217/9220 16-bit register.
inline bool cst9217ReadReg(uint16_t reg, uint8_t *out, size_t len) {
  Wire.beginTransmission(CST9217_ADDR);
  Wire.write((uint8_t)(reg >> 8));
  Wire.write((uint8_t)(reg & 0xFF));
  if (Wire.endTransmission() != 0) return false;
  Wire.requestFrom(CST9217_ADDR, (size_t)len);
  if (Wire.available() != (int)len) return false;
  Wire.readBytes(out, len);
  return true;
}

/// Bring up the CST9217/9220. Never drives cfg.pinTouchRst: on this board
/// that pin IS the panel reset (GPIO2, one shared line - see board_config.h),
/// already pulsed by initDisplay() before this runs, and pulsing it again
/// here would hard-reset a CO5300 panel that has already been brought up,
/// leaving it dark or showing garbage. The controller comes out of its own
/// bootloader on that same reset edge, which is why this can start talking
/// to it directly rather than resetting it itself.
inline bool initCst9217(const board::Config &cfg, bool verbose) {
  if (!Wire.begin(cfg.pinTouchSda, cfg.pinTouchScl, I2C_HZ)) {
    if (verbose) Serial.println("touch: ERROR I2C bus would not start");
    return false;
  }
  // The controller needs time to leave its bootloader after the shared
  // reset; ESPHome's cst9220 component and SensorLib's getAttribute() both
  // wait 30ms here before their first transaction.
  delay(30);

  // Enter command mode so the configuration/identity registers can be read.
  if (!cst9217WriteReg(CST9217_REG_CMD_MODE, nullptr, 0)) {
    if (verbose) Serial.println("touch: ERROR CST9217 would not enter command mode");
    return false;
  }
  delay(10);

  // The firmware check code confirms valid firmware is loaded, the same
  // liveness check both reference implementations perform before trusting
  // anything else the chip reports.
  uint8_t buf[4] = {0};
  if (!cst9217ReadReg(CST9217_REG_CHECKCODE, buf, sizeof(buf))) {
    if (verbose) Serial.println("touch: ERROR CST9217 did not answer its check code");
    return false;
  }
  if (buf[3] != 0xCA || buf[2] != 0xCA) {
    if (verbose) {
      Serial.printf("touch: ERROR CST9217 invalid check code 0x%02X%02X%02X%02X\n",
                    buf[3], buf[2], buf[1], buf[0]);
    }
    return false;
  }

  if (!cst9217ReadReg(CST9217_REG_CHIP_INFO, buf, sizeof(buf))) {
    if (verbose) Serial.println("touch: ERROR CST9217 did not answer its chip ID");
    return false;
  }
  uint16_t chipId = (uint16_t)((buf[3] << 8) | buf[2]);
  if (chipId != CST9217_CHIP_ID && chipId != CST9220_CHIP_ID) {
    if (verbose) Serial.printf("touch: ERROR unknown chip ID 0x%04X\n", chipId);
    return false;
  }

  pinMode(cfg.pinTouchInt, INPUT_PULLUP);
  attachInterrupt(cfg.pinTouchInt, onTouchInterrupt, FALLING);

  if (verbose) {
    Serial.printf("touch: %s ready (chip 0x%04X, sda=%d scl=%d int=%d, %lukHz)\n",
                  chipId == CST9217_CHIP_ID ? "CST9217" : "CST9220", chipId,
                  cfg.pinTouchSda, cfg.pinTouchScl, cfg.pinTouchInt,
                  (unsigned long)(I2C_HZ / 1000));
  }
  return true;
}

/// Fetch a report from the CST9217/9220, or false on an I2C failure. Mirrors
/// pollAxs5106l's contract: true whenever a transaction went through,
/// whatever it said, so out.pressed/points can carry a release.
inline bool pollCst9217(Sample &out) {
  uint8_t data[CST9217_READ_BYTES] = {0};
  if (!cst9217ReadReg(CST9217_REG_TOUCH_DATA, data, sizeof(data))) {
    return false;
  }
  // Acknowledge the report so the controller can prepare the next one - both
  // reference implementations do this unconditionally, whether or not the
  // frame below turns out to carry a valid report.
  uint8_t ack = CST9217_TOUCH_ACK;
  cst9217WriteReg(CST9217_REG_TOUCH_DATA, &ack, 1);

  // A valid report carries the ACK marker at offset 6; offset 0 must be
  // neither the ACK marker nor empty. Anything else is not a report this
  // cycle - not an I2C failure, so it still returns true, but as zero
  // touches (a release), the same way ESPHome's component treats it.
  if (data[0] == CST9217_TOUCH_ACK || data[0] == 0x00 || data[6] != CST9217_TOUCH_ACK) {
    out.pressed = false;
    out.points = 0;
    return true;
  }

  uint8_t numTouches = data[5] & 0x7F;
  if (numTouches > CST9217_MAX_TOUCHES) numTouches = CST9217_MAX_TOUCHES;
  if (numTouches == 0) {
    out.pressed = false;
    out.points = 0;
    return true;
  }
  // Only the first point: this project needs one finger, and reading more
  // would not make anything here faster.
  const uint8_t *p = data;  // point 0 starts at offset 0
  uint8_t event = p[0] & 0x0F;
  if (event != CST9217_EVENT_DOWN) {
    out.pressed = false;
    out.points = 0;
    return true;
  }
  // p[3] is shared: high nibble holds the X LSBs, low nibble the Y LSBs.
  out.rawX = (uint16_t)((p[1] << 4) | (p[3] >> 4));
  out.rawY = (uint16_t)((p[2] << 4) | (p[3] & 0x0F));
  out.points = numTouches;
  out.pressed = true;
  return true;
}

/// Bring up the touch controller. Returns false when the board has none, which
/// is not an error - it is the non-touch variant answering honestly.
///
/// Wire must already be running for the AXS5106L path (board_detect leaves it
/// up on the Touch board). The CST9217 path brings Wire up itself, since
/// nothing else has by the time this runs on that board.
inline bool init(const board::Config &cfg, bool verbose = true) {
  enabled = false;
  pressed = false;
  interruptFlag = false;
  activeController = board::TouchController::None;
  if (!cfg.hasTouch()) {
    if (verbose) Serial.printf("touch: not present on %s\n", cfg.name);
    return false;
  }

  if (cfg.touch == board::TouchController::Cst9217) {
    if (!initCst9217(cfg, verbose)) return false;
    activeController = board::TouchController::Cst9217;
    enabled = true;
    return true;
  }

  if (cfg.touch != board::TouchController::Axs5106l) {
    if (verbose) {
      Serial.printf("touch: controller on %s not yet supported\n", cfg.name);
    }
    return false;
  }

  Wire.setClock(I2C_HZ);

  pinMode(cfg.pinTouchRst, OUTPUT);
  digitalWrite(cfg.pinTouchRst, LOW);
  delay(200);
  digitalWrite(cfg.pinTouchRst, HIGH);
  delay(300);

  // Read the ID register as a liveness check. Detection already proved something
  // ACKs at this address, so a failure here means the chip is present but not
  // talking - worth distinguishing in the log from "no touch on this board".
  uint8_t id[3] = {0};
  Wire.beginTransmission(AXS5106L_ADDR);
  Wire.write(AXS5106L_REG_ID);
  bool ok = (Wire.endTransmission() == 0);
  if (ok) {
    Wire.requestFrom(AXS5106L_ADDR, (size_t)sizeof(id));
    ok = (Wire.available() == (int)sizeof(id));
    if (ok) Wire.readBytes(id, sizeof(id));
  }
  if (!ok) {
    if (verbose) Serial.println("touch: ERROR AXS5106L did not answer its ID register");
    return false;
  }

  pinMode(cfg.pinTouchInt, INPUT_PULLUP);
  attachInterrupt(cfg.pinTouchInt, onTouchInterrupt, FALLING);

  activeController = board::TouchController::Axs5106l;
  enabled = true;
  if (verbose) {
    Serial.printf("touch: AXS5106L ready (id %02X %02X %02X, rst=%d int=%d, %lukHz)\n",
                  id[0], id[1], id[2], cfg.pinTouchRst, cfg.pinTouchInt,
                  (unsigned long)(I2C_HZ / 1000));
  }
  return true;
}

inline bool available() { return enabled; }

/// Fetch a report if the controller has raised one.
///
/// Returns true only when a new report was read, so the caller can distinguish
/// "nothing happened" from "the finger lifted" - the distinction the vendor
/// drivers lose. A report with points == 0 is a release and still returns true.
inline bool poll(Sample &out) {
  if (!enabled || !interruptFlag) {
    return false;
  }
  interruptFlag = false;

  bool ok;
  if (activeController == board::TouchController::Cst9217) {
    ok = pollCst9217(out);
  } else {
    uint8_t data[AXS5106L_READ_BYTES] = {0};
    Wire.beginTransmission(AXS5106L_ADDR);
    Wire.write(AXS5106L_REG_TOUCH_DATA);
    ok = (Wire.endTransmission() == 0);
    if (ok) {
      Wire.requestFrom(AXS5106L_ADDR, (size_t)AXS5106L_READ_BYTES);
      ok = (Wire.available() == (int)AXS5106L_READ_BYTES);
      if (ok) Wire.readBytes(data, AXS5106L_READ_BYTES);
    }
    if (ok) {
      out.points = data[1];
      // 12-bit coordinates, high nibble of the first byte of each pair.
      out.rawX = (uint16_t)((data[2] & 0x0F) << 8) | data[3];
      out.rawY = (uint16_t)((data[4] & 0x0F) << 8) | data[5];
      out.pressed = out.points > 0;
    }
  }
  if (!ok) return false;
  pressed = out.pressed;
  return true;
}

/// Whether the last report said a finger was down.
inline bool isPressed() { return pressed; }

}  // namespace boardtouch
