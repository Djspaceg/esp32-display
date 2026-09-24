#include <algorithm>
#include <cstdint>
#include <cstdlib>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

#include "../display_stream/audio_backend.h"
#include "../display_stream/audio_backend_model.h"
#include "../display_stream/audio_engine.h"
#include "../display_stream/audio_engine_model.h"
#include "../display_stream/audio_protocol.h"
#include "../display_stream/audio_test.h"
#include "../display_stream/audio_transport.h"
#include "../display_stream/app_state.h"
#include "../display_stream/device_protocol.h"
#include "../display_stream/display_power.h"
#include "../display_stream/mdns_announce.h"
#include "../display_stream/net_link.h"
#include "../display_stream/serial_config_protocol.h"
#include "../display_stream/telemetry.h"
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

static void putU16(std::vector<uint8_t> &bytes, size_t offset,
                   uint16_t value) {
  bytes[offset] = (uint8_t)value;
  bytes[offset + 1] = (uint8_t)(value >> 8);
}

static void putU32(std::vector<uint8_t> &bytes, size_t offset,
                   uint32_t value) {
  bytes[offset] = (uint8_t)value;
  bytes[offset + 1] = (uint8_t)(value >> 8);
  bytes[offset + 2] = (uint8_t)(value >> 16);
  bytes[offset + 3] = (uint8_t)(value >> 24);
}

static std::vector<uint8_t> documentedPcm(uint16_t sequence,
                                          uint32_t sampleCounter,
                                          uint16_t frameCount,
                                          uint8_t channels = 2,
                                          uint32_t sampleRateHz = 16000) {
  const size_t payloadBytes =
      (size_t)frameCount * channels * sizeof(int16_t);
  std::vector<uint8_t> bytes(audioproto::HEADER_BYTES + payloadBytes, 0);
  bytes[0] = 'E';
  bytes[1] = 'A';
  bytes[2] = 'U';
  bytes[3] = 'D';
  bytes[4] = 1;
  bytes[5] = 1;
  bytes[6] = 1;
  bytes[7] = channels;
  putU16(bytes, 8, sequence);
  putU16(bytes, 10, 9);
  putU32(bytes, 12, sampleRateHz);
  putU32(bytes, 16, sampleCounter);
  putU32(bytes, 20, 123456);
  putU16(bytes, 24, frameCount);
  putU16(bytes, 26, (uint16_t)payloadBytes);
  for (size_t i = 0; i < payloadBytes; ++i) {
    bytes[audioproto::HEADER_BYTES + i] = (uint8_t)i;
  }
  return bytes;
}

static audiotransport::Packet enginePacket(uint16_t sequence,
                                           uint32_t sampleCounter,
                                           uint16_t frameCount) {
  audiotransport::Packet packet = {};
  packet.header = {
      audioproto::DatagramKind::PcmDownlink,
      sequence,
      9,
      16000,
      sampleCounter,
      0,
      frameCount,
      2,
  };
  packet.payloadBytes = frameCount * 2 * sizeof(int16_t);
  for (size_t i = 0; i < frameCount * 2; ++i) {
    packet.samples[i] = (int16_t)(i + 1);
  }
  return packet;
}

static int testFinding1() {
  audiohost::reset();
  audiotransport::stop();
  audiotransport::hostResetStats();
  CHECK(audiotransport::start(board::CONFIG_AMOLED_CO5300));
  for (uint16_t sequence = 0; sequence < 10; ++sequence) {
    audiohost::enqueueUdp(documentedPcm(sequence, sequence, 1),
                          0x01020304, 6000);
  }
  audiotransport::hostReceiveBurst();
  CHECK(audiohost::delayCalls() == 1);
  CHECK(audiohost::yieldCalls() == 0);
  CHECK(audiohost::pendingUdp() == 1);
  audiotransport::stop();
  return 0;
}

static int testFinding2() {
  audiohost::reset();
  audiotransport::stop();
  audiotransport::hostResetStats();
  CHECK(audiotransport::start(board::CONFIG_AMOLED_CO5300));
  std::vector<uint8_t> overlong = documentedPcm(1, 0, 350);
  CHECK(overlong.size() == audioproto::MAX_DATAGRAM_BYTES);
  overlong.push_back(0xA5);
  audiohost::enqueueUdp(overlong, 0x01020304, 6000);
  audiotransport::hostReceiveBurst();
  CHECK(audiotransport::stats().badDatagrams == 1);
  CHECK(audiotransport::stats().oversizedDatagrams == 1);
  audiotransport::Packet packet = {};
  CHECK(!audiotransport::receive(packet, 0));
  audiotransport::stop();
  return 0;
}

