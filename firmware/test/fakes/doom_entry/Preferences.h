// Host fake of the NVS Preferences surface the boot-menu and Doom request
// paths use.
#pragma once

#include <stddef.h>
#include <stdint.h>

#include <map>
#include <string>

extern std::map<std::string, bool> fakeNvsBools;
// Set to make every write fail, the way a full or unformatted NVS does.
extern bool fakeNvsWritesFail;

class Preferences {
 public:
  bool begin(const char *, bool) { return true; }
  size_t putBool(const char *key, bool value) {
    if (fakeNvsWritesFail) return 0;
    fakeNvsBools[key] = value;
    return sizeof(uint8_t);
  }
  bool isKey(const char *key) { return fakeNvsBools.count(key) != 0; }
  bool remove(const char *key) { return fakeNvsBools.erase(key) != 0; }
  void end() {}
};
