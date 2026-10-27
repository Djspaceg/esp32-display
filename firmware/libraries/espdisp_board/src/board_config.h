// Which supported board this binary is running on, and every board fact that
// follows from that.
//
// Fifteen board profiles are supported across the c3, c6, s3, and p4 release
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
//   XIAO ESP32-S3 + 0.42-inch  ST7735 96x54 over SPI, BOOT on GPIO0,
//                              backlight always on, nothing else
//   ESP32-S3-LCD-1.3           ST7789V2 240x240 over SPI, QMI8658A IMU on
//                              I2C GPIO47/48, battery ADC and one RGB LED
//   ESP32-S3-LCD-1.9           ST7789V2 170x320 over SPI, QMI8658 IMU on
//                              I2C GPIO47/48, two GRB LEDs, active-low
//                              backlight
//   ESP32-S3-Touch-LCD-1.54    ST7789 240x240 over SPI, CST816 touch and
//                              QMI8658 IMU on I2C GPIO42/41, battery ADC
//   ESP32-S3-Touch-LCD-1.85C   ST77916 360x360 LCD over QSPI, CST816 touch
//                              on I2C GPIO11/10, reset through TCA9554
//   CrowPanel 1.28 Rotary Knob GC9A01 240x240 round LCD over SPI, CST816D
//                              touch on I2C GPIO6/7, rotary encoder on
//                              GPIO45/42 and knob press on GPIO41
//   LilyGO T-Watch-S3          ST7789V3 240x240 over SPI, FT6336U touch on
//                              I2C GPIO39/40, AXP2101 PMU on its own I2C
//                              GPIO10/11 powering the panel (ALDO2/ALDO3)
//   ESP32-P4-WIFI6-Touch-LCD-4B  ST7703 720x720 over MIPI-DSI, GT911 touch on
//                              I2C GPIO7/8
//   ESP32-P4-WIFI6-Touch-LCD-4C  JD9365 720x720 round LCD over MIPI-DSI, GT911
//                              touch on I2C GPIO7/8
//   ESP32-P4-WIFI6-Touch-LCD-3.4C  JD9365 800x800 round LCD, otherwise the 4C
//
// The C6 and S3 families choose a profile before any panel GPIO is driven,
// except that the CrowPanel knob probe pulses that board's panel supply rail
// (GPIO1), and only when no earlier S3 probe has answered.
// C6 distinguishes its two profiles on one shared I2C bus. S3 probes the
// 0.85's codec bus on 8 MiB hardware (an answer is the GC9107 carrier, silence
// the XIAO's ST7735), then profile-specific I2C buses on larger-flash hardware,
// and accepts a result only when exactly one profile matches. P4 carries two MIPI-DSI carriers whose I2C buses answer alike, so
// it reads the panel controller's own ID over DSI before choosing one.
//
// Resolution is a panel-profile fact. The sketch derives frame geometry from
// the Config's composed PanelConfig instead of a project-wide constant.
//
// This header is deliberately hardware-free (pure data plus arithmetic) so it
// is unit tested on the host alongside band_protocol.h and panel_state.h. The
// board_detect.h executes the generated electrical plan because it needs Wire.
#pragma once

#include <stdint.h>
#include <string.h>

#include "audio_config.h"
#include "board_detection.h"
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
#include "generated_board_variants.h"
#include "generated_board_identity.h"
#include "generated_board_audio.h"
#include "generated_board_touch.h"
#include "generated_board_detection.h"

/// Which capacitive touch controller the board carries, so the sketch knows
/// which register protocol to speak. The pins alone cannot tell these apart.
enum class TouchController : uint8_t {
  None,
  Axs5106l,
  Cst9217,
  Cst816,
  Gt911,
  Ft6336,
};

/// How battery telemetry is obtained. The S3's AXP2101 reports voltage,
/// percentage, external power, and charge state. The C6 touch board exposes
/// only a 3:1 battery-voltage divider on GPIO0; it can estimate percentage but
/// cannot observe the ETA6098 charger's STAT output, so charge state remains
/// explicitly unknown.
enum class PowerController : uint8_t { None, Axp2101, BatteryAdc };

/// Which inertial sensor supplies acceleration for automatic orientation.
enum class MotionController : uint8_t { None, Qmi8658, Bma423 };

