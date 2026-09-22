#pragma once

#include <stddef.h>
#include <stdint.h>

#include <vector>

namespace audiohost {

enum class HardwareEventKind {
  PinMode,
  DigitalWrite,
  I2sSetPins,
  I2sBegin,
  I2sWrite,
  I2sEnd,
  WireBegin,
  WireTransmission,
};

struct HardwareEvent {
  HardwareEventKind kind;
  int value;
};

void reset();
void setMillis(uint32_t value);
void enqueueUdp(const std::vector<uint8_t> &data, uint32_t remoteIp,
                uint16_t remotePort);
size_t pendingUdp();
unsigned delayCalls();
unsigned yieldCalls();
const std::vector<HardwareEvent> &hardwareEvents();

}  // namespace audiohost
