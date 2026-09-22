#include <cstdint>
#include <cstdio>

#include "../display_stream/audio_backend_model.h"
#include "../display_stream/serial_config_protocol.h"
#include "../libraries/espdisp_board/src/board_config.h"

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
  using namespace audiobackend;

  const board::AudioConfig *audio =
      board::generatedAudioConfig(board::Variant::AmoledCo5300);
  CHECK(audio != nullptr);
  CHECK(audio->codec == board::AudioCodec::Es8311);
  CHECK(audio->mic == board::AudioMic::Es7210);
  CHECK(audio->amp == board::AudioAmp::Ns4150b);
  CHECK(audio->codecI2cAddress == 0x18);
  CHECK(audio->micI2cAddress == 0x40);
  CHECK(audio->pinPlaybackMclk == 16);
  CHECK(audio->pinPlaybackBclk == 9);
  CHECK(audio->pinPlaybackLrck == 45);
  CHECK(audio->pinDout == 8);
  CHECK(audio->pinDin == 10);
  CHECK(audio->pinAmpEnable == 46);
  CHECK(audio->playbackRateHz == 16000);
  CHECK(audio->playbackChannels == 2);

  CHECK(classify(*audio) == DescriptorStatus::Ready);
  const board::AudioConfig *v2 =
      board::generatedAudioConfig(board::Variant::LcdSt77916);
  CHECK(v2 != nullptr);
  CHECK(classify(*v2) == DescriptorStatus::RevisionNotApproved);
  const board::AudioConfig *silent =
      board::generatedAudioConfig(board::Variant::TouchJd9853);
  CHECK(silent != nullptr);
  CHECK(classify(*silent) == DescriptorStatus::NoAudio);

  const Format format = descriptorFormat(*audio);
  CHECK(format.sampleRateHz == audio->playbackRateHz);
  CHECK(format.channels == audio->playbackChannels);
  CHECK(format.bitsPerSample == 16);
  CHECK(supportsCodecClock(format.sampleRateHz));
  CHECK(supportsCodecClock(48000));
  CHECK(!supportsCodecClock(32000));

  CHECK(SAFE_POWER_UP.size() == 7);
  CHECK(SAFE_POWER_UP[0] == PowerStep::DisableAmp);
  CHECK(SAFE_POWER_UP[1] == PowerStep::StartClocks);
  CHECK(SAFE_POWER_UP[2] == PowerStep::PrimeSilence);
  CHECK(SAFE_POWER_UP[3] == PowerStep::InitializeCodecsMuted);
  CHECK(SAFE_POWER_UP[4] == PowerStep::SetGain);
  CHECK(SAFE_POWER_UP[5] == PowerStep::UnmuteCodec);
  CHECK(SAFE_POWER_UP[6] == PowerStep::EnableAmp);

  ToneGenerator tone(format.sampleRateHz, format.channels, 440);
  int16_t frames[64] = {};
  const size_t generated = tone.fill(frames, 32);
  CHECK(generated == 32);
  bool sawNonZero = false;
  for (size_t frame = 0; frame < generated; ++frame) {
    sawNonZero = sawNonZero || frames[frame * format.channels] != 0;
    for (uint8_t channel = 1; channel < format.channels; ++channel) {
      CHECK(frames[frame * format.channels] ==
            frames[frame * format.channels + channel]);
    }
  }
  CHECK(sawNonZero);

  const serialcfg::ParsedAudioTest defaultTest =
      serialcfg::parseAudioTest("CFGAUDIOTEST");
  CHECK(defaultTest.command == serialcfg::AudioTestCommand::Start);
  CHECK(defaultTest.durationMs == 1000);
  const serialcfg::ParsedAudioTest timedTest =
      serialcfg::parseAudioTest("CFGAUDIOTEST 750");
  CHECK(timedTest.command == serialcfg::AudioTestCommand::Start);
  CHECK(timedTest.durationMs == 750);
  CHECK(serialcfg::parseAudioTest("CFGAUDIOTEST stop").command ==
        serialcfg::AudioTestCommand::Stop);
  CHECK(serialcfg::parseAudioTest("CFGAUDIOTEST 99").command ==
        serialcfg::AudioTestCommand::Invalid);
  CHECK(serialcfg::parseAudioTest("CFGAUDIOTEST 5001").command ==
        serialcfg::AudioTestCommand::Invalid);
  CHECK(serialcfg::parseAudioTest("CFGAUDIOTEST nope").command ==
        serialcfg::AudioTestCommand::Invalid);
  CHECK(serialcfg::parseAudioTest("CFGSHOW").command ==
        serialcfg::AudioTestCommand::Unknown);

  std::printf("audio stage 1: %d checks passed\n", checks);
  return 0;
}