/// The variant fixed by an exact build target before runtime detection.
/// Every family is universal now, so each remains Unknown until its safe
/// profile detector or an explicit CFGBOARD recovery override resolves one.
/// P4 keeps its historical ESPDISP_BOARD_P4_4B family selector, which now
/// composes the P4 platform with every P4 carrier; platform_config.h remains
/// free of carrier selectors and wiring.
#if defined(CONFIG_IDF_TARGET_ESP32P4)
#if (defined(ESPDISP_BOARD_P4_4B) + defined(ESPDISP_BOARD_S3_085) + \
     defined(ESPDISP_BOARD_S3_154) + defined(ESPDISP_DOOM_S3_175) + \
     defined(ESPDISP_BOARD_S3_185)) != 1
#error "ESP32-P4 builds require exactly one compatible internal carrier selector"
#endif
#if defined(ESPDISP_DOOM_RUNTIME) && !defined(ESPDISP_BOARD_P4_4B)
#error "ESP32-P4 Doom runtime requires the board-neutral P4 family selector"
#endif
#if defined(ESPDISP_BOARD_P4_4B)
#include "generated_p4_compile.h"
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
#elif defined(CONFIG_IDF_TARGET_ESP32C3)
#if defined(ESPDISP_BOARD_P4_4B) || defined(ESPDISP_BOARD_S3_085) || \
    defined(ESPDISP_BOARD_S3_154) || defined(ESPDISP_DOOM_S3_175) || \
    defined(ESPDISP_BOARD_S3_185) || defined(ESPDISP_DOOM_RUNTIME)
#error "ESP32-C3 family builds must not use selectors from another family"
#endif
#define ESPDISP_PANEL_C3_RUNTIME 1
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
/// on the S3, whose generated plan uses four different buses.
static const int8_t PIN_PROBE_SDA = GENERATED_C6_PROBES[0].sda;
static const int8_t PIN_PROBE_SCL = GENERATED_C6_PROBES[0].scl;
/// Touch controller reset, as used by *detection*, which necessarily runs before
/// the variant is known and so cannot read it out of the table below. Released
/// before probing so a touch chip held in reset cannot make a Touch board look
/// like a non-touch one. Must equal CONFIG_TOUCH_JD9853.pinTouchRst.
static const int8_t PIN_PROBE_TP_RST = GENERATED_C6_PROBES[0].resetPin;

/// Whether a platform can execute a panel profile. SPI/QSPI panel backends are
/// platform-neutral; the MIPI-DSI SDK backend is currently available on P4.
/// Carrier pins are deliberately absent from this decision.
constexpr bool platformSupportsPanel(const PlatformConfig &platform,
                                     const PanelConfig &panel) {
  return panel.bus != PanelBus::MipiDsi ||
         platform.platform == Platform::Esp32P4;
}

