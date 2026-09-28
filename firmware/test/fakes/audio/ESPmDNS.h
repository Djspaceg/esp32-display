#pragma once

#include <stdint.h>

#include <map>
#include <string>

#include "Arduino.h"

// Records the TXT items the last announce set, so tests can read back what a
// browser would see.
class FakeMDNS {
 public:
  bool begin(const char *) { return true; }
  void end() {}
  void setInstanceName(const String &) {}
  void addService(const char *, const char *, uint16_t) {}
  void addServiceTxt(const char *, const char *, const char *key,
                     const char *value) {
    txt_[key] = value == nullptr ? "" : value;
  }
  void addServiceTxt(const char *service, const char *proto, const char *key,
                     const String &value) {
    addServiceTxt(service, proto, key, value.c_str());
  }
  void enableArduino(uint16_t, bool) {}

  bool hasTxt(const char *key) const { return txt_.count(key) != 0; }
  std::string txt(const char *key) const {
    auto found = txt_.find(key);
    return found == txt_.end() ? std::string() : found->second;
  }
  void clearTxt() { txt_.clear(); }

 private:
  std::map<std::string, std::string> txt_;
};

extern FakeMDNS MDNS;
