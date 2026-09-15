// Which supported board this binary is running on, and every board fact that
// follows from that.
//
// Eight board profiles are supported across the c6, s3, and p4 release
// families. Each family has one artifact; runtime profile selection keeps the
// physical panel/controller token independent from that family identity:
//
//   ESP32-C6-LCD-1.47          ST7789 172x320 over SPI, addressable RGB LED on
//                              GPIO8, BOOT on GPIO9
//   ESP32-C6-Touch-LCD-1.47    JD9853 172x320 over SPI, no addressable LED,
//                              BOOT on GPIO9, AXS5106L touch + QMI8658A IMU on
//                              I2C GPIO18/19, battery voltage on ADC GPIO0
//   ESP32-S3-Touch-AMOLED-1.75C  CO5300 466x466 AMOLED over QSPI, CST9217
//                              touch on I2C GPIO15/14, AXP2101 PMU, QMI8658
//                              IMU
//   ESP32-S3-LCD-0.85          GC9107 128x128 over SPI, BOOT on GPIO0,
//                              battery ADC and eight addressable RGB LEDs
//   ESP32-S3-LCD-1.3           ST7789V2 240x240 over SPI, QMI8658A IMU on
//                              I2C GPIO47/48, battery ADC and one RGB LED
//   ESP32-S3-Touch-LCD-1.54    ST7789 240x240 over SPI, CST816 touch and
//                              QMI8658 IMU on I2C GPIO42/41, battery ADC
//   ESP32-S3-Touch-LCD-1.85C   ST77916 360x360 LCD over QSPI, CST816 touch
//                              on I2C GPIO11/10, reset through TCA9554
//
// The C6 and S3 families choose a profile before any panel GPIO is driven.
// C6 distinguishes its two profiles on one shared I2C bus. S3 first uses the
// 8 MiB flash identity for GC9107, then probes profile-specific I2C buses on
// larger-flash hardware and accepts a result only when exactly one profile
// matches. P4 currently has one supported carrier but retains the same
// platform/panel/carrier separation internally.
//
// Resolution is a panel-profile fact. The sketch derives frame geometry from
// the Config's composed PanelConfig instead of a project-wide constant.
//
// This header is deliberately hardware-free (pure data plus arithmetic) so it
// is unit tested on the host alongside band_protocol.h and panel_state.h. The
// I2C probe that feeds detectVariant lives in the sketch, because it needs Wire.
#pragma once

#include <stdint.h>
#include <string.h>

#include "panel_config.h"
#include "platform_config.h"

namespace board {

/// Sentinel for "this board does not have that pin at all".
static const int8_t NO_PIN = -1;

/// The supported boards.
///
/// Unknown is the pre-detection state and the result of parsing a stored value
/// that no longer maps to a variant. It is never a usable configuration - see
/// resolve().
enum class Variant : uint8_t {
  Unknown = 0,
  LcdSt7789 = 1,     // ESP32-C6-LCD-1.47 (non-touch)
  TouchJd9853 = 2,   // ESP32-C6-Touch-LCD-1.47
  AmoledCo5300 = 3,  // ESP32-S3-Touch-AMOLED-1.75C
  LcdSt77916 = 4,    // ESP32-S3-Touch-LCD-1.85C
  LcdGc9107 = 5,     // ESP32-S3-LCD-0.85
  TouchSt7789 = 6,     // ESP32-S3-Touch-LCD-1.54
  P4_4B = 7,            // ESP32-P4-WIFI6-Touch-LCD-4B
  LcdSt7789_130 = 8,    // ESP32-S3-LCD-1.3
};

constexpr bool supportsDoom(Variant variant) {
  return variant == Variant::AmoledCo5300 || variant == Variant::P4_4B;
}

/// Which capacitive touch controller the board carries, so the sketch knows
/// which register protocol to speak. The pins alone cannot tell these apart.
enum class TouchController : uint8_t { None, Axs5106l, Cst9217, Cst816, Gt911 };

/// How battery telemetry is obtained. The S3's AXP2101 reports voltage,
/// percentage, external power, and charge state. The C6 touch board exposes
/// only a 3:1 battery-voltage divider on GPIO0; it can estimate percentage but
/// cannot observe the ETA6098 charger's STAT output, so charge state remains
/// explicitly unknown.
enum class PowerController : uint8_t { None, Axp2101, BatteryAdc };

/// Which inertial sensor supplies acceleration for automatic orientation.
enum class MotionController : uint8_t { None, Qmi8658 };

/// The variant fixed by an exact build target before runtime detection.
/// C6 and S3 are family-universal, so both remain Unknown until their safe
/// profile detector or an explicit CFGBOARD recovery override resolves one.
/// The p4-4b build target composes the P4 platform with one exact carrier;
/// platform_config.h remains free of that carrier's selector and wiring.
#if defined(CONFIG_IDF_TARGET_ESP32P4)
#if (defined(ESPDISP_BOARD_P4_4B) + defined(ESPDISP_BOARD_S3_085) + \
     defined(ESPDISP_BOARD_S3_154) + defined(ESPDISP_DOOM_S3_175) + \
     defined(ESPDISP_BOARD_S3_185)) != 1
