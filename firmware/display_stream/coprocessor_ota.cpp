#include "coprocessor_ota.h"

#include <Arduino.h>

#if defined(CONFIG_ESP_HOSTED_ENABLED)
#include <HTTPClient.h>
#include <NetworkClientSecure.h>
#include <mbedtls/sha256.h>

#include "esp32-hal-hosted.h"
#include "serial_out.h"

namespace coprocessorota {

// 12 KB covers the TLS handshake; the TLS context itself is on the heap.
static constexpr uint32_t TASK_STACK = 12288;
static constexpr UBaseType_t TASK_PRIORITY = 1;
// No byte for this long ends the transfer unfinalized.
static constexpr uint32_t STALL_MS = 15000;

static volatile bool updateRunning = false;
static const coprocessor::Image *pending = nullptr;
static uint32_t pendingHost = 0;

// coprocessor::runTransfer's Port over the HTTPS body and ESP-Hosted's OTA.
class HostedPort {
 public:
  explicit HostedPort(NetworkClient &stream) : stream_(stream) {
    mbedtls_sha256_init(&sha_);
    mbedtls_sha256_starts(&sha_, 0);
  }
  ~HostedPort() { mbedtls_sha256_free(&sha_); }

  bool begin() { return hostedBeginUpdate(); }
  int read(uint8_t *buf, size_t want) {
    if (!stream_.connected() && stream_.available() == 0) return -1;
    // readBytes waits up to the stream timeout to fill the whole chunk.
    const size_t got = stream_.readBytes(buf, want);
    if (got > 0) lastByteAt_ = millis();
    return (int)got;
  }
  bool stalled() { return millis() - lastByteAt_ > STALL_MS; }
  void digest(const uint8_t *data, size_t len) {
    mbedtls_sha256_update(&sha_, data, len);
  }
  void digestHex(char out[65]) {
    uint8_t digest[32];
    mbedtls_sha256_finish(&sha_, digest);
    for (int i = 0; i < 32; i++) snprintf(out + 2 * i, 3, "%02x", digest[i]);
    serialout::printfLine(Serial, "C6UPDATE sha256=%s", out);
  }
  bool write(const uint8_t *data, size_t len) {
    return hostedWriteUpdate(const_cast<uint8_t *>(data), len);
  }
  void progress(uint32_t written, uint32_t total) {
    if (written - lastReport_ < 131072 && written != total) return;
    lastReport_ = written;
    serialout::printfLine(Serial, "C6UPDATE %lu/%lu", (unsigned long)written,
                          (unsigned long)total);
  }
  bool end() { return hostedEndUpdate(); }
  bool activate() { return hostedActivateUpdate(); }

 private:
  NetworkClient &stream_;
  mbedtls_sha256_context sha_;
  uint32_t lastByteAt_ = millis();
  uint32_t lastReport_ = 0;
};

// Asks the coprocessor again, on this task: a version request missed at boot
// reads as Unreported, and a newer coprocessor must never be downgraded.
static bool stillOlder(uint32_t hostVersion) {
  hostedHasUpdate();
  uint32_t major = 0, minor = 0, patch = 0;
  hostedGetSlaveVersion(&major, &minor, &patch);
  const uint32_t cp = coprocessor::version(major, minor, patch);
  return coprocessor::needsUpdate(
      coprocessor::classify(hostVersion, cp != 0, cp));
}

static coprocessor::TransferOutcome download(const coprocessor::Image &image) {
  NetworkClientSecure client;
  // The connection is not what is trusted: the pinned length and SHA-256
  // are, and nothing is finalized without them.
  client.setInsecure();
  HTTPClient https;
  if (!https.begin(client, image.url)) {
    serialout::printfLine(Serial, "C6UPDATE ERR could not open %s", image.url);
    return coprocessor::TransferOutcome::Stalled;
  }
  const int code = https.GET();
  const int length = https.getSize();
  serialout::printfLine(Serial, "C6UPDATE http=%d length=%d", code, length);
  if (code != HTTP_CODE_OK || length != (int)image.length) {
    https.end();
    return coprocessor::TransferOutcome::Rejected;
  }
  HostedPort port(*https.getStreamPtr());
  const coprocessor::TransferOutcome outcome =
      coprocessor::runTransfer(image, port);
  https.end();
  return outcome;
}

static void updateTask(void *) {
  const coprocessor::Image &image = *pending;
  if (!stillOlder(pendingHost)) {
    serialout::printfLine(
        Serial, "C6UPDATE ERR coprocessor now reports a current or newer "
                "version; nothing written");
    updateRunning = false;
    vTaskDelete(nullptr);
    return;
  }
  serialout::printfLine(Serial, "C6UPDATE from %s", image.url);
  const coprocessor::TransferOutcome outcome = download(image);
  if (outcome == coprocessor::TransferOutcome::Installed) {
    serialout::printfLine(
        Serial, "C6UPDATE OK; restarting (the host boot resets the C6)");
  } else {
    serialout::printfLine(Serial, "C6UPDATE ERR %s",
                          coprocessor::outcomeText(outcome));
  }
  if (outcome == coprocessor::TransferOutcome::Installed ||
      outcome == coprocessor::TransferOutcome::ActivateFailed) {
    // Activation silences the SDIO driver's logs for this session and the
    // coprocessor may already be resetting; a clean boot is the only safe
    // next state either way.
    Serial.flush();
    delay(500);
    ESP.restart();
  }
  updateRunning = false;
  vTaskDelete(nullptr);
}

const char *start(const coprocessor::Image &image, uint32_t hostVersion) {
  if (updateRunning) return "an update is already running";
  updateRunning = true;
  pending = &image;
  pendingHost = hostVersion;
  if (xTaskCreate(updateTask, "c6update", TASK_STACK, nullptr, TASK_PRIORITY,
                  nullptr) != pdPASS) {
    updateRunning = false;
    return "could not start the update task";
  }
  return nullptr;
}

bool running() { return updateRunning; }

}  // namespace coprocessorota

#endif
