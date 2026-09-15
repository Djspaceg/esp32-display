#pragma once

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

namespace serialcfg {

inline bool hasBrightnessVerb(const char *line) {
  return line != nullptr &&
         (strcmp(line, "CFGBRIGHT") == 0 ||
          strncmp(line, "CFGBRIGHT ", 10) == 0);
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

struct BrightnessLevels {
  uint8_t low;
  uint8_t high;
  uint8_t idle;
  uint8_t survey;
};

inline bool parseByteToken(const char *&cursor, uint8_t &value) {
  if (*cursor < '0' || *cursor > '9') return false;
  unsigned parsed = 0;
  do {
    parsed = parsed * 10U + (unsigned)(*cursor - '0');
    if (parsed > 255U) return false;
    cursor++;
  } while (*cursor >= '0' && *cursor <= '9');
  if (parsed == 0) return false;
  value = (uint8_t)parsed;
  return true;
}

inline bool parseBrightnessLevels(const char *line, BrightnessLevels &levels) {
  static const char PREFIX[] = "CFGBRIGHTLEVELS ";
  if (line == nullptr || strncmp(line, PREFIX, sizeof(PREFIX) - 1) != 0) {
    return false;
  }
  const char *cursor = line + sizeof(PREFIX) - 1;
  uint8_t values[4] = {0};
  for (size_t i = 0; i < 4; ++i) {
    if (!parseByteToken(cursor, values[i])) return false;
    if (i < 3) {
      if (*cursor != ' ') return false;
      cursor++;
    } else if (*cursor != 0) {
      return false;
    }
  }
  if (values[0] >= values[1]) return false;
  levels.low = values[0];
  levels.high = values[1];
  levels.idle = values[2];
  levels.survey = values[3];
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
