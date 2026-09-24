#pragma once

#include <stdint.h>

#include <board_config.h>

const char *startAudioToneTest(const board::Config &config,
                               uint32_t durationMs);
void stopAudioToneTest(bool report = true);
void serviceAudioToneTest();
bool audioToneTestRunning();
