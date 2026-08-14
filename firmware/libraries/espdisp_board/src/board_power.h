// Battery telemetry for both touch boards:
// - AXP2101 PMU on the ESP32-S3-Touch-AMOLED-1.75C.
// - A 3:1 resistor-divider ADC on the ESP32-C6-Touch-LCD-1.47.
//
// The AXP2101 reports attachment, external power, charging state, gauge
// percentage, and voltage. The C6's ETA6098 charger exposes STAT only to an
// LED, not to the ESP32, so its ADC path reports measured voltage, an estimated
// percentage, and an explicitly unknown charge state.
//
// Every entry point is a no-op unless the board table says this board has a
// battery telemetry path (`board::Config::hasBattery()`). That keeps the C6
// non-touch variant from sampling an unconnected ADC and keeps the AXP2101
// register path exclusive to the S3.
//
// WHY NOT XPOWERSLIB: the vendor library is the obvious thing to vendor, and it
// is where the register map below comes from. It was not vendored. It is a
// multi-chip library (AXP192, AXP202, AXP216, SY6970, HUSB238) whose AXP2101
// implementation alone is around 3000 lines of C++ templates covering every
// regulator, interrupt source and charge-curve setting on the part. This
// firmware needs five PMU registers plus one small ADC path. Keeping both here
// avoids a multi-chip dependency in the already-constrained C6 app partition.
//
// Register map and semantics: XPowersLib's AXP2101Constants.h and
// XPowersAXP2101.tpp (github.com/lewisxhe/XPowersLib), cross-checked against
// Waveshare's 03_LVGL_AXP2101_ADC_Data example for this board.
//
// SHARING THE BUS WITH TOUCH is safe by construction, not by luck: both
// serviceTouch() and sendBatteryStatus() are called from the loop task, and
// there is no ISR and no second task on this bus, so PMU and touch traffic
// interleave and never overlap. The clock matches boardtouch::I2C_HZ so
// whichever comes up first leaves the bus at a speed the other expects.
//
// HARDWARE VALIDATION. The AXP2101 path has been exercised on an attached S3
// board: initialization succeeded and live readings reported a present cell,
// VBUS, standby state, 100%, and 4166 mV. The C6 GPIO0 ADC path is based on the
// board schematic but has not yet been physically measured on a C6 touch board;
// its ETA6098 charge state remains explicitly unknown by design.
#pragma once

#include <Arduino.h>
#include <Wire.h>

#include <board_config.h>
#include <battery_estimate.h>

