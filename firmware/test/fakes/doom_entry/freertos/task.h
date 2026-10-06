#pragma once

#include "FreeRTOS.h"

TickType_t xTaskGetTickCount();
TickType_t xTaskGetTickCountFromISR();
