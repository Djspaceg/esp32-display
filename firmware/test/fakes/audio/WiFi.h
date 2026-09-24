#pragma once

#include "Arduino.h"

static constexpr int WL_CONNECTED = 3;

class FakeWiFi {
 public:
  IPAddress localIP() const { return IPAddress(); }
  int status() const { return status_; }
  int RSSI() const { return -42; }
  void setStatus(int status) { status_ = status; }

 private:
  int status_ = WL_CONNECTED;
};

extern FakeWiFi WiFi;
