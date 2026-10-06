#include "wifi_worker.h"

#include <Arduino.h>
#include <WiFi.h>
#include <string.h>

namespace wifiworker {

enum class Request : uint8_t { Reconnect, Reassociate };

static QueueHandle_t requests = nullptr;
static bool running = false;
static portMUX_TYPE stateMux = portMUX_INITIALIZER_UNLOCKED;
static int lastRssi = 0;
static uint32_t lastRssiAt = 0;
static bool haveRssi = false;
static bool reconnectDone = false;
static bool reconnectAccepted = false;
static uint32_t lastPollAt = 0;
static bool polledOnce = false;
// While associated: the later of the last RSSI answer and the association.
static bool associated = false;
static uint32_t lastAnswerAt = 0;
// The joined network's SSID for this association; 32 bytes is the 802.11
// maximum.
static char lastSsid[33] = "";
static bool haveSsid = false;
// A read is owed: set on each association and after every request run here
// (a reconnect can change the network without the status poll seeing a drop).
static bool ssidOwed = false;
static uint32_t lastSsidAttemptAt = 0;
static bool ssidAttempted = false;

// loopTask's priority, pinned to core 0 (the other core on dual-core chips):
// the worker spends most of its life blocked in an RPC wait.
static constexpr uint32_t TASK_STACK = 4096;
static constexpr UBaseType_t TASK_PRIORITY = 1;
static constexpr BaseType_t TASK_CORE = 0;
static constexpr UBaseType_t QUEUE_DEPTH = 4;

static void workerTask(void *) {
  for (;;) serviceOnce(RSSI_POLL_MS);
}

bool start() {
  if (running) return true;
  requests = xQueueCreate(QUEUE_DEPTH, sizeof(Request));
  if (requests == nullptr) return false;
  if (xTaskCreatePinnedToCore(workerTask, "wifiwork", TASK_STACK, nullptr,
                              TASK_PRIORITY, nullptr, TASK_CORE) != pdPASS) {
    vQueueDelete(requests);
    requests = nullptr;
    return false;
  }
  running = true;
  return true;
}

int rssi() {
  portENTER_CRITICAL(&stateMux);
  const bool have = haveRssi;
  const int value = lastRssi;
  const uint32_t at = lastRssiAt;
  portEXIT_CRITICAL(&stateMux);
  if (!have || (uint32_t)(millis() - at) > RSSI_STALE_MS) return 0;
  return value;
}

bool ssid(char *out, size_t len) {
  if (len == 0) return false;
  if (!running) {
    // No worker (start() failed, or setup() before it starts): read it here.
    if (WiFi.status() != WL_CONNECTED) {
      out[0] = 0;
      return false;
    }
    strncpy(out, WiFi.SSID().c_str(), len - 1);
    out[len - 1] = 0;
    return true;
  }
  portENTER_CRITICAL(&stateMux);
  const bool have = haveSsid;
  strncpy(out, have ? lastSsid : "", len - 1);
  portEXIT_CRITICAL(&stateMux);
  out[len - 1] = 0;
  return have;
}

bool lastAnswerAgeMs(uint32_t now, uint32_t &ageMs) {
  portENTER_CRITICAL(&stateMux);
  const bool linked = associated;
  const uint32_t at = lastAnswerAt;
  portEXIT_CRITICAL(&stateMux);
  // The worker on the other core can store an answer newer than the
  // caller's now; that is an age of zero, not a wrap to ~49 days.
  const int32_t age = (int32_t)(now - at);
  ageMs = linked && age > 0 ? (uint32_t)age : 0;
  return linked;
}

bool coprocessorSilent() {
  portENTER_CRITICAL(&stateMux);
  const bool linked = associated;
  const uint32_t at = lastAnswerAt;
  portEXIT_CRITICAL(&stateMux);
  return linked && (uint32_t)(millis() - at) > COPROCESSOR_SILENT_MS;
}

static void run(Request request) {
  if (request == Request::Reassociate) {
    WiFi.disconnect();
    WiFi.reconnect();
    return;
  }
  const bool accepted = WiFi.reconnect();
  portENTER_CRITICAL(&stateMux);
  reconnectDone = true;
  reconnectAccepted = accepted;
  portEXIT_CRITICAL(&stateMux);
}

static void post(Request request) {
  if (!running) {
    // No worker (start() failed): blocking here beats never reconnecting,
    // since auto-reconnect is off and nothing else would retry.
    run(request);
    return;
  }
  // A full queue means the worker is already stuck on a silent C6 with work
  // queued behind it; one more of the same request would add nothing.
  xQueueSend(requests, &request, 0);
}

void requestReconnect() { post(Request::Reconnect); }
void requestReassociate() { post(Request::Reassociate); }

bool takeReconnectResult(bool &accepted) {
  portENTER_CRITICAL(&stateMux);
  const bool done = reconnectDone;
  accepted = reconnectAccepted;
  reconnectDone = false;
  portEXIT_CRITICAL(&stateMux);
  return done;
}

// Only after an RSSI answer, so a silent C6 is not asked for the SSID too;
// and a failed read is retried SSID_POLL_MS later, not on every pass.
static void readSsidIfOwed() {
  if (!ssidOwed) return;
  const uint32_t now = millis();
  if (ssidAttempted && (uint32_t)(now - lastSsidAttemptAt) < SSID_POLL_MS) return;
  const String joined = WiFi.SSID();
  // Timed from the answer, so a stalled RPC's wait is not counted as the gap.
  ssidAttempted = true;
  lastSsidAttemptAt = millis();
  // Empty is a failed RPC or a link going down: keep what this association
  // already read, and stay owed.
  if (joined.c_str()[0] == 0) return;
  ssidOwed = false;
  portENTER_CRITICAL(&stateMux);
  strncpy(lastSsid, joined.c_str(), sizeof(lastSsid) - 1);
  lastSsid[sizeof(lastSsid) - 1] = 0;
  haveSsid = true;
  portEXIT_CRITICAL(&stateMux);
}

void serviceOnce(uint32_t waitMs) {
  Request request;
  if (requests != nullptr &&
      xQueueReceive(requests, &request, pdMS_TO_TICKS(waitMs)) == pdTRUE) {
    run(request);
    ssidOwed = true;
    ssidAttempted = false;
  }
  const uint32_t now = millis();
  if (WiFi.status() != WL_CONNECTED) {
    // Not associated: no sample describes this link, and the next
    // association must not inherit the last one's reading.
    portENTER_CRITICAL(&stateMux);
    associated = false;
    haveRssi = false;
    haveSsid = false;
    lastSsid[0] = 0;
    portEXIT_CRITICAL(&stateMux);
    return;
  }
  portENTER_CRITICAL(&stateMux);
  if (!associated) {
    associated = true;
    lastAnswerAt = now;
    ssidOwed = true;
    ssidAttempted = false;
  }
  portEXIT_CRITICAL(&stateMux);
  if (polledOnce && (uint32_t)(now - lastPollAt) < RSSI_POLL_MS) return;
  polledOnce = true;
  lastPollAt = now;
  const int value = WiFi.RSSI();
  if (value == 0) return;  // the RPC failed; keep the last good sample
  portENTER_CRITICAL(&stateMux);
  lastRssi = value;
  lastRssiAt = millis();
  lastAnswerAt = lastRssiAt;
  haveRssi = true;
  portEXIT_CRITICAL(&stateMux);
  readSsidIfOwed();
}

}  // namespace wifiworker
