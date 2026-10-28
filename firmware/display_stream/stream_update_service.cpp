#include "stream_update_service.h"

#include <Arduino.h>
#include <PBKDF2_HMACBuilder.h>
#include <SHA2Builder.h>
#include <Update.h>

#include <atomic>

#include <esp_heap_caps.h>
#include <esp_ota_ops.h>
#include <esp_random.h>
#include <esp_task_wdt.h>
#include <freertos/semphr.h>
#include <mbedtls/sha256.h>

#include "app_state.h"
#include "display_power.h"
#include "net_link.h"
#include "ota_policy.h"
#include "stream_update.h"
#include "stream_update_flash.h"
#include "ui_screens.h"

namespace streamupdatesvc {

using streamupdate::Phase;
using streamupdate::Status;
using streamupdate::Work;

namespace {

class MbedHasher : public streamupdate::Hasher {
 public:
  MbedHasher() { mbedtls_sha256_init(&ctx_); }
  void reset() override {
    mbedtls_sha256_free(&ctx_);
    mbedtls_sha256_init(&ctx_);
    mbedtls_sha256_starts(&ctx_, 0);
  }
  void update(const uint8_t *data, size_t len) override {
    mbedtls_sha256_update(&ctx_, data, len);
  }
  void finish(uint8_t out[streamupdate::SHA256_BYTES]) override {
    mbedtls_sha256_finish(&ctx_, out);
  }