#error "ESP32-P4 builds require exactly one compatible internal carrier selector"
#endif
#if defined(ESPDISP_DOOM_RUNTIME) && !defined(ESPDISP_BOARD_P4_4B)
#error "ESP32-P4 Doom runtime requires the board-neutral P4 carrier selector"
#endif
#if defined(ESPDISP_BOARD_P4_4B)
#define ESPDISP_PANEL_ST7703_720X720 1
#define ESPDISP_LARGE_TILE_STREAM 1
static const Variant COMPILED_VARIANT = Variant::P4_4B;
#else
#error "The selected carrier is not compatible with ESP32-P4"
#endif
#elif defined(CONFIG_IDF_TARGET_ESP32S3)
#if defined(ESPDISP_BOARD_P4_4B) || defined(ESPDISP_BOARD_S3_085) || \
    defined(ESPDISP_BOARD_S3_154) || defined(ESPDISP_DOOM_S3_175) || \
    defined(ESPDISP_BOARD_S3_185)
#error "ESP32-S3 family builds must not use profile-specific compile selectors"
#endif
#define ESPDISP_PANEL_S3_RUNTIME 1
static const Variant COMPILED_VARIANT = Variant::Unknown;
#else
#if defined(ESPDISP_BOARD_P4_4B) || defined(ESPDISP_BOARD_S3_085) || \
    defined(ESPDISP_BOARD_S3_154) || defined(ESPDISP_DOOM_S3_175) || \
    defined(ESPDISP_BOARD_S3_185) || defined(ESPDISP_DOOM_RUNTIME)
#error "ESP32-C6 family builds must not use selectors from another family"
#endif
#define ESPDISP_PANEL_C6_RUNTIME 1
static const Variant COMPILED_VARIANT = Variant::Unknown;
#endif

/// The shared I2C bus that C6 boot-time detection probes. Same pins on both
/// C6 boards; only the Touch variant has anything answering on it. Meaningless
/// on the S3, where COMPILED_VARIANT preempts detection entirely.
static const int8_t PIN_PROBE_SDA = 18;
static const int8_t PIN_PROBE_SCL = 19;
/// Touch controller reset, as used by *detection*, which necessarily runs before
/// the variant is known and so cannot read it out of the table below. Released
/// before probing so a touch chip held in reset cannot make a Touch board look
/// like a non-touch one. Must equal CONFIG_TOUCH_JD9853.pinTouchRst.
static const int8_t PIN_PROBE_TP_RST = 20;

/// S3 profile signatures. These are pure carrier data so host tests can pin
/// the exact address sets that board_detect.h probes before any panel pin is
/// driven. In particular, CO5300 carries CST9217 at 0x5A, not CST816 at 0x15.
static constexpr uint8_t S3_CO5300_PROBE_ADDRESSES[] = {
    0x5A, 0x34, 0x6A, 0x6B};
static constexpr uint8_t S3_ST77916_PROBE_ADDRESSES[] = {0x15, 0x20};
static constexpr uint8_t S3_ST7789_154_PROBE_ADDRESSES[] = {0x15, 0x6A, 0x6B};
static constexpr uint8_t S3_ST7789_130_PROBE_ADDRESSES[] = {0x6B};

/// Whether a platform can execute a panel profile. SPI/QSPI panel backends are
/// platform-neutral; the MIPI-DSI SDK backend is currently available on P4.
/// Carrier pins are deliberately absent from this decision.
constexpr bool platformSupportsPanel(const PlatformConfig &platform,
                                     const PanelConfig &panel) {
  return panel.bus != PanelBus::MipiDsi ||
         platform.platform == Platform::Esp32P4;
}

/// Everything that differs between the boards. The sketch reads this and holds
/// no board conditionals of its own, so adding a variant is a new table entry
/// rather than a hunt for scattered `if (touch)` branches.
struct Config {
  Variant variant;
  const char *name;
  /// Orthogonal composition axes. Platform contains chip/runtime facts only;
  /// panel contains controller/interface/timing facts only; the remaining
  /// fields are carrier wiring and peripherals.
  const PlatformConfig *platform;
  const PanelConfig *panel;

  // Panel controller, interface, geometry, timing, offsets, inversion and
  // shape are read only through `panel`. This carrier owns wiring and mated
  // peripherals; keeping panel facts out of it makes composition executable
  // rather than two tables that can drift.

