// Host fake of the NVS Preferences surface the boot-menu and Doom request
// paths use.
#pragma once

#include <stddef.h>
#include <stdint.h>

#include <map>
#include <string>
#include <string.h>

extern std::map<std::string, bool> fakeNvsBools;
extern std::map<std::string, std::string> fakeNvsStrings;
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
  size_t putString(const char *key, const char *value) {
    if (fakeNvsWritesFail) return 0;
    fakeNvsStrings[key] = value;
    return strlen(value);
  }
  bool isKey(const char *key) {
    return fakeNvsBools.count(key) != 0 || fakeNvsStrings.count(key) != 0;
  }
  bool remove(const char *key) {
    return (fakeNvsBools.erase(key) + fakeNvsStrings.erase(key)) != 0;
  }
  void end() {}
};
