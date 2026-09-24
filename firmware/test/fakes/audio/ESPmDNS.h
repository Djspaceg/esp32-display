#pragma once

#include <stdint.h>

#include "Arduino.h"

class FakeMDNS {
 public:
  bool begin(const char *) { return true; }
  void end() {}
  void setInstanceName(const String &) {}
  void addService(const char *, const char *, uint16_t) {}
  void addServiceTxt(const char *, const char *, const char *,
                     const char *) {}
  void addServiceTxt(const char *, const char *, const char *,
                     const String &) {}
  void enableArduino(uint16_t, bool) {}
};

extern FakeMDNS MDNS;