  // Panel bus + control pins. pinMosi is the single data line on SPI boards
  // and data lane 0 on QSPI boards - the same physical role, and the same
  // union field in the IDF's spi_bus_config_t. Lanes 1-3 are NO_PIN on SPI
  // boards. pinDc is NO_PIN on QSPI panels: the command envelope replaces the
  // D/C line.
  int8_t pinSclk;
  int8_t pinMosi;   // data0 on QSPI
  int8_t pinData1;
  int8_t pinData2;
  int8_t pinData3;
  int8_t pinCs;
  int8_t pinDc;
  int8_t pinRst;

  /// PWM backlight, or NO_PIN. AMOLEDs have no backlight at all - each pixel
  /// emits - so brightness there is panel command 0x51, not a PWM duty. The
  /// sketch picks its brightness sink from hasBacklightPin().
  int8_t pinBl;

  // BOOT button: short press toggles backlight, long press flips 180.
  //
  // GPIO9 on both C6 boards. Waveshare's pinout table for the Touch board says
  // GPIO8 and omits GPIO9 entirely; that is wrong. Measured on a real board by
  // holding both pins INPUT_PULLUP and watching which one moves: every press
  // pulls GPIO9 low, GPIO8 never changes and reads high at rest. Trusting the
  // table shipped a firmware whose button silently did nothing on this variant.
  //
  // GPIO0 on the S3 board is the chip's standard BOOT strapping pin and what
  // Waveshare's docs describe. Confirmed on real hardware: all three press
  // tiers (short/long/extra-long, see handleButton() in display_stream.ino)
  // fired correctly in one continuous press-and-release, watched live over
  // serial. The C6 history above is why that check mattered rather than
  // trusting the table outright.
  int8_t pinBootButton;

  // Addressable WS2812-style LED, or NO_PIN. Present only on the C6 non-touch
  // board; the Touch board has none, so nothing should ever drive GPIO8 there.
  // Its function on the Touch board is undocumented and unmeasured - it reads
  // high with a pull-up and is not the button - which is reason enough to leave
  // it alone rather than assume it is spare.
  int8_t pinRgbLed;

  // Capacitive touch: which controller, its I2C bus, and its reset/interrupt
  // lines (NO_PIN when absent). Gated because pinTouchInt is GPIO21 on the C6
  // Touch board while GPIO21 is LCD_RST on the non-touch one: enabling touch
  // unconditionally would attach an interrupt to the other board's panel reset
  // line, and pulse GPIO20 there for no reason.
  //
  // Reset topology is profile-specific. Touch bring-up compares these fields:
  // it never re-pulses a line shared with the panel, but it must pulse a
  // dedicated GPIO or expander output before the first I2C command.
  TouchController touch;
  int8_t pinTouchSda;
  int8_t pinTouchScl;
  int8_t pinTouchRst;
  int8_t pinTouchInt;

  /// Battery telemetry source. AXP2101 shares the touch I2C bus; BatteryAdc
  /// uses pinBatteryAdc and batteryAdcScale to reconstruct cell millivolts from
  /// the board's resistor divider. pinBatteryEnable and pinChargeStatus are
  /// optional carrier controls for ADC paths; charge status is active-low.
  PowerController power;
  int8_t pinBatteryAdc;
  uint8_t batteryAdcScale;
  int8_t pinBatteryEnable;
  int8_t pinChargeStatus;

  /// QMI8658-family accelerometer on the shared touch I2C bus. The axis fields
  /// map sensor X/Y/Z indices onto panel-right and panel-down coordinates. Both
  /// vendor board examples use the identity map; keeping it in the table makes
  /// a board-revision correction local rather than baking it into the classifier.
  MotionController motion;
  uint8_t motionXAxis;
  int8_t motionXSign;
  uint8_t motionYAxis;
  int8_t motionYSign;

  /// Reset lines provided by a TCA9554 at address 0x20. Zero means the reset
  /// is a direct GPIO (`pinRst` / `pinTouchRst`) or absent. EXIO is 1..8.
  uint8_t panelResetExio;
  uint8_t touchResetExio;

  /// Optional carrier-level backlight enable and PWM polarity. These stay in
  /// the carrier composition because they are wiring, not panel or P4 facts.
  int8_t pinBlEnable;
  bool backlightInverted;

  /// Optional UART bridge connected to this carrier's external USB port.
  /// When absent, the platform's serial transport remains authoritative.
  int8_t pinSerialRx = NO_PIN;
  int8_t pinSerialTx = NO_PIN;

  SerialTransport serialTransport() const {
    return pinSerialRx != NO_PIN && pinSerialTx != NO_PIN
               ? SerialTransport::UartBridge
               : platform->serial;
  }

