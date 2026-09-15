// Hardware-independent command authorization and parsing for board bootstrap.
#pragma once

#include <cerrno>
#include <climits>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstring>

namespace bootstrapproto {

inline bool parseBoundedLong(const char *text, long minimum, long maximum,
                             long &value) {
  if (text == nullptr || *text == '\0' || minimum > maximum) return false;
  errno = 0;
  char *end = nullptr;
  const long parsed = std::strtol(text, &end, 0);
  if (errno == ERANGE || end == text || *end != '\0' ||
      parsed < minimum || parsed > maximum) {
    return false;
  }
  value = parsed;
  return true;
}

inline bool commandRequiresConfirm(const char *command) {
  if (command == nullptr) return false;
  const char *commands[] = {
      "I2C_SCAN",        "I2C_READ",       "IMU_CONFIG",
      "IMU_READ",        "PANEL_CONFIG",   "PANEL_READ_ID",
      "PANEL_FILL",      "PANEL_EDGES",    "PANEL_GLYPH",
      "BACKLIGHT",       "BACKLIGHT_ENABLE",
      "TOUCH_CONFIG",    "TOUCH_READ",
  };
  for (const char *candidate : commands) {
    if (std::strcmp(command, candidate) == 0) return true;
  }
  return false;
}

inline bool commandAuthorized(const char *command, const char *secondToken) {
  return !commandRequiresConfirm(command) ||
         (secondToken != nullptr &&
          std::strcmp(secondToken, "CONFIRM") == 0);
}

struct I2cScanArgs {
  int sda;
  int scl;
};

inline bool parseI2cScanArgs(const char *sdaText, const char *sclText,
                             I2cScanArgs &args) {
  long sda = 0;
  long scl = 0;
  if (!parseBoundedLong(sdaText, 0, 127, sda) ||
      !parseBoundedLong(sclText, 0, 127, scl) || sda == scl) {
    return false;
  }
  args = {(int)sda, (int)scl};
  return true;
}

struct I2cReadArgs {
  int sda;
  int scl;
  uint8_t address;
  uint16_t reg;
  uint8_t regWidth;
  size_t length;
};

inline bool parseI2cReadArgs(const char *sdaText, const char *sclText,
                             const char *addressText, const char *regText,
                             const char *widthText, const char *lengthText,
                             I2cReadArgs &args) {
  I2cScanArgs bus = {};
  long address = 0;
  long width = 0;
  long length = 0;
  if (!parseI2cScanArgs(sdaText, sclText, bus) ||
      !parseBoundedLong(addressText, 0x08, 0x77, address) ||
      !parseBoundedLong(widthText, 1, 2, width) ||
      !parseBoundedLong(lengthText, 1, 32, length)) {
    return false;
  }
  long reg = 0;
  const long maximumRegister = width == 1 ? 0xFF : 0xFFFF;
  if (!parseBoundedLong(regText, 0, maximumRegister, reg)) return false;
  args = {
      bus.sda,
      bus.scl,
      (uint8_t)address,
      (uint16_t)reg,
      (uint8_t)width,
      (size_t)length,
  };
  return true;
}

struct ImuArgs {
  int sda;
  int scl;
  uint8_t address;
};

inline bool parseImuArgs(const char *sdaText, const char *sclText,
                         const char *addressText, ImuArgs &args) {
  I2cScanArgs bus = {};
  long address = 0;
  if (!parseI2cScanArgs(sdaText, sclText, bus) ||
      !parseBoundedLong(addressText, 0x6A, 0x6B, address)) {
    return false;
  }
  args = {bus.sda, bus.scl, (uint8_t)address};
  return true;
}

enum class TouchController : uint8_t {
  Axs5106l,
  Cst816,
  Cst9217,
  Gt911,
};

inline bool parseTouchController(const char *text, TouchController &controller) {
  if (text == nullptr) return false;
  if (std::strcmp(text, "axs5106l") == 0) {
    controller = TouchController::Axs5106l;
  } else if (std::strcmp(text, "cst816") == 0) {
    controller = TouchController::Cst816;
  } else if (std::strcmp(text, "cst9217") == 0) {
    controller = TouchController::Cst9217;
  } else if (std::strcmp(text, "gt911") == 0) {
    controller = TouchController::Gt911;
  } else {
    return false;
  }
  return true;
}

inline bool touchControllerAcceptsAddress(TouchController controller,
                                          uint8_t address) {
  switch (controller) {
    case TouchController::Axs5106l:
      return address == 0x51 || address == 0x63;
    case TouchController::Cst816:
      return address == 0x15;
    case TouchController::Cst9217:
      return address == 0x5A;
    case TouchController::Gt911:
      return address == 0x14 || address == 0x5D;
  }
  return false;
}

struct TouchConfigArgs {
  TouchController controller;
  int sda;
  int scl;
  uint8_t address;
  int reset;
  int interrupt;
  uint8_t exio;
  uint8_t expanderAddress;
  bool sharedReset;
};

inline bool parseTouchConfigArgs(
    const char *controllerText, const char *sdaText, const char *sclText,
    const char *addressText, const char *resetText, const char *interruptText,
    const char *exioText, const char *expanderText,
    const char *sharedResetText, TouchConfigArgs &args) {
  TouchController controller;
  I2cScanArgs bus = {};
  long address = 0;
  long reset = 0;
  long interrupt = 0;
  long exio = 0;
  long expander = 0;
  long sharedReset = 0;
  if (!parseTouchController(controllerText, controller) ||
      !parseI2cScanArgs(sdaText, sclText, bus) ||
      !parseBoundedLong(addressText, 0x08, 0x77, address) ||
      !touchControllerAcceptsAddress(controller, (uint8_t)address) ||
      !parseBoundedLong(resetText, -1, 127, reset) ||
      !parseBoundedLong(interruptText, -1, 127, interrupt) ||
      !parseBoundedLong(exioText, 0, 8, exio) ||
      !parseBoundedLong(expanderText, 0, 0x77, expander) ||
      !parseBoundedLong(sharedResetText, 0, 1, sharedReset)) {
    return false;
  }
  if ((exio == 0 && expander != 0) ||
      (exio > 0 && (expander < 0x08 || expander > 0x77))) {
    return false;
  }
  args = {
      controller,
      bus.sda,
      bus.scl,
      (uint8_t)address,
      (int)reset,
      (int)interrupt,
      (uint8_t)exio,
      (uint8_t)expander,
      sharedReset != 0,
  };
  return true;
}

struct TouchReadArgs {
  TouchController controller;
  int sda;
  int scl;
  uint8_t address;
};

inline bool parseTouchReadArgs(const char *controllerText,
                               const char *sdaText, const char *sclText,
                               const char *addressText,
                               TouchReadArgs &args) {
  TouchController controller;
  I2cScanArgs bus = {};
  long address = 0;
  if (!parseTouchController(controllerText, controller) ||
      !parseI2cScanArgs(sdaText, sclText, bus) ||
      !parseBoundedLong(addressText, 0x08, 0x77, address) ||
      !touchControllerAcceptsAddress(controller, (uint8_t)address)) {
    return false;
  }
  args = {controller, bus.sda, bus.scl, (uint8_t)address};
  return true;
}

struct PanelEdgesArgs {
  int orientation;
  bool hasMarker;
  int markerX;
  int markerY;
};

inline bool validMarkerName(const char *value) {
  return std::strcmp(value, "top_left") == 0 ||
         std::strcmp(value, "top_right") == 0 ||
         std::strcmp(value, "bottom_left") == 0 ||
         std::strcmp(value, "bottom_right") == 0;
}

inline bool parsePanelEdgesArgs(const char *const *assignments, size_t count,
                                int panelWidth, int panelHeight,
                                PanelEdgesArgs &args) {
  if (assignments == nullptr || panelWidth < 1 || panelHeight < 1) {
    return false;
  }
  long orientation = 0;
  long markerX = -1;
  long markerY = -1;
  bool sawOrientation = false;
  bool sawMarker = false;
  bool sawX = false;
  bool sawY = false;
  for (size_t i = 0; i < count; ++i) {
    const char *token = assignments[i];
    if (token == nullptr) return false;
    if (std::strncmp(token, "orientation=", 12) == 0) {
      if (sawOrientation ||
          !parseBoundedLong(token + 12, 0, 3, orientation)) {
        return false;
      }
      sawOrientation = true;
    } else if (std::strncmp(token, "marker=", 7) == 0) {
      if (sawMarker || !validMarkerName(token + 7)) return false;
      sawMarker = true;
    } else if (std::strncmp(token, "x=", 2) == 0) {
      if (sawX ||
          !parseBoundedLong(token + 2, 0, panelWidth - 1, markerX)) {
        return false;
      }
      sawX = true;
    } else if (std::strncmp(token, "y=", 2) == 0) {
      if (sawY ||
          !parseBoundedLong(token + 2, 0, panelHeight - 1, markerY)) {
        return false;
      }
      sawY = true;
    } else {
      return false;
    }
  }
  if (sawOrientation && (sawMarker || sawX || sawY)) return false;
  if (!sawOrientation && !(sawMarker && sawX && sawY)) return false;
  args = {
      (int)orientation,
      sawMarker,
      (int)markerX,
      (int)markerY,
  };
  return true;
}

}  // namespace bootstrapproto
