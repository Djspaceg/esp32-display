// Battery telemetry for the four battery-capable boards:
// - AXP2101 PMU on the ESP32-S3-Touch-AMOLED-1.75C.
// - A 3:1 resistor-divider ADC on the ESP32-C6-Touch-LCD-1.47.
// - A shared 3:1 divider design on the ESP32-S3-LCD-0.85 and
//   ESP32-S3-Touch-LCD-1.54, with an ADC enable and charger-status input.
//
// The AXP2101 reports attachment, external power, charging state, gauge
// percentage, and voltage. The ADC paths report measured voltage and an
// estimated percentage. The C6 charger's status output drives only an LED, so
// its charge state remains unknown; the two S3 ADC boards report Charging only
// while their active-low status input is asserted.
//
// EXTERNAL POWER IS THREE-VALUED, not a bool, because only the AXP2101 boards
// can answer the question at all. An ADC-divider board has no external-power
// sense, so it reports Unknown rather than the Absent it used to claim; see
// Reading::external and axp2101_status.h.
//
// Every entry point is a no-op unless the board table says this board has a
// battery telemetry path (`board::Config::hasBattery()`). That keeps boards
// without telemetry from sampling an unconnected ADC or entering the AXP2101
// register path.
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
// its ETA6098 charge state remains explicitly unknown by design. The 1.54-inch
// S3 GPIO1/2/3 path initialized and produced a live percentage on attached
// hardware; its voltage plausibility and active-low charging transition remain
// to be checked. The 0.85-inch path still awaits hardware validation.
#pragma once

#include <Arduino.h>
#include <Wire.h>

#include <axp2101_status.h>
#include <board_config.h>
#include <battery_estimate.h>

namespace boardpower {

static const uint8_t I2C_ADDR = 0x34;

// STATUS1: bit5 VBUS good, bit3 battery present.
static const uint8_t REG_STATUS1 = 0x00;
// STATUS2: bits 6:5 battery current direction, bit3 VINDPM status. What those
// bits mean, and the decode taken from them, live in axp2101_status.h.
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

static const uint8_t ADC_EN_BATTERY_VOLTAGE = 1u << 0;

/// How many ADC conversions one reading is chosen from. Eight is what the old
/// averaging path took, kept so this change is a change of method and not of
/// sampling time, and it is comfortably under batteryestimate::MAX_SAMPLES.
static const uint8_t SAMPLE_COUNT = 8;
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
  /// Whether external power is supplying the board, or that this board has no
  /// way to know. It is not a bool on purpose: the ADC-divider boards have no
  /// external-power sense at all, and the field used to be set to false for
  /// them, which reports "nothing is plugged in" as a measured fact when the
  /// truth is that nothing measured it. Charge state has always been allowed to
  /// say Unknown for exactly this reason; external power now can too.
  axp2101::External external;
  bool percentKnown;    ///< false when the gauge has no opinion
  uint8_t percent;      ///< 0-100, meaningless unless percentKnown
  Charge charge;
  uint16_t millivolts;  ///< 0 when the ADC returned nothing
};