  bool hasRgbLed() const { return pinRgbLed != NO_PIN; }
  bool hasBootButton() const { return pinBootButton != NO_PIN; }
  bool hasTouch() const {
    if (touch == TouchController::None || pinTouchSda == NO_PIN ||
        pinTouchScl == NO_PIN) {
      return false;
    }
    if (touch == TouchController::Gt911) return true;  // polling profile
    return (pinTouchRst != NO_PIN || touchResetExio != 0) &&
           pinTouchInt != NO_PIN;
  }
  /// Whether a battery reading is possible at all on this board. The bus pins
  /// are part of the test because the PMU is read over the touch I2C bus: a
  /// controller with nowhere to talk cannot be read, and claiming otherwise
  /// would make the firmware advertise a battery it can never sample.
  bool hasBattery() const {
    if (power == PowerController::Axp2101) {
      return pinTouchSda != NO_PIN && pinTouchScl != NO_PIN;
    }
    if (power == PowerController::BatteryAdc) {
      return pinBatteryAdc != NO_PIN && batteryAdcScale > 0;
    }
    return false;
  }
  bool hasMotion() const {
    return motion != MotionController::None && pinTouchSda != NO_PIN &&
           pinTouchScl != NO_PIN && motionXAxis < 3 && motionYAxis < 3 &&
           motionXAxis != motionYAxis &&
           (motionXSign == 1 || motionXSign == -1) &&
           (motionYSign == 1 || motionYSign == -1);
  }
  bool isQspi() const {
    return panel != nullptr && panel->bus == PanelBus::Qspi;
  }
  bool isDsi() const {
    return panel != nullptr && panel->bus == PanelBus::MipiDsi;
  }
  bool hasExpanderReset() const {
    return panelResetExio != 0 || touchResetExio != 0;
  }
  /// Brightness sink: PWM duty on this pin, or panel command 0x51 when absent.
  bool hasBacklightPin() const { return pinBl != NO_PIN; }
};

/// ESP32-C6-LCD-1.47: ST7789, addressable LED, BOOT on GPIO9.
static const Config CONFIG_LCD_ST7789 = {
    Variant::LcdSt7789,
    "ESP32-C6-LCD-1.47 (ST7789)",
    &PLATFORM_ESP32_C6,
    &PANEL_ST7789_172X320,
    /* sclk  */ 7,
    /* mosi  */ 6,
    /* data1 */ NO_PIN,
    /* data2 */ NO_PIN,
    /* data3 */ NO_PIN,
    /* cs    */ 14,
    /* dc    */ 15,
    /* rst   */ 21,
    /* bl    */ 22,
    /* boot  */ 9,
    /* led   */ 8,
    TouchController::None,
    /* touchSda */ NO_PIN,  // I2C pins exist on the board but carry nothing
    /* touchScl */ NO_PIN,
    /* touchRst */ NO_PIN,
    /* touchInt */ NO_PIN,
    PowerController::None,
    /* batteryAdc */ NO_PIN,
    /* adcScale */ 0,
    /* batteryEnable */ NO_PIN,
    /* chargeStatus */ NO_PIN,
    MotionController::None,
    /* motion X */ 0, 1,
    /* motion Y */ 1, 1,
    /* panelResetExio */ 0,
    /* touchResetExio */ 0,
    /* pinBlEnable */ NO_PIN,
    /* backlightInverted */ false,
};

/// ESP32-C6-Touch-LCD-1.47: JD9853, no addressable LED, BOOT on GPIO9.
///
/// Pin map and panel settings follow Waveshare's own ESP-IDF BSP for this board
/// (80MHz pclk, RGB element order, INVON), which uses the same esp_lcd API this
/// firmware does.
static const Config CONFIG_TOUCH_JD9853 = {
    Variant::TouchJd9853,
    "ESP32-C6-Touch-LCD-1.47 (JD9853)",
    &PLATFORM_ESP32_C6,
    &PANEL_JD9853_172X320,
    /* sclk  */ 1,
    /* mosi  */ 2,
    /* data1 */ NO_PIN,
    /* data2 */ NO_PIN,
    /* data3 */ NO_PIN,
    /* cs    */ 14,
    /* dc    */ 15,
    /* rst   */ 22,
    /* bl    */ 23,
    // GPIO9, not the GPIO8 Waveshare's pinout table states. Measured: with both
    // candidates held INPUT_PULLUP, pressing BOOT drives GPIO9 low every time
    // and GPIO8 never moves. See the note above the struct.
    /* boot  */ 9,
    /* led   */ NO_PIN,
    TouchController::Axs5106l,
    /* touchSda */ 18,  // the shared detection bus
    /* touchScl */ 19,
    /* touchRst */ 20,
    /* touchInt */ 21,
    // ETA6098 charger STAT is LED-only, but the cell rail reaches ADC1_CH0
    // through a 200k/100k divider, so voltage and an estimated level are real
    // while charge state is reported as unknown.
    PowerController::BatteryAdc,
    /* batteryAdc */ 0,
    /* adcScale */ 3,
    /* batteryEnable */ NO_PIN,
    /* chargeStatus */ NO_PIN,
    MotionController::Qmi8658,
    // Waveshare's board examples leave the QMI8658 geometry at identity.
    /* motion X */ 0, 1,
    /* motion Y */ 1, 1,
    /* panelResetExio */ 0,
    /* touchResetExio */ 0,
    /* pinBlEnable */ NO_PIN,
    /* backlightInverted */ false,
};

