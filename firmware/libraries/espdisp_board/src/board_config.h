// Which Waveshare 1.47" ESP32-C6 board this binary is running on, and every
// board fact that follows from that.
//
// Two boards share this form factor, the same ESP32-C6FH8, the same 8MB flash,
// and the same 172x320 panel resolution - but not the same panel controller or
// pin map:
//
//   ESP32-C6-LCD-1.47        ST7789, addressable RGB LED on GPIO8, BOOT on GPIO9
//   ESP32-C6-Touch-LCD-1.47  JD9853, no addressable LED, BOOT on GPIO8,
//                            AXS5106L touch + QMI8658A IMU on I2C GPIO18/19
//
// Because the resolution matches, everything above the panel - WiFi, mDNS, the
// band protocol, buffer sizing, the whole Mac side - is identical. Only the
// display half differs, so one binary can serve both boards: detect at boot,
// then read the pins and driver out of this table.
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

/// The two supported boards.
///
/// Unknown is the pre-detection state and the result of parsing a stored value
/// that no longer maps to a variant. It is never a usable configuration - see
/// resolve().
enum class Variant : uint8_t {
  Unknown = 0,
  LcdSt7789 = 1,    // ESP32-C6-LCD-1.47 (non-touch)
  TouchJd9853 = 2,  // ESP32-C6-Touch-LCD-1.47
};

/// Which panel controller to construct. The ESP32 Arduino core ships an
/// esp_lcd ST7789 driver; the JD9853 one is vendored in firmware/libraries.
enum class PanelDriver : uint8_t { St7789, Jd9853 };

/// The shared I2C bus that detection probes. Same pins on both boards; only the
/// Touch variant has anything answering on it.
static const int8_t PIN_PROBE_SDA = 18;
static const int8_t PIN_PROBE_SCL = 19;
/// Touch controller reset. Released before probing so a touch chip held in
/// reset cannot make a Touch board look like a non-touch one.
static const int8_t PIN_PROBE_TP_RST = 20;

/// Everything that differs between the boards. The sketch reads this and holds
/// no board conditionals of its own, so adding a third variant is a new table
/// entry rather than a hunt for scattered `if (touch)` branches.
struct Config {
  Variant variant;
  const char *name;
  PanelDriver driver;

  // Panel SPI + control pins.
  int8_t pinSclk;
  int8_t pinMosi;
  int8_t pinCs;
  int8_t pinDc;
  int8_t pinRst;
  int8_t pinBl;

  // BOOT button: short press toggles backlight, long press flips 180.
  int8_t pinBootButton;

  // Addressable WS2812-style LED, or NO_PIN. This is not cosmetic bookkeeping:
  // on the Touch board GPIO8 - where the non-touch board's LED lives - is the
  // BOOT button, wired to ground through the switch. Driving it as a LED output
  // there means a pressed button shorts a driven-high pad.
  int8_t pinRgbLed;

  /// Gap on the 172px axis: the panel is 172 wide in a 240-wide controller RAM,
  /// centred, on both boards.
  uint8_t colOffset;

  /// Whether the panel needs INVON. True on both boards (both are IPS), kept
  /// per-variant because it is a property of the panel, not of the project.
  bool invertColor;

  bool hasRgbLed() const { return pinRgbLed != NO_PIN; }
};

/// ESP32-C6-LCD-1.47: ST7789, addressable LED, BOOT on GPIO9.
static const Config CONFIG_LCD_ST7789 = {
    Variant::LcdSt7789,
    "ESP32-C6-LCD-1.47 (ST7789)",
    PanelDriver::St7789,
    /* sclk */ 7,
    /* mosi */ 6,
    /* cs   */ 14,
    /* dc   */ 15,
    /* rst  */ 21,
    /* bl   */ 22,
    /* boot */ 9,
    /* led  */ 8,
    /* colOffset   */ 34,
    /* invertColor */ true,
};

/// ESP32-C6-Touch-LCD-1.47: JD9853, no addressable LED, BOOT on GPIO8.
///
/// Pin map and panel settings follow Waveshare's own ESP-IDF BSP for this board
/// (80MHz pclk, RGB element order, INVON), which uses the same esp_lcd API this
/// firmware does.
static const Config CONFIG_TOUCH_JD9853 = {
    Variant::TouchJd9853,
    "ESP32-C6-Touch-LCD-1.47 (JD9853)",
    PanelDriver::Jd9853,
    /* sclk */ 1,
    /* mosi */ 2,
    /* cs   */ 14,
    /* dc   */ 15,
    /* rst  */ 22,
    /* bl   */ 23,
    /* boot */ 8,
    /* led  */ NO_PIN,
    /* colOffset   */ 34,
    /* invertColor */ true,
};

/// Map a possibly-Unknown variant onto one that is safe to run.
///
/// Unknown resolves to the Touch board on purpose. The two misdetections are
/// not symmetric:
///
///   Touch board treated as non-touch  -> GPIO8 driven as a LED output, but
///       GPIO8 is that board's BOOT button, switched to ground. Pressing it
///       shorts a driven pad. GPIO6/GPIO21 also become outputs contending with
///       the IMU interrupt and touch interrupt lines.
///   Non-touch board treated as Touch  -> the SPI pins are wrong, so the panel
///       is simply never written. A dark screen, no electrical stress.
///
/// A dark screen is recoverable and diagnosable over USB; a shorted pad is not.
/// So an inconclusive probe must land on Touch, even though that inverts the
/// historical default of this firmware.
inline Variant resolve(Variant variant) {
  return variant == Variant::Unknown ? Variant::TouchJd9853 : variant;
}

/// The board table for a variant. Unknown resolves per resolve().
inline const Config &configFor(Variant variant) {
  return resolve(variant) == Variant::LcdSt7789 ? CONFIG_LCD_ST7789
                                                : CONFIG_TOUCH_JD9853;
}

/// Decide the variant from an I2C scan of PIN_PROBE_SDA/SCL.
///
/// The Touch board carries an AXS5106L touch controller and a QMI8658A IMU on
/// that bus (observed at 0x63 and 0x6B); the non-touch board has nothing there.
/// So "anything answered" is the discriminator.
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
  return Variant::Unknown;
}

/// Short stable token for a variant, for CFGSHOW/telemetry and NVS debugging.
inline const char *variantToken(Variant variant) {
  switch (variant) {
    case Variant::LcdSt7789:
      return "st7789";
    case Variant::TouchJd9853:
      return "jd9853";
    default:
      return "auto";
  }
}

}  // namespace board
