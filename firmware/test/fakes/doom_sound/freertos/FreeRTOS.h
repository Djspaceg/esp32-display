// C-compatible stand-in: the Doom stubs only delay through FreeRTOS.
#pragma once

#include <stdint.h>

typedef uint32_t TickType_t;
#define pdMS_TO_TICKS(ms) ((TickType_t)(ms))