/// ESP32-S3-Touch-AMOLED-1.75C: CO5300 466x466 AMOLED over QSPI,
/// CST9217 touch and AXP2101 PMU. The measured board shares panel and touch
/// reset on GPIO2.
static const Config CONFIG_AMOLED_CO5300 = {
    Variant::AmoledCo5300,
    "ESP32-S3-Touch-AMOLED-1.75C (CO5300)",
    &PLATFORM_ESP32_S3,
    &PANEL_CO5300_466X466,
    /* sclk  */ 38,
    /* mosi  */ 4,
    /* data1 */ 5,
    /* data2 */ 6,
    /* data3 */ 7,
    /* cs    */ 12,
    /* dc    */ NO_PIN,
    /* rst   */ 2,
    /* bl    */ NO_PIN,
    /* boot  */ 0,
    /* led   */ NO_PIN,
    TouchController::Cst9217,
    /* touchSda */ 15,
    /* touchScl */ 14,
    /* touchRst */ 2,
    /* touchInt */ 11,
    PowerController::Axp2101,
    /* batteryAdc */ NO_PIN,
    /* adcScale */ 0,
    /* batteryEnable */ NO_PIN,
    /* chargeStatus */ NO_PIN,
    MotionController::Qmi8658,
    // Field calibration: swapped raw axes preserve room-frame tracking, and
    // negating both signs corrects the measured uniform 180-degree offset.
    /* motion X */ 1, -1,
    /* motion Y */ 0, 1,
    /* panelResetExio */ 0,
    /* touchResetExio */ 0,
    /* pinBlEnable */ NO_PIN,
    /* backlightInverted */ false,
};

/// ESP32-S3-Touch-LCD-1.85C: ST77916 360x360 round TFT over QSPI.
/// Panel and CST816 touch reset are TCA9554 EXIO2 and EXIO1 respectively.
static const Config CONFIG_LCD_ST77916 = {
    Variant::LcdSt77916,
    "ESP32-S3-Touch-LCD-1.85C (ST77916)",
    &PLATFORM_ESP32_S3,
    &PANEL_ST77916_360X360,
    /* sclk  */ 40,
    /* mosi  */ 46,
    /* data1 */ 45,
    /* data2 */ 42,
    /* data3 */ 41,
    /* cs    */ 21,
    /* dc    */ NO_PIN,
    /* rst   */ NO_PIN,
    /* bl    */ 5,
    /* boot  */ 0,
    /* led   */ NO_PIN,
    TouchController::Cst816,
    /* touchSda */ 11,
    /* touchScl */ 10,
    /* touchRst */ NO_PIN,
    /* touchInt */ 4,
    PowerController::None,
    /* batteryAdc */ NO_PIN,
    /* adcScale */ 0,
    /* batteryEnable */ NO_PIN,
    /* chargeStatus */ NO_PIN,
    MotionController::None,
    /* motion X */ 0, 1,
    /* motion Y */ 1, 1,
    /* panelResetExio */ 2,
    /* touchResetExio */ 1,
    /* pinBlEnable */ NO_PIN,
    /* backlightInverted */ false,
};

/// ESP32-S3-LCD-0.85: GC9107 128x128 square LCD over 4-wire SPI.
/// PLUS (GPIO4) and PWR (GPIO5) are carrier controls with no stream-firmware
/// action; only BOOT GPIO0 is mapped to the established button behavior.
static const Config CONFIG_LCD_GC9107 = {
    Variant::LcdGc9107,
    "ESP32-S3-LCD-0.85 (GC9107)",
    &PLATFORM_ESP32_S3,
    &PANEL_GC9107_128X128,
    /* sclk  */ 38,
    /* mosi  */ 39,
    /* data1 */ NO_PIN,
    /* data2 */ NO_PIN,
    /* data3 */ NO_PIN,
    /* cs    */ 21,
    /* dc    */ 45,
    /* rst   */ 40,
    /* bl    */ 46,
    /* boot  */ 0,
    /* led   */ 48,
    TouchController::None,
    /* touchSda */ NO_PIN,
    /* touchScl */ NO_PIN,
    /* touchRst */ NO_PIN,
    /* touchInt */ NO_PIN,
    PowerController::BatteryAdc,
    /* batteryAdc */ 1,
    /* adcScale */ 3,
    /* batteryEnable */ 2,
    /* chargeStatus */ 3,
    MotionController::None,
    /* motion X */ 0, 1,
    /* motion Y */ 1, 1,
    /* panelResetExio */ 0,
    /* touchResetExio */ 0,
    /* pinBlEnable */ NO_PIN,
    /* backlightInverted */ false,
};

