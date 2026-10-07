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
#include "esp_timer.h"
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
bool taskCreateFailing = false;
std::vector<audiohost::CreatedTask> createdTaskList;
int liveMutexCount = 0;
bool anyMutexMisuse = false;
unsigned taskYieldCalls = 0;
bool i2sFailing = false;
bool i2sDmaFailing = false;
bool i2sRxDmaFailing = false;
bool i2sChannelMisuse = false;
std::deque<UdpDatagram> udpDatagrams;
std::vector<audiohost::HardwareEvent> events;
std::vector<audiohost::SentDatagram> sentUdpDatagrams;
uint8_t activeWireAddress = 0;
uint32_t rssiStallMs = 0;
unsigned rssiCalls = 0;
unsigned linkCalls = 0;
unsigned ssidCalls = 0;
int rssiValue = -42;

struct FakeI2cDevice {
  bool present;
  uint8_t registers[256];
};
FakeI2cDevice i2cDevices[128] = {};
// The last value written to each register, -1 for never; kept apart from
// `registers` so a write cannot change what an ID read returns.
int writtenRegisters[128][256];
unsigned activeWireBytes = 0;
uint8_t activeWireRegister = 0;
int activeWireValue = -1;
unsigned registerWrites = 0;
int pendingRead = -1;

void installGenuineCodecs() {
  for (auto &device : i2cDevices) device = {};
  i2cDevices[0x18].present = true;
  i2cDevices[0x18].registers[0xFD] = 0x83;
  i2cDevices[0x18].registers[0xFE] = 0x11;
  i2cDevices[0x40].present = true;
  i2cDevices[0x40].registers[0x3D] = 0x72;
  i2cDevices[0x40].registers[0x3E] = 0x10;
}

// Tests that never call reset() still see the genuine parts.
const bool genuineCodecsInstalled = (installGenuineCodecs(), true);

}  // namespace

FakeSerial Serial;
FakeWiFi WiFi;
FakeMDNS MDNS;
TwoWire Wire;

uint32_t millis() { return nowMs; }
uint32_t micros() { return nowMs * 1000U; }
void delay(uint32_t milliseconds) { nowMs += milliseconds; }

int FakeWiFi::RSSI() const {
  rssiCalls++;
  nowMs += rssiStallMs;
  return rssiValue;
}

bool FakeWiFi::reconnect() {
  linkCalls++;
  nowMs += rssiStallMs;
  return true;
}

String FakeWiFi::SSID() const {
  ssidCalls++;
  nowMs += rssiStallMs;
  return String(ssid_.c_str());
}

bool FakeWiFi::disconnect() {
  linkCalls++;
  nowMs += rssiStallMs;
  return true;
}

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

BaseType_t xTaskCreatePinnedToCore(TaskFunction_t, const char *name,
                                  uint32_t, void *, UBaseType_t priority,
                                  TaskHandle_t *handle, BaseType_t core) {
  if (taskCreateFailing) return 0;  // pdFAIL
  createdTaskList.push_back({name, priority, core});
  if (handle != nullptr) *handle = reinterpret_cast<TaskHandle_t>(1);
  return pdPASS;
}

SemaphoreHandle_t xSemaphoreCreateMutex() {
  liveMutexCount++;
  return new int(0);  // the holder count
}

BaseType_t xSemaphoreTake(SemaphoreHandle_t semaphore, TickType_t) {
  int *held = static_cast<int *>(semaphore);
  if (held == nullptr || *held != 0) {
    anyMutexMisuse = true;
    return pdFALSE;
  }
  *held = 1;
  return pdTRUE;
}

BaseType_t xSemaphoreGive(SemaphoreHandle_t semaphore) {
  int *held = static_cast<int *>(semaphore);
  if (held == nullptr || *held != 1) {
    anyMutexMisuse = true;
    return pdFALSE;
  }
  *held = 0;
  return pdTRUE;
}

void vSemaphoreDelete(SemaphoreHandle_t semaphore) {
  liveMutexCount--;
  delete static_cast<int *>(semaphore);
}

int64_t esp_timer_get_time() { return (int64_t)nowMs * 1000; }

void vTaskDelete(TaskHandle_t) {}

void vTaskDelay(TickType_t) { taskDelayCalls++; }

void taskYIELD() { taskYieldCalls++; }

int lwip_socket(int, int, int) { return 1; }
int lwip_close(int) { return 0; }
int lwip_bind(int, const struct sockaddr *, socklen_t) { return 0; }
int lwip_setsockopt(int, int, int, const void *, socklen_t) { return 0; }

