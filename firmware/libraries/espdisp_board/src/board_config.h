// Which supported board this binary is running on, and every board fact that
// follows from that.
//
// Three boards are supported, across two chips:
//
//   ESP32-C6-LCD-1.47          ST7789 172x320 over SPI, addressable RGB LED on
//                              GPIO8, BOOT on GPIO9
//   ESP32-C6-Touch-LCD-1.47    JD9853 172x320 over SPI, no addressable LED,
//                              BOOT on GPIO9, AXS5106L touch + QMI8658A IMU on
//                              I2C GPIO18/19
//   ESP32-S3-Touch-AMOLED-1.75C  CO5300 466x466 AMOLED over QSPI, CST9217
//                              touch on I2C GPIO15/14, AXP2101 PMU, QMI8658
//                              IMU
//
// The two C6 boards share one binary: same chip, same resolution, different
// panel controller and pin map, so the variant is detected at boot and the
// pins read out of this table. The S3 board is necessarily its own compile
// (different chip), so its variant is pinned at compile time via
// COMPILED_VARIANT and none of the probe machinery runs there.
//
// Unlike the original two-board design, resolution is now a per-board fact:
// the sketch derives its frame geometry (bandproto::Geometry) from panelW and
// panelH here instead of a project-wide constant.
//
// This header is deliberately hardware-free (pure data plus arithmetic) so it
// is unit tested on the host alongside band_protocol.h and panel_state.h. The
// I2C probe that feeds detectVariant lives in the sketch, because it needs Wire.
#pragma once

#include <stdint.h>
#include <string.h>

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
};

/// Which panel controller to construct. The ESP32 Arduino core ships an
/// esp_lcd ST7789 driver; the JD9853 and CO5300 ones are vendored in
/// firmware/libraries.
enum class PanelDriver : uint8_t { St7789, Jd9853, Co5300 };

/// How the panel is wired to the chip. SPI is single-lane with a D/C line;
/// QSPI is four data lanes with the command/data distinction encoded in a
/// 32-bit command envelope instead of a pin.
enum class PanelBus : uint8_t { Spi, Qspi };

/// Which capacitive touch controller the board carries, so the sketch knows
/// which register protocol to speak. The pins alone cannot tell these apart.
enum class TouchController : uint8_t { None, Axs5106l, Cst9217 };

/// Which power-management IC the board carries, so the sketch knows whether a
/// battery reading is even possible and which register protocol to speak.
///
/// Only the 1.75C has one. The two C6 boards run straight off USB with no cell
/// and no gauge, which is why battery reporting is a per-board capability here
/// rather than a firmware-wide one.
enum class PowerController : uint8_t { None, Axp2101 };

/// The variant this binary serves, when the compile target admits exactly one.
/// The C6 binary serves two boards, so there it is Unknown and the boot-time
/// I2C probe decides. The S3 binary serves only the AMOLED board; probing
/// would be pointless and the C6 probe pins mean nothing on that chip.
#if defined(CONFIG_IDF_TARGET_ESP32S3)
static const Variant COMPILED_VARIANT = Variant::AmoledCo5300;
#else
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

/// Everything that differs between the boards. The sketch reads this and holds
/// no board conditionals of its own, so adding a variant is a new table entry
/// rather than a hunt for scattered `if (touch)` branches.
struct Config {
  Variant variant;
  const char *name;
  PanelDriver driver;
  PanelBus bus;

  /// Panel resolution in native (portrait) orientation. Everything above the
  /// panel - buffer sizing, band geometry, the mDNS res record - derives from
  /// these two numbers.
  uint16_t panelW;
  uint16_t panelH;

  /// Pixel clock. 80MHz single-lane on the C6 LCDs (what both Waveshare BSPs
  /// use); 40MHz quad on the CO5300 (what Espressif's driver macro and
  /// Waveshare's demo use - 4 lanes at 40MHz still doubles the single-lane
  /// byte rate).
  uint32_t pclkHz;

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
  // Waveshare's docs describe; UNVERIFIED on real hardware as of this entry,
  // and the C6 history above is exactly why it must be measured before it is
  // trusted.
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
  // On the 1.75C, touch reset IS the panel reset (GPIO2, one shared line), so
  // resetting the panel resets the touch controller with it - the touch
  // bring-up there must come after panel reset, never pulse the line itself.
  TouchController touch;
  int8_t pinTouchSda;
  int8_t pinTouchScl;
  int8_t pinTouchRst;
  int8_t pinTouchInt;

  /// Power-management IC, or None. No pins of its own: on the one board that
  /// has a PMU it shares the touch I2C bus (pinTouchSda/pinTouchScl), which is
  /// what Waveshare's own pin_config.h and their AXP2101 example do. Recorded
  /// here rather than inferred from the variant so the reader can be gated on
  /// a fact in the table like every other per-board fact.
  PowerController power;

  /// Gap on the X axis inside the controller's RAM. The 1.47" panels are 172
  /// wide in a 240-wide controller, centred: 34. The 1.75C's CO5300 maps the
  /// 466px glass starting at column 6 (the offset Waveshare's own demo passes).
  uint8_t colOffset;