namespace boardpower {

static const uint8_t I2C_ADDR = 0x34;

// STATUS1: bit5 VBUS good, bit3 battery present.
static const uint8_t REG_STATUS1 = 0x00;
// STATUS2: bits 7:5 charge status, bit3 part of the VBUS-in test below.
static const uint8_t REG_STATUS2 = 0x01;
// ADC_CHANNEL_CTRL: bit0 enables the battery voltage channel.
static const uint8_t REG_ADC_CHANNEL_CTRL = 0x30;
// Battery voltage, 13 bits across two registers (high 5 bits, then low 8).
static const uint8_t REG_BAT_VOLTAGE_HIGH = 0x34;
static const uint8_t REG_BAT_VOLTAGE_LOW = 0x35;
// BAT_DET_CTRL: bit0 enables battery detection.
static const uint8_t REG_BAT_DET_CTRL = 0x68;
// Fuel-gauge percentage. Only meaningful while STATUS1 says a battery is
// present - the vendor library returns -1 otherwise, which is what maps onto
// deviceproto::BATTERY_PERCENT_UNKNOWN on the wire.
static const uint8_t REG_BAT_PERCENT = 0xA4;

static const uint8_t STATUS1_VBUS_GOOD = 1u << 5;
static const uint8_t STATUS1_BATTERY_PRESENT = 1u << 3;
static const uint8_t STATUS2_VBUS_NOT_IN = 1u << 3;
static const uint8_t ADC_EN_BATTERY_VOLTAGE = 1u << 0;
static const uint8_t BAT_DET_EN = 1u << 0;

/// Bus speed. Matches boardtouch::I2C_HZ deliberately: the PMU and the touch
/// controller share one bus, so bringing up either must not leave it running at
/// a speed the other was not set up for. The AXP2101 is a 400kHz part.
static const uint32_t I2C_HZ = 400000;

/// The charge states the PMU distinguishes. Mirrors deviceproto::ChargeState
/// but is kept separate so this library stays independent of the wire format -
/// the sketch maps one to the other, as it does for touch gestures.
enum class Charge : uint8_t { Unknown, Charging, Discharging, Standby };

/// One reading from the active battery telemetry source.
struct Reading {
  bool present;         ///< a battery is attached
  bool externalPower;   ///< USB/VBUS is supplying the board
  bool percentKnown;    ///< false when the gauge has no opinion
  uint8_t percent;      ///< 0-100, meaningless unless percentKnown
  Charge charge;
  uint16_t millivolts;  ///< 0 when the ADC returned nothing
};

static bool enabled = false;
static board::PowerController activeController = board::PowerController::None;
static int8_t activeAdcPin = board::NO_PIN;
static uint8_t activeAdcScale = 0;

/// Read one register.
///
/// The address write ends with a STOP (Wire.endTransmission() with its default
/// argument) rather than holding the bus with a repeated start. A repeated start
/// is the more common convention for parts like this, so the shape was checked
/// against the vendor rather than assumed: XPowersLib's own Arduino path does
/// exactly this - beginTransmission, write(reg), endTransmission(), requestFrom -
/// in XPowersCommon.hpp's readRegister(reg, buf, length)
/// (github.com/lewisxhe/XPowersLib). So the part is driven the way the library
/// this register map came from drives it, and a STOP between the two phases is
/// not the thing to suspect when a reading looks wrong.
inline bool readRegister(uint8_t reg, uint8_t &value) {
  Wire.beginTransmission(I2C_ADDR);
  Wire.write(reg);
  if (Wire.endTransmission() != 0) return false;
  Wire.requestFrom(I2C_ADDR, (size_t)1);
  if (Wire.available() != 1) return false;
  value = (uint8_t)Wire.read();
  return true;
}

inline bool writeRegister(uint8_t reg, uint8_t value) {
  Wire.beginTransmission(I2C_ADDR);
  Wire.write(reg);
  Wire.write(value);
  return Wire.endTransmission() == 0;
}

/// Set bits in a register without disturbing the rest of it. The ADC and
/// battery-detect registers both carry unrelated enables, so a blind write
/// would switch off whatever the PMU's own defaults had turned on.
inline bool setRegisterBits(uint8_t reg, uint8_t bits) {
  uint8_t value = 0;
  if (!readRegister(reg, value)) return false;
  if ((value & bits) == bits) return true;
  return writeRegister(reg, (uint8_t)(value | bits));
}

/// Bring up the configured battery telemetry source. Returns false when the board
/// has none, which is not an error, and false when a configured source could not
/// initialize. The caller uses the return value to decide whether to advertise
/// CAP_BATTERY, so a failed source means no advertised battery rather than a
/// promise of readings that never arrive.
///
/// Brings up Wire itself. Nothing else does on this board: the S3 build pins
/// board::COMPILED_VARIANT so boarddetect::probe() never runs, and
/// boardtouch::init() returns early for the CST9217 before touching Wire.
///
/// NEVER drives cfg.pinTouchRst, and there is no pinMode or digitalWrite
/// anywhere in this file for that reason. On the 1.75C that line IS the panel
/// reset (GPIO2, one shared line), so pulsing it would hard-reset a CO5300 that
/// initDisplay() has already brought up and leave the panel dark. board_touch.h
/// documents the same hazard. The PMU needs no reset line in any case.
inline bool init(const board::Config &cfg, bool verbose = true) {
  enabled = false;
  activeController = board::PowerController::None;
  activeAdcPin = board::NO_PIN;
  activeAdcScale = 0;
  if (!cfg.hasBattery()) {
    if (verbose) Serial.printf("power: no battery telemetry on %s\n", cfg.name);
    return false;
  }

  if (cfg.power == board::PowerController::BatteryAdc) {
    pinMode(cfg.pinBatteryAdc, INPUT);
    analogReadResolution(12);
    activeController = cfg.power;
    activeAdcPin = cfg.pinBatteryAdc;
    activeAdcScale = cfg.batteryAdcScale;
    enabled = true;
    if (verbose) {
      Serial.printf(
          "power: battery ADC ready (gpio=%d divider=%u:1; charge state unavailable)\n",
          activeAdcPin, activeAdcScale);
    }
    return true;
  }

  if (cfg.power != board::PowerController::Axp2101) {
    // Only the AXP2101 register map is implemented here. Any other controller
    // needs its own reader; returning false keeps CAP_BATTERY honest.
    if (verbose) {
      Serial.printf("power: controller on %s not yet supported\n", cfg.name);
    }
    return false;
  }

  // Shared with touch (GPIO15/14 on the 1.75C). Wire.begin is idempotent
  // enough to call from whichever of the two comes up first.
  if (!Wire.begin(cfg.pinTouchSda, cfg.pinTouchScl, I2C_HZ)) {
    if (verbose) Serial.println("power: ERROR I2C bus would not start");
    return false;
  }

  uint8_t status1 = 0;
  if (!readRegister(REG_STATUS1, status1)) {
    if (verbose) {
      Serial.printf("power: ERROR no AXP2101 at 0x%02X (sda=%d scl=%d)\n",
                    I2C_ADDR, cfg.pinTouchSda, cfg.pinTouchScl);
    }
    return false;
  }

  // The ADCs are off until asked. Without these two the voltage register reads
  // zero and the gauge never reports, so every reading would come back empty
  // and look like a wiring fault.
  bool ok = setRegisterBits(REG_BAT_DET_CTRL, BAT_DET_EN);
  ok = setRegisterBits(REG_ADC_CHANNEL_CTRL, ADC_EN_BATTERY_VOLTAGE) && ok;
  if (!ok) {
    if (verbose) Serial.println("power: ERROR could not enable battery ADC");
    return false;
  }

  activeController = cfg.power;
  enabled = true;
  if (verbose) {
    Serial.printf("power: AXP2101 ready (status1=0x%02X, battery %s, sda=%d scl=%d)\n",
                  status1,
                  (status1 & STATUS1_BATTERY_PRESENT) ? "present" : "absent",
                  cfg.pinTouchSda, cfg.pinTouchScl);
  }
  return true;
}

inline bool available() { return enabled; }

/// Sample the active battery telemetry source. Returns false when no source is
/// enabled or a transaction failed, so a caller never reports a half-populated
/// reading as fact.
inline bool read(Reading &out) {
  if (!enabled) return false;

  if (activeController == board::PowerController::BatteryAdc) {
    // Average several calibrated millivolt reads; the 100nF capacitor on the
    // divider suppresses noise, and averaging removes the remaining ADC jitter.
    uint32_t dividedMillivolts = 0;
    for (uint8_t i = 0; i < 8; i++) {
      dividedMillivolts += (uint32_t)analogReadMilliVolts(activeAdcPin);
    }
    dividedMillivolts /= 8;
    uint32_t cellMillivolts = dividedMillivolts * activeAdcScale;
    if (cellMillivolts > UINT16_MAX) cellMillivolts = UINT16_MAX;

    Reading reading = {};
    reading.millivolts = (uint16_t)cellMillivolts;
    reading.present = batteryestimate::cellPresent(reading.millivolts);
    reading.externalPower = false;  // ETA6098 STAT is not wired to the ESP32
    reading.charge = Charge::Unknown;
    reading.percentKnown = reading.present;
    reading.percent = reading.present
        ? batteryestimate::percentFromMillivolts(reading.millivolts)
        : 0;
    out = reading;
    return true;
  }

  uint8_t status1 = 0;
  uint8_t status2 = 0;
  if (!readRegister(REG_STATUS1, status1)) return false;
  if (!readRegister(REG_STATUS2, status2)) return false;

  Reading reading;
  reading.present = (status1 & STATUS1_BATTERY_PRESENT) != 0;
  // Two registers agreeing, which is how the vendor library tests it: VBUS is
  // supplying the board when STATUS1 says the input is good AND STATUS2 does
  // not say otherwise.
  reading.externalPower = (status1 & STATUS1_VBUS_GOOD) != 0 &&
                          (status2 & STATUS2_VBUS_NOT_IN) == 0;

  switch ((status2 >> 5) & 0x07) {
    case 0:
      reading.charge = Charge::Standby;
      break;
    case 1:
      reading.charge = Charge::Charging;
      break;
    case 2:
      reading.charge = Charge::Discharging;
      break;
    default:
      // The part documents three states in these bits; anything else is a
      // value this reader does not know, and saying so beats guessing.
      reading.charge = Charge::Unknown;
      break;
  }

  uint8_t high = 0;
  uint8_t low = 0;
  if (!readRegister(REG_BAT_VOLTAGE_HIGH, high)) return false;
  if (!readRegister(REG_BAT_VOLTAGE_LOW, low)) return false;
  // 13-bit result already scaled to millivolts by the part.
  reading.millivolts = (uint16_t)(((uint16_t)(high & 0x1F) << 8) | low);

  reading.percentKnown = false;
  reading.percent = 0;
  if (reading.present) {
    uint8_t percent = 0;
    if (!readRegister(REG_BAT_PERCENT, percent)) return false;
    // Above 100 is not a percentage. The gauge reports 0xFF before it has
    // settled, and treating that as "full" would be the worst possible way to
    // be wrong about a battery.
    if (percent <= 100) {
      reading.percentKnown = true;
      reading.percent = percent;
    }
  }

  out = reading;
  return true;
}

}  // namespace boardpower
