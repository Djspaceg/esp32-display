#pragma once

#include <Arduino.h>
#include <board_config.h>

namespace audioengine {

bool start(const board::Config &config);
void stop();
bool available();
bool shouldSuppressVideo();
bool streamActive();
void setLocalTestActive(bool active);

extern uint32_t tuneLowWatermarkMs;
extern uint32_t tuneTargetWatermarkMs;
extern uint32_t tuneHighWatermarkMs;
extern int32_t tuneMaxCorrectionPpm;
extern TaskHandle_t engineTaskHandle;

}  // namespace audioengine