static int testFinding3() {
  audiohost::reset();
  audiotransport::stop();
  audiotransport::hostResetStats();
  CHECK(audiotransport::start(board::CONFIG_AMOLED_CO5300));
  for (uint16_t sequence = 0; sequence < 13; ++sequence) {
    audiohost::enqueueUdp(documentedPcm(sequence, sequence, 1),
                          0x01020304, 6000);
  }
  audiotransport::hostReceiveBurst();
  audiotransport::hostReceiveBurst();
  CHECK(audiotransport::stats().queueDrops == 1);
  CHECK(audiotransport::stats().ingressDrops == 1);
  audiotransport::stop();

  audioengine::host::resetAdmission(4);
  CHECK(audioengine::host::admitPacket(enginePacket(1, 0, 3), 100));
  CHECK(!audioengine::host::admitPacket(enginePacket(2, 3, 2), 200));
  auto snapshot = audioengine::host::admissionSnapshot();
  CHECK(snapshot.fillFrames == 3);
  CHECK(snapshot.lastPacketAt == 100);
  CHECK(snapshot.engineDrops == 1);
  CHECK(audioengine::host::discardFrames(3));
  CHECK(audioengine::host::admitPacket(enginePacket(2, 3, 2), 300));
  CHECK(audioproto::STATUS_PAYLOAD_BYTES == 48);

  audioengine::PlaybackMetrics metrics;
  metrics.start(100, 1000);
  metrics.observe(50, audioengine::UnderrunState::FadingOut, 1010);
  metrics.observe(0, audioengine::UnderrunState::SilentRefill, 1030);
  CHECK(metrics.minimumFillFrames() == 0);
  CHECK(metrics.underrunDurationMs(1040) == 30);
  metrics.observe(100, audioengine::UnderrunState::Playing, 1050);
  CHECK(metrics.underrunDurationMs(2000) == 40);
  return 0;
}

static int testFinding4() {
  const int16_t input[8] = {
      100, 100, 100, 100, 100, 100, 100, 100,
  };
  const int16_t lastOutput[2] = {800, 0};
  int16_t output[8] = {};
  CHECK(!audioengine::host::renderFadingOut(
      input, 8, 1, 8, lastOutput, output));
  CHECK(output[0] == 800);
  CHECK(output[1] > output[2]);
  CHECK(output[2] > output[3]);
  CHECK(output[3] == 0);
  CHECK(output[4] == 0);
  return 0;
}

static int testFinding5() {
  audiohost::reset();
  hbIp = 0x11111111;
  hbPort = 1111;
  lastSenderPacketAt = 123;
  statBadLen = 0;
  audiohost::setMillis(999);
  const uint8_t audioMagic[] = {'E', 'A', 'U', 'D', 1};
  hostHandleInbound(audioMagic, sizeof(audioMagic), 0x22222222, 2222);
  CHECK(hbIp == 0x11111111);
  CHECK(hbPort == 1111);
  CHECK(lastSenderPacketAt == 123);
  CHECK(statBadLen == 1);
  return 0;
}

static int testFinding6() {
  const board::AudioConfig *mismatched =
      board::generatedAudioConfig(board::Variant::LcdSt77916);
  const board::AudioConfig *valid =
      board::generatedAudioConfig(board::Variant::AmoledCo5300);
  CHECK(mismatched != nullptr);
  CHECK(valid != nullptr);
  audio::CodecSerialAudioBackend backend;
  audiohost::reset();
  CHECK(!backend.start(board::CONFIG_AMOLED_CO5300, *mismatched,
                       audiobackend::descriptorFormat(*mismatched)));
  CHECK(audiohost::hardwareEvents().empty());

  board::AudioConfig malformed = *valid;
  malformed.codec = board::AudioCodec::Unknown;
  audiohost::reset();
  CHECK(!backend.start(board::CONFIG_AMOLED_CO5300, malformed,
                       audiobackend::descriptorFormat(malformed)));
  CHECK(audiohost::hardwareEvents().empty());

  audiohost::reset();
  backend.stop();
  CHECK(audiohost::hardwareEvents().empty());

  audiohost::reset();
  CHECK(backend.start(board::CONFIG_AMOLED_CO5300, *valid,
                      audiobackend::descriptorFormat(*valid)));
  const auto &events = audiohost::hardwareEvents();
  CHECK(events.size() > 6);
  CHECK(events[0].kind == audiohost::HardwareEventKind::PinMode);
  CHECK(events[0].value == valid->pinAmpEnable);
  CHECK(events[1].kind == audiohost::HardwareEventKind::DigitalWrite);
  CHECK(events[1].value == valid->pinAmpEnable * 10 + LOW);
  CHECK(events[2].kind == audiohost::HardwareEventKind::I2sSetPins);
  CHECK(events[3].kind == audiohost::HardwareEventKind::I2sBegin);
  CHECK(events[4].kind == audiohost::HardwareEventKind::I2sWrite);
  CHECK(events[5].kind == audiohost::HardwareEventKind::WireBegin);
  CHECK(events.back().kind == audiohost::HardwareEventKind::DigitalWrite);
  CHECK(events.back().value == valid->pinAmpEnable * 10 + HIGH);
  backend.stop();
  return 0;
}

