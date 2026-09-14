#pragma once

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

namespace serialcfg {

inline bool hasBrightnessVerb(const char *line) {
  return line != nullptr && strncmp(line, "CFGBRIGHT", 9) == 0;
}

inline bool parseBrightness(const char *line, uint8_t &level) {
  static const char PREFIX[] = "CFGBRIGHT ";
  if (line == nullptr || strncmp(line, PREFIX, sizeof(PREFIX) - 1) != 0) {
    return false;
  }
  const char *cursor = line + sizeof(PREFIX) - 1;
  if (*cursor == 0) return false;

  unsigned value = 0;
  while (*cursor >= '0' && *cursor <= '9') {
    value = value * 10U + (unsigned)(*cursor - '0');
    if (value > 255U) return false;
    cursor++;
  }
  if (*cursor != 0 || value < 1U) return false;
  level = (uint8_t)value;
  return true;
}

inline int formatShowExtension(char *output, size_t outputSize,
                               uint32_t capabilities, uint8_t brightnessLevel,
                               const char *firmwareVersion) {
  return snprintf(output, outputSize, " caps=%08lx bllevel=%u fw=%s",
                  (unsigned long)capabilities, (unsigned)brightnessLevel,
                  firmwareVersion);
}

}  // namespace serialcfg