/// ESP32-S3-Touch-LCD-1.54: 240x240 ST7789 over 4-wire SPI, with a
/// directly-reset CST816 touch controller and QMI8658 on I2C GPIO42/41.
/// GPIO4/GPIO5 are auxiliary carrier buttons; only BOOT GPIO0 is assigned an
/// established stream-firmware action.
static const Config CONFIG_TOUCH_ST7789 = {
    Variant::TouchSt7789,
    "ESP32-S3-Touch-LCD-1.54 (ST7789)",
    &PLATFORM_ESP32_S3,
    &PANEL_ST7789_240X240,
    /* sclk  */ 38,
    /* mosi  */ 39,
    /* data1 */ NO_PIN,
    /* data2 */ NO_PIN,
    /* data3 */ NO_PIN,
    /* cs    */ 21,
    /* dc    */ 45,
    /* rst   */ 40,
    /* bl    */ 46,
    /* boot  */ 0,
    /* led   */ NO_PIN,
    TouchController::Cst816,
    /* touchSda */ 42,
    /* touchScl */ 41,
    /* touchRst */ 47,
    /* touchInt */ 48,
    PowerController::BatteryAdc,
    /* batteryAdc */ 1,
    /* adcScale */ 3,
    /* batteryEnable */ 2,
    /* chargeStatus */ 3,
    MotionController::Qmi8658,
    // Waveshare's QMI8658 example exposes the sensor axes without remapping.
    /* motion X */ 0, 1,
    /* motion Y */ 1, 1,
    /* panelResetExio */ 0,
    /* touchResetExio */ 0,
    /* pinBlEnable */ NO_PIN,
    /* backlightInverted */ false,
};

/// Waveshare ESP32-S3-LCD-1.3: 240x240 ST7789V2 over 4-wire SPI,
/// QMI8658A on I2C GPIO47/48, a 2:1 battery divider on GPIO7, and one
/// WS2812-compatible RGB LED on GPIO19. The schematic routes backlight PWM to
/// GPIO20; Waveshare's Arduino demo confirms mode 0, 40 MHz, RGB order,
/// inversion, and zero display offsets. The standard, case, and prism versions
/// share this carrier; square-panel software rotation covers the prism mount.
static const Config CONFIG_LCD_ST7789_130 = {
    Variant::LcdSt7789_130,
    "ESP32-S3-LCD-1.3 (ST7789V2)",
    &PLATFORM_ESP32_S3,
    &PANEL_ST7789V2_240X240,
    /* sclk  */ 40,
    /* mosi  */ 41,
    /* data1 */ NO_PIN,
    /* data2 */ NO_PIN,
    /* data3 */ NO_PIN,
    /* cs    */ 39,
    /* dc    */ 38,
    /* rst   */ 42,
    /* bl    */ 20,
    /* boot  */ NO_PIN,
    /* led   */ 19,
    TouchController::None,
    /* touchSda */ 47,  // shared QMI8658A bus; this board has no touch
    /* touchScl */ 48,
    /* touchRst */ NO_PIN,
    /* touchInt */ NO_PIN,
    PowerController::BatteryAdc,
    /* batteryAdc */ 7,
    /* adcScale */ 2,
    /* batteryEnable */ NO_PIN,
    /* chargeStatus */ NO_PIN,
    MotionController::Qmi8658,
    // Waveshare's examples consume the QMI8658 axes without remapping.
    /* motion X */ 0, 1,
    /* motion Y */ 1, 1,
    /* panelResetExio */ 0,
    /* touchResetExio */ 0,
    /* pinBlEnable */ NO_PIN,
    /* backlightInverted */ false,
    /* serialRx */ 44,
    /* serialTx */ 43,
};

/// Waveshare ESP32-P4-WIFI6-Touch-LCD-4B: ST7703 720x720 over MIPI-DSI,
/// GT911 polling touch, and an ESP32-C6 hosted-WiFi coprocessor. The P4
/// platform and ST7703 panel remain reusable; this row owns only their exact
/// carrier composition and wiring.
static const Config CONFIG_P4_4B = {
    Variant::P4_4B,
    "ESP32-P4-WIFI6-Touch-LCD-4B (ST7703)",
    &PLATFORM_ESP32_P4,
    &PANEL_ST7703_720X720,
    /* sclk */ NO_PIN,
    /* mosi */ NO_PIN,
    /* data1 */ NO_PIN,
    /* data2 */ NO_PIN,
    /* data3 */ NO_PIN,
    /* cs */ NO_PIN,
    /* dc */ NO_PIN,
    /* rst */ 27,
    /* bl */ 26,
    /* boot */ 35,
    /* led */ NO_PIN,
    TouchController::Gt911,
    /* touchSda */ 7,
    /* touchScl */ 8,
    /* touchRst */ NO_PIN,
    /* touchInt */ NO_PIN,
    PowerController::None,
    /* batteryAdc */ NO_PIN,
    /* adcScale */ 0,
    /* batteryEnable */ NO_PIN,
    /* chargeStatus */ NO_PIN,
    MotionController::None,
    /* motion X */ 0, 1,
    /* motion Y */ 1, 1,
    /* panelResetExio */ 0,
    /* touchResetExio */ 0,
    /* pinBlEnable */ 33,
    /* backlightInverted */ true,
};

