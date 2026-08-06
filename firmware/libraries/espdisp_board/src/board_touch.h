// Reading the AXS5106L capacitive touch controller on the
// ESP32-C6-Touch-LCD-1.47. The coordinate transform is in touch_map.h; this file
// only gets numbers off the chip.
//
// Every entry point is a no-op unless the board actually has touch, because the
// interrupt pin (GPIO21) is LCD_RST on the non-touch board. Attaching an
// interrupt to, and pulsing, the other board's panel reset line is the same
// class of mistake as driving its BOOT button, so it is gated the same way.
//
// WHY NOT WAVESHARE'S DRIVER: their Arduino esp_lcd_touch_axs5106l library was
// the obvious thing to vendor, and it is where the register map and reset timing
// below come from. It was not vendored for two reasons. Its init does nothing
// but pulse reset and read the ID register, so there are no chip quirks to
// preserve. And its read path sets touch_num = 0 both when the finger has lifted
// and when no interrupt has fired since the last call, which makes press and
// release indistinguishable - and release timing is exactly what a long-press or
// swipe gesture needs. Reimplementing it is about thirty lines and gets that
// right.
//
// Register map and reset timing: Waveshare ESP32-C6-Touch-LCD-1.47 demo,
// Arduino/libraries/esp_lcd_touch_axs5106l (see docs in that archive).
#pragma once

#include <Arduino.h>
#include <Wire.h>

#include <board_config.h>

namespace boardtouch {

static const uint8_t I2C_ADDR = 0x63;      // matches what board_detect sees
static const uint8_t REG_ID = 0x08;        // 3 bytes
static const uint8_t REG_TOUCH_DATA = 0x01;

/// The controller reports 6 bytes per point after a 2-byte header. We read two
/// points' worth, matching the vendor driver, but only use the first: this
/// project needs one finger, and reading less would not make it faster in any
/// way that matters at 400kHz.
static const size_t READ_BYTES = 14;

/// Touch bus speed. Detection probes at 100kHz because it is only looking for
/// ACKs; the vendor uses 400kHz for touch, and a 14-byte read at that rate is
/// well under a millisecond, which matters because it happens on the same loop
/// that services DMA and WiFi.
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

static void IRAM_ATTR onTouchInterrupt() { interruptFlag = true; }

/// Bring up the touch controller. Returns false when the board has none, which
/// is not an error - it is the non-touch variant answering honestly.
///
/// Wire must already be running (board_detect leaves it up on the Touch board).
inline bool init(const board::Config &cfg, bool verbose = true) {
  enabled = false;
  pressed = false;
  interruptFlag = false;
  if (!cfg.hasTouch()) {
    if (verbose) Serial.printf("touch: not present on %s\n", cfg.name);
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
  Wire.beginTransmission(I2C_ADDR);
  Wire.write(REG_ID);
  bool ok = (Wire.endTransmission() == 0);
  if (ok) {
    Wire.requestFrom(I2C_ADDR, (size_t)sizeof(id));
    ok = (Wire.available() == (int)sizeof(id));
    if (ok) Wire.readBytes(id, sizeof(id));
  }
  if (!ok) {
    if (verbose) Serial.println("touch: ERROR AXS5106L did not answer its ID register");
    return false;
  }

  pinMode(cfg.pinTouchInt, INPUT_PULLUP);
  attachInterrupt(cfg.pinTouchInt, onTouchInterrupt, FALLING);

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
/// driver loses. A report with points == 0 is a release and still returns true.
inline bool poll(Sample &out) {
  if (!enabled || !interruptFlag) {
    return false;
  }
  interruptFlag = false;

  uint8_t data[READ_BYTES] = {0};
  Wire.beginTransmission(I2C_ADDR);
  Wire.write(REG_TOUCH_DATA);
  if (Wire.endTransmission() != 0) {
    return false;
  }
  Wire.requestFrom(I2C_ADDR, (size_t)READ_BYTES);
  if (Wire.available() != (int)READ_BYTES) {
    return false;
  }
  Wire.readBytes(data, READ_BYTES);

  out.points = data[1];
  // 12-bit coordinates, high nibble of the first byte of each pair.
  out.rawX = (uint16_t)((data[2] & 0x0F) << 8) | data[3];
  out.rawY = (uint16_t)((data[4] & 0x0F) << 8) | data[5];
  out.pressed = out.points > 0;
  pressed = out.pressed;
  return true;
}

/// Whether the last report said a finger was down.
inline bool isPressed() { return pressed; }

}  // namespace boardtouch
