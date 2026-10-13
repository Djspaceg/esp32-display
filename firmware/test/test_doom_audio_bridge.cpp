// Host test for the board side of Doom's sound effects
// (display_stream/doom_audio.cpp, compiled unmodified against fakes/audio
// with the real codec backend).
//
// Properties:
// - A board whose descriptor names no audio parts gets no I2C read, no GPIO
//   write, no log line, no task and no added delay at any restart path.
// - A board with the parts starts the codec transmit-only (no microphone
//   ADC, no receive DMA), amplifier last, and one output task on core 0.
// - Each failure after the probe leaves the amplifier off and frees what it
//   took, so sound stays off and Doom carries on.
// - doom_audio_end lets the queue drain, then turns the amplifier off once.
// - Quiet mode (the NVS "quiet" key CFGQUIET sets) declines before any I2C
//   read or GPIO write, so neither game mixes or plays a sample.
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include <Arduino.h>
#include <Preferences.h>
#include <board_config.h>

#include "../display_stream/audio_backend.h"
#include "audio_host_fakes.h"
#include "platform/doom_audio_bridge.h"

extern const board::Config *bcfg;  // defined by fakes/audio
void doomAudioResetForTest();
size_t doomAudioServiceOnceForTest();

static int checks = 0;
#define CHECK(cond)                                          \
  do {                                                       \
    checks++;                                                \
    if (!(cond)) {                                           \
      printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
      printf("log was:\n%s", logged.c_str());               \
      return 1;                                              \
    }                                                        \
  } while (0)

static std::string logged;

extern "C" void doom_log(const char *format, ...) {
  char line[256];
  va_list args;
  va_start(args, format);
  vsnprintf(line, sizeof(line), format, args);
  va_end(args);
  logged += line;
  logged += "\n";
}

static size_t renderedFrames = 0;
static unsigned renderedChannels = 0;

static void renderSilence(int16_t *out, size_t frames, unsigned channels) {
  memset(out, 0, frames * channels * sizeof(int16_t));
  renderedFrames += frames;
  renderedChannels = channels;
}

static void fresh(const board::Config &config) {
  audio::sharedCodecBackend().stop();
  audiohost::reset();
  audio::resetBoardAudioStatusForTest();
  doomAudioResetForTest();
  logged.clear();
  bcfg = &config;
}

static bool sawEvent(audiohost::HardwareEventKind kind) {
  for (const auto &event : audiohost::hardwareEvents()) {
    if (event.kind == kind) return true;
  }
  return false;
}

