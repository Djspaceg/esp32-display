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
// Each WiFi.RSSI() advances the fake clock by this much (0 after reset());
// 5000 models ESP-Hosted's DEFAULT_RPC_RSP_TIMEOUT with a silent C6.
void setRssiRpcStallMs(uint32_t value);
unsigned rssiRpcCalls();
// WiFi.reconnect() and WiFi.disconnect(), stalled the same way.
unsigned linkRpcCalls();
// WiFi.SSID(), stalled the same way.
unsigned ssidRpcCalls();
// What WiFi.RSSI() returns (-42 after reset()); 0 is a failed RPC.
void setRssiValue(int value);

// I2C devices the fake bus answers for. reset() installs a genuine ES8311 at
// 0x18 and ES7210 at 0x40; tests remove or alter them to model other boards.
void setI2cDevice(uint8_t address, bool present, uint8_t idRegisterA = 0,
                  uint8_t idA = 0, uint8_t idRegisterB = 0, uint8_t idB = 0);
unsigned wireRegisterWrites();
// Every I2S write and read returns 0 bytes at once, as the driver does on a
// deleted or disabled channel. reset() clears it.
void setI2sFailing(bool failing);

}  // namespace audiohost
