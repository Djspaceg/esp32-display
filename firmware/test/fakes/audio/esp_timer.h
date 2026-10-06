#pragma once

#include <stdint.h>

// Microseconds on the fake millis() clock.
int64_t esp_timer_get_time();