// Shared across translation units: setup initializes the active source from the
// sketch TU, while telemetry.cpp reads it after the firmware module split.
// These fields form one state cluster; keeping any of them namespace-static
// would advertise battery support but leave the telemetry reader disabled or
// pointed at the wrong controller/pin.
inline bool enabled = false;
inline board::PowerController activeController = board::PowerController::None;
inline int8_t activeAdcPin = board::NO_PIN;
inline uint8_t activeAdcScale = 0;
inline int8_t activeBatteryEnable = board::NO_PIN;
inline int8_t activeChargeStatus = board::NO_PIN;

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
/// Brings up Wire itself. S3 detection closes and floats each probe bus before
/// profile-dependent initialization, and boardtouch::init() may run before or
/// after this on the same selected bus.
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
  activeBatteryEnable = board::NO_PIN;
  activeChargeStatus = board::NO_PIN;
  if (!cfg.hasBattery()) {
    if (verbose) Serial.printf("power: no battery telemetry on %s\n", cfg.name);
    return false;
  }

  if (cfg.power == board::PowerController::BatteryAdc) {
    if (cfg.pinBatteryEnable != board::NO_PIN) {
      pinMode(cfg.pinBatteryEnable, OUTPUT);
      digitalWrite(cfg.pinBatteryEnable, HIGH);
    }
    if (cfg.pinChargeStatus != board::NO_PIN) {
      pinMode(cfg.pinChargeStatus, INPUT_PULLUP);
    }
    pinMode(cfg.pinBatteryAdc, INPUT);
    analogReadResolution(12);
    activeController = cfg.power;
    activeAdcPin = cfg.pinBatteryAdc;
    activeAdcScale = cfg.batteryAdcScale;
    activeBatteryEnable = cfg.pinBatteryEnable;
    activeChargeStatus = cfg.pinChargeStatus;
    enabled = true;
    if (verbose) {
      Serial.printf(
          "power: battery ADC ready (gpio=%d divider=%u:1 enable=%d charge=%d)\n",
          activeAdcPin, activeAdcScale, activeBatteryEnable, activeChargeStatus);
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
                  axp2101::batteryPresent(status1) ? "present" : "absent",
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
    // Take a batch of calibrated millivolt reads and let selectCellMillivolts
    // pick from them. This used to average eight raw reads, which is how a
    // healthy cell got reported as absent: the 1.85 inch divider intermittently
    // returns 0, and a mean lets those zeros drag the result under the presence
    // threshold without leaving any trace that they were glitches. A median of
    // the samples that could physically be a cell throws an outlier out instead
    // of blending it in. See battery_estimate.h for the full reasoning.
    uint16_t cellSamples[SAMPLE_COUNT];
    for (uint8_t i = 0; i < SAMPLE_COUNT; i++) {
      uint32_t cellMillivolts =
          (uint32_t)analogReadMilliVolts(activeAdcPin) * activeAdcScale;
      if (cellMillivolts > UINT16_MAX) cellMillivolts = UINT16_MAX;
      cellSamples[i] = (uint16_t)cellMillivolts;
    }
    const batteryestimate::Selection selected =
        batteryestimate::selectCellMillivolts(cellSamples, SAMPLE_COUNT);

    Reading reading = {};
    reading.millivolts = selected.millivolts;
    reading.present = batteryestimate::cellPresent(reading.millivolts);
    // No external-power sense exists on this board: the charger's status output
    // drives an LED and reaches no processor pin. Saying so beats the false
    // that used to sit here, which a consumer could not tell from a measurement.
    reading.external = axp2101::External::Unknown;
    reading.charge = activeChargeStatus != board::NO_PIN &&
                             digitalRead(activeChargeStatus) == LOW
                         ? Charge::Charging
                         : Charge::Unknown;
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
  reading.present = axp2101::batteryPresent(status1);
  reading.external = axp2101::externalFromStatus(status1, status2);

  if (!reading.present) {
    reading.charge = Charge::Unknown;
    reading.millivolts = 0;
    reading.percentKnown = false;
    reading.percent = 0;
    out = reading;
    return true;
  }

  switch (axp2101::chargeDirection(status2)) {
    case axp2101::DIRECTION_STANDBY:
      reading.charge = Charge::Standby;
      break;
    case axp2101::DIRECTION_CHARGING:
      reading.charge = Charge::Charging;
      break;
    case axp2101::DIRECTION_DISCHARGING:
      reading.charge = Charge::Discharging;
      break;
    default:
      // Three of the four codes these two bits can carry are documented;
      // the fourth is a value this reader does not know, and saying so beats
      // guessing.
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
  uint8_t percent = 0;
  if (!readRegister(REG_BAT_PERCENT, percent)) return false;
  // Above 100 is not a percentage. The gauge reports 0xFF before it has
  // settled, and treating that as "full" would be the worst possible way to
  // be wrong about a battery.
  if (percent <= 100) {
    reading.percentKnown = true;
    reading.percent = percent;
  }

  out = reading;
  return true;
}

}  // namespace boardpower