 private:
  mbedtls_sha256_context ctx_;
};

// How many chunks may wait in RAM ahead of flash. 64 x 1440 = 90 KB covers a
// 64 KB block erase with the link still running (SPI panels still erase as
// the writes go; stream_update_flash.h); PSRAM where there is any.
// Without PSRAM (C3, C6) fewer, so streaming's buffers keep their headroom.
constexpr uint16_t SLOTS_PSRAM = 64;
constexpr uint16_t SLOTS_INTERNAL = 24;
// The loop does this much update work per pass before returning, so the
// heartbeat and EINF timers keep running and the watchdog keeps being fed.
constexpr uint32_t SERVICE_BUDGET_MS = 25;

streamupdate::Receiver rx;
MbedHasher hasher;
SemaphoreHandle_t lock = nullptr;
uint8_t *slotMemory = nullptr;
bool configured = false;

// The inactive app partition, written directly rather than through Update so
// the whole image area can be erased before the progress screen is up. Why,
// and why the first byte goes last: stream_update_flash.h.
class PartitionSink : public streamupdate::FlashSink {
 public:
  const esp_partition_t *partition = nullptr;
  bool erase(uint32_t offset, uint32_t length) override {
    return esp_partition_erase_range(partition, offset, length) == ESP_OK;
  }
  bool write(uint32_t offset, const uint8_t *data, size_t length) override {
    return esp_partition_write(partition, offset, data, length) == ESP_OK;
  }
};
PartitionSink partitionSink;
streamupdate::FlashImageWriter image;
// A begun image whose erase is still running, one step per service() pass so
// loop() keeps feeding the watchdog and the heartbeat between steps. The
// receiver hears about the begin only once the erase is done.
struct PendingBegin {
  bool active = false;
  uint8_t *memory = nullptr;
  uint16_t slots = 0;
  uint32_t startedMs = 0;
};
PendingBegin pendingBegin;
// True from a successful begin until activation or abort: this update owns
// the inactive partition, as Update.isRunning() says for ArduinoOTA's. The
// reverse needs no flag: while this receiver owns the panel, loop() returns
// before ArduinoOTA.handle() can begin anything.
bool imageOpen = false;

// The P4's DSI refresh stops while flash is erased (stream_update_flash.h),
// and its panel shows a blank cyan field until it resumes. Dark is better.
bool panelBlanksDuringFlashErase() { return bcfg->isDsi(); }
// rx.ownsPanel(), republished on every unlock so the frame path - every
// inbound frame datagram asks - reads a flag instead of taking the mutex.
std::atomic<bool> panelOwned{false};

// What the screen and the serial line last said, so each says it once.
Phase shownPhase = Phase::Idle;
int shownPercent = -1;
uint32_t startedAtMs = 0;
uint32_t receivingAtMs = 0;
otapolicy::SavedPanelState savedPanel;

struct Lock {
  Lock() { xSemaphoreTake(lock, portMAX_DELAY); }
  ~Lock() {
    panelOwned.store(rx.ownsPanel(), std::memory_order_relaxed);
    xSemaphoreGive(lock);
  }
};

void ensureConfigured() {
  if (configured) return;
  lock = xSemaphoreCreateMutex();
  const esp_partition_t *next = esp_ota_get_next_update_partition(nullptr);
  const uint16_t slots =
      psramFound() ? SLOTS_PSRAM : SLOTS_INTERNAL;
  rx.configure(next != nullptr ? next->size : 0, slots, &hasher);
  configured = true;
}

// Send whatever the receiver queued, outside the lock.
void flushOutgoing() {
  streamupdate::Receiver::Outgoing out[streamupdate::Receiver::OUTBOX_DEPTH];
  size_t n = 0;
  {
    Lock held;
    while (n < streamupdate::Receiver::OUTBOX_DEPTH && rx.popOutgoing(out[n])) {
      n++;
    }
  }
  for (size_t i = 0; i < n; i++) {
    sendToEndpoint(out[i].to.ip, out[i].to.port, out[i].bytes, out[i].len);
  }
}

bool verifyResponse(const streamupdate::WorkItem &w) {
  // The cnonce must commit to the image the BEGIN named (cnonceSeed).
  char seed[2 * streamupdate::HEX_DIGEST_CHARS + 2];
  if (streamupdate::cnonceSeed(seed, sizeof(seed), w.expectedHex, w.nonce) == 0) {
    return false;
  }
  SHA256Builder seedHash;
  seedHash.begin();
  seedHash.add(seed);
  seedHash.calculate();
  const String seedHex = seedHash.toString();
  if (seedHex.length() != streamupdate::HEX_DIGEST_CHARS ||
      !streamupdate::sameDigestHex(seedHex.c_str(), w.cnonce)) {
    return false;
  }
  char salt[2 * streamupdate::HEX_DIGEST_CHARS + 2];
  if (streamupdate::authSalt(salt, sizeof(salt), w.nonce, w.cnonce) == 0) {
    return false;
  }
  // ArduinoOTA's derivation, line for line (ArduinoOTA.cpp:290-305).
  SHA256Builder sha256;
  PBKDF2_HMACBuilder pbkdf2(&sha256, String(rx.passwordHash()), String(salt),
                            streamupdate::PBKDF2_ITERATIONS);
  pbkdf2.begin();
  pbkdf2.calculate();
  const String derived = pbkdf2.toString();
  char challenge[3 * streamupdate::HEX_DIGEST_CHARS + 3];
  if (derived.length() != streamupdate::HEX_DIGEST_CHARS ||
      streamupdate::authChallenge(challenge, sizeof(challenge), derived.c_str(),
                                  w.nonce, w.cnonce) == 0) {
    return false;
  }
  SHA256Builder expected;
  expected.begin();
  expected.add(challenge);
  expected.calculate();
  const String expectedHex = expected.toString();
  return expectedHex.length() == streamupdate::HEX_DIGEST_CHARS &&
         streamupdate::sameDigestHex(expectedHex.c_str(), w.response);
}

uint8_t *allocateSlots(uint16_t slots, uint16_t slotBytes) {
  const size_t bytes = (size_t)slots * slotBytes;
  uint8_t *memory = nullptr;
  if (psramFound()) {
    memory = (uint8_t *)heap_caps_malloc(bytes, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
  }
  if (memory == nullptr) {
    memory = (uint8_t *)heap_caps_malloc(bytes, MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
  }
  return memory;
}

void freeSlotsIfUnused() {
  if (slotMemory == nullptr) return;
  bool inUse;
  {
    Lock held;
    inUse = rx.usingSlots();
  }
  if (!inUse) {
    heap_caps_free(slotMemory);
    slotMemory = nullptr;
  }
}

const char *statusWord(Status s) {
  switch (s) {
    case Status::AuthRefused:
      return "bad password";
    case Status::BeginFailed:
      return "no free slot";
    case Status::WriteFailed:
      return "flash failed";
    case Status::HashMismatch:
      return "sha256 failed";
    case Status::ImageRefused:
      return "image refused";
    case Status::Activated:
      return "rebooting";
    case Status::Aborted:
      return "cancelled";
    default:
      return "failed";
  }
}

// One unit of loop-side work, outside the lock. Returns false when idle.
bool doOneWork() {
  streamupdate::WorkItem w;
  // The digest is copied here, under the lock, for the log line below.
  char digestHex[streamupdate::HEX_DIGEST_CHARS + 1] = {};
  {
    Lock held;
    // The clock is read under the lock, so no chunk filed by the receive task
    // can carry a later stamp than this "now" (elapsedMs guards it anyway).
    w = rx.takeWork(millis());
    if (w.kind == Work::Activate) {
      memcpy(digestHex, rx.actualHex(), sizeof(digestHex));
    }
  }
  switch (w.kind) {
    case Work::None:
      return false;
    case Work::VerifyAuth: {
      const bool ok = verifyResponse(w);
      Serial.printf("supd: auth %s\n", ok ? "ok" : "refused (wrong password)");
      Lock held;
      rx.finishAuth(ok, millis());
      break;
    }
    case Work::Begin: {
      const char *error = nullptr;
      uint8_t *memory = nullptr;
      bool ok = false;
      const esp_partition_t *next = esp_ota_get_next_update_partition(nullptr);
      if (Update.isRunning() || imageOpen) {
        error = "another update is running";
      } else if (next == nullptr || w.imageBytes > next->size) {
        error = "no update partition large enough";
      } else if ((memory = allocateSlots(w.slots, w.slotBytes)) == nullptr) {
        error = "not enough memory for the receive window";
      } else {
        ok = true;
      }
      if (!ok) {
        Serial.printf("supd: begin refused: %s\n", error);
        Lock held;
        rx.finishBegin(false, error, nullptr, w.slots, millis());
        break;
      }
      partitionSink.partition = next;
      image.start(&partitionSink, w.imageBytes, panelBlanksDuringFlashErase());
      imageOpen = true;
      pendingBegin.active = true;
      pendingBegin.memory = memory;
      pendingBegin.slots = w.slots;
      pendingBegin.startedMs = millis();
      if (panelBlanksDuringFlashErase()) driveBrightness(0);
      Serial.printf("supd: opening %lu bytes of %s (window %u x %u)\n",
                    (unsigned long)w.imageBytes, next->label,
                    (unsigned)w.slots, (unsigned)w.slotBytes);
      break;
    }
    case Work::Write: {
      const bool ok = image.write(w.data, w.len);
      Lock held;
      rx.finishWrite(w.seq, ok, ok ? nullptr : "flash write failed", millis());
      break;
    }
    case Work::Activate: {
      Serial.printf("supd: sha256 match %s\n", digestHex);
      const char *error = nullptr;
      bool ok = image.finish();
      if (!ok) {
        error = "flash write failed";
      } else {
        // Choosing the boot partition erases a sector of otadata, and the
        // reboot follows: both would show the cyan field, so go dark first.
        if (panelBlanksDuringFlashErase()) driveBrightness(0);
        // This also verifies the image (esp_image_verify) before choosing it.
        const esp_err_t err = esp_ota_set_boot_partition(partitionSink.partition);
        ok = err == ESP_OK;
        if (!ok) {
          error = esp_err_to_name(err);
          applyBacklight();
        }
      }
      image.close();
      imageOpen = false;
      if (!ok) Serial.printf("supd: activation refused: %s\n", error);
      Lock held;
      rx.finishActivate(ok, error, millis());
      break;
    }
    case Work::Abort: {
      // Nothing to undo: an image whose first byte was never written is not
      // a valid image, and the boot partition has not changed.
      image.close();
      imageOpen = false;
      Lock held;
      rx.finishAbort(millis());
      break;
    }
  }
  esp_task_wdt_reset();
  return true;
}

// Screen and serial follow the receiver's phase; nothing here decides.
void reflectState(uint32_t now) {
  Phase phase;
  uint32_t written, total;
  bool hasResult;
  Status result;
  char detail[streamupdate::STATUS_DETAIL_MAX + 1];
  uint16_t session;
  streamupdate::Endpoint peer;
  streamupdate::Stats stats;
  bool matched;
  char expectedHex[65], actualHex[65];
  {
    Lock held;
    phase = rx.phase();
    written = rx.bytesWritten();
    total = rx.imageBytes();
    hasResult = rx.hasResult();
    result = rx.result();
    strncpy(detail, rx.resultDetail(), sizeof(detail));
    detail[sizeof(detail) - 1] = '\0';
    session = rx.session();
    peer = rx.peer();
    stats = rx.stats();
    matched = rx.digestMatched();
    memcpy(expectedHex, rx.expectedHex(), sizeof(expectedHex));
    memcpy(actualHex, rx.actualHex(), sizeof(actualHex));
  }
  if (phase == shownPhase) {
    if (phase == Phase::Receiving && total > 0) {
      const int percent = (int)((uint64_t)written * 100u / total);
      if (percent >= shownPercent + 5) {
        shownPercent = percent - percent % 5;
        Serial.printf("supd: %d%% (%lu/%lu)\n", shownPercent,
                      (unsigned long)written, (unsigned long)total);
        drawOtaScreen("updating", shownPercent);
      }
    }
    return;
  }
  const Phase was = shownPhase;
  shownPhase = phase;
  if (phase == Phase::AwaitingAuth) {
    startedAtMs = now;
    Serial.printf("supd: begin session=%04x %lu bytes from %u.%u.%u.%u:%u\n",
                  (unsigned)session, (unsigned long)total,
                  (unsigned)(peer.ip & 0xFF), (unsigned)((peer.ip >> 8) & 0xFF),
                  (unsigned)((peer.ip >> 16) & 0xFF), (unsigned)(peer.ip >> 24),
                  (unsigned)peer.port);
    Serial.printf("supd: expected sha256 %s\n", expectedHex);
  }
  if (phase == Phase::Receiving) {
    receivingAtMs = now;
    shownPercent = 0;
    // Same treatment ArduinoOTA's onStart gives the panel: visible whatever
    // the Mac last asked for, and the asked-for state saved to give back.
    savedPanel.save(displaySleeping, idleActive);
    displaySleeping = false;
    idleActive = false;
    applyBacklight();
    drawOtaScreen("updating", 0);
  }
  if (phase == Phase::Done && hasResult &&
      (was == Phase::Receiving || was == Phase::Finalizing ||
       was == Phase::Beginning)) {
    const uint32_t ms = streamupdate::elapsedMs(now, receivingAtMs);
    Serial.printf(
        "supd: transfer %lu bytes in %lu ms; filed=%lu dup=%lu ooo=%lu "
        "window=%lu bad=%lu\n",
        (unsigned long)written, (unsigned long)ms,
        (unsigned long)stats.chunksFiled, (unsigned long)stats.duplicates,
        (unsigned long)stats.outOfOrder, (unsigned long)stats.outsideWindow,
        (unsigned long)stats.badChunks);
    if (result == Status::HashMismatch || (!matched && actualHex[0] != '\0')) {
      Serial.printf("supd: sha256 MISMATCH expected=%s got=%s\n", expectedHex,
                    actualHex);
    }
    if (result == Status::Activated) {
      Serial.println("supd: activated; rebooting into the new image");
      drawOtaScreen("rebooting", 100);
      savedPanel.discard();
    } else {
      Serial.printf("supd: failed: %s%s%s\n", statusWord(result),
                    detail[0] ? " - " : "", detail);
      // Only where the update took the screen: a session that failed on its
      // first write, inside one service pass, never woke or saved the panel,
      // and must not paint over whatever the panel was showing.
      if (savedPanel.held) drawOtaScreen(statusWord(result), -1);
    }
  } else if (phase == Phase::Done && hasResult) {
    Serial.printf("supd: session %04x ended: %s%s%s\n", (unsigned)session,
                  statusWord(result), detail[0] ? " - " : "", detail);
  }
  // Whatever ended an active update - a verdict, or a new session already
  // under way - the panel's own state goes back, after the reason is on the
  // glass as ArduinoOTA's onError does it. take() answers false if nothing
  // was borrowed, so this cannot wake a panel the update never touched.
  const bool leftActive =
      (was == Phase::Receiving || was == Phase::Finalizing) &&
      phase != Phase::Receiving && phase != Phase::Finalizing;
  if (leftActive && !(phase == Phase::Done && result == Status::Activated)) {
    if (savedPanel.take(displaySleeping, idleActive)) applyBacklight();
  }
}

}  // namespace

void arm(const char *password) {
  ensureConfigured();
  if (password == nullptr || password[0] == '\0') {
    Lock held;
    rx.setPasswordHash(nullptr);
    return;
  }
  SHA256Builder hash;
  hash.begin();
  hash.add(password);
  hash.calculate();
  const String hex = hash.toString();
  Lock held;
  rx.setPasswordHash(hex.c_str());
}

bool armed() {
  if (!configured) return false;
  Lock held;
  return rx.armed();
}

bool verifyCameraAuth(const char *nonce, const char *cnonce,
                      const char *response) {
  if (!armed() || nonce == nullptr || cnonce == nullptr || response == nullptr) {
    return false;
  }
  char salt[2 * streamupdate::HEX_DIGEST_CHARS + 2];
  if (streamupdate::authSalt(salt, sizeof(salt), nonce, cnonce) == 0) {
    return false;
  }
  char passwordHash[streamupdate::HEX_DIGEST_CHARS + 1] = {};
  {
    Lock held;
    memcpy(passwordHash, rx.passwordHash(), sizeof(passwordHash));
  }
  SHA256Builder sha256;
  PBKDF2_HMACBuilder pbkdf2(&sha256, String(passwordHash), String(salt),
                            streamupdate::PBKDF2_ITERATIONS);
  pbkdf2.begin();
  pbkdf2.calculate();
  const String derived = pbkdf2.toString();
  char challenge[3 * streamupdate::HEX_DIGEST_CHARS + 3];
  if (derived.length() != streamupdate::HEX_DIGEST_CHARS ||
      streamupdate::authChallenge(challenge, sizeof(challenge), derived.c_str(),
                                  nonce, cnonce) == 0) {
    return false;
  }
  SHA256Builder expected;
  expected.begin();
  expected.add(challenge);
  expected.calculate();
  const String expectedHex = expected.toString();
  return expectedHex.length() == streamupdate::HEX_DIGEST_CHARS &&
         streamupdate::sameDigestHex(expectedHex.c_str(), response);
}

bool handleInbound(const uint8_t *data, size_t len, uint32_t remoteIp,
                   uint16_t remotePort) {
  if (!streamupdate::hasMagic(data, len)) return false;
  if (!configured) return true;  // ours, but nothing armed: drop quietly
  // Only a BEGIN uses them (its challenge nonce); not worth drawing per chunk.
  uint8_t random32[32] = {};
  if (data[3] == 'B') esp_fill_random(random32, sizeof(random32));
  {
    Lock held;
    rx.onPacket(data, len, {remoteIp, remotePort}, millis(), random32);
  }
  flushOutgoing();
  return true;
}

bool ownsPanel() {
  return panelOwned.load(std::memory_order_relaxed);
}

// One erase step of a pending begin, then, once the erase is done, the begin
// the receiver has been waiting for.
static void serviceErase() {
  if (!pendingBegin.active) return;
  bool stillWanted;
  {
    Lock held;
    stillWanted = rx.phase() == Phase::Beginning;
  }
  // A session that ended mid-erase (the sender gave up, an abort) is not
  // worth the rest of the erase: answer now, and the receiver owes an abort.
  const bool stepOk = !stillWanted || image.eraseStep();
  esp_task_wdt_reset();
  if (stillWanted && stepOk && !image.eraseDone()) return;
  const bool ok = stepOk && (image.eraseDone() || !stillWanted);
  pendingBegin.active = false;
  if (panelBlanksDuringFlashErase()) applyBacklight();
  const char *error = ok ? nullptr : "flash erase failed";
  if (ok) {
    slotMemory = pendingBegin.memory;
    if (stillWanted) {
      Serial.printf("supd: opened in %lu ms; receiving into %s\n",
                    (unsigned long)streamupdate::elapsedMs(millis(), pendingBegin.startedMs),
                    partitionSink.partition->label);
    } else {
      Serial.println("supd: session ended during the erase; releasing");
    }
  } else {
    heap_caps_free(pendingBegin.memory);
    imageOpen = false;
    Serial.printf("supd: begin refused: %s\n", error);
  }
  Lock held;
  rx.finishBegin(ok, error, ok ? pendingBegin.memory : nullptr,
                 pendingBegin.slots, millis());
}

bool service() {
  if (!configured) return false;
  const uint32_t start = millis();
  serviceErase();
  // takeWork() also runs the timeouts and keepalive acks, so this runs every
  // pass even with nothing to write.
  while (doOneWork()) {
    flushOutgoing();
    if (millis() - start >= SERVICE_BUDGET_MS) break;
  }
  flushOutgoing();
  reflectState(millis());
  freeSlotsIfUnused();
  bool rebootNow, owns;
  {
    Lock held;
    rebootNow = rx.rebootDue(millis());
    owns = rx.ownsPanel();
  }
  if (rebootNow) {
    Serial.flush();
    delay(50);
    ESP.restart();
  }
  return owns;
}

}  // namespace streamupdatesvc
