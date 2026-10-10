#pragma once

#include <stdint.h>

#include <board_config.h>

const char *startAudioToneTest(const board::Config &config,
                               uint32_t durationMs);
void stopAudioToneTest(bool report = true);
void serviceAudioToneTest();
bool audioToneTestRunning();

// What the board's own microphones heard at the tone's frequency: the window
// of silence the test plays first, then the tone. `measured` is false until a
// tone completes with microphone data for both windows.
struct AudioToneLoopback {
  bool measured;
  uint8_t channels;
  float silenceDbfs[2];
  float toneDbfs[2];
};
AudioToneLoopback lastAudioToneLoopback();
