// Host fake of the NVS Preferences surface the Doom request path uses.
#pragma once

#include <stddef.h>
#include <stdint.h>

#include <map>
#include <string>

extern std::map<std::string, bool> fakeNvsBools;

class Preferences {
 public:
  bool begin(const char *, bool) { return true; }
  size_t putBool(const char *key, bool value) {
    fakeNvsBools[key] = value;
    return sizeof(uint8_t);
  }
  void end() {}
};
