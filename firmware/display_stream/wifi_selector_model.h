// Hardware-free selection and label helpers for the on-device WiFi preset UI.
#pragma once

#include <stddef.h>
#include <stdint.h>

#include "wifi_presets.h"

namespace wifiselector {

inline size_t initialIndex(const uint8_t *slots, size_t count,
                           uint8_t activeSlot) {
  if (slots == nullptr || count == 0) return 0;
  for (size_t i = 0; i < count; ++i) {
    if (slots[i] == activeSlot) return i;
  }
  return 0;
}

inline size_t movedIndex(size_t current, size_t count, int direction) {
  if (count == 0) return 0;
  current %= count;
  if (direction < 0) return current == 0 ? count - 1 : current - 1;
  if (direction > 0) return current + 1 == count ? 0 : current + 1;
  return current;
}

inline size_t windowStart(size_t current, size_t count, size_t visibleCount) {
  if (count == 0 || visibleCount == 0 || visibleCount >= count) return 0;
  current %= count;
  size_t first = current > visibleCount / 2 ? current - visibleCount / 2 : 0;
  const size_t lastStart = count - visibleCount;
  if (first > lastStart) first = lastStart;
  return first;
}

inline size_t displaySsid(const wifipresets::Credentials &credentials,
                          char *output, size_t capacity) {
  if (output == nullptr || capacity == 0) return 0;
  const size_t available = capacity - 1;
  size_t copied = credentials.ssidLength;
  if (copied > available) copied = available;
  for (size_t i = 0; i < copied; ++i) {
    const uint8_t byte = credentials.ssid[i];
    output[i] = byte >= 0x20 && byte <= 0x7E ? (char)byte : '?';
  }
  if (credentials.ssidLength > copied && copied >= 3) {
    output[copied - 3] = '.';
    output[copied - 2] = '.';
    output[copied - 1] = '.';
  }
  output[copied] = 0;
  return copied;
}

}  // namespace wifiselector