/// The carrier composition consumed after detection. Controller implementations
/// may still branch on capabilities, but board facts belong in descriptor-backed
/// rows rather than scattered profile tests.
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

  // BOOT button: short press opens the WiFi status screen, double press the
  // WiFi selector, long press flips 180.
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

  /// Optional GPIO that switches the panel's own supply rail. Panel bring-up
  /// drives it high before the bus starts and holds it there (boot detection
  /// may pulse it earlier). On the CrowPanel knob it also feeds the backlight
  /// anode and the touch pull-ups.
  int8_t pinPanelPower = NO_PIN;

  /// Optional quadrature rotary encoder, both lines idle-high. Its push switch,
  /// when it has one, is the carrier's pinBootButton.
  int8_t pinEncoderA = NO_PIN;
  int8_t pinEncoderB = NO_PIN;

  /// Addressable LED byte order: GRB for WS2812B parts driven that way by the
  /// vendor, otherwise the RGB order measured on the C6.
  bool rgbLedGrb = false;

  /// The lowest backlight PWM duty, in thousandths of full, at which the glass
  /// shows anything. Zero means the backlight lights at any duty. A lit level
  /// whose duty would fall below it is raised to it (backlight_curve.h), so no
  /// lit level is black; level 0 still turns it off.
  uint16_t backlightFloorPermille = 0;

  /// The PMU's own I2C bus, when it is not the touch bus. Both NO_PIN means
  /// the AXP2101 shares the touch bus, as on the 1.75C. A carrier that
  /// declares one (the T-Watch-S3: AXP2101 on GPIO10/11, touch alone on
  /// GPIO39/40) gets the PMU on the chip's second I2C controller, Wire1, so
  /// neither bus is ever re-pinned while the other is in use.
  int8_t pinPmuSda = NO_PIN;
  int8_t pinPmuScl = NO_PIN;

  /// The AXP2101 ALDOs that feed the panel, its backlight or its touch
  /// controller, as LDO_ONOFF_CTRL0 (90H) bits: bit 0 ALDO1 .. bit 3 ALDO4.
  /// Panel bring-up sets each to PMU_PANEL_RAIL_MILLIVOLTS and switches it on
  /// before the panel bus starts. Zero: no PMU-switched panel rail.
  uint8_t pmuPanelAldoMask = 0;

  /// The VBUS input current limit an AXP2101 board is raised to when its PMU
  /// holds less (boardpower::init). 1500 mA from the 1.75C's brown-out; a
  /// carrier whose vendor sets a lower one keeps the vendor's.
  uint16_t pmuInputLimitMilliamps = 1500;

  /// Whether some units of this carrier have no BOOT key to press although
  /// pinBootButton is wired (the T-Watch-S3's earlier batches: the switch
  /// pad is there, the key on the back cover is not). Doom then gives the
  /// PWR key BOOT's tiers (menu, previous menu, 3 s exit) instead of firing
  /// with it, since nothing else can open the menu or leave mid-game; touch
  /// still fires.
  bool bootButtonOptional = false;

  /// The accelerometer's own I2C bus, when it is not the touch bus. Both
  /// NO_PIN means it shares the touch bus (every QMI8658 board). The
  /// T-Watch-S3's BMA423 sits on its main bus, GPIO10/11, with the AXP2101,
  /// so it is read on the same Wire1 the PMU uses.
  int8_t pinMotionSda = NO_PIN;
  int8_t pinMotionScl = NO_PIN;

  bool hasMotionBus() const {
    return pinMotionSda != NO_PIN && pinMotionScl != NO_PIN;
  }
  int8_t motionSda() const {
    return hasMotionBus() ? pinMotionSda : pinTouchSda;
  }
  int8_t motionScl() const {
    return hasMotionBus() ? pinMotionScl : pinTouchScl;
  }

  bool hasPmuBus() const {
    return pinPmuSda != NO_PIN && pinPmuScl != NO_PIN;
  }
  /// The bus the PMU answers on: its own, or else the touch bus.
  int8_t pmuSda() const { return hasPmuBus() ? pinPmuSda : pinTouchSda; }
  int8_t pmuScl() const { return hasPmuBus() ? pinPmuScl : pinTouchScl; }

  SerialTransport serialTransport() const {
    return pinSerialRx != NO_PIN && pinSerialTx != NO_PIN
               ? SerialTransport::UartBridge
               : platform->serial;
  }

  bool hasRgbLed() const { return pinRgbLed != NO_PIN; }
  bool hasBootButton() const { return pinBootButton != NO_PIN; }
  bool hasEncoder() const {
    return pinEncoderA != NO_PIN && pinEncoderB != NO_PIN;
  }
  bool hasTouch() const {
    if (touch == TouchController::None || pinTouchSda == NO_PIN ||
        pinTouchScl == NO_PIN) {
      return false;
    }
    if (touch == TouchController::Gt911) return true;  // polling profile
    // The T-Watch-S3's FT6336U has no reset line (LilyGO: "Not Connected");
    // its interrupt is all it needs.
    if (touch == TouchController::Ft6336) return pinTouchInt != NO_PIN;
    return (pinTouchRst != NO_PIN || touchResetExio != 0) &&
           pinTouchInt != NO_PIN;
  }
  /// Whether a battery reading is possible at all on this board. The bus pins
  /// are part of the test because the PMU is read over I2C (its own bus or
  /// the touch bus): a controller with nowhere to talk cannot be read, and
  /// claiming otherwise would make the firmware advertise a battery it can
  /// never sample.
  bool hasBattery() const {
    if (power == PowerController::Axp2101) {
      return pmuSda() != NO_PIN && pmuScl() != NO_PIN;
    }
    if (power == PowerController::BatteryAdc) {
      return pinBatteryAdc != NO_PIN && batteryAdcScale > 0;
    }
    return false;
  }
  bool hasMotion() const {
    return motion != MotionController::None && motionSda() != NO_PIN &&
           motionScl() != NO_PIN && motionXAxis < 3 && motionYAxis < 3 &&
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

#include "generated_board_configs.h"

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
    // GPIO8 is the battery sense, through the same 3:1 divider the other
    // divider boards use. Confirmed on attached hardware at 3750 mV / 35
    // percent. The divider intermittently returns 0, and an earlier session
    // sampled a run of those zeros, concluded the pin was dead and reverted
    // this declaration; batteryestimate::selectCellMillivolts is what makes
    // them harmless, by taking the median of the samples that could physically
    // be a cell. GPIO8 is ADC1_CH7, the WiFi-safe ADC unit, and is otherwise
    // unused in this pin map, so the zeros are a property of the divider rather
    // than of the assignment.
    //
    // No enable line and no charge-status net exist on this design, so charge
    // state stays honestly unknown - the same posture the C6 takes.
    PowerController::BatteryAdc,
    /* batteryAdc */ 8,
    /* adcScale */ 3,
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

/// Seeed XIAO ESP32-S3 with the Questwise 0.42-inch 96x54 ST7735 TFT, wired to
/// the tiny TFT carrier's pin map (hardware/tiny-tft-carrier/DESIGN.md). The
/// screen pulls its BL input high, so the backlight is always on and no
/// backlight pin is declared: GPIO2 (D1, bridged to BL only by the carrier's
/// JP1) is never driven. The XIAO's user LED on GPIO21 is a plain LED and is
/// left alone. No touch, IMU, battery or audio.
static const Config CONFIG_XIAO_ST7735_042 = {
    Variant::XiaoSt7735,
    "XIAO ESP32-S3 + 0.42-inch 96x54 screen",
    &PLATFORM_ESP32_S3,
    &PANEL_ST7735_96X54,
    /* sclk  */ 7,
    /* mosi  */ 9,
    /* data1 */ NO_PIN,
    /* data2 */ NO_PIN,
    /* data3 */ NO_PIN,
    /* cs    */ 6,
    /* dc    */ 4,
    /* rst   */ 5,
    /* bl    */ NO_PIN,
    /* boot  */ 0,
    /* led   */ NO_PIN,
    TouchController::None,
    /* touchSda */ NO_PIN,
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

/// Waveshare ESP32-S3-LCD-1.9: 170x320 ST7789V2 over 4-wire SPI (column
/// offset 35 in a 240x320 controller), QMI8658 on I2C GPIO47/48, BOOT on
/// GPIO0, two WS2812B on GPIO15, native USB-Serial-JTAG on GPIO19/20. The
/// backlight is an AO3401 P-FET, so GPIO14 is active low. GPIO4 senses the
/// system rail through a 200k/100k divider: it reads VSYS/3 on USB and on
/// battery alike, which makes it the detection guard that keeps this carrier
/// apart from the 1.3-inch one, and not a battery gauge. Pins and init facts
/// are from Waveshare's schematic and ESP-IDF factory demo.
static const Config CONFIG_LCD_ST7789_190 = {
    Variant::LcdSt7789_190,
    "ESP32-S3-LCD-1.9 (ST7789V2)",
    &PLATFORM_ESP32_S3,
    &PANEL_ST7789V2_170X320,
    /* sclk  */ 10,
    /* mosi  */ 13,
    /* data1 */ NO_PIN,
    /* data2 */ NO_PIN,
    /* data3 */ NO_PIN,
    /* cs    */ 12,
    /* dc    */ 11,
    /* rst   */ 9,
    /* bl    */ 14,
    /* boot  */ 0,
    /* led   */ 15,
    TouchController::None,
    /* touchSda */ 47,  // shared QMI8658 bus; the non-touch SKU has no touch
    /* touchScl */ 48,
    /* touchRst */ NO_PIN,
    /* touchInt */ NO_PIN,
    // No battery telemetry: the GPIO4 divider sits on the system rail, which
    // is VBUS through a diode on USB, so it would report a full cell whenever
    // the board is plugged in, battery or not.
    PowerController::None,
    /* batteryAdc */ NO_PIN,
    /* adcScale */ 0,
    /* batteryEnable */ NO_PIN,
    /* chargeStatus */ NO_PIN,
    MotionController::Qmi8658,
    // Waveshare's QMI8658 example consumes the sensor axes without remapping.
    /* motion X */ 0, 1,
    /* motion Y */ 1, 1,
    /* panelResetExio */ 0,
    /* touchResetExio */ 0,
    /* pinBlEnable */ NO_PIN,
    /* backlightInverted */ true,
    /* serialRx */ NO_PIN,
    /* serialTx */ NO_PIN,
    /* panelPower */ NO_PIN,
    /* encoderA */ NO_PIN,
    /* encoderB */ NO_PIN,
    // Waveshare's ESP-IDF and Arduino WS2812 demos both drive these as GRB.
    /* rgbLedGrb */ true,
};

/// ELECROW CrowPanel 1.28" rotary display: GC9A01 240x240 round IPS over
/// 4-wire SPI, CST816D touch on GPIO6/7, and a detented EC3501 encoder whose
/// push switch (GPIO41, active low) takes the BOOT-button actions. GPIO1 powers
/// the LCD-3.3 rail - panel, backlight anode and touch pull-ups - so nothing on
/// the glass works until it is high. Nets are from ELECROW's schematic; the
/// vendor factory sketch confirms the same pins and SPI mode 0 with inversion.
/// The five-LED WS2812 ring (GPIO48) and green power LED (GPIO40) are left
/// undriven.
static const Config CONFIG_ELECROW_KNOB_128 = {
    Variant::ElecrowKnob128,
    "CrowPanel 1.28 Rotary Knob (GC9A01)",
    &PLATFORM_ESP32_S3,
    &PANEL_GC9107_240X240,
    /* sclk  */ 10,
    /* mosi  */ 11,
    /* data1 */ NO_PIN,
    /* data2 */ NO_PIN,
    /* data3 */ NO_PIN,
    /* cs    */ 9,
    /* dc    */ 3,
    /* rst   */ 14,
    /* bl    */ 46,
    /* boot  */ 41,  // knob push switch; the chip BOOT key GPIO0 is unused
    /* led   */ NO_PIN,
    TouchController::Cst816,
    /* touchSda */ 6,
    /* touchScl */ 7,
    /* touchRst */ 13,
    /* touchInt */ 5,
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
    /* serialRx */ NO_PIN,
    /* serialTx */ NO_PIN,
    /* panelPower */ 1,
    /* encoderA */ 45,
    /* encoderB */ 42,
};

/// LilyGO T-Watch-S3: ST7789V3 240x240 IPS over 4-wire SPI (SCLK GPIO18, MOSI
/// GPIO13, CS GPIO12, DC GPIO38; reset is an RC network, no GPIO), backlight
/// PWM GPIO45 into an NPN low-side switch (active high). FT6336U touch alone
/// on I2C GPIO39/40, INT GPIO16, no reset line. The AXP2101 (0x34) sits on
/// the main bus GPIO10/11 beside the BMA423 IMU, PCF8563 RTC and DRV2605
/// haptic driver, and its ALDO2 (backlight anode) and ALDO3 (panel logic,
/// touch and touch pull-ups) must be on before the glass shows anything. The
/// crown is the AXP2101 PWR key; BOOT is GPIO0. No IMU driver, speaker,
/// microphone, radio, IR or haptics are driven here. Every fact is from
/// LilyGO's code and schematic; boards/s3-lilygo-twatch-s3.toml cites each.
static const Config CONFIG_LILYGO_TWATCH_S3 = {
    Variant::LilygoTwatchS3,
    "LilyGO T-Watch-S3 (ST7789V3)",
    &PLATFORM_ESP32_S3,
    &PANEL_ST7789V3_240X240,
    /* sclk  */ 18,
    /* mosi  */ 13,
    /* data1 */ NO_PIN,
    /* data2 */ NO_PIN,
    /* data3 */ NO_PIN,
    /* cs    */ 12,
    /* dc    */ 38,
    /* rst   */ NO_PIN,
    /* bl    */ 45,
    /* boot  */ 0,
    /* led   */ NO_PIN,
    TouchController::Ft6336,
    /* touchSda */ 39,
    /* touchScl */ 40,
    /* touchRst */ NO_PIN,
    /* touchInt */ 16,
    PowerController::Axp2101,
    /* batteryAdc */ NO_PIN,
    /* adcScale */ 0,
    /* batteryEnable */ NO_PIN,
    /* chargeStatus */ NO_PIN,
    // BMA423 on the main bus. Panel-right is sensor +Y and panel-down sensor
    // -X: LilyGO's own remap for this board (BOTTOM_LAYER_TOP_RIGHT_CORNER,
    // device x = sensor Y, device y = sensor X, z = -Z) turned into this
    // firmware's panel-right/panel-down frame.
    MotionController::Bma423,
    /* motion X */ 1, 1,
    /* motion Y */ 0, -1,
    /* panelResetExio */ 0,
    /* touchResetExio */ 0,
    /* pinBlEnable */ NO_PIN,
    /* backlightInverted */ false,
    /* serialRx */ NO_PIN,
    /* serialTx */ NO_PIN,
    /* panelPower */ NO_PIN,
    /* encoderA */ NO_PIN,
    /* encoderB */ NO_PIN,
    /* rgbLedGrb */ false,
    /* backlightFloorPermille */ 0,
    /* pmuSda */ 10,
    /* pmuScl */ 11,
    /* pmuPanelAldoMask */ 0x06,  // ALDO2 | ALDO3
    /* pmuInputLimitMilliamps */ 900,
    /* bootButtonOptional */ true,
    /* motionSda */ 10,
    /* motionScl */ 11,
};

/// Waveshare ESP32-P4-WIFI6-Touch-LCD-4C: JD9365 720x720 round IPS over
/// two-lane MIPI-DSI, on the "XC" carrier it shares with the 3.4-inch 3.4C.
/// Panel reset GPIO27; backlight PWM GPIO26 into the AP3032 boost feedback, so
/// active low (the BSP inverts LEDC), with BL_EN on GPIO33 pulled up; BOOT
/// GPIO35. GT911-family touch is polled on I2C GPIO7/8: its reset (GPIO23)
/// is left alone, as the BSP does, and its interrupt only reaches a test pad.
/// The ES8311 codec (0x18) and ES7210 mic ADC (0x40) share that bus; the
/// NS4150B amplifier enable is GPIO53 (audio comes from the descriptor). No IMU,
/// PMU, battery gauge or addressable LED. CH343 UART bridge on the USB-C port.
/// Pins and timing are from Waveshare's XC schematic and BSP 3.0.1.
static const Config CONFIG_P4_4C = {
    Variant::P4_4C,
    "ESP32-P4-WIFI6-Touch-LCD-4C (JD9365)",
    &PLATFORM_ESP32_P4,
    &PANEL_JD9365_720X720,
    /* sclk  */ NO_PIN,
    /* mosi  */ NO_PIN,
    /* data1 */ NO_PIN,
    /* data2 */ NO_PIN,
    /* data3 */ NO_PIN,
    /* cs    */ NO_PIN,
    /* dc    */ NO_PIN,
    /* rst   */ 27,
    /* bl    */ 26,
    /* boot  */ 35,
    /* led   */ NO_PIN,
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
    /* serialRx */ NO_PIN,
    /* serialTx */ NO_PIN,
    /* panelPower */ NO_PIN,
    /* encoderA */ NO_PIN,
    /* encoderB */ NO_PIN,
    /* rgbLedGrb */ false,
    /* backlightFloorPermille */ 510,
};

/// Waveshare ESP32-P4-WIFI6-Touch-LCD-3.4C: the 4C's XC carrier with 3.4-inch
/// 800x800 round JD9365 glass. Same pins, backlight, touch bus and audio parts
/// as the 4C; Waveshare's BSP 3.0.1 selects it with
/// CONFIG_BSP_LCD_TYPE_800_800_3_4_INCH at the same lane rate, pixel clock
/// and porches. Detection tells it from the 4C only by the GT9271's stored
/// config resolution (800x800). Not yet run on 3.4C hardware.
static const Config CONFIG_P4_34C = {
    Variant::P4_34C,
    "ESP32-P4-WIFI6-Touch-LCD-3.4C (JD9365)",
    &PLATFORM_ESP32_P4,
    &PANEL_JD9365_800X800,
    /* sclk  */ NO_PIN,
    /* mosi  */ NO_PIN,
    /* data1 */ NO_PIN,
    /* data2 */ NO_PIN,
    /* data3 */ NO_PIN,
    /* cs    */ NO_PIN,
    /* dc    */ NO_PIN,
    /* rst   */ 27,
    /* bl    */ 26,
    /* boot  */ 35,
    /* led   */ NO_PIN,
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
    /* serialRx */ NO_PIN,
    /* serialTx */ NO_PIN,
    /* panelPower */ NO_PIN,
    /* encoderA */ NO_PIN,
    /* encoderB */ NO_PIN,
    /* rgbLedGrb */ false,
    /* backlightFloorPermille */ 510,
};

#include "generated_board_config_lookup.h"

/// The backlight wiring every carrier of one family shares, so it can be
/// driven off before the carrier is known. `valid` is false when the family
/// has no carrier, or when any two of its carriers wire the backlight
/// differently: then nothing may be driven.
struct UnresolvedBacklight {
  bool valid;
  int8_t pinBl;
  int8_t pinBlEnable;
  bool inverted;
};

inline UnresolvedBacklight unresolvedBacklight(Platform platform) {
  UnresolvedBacklight result = {false, NO_PIN, NO_PIN, false};
  bool first = true;
  for (const auto &identity : GENERATED_BOARD_IDENTITIES) {
    if (identity.platform != platform) continue;
    const Config *config = generatedConfigFor(identity.variant);
    if (config == nullptr || config->pinBl == NO_PIN) {
      return {false, NO_PIN, NO_PIN, false};
    }
    if (first) {
      result = {true, config->pinBl, config->pinBlEnable,
                config->backlightInverted};
      first = false;
    } else if (config->pinBl != result.pinBl ||
               config->pinBlEnable != result.pinBlEnable ||
               config->backlightInverted != result.inverted) {
      return {false, NO_PIN, NO_PIN, false};
    }
  }
  return result;
}

/// "profile|profile|...|auto" for one family, in catalog order, for the
/// CFGBOARD error hint. False (and an empty string) when it does not fit.
inline bool formatProfileHint(Platform platform, char *out, size_t capacity) {
  if (out == nullptr || capacity == 0) return false;
  out[0] = 0;
  size_t used = 0;
  auto append = [&](const char *text) {
    const size_t length = strlen(text);
    const size_t separator = used != 0 ? 1 : 0;
    if (used + separator + length + 1 > capacity) return false;
    if (separator) out[used++] = '|';
    memcpy(out + used, text, length);
    used += length;
    out[used] = 0;
    return true;
  };
  for (const auto &identity : GENERATED_BOARD_IDENTITIES_BY_CATALOG) {
    if (identity.platform != platform) continue;
    if (!append(identity.profile)) {
      out[0] = 0;
      return false;
    }
  }
  if (!append("auto")) {
    out[0] = 0;
    return false;
  }
  return true;
}

/// Whether a physical profile belongs to a platform family. This is used both
/// for CFGBOARD recovery overrides and for detection results, so neither path
/// can make a family artifact drive another chip family's pin map.
inline bool variantMatchesPlatform(Variant variant, Platform platform) {
  const GeneratedBoardIdentity *identity = generatedIdentity(variant);
  return identity != nullptr && identity->platform == platform;
}

struct DetectionResult {
  Variant variant;
  uint8_t matchedCandidates;
};

inline DetectionResult detectFromEvidence(
    Platform platform, uint32_t flashBytes,
    const boarddetectmodel::ProbeEvidence *evidence, size_t evidenceCount,
    const boarddetectmodel::SenseEvidence *senses = nullptr,
    size_t senseCount = 0,
    const boarddetectmodel::PanelIdEvidence *panelId = nullptr,
    const boarddetectmodel::TouchConfigEvidence *touchConfig = nullptr) {
  const boarddetectmodel::Evaluation result = boarddetectmodel::evaluate(
      detectionPlanForPlatform(platform), flashBytes, evidence, evidenceCount,
      senses, senseCount, panelId, touchConfig);
  return {(Variant)result.variantValue, result.matchedCandidates};
}

/// Resolve the S3 detector's independent profile signals. On 8 MiB flash an
/// answer from the 0.85's codec bus is the GC9107 carrier and silence there is
/// the XIAO's ST7735 (`codec085Bus`); each larger-flash profile has a distinct I2C
/// bus (the T-Watch-S3's is GPIO10/11, `twatchBus`), except that the 1.3-inch and 1.9-inch carriers share GPIO47/48 and are
/// separated by the GPIO4 sense: the 1.9's system-rail divider versus the
/// 1.3's bare header pin. A negative gpio4Millivolts means no reading. Exactly
/// one candidate is required. No match and conflicting matches both remain
/// Unknown so setup can stay serial-only until CFGBOARD supplies an explicit
/// recovery override.
inline Variant variantFromS3Probe(uint32_t flashBytes, bool co5300Bus,
                                  bool st77916Bus, bool st7789Bus,
                                  bool qmi8658Bus47_48,
                                  bool knob128Bus = false,
                                  int gpio4Millivolts = -1,
                                  bool codec085Bus = true,
                                  bool twatchBus = false) {
  // Generated probe order: the 0.85's 8 MiB codec bus first, then the 1.85C
  // bus before the 1.75C's, because the 1.75C's SDA is the 1.85C V2's
  // amplifier enable, then the T-Watch-S3's main bus, after both buses it
  // shares pins with. The answers go through the same probe loop the device
  // runs, so its skip rules apply here too.
  const bool answers[] = {codec085Bus, st77916Bus, co5300Bus, twatchBus,
                          st7789Bus, qmi8658Bus47_48, knob128Bus};
  const auto &plan = detectionPlanForPlatform(Platform::Esp32S3);
  boarddetectmodel::ProbeEvidence evidence[GENERATED_MAX_PROBE_COUNT] = {};
  boarddetectmodel::runI2cProbes(
      plan, flashBytes, evidence,
      [&](uint8_t i) {
        return boarddetectmodel::ProbeEvidence{
            boarddetectmodel::ProbeStatus::Started,
            (uint8_t)(i < sizeof(answers) && answers[i] ? 1 : 0)};
      },
      [](uint8_t) {});
  const boarddetectmodel::SenseEvidence sense = {
      gpio4Millivolts >= 0,
      (uint16_t)(gpio4Millivolts < 0 ? 0 : gpio4Millivolts)};
  return detectFromEvidence(
             Platform::Esp32S3, flashBytes, evidence, plan.probeCount, &sense,
             1)
      .variant;
}

/// Resolve the P4 carrier from its three passive signals: the ID its MIPI-DSI
/// panel returned to a DCS 0x04 read (`idRead` false when the read failed or
/// timed out), GPIO52 read against the internal pull-down (`gpio52Level` -1
/// when unread), and the resolution stored in the GT touch controller's
/// config (`touchRead` false when no controller answered). The 4B needs its
/// ST7703's 38 21 1F and a high GPIO52 (its PHY's 1.5K MDIO pull-up). The XC
/// carrier needs its JD9365's 93 65 04 and a low GPIO52 (a floating header
/// pin), and then the touch config tells its glass apart: 720x720 is the 4C,
/// 800x800 the 3.4C. Every other combination stays Unknown.
inline Variant variantFromP4Evidence(bool idRead, const uint8_t *id,
                                     int gpio52Level, bool touchRead,
                                     uint16_t touchWidth,
                                     uint16_t touchHeight) {
  const boarddetectmodel::PanelIdEvidence evidence =
      boarddetectmodel::panelIdEvidenceFromRead(idRead, id);
  const boarddetectmodel::SenseEvidence sense = {
      gpio52Level >= 0, (uint16_t)(gpio52Level > 0 ? 3300 : 0)};
  boarddetectmodel::TouchConfigEvidence touch;
  touch.read = touchRead;
  touch.width = touchWidth;
  touch.height = touchHeight;
  return detectFromEvidence(Platform::Esp32P4, 32u * 1024u * 1024u, nullptr,
                            0, &sense, 1, &evidence, &touch)
      .variant;
}

/// Map a possibly-Unknown C6 variant onto the electrically safer C6 profile.
///
/// Unknown resolves to the C6 Touch board on purpose; it can only arise on the
/// C6 when this fallback is used; unresolved S3 detection is handled as
/// serial-only recovery before configFor(). Both C6 misdetections leave the
/// panel dark, because the SPI pins differ - but they are not equally
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
  const Config *config = generatedConfigFor(resolve(variant));
  return config == nullptr ? CONFIG_TOUCH_JD9853 : *config;
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
  const boarddetectmodel::ProbeEvidence evidence = {
      probeSucceeded ? boarddetectmodel::ProbeStatus::Started
                     : boarddetectmodel::ProbeStatus::StartFailed,
      (uint8_t)(deviceCount > 255 ? 255 : (deviceCount < 0 ? 0 : deviceCount)),
  };
  return detectFromEvidence(
             Platform::Esp32C6, 8u * 1024u * 1024u, &evidence, 1)
      .variant;
}

/// Parse a variant previously cached in NVS.
///
/// Returns Unknown for anything unrecognised (never written, or written by a
/// future firmware with more variants) so the caller re-probes instead of
/// trusting a value it cannot interpret.
inline Variant variantFromStored(uint8_t raw) {
  const Variant variant = (Variant)raw;
  return generatedIdentity(variant) == nullptr ? Variant::Unknown : variant;
}

/// Parse an operator override (CFGBOARD over USB serial).
///
/// Exact tokens only. "auto" - and anything unrecognised - maps to Unknown,
/// which is the caller's cue to clear the cache and re-probe rather than pin
/// the board to a guess.
inline Variant variantFromName(const char *token) {
  if (token == nullptr) return Variant::Unknown;
  for (const auto &identity : GENERATED_BOARD_IDENTITIES) {
    if (strcmp(token, identity.profile) == 0) return identity.variant;
  }
  return Variant::Unknown;
}

/// Short stable token for a variant, for CFGSHOW/telemetry and NVS debugging.
inline const char *variantToken(Variant variant) {
  const GeneratedBoardIdentity *identity = generatedIdentity(variant);
  return identity == nullptr ? "auto" : identity->profile;
}

/// Stable user-facing firmware family, distinct from the physical profile.
inline const char *targetToken(Variant variant) {
  const GeneratedBoardIdentity *identity = generatedIdentity(variant);
  return identity == nullptr ? "unknown" : identity->target;
}

}  // namespace board
