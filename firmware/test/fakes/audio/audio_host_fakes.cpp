#include "audio_host_fakes.h"

#include <algorithm>
#include <cstring>
#include <deque>
#include <vector>

#include "Arduino.h"
#include "ESP_I2S.h"
#include "ESPmDNS.h"
#include "WiFi.h"
#include "Wire.h"
#include "lwip/sockets.h"

#include "../../../display_stream/app_state.h"
#include "../../../display_stream/control_apply.h"
#include "../../../display_stream/display_power.h"
#include "../../../display_stream/frame_pipeline.h"
#include "../../../display_stream/orientation.h"
#include "../../../display_stream/ota_service.h"

namespace {

struct FakeQueue {
  size_t depth;
  size_t itemSize;
  std::deque<std::vector<uint8_t>> items;
};

struct UdpDatagram {
  std::vector<uint8_t> data;
  uint32_t remoteIp;
  uint16_t remotePort;
};

uint32_t nowMs = 0;
unsigned taskDelayCalls = 0;
unsigned taskYieldCalls = 0;
std::deque<UdpDatagram> udpDatagrams;
std::vector<audiohost::HardwareEvent> events;
uint8_t activeWireAddress = 0;

}  // namespace

FakeSerial Serial;
FakeWiFi WiFi;
FakeMDNS MDNS;
TwoWire Wire;

uint32_t millis() { return nowMs; }
uint32_t micros() { return nowMs * 1000U; }
void delay(uint32_t milliseconds) { nowMs += milliseconds; }

void pinMode(int pin, int) {
  events.push_back({audiohost::HardwareEventKind::PinMode, pin});
}

void digitalWrite(int pin, int value) {
  events.push_back(
      {audiohost::HardwareEventKind::DigitalWrite, pin * 10 + value});
}

QueueHandle_t xQueueCreate(UBaseType_t depth, UBaseType_t itemSize) {
  return new FakeQueue{depth, itemSize, {}};
}

BaseType_t xQueueSend(QueueHandle_t handle, const void *item, TickType_t) {
  auto *queue = static_cast<FakeQueue *>(handle);
  if (queue == nullptr || queue->items.size() >= queue->depth) return pdFALSE;
  const auto *bytes = static_cast<const uint8_t *>(item);
  queue->items.emplace_back(bytes, bytes + queue->itemSize);
  return pdTRUE;
}

BaseType_t xQueueReceive(QueueHandle_t handle, void *item, TickType_t) {
  auto *queue = static_cast<FakeQueue *>(handle);
  if (queue == nullptr || queue->items.empty()) return pdFALSE;
  std::memcpy(item, queue->items.front().data(), queue->itemSize);
  queue->items.pop_front();
  return pdTRUE;
}

void vQueueDelete(QueueHandle_t handle) {
  delete static_cast<FakeQueue *>(handle);
}

BaseType_t xTaskCreatePinnedToCore(TaskFunction_t, const char *, uint32_t,
                                  void *, UBaseType_t, TaskHandle_t *handle,
                                  BaseType_t) {
  if (handle != nullptr) *handle = reinterpret_cast<TaskHandle_t>(1);
  return pdPASS;
}

void vTaskDelete(TaskHandle_t) {}

void vTaskDelay(TickType_t) { taskDelayCalls++; }

void taskYIELD() { taskYieldCalls++; }

int lwip_socket(int, int, int) { return 1; }
int lwip_close(int) { return 0; }
int lwip_bind(int, const struct sockaddr *, socklen_t) { return 0; }
int lwip_setsockopt(int, int, int, const void *, socklen_t) { return 0; }

ssize_t lwip_sendto(int, const void *, size_t length, int,
                    const struct sockaddr *, socklen_t) {
  return static_cast<ssize_t>(length);
}

int lwip_recvfrom(int, void *buffer, size_t capacity, int,
                  struct sockaddr *source, socklen_t *sourceLength) {
  if (udpDatagrams.empty()) return -1;
  UdpDatagram datagram = udpDatagrams.front();
  udpDatagrams.pop_front();
  const size_t copied = std::min(capacity, datagram.data.size());
  std::memcpy(buffer, datagram.data.data(), copied);
  if (source != nullptr && sourceLength != nullptr &&
      *sourceLength >= sizeof(sockaddr_in)) {
    auto *from = reinterpret_cast<sockaddr_in *>(source);
    std::memset(from, 0, sizeof(*from));
    from->sin_family = AF_INET;
    from->sin_addr.s_addr = datagram.remoteIp;
    from->sin_port = htons(datagram.remotePort);
    *sourceLength = sizeof(*from);
  }
  return static_cast<int>(copied);
}

