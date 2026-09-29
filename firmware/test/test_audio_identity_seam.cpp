// Runtime seam for the audio start gate. A 1.75C whose 0x18 and 0x40 both
// acknowledge but carry some other chip's IDs must not get I2S clocks or an
// enabled amplifier. Only the backend API that predates chip-ID
// identification is used, so this same file also runs against that older
// source and shows its gate accepting the impostor.
#include <cstdio>

#include "../display_stream/audio_backend.h"
#include "../display_stream/audio_backend_model.h"
#include "../libraries/espdisp_board/src/board_config.h"
#include "fakes/audio/audio_host_fakes.h"

static int checks = 0;
#define CHECK(cond)                                                        \
  do {                                                                     \
    checks++;                                                              \
    if (!(cond)) {                                                         \
      std::printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);          \
      return 1;                                                            \
    }                                                                      \
  } while (0)

int main() {
  const board::AudioConfig *audio =
      board::generatedAudioConfig(board::Variant::AmoledCo5300);
  CHECK(audio != nullptr);
  audiohost::reset();
  // Something answers at both addresses, but not with 83 11 / 72 10.
  audiohost::setI2cDevice(0x18, true, 0xFD, 0x00, 0xFE, 0x00);
  audiohost::setI2cDevice(0x40, true, 0x3D, 0x00, 0x3E, 0x00);
  audio::CodecSerialAudioBackend backend;
  const bool started = backend.start(board::CONFIG_AMOLED_CO5300, *audio,
                                     audiobackend::descriptorFormat(*audio));
  bool ampEnabled = false;
  bool clocksStarted = false;
  for (const auto &event : audiohost::hardwareEvents()) {
    ampEnabled = ampEnabled ||
                 (event.kind == audiohost::HardwareEventKind::DigitalWrite &&
                  event.value == audio->pinAmpEnable * 10 + 1);
    clocksStarted = clocksStarted ||
                    event.kind == audiohost::HardwareEventKind::I2sBegin;
  }
  CHECK(!started);
  CHECK(!clocksStarted);
  CHECK(!ampEnabled);
  std::printf("audio identity seam: %d checks passed\n", checks);
  return 0;
}