  /// Whether the panel needs INVON. True on both C6 boards (both are IPS),
  /// false on the AMOLED. Kept per-variant because it is a property of the
  /// panel, not of the project.
  bool invertColor;

  /// Round glass over a square framebuffer: the corners exist in memory but
  /// not on the panel. Content that must stay visible (the idle status card)
  /// has to keep inside the inscribed square.
  bool roundDisplay;

  bool hasRgbLed() const { return pinRgbLed != NO_PIN; }
  bool hasTouch() const {
    return touch != TouchController::None && pinTouchRst != NO_PIN &&
           pinTouchInt != NO_PIN;
  }
  /// Whether a battery reading is possible at all on this board. The bus pins
  /// are part of the test because the PMU is read over the touch I2C bus: a
  /// controller with nowhere to talk cannot be read, and claiming otherwise
  /// would make the firmware advertise a battery it can never sample.
  bool hasBattery() const {
    return power != PowerController::None && pinTouchSda != NO_PIN &&
           pinTouchScl != NO_PIN;
  }
  bool isQspi() const { return bus == PanelBus::Qspi; }
  /// Brightness sink: PWM duty on this pin, or panel command 0x51 when absent.
  bool hasBacklightPin() const { return pinBl != NO_PIN; }
};

/// ESP32-C6-LCD-1.47: ST7789, addressable LED, BOOT on GPIO9.
static const Config CONFIG_LCD_ST7789 = {
    Variant::LcdSt7789,
    "ESP32-C6-LCD-1.47 (ST7789)",
    PanelDriver::St7789,
    PanelBus::Spi,
    /* panelW */ 172,
    /* panelH */ 320,
    /* pclkHz */ 80 * 1000 * 1000,
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
    PowerController::None,  // USB powered, no cell and no gauge
    /* colOffset   */ 34,
    /* invertColor */ true,
    /* roundDisplay */ false,
};

/// ESP32-C6-Touch-LCD-1.47: JD9853, no addressable LED, BOOT on GPIO9.
///
/// Pin map and panel settings follow Waveshare's own ESP-IDF BSP for this board
/// (80MHz pclk, RGB element order, INVON), which uses the same esp_lcd API this
/// firmware does.
static const Config CONFIG_TOUCH_JD9853 = {
    Variant::TouchJd9853,
    "ESP32-C6-Touch-LCD-1.47 (JD9853)",
    PanelDriver::Jd9853,
    PanelBus::Spi,
    /* panelW */ 172,
    /* panelH */ 320,
    /* pclkHz */ 80 * 1000 * 1000,
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
    PowerController::None,  // USB powered, no cell and no gauge
    /* colOffset   */ 34,
    /* invertColor */ true,
    /* roundDisplay */ false,
};

/// ESP32-S3-Touch-AMOLED-1.75C: CO5300 466x466 AMOLED over QSPI, CST9217
/// touch, AXP2101 PMU.
///
/// Pin map from Waveshare's pin_config.h in the board's engineering-sample
/// repository (examples/arduino/libraries/Mylibrary). Panel reset and touch
/// reset are one line (GPIO2). No D/C pin, no backlight pin: QSPI command
/// envelope and panel command 0x51 respectively. The column offset of 6 is
/// what Waveshare's own Arduino_CO5300 construction passes for this glass.
static const Config CONFIG_AMOLED_CO5300 = {
    Variant::AmoledCo5300,
    "ESP32-S3-Touch-AMOLED-1.75C (CO5300)",
    PanelDriver::Co5300,
    PanelBus::Qspi,
    /* panelW */ 466,
    /* panelH */ 466,
    /* pclkHz */ 40 * 1000 * 1000,
    /* sclk  */ 38,
    /* mosi  */ 4,  // SDIO0
    /* data1 */ 5,
    /* data2 */ 6,
    /* data3 */ 7,
    /* cs    */ 12,
    /* dc    */ NO_PIN,  // QSPI: no D/C line
    /* rst   */ 2,
    /* bl    */ NO_PIN,  // AMOLED: brightness is panel command 0x51
    // GPIO0, the S3's standard BOOT strapping pin. UNVERIFIED on hardware -
    // see the measurement note above the struct before trusting it.
    /* boot  */ 0,
    /* led   */ NO_PIN,
    TouchController::Cst9217,
    /* touchSda */ 15,
    /* touchScl */ 14,
    /* touchRst */ 2,  // shared with panel reset - never pulse independently
    /* touchInt */ 11,
    // AXP2101 PMU at 0x34 on the touch bus above (GPIO15/14). The only board
    // here with a battery, so the only one that reports one.
    PowerController::Axp2101,
    /* colOffset   */ 6,
    /* invertColor */ false,
    /* roundDisplay */ true,
};

/// Map a possibly-Unknown variant onto one that is safe to run.
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
    default:
      return "auto";
  }
}

}  // namespace board