void I2SClass::setPins(int8_t, int8_t, int8_t, int8_t, int8_t) {
  events.push_back({audiohost::HardwareEventKind::I2sSetPins, 0});
}

bool I2SClass::begin(int, uint32_t sampleRateHz, int, i2s_slot_mode_t) {
  events.push_back(
      {audiohost::HardwareEventKind::I2sBegin, static_cast<int>(sampleRateHz)});
  return true;
}

size_t I2SClass::write(const void *, size_t bytes) {
  events.push_back(
      {audiohost::HardwareEventKind::I2sWrite, static_cast<int>(bytes)});
  return bytes;
}

size_t I2SClass::readBytes(char *data, size_t bytes) {
  std::memset(data, 0, bytes);
  return bytes;
}

void I2SClass::end() {
  events.push_back({audiohost::HardwareEventKind::I2sEnd, 0});
}

bool TwoWire::begin(int8_t, int8_t, uint32_t) {
  events.push_back({audiohost::HardwareEventKind::WireBegin, 0});
  return true;
}

void TwoWire::beginTransmission(uint8_t address) {
  activeWireAddress = address;
}

size_t TwoWire::write(uint8_t) { return 1; }

uint8_t TwoWire::endTransmission() {
  events.push_back(
      {audiohost::HardwareEventKind::WireTransmission, activeWireAddress});
  return 0;
}

namespace audiohost {

void reset() {
  nowMs = 0;
  taskDelayCalls = 0;
  taskYieldCalls = 0;
  udpDatagrams.clear();
  events.clear();
  activeWireAddress = 0;
}

void setMillis(uint32_t value) { nowMs = value; }

void enqueueUdp(const std::vector<uint8_t> &data, uint32_t remoteIp,
                uint16_t remotePort) {
  udpDatagrams.push_back({data, remoteIp, remotePort});
}

size_t pendingUdp() { return udpDatagrams.size(); }
unsigned delayCalls() { return taskDelayCalls; }
unsigned yieldCalls() { return taskYieldCalls; }
const std::vector<HardwareEvent> &hardwareEvents() { return events; }

}  // namespace audiohost

String cfgSsid;
String cfgPass;
uint8_t wifiCredentialPresetSlot = 0;
bool wifiLegacyMirrorPending = false;
String cfgName("audio-host");
const char *FW_VERSION = "host";
uint8_t deviceId[6] = {};
board::Variant boardVariant = board::Variant::AmoledCo5300;
const board::Config *bcfg = &board::CONFIG_AMOLED_CO5300;
bandproto::Geometry PANEL_GEOMETRY = {466, 466};
int16_t PANEL_W = 466;
int16_t PANEL_H = 466;
size_t FRAME_BYTES = 466U * 466U * 2U;
const uint16_t UDP_PORT = 5568;
esp_lcd_panel_handle_t panel = nullptr;
bool touchAvailable = false;
touchmap::Calibration touchCalibration = touchmap::CST9217_ON_CO5300;
bool batteryAvailable = false;
bool audioAvailable = true;
volatile uint32_t statFramesShown = 0;
volatile uint32_t statFramesDropped = 0;
volatile uint32_t statFramesPartial = 0;
volatile uint32_t statPackets = 0;
volatile uint32_t statBadLen = 0;
volatile uint32_t statDrawErrors = 0;

bool tileStreamEnabled() { return true; }
bool largeTileStreamEnabled() { return false; }

portMUX_TYPE controlMux;
controlq::ControlQueue controls;
deviceproto::IdleTextMessage idleText = {};
uint32_t idleTextAt = 0;
deviceproto::IdleTextMessage lastSavedIdleText = {};
uint32_t restartAt = 0;

uint8_t fixedBlLevel = 0;
uint8_t panelRotation = 0;
bool displaySleeping = false;
bool idleActive = false;
bool panelManuallyOff = false;
volatile uint32_t lastSenderPacketAt = 0;
volatile bool sleepRequested = false;
volatile bool wakeRequested = false;

uint8_t currentBrightness() { return 100; }
bool blIsHigh() { return true; }

bool applyBandPayload(const bandproto::Header &, bool, const uint8_t *, size_t,
                      bool) {
  return true;
}

void handleTilePacket(const uint8_t *, size_t) {}

const uint16_t OTA_PORT = 3232;
bool otaConfigured = false;
bool otaActive = false;
volatile bool otaInProgress = false;

otapolicy::Status currentOtaStatus() {
  return otapolicy::status(otaActive, otaConfigured);
}