static int testFinding7() {
  CHECK(!audiobackend::supportsCodecClock(24000));
  CHECK(audiobackend::supportsCodecClock(16000));
  CHECK(audiobackend::supportsCodecClock(44100));
  CHECK(audiobackend::supportsCodecClock(48000));
  CHECK(audiobackend::supportsCodecClock(64000));
  board::AudioConfig at24k = *board::generatedAudioConfig(
      board::Variant::AmoledCo5300);
  at24k.playbackRateHz = 24000;
  at24k.captureRateHz = 24000;
  audio::CodecSerialAudioBackend backend;
  audiohost::reset();
  CHECK(!backend.start(board::CONFIG_AMOLED_CO5300, at24k,
                       audiobackend::descriptorFormat(at24k)));
  CHECK(audiohost::hardwareEvents().empty());
  return 0;
}

static int testFinding9() {
  const std::filesystem::path procedure =
      std::filesystem::path(__FILE__).parent_path().parent_path()
          .parent_path() /
      "docs/audio-bringup-procedure.md";
  std::ifstream input(procedure);
  CHECK(input.good());
  const std::string text((std::istreambuf_iterator<char>(input)),
                         std::istreambuf_iterator<char>());
  CHECK(text.find("UDP listening on 5568") != std::string::npos);
  CHECK(text.find("Correct serial output with no tone points to the analog "
                  "path") == std::string::npos);
  return 0;
}

static int testRound3RejectedPeerOwnership() {
  constexpr uint32_t acceptedIp = 0x01020304;
  constexpr uint16_t acceptedPort = 6000;
  constexpr uint32_t rejectedIp = 0x05060708;
  constexpr uint16_t rejectedPort = 7000;

  audiohost::reset();
  audioengine::stop();
  audiotransport::stop();
  audiotransport::hostResetStats();
  CHECK(audiotransport::start(board::CONFIG_AMOLED_CO5300));
  CHECK(audioengine::start(board::CONFIG_AMOLED_CO5300));

  audiohost::enqueueUdp(documentedPcm(0, 0, 1),
                        acceptedIp, acceptedPort);
  audiotransport::hostReceiveBurst();
  CHECK(audioengine::host::runEngineTaskIterations(1));
  auto snapshot = audioengine::host::engineLoopSnapshot();
  CHECK(snapshot.packetsVisited == 1);
  CHECK(snapshot.packetsAccepted == 1);
  CHECK(audiotransport::sendStatus(9, 16000, {}));
  CHECK(audiohost::sentDatagrams().back().remoteIp == acceptedIp);
  CHECK(audiohost::sentDatagrams().back().remotePort == acceptedPort);

  audiohost::enqueueUdp(
      documentedPcm(1, 1, 1, 2, 48000), rejectedIp, rejectedPort);
  audiotransport::hostReceiveBurst();
  CHECK(audioengine::host::runEngineTaskIterations(1));
  snapshot = audioengine::host::engineLoopSnapshot();
  CHECK(snapshot.packetsVisited == 1);
  CHECK(snapshot.packetsAccepted == 0);
  CHECK(snapshot.engineDrops == 1);
  CHECK(audiotransport::sendStatus(9, 16000, {}));
  CHECK(audiohost::sentDatagrams().back().remoteIp == acceptedIp);
  CHECK(audiohost::sentDatagrams().back().remotePort == acceptedPort);

  audioengine::stop();
  audiotransport::stop();
  return 0;
}

