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
extern std::map<std::string, std::string> fakeNvsBytes;
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
  size_t putBytes(const char *key, const void *value, size_t length) {
    if (fakeNvsWritesFail) return 0;
    fakeNvsBytes[key] = std::string((const char *)value, length);
    return length;
  }
  size_t getBytesLength(const char *key) {
    const auto found = fakeNvsBytes.find(key);
    return found == fakeNvsBytes.end() ? 0 : found->second.size();
  }
  size_t getBytes(const char *key, void *out, size_t capacity) {
    const auto found = fakeNvsBytes.find(key);
    if (found == fakeNvsBytes.end() || found->second.size() > capacity) return 0;
    memcpy(out, found->second.data(), found->second.size());
    return found->second.size();
  }
  bool isKey(const char *key) {
    return fakeNvsBools.count(key) != 0 || fakeNvsStrings.count(key) != 0 ||
           fakeNvsBytes.count(key) != 0;
  }
  bool remove(const char *key) {
    return (fakeNvsBools.erase(key) + fakeNvsStrings.erase(key) +
            fakeNvsBytes.erase(key)) != 0;
  }
  void end() {}
};
