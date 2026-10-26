// Battery telemetry for the battery-capable boards:
// - AXP2101 PMU on the ESP32-S3-Touch-AMOLED-1.75C (on the touch bus) and the
//   LilyGO T-Watch-S3 (on its own bus, Wire1; see beginBus). The watch's
//   panel, backlight and touch also run from AXP2101 ALDOs, which
//   enablePanelRails() switches on before panel bring-up.
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
// PWRON_STATUS / PWROFF_STATUS: what last switched the part on and off.
static const uint8_t REG_PWRON_STATUS = 0x20;
static const uint8_t REG_PWROFF_STATUS = 0x21;
// INPUT_CURRENT_LIMIT: bits 2:0 the VBUS input current limit code
// (axp2101_status.h).
static const uint8_t REG_INPUT_CURRENT_LIMIT = 0x16;
// BAT_DET_CTRL: bit0 enables battery detection.
static const uint8_t REG_BAT_DET_CTRL = 0x68;
// PWROFF_EN / IRQ_OFF_ON_LEVEL: whether and after how long a PWR key hold
// powers the part off (axp2101_status.h). Read only, for the boot log.
static const uint8_t REG_PWROFF_EN = 0x22;
static const uint8_t REG_IRQ_OFF_ON_LEVEL = 0x27;
// INTEN2 / INTSTS2: the PWR key's interrupts (axp2101_status.h).
static const uint8_t REG_IRQ_ENABLE2 = 0x41;
static const uint8_t REG_IRQ_STATUS2 = 0x49;
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
/// The bus the AXP2101 register helpers talk on; beginBus() sets it.
inline TwoWire *activeBus = &Wire;

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
  TwoWire &wire = *activeBus;
  wire.beginTransmission(I2C_ADDR);
  wire.write(reg);
  if (wire.endTransmission() != 0) return false;
  wire.requestFrom(I2C_ADDR, (size_t)1);
  if (wire.available() != 1) return false;
  value = (uint8_t)wire.read();
  return true;
}

inline bool writeRegister(uint8_t reg, uint8_t value) {
  TwoWire &wire = *activeBus;
  wire.beginTransmission(I2C_ADDR);
  wire.write(reg);
  wire.write(value);
  return wire.endTransmission() == 0;
}

/// Start the bus this board's PMU answers on and point the register helpers at
/// it: Wire on the touch bus (GPIO15/14 on the 1.75C, where Wire.begin is
/// idempotent enough to call from whichever of touch and power comes up
/// first), or Wire1 on the PMU's own bus (GPIO10/11 on the T-Watch-S3), so the
/// touch bus on Wire is never re-pinned under the touch driver. False when the
/// bus will not start, or the board names its own PMU bus on a chip without a
/// second I2C controller.
inline bool beginBus(const board::Config &cfg) {
  activeBus = &Wire;
  if (cfg.hasPmuBus()) {
#if SOC_HP_I2C_NUM > 1
    activeBus = &Wire1;
#else
    return false;
#endif
  }
  return activeBus->begin(cfg.pmuSda(), cfg.pmuScl(), I2C_HZ);
}

/// What LilyGO's T-Watch-S3 code programs every panel ALDO to before
/// enabling it (LilyGoWatch2022::initPMU, setVoltage(CH_ALDO2/CH_ALDO3,
/// 3300)); this firmware never sets another value.
static const uint16_t PMU_PANEL_RAIL_MILLIVOLTS = 3300;
// LDO_ONOFF_CTRL0 (90H) and the ALDO1-ALDO4 voltage registers (92H-95H);
// their bit layout and the value arithmetic are in axp2101_status.h.
static const uint8_t REG_LDO_ONOFF_CTRL0 = 0x90;
static const uint8_t REG_ALDO1_VOLTAGE = 0x92;
static const uint8_t ALDO_COUNT = 4;
static_assert(axp2101::aldoVoltageCode(PMU_PANEL_RAIL_MILLIVOLTS) == 0x1C,
              "LilyGO's 3300 mV is ALDO code 0x1C");

