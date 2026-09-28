#pragma once

#include <string>

#include "Arduino.h"

static constexpr int WL_CONNECTED = 3;

class FakeWiFi {
 public:
  IPAddress localIP() const { return IPAddress(); }
  int status() const { return status_; }
  int RSSI() const { return -42; }
  String SSID() const { return String(ssid_.c_str()); }
  void setStatus(int status) { status_ = status; }
  void setSSID(const char *ssid) { ssid_ = ssid; }

 private:
  int status_ = WL_CONNECTED;
  std::string ssid_;
};

extern FakeWiFi WiFi;
