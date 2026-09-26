// Host tests for the rescue image's pin guard and screen layout
// (firmware/rescue/rescue_model.h).
#include <cstdio>
#include <cstring>
#include <fstream>
#include <set>
#include <string>
#include <vector>

#include "../rescue/rescue_model.h"

static int checks = 0;
#define CHECK(cond)                                          \
  do {                                                       \
    checks++;                                                \
    if (!(cond)) {                                           \
      printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
      return 1;                                              \
    }                                                        \
  } while (0)

using board::Platform;

static std::string sourceText(const char *relative) {
  std::string here = __FILE__;
  const size_t slash = here.find_last_of('/');
  const std::string dir = slash == std::string::npos ? "." : here.substr(0, slash);
  std::ifstream input(dir + "/" + relative);
  return std::string(std::istreambuf_iterator<char>(input),
                     std::istreambuf_iterator<char>());
}

// Every Config pin field a source file reads as `.pinX` or `->pinX`.
static std::set<std::string> pinFieldsUsed(const std::string &text) {
  std::set<std::string> fields;
  for (size_t at = text.find("pin"); at != std::string::npos;
       at = text.find("pin", at + 3)) {
    const bool member = (at >= 1 && text[at - 1] == '.') ||
                        (at >= 2 && text.compare(at - 2, 2, "->") == 0);
    if (!member || at + 3 >= text.size() || text[at + 3] < 'A' ||
        text[at + 3] > 'Z') {
      continue;
    }
    size_t end = at + 3;
    while (end < text.size() &&
           (isalnum((unsigned char)text[end]) || text[end] == '_')) {
      ++end;
    }
    fields.insert(text.substr(at, end - at));
  }
  return fields;
}

template <size_t N>
static bool listed(const char *const (&names)[N], const std::string &field) {
  for (const char *name : names) {
    if (field == name) return true;
  }
  return false;
}

struct PinField {
  const char *name;
  int8_t board::Config::*member;
};
static const PinField PIN_FIELDS[] = {
    {"pinPanelPower", &board::Config::pinPanelPower},
    {"pinSclk", &board::Config::pinSclk},
    {"pinMosi", &board::Config::pinMosi},
    {"pinData1", &board::Config::pinData1},
    {"pinData2", &board::Config::pinData2},
    {"pinData3", &board::Config::pinData3},
    {"pinCs", &board::Config::pinCs},
    {"pinDc", &board::Config::pinDc},
    {"pinRst", &board::Config::pinRst},
    {"pinTouchSda", &board::Config::pinTouchSda},
    {"pinTouchScl", &board::Config::pinTouchScl},
    {"pinBl", &board::Config::pinBl},
    {"pinBlEnable", &board::Config::pinBlEnable},
    {"pinSerialRx", &board::Config::pinSerialRx},
    {"pinSerialTx", &board::Config::pinSerialTx},
};

static int8_t PinField_lookup(const board::Config &cfg, const char *name) {
  for (const auto &field : PIN_FIELDS) {
    if (strcmp(field.name, name) == 0) return cfg.*field.member;
  }
  return -2;
}

static bool insideBox(const rescuemodel::Screen &screen,
                      const rescuemodel::Line &line) {
  const int w = rescuemodel::textWidth(strlen(line.text), line.scale);
  const int h = 7 * line.scale;
  const int corners[4][2] = {{line.x, line.y},
                             {line.x + w - 1, line.y},
                             {line.x, line.y + h - 1},
                             {line.x + w - 1, line.y + h - 1}};
  for (const auto &corner : corners) {
    const int x = corner[0], y = corner[1];
    if (x < screen.border || y < screen.border ||
        x >= screen.width - screen.border ||
        y >= screen.height - screen.border) {
      return false;
    }
    if (screen.round && rescuemodel::onBorder(screen, x, y)) return false;
    if (screen.round) {
      const int side = screen.width < screen.height ? screen.width
                                                    : screen.height;
      const long dx = 2L * x + 1 - screen.width;
      const long dy = 2L * y + 1 - screen.height;
      const long inner = (long)(side - 2 * screen.border);
      if (dx * dx + dy * dy >= inner * inner) return false;
    }
  }
  return true;
}

