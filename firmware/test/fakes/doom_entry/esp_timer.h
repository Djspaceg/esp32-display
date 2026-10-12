// Fake esp_timer for the host tests: the callback a periodic timer was
// created with is kept, and a test fires it by hand.
#pragma once

#include <stdint.h>

typedef struct fake_esp_timer *esp_timer_handle_t;
typedef int esp_err_t;
#ifndef ESP_OK
#define ESP_OK 0
#endif

typedef struct {
  void (*callback)(void *arg);
  void *arg;
  int dispatch_method;
  const char *name;
  bool skip_unhandled_events;
} esp_timer_create_args_t;

extern void (*fakeEspTimerCallback)(void *arg);
extern void *fakeEspTimerArg;

inline esp_err_t esp_timer_create(const esp_timer_create_args_t *args,
                                  esp_timer_handle_t *out) {
  fakeEspTimerCallback = args->callback;
  fakeEspTimerArg = args->arg;
  *out = reinterpret_cast<esp_timer_handle_t>(1);
  return ESP_OK;
}
inline esp_err_t esp_timer_start_periodic(esp_timer_handle_t, uint64_t) {
  return ESP_OK;
}
inline esp_err_t esp_timer_stop(esp_timer_handle_t) { return ESP_OK; }
