#pragma once

#include <stddef.h>
#include <stdint.h>

#include <functional>

#include "Arduino.h"

class AsyncUDPPacket {
 public:
  const uint8_t *data() const { return data_; }
  size_t length() const { return length_; }
  IPAddress remoteIP() const { return IPAddress(remoteIp_); }
  uint16_t remotePort() const { return remotePort_; }

 private:
  const uint8_t *data_ = nullptr;
  size_t length_ = 0;
  uint32_t remoteIp_ = 0;
  uint16_t remotePort_ = 0;
};

class AsyncUDP {
 public:
  bool listen(uint16_t) { return true; }

  template <typename Callback>
  void onPacket(Callback callback) {
    callback_ = callback;
  }

  size_t writeTo(const uint8_t *, size_t length, IPAddress, uint16_t) {
    return length;
  }

 private:
  std::function<void(AsyncUDPPacket)> callback_;
};