static int testRound3QueueFullPeerOwnership() {
  constexpr uint32_t acceptedIp = 0x01020304;
  constexpr uint16_t acceptedPort = 6000;
  constexpr uint32_t rejectedIp = 0x05060708;
  constexpr uint16_t rejectedPort = 7000;

  audiohost::reset();
  audioengine::stop();
  audiotransport::stop();
  audiotransport::hostResetStats();
  CHECK(audiotransport::start(board::CONFIG_AMOLED_CO5300));
  CHECK(audioengine::start(board::CONFIG_AMOLED_CO5300));

  audiohost::enqueueUdp(documentedPcm(0, 0, 1),
                        acceptedIp, acceptedPort);
  audiotransport::hostReceiveBurst();
  CHECK(audioengine::host::runEngineTaskIterations(1));
  const auto snapshot = audioengine::host::engineLoopSnapshot();
  CHECK(snapshot.packetsAccepted == 1);
  CHECK(audiotransport::sendStatus(9, 16000, {}));
  CHECK(audiohost::sentDatagrams().back().remoteIp == acceptedIp);
  CHECK(audiohost::sentDatagrams().back().remotePort == acceptedPort);

  for (uint16_t sequence = 0; sequence < audiotransport::QUEUE_DEPTH;
       ++sequence) {
    audiohost::enqueueUdp(documentedPcm(sequence, sequence, 1),
                          acceptedIp, acceptedPort);
  }
  audiohost::enqueueUdp(
      documentedPcm(12, 12, 1), rejectedIp, rejectedPort);
  audiotransport::hostReceiveBurst();
  audiotransport::hostReceiveBurst();
  CHECK(audiotransport::stats().queueDrops == 1);
  CHECK(audiotransport::sendStatus(9, 16000, {}));
  CHECK(audiohost::sentDatagrams().back().remoteIp == acceptedIp);
  CHECK(audiohost::sentDatagrams().back().remotePort == acceptedPort);

  audioengine::stop();
  audiotransport::stop();
  return 0;
}

static int testRound3EngineLoopSkipsRejectedPacket() {
  constexpr uint32_t acceptedIp = 0x01020304;
  constexpr uint16_t acceptedPort = 6000;

  audiohost::reset();
  audioengine::stop();
  audiotransport::stop();
  audiotransport::hostResetStats();
  CHECK(audiotransport::start(board::CONFIG_AMOLED_CO5300));
  CHECK(audioengine::start(board::CONFIG_AMOLED_CO5300));

  audiohost::enqueueUdp(
      documentedPcm(0, 0, 1, 2, 48000), 0x05060708, 7000);
  audiohost::enqueueUdp(
      documentedPcm(0, 0, 1), acceptedIp, acceptedPort);
  audiotransport::hostReceiveBurst();
  CHECK(audioengine::host::runEngineTaskIterations(1));
  const auto snapshot = audioengine::host::engineLoopSnapshot();
  CHECK(snapshot.packetsVisited == 2);
  CHECK(snapshot.packetsAccepted == 1);
  CHECK(snapshot.engineDrops == 1);
  audiotransport::Packet remaining = {};
  CHECK(!audiotransport::receive(remaining, 0));
  CHECK(audiotransport::sendStatus(9, 16000, {}));
  CHECK(audiohost::sentDatagrams().back().remoteIp == acceptedIp);
  CHECK(audiohost::sentDatagrams().back().remotePort == acceptedPort);

  audioengine::stop();
  audiotransport::stop();
  return 0;
}

static int testRound3EngineLoopObservesPlaybackMetrics() {
  constexpr uint32_t acceptedIp = 0x01020304;
  constexpr uint16_t acceptedPort = 6000;
  constexpr uint16_t framesPerPacket = 320;

  audiohost::reset();
  audioengine::stop();
  audiotransport::stop();
  audiotransport::hostResetStats();
  CHECK(audiotransport::start(board::CONFIG_AMOLED_CO5300));
  CHECK(audioengine::start(board::CONFIG_AMOLED_CO5300));
  for (uint16_t sequence = 0; sequence < 6; ++sequence) {
    audiohost::enqueueUdp(
        documentedPcm(sequence, sequence * framesPerPacket,
                      framesPerPacket),
        acceptedIp, acceptedPort);
  }
  audiotransport::hostReceiveBurst();
  audiohost::setMillis(250);
  CHECK(audioengine::host::runEngineTaskIterations(2));
  const auto snapshot = audioengine::host::engineLoopSnapshot();
  CHECK(snapshot.packetsVisited == 6);
  CHECK(snapshot.packetsAccepted == 6);
  CHECK(snapshot.metricsObserveCalls == 1);
  CHECK(snapshot.minimumFillFrames == 1760);

  const auto &sent = audiohost::sentDatagrams();
  const auto status = std::find_if(
      sent.begin(), sent.end(), [](const audiohost::SentDatagram &datagram) {
        return datagram.data.size() >= audioproto::HEADER_BYTES &&
               datagram.data[5] ==
                   (uint8_t)audioproto::DatagramKind::Status;
      });
  CHECK(status != sent.end());
  CHECK(status->remoteIp == acceptedIp);
  CHECK(status->remotePort == acceptedPort);
  CHECK(audioproto::readU32LE(
            status->data.data() + audioproto::HEADER_BYTES) == 1760);
  CHECK(audioproto::readU32LE(
            status->data.data() + audioproto::HEADER_BYTES + 8) == 1760);

  audioengine::stop();
  audiotransport::stop();
  return 0;
}

