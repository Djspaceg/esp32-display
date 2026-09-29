#pragma once

#include <string>

#include "Arduino.h"

static constexpr int WL_CONNECTED = 3;

class FakeWiFi {
 public:
  IPAddress localIP() const { return IPAddress(); }
  int status() const { return status_; }
  // A hosted-RPC read on P4 (esp_wifi_sta_get_ap_info over ESP-Hosted), so
  // it is out of line: audio_host_fakes.cpp counts calls and can stall the
  // fake clock the way an unanswered co-processor request does.
  int RSSI() const;
  // Also RPCs on P4; counted with RSSI() in hostedRpcCalls().
  bool reconnect();
  bool disconnect();
  // Also an RPC on P4 (the joined AP's config); counted in ssidRpcCalls().
  String SSID() const;
  void setStatus(int status) { status_ = status; }
  void setSSID(const char *ssid) { ssid_ = ssid; }

 private:
  int status_ = WL_CONNECTED;
  std::string ssid_;
};

extern FakeWiFi WiFi;
