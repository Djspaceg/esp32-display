#include "fault_inject.h"

#include <Arduino.h>

#if __has_include("fault_inject_local.h")
#include "fault_inject_local.h"
#endif

#if defined(ESPDISP_FAULT_INJECT) && ESPDISP_FAULT_INJECT && \
    defined(BOARD_HAS_SDIO_ESP_HOSTED)
#include <driver/gpio.h>
#include <esp32-hal-hosted.h>
#include <esp_hosted.h>
#include <esp_timer.h>
#include <esp_wifi.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>
#include <stdlib.h>
#include <string.h>

namespace faultinject {

static esp_timer_handle_t releaseTimer = nullptr;
static volatile uint32_t jamCount = 0;
static volatile uint32_t jamKind = 0;

// ESP-Hosted runs one RPC at a time. This C6 leaves some requests unanswered
// (its firmware predates them), so a side task sending those back to back
// keeps every other task's hosted RPC waiting its turn with the SDIO link
// still up: the silent-C6 case, without the bus fault a held reset triggers.
static void jamTask(void *) {
  for (uint32_t i = 0; i < jamCount; i++) {
    const uint32_t start = millis();
    int err = 0;
    if (jamKind == 0) {
      uint32_t chip = 0;
      char name[20] = {0};
      err = esp_hosted_get_cp_info(&chip, name, sizeof(name));
    } else {
      esp_hosted_coprocessor_fwver_t ver = {};
      err = esp_hosted_get_coprocessor_fwversion(&ver);
      Serial.printf("DIAG hosted slave=%lu.%lu.%lu\n", (unsigned long)ver.major1,
                    (unsigned long)ver.minor1, (unsigned long)ver.patch1);
    }
    Serial.printf("DIAG rpc jam %lu/%lu kind=%lu err=%d in %lums t=%lu\n",
                  (unsigned long)(i + 1), (unsigned long)jamCount,
                  (unsigned long)jamKind, err,
                  (unsigned long)(millis() - start), (unsigned long)millis());
  }
  vTaskDelete(nullptr);
}

static volatile uint32_t scanDwellMs = 0;

// A blocking passive scan runs inside the C6's RPC handler, so the C6 answers
// nothing else until it ends (13 channels x dwell): hosted RPCs from every
// other task go unanswered for that long while SDIO stays up.
static void scanTask(void *) {
  wifi_scan_config_t config = {};
  config.scan_type = WIFI_SCAN_TYPE_PASSIVE;
  config.scan_time.passive = scanDwellMs;
  const uint32_t start = millis();
  Serial.printf("DIAG scan start dwell=%lums t=%lu\n",
                (unsigned long)scanDwellMs, (unsigned long)start);
  const esp_err_t err = esp_wifi_scan_start(&config, true);
  Serial.printf("DIAG scan end err=%d (%s) in %lums t=%lu\n", (int)err,
                esp_err_to_name(err), (unsigned long)(millis() - start),
                (unsigned long)millis());
  vTaskDelete(nullptr);
}

static void releaseCoprocessor(void *) {
  gpio_set_level((gpio_num_t)BOARD_SDIO_ESP_HOSTED_RESET, 1);
  Serial.printf("DIAG c6 released t=%lu\n", (unsigned long)millis());
}

void announce() {
  Serial.println("DIAG: bench-only C6 fault injection compiled in; "
                 "not a release image");
}

bool handleLine(const char *line, Print &out) {
  if (strncmp(line, "DIAGC6HOLD ", 11) == 0) {
    const uint32_t holdMs = (uint32_t)strtoul(line + 11, nullptr, 10);
    if (releaseTimer == nullptr) {
      esp_timer_create_args_t args = {};
      args.callback = releaseCoprocessor;
      args.name = "c6release";
      if (esp_timer_create(&args, &releaseTimer) != ESP_OK) {
        out.println("DIAG c6 hold: timer create failed");
        return true;
      }
    }
    esp_timer_stop(releaseTimer);
    gpio_set_level((gpio_num_t)BOARD_SDIO_ESP_HOSTED_RESET, 0);
    esp_timer_start_once(releaseTimer, (uint64_t)holdMs * 1000u);
    out.printf("DIAG c6 held low gpio=%d for %lums t=%lu\n",
               (int)BOARD_SDIO_ESP_HOSTED_RESET, (unsigned long)holdMs,
               (unsigned long)millis());
    return true;
  }
  if (strncmp(line, "DIAGRPCJAM ", 11) == 0) {
    char *rest = nullptr;
    jamCount = (uint32_t)strtoul(line + 11, &rest, 10);
    jamKind = (uint32_t)strtoul(rest, nullptr, 10);
    if (xTaskCreatePinnedToCore(jamTask, "rpcjam", 4096, nullptr, 1, nullptr,
                                0) != pdPASS) {
      out.println("DIAG rpc jam: task create failed");
    }
    return true;
  }
  if (strncmp(line, "DIAGSCAN ", 9) == 0) {
    scanDwellMs = (uint32_t)strtoul(line + 9, nullptr, 10);
    if (xTaskCreatePinnedToCore(scanTask, "diagscan", 4096, nullptr, 1,
                                nullptr, 0) != pdPASS) {
      out.println("DIAG scan: task create failed");
    }
    return true;
  }
  if (strcmp(line, "DIAGC6VER") == 0) {
    uint32_t hMaj = 0, hMin = 0, hPat = 0, sMaj = 0, sMin = 0, sPat = 0;
    hostedGetHostVersion(&hMaj, &hMin, &hPat);
    hostedGetSlaveVersion(&sMaj, &sMin, &sPat);
    out.printf("DIAG hosted host=%lu.%lu.%lu slave_at_init=%lu.%lu.%lu\n",
               (unsigned long)hMaj, (unsigned long)hMin, (unsigned long)hPat,
               (unsigned long)sMaj, (unsigned long)sMin, (unsigned long)sPat);
    // The live query is an RPC, so it runs on the jam task, not loopTask.
    jamCount = 1;
    jamKind = 1;
    if (xTaskCreatePinnedToCore(jamTask, "rpcjam", 4096, nullptr, 1, nullptr,
                                0) != pdPASS) {
      out.println("DIAG fwversion: task create failed");
    }
    return true;
  }
  return false;
}

}  // namespace faultinject

#else

namespace faultinject {

void announce() {}
bool handleLine(const char *, Print &) { return false; }

}  // namespace faultinject

#endif
