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
  WireRequest,
};

struct HardwareEvent {
  HardwareEventKind kind;
  int value;
};

struct SentDatagram {
  std::vector<uint8_t> data;
  uint32_t remoteIp;
  uint16_t remotePort;
};

void reset();
void setMillis(uint32_t value);
void enqueueUdp(const std::vector<uint8_t> &data, uint32_t remoteIp,
                uint16_t remotePort);
size_t pendingUdp();
unsigned delayCalls();
unsigned yieldCalls();
const std::vector<HardwareEvent> &hardwareEvents();
const std::vector<SentDatagram> &sentDatagrams();

// I2C devices the fake bus answers for. reset() installs a genuine ES8311 at
// 0x18 and ES7210 at 0x40; tests remove or alter them to model other boards.
void setI2cDevice(uint8_t address, bool present, uint8_t idRegisterA = 0,
                  uint8_t idA = 0, uint8_t idRegisterB = 0, uint8_t idB = 0);
unsigned wireRegisterWrites();

}  // namespace audiohost
