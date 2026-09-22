#pragma once

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

namespace serialcfg {

enum class AudioTestCommand : uint8_t { Unknown, Start, Stop, Invalid };

struct ParsedAudioTest {
  AudioTestCommand command;
  uint32_t durationMs;
};

enum class AudioTuneField : uint8_t {
  Unknown,
  Show,
  LowMs,
  TargetMs,
  HighMs,
  MaxPpm,
  ReceiveBufferKb,
  Invalid,
};

struct ParsedAudioTune {
  AudioTuneField field;
  int32_t value;
};

struct AudioTuneConfig {
  uint32_t lowMs;
  uint32_t targetMs;
  uint32_t highMs;
  int32_t maxPpm;
  int32_t receiveBufferKb;
};

inline ParsedAudioTune parseAudioTune(const char *line) {
  static const char VERB[] = "CFGAUDIO";
  static const char PREFIX[] = "CFGAUDIO ";
  if (line == nullptr) return {AudioTuneField::Unknown, 0};
  if (strcmp(line, VERB) == 0) return {AudioTuneField::Show, 0};
  if (strncmp(line, PREFIX, sizeof(PREFIX) - 1) != 0) {
    return {AudioTuneField::Unknown, 0};
  }
  const char *cursor = line + sizeof(PREFIX) - 1;
  const char *separator = strchr(cursor, ' ');
  if (separator == nullptr || separator == cursor) {
    return {AudioTuneField::Invalid, 0};
  }
  AudioTuneField field = AudioTuneField::Invalid;
  const size_t nameLength = (size_t)(separator - cursor);
  if (nameLength == 5 && memcmp(cursor, "lowms", 5) == 0) {
    field = AudioTuneField::LowMs;
  } else if (nameLength == 8 && memcmp(cursor, "targetms", 8) == 0) {
    field = AudioTuneField::TargetMs;
  } else if (nameLength == 6 && memcmp(cursor, "highms", 6) == 0) {
    field = AudioTuneField::HighMs;
  } else if (nameLength == 6 && memcmp(cursor, "maxppm", 6) == 0) {
    field = AudioTuneField::MaxPpm;
  } else if (nameLength == 8 && memcmp(cursor, "rcvbufkb", 8) == 0) {
    field = AudioTuneField::ReceiveBufferKb;
  }
  cursor = separator + 1;
  if (field == AudioTuneField::Invalid ||
      *cursor < '0' || *cursor > '9') {
    return {AudioTuneField::Invalid, 0};
  }
  int32_t value = 0;
  while (*cursor >= '0' && *cursor <= '9') {
    if (value > 100000) return {AudioTuneField::Invalid, 0};
    value = value * 10 + (*cursor - '0');
    cursor++;
  }
  if (*cursor != 0) return {AudioTuneField::Invalid, 0};
  return {field, value};
}

inline bool applyAudioTune(const ParsedAudioTune &parsed,
                           const AudioTuneConfig &current,
                           AudioTuneConfig &updated) {
  updated = current;
  switch (parsed.field) {
    case AudioTuneField::LowMs:
      updated.lowMs = (uint32_t)parsed.value;
      break;
    case AudioTuneField::TargetMs:
      updated.targetMs = (uint32_t)parsed.value;
      break;
    case AudioTuneField::HighMs:
      updated.highMs = (uint32_t)parsed.value;
      break;
    case AudioTuneField::MaxPpm:
      updated.maxPpm = parsed.value;
      break;
    case AudioTuneField::ReceiveBufferKb:
      updated.receiveBufferKb = parsed.value;
      break;
    default:
      return false;
  }
  return updated.lowMs >= 20 &&
         updated.lowMs + 10 <= updated.targetMs &&
         updated.targetMs + 10 <= updated.highMs &&
         updated.highMs <= 250 &&
         updated.maxPpm >= 50 && updated.maxPpm <= 2000 &&
         updated.receiveBufferKb >= 16 &&
         updated.receiveBufferKb <= 256;
}

inline ParsedAudioTest parseAudioTest(const char *line) {
  static const char VERB[] = "CFGAUDIOTEST";
  static const char PREFIX[] = "CFGAUDIOTEST ";
  if (line == nullptr) return {AudioTestCommand::Unknown, 0};
  if (strcmp(line, VERB) == 0) return {AudioTestCommand::Start, 1000};
  if (strncmp(line, PREFIX, sizeof(PREFIX) - 1) != 0) {
    return {AudioTestCommand::Unknown, 0};
  }
  const char *arg = line + sizeof(PREFIX) - 1;
  if (strcmp(arg, "stop") == 0) return {AudioTestCommand::Stop, 0};
  if (*arg < '0' || *arg > '9') return {AudioTestCommand::Invalid, 0};
  uint32_t duration = 0;
  while (*arg >= '0' && *arg <= '9') {
    duration = duration * 10U + (uint32_t)(*arg - '0');
    if (duration > 5000U) return {AudioTestCommand::Invalid, 0};
    arg++;
  }
  if (*arg != 0 || duration < 100U) {
    return {AudioTestCommand::Invalid, 0};
  }
  return {AudioTestCommand::Start, duration};
}

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
