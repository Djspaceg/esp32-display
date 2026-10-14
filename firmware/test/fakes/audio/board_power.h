#pragma once

#include <stdint.h>

#include <axp2101_status.h>

namespace boardpower {

enum class Charge : uint8_t { Unknown, Charging, Discharging, Standby };

struct Reading {
  bool present;
  axp2101::External external;
  bool percentKnown;
  uint8_t percent;
  Charge charge;
  uint16_t millivolts;
};

inline bool read(Reading &) { return false; }
inline bool powerKeyEvents(axp2101::PowerKeyEvents &) { return false; }
inline bool hasPowerKey() { return false; }

}  // namespace boardpower