/// Raise the AXP2101 ALDOs a carrier's panel hangs off (cfg.pmuPanelAldoMask)
/// before the panel bus starts: each is set to PMU_PANEL_RAIL_MILLIVOLTS when
/// it holds another value, then switched on. On the T-Watch-S3 that is ALDO2
/// (backlight LED anode) and ALDO3 (panel logic, touch controller and its
/// pull-ups), which nothing else switches on after a full power loss. No
/// other rail is touched, read-modify-write keeps every other bit, and true
/// with nothing done when the carrier names no rail.
///
/// A rail that was off gets 120 ms before the caller goes on. The panel has
/// no reset GPIO on this carrier (an RC network on its supply resets it), so
/// nothing else orders its first command after that reset; 120 ms is a
/// conservative choice, the wait ST7789 drivers give the panel after a reset
/// or SLPOUT, not a measured figure. LilyGO's own code waits for nothing.
inline bool enablePanelRails(const board::Config &cfg, bool verbose = true) {
  if (cfg.power != board::PowerController::Axp2101 ||
      cfg.pmuPanelAldoMask == 0) {
    return true;
  }
  if (!beginBus(cfg)) {
    if (verbose) {
      Serial.printf("power: ERROR PMU bus would not start (sda=%d scl=%d)\n",
                    cfg.pmuSda(), cfg.pmuScl());
    }
    return false;
  }
  const uint8_t mask =
      (uint8_t)(cfg.pmuPanelAldoMask & axp2101::ALDO_ONOFF_MASK);
  uint8_t onoff = 0;
  if (!readRegister(REG_LDO_ONOFF_CTRL0, onoff)) {
    if (verbose) {
      Serial.printf("power: ERROR no AXP2101 at 0x%02X for the panel rails\n",
                    I2C_ADDR);
    }
    return false;
  }
  for (uint8_t i = 0; i < ALDO_COUNT; ++i) {
    if ((mask & (1u << i)) == 0) continue;
    uint8_t voltage = 0;
    if (!readRegister((uint8_t)(REG_ALDO1_VOLTAGE + i), voltage)) return false;
    const uint8_t set =
        axp2101::aldoVoltageWrite(voltage, PMU_PANEL_RAIL_MILLIVOLTS);
    if (set == voltage) continue;
    if (!writeRegister((uint8_t)(REG_ALDO1_VOLTAGE + i), set)) return false;
    if (verbose) {
      Serial.printf("power: AXP2101 ALDO%u %d mV -> %u mV\n",
                    (unsigned)(i + 1), axp2101::aldoMillivolts(voltage),
                    (unsigned)PMU_PANEL_RAIL_MILLIVOLTS);
    }
  }
  const bool wereOn = (onoff & mask) == mask;
  if (!wereOn && !writeRegister(REG_LDO_ONOFF_CTRL0,
                                axp2101::aldoEnableWrite(onoff, mask))) {
    return false;
  }
  if (verbose) {
    Serial.printf("power: AXP2101 panel ALDOs 0x%X at %u mV, %s (90H=0x%02X)\n",
                  (unsigned)mask, (unsigned)PMU_PANEL_RAIL_MILLIVOLTS,
                  wereOn ? "already on" : "switched on", onoff);
  }
  if (!wereOn) delay(120);
  return true;
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
/// NEVER drives cfg.pinTouchRst or cfg.pinRst, and there is no pinMode or
/// digitalWrite anywhere in this file for that reason: touch bring-up owns the
/// touch reset (GPIO2 on the 1.75C) and panel bring-up owns the panel reset
/// (GPIO1), and pulsing either here would reset a controller that is already
/// up. The PMU needs no reset line in any case.
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

  // The touch bus (GPIO15/14 on the 1.75C) or the PMU's own; see beginBus.
  if (!beginBus(cfg)) {
    if (verbose) Serial.println("power: ERROR I2C bus would not start");
    return false;
  }

  uint8_t status1 = 0;
  if (!readRegister(REG_STATUS1, status1)) {
    if (verbose) {
      Serial.printf("power: ERROR no AXP2101 at 0x%02X (sda=%d scl=%d)\n",
                    I2C_ADDR, cfg.pmuSda(), cfg.pmuScl());
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

  // The PWR key's press and edge interrupts, so their status bits latch for
  // powerKeyEvents() to poll; the PMU's own long-hold power off is untouched.
  // Any press left latched from before boot is cleared.
  uint8_t inten2 = 0;
  if (readRegister(REG_IRQ_ENABLE2, inten2)) {
    writeRegister(REG_IRQ_ENABLE2, axp2101::powerKeyIrqEnable(inten2));
    writeRegister(REG_IRQ_STATUS2, axp2101::IRQ2_PKEY_ALL);
  }

  activeController = cfg.power;
  enabled = true;
  if (verbose) {
    Serial.printf("power: AXP2101 ready (status1=0x%02X, battery %s, sda=%d scl=%d)\n",
                  status1,
                  axp2101::batteryPresent(status1) ? "present" : "absent",
                  cfg.pmuSda(), cfg.pmuScl());
    // What the part last switched on and off for: a board that powers itself
    // off under load shows the cause here on its next boot.
    uint8_t pwron = 0, pwroff = 0;
    if (readRegister(REG_PWRON_STATUS, pwron) &&
        readRegister(REG_PWROFF_STATUS, pwroff)) {
      Serial.printf("power: AXP2101 last power-on 0x%02X, last power-off 0x%02X\n",
                    pwron, pwroff);
    }
    // What holding the PWR key does, so nobody has to find out by holding it.
    uint8_t pwroffEn = 0, offOnLevel = 0;
    if (readRegister(REG_PWROFF_EN, pwroffEn) &&
        readRegister(REG_IRQ_OFF_ON_LEVEL, offOnLevel)) {
      Serial.printf("power: AXP2101 PWR key long press %d ms, %d s hold: %s "
                    "(22H=0x%02X 27H=0x%02X)\n",
                    axp2101::powerKeyLongPressMillis(offOnLevel),
                    axp2101::powerKeyOffSeconds(offOnLevel),
                    axp2101::powerKeyHoldAction(pwroffEn), pwroffEn, offOnLevel);
    }
  }
  // The VBUS input current limit, raised to cfg.pmuInputLimitMilliamps
  // (1500 mA unless the carrier's vendor sets less) when lower. A 1.75C on
  // USB ran its battery from 60% to 0% while reporting "charging" and then
  // lost power under load: the board drew more than the PMU let in.
  uint8_t inputLimit = 0;
  if (readRegister(REG_INPUT_CURRENT_LIMIT, inputLimit)) {
    const uint8_t raised =
        axp2101::raisedInputLimit(inputLimit, cfg.pmuInputLimitMilliamps);
    const bool wrote =
        raised != inputLimit && writeRegister(REG_INPUT_CURRENT_LIMIT, raised);
    uint8_t now = inputLimit;
    if (wrote) readRegister(REG_INPUT_CURRENT_LIMIT, now);
    if (verbose) {
      Serial.printf("power: AXP2101 VBUS input limit %d mA%s%d mA\n",
                    axp2101::inputLimitMilliamps(inputLimit),
                    wrote ? ", raised to " : ", kept at ",
                    axp2101::inputLimitMilliamps(now));
    }
  }
  return true;
}

inline bool available() { return enabled; }

/// Poll the PWR key: reads REG 49H and clears the key bits it found, so each
/// press and edge is reported once. Returns false on any board without an AXP2101 or
/// when the read failed.
inline bool powerKeyEvents(axp2101::PowerKeyEvents &events) {
  if (!enabled || activeController != board::PowerController::Axp2101) {
    return false;
  }
  uint8_t status = 0;
  if (!readRegister(REG_IRQ_STATUS2, status)) return false;
  // A clear that did not land leaves these bits set, and the next read would
  // report them again as new; reporting nothing now lets the next read carry
  // them once, beside whatever has latched since.
  const uint8_t clear = axp2101::powerKeyClear(status);
  if (clear != 0 && !writeRegister(REG_IRQ_STATUS2, clear)) return false;
  events = axp2101::powerKeyEvents(status);
  return true;
}

/// What holding the PWR key does on this board: after how many seconds, and
/// what (axp2101::powerKeyHoldAction's word). False off the AXP2101 path or
/// when either register read failed.
inline bool powerKeyHold(int &offSeconds, const char *&action) {
  if (!enabled || activeController != board::PowerController::Axp2101) {
    return false;
  }
  uint8_t pwroffEn = 0, offOnLevel = 0;
  if (!readRegister(REG_PWROFF_EN, pwroffEn)) return false;
  if (!readRegister(REG_IRQ_OFF_ON_LEVEL, offOnLevel)) return false;
  offSeconds = axp2101::powerKeyOffSeconds(offOnLevel);
  action = axp2101::powerKeyHoldAction(pwroffEn);
  return true;
}

/// Read STATUS1 and STATUS2 raw, without interpreting them.
///
/// Exists so the external-power question can be settled from what the part
/// actually reports rather than from what this file concludes. Returns false on
/// any board that is not on the AXP2101 path, so a caller cannot mistake
/// untouched zeros for a reading of zero.
inline bool readRawStatus(uint8_t &status1, uint8_t &status2) {
  if (!enabled || activeController != board::PowerController::Axp2101) {
    return false;
  }
  if (!readRegister(REG_STATUS1, status1)) return false;
  return readRegister(REG_STATUS2, status2);
}

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
