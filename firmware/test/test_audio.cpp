#include <cstdint>
#include <cstdio>
#include <cstring>

#include "../display_stream/audio_backend_model.h"
#include "../display_stream/audio_engine_model.h"
#include "../display_stream/audio_protocol.h"
#include "../display_stream/device_protocol.h"
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
  CHECK(matchesBoard(board::CONFIG_AMOLED_CO5300, *audio));
  const board::AudioConfig *v2 =
      board::generatedAudioConfig(board::Variant::LcdSt77916);
  CHECK(v2 != nullptr);
  CHECK(classify(*v2) == DescriptorStatus::RevisionNotApproved);
  CHECK(!matchesBoard(board::CONFIG_AMOLED_CO5300, *v2));
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

  CHECK(serialcfg::parseAudioTune("CFGSHOW").field ==
        serialcfg::AudioTuneField::Unknown);
  CHECK(serialcfg::parseAudioTune("CFGAUDIO").field ==
        serialcfg::AudioTuneField::Show);
  const serialcfg::ParsedAudioTune lowTune =
      serialcfg::parseAudioTune("CFGAUDIO lowms 70");
  CHECK(lowTune.field == serialcfg::AudioTuneField::LowMs);
  CHECK(lowTune.value == 70);
  CHECK(serialcfg::parseAudioTune("CFGAUDIO targetms 130").field ==
        serialcfg::AudioTuneField::TargetMs);
  CHECK(serialcfg::parseAudioTune("CFGAUDIO highms 200").field ==
        serialcfg::AudioTuneField::HighMs);
  CHECK(serialcfg::parseAudioTune("CFGAUDIO maxppm 800").field ==
        serialcfg::AudioTuneField::MaxPpm);
  CHECK(serialcfg::parseAudioTune("CFGAUDIO rcvbufkb 128").field ==
        serialcfg::AudioTuneField::ReceiveBufferKb);
  CHECK(serialcfg::parseAudioTune("CFGAUDIO lowms 70 trailing").field ==
        serialcfg::AudioTuneField::Invalid);
  CHECK(serialcfg::parseAudioTune("CFGAUDIO lowms -1").field ==
        serialcfg::AudioTuneField::Invalid);
  serialcfg::AudioTuneConfig tune = {80, 120, 180, 400, 96};
  serialcfg::AudioTuneConfig updatedTune = {};
  CHECK(serialcfg::applyAudioTune(lowTune, tune, updatedTune));
  CHECK(updatedTune.lowMs == 70);
  CHECK(updatedTune.targetMs == 120);
  CHECK(!serialcfg::applyAudioTune(
      serialcfg::parseAudioTune("CFGAUDIO targetms 75"),
      tune, updatedTune));
  CHECK(!serialcfg::applyAudioTune(
      serialcfg::parseAudioTune("CFGAUDIO maxppm 49"),
      tune, updatedTune));
  CHECK(!serialcfg::applyAudioTune(
      serialcfg::parseAudioTune("CFGAUDIO rcvbufkb 257"),
      tune, updatedTune));

  // --- Stage 2 audio wire protocol ---------------------------------------
  CHECK(audioproto::UDP_PORT == 5569);
  CHECK(audioproto::VERSION == 1);
  CHECK((uint8_t)audioproto::DatagramKind::PcmDownlink == 1);
  CHECK((uint8_t)audioproto::DatagramKind::PcmUplink == 2);
  CHECK((uint8_t)audioproto::DatagramKind::Status == 3);
  CHECK(deviceproto::CAP_AUDIO_DOWNLINK == (1u << 20));
  CHECK(deviceproto::CAP_AUDIO_UPLINK == (1u << 21));
  CHECK(audioproto::peerVersionsCompatible(1, 1, true));
  CHECK(!audioproto::peerVersionsCompatible(1, 2, true));
  CHECK(!audioproto::peerVersionsCompatible(1, 1, false));

  uint8_t pcm[16] = {};
  for (size_t i = 0; i < sizeof(pcm); ++i) pcm[i] = (uint8_t)i;
  uint8_t packet[audioproto::MAX_DATAGRAM_BYTES] = {};
  const audioproto::PcmHeader outbound = {
      audioproto::DatagramKind::PcmDownlink,
      7,
      3,
      16000,
      320,
      123456,
      4,
      2,
  };
  const size_t packetBytes = audioproto::writePcm(
      packet, sizeof(packet), outbound, pcm, sizeof(pcm));
  CHECK(packetBytes == audioproto::HEADER_BYTES + sizeof(pcm));
  CHECK(audioproto::hasAudioMagic(packet, packetBytes));
  CHECK(!audioproto::hasAudioMagic(packet, 3));
  CHECK(!audioproto::hasAudioMagic(nullptr, packetBytes));
  audioproto::PcmDatagram parsed = {};
  CHECK(audioproto::parsePcmDownlink(packet, packetBytes, parsed) ==
        audioproto::ParseResult::Ok);
  CHECK(parsed.header.sequence == 7);
  CHECK(parsed.header.streamGeneration == 3);
  CHECK(parsed.header.sampleRateHz == 16000);
  CHECK(parsed.header.sampleCounter == 320);
  CHECK(parsed.header.frameCount == 4);
  CHECK(parsed.header.channels == 2);
  CHECK(parsed.payloadBytes == sizeof(pcm));
  CHECK(std::memcmp(parsed.payload, pcm, sizeof(pcm)) == 0);
  for (size_t len = 0; len < audioproto::HEADER_BYTES; ++len) {
    CHECK(audioproto::parsePcmDownlink(packet, len, parsed) ==
          audioproto::ParseResult::Truncated);
  }
  uint8_t hostile[audioproto::MAX_DATAGRAM_BYTES] = {};
  std::memcpy(hostile, packet, packetBytes);
  hostile[0] = 'X';
  CHECK(!audioproto::hasAudioMagic(hostile, packetBytes));
  CHECK(audioproto::parsePcmDownlink(hostile, packetBytes, parsed) ==
        audioproto::ParseResult::BadMagic);
  std::memcpy(hostile, packet, packetBytes);
  hostile[4] = 2;
  CHECK(audioproto::parsePcmDownlink(hostile, packetBytes, parsed) ==
        audioproto::ParseResult::VersionMismatch);
  std::memcpy(hostile, packet, packetBytes);
  hostile[5] = 99;
  CHECK(audioproto::parsePcmDownlink(hostile, packetBytes, parsed) ==
        audioproto::ParseResult::UnknownKind);
  std::memcpy(hostile, packet, packetBytes);
  hostile[6] = 0x80;
  CHECK(audioproto::parsePcmDownlink(hostile, packetBytes, parsed) ==
        audioproto::ParseResult::BadFlags);
  std::memcpy(hostile, packet, packetBytes);
  hostile[7] = 0;
  CHECK(audioproto::parsePcmDownlink(hostile, packetBytes, parsed) ==
        audioproto::ParseResult::BadFormat);
  std::memcpy(hostile, packet, packetBytes);
  hostile[24] = 5;
  CHECK(audioproto::parsePcmDownlink(hostile, packetBytes, parsed) ==
        audioproto::ParseResult::BadLength);
  CHECK(audioproto::parsePcmDownlink(packet, packetBytes - 1, parsed) ==
        audioproto::ParseResult::BadLength);

  const audioproto::Status status = {
      100, 120, 2, 3, 4, 5, 6, 7,
  };
  const size_t statusBytes = audioproto::writeStatus(
      packet, sizeof(packet), 8, 9, 48000, 10, status);
  CHECK(statusBytes ==
        audioproto::HEADER_BYTES + audioproto::STATUS_PAYLOAD_BYTES);
  CHECK(std::memcmp(packet, "EAUD", 4) == 0);
  CHECK(packet[4] == audioproto::VERSION);
  CHECK(packet[5] == (uint8_t)audioproto::DatagramKind::Status);
  CHECK(audioproto::readU16LE(packet + 8) == 8);
  CHECK(audioproto::readU16LE(packet + 10) == 9);
  CHECK(audioproto::readU32LE(packet + 12) == 48000);
  CHECK(audioproto::readU32LE(packet + audioproto::HEADER_BYTES) == 100);
  CHECK(audioproto::readU32LE(
            packet + audioproto::HEADER_BYTES + 7 * sizeof(uint32_t)) == 7);

  // --- Jitter storage and sequence/version gates -------------------------
  int16_t jitterStorage[32] = {};
  audioengine::JitterBuffer jitter;
  CHECK(jitter.reset(jitterStorage, 16, 2));
  int16_t fourFrames[8] = {1, 2, 3, 4, 5, 6, 7, 8};
  CHECK(jitter.push(fourFrames, 4));
  CHECK(jitter.fillFrames() == 4);
  CHECK(jitter.peek(0, 0) == 1);
  CHECK(jitter.peek(3, 1) == 8);
  CHECK(jitter.discard(2));
  CHECK(jitter.fillFrames() == 2);
  CHECK(jitter.pushSilence(3));
  CHECK(jitter.fillFrames() == 5);
  CHECK(jitter.peek(4, 0) == 0);
  CHECK(!jitter.push(fourFrames, 12));
  CHECK(!jitter.discard(6));

  audioengine::StreamTracker tracker(128);
  auto sequence = tracker.accept(1, 9, 100, 1000, 20);
  CHECK(sequence.decision == audioengine::StreamDecision::Start);
  sequence = tracker.accept(1, 9, 101, 1020, 20);
  CHECK(sequence.decision == audioengine::StreamDecision::Accept);
  sequence = tracker.accept(1, 9, 103, 1060, 20);
  CHECK(sequence.decision == audioengine::StreamDecision::AcceptGap);
  CHECK(sequence.gapFrames == 20);
  sequence = tracker.accept(1, 9, 102, 1040, 20);
  CHECK(sequence.decision == audioengine::StreamDecision::Late);
  sequence = tracker.accept(2, 9, 104, 1080, 20);
  CHECK(sequence.decision == audioengine::StreamDecision::VersionMismatch);
  sequence = tracker.accept(1, 9, 110, 5000, 20);
  CHECK(sequence.decision == audioengine::StreamDecision::Discontinuity);
  sequence = tracker.accept(1, 10, 1, 0, 20);
  CHECK(sequence.decision == audioengine::StreamDecision::Start);
  audioengine::StreamTracker wrappingTracker(128);
  sequence = wrappingTracker.accept(1, 11, UINT16_MAX, UINT32_MAX - 19, 20);
  CHECK(sequence.decision == audioengine::StreamDecision::Start);
  sequence = wrappingTracker.accept(1, 11, 0, 0, 20);
  CHECK(sequence.decision == audioengine::StreamDecision::Accept);
  CHECK(!audioengine::streamIdleExpired(
      1999, 0, audioengine::DEFAULT_STREAM_IDLE_TIMEOUT_MS));
  CHECK(audioengine::streamIdleExpired(
      2000, 0, audioengine::DEFAULT_STREAM_IDLE_TIMEOUT_MS));
  CHECK(audioengine::streamIdleExpired(10, UINT32_MAX - 100, 110));

  // --- Fill-trend drift and underrun behavior ----------------------------
  const audioengine::DriftConfig drift = {
      1920, 1280, 2880, 400,
  };
  audioengine::FillTrendController fillController(drift);
  auto driftDecision = fillController.update(1920);
  CHECK(driftDecision.ppm == 0);
  driftDecision = fillController.update(1700);
  CHECK(driftDecision.trendFrames < 0);
  CHECK(driftDecision.ppm < 0);
  driftDecision = fillController.update(2300);
  CHECK(driftDecision.trendFrames > 0);
  CHECK(driftDecision.ppm > 0);
  driftDecision = fillController.update(3000);
  CHECK(driftDecision.hardCorrection ==
        audioengine::HardCorrection::DropCrossfadedBlock);
  CHECK(driftDecision.ppm <= drift.maxPpm);

  audioengine::ResampleCursor cursor;
  cursor.setCorrectionPpm(400);
  CHECK(cursor.advance(10000) == 10004);
  cursor.reset();
  cursor.setCorrectionPpm(-400);
  CHECK(cursor.advance(10000) == 9996);

  int16_t corrected[8] = {100, -100, 200, -200, 300, -300, 400, -400};
  const int16_t uncorrected[8] = {};
  CHECK(audioengine::crossfadeBlocks(uncorrected, corrected, 4, 2));
  CHECK(corrected[0] == 0);
  CHECK(corrected[1] == 0);
  CHECK(corrected[6] == 400);
  CHECK(corrected[7] == -400);
  CHECK(!audioengine::crossfadeBlocks(nullptr, corrected, 4, 2));
  int16_t fade[8] = {100, 100, 100, 100, 100, 100, 100, 100};
  CHECK(audioengine::applyEdgeFade(fade, 8, 1, 4, false));
  CHECK(fade[3] == 100);
  CHECK(fade[4] == 100);
  CHECK(fade[7] == 0);
  CHECK(audioengine::applyEdgeFade(fade, 8, 1, 4, true));
  CHECK(fade[0] == 0);
  CHECK(fade[3] == 100);
  CHECK(!audioengine::applyEdgeFade(nullptr, 8, 1, 4, true));

  audioengine::UnderrunController underrun;
  CHECK(underrun.update(1000, 0, 800, 1200, 160) ==
        audioengine::UnderrunState::Buffering);
  CHECK(underrun.update(1200, 200, 800, 1200, 160) ==
        audioengine::UnderrunState::Playing);
  CHECK(underrun.update(790, -20, 800, 1200, 160) ==
        audioengine::UnderrunState::FadingOut);
  CHECK(underrun.update(700, -10, 800, 1200, 160) ==
        audioengine::UnderrunState::SilentRefill);
  CHECK(underrun.update(1200, 200, 800, 1200, 160) ==
        audioengine::UnderrunState::FadingIn);
  CHECK(underrun.update(1180, -20, 800, 1200, 160) ==
        audioengine::UnderrunState::Playing);

  std::printf("audio stages 1-2: %d checks passed\n", checks);
  return 0;
}