/// Whether a physical profile belongs to a platform family. This is used both
/// for CFGBOARD recovery overrides and for detection results, so neither path
/// can make a family artifact drive another chip family's pin map.
inline bool variantMatchesPlatform(Variant variant, Platform platform) {
  switch (platform) {
    case Platform::Esp32C6:
      return variant == Variant::LcdSt7789 ||
             variant == Variant::TouchJd9853;
    case Platform::Esp32S3:
      return variant == Variant::AmoledCo5300 ||
             variant == Variant::LcdSt77916 ||
             variant == Variant::LcdGc9107 ||
             variant == Variant::TouchSt7789 ||
             variant == Variant::LcdSt7789_130;
    case Platform::Esp32P4:
      return variant == Variant::P4_4B;
  }
  return false;
}

/// Resolve the S3 detector's independent profile signals. The 8 MiB carrier is
/// identified by flash capacity; each larger-flash profile has a distinct I2C
/// bus. Exactly one candidate is required. No match and conflicting matches
/// both remain Unknown so setup can stay serial-only until CFGBOARD supplies an
/// explicit recovery override.
inline Variant variantFromS3Probe(uint32_t flashBytes, bool co5300Bus,
                                  bool st77916Bus, bool st7789Bus,
                                  bool st7789_130Bus) {
  const bool gc9107 = flashBytes > 0 && flashBytes <= 8u * 1024u * 1024u;
  const bool allowLargerProfiles = flashBytes > 8u * 1024u * 1024u;
  const bool candidates[] = {
      gc9107,
      allowLargerProfiles && co5300Bus,
      allowLargerProfiles && st77916Bus,
      allowLargerProfiles && st7789Bus,
      allowLargerProfiles && st7789_130Bus,
  };
  uint8_t count = 0;
  uint8_t selected = 0;
  for (uint8_t i = 0; i < sizeof(candidates) / sizeof(candidates[0]); ++i) {
    if (candidates[i]) {
      ++count;
      selected = i;
    }
  }
  if (count != 1) return Variant::Unknown;
  switch (selected) {
    case 0: return Variant::LcdGc9107;
    case 1: return Variant::AmoledCo5300;
    case 2: return Variant::LcdSt77916;
    case 3: return Variant::TouchSt7789;
    case 4: return Variant::LcdSt7789_130;
    default: return Variant::Unknown;
  }
}

/// Map a possibly-Unknown C6 variant onto the electrically safer C6 profile.
///
/// Unknown resolves to the C6 Touch board on purpose; it can only arise on the
/// C6, because the S3 build pins COMPILED_VARIANT. Both C6 misdetections leave
/// the panel dark, because the SPI pins differ - but they are not equally
/// clean electrically:
///
///   Touch board treated as non-touch  -> SPI clock and data land on GPIO7 and
///       GPIO6, and panel reset on GPIO21. On that board GPIO6 is the QMI8658A
///       interrupt 2 and GPIO21 is the AXS5106L touch interrupt: both are chip
///       *outputs*, so the ESP32 would be driving against two live drivers. It
///       would also PWM GPIO22, which is that board's panel reset. GPIO8 would
///       be driven as a LED output despite having no LED and no known function.
///   Non-touch board treated as Touch  -> SPI lands on GPIO1/GPIO2 and reset on
///       GPIO22, none of which is a known output on that board, and touch setup
///       pulses GPIO20 and reads GPIO21. Pins of unknown function, but nothing
///       confirmed to be driven from the other end.
///
/// Only one of those directions is known to fight two chip outputs, so an
/// inconclusive probe lands on Touch. Note this inverts the historical default
/// of this firmware, and that the original justification for it was stronger
/// than the facts: it assumed Waveshare's claim that GPIO8 is the Touch board's
/// BOOT button, which measurement disproved. The conclusion survives the
/// correction; the reasoning had to be rewritten.
inline Variant resolve(Variant variant) {
  return variant == Variant::Unknown ? Variant::TouchJd9853 : variant;
}