int main() {
  const char *filter = std::getenv("AUDIO_TEST_FILTER");
  const struct {
    const char *name;
    int (*test)();
  } findingTests[] = {
      {"1", testFinding1},
      {"2", testFinding2},
      {"3", testFinding3},
      {"4", testFinding4},
      {"5", testFinding5},
      {"6", testFinding6},
      {"7", testFinding7},
      {"9", testFinding9},
      {"round3-peer-rejected", testRound3RejectedPeerOwnership},
      {"round3-peer-queue", testRound3QueueFullPeerOwnership},
      {"round3-engine-loop", testRound3EngineLoopSkipsRejectedPacket},
      {"round3-engine-metrics",
       testRound3EngineLoopObservesPlaybackMetrics},
  };
  for (const auto &finding : findingTests) {
    if (filter == nullptr || std::strcmp(filter, finding.name) == 0) {
      if (finding.test() != 0) return 1;
      if (filter != nullptr) {
        std::printf("audio finding %s: %d checks passed\n",
                    finding.name, checks);
        return 0;
      }
    }
  }

  const char *noAudioError =
      startAudioToneTest(board::CONFIG_TOUCH_JD9853, 1000);
  CHECK(noAudioError != nullptr);
  CHECK(std::strcmp(noAudioError, "board descriptor has no audio") == 0);
  CHECK((deviceCapabilities() & deviceproto::CAP_AUDIO_DOWNLINK) != 0);
  CHECK((deviceCapabilities() & deviceproto::CAP_AUDIO_UPLINK) != 0);
  addMdnsService();

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
  const uint8_t expectedPacket[] = {
      'E', 'A', 'U', 'D', 1, 1, 1, 2,
      7, 0, 3, 0,
      0x80, 0x3E, 0, 0,
      0x40, 0x01, 0, 0,
      0x40, 0xE2, 0x01, 0,
      4, 0, 16, 0,
      0, 1, 2, 3, 4, 5, 6, 7,
      8, 9, 10, 11, 12, 13, 14, 15,
  };
  CHECK(sizeof(expectedPacket) == packetBytes);
  CHECK(std::memcmp(packet, expectedPacket, packetBytes) == 0);
  CHECK(audioproto::hasAudioMagic(expectedPacket, sizeof(expectedPacket)));
  CHECK(!audioproto::hasAudioMagic(expectedPacket, 3));
  CHECK(!audioproto::hasAudioMagic(nullptr, sizeof(expectedPacket)));
  audioproto::PcmDatagram parsed = {};
  CHECK(audioproto::parsePcmDownlink(
            expectedPacket, sizeof(expectedPacket), parsed) ==
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
      100, 120, 80, 2, 250, 3, 4, 5, 6, 7, 8, 9,
  };
  const size_t statusBytes = audioproto::writeStatus(
      packet, sizeof(packet), 8, 9, 48000, 10, status);
  CHECK(statusBytes ==
        audioproto::HEADER_BYTES + audioproto::STATUS_PAYLOAD_BYTES);
  std::vector<uint8_t> expectedStatus(statusBytes, 0);
  expectedStatus[0] = 'E';
  expectedStatus[1] = 'A';
  expectedStatus[2] = 'U';
  expectedStatus[3] = 'D';
  expectedStatus[4] = 1;
  expectedStatus[5] = 3;
  putU16(expectedStatus, 8, 8);
  putU16(expectedStatus, 10, 9);
  putU32(expectedStatus, 12, 48000);
  putU32(expectedStatus, 20, 10);
  putU16(expectedStatus, 26, 48);
  const uint32_t expectedStatusFields[] = {
      100, 120, 80, 2, 250, 3, 4, 5, 6, 7, 8, 9,
  };
  for (size_t i = 0; i < 12; ++i) {
    putU32(expectedStatus, audioproto::HEADER_BYTES + i * 4,
           expectedStatusFields[i]);
  }
  CHECK(std::memcmp(packet, expectedStatus.data(), statusBytes) == 0);

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
  CHECK(corrected[2] == 66);
  CHECK(corrected[3] == -66);
  CHECK(corrected[4] == 200);
  CHECK(corrected[5] == -200);
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