int main() {
  // ---- Boards without audio parts: nothing at all. ----
  for (const board::Config *config :
       {&board::CONFIG_LCD_ST7789_130, &board::CONFIG_LCD_ST7789_190,
        &board::CONFIG_ELECROW_KNOB_128}) {
    fresh(*config);
    CHECK(doom_audio_begin(renderSilence) == 0);
    doom_audio_lock();
    doom_audio_unlock();
    const uint32_t before = millis();
    doom_audio_end();
    CHECK(millis() == before);
    CHECK(audiohost::hardwareEvents().empty());
    CHECK(audiohost::createdTasks().empty());
    CHECK(audiohost::liveMutexes() == 0);
    CHECK(logged.empty());
  }

  // ---- A 1.75C with its codec and ADC. ----
  fresh(board::CONFIG_AMOLED_CO5300);
  const board::AudioConfig *audio =
      board::generatedAudioConfig(board::Variant::AmoledCo5300);
  CHECK(doom_audio_begin(nullptr) == 0);
  CHECK(audiohost::hardwareEvents().empty());
  CHECK(doom_audio_begin(renderSilence) == 16000);
  CHECK(logged.find("sound: effects on, 16000 Hz, 2 channels") !=
        std::string::npos);
  // Transmit-only: the receive pin is not given to I2S, and the ES7210 is
  // left powered down.
  int din = 0;
  for (const auto &event : audiohost::hardwareEvents()) {
    if (event.kind == audiohost::HardwareEventKind::I2sSetPins) {
      din = event.value;
    }
  }
  CHECK(din == board::NO_PIN);
  CHECK(audiohost::lastRegisterWrite(audio->micI2cAddress, 0x47) == 0xFF);
  CHECK(audiohost::lastRegisterWrite(audio->micI2cAddress, 0x06) == 0x07);
  // Amplifier last.
  CHECK(audiohost::hardwareEvents().back().kind ==
        audiohost::HardwareEventKind::DigitalWrite);
  CHECK(audiohost::hardwareEvents().back().value ==
        audio->pinAmpEnable * 10 + HIGH);
  // One output task, on the core loopTask does not use.
  CHECK(audiohost::createdTasks().size() == 1);
  CHECK(strcmp(audiohost::createdTasks()[0].name, "doom_snd") == 0);
  CHECK(audiohost::createdTasks()[0].core == 0);
  CHECK(audiohost::liveMutexes() == 1);
  // The lock is the mutex, paired.
  doom_audio_lock();
  doom_audio_unlock();
  CHECK(!audiohost::mutexMisuse());
  // The output task's pass: one whole DMA buffer (240 frames, both slots)
  // rendered and written; a write the codec refuses still waits out the
  // block, so the task cannot spin.
  renderedFrames = 0;
  CHECK(doomAudioServiceOnceForTest() == 240);
  CHECK(renderedFrames == 240 && renderedChannels == 2);
  CHECK(audiohost::hardwareEvents().back().kind ==
        audiohost::HardwareEventKind::I2sWrite);
  CHECK(audiohost::hardwareEvents().back().value == 240 * 2 * 2);
  const unsigned delaysBefore = audiohost::delayCalls();
  audiohost::setI2sFailing(true);
  CHECK(doomAudioServiceOnceForTest() == 0);
  CHECK(audiohost::delayCalls() > delaysBefore);
  audiohost::setI2sFailing(false);
  // Only once per boot.
  CHECK(doom_audio_begin(renderSilence) == 0);
  CHECK(audiohost::createdTasks().size() == 1);
  // End: the queue (at most the 90 ms ring) drains, then the amplifier goes
  // off, once.
  const size_t eventsBefore = audiohost::hardwareEvents().size();
  const uint32_t endStart = millis();
  doom_audio_end();
  CHECK(millis() - endStart >= 90 && millis() - endStart <= 92);
  CHECK(audiohost::hardwareEvents().size() == eventsBefore + 1);
  CHECK(audiohost::hardwareEvents().back().value ==
        audio->pinAmpEnable * 10 + LOW);
  const uint32_t secondEnd = millis();
  doom_audio_end();
  CHECK(millis() == secondEnd);
  CHECK(audiohost::hardwareEvents().size() == eventsBefore + 1);

  // ---- Codec parts that do not identify: probe only, then off. ----
  fresh(board::CONFIG_AMOLED_CO5300);
  audiohost::setI2cDevice(0x18, false);
  CHECK(doom_audio_begin(renderSilence) == 0);
  CHECK(logged.find("sound: off, codec and ADC not identified") !=
        std::string::npos);
  CHECK(!sawEvent(audiohost::HardwareEventKind::PinMode));
  CHECK(!sawEvent(audiohost::HardwareEventKind::DigitalWrite));
  CHECK(!sawEvent(audiohost::HardwareEventKind::I2sBegin));
  CHECK(audiohost::createdTasks().empty());
  CHECK(audiohost::liveMutexes() == 0);

  // ---- The output task cannot be created: codec stopped, amp off. ----
  fresh(board::CONFIG_AMOLED_CO5300);
  audiohost::setTaskCreateFailing(true);
  CHECK(doom_audio_begin(renderSilence) == 0);
  CHECK(logged.find("sound: off, output task not created") !=
        std::string::npos);
  CHECK(sawEvent(audiohost::HardwareEventKind::I2sEnd));
  CHECK(audiohost::hardwareEvents().back().kind !=
            audiohost::HardwareEventKind::DigitalWrite ||
        audiohost::hardwareEvents().back().value !=
            audio->pinAmpEnable * 10 + HIGH);
  {
    // The amplifier's last write is LOW.
    int lastAmp = -1;
    for (const auto &event : audiohost::hardwareEvents()) {
      if (event.kind == audiohost::HardwareEventKind::DigitalWrite &&
          event.value / 10 == audio->pinAmpEnable) {
        lastAmp = event.value % 10;
      }
    }
    CHECK(lastAmp == LOW);
  }
  CHECK(audiohost::liveMutexes() == 0);
  CHECK(!audio::sharedCodecBackend().running());
  const uint32_t failedEnd = millis();
  doom_audio_end();
  CHECK(millis() == failedEnd);
  // A later attempt in the same boot may still succeed.
  audiohost::setTaskCreateFailing(false);
  CHECK(doom_audio_begin(renderSilence) == 16000);

  // ---- Quiet mode (CFGQUIET 1): a board with audio stays silent. ----
  // Doom and Quake both start their sound here, so declining leaves each
  // engine with sound off: nothing is mixed, the codec and amplifier are never
  // touched, and the reason is logged once.
  fresh(board::CONFIG_AMOLED_CO5300);
  Preferences::bools()["quiet"] = true;
  renderedFrames = 0;
  CHECK(doom_audio_begin(renderSilence) == 0);
  CHECK(logged.find("sound: off, quiet mode") != std::string::npos);
  CHECK(audiohost::hardwareEvents().empty());
  CHECK(audiohost::createdTasks().empty());
  CHECK(audiohost::liveMutexes() == 0);
  CHECK(renderedFrames == 0);
  const uint32_t quietEnd = millis();
  doom_audio_end();
  CHECK(millis() == quietEnd);
  CHECK(audiohost::hardwareEvents().empty());
  // Turned off again, the same board has its sound back.
  fresh(board::CONFIG_AMOLED_CO5300);
  Preferences::bools()["quiet"] = false;
  CHECK(doom_audio_begin(renderSilence) == 16000);
  Preferences::bools().clear();

  audio::sharedCodecBackend().stop();
  printf("test_doom_audio_bridge: %d checks passed\n", checks);
  return 0;
}
