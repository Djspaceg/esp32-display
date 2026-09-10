// Hardware-free WiFi preset record and command policy.
#pragma once

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

namespace wifipresets {

static const uint8_t SLOT_MIN = 1;
static const uint8_t SLOT_MAX = 10;
static const uint8_t ACTIVE_DIRECT = 255;
static const uint8_t RECORD_VERSION = 1;
static const size_t SSID_MAX_BYTES = 32;
static const size_t PASSWORD_MAX_BYTES = 64;
static const size_t RECORD_HEADER_BYTES = 3;
static const size_t RECORD_CRC_BYTES = 4;
static const size_t RECORD_MAX_BYTES =
    RECORD_HEADER_BYTES + SSID_MAX_BYTES + PASSWORD_MAX_BYTES +
    RECORD_CRC_BYTES;

inline bool validSlot(uint8_t slot) {
  return slot >= SLOT_MIN && slot <= SLOT_MAX;
}

inline uint16_t slotMask(uint8_t slot) {
  return validSlot(slot) ? (uint16_t)(1u << (slot - 1)) : 0;
}

inline bool slotMutationNeedsDirect(uint8_t activeSelector, uint8_t slot) {
  return validSlot(slot) && activeSelector == slot;
}

inline size_t orderedSlots(uint16_t mask, uint8_t *slots, size_t capacity) {
  size_t count = 0;
  for (uint8_t slot = SLOT_MIN; slot <= SLOT_MAX; ++slot) {
    if ((mask & slotMask(slot)) == 0) continue;
    if (slots != nullptr && count < capacity) slots[count] = slot;
    ++count;
  }
  return count;
}

struct Credentials {
  uint8_t ssidLength = 0;
  uint8_t passwordLength = 0;
  uint8_t ssid[SSID_MAX_BYTES] = {0};
  uint8_t password[PASSWORD_MAX_BYTES] = {0};
};

enum class CredentialError : uint8_t {
  None,
  SsidLengthOrNul,
  PasswordLengthOrNul,
};

inline CredentialError validateCredentials(const Credentials &credentials) {
  if (credentials.ssidLength == 0 ||
      credentials.ssidLength > SSID_MAX_BYTES ||
      memchr(credentials.ssid, 0, credentials.ssidLength) != nullptr) {
    return CredentialError::SsidLengthOrNul;
  }
  if (credentials.passwordLength > PASSWORD_MAX_BYTES ||
      (credentials.passwordLength > 0 &&
       memchr(credentials.password, 0, credentials.passwordLength) !=
           nullptr)) {
    return CredentialError::PasswordLengthOrNul;
  }
  return CredentialError::None;
}

inline uint32_t crc32(const uint8_t *bytes, size_t length) {
  uint32_t crc = 0xFFFFFFFFu;
  for (size_t i = 0; i < length; ++i) {
    crc ^= bytes[i];
    for (uint8_t bit = 0; bit < 8; ++bit) {
      crc = (crc >> 1) ^ (0xEDB88320u & (uint32_t)(0u - (crc & 1u)));
    }
  }
  return crc ^ 0xFFFFFFFFu;
}

inline uint32_t readU32Le(const uint8_t *bytes) {
  return (uint32_t)bytes[0] | ((uint32_t)bytes[1] << 8) |
         ((uint32_t)bytes[2] << 16) | ((uint32_t)bytes[3] << 24);
}

inline void writeU32Le(uint8_t *bytes, uint32_t value) {
  bytes[0] = (uint8_t)value;
  bytes[1] = (uint8_t)(value >> 8);
  bytes[2] = (uint8_t)(value >> 16);
  bytes[3] = (uint8_t)(value >> 24);
}

inline size_t encodedRecordLength(const Credentials &credentials) {
  return RECORD_HEADER_BYTES + credentials.ssidLength +
         credentials.passwordLength + RECORD_CRC_BYTES;
}

inline size_t encodeRecord(const Credentials &credentials, uint8_t *output,
                           size_t capacity) {
  if (validateCredentials(credentials) != CredentialError::None) return 0;
  const size_t length = encodedRecordLength(credentials);
  if (output == nullptr || capacity < length) return 0;

  output[0] = RECORD_VERSION;
  output[1] = credentials.ssidLength;
  output[2] = credentials.passwordLength;
  size_t offset = RECORD_HEADER_BYTES;
  memcpy(output + offset, credentials.ssid, credentials.ssidLength);
  offset += credentials.ssidLength;
  memcpy(output + offset, credentials.password, credentials.passwordLength);
  offset += credentials.passwordLength;
  writeU32Le(output + offset, crc32(output, offset));
  return length;
}

enum class RecordStatus : uint8_t {
  Valid,
  Length,
  Version,
  Credential,
  Crc,
};

inline RecordStatus decodeRecord(const uint8_t *record, size_t length,
                                 Credentials &output) {
  if (record == nullptr ||
      length < RECORD_HEADER_BYTES + RECORD_CRC_BYTES ||
      length > RECORD_MAX_BYTES) {
    return RecordStatus::Length;
  }
  if (record[0] != RECORD_VERSION) return RecordStatus::Version;

  const size_t ssidLength = record[1];
  const size_t passwordLength = record[2];
  if (ssidLength == 0 || ssidLength > SSID_MAX_BYTES ||
      passwordLength > PASSWORD_MAX_BYTES) {
    return RecordStatus::Credential;
  }
  const size_t payloadLength = ssidLength + passwordLength;
  const size_t expectedLength =
      RECORD_HEADER_BYTES + payloadLength + RECORD_CRC_BYTES;
  if (length != expectedLength) return RecordStatus::Length;

  Credentials decoded = {};
  decoded.ssidLength = (uint8_t)ssidLength;
  decoded.passwordLength = (uint8_t)passwordLength;
  memcpy(decoded.ssid, record + RECORD_HEADER_BYTES, ssidLength);
  memcpy(decoded.password, record + RECORD_HEADER_BYTES + ssidLength,
         passwordLength);
  if (validateCredentials(decoded) != CredentialError::None) {
    return RecordStatus::Credential;
  }

  const uint32_t storedCrc =
      readU32Le(record + expectedLength - RECORD_CRC_BYTES);
  const uint32_t calculatedCrc =
      crc32(record, expectedLength - RECORD_CRC_BYTES);
  if (storedCrc != calculatedCrc) return RecordStatus::Crc;
  output = decoded;
  return RecordStatus::Valid;
}

enum class EffectiveOrigin : uint8_t {
  Preset,
  Legacy,
  Compiled,
};

inline EffectiveOrigin effectiveOrigin(uint8_t activeSelector,
                                       bool activeRecordValid,
                                       bool legacySsidStored) {
  if (validSlot(activeSelector) && activeRecordValid) {
    return EffectiveOrigin::Preset;
  }
  return legacySsidStored ? EffectiveOrigin::Legacy
                          : EffectiveOrigin::Compiled;
}

inline uint8_t effectiveActiveSlot(uint8_t activeSelector,
                                   bool activeRecordValid) {
  return validSlot(activeSelector) && activeRecordValid ? activeSelector : 0;
}

inline bool byteStringsEqual(const uint8_t *left, size_t leftLength,
                             const uint8_t *right, size_t rightLength) {
  if (leftLength != rightLength) return false;
  if (leftLength == 0) return true;
  if (left == nullptr || right == nullptr) return false;
  return memcmp(left, right, leftLength) == 0;
}

inline bool mirrorNeeded(const Credentials &credentials,
                         const uint8_t *legacySsid, size_t legacySsidLength,
                         const uint8_t *legacyPassword,
                         size_t legacyPasswordLength) {
  return !byteStringsEqual(credentials.ssid, credentials.ssidLength, legacySsid,
                           legacySsidLength) ||
         !byteStringsEqual(credentials.password, credentials.passwordLength,
                           legacyPassword, legacyPasswordLength);
}

enum class CommandKind : uint8_t {
  Unknown,
  Set,
  Clear,
  Use,
  ShowRoster,
  ShowSlot,
};

enum class CommandError : uint8_t {
  None,
  ExpectedSet,
  SlotOutOfRange,
  BadBase64Ssid,
  BadBase64Password,
  SsidLengthOrNul,
  PasswordLengthOrNul,
};

inline const char *commandErrorText(CommandError error) {
  switch (error) {
    case CommandError::ExpectedSet:
      return "CFGERR expected: CFGWIFISET <1-10> <base64 ssid> <base64 "
             "password|->";
    case CommandError::SlotOutOfRange:
      return "CFGERR wifi slot out of range (1-10)";
    case CommandError::BadBase64Ssid:
      return "CFGERR bad base64 ssid";
    case CommandError::BadBase64Password:
      return "CFGERR bad base64 password";
    case CommandError::SsidLengthOrNul:
      return "CFGERR ssid must be 1..32 bytes and contain no 0x00";
    case CommandError::PasswordLengthOrNul:
      return "CFGERR password must be 0..64 bytes and contain no 0x00";
    case CommandError::None:
      break;
  }
  return nullptr;
}

inline bool formatted(int written, size_t capacity) {
  return written >= 0 && (size_t)written < capacity;
}

inline bool formatSavedReply(char *output, size_t capacity, uint8_t slot,
                             uint8_t ssidLength, bool passwordSet,
                             uint8_t activeSlot) {
  if (activeSlot == 0) {
    return formatted(
        snprintf(output, capacity,
                 "CFGOK wifi slot=%u saved ssid_bytes=%u pass=%s "
                 "active=direct",
                 (unsigned)slot, (unsigned)ssidLength,
                 passwordSet ? "set" : "open"),
        capacity);
  }
  return formatted(
      snprintf(output, capacity,
               "CFGOK wifi slot=%u saved ssid_bytes=%u pass=%s active=%u",
               (unsigned)slot, (unsigned)ssidLength,
               passwordSet ? "set" : "open", (unsigned)activeSlot),
      capacity);
}

inline bool formatClearedReply(char *output, size_t capacity, uint8_t slot,
                               uint8_t activeSlot) {
  if (activeSlot == 0) {
    return formatted(
        snprintf(output, capacity,
                 "CFGOK wifi slot=%u cleared active=direct", (unsigned)slot),
        capacity);
  }
  return formatted(
      snprintf(output, capacity, "CFGOK wifi slot=%u cleared active=%u",
               (unsigned)slot, (unsigned)activeSlot),
      capacity);
}

inline bool formatSelectedReply(char *output, size_t capacity, uint8_t slot) {
  return formatted(
      snprintf(output, capacity,
               "CFGOK wifi slot=%u selected, restarting", (unsigned)slot),
      capacity);
}

inline bool formatRosterReply(char *output, size_t capacity, uint16_t validMask,
                              uint8_t activeSlot, bool local) {
  if (activeSlot == 0) {
    return formatted(
        snprintf(output, capacity,
                 "CFGINFO wifi capacity=10 valid=0x%03x active=direct "
                 "mode=direct local=%u",
                 (unsigned)(validMask & 0x3FFu), local ? 1u : 0u),
        capacity);
  }
  return formatted(
      snprintf(output, capacity,
               "CFGINFO wifi capacity=10 valid=0x%03x active=%u "
               "mode=preset local=%u",
               (unsigned)(validMask & 0x3FFu), (unsigned)activeSlot,
               local ? 1u : 0u),
      capacity);
}

inline bool formatValidSlotReply(char *output, size_t capacity, uint8_t slot,
                                 bool active, const char *ssid64,
                                 bool passwordSet) {
  return formatted(
      snprintf(output, capacity,
               "CFGINFO wifi slot=%u valid=1 active=%u ssid64=%s pass=%s",
               (unsigned)slot, active ? 1u : 0u,
               ssid64 != nullptr ? ssid64 : "",
               passwordSet ? "set" : "open"),
      capacity);
}

inline bool formatInvalidSlotReply(char *output, size_t capacity,
                                   uint8_t slot) {
  return formatted(
      snprintf(output, capacity, "CFGINFO wifi slot=%u valid=0 active=0",
               (unsigned)slot),
      capacity);
}

inline bool formatUnavailableReply(char *output, size_t capacity,
                                   uint8_t slot) {
  return formatted(
      snprintf(output, capacity, "CFGERR wifi slot=%u unavailable",
               (unsigned)slot),
      capacity);
}

inline bool formatSaveFailedReply(char *output, size_t capacity,
                                  uint8_t slot) {
  return formatted(
      snprintf(output, capacity, "CFGERR wifi slot=%u save failed",
               (unsigned)slot),
      capacity);
}

struct ParsedCommand {
  CommandKind kind = CommandKind::Unknown;
  CommandError error = CommandError::None;
  uint8_t slot = 0;
  Credentials credentials = {};
};

struct Token {
  const char *bytes = nullptr;
  size_t length = 0;
};

inline bool commandArguments(const char *line, const char *command,
                             const char *&arguments) {
  if (line == nullptr) return false;
  const size_t commandLength = strlen(command);
  if (strncmp(line, command, commandLength) != 0) return false;
  if (line[commandLength] == '\0') {
    arguments = line + commandLength;
    return true;
  }
  if (line[commandLength] != ' ') return false;
  arguments = line + commandLength + 1;
  return true;
}

inline size_t tokenize(const char *arguments, Token *tokens, size_t capacity,
                       bool &overflow) {
  overflow = false;
  size_t count = 0;
  const char *cursor = arguments;
  while (cursor != nullptr && *cursor != '\0') {
    while (*cursor == ' ') ++cursor;
    if (*cursor == '\0') break;
    const char *start = cursor;
    while (*cursor != '\0' && *cursor != ' ') ++cursor;
    if (count < capacity) {
      tokens[count].bytes = start;
      tokens[count].length = (size_t)(cursor - start);
    } else {
      overflow = true;
    }
    ++count;
  }
  return count;
}

inline bool parseSlot(const Token &token, uint8_t &slot) {
  if (token.bytes == nullptr || token.length == 0 || token.length > 3) {
    return false;
  }
  unsigned value = 0;
  for (size_t i = 0; i < token.length; ++i) {
    const char c = token.bytes[i];
    if (c < '0' || c > '9') return false;
    value = value * 10u + (unsigned)(c - '0');
  }
  if (value < SLOT_MIN || value > SLOT_MAX) return false;
  slot = (uint8_t)value;
  return true;
}

inline int base64Value(char c) {
  if (c >= 'A' && c <= 'Z') return c - 'A';
  if (c >= 'a' && c <= 'z') return c - 'a' + 26;
  if (c >= '0' && c <= '9') return c - '0' + 52;
  if (c == '+') return 62;
  if (c == '/') return 63;
  return -1;
}

enum class Base64Status : uint8_t {
  Valid,
  Invalid,
  TooLong,
};

inline Base64Status decodeBase64(const Token &token, uint8_t *output,
                                 size_t capacity, size_t &decodedLength) {
  decodedLength = 0;
  if (token.bytes == nullptr || token.length == 0 ||
      (token.length % 4) != 0) {
    return Base64Status::Invalid;
  }

  size_t padding = 0;
  if (token.bytes[token.length - 1] == '=') ++padding;
  if (token.bytes[token.length - 2] == '=') ++padding;
  for (size_t i = 0; i < token.length - padding; ++i) {
    if (base64Value(token.bytes[i]) < 0) return Base64Status::Invalid;
  }
  for (size_t i = token.length - padding; i < token.length; ++i) {
    if (token.bytes[i] != '=') return Base64Status::Invalid;
  }
  if (padding > 2) return Base64Status::Invalid;
  for (size_t i = 0; i + padding < token.length; ++i) {
    if (token.bytes[i] == '=') return Base64Status::Invalid;
  }

  decodedLength = (token.length / 4) * 3 - padding;
  if (decodedLength > capacity) return Base64Status::TooLong;
  if (decodedLength > 0 && output == nullptr) return Base64Status::Invalid;

  size_t outputOffset = 0;
  for (size_t i = 0; i < token.length; i += 4) {
    const int a = base64Value(token.bytes[i]);
    const int b = base64Value(token.bytes[i + 1]);
    const int c =
        token.bytes[i + 2] == '=' ? 0 : base64Value(token.bytes[i + 2]);
    const int d =
        token.bytes[i + 3] == '=' ? 0 : base64Value(token.bytes[i + 3]);
    if (a < 0 || b < 0 || c < 0 || d < 0) return Base64Status::Invalid;
    if (token.bytes[i + 2] == '=' && token.bytes[i + 3] != '=') {
      return Base64Status::Invalid;
    }
    if (token.bytes[i + 2] == '=' && (b & 0x0F) != 0) {
      return Base64Status::Invalid;
    }
    if (token.bytes[i + 3] == '=' && token.bytes[i + 2] != '=' &&
        (c & 0x03) != 0) {
      return Base64Status::Invalid;
    }

    if (outputOffset < decodedLength) {
      output[outputOffset++] = (uint8_t)((a << 2) | (b >> 4));
    }
    if (outputOffset < decodedLength) {
      output[outputOffset++] = (uint8_t)((b << 4) | (c >> 2));
    }
    if (outputOffset < decodedLength) {
      output[outputOffset++] = (uint8_t)((c << 6) | d);
    }
  }
  return Base64Status::Valid;
}

inline ParsedCommand parseCommand(const char *line) {
  ParsedCommand parsed;
  const char *arguments = nullptr;
  Token tokens[4] = {};
  bool overflow = false;

  if (commandArguments(line, "CFGWIFISET", arguments)) {
    parsed.kind = CommandKind::Set;
    const size_t count = tokenize(arguments, tokens, 4, overflow);
    if (overflow || count != 3) {
      parsed.error = CommandError::ExpectedSet;
      return parsed;
    }
    if (!parseSlot(tokens[0], parsed.slot)) {
      parsed.error = CommandError::SlotOutOfRange;
      return parsed;
    }

    size_t decodedLength = 0;
    const Base64Status ssidStatus =
        decodeBase64(tokens[1], parsed.credentials.ssid, SSID_MAX_BYTES,
                     decodedLength);
    if (ssidStatus == Base64Status::Invalid) {
      parsed.error = CommandError::BadBase64Ssid;
      return parsed;
    }
    if (ssidStatus == Base64Status::TooLong) {
      parsed.error = CommandError::SsidLengthOrNul;
      return parsed;
    }
    parsed.credentials.ssidLength = (uint8_t)decodedLength;

    if (tokens[2].length == 1 && tokens[2].bytes[0] == '-') {
      parsed.credentials.passwordLength = 0;
    } else {
      const Base64Status passwordStatus =
          decodeBase64(tokens[2], parsed.credentials.password,
                       PASSWORD_MAX_BYTES, decodedLength);
      if (passwordStatus == Base64Status::Invalid) {
        parsed.error = CommandError::BadBase64Password;
        return parsed;
      }
      if (passwordStatus == Base64Status::TooLong) {
        parsed.error = CommandError::PasswordLengthOrNul;
        return parsed;
      }
      parsed.credentials.passwordLength = (uint8_t)decodedLength;
    }

    switch (validateCredentials(parsed.credentials)) {
      case CredentialError::SsidLengthOrNul:
        parsed.error = CommandError::SsidLengthOrNul;
        return parsed;
      case CredentialError::PasswordLengthOrNul:
        parsed.error = CommandError::PasswordLengthOrNul;
        return parsed;
      case CredentialError::None:
        return parsed;
    }
  }

  if (commandArguments(line, "CFGWIFICLEAR", arguments)) {
    parsed.kind = CommandKind::Clear;
    const size_t count = tokenize(arguments, tokens, 2, overflow);
    if (overflow || count != 1 || !parseSlot(tokens[0], parsed.slot)) {
      parsed.error = CommandError::SlotOutOfRange;
    }
    return parsed;
  }

  if (commandArguments(line, "CFGWIFIUSE", arguments)) {
    parsed.kind = CommandKind::Use;
    const size_t count = tokenize(arguments, tokens, 2, overflow);
    if (overflow || count != 1 || !parseSlot(tokens[0], parsed.slot)) {
      parsed.error = CommandError::SlotOutOfRange;
    }
    return parsed;
  }

  if (commandArguments(line, "CFGWIFISHOW", arguments)) {
    const size_t count = tokenize(arguments, tokens, 2, overflow);
    if (!overflow && count == 0) {
      parsed.kind = CommandKind::ShowRoster;
      return parsed;
    }
    parsed.kind = CommandKind::ShowSlot;
    if (overflow || count != 1 || !parseSlot(tokens[0], parsed.slot)) {
      parsed.error = CommandError::SlotOutOfRange;
    }
    return parsed;
  }

  return parsed;
}

inline CommandKind commandKind(const char *line) {
  return parseCommand(line).kind;
}

}  // namespace wifipresets