/// The board table for a variant. Unknown resolves per resolve().
inline const Config &configFor(Variant variant) {
  switch (resolve(variant)) {
    case Variant::LcdSt7789:
      return CONFIG_LCD_ST7789;
    case Variant::AmoledCo5300:
      return CONFIG_AMOLED_CO5300;
    case Variant::LcdSt77916:
      return CONFIG_LCD_ST77916;
    case Variant::LcdGc9107:
      return CONFIG_LCD_GC9107;
    case Variant::TouchSt7789:
      return CONFIG_TOUCH_ST7789;
    case Variant::LcdSt7789_130:
      return CONFIG_LCD_ST7789_130;
    case Variant::P4_4B:
      return CONFIG_P4_4B;
    default:
      return CONFIG_TOUCH_JD9853;
  }
}

/// Decide the C6 variant from an I2C scan of PIN_PROBE_SDA/SCL.
///
/// The Touch board carries an AXS5106L touch controller and a QMI8658A IMU on
/// that bus (observed at 0x63 and 0x6B); the non-touch board has nothing there.
/// So "anything answered" is the discriminator.
///
/// Only meaningful when COMPILED_VARIANT is Unknown (the C6 build). The S3
/// board also has I2C devices, but its variant never reaches this decision.
///
/// probeSucceeded is whether the scan itself ran meaningfully. A bus that could
/// not be driven tells us nothing about which board this is, and per resolve()
/// "nothing known" must mean Touch.
inline Variant variantFromI2cProbe(bool probeSucceeded, int deviceCount) {
  if (!probeSucceeded) {
    return Variant::TouchJd9853;
  }
  return deviceCount > 0 ? Variant::TouchJd9853 : Variant::LcdSt7789;
}

/// Parse a variant previously cached in NVS.
///
/// Returns Unknown for anything unrecognised (never written, or written by a
/// future firmware with more variants) so the caller re-probes instead of
/// trusting a value it cannot interpret.
inline Variant variantFromStored(uint8_t raw) {
  if (raw == (uint8_t)Variant::LcdSt7789) return Variant::LcdSt7789;
  if (raw == (uint8_t)Variant::TouchJd9853) return Variant::TouchJd9853;
  if (raw == (uint8_t)Variant::AmoledCo5300) return Variant::AmoledCo5300;
  if (raw == (uint8_t)Variant::LcdSt77916) return Variant::LcdSt77916;
  if (raw == (uint8_t)Variant::LcdGc9107) return Variant::LcdGc9107;
  if (raw == (uint8_t)Variant::TouchSt7789) return Variant::TouchSt7789;
  if (raw == (uint8_t)Variant::P4_4B) return Variant::P4_4B;
  if (raw == (uint8_t)Variant::LcdSt7789_130) return Variant::LcdSt7789_130;
  return Variant::Unknown;
}

/// Parse an operator override (CFGBOARD over USB serial).
///
/// Exact tokens only. "auto" - and anything unrecognised - maps to Unknown,
/// which is the caller's cue to clear the cache and re-probe rather than pin
/// the board to a guess.
inline Variant variantFromName(const char *token) {
  if (token == nullptr) return Variant::Unknown;
  if (strcmp(token, "st7789") == 0) return Variant::LcdSt7789;
  if (strcmp(token, "jd9853") == 0) return Variant::TouchJd9853;
  if (strcmp(token, "co5300") == 0) return Variant::AmoledCo5300;
  if (strcmp(token, "st77916") == 0) return Variant::LcdSt77916;
  if (strcmp(token, "gc9107") == 0) return Variant::LcdGc9107;
  if (strcmp(token, "st7789-154") == 0) return Variant::TouchSt7789;
  if (strcmp(token, "st7789-130") == 0) return Variant::LcdSt7789_130;
  if (strcmp(token, "st7703-4b") == 0) return Variant::P4_4B;
  return Variant::Unknown;
}

/// Short stable token for a variant, for CFGSHOW/telemetry and NVS debugging.
inline const char *variantToken(Variant variant) {
  switch (variant) {
    case Variant::LcdSt7789:
      return "st7789";
    case Variant::TouchJd9853:
      return "jd9853";
    case Variant::AmoledCo5300:
      return "co5300";
    case Variant::LcdSt77916:
      return "st77916";
    case Variant::LcdGc9107:
      return "gc9107";
    case Variant::TouchSt7789:
      return "st7789-154";
    case Variant::LcdSt7789_130:
      return "st7789-130";
    case Variant::P4_4B:
      return "st7703-4b";
    default:
      return "auto";
  }
}

/// Stable user-facing firmware family, distinct from the physical profile.
inline const char *targetToken(Variant variant) {
  switch (variant) {
    case Variant::LcdSt7789:
    case Variant::TouchJd9853:
      return "c6";
    case Variant::AmoledCo5300:
    case Variant::LcdSt77916:
    case Variant::LcdGc9107:
    case Variant::TouchSt7789:
    case Variant::LcdSt7789_130:
      return "s3";
    case Variant::P4_4B:
      return "p4";
    default:
      return "unknown";
  }
}

}  // namespace board
