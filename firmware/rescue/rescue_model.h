// Hardware-free half of the rescue image: which pins it may drive, and what it
// draws. Host tested by firmware/test/test_rescue_model.cpp.
#pragma once

#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include <board_config.h>

namespace rescuemodel {

// ---- Pins ---------------------------------------------------------------

/// The USB Serial/JTAG pads (USB_INT_PHY0 D-/D+) of each chip. The rescue image
/// exists because firmware drove these on a board whose USB they carry, so it
/// never drives them on any board, including carriers that route them
/// elsewhere (the S3 1.3's LED and backlight): it cannot tell a correct
/// detection from the misdetection it is rescuing.
struct UsbPins {
  int8_t dm;
  int8_t dp;
};

constexpr UsbPins usbPinsFor(board::Platform platform) {
  return platform == board::Platform::Esp32C3   ? UsbPins{18, 19}
         : platform == board::Platform::Esp32C6 ? UsbPins{12, 13}
         : platform == board::Platform::Esp32S3 ? UsbPins{19, 20}
                                                : UsbPins{24, 25};
}

constexpr bool isUsbPin(board::Platform platform, int8_t pin) {
  return pin != board::NO_PIN &&
         (pin == usbPinsFor(platform).dm || pin == usbPinsFor(platform).dp);
}

/// What the rescue image may drive on one detected board. The first USB pin
/// found is reported so the serial log can say why something stayed off.
struct PinPlan {
  bool panel;      // bus, control, reset, rail and expander lines
  bool backlight;  // PWM backlight pin (non-DSI panels)
  bool uartBridge; // the carrier's USB-UART bridge pins
  int8_t blockedPin;
};

inline PinPlan planPins(const board::Config &cfg) {
  const board::Platform platform = cfg.platform->platform;
  int8_t blocked = board::NO_PIN;
  auto clear = [&](const int8_t *pins, size_t count) {
    for (size_t i = 0; i < count; ++i) {
      if (isUsbPin(platform, pins[i])) {
        if (blocked == board::NO_PIN) blocked = pins[i];
        return false;
      }
    }
    return true;
  };
  const bool expander = cfg.hasExpanderReset();
  const bool dsi = cfg.isDsi();
  // The DSI backend configures its backlight PWM and enable line inside panel
  // bring-up, so on DSI they are panel pins.
  const int8_t panelPins[] = {
      cfg.pinPanelPower, cfg.pinSclk, cfg.pinMosi, cfg.pinData1,
      cfg.pinData2, cfg.pinData3, cfg.pinCs, cfg.pinDc, cfg.pinRst,
      expander ? cfg.pinTouchSda : board::NO_PIN,
      expander ? cfg.pinTouchScl : board::NO_PIN,
      dsi ? cfg.pinBl : board::NO_PIN,
      dsi ? cfg.pinBlEnable : board::NO_PIN,
  };
  const int8_t backlightPins[] = {dsi ? board::NO_PIN : cfg.pinBl};
  const int8_t bridgePins[] = {cfg.pinSerialRx, cfg.pinSerialTx};
  PinPlan plan;
  plan.panel = clear(panelPins, sizeof(panelPins) / sizeof(panelPins[0]));
  plan.backlight = plan.panel && clear(backlightPins, 1);
  plan.uartBridge =
      cfg.serialTransport() == board::SerialTransport::UartBridge &&
      clear(bridgePins, 2);
  plan.blockedPin = blocked;
  return plan;
}

/// The Config pin fields each part of the plan covers, by name. The host test
/// scans the bring-up sources for every `cfg.pin*` / `cfg->pin*` they use and
/// requires it to appear here, so a new bring-up pin cannot bypass the guard.
static const char *const PANEL_PIN_FIELDS[] = {
    "pinPanelPower", "pinSclk", "pinMosi", "pinData1", "pinData2",
    "pinData3", "pinCs", "pinDc", "pinRst", "pinTouchSda", "pinTouchScl",
    "pinBl", "pinBlEnable",
};
static const char *const BACKLIGHT_PIN_FIELDS[] = {"pinBl"};
static const char *const BRIDGE_PIN_FIELDS[] = {"pinSerialRx", "pinSerialTx"};

// ---- Stored CFGBOARD override -------------------------------------------

/// The profile a stored CFGBOARD value (NVS "espdisp"/"board") would force on
/// the stream firmware of this family, or nullptr when it forces nothing.
/// Mirrors display_stream's setup(): a fixed-variant family ignores the key,
/// and an unknown or cross-family value falls through to detection. The
/// rescue image itself never applies it; it only reports it, because the
/// real firmware flashed next would.
inline const char *effectiveOverride(uint8_t stored, board::Platform platform,
                                     board::Variant compiledVariant) {
  if (compiledVariant != board::Variant::Unknown) return nullptr;
  const board::Variant forced = board::variantFromStored(stored);
  if (forced == board::Variant::Unknown ||
      !board::variantMatchesPlatform(forced, platform)) {
    return nullptr;
  }
  return board::variantToken(forced);
}

// ---- Drawing ------------------------------------------------------------

static const uint16_t COLOR_BACKGROUND = 0x0000;
static const uint16_t COLOR_BORDER = 0xFD20;   // orange
static const uint16_t COLOR_TITLE = 0xFFFF;    // white
static const uint16_t COLOR_NAME = 0xFFE0;     // yellow
static const uint16_t COLOR_PROFILE = 0x07FF;  // cyan
static const uint16_t COLOR_WARNING = 0xF800;  // red

static const char TITLE[] = "RESCUE";
static const uint8_t MAX_NAME_LINES = 3;
static const uint8_t MAX_LINE_CHARS = 40;

// The glyphs the rescue screen can show, taken from the classic 5x7 font in
// display_stream/font5x7.h (Adafruit GFX, BSD license). Board names are drawn
// upper-cased, so this is the whole alphabet they need; anything else is '?'.
static const char GLYPH_CHARS[] = " ()-./0123456789:?ABCDEFGHIJKLMNOPQRSTUVWXYZ_";
static const uint8_t GLYPHS[][5] = {
    {0x00, 0x00, 0x00, 0x00, 0x00},  // ' '
    {0x00, 0x1C, 0x22, 0x41, 0x00},  // '('
    {0x00, 0x41, 0x22, 0x1C, 0x00},  // ')'
    {0x08, 0x08, 0x08, 0x08, 0x08},  // '-'
    {0x00, 0x00, 0x60, 0x60, 0x00},  // '.'
    {0x20, 0x10, 0x08, 0x04, 0x02},  // '/'
    {0x3E, 0x51, 0x49, 0x45, 0x3E},  // '0'
    {0x00, 0x42, 0x7F, 0x40, 0x00},  // '1'
    {0x72, 0x49, 0x49, 0x49, 0x46},  // '2'
    {0x21, 0x41, 0x49, 0x4D, 0x33},  // '3'
    {0x18, 0x14, 0x12, 0x7F, 0x10},  // '4'
    {0x27, 0x45, 0x45, 0x45, 0x39},  // '5'
    {0x3C, 0x4A, 0x49, 0x49, 0x31},  // '6'
    {0x41, 0x21, 0x11, 0x09, 0x07},  // '7'
    {0x36, 0x49, 0x49, 0x49, 0x36},  // '8'
    {0x46, 0x49, 0x49, 0x29, 0x1E},  // '9'
    {0x00, 0x00, 0x14, 0x00, 0x00},  // ':'
    {0x02, 0x01, 0x59, 0x09, 0x06},  // '?'
    {0x7C, 0x12, 0x11, 0x12, 0x7C},  // 'A'
    {0x7F, 0x49, 0x49, 0x49, 0x36},  // 'B'
    {0x3E, 0x41, 0x41, 0x41, 0x22},  // 'C'
    {0x7F, 0x41, 0x41, 0x41, 0x3E},  // 'D'
    {0x7F, 0x49, 0x49, 0x49, 0x41},  // 'E'
    {0x7F, 0x09, 0x09, 0x09, 0x01},  // 'F'
    {0x3E, 0x41, 0x41, 0x51, 0x73},  // 'G'
    {0x7F, 0x08, 0x08, 0x08, 0x7F},  // 'H'
    {0x00, 0x41, 0x7F, 0x41, 0x00},  // 'I'
    {0x20, 0x40, 0x41, 0x3F, 0x01},  // 'J'
    {0x7F, 0x08, 0x14, 0x22, 0x41},  // 'K'
    {0x7F, 0x40, 0x40, 0x40, 0x40},  // 'L'
    {0x7F, 0x02, 0x1C, 0x02, 0x7F},  // 'M'
    {0x7F, 0x04, 0x08, 0x10, 0x7F},  // 'N'
    {0x3E, 0x41, 0x41, 0x41, 0x3E},  // 'O'
    {0x7F, 0x09, 0x09, 0x09, 0x06},  // 'P'
    {0x3E, 0x41, 0x51, 0x21, 0x5E},  // 'Q'
    {0x7F, 0x09, 0x19, 0x29, 0x46},  // 'R'
    {0x26, 0x49, 0x49, 0x49, 0x32},  // 'S'
    {0x03, 0x01, 0x7F, 0x01, 0x03},  // 'T'
    {0x3F, 0x40, 0x40, 0x40, 0x3F},  // 'U'
    {0x1F, 0x20, 0x40, 0x20, 0x1F},  // 'V'
    {0x3F, 0x40, 0x38, 0x40, 0x3F},  // 'W'
    {0x63, 0x14, 0x08, 0x14, 0x63},  // 'X'
    {0x03, 0x04, 0x78, 0x04, 0x03},  // 'Y'
    {0x61, 0x59, 0x49, 0x4D, 0x43},  // 'Z'
    {0x40, 0x40, 0x40, 0x40, 0x40},  // '_'
};

inline const uint8_t *glyphFor(char c) {
  if (c >= 'a' && c <= 'z') c = (char)(c - 'a' + 'A');
  const char *at = c == 0 ? nullptr : strchr(GLYPH_CHARS, c);
  if (at == nullptr) at = strchr(GLYPH_CHARS, '?');
  return GLYPHS[at - GLYPH_CHARS];
}

/// Pixel width of a scaled string: 5 columns plus 1 of spacing per glyph,
/// less the trailing spacing.
constexpr int textWidth(size_t chars, int scale) {
  return chars == 0 ? 0 : (int)chars * 6 * scale - scale;
}

/// Word-wrap into at most MAX_NAME_LINES lines of perLine characters,
/// preferring spaces, then hyphens, then a hard break. Returns the line count,
/// or MAX_NAME_LINES + 1 when the text does not fit.
inline uint8_t wrap(const char *text, uint8_t perLine,
                    char lines[MAX_NAME_LINES][MAX_LINE_CHARS + 1]) {
  if (perLine == 0) return MAX_NAME_LINES + 1;
  if (perLine > MAX_LINE_CHARS) perLine = MAX_LINE_CHARS;
  uint8_t count = 0;
  const char *p = text;
  while (*p == ' ') ++p;
  while (*p != 0) {
    if (count == MAX_NAME_LINES) return MAX_NAME_LINES + 1;
    size_t remaining = strlen(p);
    size_t take = remaining;
    size_t next = remaining;
    if (remaining > perLine) {
      take = 0;
      for (size_t i = perLine; i > 0; --i) {
        if (p[i] == ' ') { take = i; next = i + 1; break; }
      }
      if (take == 0) {
        for (size_t i = perLine; i > 0; --i) {
          if (p[i - 1] == '-') { take = i; next = i; break; }
        }
      }
      if (take == 0) { take = perLine; next = perLine; }
    }
    while (take > 0 && p[take - 1] == ' ') --take;
    memcpy(lines[count], p, take);
    lines[count][take] = 0;
    ++count;
    p += next;
    while (*p == ' ') ++p;
  }
  return count;
}

struct Line {
  char text[MAX_LINE_CHARS + 1];
  uint16_t color;
  uint8_t scale;
  int x;
  int y;
};

/// The whole screen: a border (a ring on round glass), RESCUE, the board name
/// and the profile token, centred and scaled to the panel.
struct Screen {
  int width;
  int height;
  bool round;
  int border;
  uint8_t lineCount;
  Line lines[4 + MAX_NAME_LINES];
};

/// The content box: inside the border on rectangular glass; on round glass a
/// box whose corners stay inside the ring (0.70 x 0.60 of the diameter keeps
/// every corner under 0.93 of the inner radius).
inline void contentBox(int width, int height, bool round, int border,
                       int &boxW, int &boxH) {
  const int side = width < height ? width : height;
  const int margin = border + (side / 40 > 2 ? side / 40 : 2);
  if (round) {
    boxW = (side - 2 * border) * 70 / 100;
    boxH = (side - 2 * border) * 60 / 100;
  } else {
    boxW = width - 2 * margin;
    boxH = height - 2 * margin;
  }
}

/// `warning`, when set, is one extra red line under the profile token.
inline Screen layout(int width, int height, bool round, const char *name,
                     const char *profile, const char *warning = nullptr) {
  Screen screen = {};
  screen.width = width;
  screen.height = height;
  screen.round = round;
  const int side = width < height ? width : height;
  screen.border = side / 30 > 3 ? side / 30 : 3;
  int boxW = 0, boxH = 0;
  contentBox(width, height, round, screen.border, boxW, boxH);

  char nameLines[MAX_NAME_LINES][MAX_LINE_CHARS + 1] = {};
  int titleScale = boxW / textWidth(sizeof(TITLE) - 1, 1);
  if (titleScale < 1) titleScale = 1;
  for (; titleScale >= 1; --titleScale) {
    int nameScale = titleScale / 2 > 1 ? titleScale / 2 : 1;
    uint8_t nameCount = MAX_NAME_LINES + 1;
    for (; nameScale >= 1; --nameScale) {
      nameCount = wrap(name, (uint8_t)((boxW + nameScale) / (6 * nameScale)),
                       nameLines);
      if (nameCount <= MAX_NAME_LINES) break;
    }
    if (nameScale < 1) nameScale = 1;
    if (nameCount > MAX_NAME_LINES) continue;
    // The warning wraps like the name, onto at most two lines, at the name's
    // scale or, failing that, the smallest.
    char warningLines[MAX_NAME_LINES][MAX_LINE_CHARS + 1] = {};
    uint8_t warningCount = 0;
    int warningScale = nameScale;
    if (warning != nullptr) {
      for (warningScale = nameScale; warningScale >= 1; --warningScale) {
        warningCount = wrap(
            warning, (uint8_t)((boxW + warningScale) / (6 * warningScale)),
            warningLines);
        if (warningCount <= 2) break;
        if (warningScale == 1) return screen;  // nothing honest fits
      }
    }
    const int nameGap = 4 * nameScale;
    const int titleGap = 2 * titleScale > nameGap ? 2 * titleScale : nameGap;
    const int total =
        7 * titleScale + titleGap + nameCount * 8 * nameScale - nameScale +
        nameGap + 7 * nameScale +
        (warningCount == 0 ? 0
                           : nameGap + warningCount * 8 * warningScale -
                                 warningScale);
    if (total > boxH && titleScale > 1) continue;

    int y = (height - total) / 2;
    auto add = [&](const char *text, uint16_t color, int scale) {
      Line &line = screen.lines[screen.lineCount++];
      strncpy(line.text, text, MAX_LINE_CHARS);
      line.text[MAX_LINE_CHARS] = 0;
      line.color = color;
      line.scale = (uint8_t)scale;
      line.x = (width - textWidth(strlen(line.text), scale)) / 2;
      line.y = y;
    };
    add(TITLE, COLOR_TITLE, titleScale);
    y += 7 * titleScale + titleGap;
    for (uint8_t i = 0; i < nameCount; ++i) {
      add(nameLines[i], COLOR_NAME, nameScale);
      y += 8 * nameScale;
    }
    y += nameGap - nameScale;
    add(profile, COLOR_PROFILE, nameScale);
    y += 7 * nameScale + nameGap;
    for (uint8_t i = 0; i < warningCount; ++i) {
      add(warningLines[i], COLOR_WARNING, warningScale);
      y += 8 * warningScale;
    }
    return screen;
  }
  return screen;
}

inline bool onBorder(const Screen &screen, int x, int y) {
  if (!screen.round) {
    return x < screen.border || y < screen.border ||
           x >= screen.width - screen.border ||
           y >= screen.height - screen.border;
  }
  // Doubled coordinates keep the centre of an even-sized panel integral.
  const int side = screen.width < screen.height ? screen.width : screen.height;
  const long dx = 2L * x + 1 - screen.width;
  const long dy = 2L * y + 1 - screen.height;
  const long d2 = dx * dx + dy * dy;
  const long outer = (long)side * side;
  const long inner = (long)(side - 2 * screen.border) *
                     (side - 2 * screen.border);
  return d2 >= inner && d2 < outer;
}

/// Render rows [y0, y0 + rows) into an RGB565 big-endian buffer of
/// screen.width x rows, which is panel byte order.
inline void renderBand(const Screen &screen, int y0, int rows, uint8_t *out) {
  auto put = [&](int x, int y, uint16_t color) {
    const size_t at = ((size_t)(y - y0) * screen.width + x) * 2;
    out[at] = (uint8_t)(color >> 8);
    out[at + 1] = (uint8_t)(color & 0xFF);
  };
  for (int y = y0; y < y0 + rows; ++y) {
    for (int x = 0; x < screen.width; ++x) {
      put(x, y, onBorder(screen, x, y) ? COLOR_BORDER : COLOR_BACKGROUND);
    }
  }
  for (uint8_t i = 0; i < screen.lineCount; ++i) {
    const Line &line = screen.lines[i];
    const int s = line.scale;
    if (line.y + 7 * s <= y0 || line.y >= y0 + rows) continue;
    int x = line.x;
    for (const char *c = line.text; *c != 0; ++c, x += 6 * s) {
      const uint8_t *glyph = glyphFor(*c);
      for (int col = 0; col < 5; ++col) {
        for (int row = 0; row < 7; ++row) {
          if ((glyph[col] & (1 << row)) == 0) continue;
          for (int sy = 0; sy < s; ++sy) {
            const int py = line.y + row * s + sy;
            if (py < y0 || py >= y0 + rows || py >= screen.height) continue;
            for (int sx = 0; sx < s; ++sx) {
              const int px = x + col * s + sx;
              if (px >= 0 && px < screen.width) put(px, py, line.color);
            }
          }
        }
      }
    }
  }
}

}  // namespace rescuemodel
