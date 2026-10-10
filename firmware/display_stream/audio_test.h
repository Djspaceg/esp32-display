#pragma once

#include <stdint.h>

#include <board_config.h>

const char *startAudioToneTest(const board::Config &config,
                               uint32_t durationMs);
void stopAudioToneTest(bool report = true);
void serviceAudioToneTest();
bool audioToneTestRunning();

// What the board's own microphones heard at the tone's frequency: the window
// of silence the test plays first, the tone, then the tone with the amplifier
// off. `measured` is false until a tone completes with microphone data for
// all three windows.
struct AudioToneLoopback {
  bool measured;
  uint8_t channels;
  float silenceDbfs[2];
  float toneDbfs[2];
  float ampOffDbfs[2];
};
AudioToneLoopback lastAudioToneLoopback();
