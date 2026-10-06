#include "mem_diag.h"

#include <Arduino.h>
#include <esp_attr.h>
#include <esp_heap_caps.h>

#include "audio_transport.h"
#include "wifi_worker.h"

namespace memdiag {

// Written by the failure callback, which can run in any task (or an ISR) that
// allocates, so it only counts and stores: no printing, no locking. A torn
// size/caps pair is possible across two failures and harmless for a
// diagnostic.
static volatile uint32_t failures = 0;
static volatile uint32_t lastSize = 0;
static volatile uint32_t lastCaps = 0;

static void IRAM_ATTR onAllocFailed(size_t size, uint32_t caps,
                                    const char *function) {
  (void)function;
  failures = failures + 1;
  lastSize = (uint32_t)size;
  lastCaps = caps;
}

void begin() { heap_caps_register_failed_alloc_callback(onAllocFailed); }

memreport::Sample sample() {
  memreport::Sample s;
  s.internalFree = (uint32_t)heap_caps_get_free_size(MALLOC_CAP_INTERNAL);
  s.internalMinFree =
      (uint32_t)heap_caps_get_minimum_free_size(MALLOC_CAP_INTERNAL);
  const uint32_t dmaCaps = MALLOC_CAP_DMA | MALLOC_CAP_INTERNAL;
  s.dmaFree = (uint32_t)heap_caps_get_free_size(dmaCaps);
  s.dmaMinFree = (uint32_t)heap_caps_get_minimum_free_size(dmaCaps);
  s.dmaLargestBlock = (uint32_t)heap_caps_get_largest_free_block(dmaCaps);
  s.allocFailures = failures;
  s.lastFailedSize = lastSize;
  s.lastFailedCaps = lastCaps;
#if defined(CONFIG_IDF_TARGET_ESP32P4)
  // Only the P4's WiFi is a hosted RPC link (to its C6 co-processor).
  uint32_t age = 0;
  s.rpcAgeMs = wifiworker::lastAnswerAgeMs(millis(), age)
                   ? (int32_t)(age > INT32_MAX ? INT32_MAX : age)
                   : -1;
#else
  s.rpcAgeMs = -1;
#endif
  s.uplinkErrors = audiotransport::stats().uplinkErrors;
  return s;
}

}  // namespace memdiag