ssize_t lwip_sendto(int, const void *data, size_t length, int,
                    const struct sockaddr *target, socklen_t targetLength) {
  if (data == nullptr || target == nullptr ||
      targetLength < sizeof(sockaddr_in)) {
    return -1;
  }
  const auto *destination =
      reinterpret_cast<const sockaddr_in *>(target);
  const auto *bytes = static_cast<const uint8_t *>(data);
  sentUdpDatagrams.push_back({
      std::vector<uint8_t>(bytes, bytes + length),
      destination->sin_addr.s_addr,
      ntohs(destination->sin_port),
  });
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

// The fake port's one channel pair. Handles are addresses inside it, so a
// stale or doubly deleted handle is detectable rather than a crash.
struct FakeI2sChannel {
  bool allocated;
  bool enabled;
};
static FakeI2sChannel fakeI2sChannels[2] = {};

static bool fakeI2sHandleValid(i2s_chan_handle_t handle) {
  return handle == &fakeI2sChannels[0] || handle == &fakeI2sChannels[1];
}

int i2s_channel_disable(i2s_chan_handle_t handle) {
  if (!fakeI2sHandleValid(handle) || !handle->allocated) {
    i2sChannelMisuse = true;
    return -1;
  }
  if (!handle->enabled) return -1;  // "the channel has not been enabled yet"
  handle->enabled = false;
  return 0;
}

// Like the driver: a stale handle is misuse, and a running channel is refused.
int i2s_del_channel(i2s_chan_handle_t handle) {
  if (!fakeI2sHandleValid(handle) || !handle->allocated) {
    i2sChannelMisuse = true;
    return -1;
  }
  if (handle->enabled) {
    i2sChannelMisuse = true;
    return -1;
  }
  handle->allocated = false;
  return 0;
}

// Records the receive pin: -1 is a transmit-only channel.
void I2SClass::setPins(int8_t, int8_t, int8_t, int8_t din, int8_t) {
  events.push_back({audiohost::HardwareEventKind::I2sSetPins, din});
  capture_ = din >= 0;
}

bool I2SClass::begin(int, uint32_t sampleRateHz, int, i2s_slot_mode_t) {
  events.push_back(
      {audiohost::HardwareEventKind::I2sBegin, static_cast<int>(sampleRateHz)});
  begun_ = true;
  // i2s_new_channel: "no available channel found" while either half is held.
  if (fakeI2sChannels[0].allocated || fakeI2sChannels[1].allocated) {
    return false;
  }
  fakeI2sChannels[0].allocated = true;
  tx_ = &fakeI2sChannels[0];
  if (capture_) {
    fakeI2sChannels[1].allocated = true;
    rx_ = &fakeI2sChannels[1];
  }
  // The core configures and enables tx, then rx; a DMA descriptor failure
  // stops it at the first channel it hits, leaving the rest unenabled.
  if (i2sDmaFailing) return false;
  tx_->enabled = true;
  if (rx_ != nullptr) {
    if (i2sRxDmaFailing) return false;
    rx_->enabled = true;
  }
  return true;
}

size_t I2SClass::write(const void *, size_t bytes) {
  events.push_back(
      {audiohost::HardwareEventKind::I2sWrite, static_cast<int>(bytes)});
  return i2sFailing ? 0 : bytes;
}

size_t I2SClass::readBytes(char *data, size_t bytes) {
  std::memset(data, 0, bytes);
  return i2sFailing ? 0 : bytes;
}

// The core's end(): disable then delete each channel, returning at the first
// error, and clearing a handle only once it is deleted.
bool I2SClass::end() {
  events.push_back({audiohost::HardwareEventKind::I2sEnd, 0});
  if (!begun_) return true;
  begun_ = false;
  if (tx_ != nullptr) {
    if (i2s_channel_disable(tx_) != 0 || i2s_del_channel(tx_) != 0) {
      return false;
    }
    tx_ = nullptr;
  }
  if (rx_ != nullptr) {
    if (i2s_channel_disable(rx_) != 0 || i2s_del_channel(rx_) != 0) {
      return false;
    }
    rx_ = nullptr;
  }
  return true;
}

bool TwoWire::begin(int8_t sda, int8_t scl, uint32_t) {
  events.push_back({audiohost::HardwareEventKind::WireBegin, sda * 100 + scl});
  return true;
}

void TwoWire::beginTransmission(uint8_t address) {
  activeWireAddress = address;
  activeWireBytes = 0;
}

size_t TwoWire::write(uint8_t value) {
  if (activeWireBytes == 0) activeWireRegister = value;
  if (activeWireBytes == 1) activeWireValue = value;
  activeWireBytes++;
  return 1;
}

uint8_t TwoWire::endTransmission() {
  events.push_back(
      {audiohost::HardwareEventKind::WireTransmission, activeWireAddress});
  if (activeWireAddress >= 128 || !i2cDevices[activeWireAddress].present) {
    return 2;
  }
  if (activeWireBytes > 1) {
    registerWrites++;
    writtenRegisters[activeWireAddress][activeWireRegister] = activeWireValue;
  }
  return 0;
}

size_t TwoWire::requestFrom(uint8_t address, size_t length) {
  events.push_back({audiohost::HardwareEventKind::WireRequest, address});
  pendingRead = -1;
  if (address >= 128 || !i2cDevices[address].present || length != 1) {
    return 0;
  }
  pendingRead = i2cDevices[address].registers[activeWireRegister];
  return 1;
}

int TwoWire::read() {
  const int value = pendingRead;
  pendingRead = -1;
  return value;
}

namespace audiohost {

void reset() {
  nowMs = 0;
  taskDelayCalls = 0;
  taskCreateFailing = false;
  createdTaskList.clear();
  liveMutexCount = 0;
  anyMutexMisuse = false;
  taskYieldCalls = 0;
  udpDatagrams.clear();
  events.clear();
  sentUdpDatagrams.clear();
  activeWireAddress = 0;
  activeWireBytes = 0;
  activeWireRegister = 0;
  registerWrites = 0;
  activeWireValue = -1;
  for (auto &device : writtenRegisters) {
    for (int &value : device) value = -1;
  }
  pendingRead = -1;
  installGenuineCodecs();
  rssiStallMs = 0;
  rssiCalls = 0;
  linkCalls = 0;
  ssidCalls = 0;
  rssiValue = -42;
  i2sFailing = false;
  i2sDmaFailing = false;
  i2sRxDmaFailing = false;
  i2sChannelMisuse = false;
  for (auto &channel : fakeI2sChannels) channel = {};
  WiFi.setStatus(WL_CONNECTED);
}

void setI2sFailing(bool failing) { i2sFailing = failing; }
void setI2sDmaFailing(bool failing) { i2sDmaFailing = failing; }
void setI2sRxDmaFailing(bool failing) { i2sRxDmaFailing = failing; }
int liveI2sChannels() {
  return (fakeI2sChannels[0].allocated ? 1 : 0) +
         (fakeI2sChannels[1].allocated ? 1 : 0);
}
bool i2sChannelMisused() { return i2sChannelMisuse; }
unsigned i2sBeginCalls() {
  return (unsigned)std::count_if(events.begin(), events.end(), [](const audiohost::HardwareEvent &event) {
    return event.kind == audiohost::HardwareEventKind::I2sBegin;
  });
}

void setI2cDevice(uint8_t address, bool present, uint8_t idRegisterA,
                  uint8_t idA, uint8_t idRegisterB, uint8_t idB) {
  if (address >= 128) return;
  i2cDevices[address] = {};
  i2cDevices[address].present = present;
  i2cDevices[address].registers[idRegisterA] = idA;
  i2cDevices[address].registers[idRegisterB] = idB;
}

unsigned wireRegisterWrites() { return registerWrites; }

int lastRegisterWrite(uint8_t address, uint8_t reg) {
  return address < 128 ? writtenRegisters[address][reg] : -1;
}

void setMillis(uint32_t value) { nowMs = value; }

void enqueueUdp(const std::vector<uint8_t> &data, uint32_t remoteIp,
                uint16_t remotePort) {
  udpDatagrams.push_back({data, remoteIp, remotePort});
}

size_t pendingUdp() { return udpDatagrams.size(); }
unsigned delayCalls() { return taskDelayCalls; }
void setTaskCreateFailing(bool failing) { taskCreateFailing = failing; }
const std::vector<CreatedTask> &createdTasks() { return createdTaskList; }
int liveMutexes() { return liveMutexCount; }
bool mutexMisuse() { return anyMutexMisuse; }
unsigned yieldCalls() { return taskYieldCalls; }
const std::vector<HardwareEvent> &hardwareEvents() { return events; }
const std::vector<SentDatagram> &sentDatagrams() {
  return sentUdpDatagrams;
}
void setRssiRpcStallMs(uint32_t value) { rssiStallMs = value; }
unsigned rssiRpcCalls() { return rssiCalls; }
unsigned linkRpcCalls() { return linkCalls; }
unsigned ssidRpcCalls() { return ssidCalls; }
void setRssiValue(int value) { rssiValue = value; }

}  // namespace audiohost

String cfgSsid;
String cfgPass;
uint8_t wifiCredentialPresetSlot = 0;
bool wifiLegacyMirrorPending = false;
String cfgName("audio-host");
const char *FW_VERSION = "host";
const char *FW_SOURCE = "unknown";
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