int main() {
  // --- Detection runs before any guard, so it must never touch USB pins ---
  {
    const Platform platforms[] = {Platform::Esp32C3, Platform::Esp32C6,
                                  Platform::Esp32S3, Platform::Esp32P4};
    for (Platform platform : platforms) {
      const auto &plan = board::detectionPlanForPlatform(platform);
      for (uint8_t i = 0; i < plan.probeCount; ++i) {
        CHECK(!rescuemodel::isUsbPin(platform, plan.probes[i].sda));
        CHECK(!rescuemodel::isUsbPin(platform, plan.probes[i].scl));
        CHECK(!rescuemodel::isUsbPin(platform, plan.probes[i].resetPin));
      }
      for (uint8_t i = 0; i < plan.senseCount; ++i) {
        CHECK(!rescuemodel::isUsbPin(platform, plan.sensePins[i]));
      }
    }
    CHECK(rescuemodel::isUsbPin(Platform::Esp32S3, 19));
    CHECK(rescuemodel::isUsbPin(Platform::Esp32S3, 20));
    CHECK(rescuemodel::isUsbPin(Platform::Esp32C6, 12));
    CHECK(rescuemodel::isUsbPin(Platform::Esp32C6, 13));
    CHECK(rescuemodel::isUsbPin(Platform::Esp32C3, 18));
    CHECK(rescuemodel::isUsbPin(Platform::Esp32C3, 19));
    CHECK(rescuemodel::isUsbPin(Platform::Esp32P4, 24));
    CHECK(rescuemodel::isUsbPin(Platform::Esp32P4, 25));
    CHECK(!rescuemodel::isUsbPin(Platform::Esp32S3, board::NO_PIN));
    CHECK(!rescuemodel::isUsbPin(Platform::Esp32C6, 19));
  }

  // --- Pin plan for every supported board ---------------------------------
  {
    int profiles = 0;
    for (const auto &identity : board::GENERATED_BOARD_IDENTITIES) {
      const board::Config &cfg = board::configFor(identity.variant);
      CHECK(cfg.variant == identity.variant);
      const rescuemodel::PinPlan plan = rescuemodel::planPins(cfg);
      CHECK(plan.panel);
      if (identity.variant == board::Variant::LcdSt7789_130) {
        // Its LED and backlight sit on the S3's USB pads.
        CHECK(!plan.backlight);
        CHECK(plan.blockedPin == 20);
        CHECK(plan.uartBridge);
      } else {
        CHECK(plan.backlight);
        CHECK(plan.blockedPin == board::NO_PIN);
      }
      ++profiles;
    }
    CHECK(profiles == 11);

    board::Config onUsb = board::CONFIG_TOUCH_ST7789;
    onUsb.pinSclk = 19;
    rescuemodel::PinPlan plan = rescuemodel::planPins(onUsb);
    CHECK(!plan.panel);
    CHECK(!plan.backlight);
    CHECK(plan.blockedPin == 19);

    board::Config rail = board::CONFIG_ELECROW_KNOB_128;
    rail.pinPanelPower = 20;
    CHECK(!rescuemodel::planPins(rail).panel);

    board::Config bridge = board::CONFIG_LCD_ST7789_130;
    bridge.pinSerialTx = 19;
    CHECK(!rescuemodel::planPins(bridge).uartBridge);
  }

  // --- The guard covers every pin bring-up drives ---------------------------
  {
    // What the shared bring-up and the rescue sketch actually read, straight
    // from their sources: a new pin there that the plan does not list fails.
    const char *const sources[] = {
        "../libraries/espdisp_board/src/panel_init.h",
        "../libraries/espdisp_board/src/panel_init_dsi.h",
        "../libraries/espdisp_board/src/board_io.h",
        "../libraries/espdisp_board/src/display_backend.h",
        "../rescue/rescue.ino",
    };
    size_t seen = 0;
    for (const char *source : sources) {
      const std::string text = sourceText(source);
      CHECK(!text.empty());
      for (const std::string &field : pinFieldsUsed(text)) {
        ++seen;
        const bool covered = listed(rescuemodel::PANEL_PIN_FIELDS, field) ||
                             listed(rescuemodel::BACKLIGHT_PIN_FIELDS, field) ||
                             listed(rescuemodel::BRIDGE_PIN_FIELDS, field);
        if (!covered) printf("  %s drives %s, which planPins does not check\n",
                             source, field.c_str());
        CHECK(covered);
      }
    }
    CHECK(seen >= 15);

    // And each listed field really gates its part of the plan.
    for (const char *name : rescuemodel::PANEL_PIN_FIELDS) {
      const bool dsiOnly = strcmp(name, "pinBl") == 0 ||
                           strcmp(name, "pinBlEnable") == 0;
      const bool expanderOnly = strcmp(name, "pinTouchSda") == 0 ||
                                strcmp(name, "pinTouchScl") == 0;
      board::Config cfg = dsiOnly ? board::CONFIG_P4_4B
                          : expanderOnly ? board::CONFIG_LCD_ST77916
                                         : board::CONFIG_TOUCH_ST7789;
      CHECK(PinField_lookup(cfg, name) != -2);
      for (const auto &field : PIN_FIELDS) {
        if (strcmp(field.name, name) == 0) {
          cfg.*field.member = rescuemodel::usbPinsFor(cfg.platform->platform).dp;
        }
      }
      if (rescuemodel::planPins(cfg).panel) {
        printf("  %s on a USB pin did not block the panel\n", name);
      }
      CHECK(!rescuemodel::planPins(cfg).panel);
    }
    board::Config lit = board::CONFIG_TOUCH_ST7789;
    lit.pinBl = 19;
    CHECK(rescuemodel::planPins(lit).panel);
    CHECK(!rescuemodel::planPins(lit).backlight);
    for (const char *name : rescuemodel::BRIDGE_PIN_FIELDS) {
      board::Config cfg = board::CONFIG_LCD_ST7789_130;
      for (const auto &field : PIN_FIELDS) {
        if (strcmp(field.name, name) == 0) cfg.*field.member = 20;
      }
      CHECK(!rescuemodel::planPins(cfg).uartBridge);
    }
  }

  // --- A stored CFGBOARD override is reported the way the stream applies it -
  {
    using board::Variant;
    const Variant none = Variant::Unknown;
    CHECK(rescuemodel::effectiveOverride(0, Platform::Esp32S3, none) == nullptr);
    CHECK(strcmp(rescuemodel::effectiveOverride(
                     (uint8_t)Variant::LcdSt7789_130, Platform::Esp32S3, none),
                 "st7789-130") == 0);
    // Cross-family and unknown values fall through to detection.
    CHECK(rescuemodel::effectiveOverride((uint8_t)Variant::LcdSt7789,
                                         Platform::Esp32S3, none) == nullptr);
    CHECK(rescuemodel::effectiveOverride(250, Platform::Esp32S3, none) ==
          nullptr);
    // A fixed-variant family never applies the key.
    CHECK(rescuemodel::effectiveOverride((uint8_t)Variant::P4_4B,
                                         Platform::Esp32P4, Variant::P4_4B) ==
          nullptr);
    CHECK(strcmp(rescuemodel::effectiveOverride((uint8_t)Variant::LcdSt7789,
                                                Platform::Esp32C6, none),
                 "st7789") == 0);
  }

  // --- Word wrap ------------------------------------------------------------
  {
    char lines[rescuemodel::MAX_NAME_LINES][rescuemodel::MAX_LINE_CHARS + 1];
    CHECK(rescuemodel::wrap("ESP32-S3-LCD-0.85 (GC9107)", 19, lines) == 2);
    CHECK(strcmp(lines[0], "ESP32-S3-LCD-0.85") == 0);
    CHECK(strcmp(lines[1], "(GC9107)") == 0);
    CHECK(rescuemodel::wrap("ESP32-P4-WIFI6-TOUCH-LCD-4B (ST7703)", 21,
                            lines) == 2);
    CHECK(strcmp(lines[0], "ESP32-P4-WIFI6-TOUCH-") == 0);
    CHECK(strcmp(lines[1], "LCD-4B (ST7703)") == 0);
    CHECK(rescuemodel::wrap("ABCDEFGHIJ", 4, lines) == 3);
    CHECK(strcmp(lines[2], "IJ") == 0);
    CHECK(rescuemodel::wrap("ABCDEFGHIJKLM", 4, lines) ==
          rescuemodel::MAX_NAME_LINES + 1);
    CHECK(rescuemodel::wrap("  ", 4, lines) == 0);
  }

  // --- Glyphs ---------------------------------------------------------------
  {
    CHECK(rescuemodel::glyphFor('a') == rescuemodel::glyphFor('A'));
    CHECK(rescuemodel::glyphFor('~') == rescuemodel::glyphFor('?'));
    CHECK(rescuemodel::glyphFor('A') != rescuemodel::glyphFor('B'));
  }

  // --- Every panel gets the whole screen, inside its glass ------------------
  {
    for (const auto &identity : board::GENERATED_BOARD_IDENTITIES) {
      const board::Config &cfg = board::configFor(identity.variant);
      const rescuemodel::Screen screen = rescuemodel::layout(
          cfg.panel->width, cfg.panel->height, cfg.panel->roundDisplay,
          cfg.name, identity.profile);
      CHECK(screen.lineCount >= 3);
      CHECK(strcmp(screen.lines[0].text, rescuemodel::TITLE) == 0);
      CHECK(strcmp(screen.lines[screen.lineCount - 1].text,
                   identity.profile) == 0);
      for (uint8_t i = 0; i < screen.lineCount; ++i) {
        if (!insideBox(screen, screen.lines[i])) {
          printf("  %s line %u '%s' leaves the glass\n", identity.profile, i,
                 screen.lines[i].text);
        }
        CHECK(insideBox(screen, screen.lines[i]));
        if (i > 0) {
          CHECK(screen.lines[i].y >=
                screen.lines[i - 1].y + 7 * screen.lines[i - 1].scale);
        }
      }
      // RESCUE is the largest thing on the glass.
      CHECK(screen.lines[0].scale >= screen.lines[1].scale);
      CHECK(screen.lines[0].scale >= 2);
    }
  }

  // --- The override warning fits every panel, whatever it names ------------
  {
    size_t longest = 0;
    const char *longestToken = "";
    for (const auto &identity : board::GENERATED_BOARD_IDENTITIES) {
      if (strlen(identity.profile) > longest) {
        longest = strlen(identity.profile);
        longestToken = identity.profile;
      }
    }
    char warning[64];
    snprintf(warning, sizeof(warning), "CFGBOARD %s", longestToken);
    for (const auto &identity : board::GENERATED_BOARD_IDENTITIES) {
      const board::Config &cfg = board::configFor(identity.variant);
      const rescuemodel::Screen screen = rescuemodel::layout(
          cfg.panel->width, cfg.panel->height, cfg.panel->roundDisplay,
          cfg.name, identity.profile, warning);
      CHECK(screen.lineCount >= 4);
      std::string shown;
      for (uint8_t i = 0; i < screen.lineCount; ++i) {
        if (screen.lines[i].color != rescuemodel::COLOR_WARNING) continue;
        if (!shown.empty() && shown.back() != '-') shown += ' ';
        shown += screen.lines[i].text;
      }
      CHECK(shown == warning);
      CHECK(screen.lines[screen.lineCount - 1].color ==
            rescuemodel::COLOR_WARNING);
      for (uint8_t i = 0; i < screen.lineCount; ++i) {
        if (!insideBox(screen, screen.lines[i])) {
          printf("  %s warning layout line %u '%s' leaves the glass\n",
                 identity.profile, i, screen.lines[i].text);
        }
        CHECK(insideBox(screen, screen.lines[i]));
        if (i > 0) {
          CHECK(screen.lines[i].y >=
                screen.lines[i - 1].y + 7 * screen.lines[i - 1].scale);
        }
      }
    }
  }

  // --- Rendering ------------------------------------------------------------
  {
    const rescuemodel::Screen square =
        rescuemodel::layout(240, 240, false, "ESP32-S3-LCD-1.3", "st7789-130");
    std::vector<uint8_t> frame(240 * 240 * 2);
    for (int y = 0; y < 240; y += 16) {
      rescuemodel::renderBand(square, y, 16, frame.data() + y * 240 * 2);
    }
    auto pixel = [&](int x, int y) {
      return (uint16_t)(frame[(y * 240 + x) * 2] << 8 |
                        frame[(y * 240 + x) * 2 + 1]);
    };
    CHECK(pixel(0, 0) == rescuemodel::COLOR_BORDER);
    CHECK(pixel(239, 239) == rescuemodel::COLOR_BORDER);
    CHECK(pixel(120, 120) != rescuemodel::COLOR_BORDER);
    int title = 0, name = 0, profile = 0;
    for (int y = 0; y < 240; ++y) {
      for (int x = 0; x < 240; ++x) {
        title += pixel(x, y) == rescuemodel::COLOR_TITLE;
        name += pixel(x, y) == rescuemodel::COLOR_NAME;
        profile += pixel(x, y) == rescuemodel::COLOR_PROFILE;
      }
    }
    CHECK(title > 0 && name > 0 && profile > 0);
    CHECK(title > name);

    const rescuemodel::Screen round =
        rescuemodel::layout(240, 240, true, "CrowPanel", "gc9a01-knob-128");
    std::vector<uint8_t> band(240 * 4 * 2);
    rescuemodel::renderBand(round, 0, 4, band.data());
    CHECK(band[0] == 0 && band[1] == 0);  // corner outside the circle is dark
    const size_t top = (size_t)(1 * 240 + 120) * 2;
    CHECK((uint16_t)(band[top] << 8 | band[top + 1]) ==
          rescuemodel::COLOR_BORDER);
  }

  printf("OK: %d rescue checks passed\n", checks);
  return 0;
}
