#pragma once

#include <stdint.h>

#include <map>
#include <string>

class Preferences {
 public:
  // Stored bools, shared by every instance as NVS is; tests set and clear it.
  static std::map<std::string, bool> &bools() {
    static std::map<std::string, bool> stored;
    return stored;
  }

  bool begin(const char *, bool) { return true; }
  uint8_t getUChar(const char *, uint8_t fallback) { return fallback; }
  bool getBool(const char *key, bool fallback) {
    const auto found = bools().find(key);
    return found == bools().end() ? fallback : found->second;
  }
  void end() {}
};
