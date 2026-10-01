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
#include "fakes/audio/ESPmDNS.h"
#include "fakes/audio/WiFi.h"
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
  audio::resetBoardAudioStatusForTest();
  CHECK(backend.start(board::CONFIG_AMOLED_CO5300, *valid,
                      audiobackend::descriptorFormat(*valid)));
  const auto &events = audiohost::hardwareEvents();
  // The read-only chip-ID probe runs first; only then does any pin move.
  size_t first = 0;
  while (first < events.size() &&
         (events[first].kind == audiohost::HardwareEventKind::WireBegin ||
          events[first].kind ==
              audiohost::HardwareEventKind::WireTransmission ||
          events[first].kind == audiohost::HardwareEventKind::WireRequest)) {
    ++first;
  }
  CHECK(first >= 9);
  CHECK(events.size() > first + 5);
  // Identification and start() each drive the amp low before any clock.
  size_t ampLowPairs = 0;
  while (first + 1 < events.size() &&
         events[first].kind == audiohost::HardwareEventKind::PinMode &&
         events[first].value == valid->pinAmpEnable &&
         events[first + 1].kind ==
             audiohost::HardwareEventKind::DigitalWrite &&
         events[first + 1].value == valid->pinAmpEnable * 10 + LOW) {
    first += 2;
    ++ampLowPairs;
  }
  CHECK(ampLowPairs >= 1);
  first -= 2;
  CHECK(events[first + 2].kind == audiohost::HardwareEventKind::I2sSetPins);
  CHECK(events[first + 3].kind == audiohost::HardwareEventKind::I2sBegin);
  CHECK(events[first + 4].kind == audiohost::HardwareEventKind::I2sWrite);
  CHECK(events[first + 5].kind ==
        audiohost::HardwareEventKind::WireTransmission);
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


// The loop task's tone-test service must leave a backend it did not start
// alone. It used to stop any running backend while no tone was pending, so the
// moment a sender's stream started the codec on the 1.85C it tore I2S down
// under the engine (TX deleted, RX left half-disabled), the engine spun on the
// failed I2S calls at priority 12, and the loop-task watchdog rebooted the
// board every ~13 s.
static int testToneServiceLeavesNetworkStreamRunning() {
  constexpr uint32_t senderIp = 0x01020304;
  constexpr uint16_t senderPort = 6000;
  constexpr uint16_t framesPerPacket = 320;

  audiohost::reset();
  audio::resetBoardAudioStatusForTest();
  audioengine::stop();
  audiotransport::stop();
  audiotransport::hostResetStats();
  CHECK(audiotransport::start(board::CONFIG_LCD_ST77916));
  CHECK(audioengine::start(board::CONFIG_LCD_ST77916));
  for (uint16_t sequence = 0; sequence < 6; ++sequence) {
    audiohost::enqueueUdp(
        documentedPcm(sequence, sequence * framesPerPacket, framesPerPacket),
        senderIp, senderPort);
  }
  audiotransport::hostReceiveBurst();
  audiohost::setMillis(250);
  CHECK(audioengine::host::runEngineTaskIterations(2));
  audio::CodecSerialAudioBackend &backend = audio::sharedCodecBackend();
  CHECK(backend.running());
  const auto i2sEnds = [] {
    return std::count_if(
        audiohost::hardwareEvents().begin(), audiohost::hardwareEvents().end(),
        [](const audiohost::HardwareEvent &event) {
          return event.kind == audiohost::HardwareEventKind::I2sEnd;
        });
  };
  const auto endsBefore = i2sEnds();

  serviceAudioToneTest();

  CHECK(backend.running());
  CHECK(i2sEnds() == endsBefore);
  CHECK(!audioToneTestRunning());

  audioengine::stop();
  audiotransport::stop();
  audio::resetBoardAudioStatusForTest();
  return 0;
}

// A backend whose I2S calls fail at once (a deleted or disabled channel) must
// be stopped and the engine must sleep, not retry. Before, the engine looped on
// the failed calls at priority 12 on the loop task's core, starving it until
// the 10 s loop watchdog rebooted the board.
static int testFailedI2sStopsBackendAndYields() {
  constexpr uint32_t senderIp = 0x01020304;
  constexpr uint16_t senderPort = 6000;
  constexpr uint16_t framesPerPacket = 320;

  audiohost::reset();
  audio::resetBoardAudioStatusForTest();
  audioengine::stop();
  audiotransport::stop();
  audiotransport::hostResetStats();
  CHECK(audiotransport::start(board::CONFIG_LCD_ST77916));
  CHECK(audioengine::start(board::CONFIG_LCD_ST77916));
  for (uint16_t sequence = 0; sequence < 6; ++sequence) {
    audiohost::enqueueUdp(
        documentedPcm(sequence, sequence * framesPerPacket, framesPerPacket),
        senderIp, senderPort);
  }
  audiotransport::hostReceiveBurst();
  audiohost::setMillis(250);
  CHECK(audioengine::host::runEngineTaskIterations(2));
  audio::CodecSerialAudioBackend &backend = audio::sharedCodecBackend();
  CHECK(backend.running());

  audiohost::setI2sFailing(true);
  const unsigned delaysBefore = audiohost::delayCalls();
  CHECK(audioengine::host::runEngineTaskIterations(1));
  CHECK(!backend.running());
  CHECK(audiohost::delayCalls() > delaysBefore);
  CHECK(!audioengine::streamActive());

  audioengine::stop();
  audiotransport::stop();
  audio::resetBoardAudioStatusForTest();
  return 0;
}

static void queueSenderStream(uint16_t packets) {
  constexpr uint16_t framesPerPacket = 320;
  for (uint16_t sequence = 0; sequence < packets; ++sequence) {
    audiohost::enqueueUdp(
        documentedPcm(sequence, sequence * framesPerPacket, framesPerPacket),
        0x01020304, 6000);
  }
  audiotransport::hostReceiveBurst();
}

// A tone runs to completion, then gives the codec back: ownership and the
// engine's local-test hold are both released, so a sender's stream plays.
static int testToneLifecycleReleasesTheBackend() {
  audiohost::reset();
  audio::resetBoardAudioStatusForTest();
  audioengine::stop();
  audiotransport::stop();
  audiotransport::hostResetStats();
  CHECK(audiotransport::start(board::CONFIG_LCD_ST77916));
  CHECK(audioengine::start(board::CONFIG_LCD_ST77916));
  CHECK(startAudioToneTest(board::CONFIG_LCD_ST77916, 100) == nullptr);
  CHECK(audioToneTestRunning());
  for (int pass = 0; pass < 32 && audioToneTestRunning(); ++pass) {
    serviceAudioToneTest();
  }
  serviceAudioToneTest();
  CHECK(!audioToneTestRunning());
  CHECK(!audio::sharedCodecBackend().running());

  queueSenderStream(6);
  audiohost::setMillis(250);
  CHECK(audioengine::host::runEngineTaskIterations(2));
  CHECK(audioengine::streamActive());
  CHECK(audio::sharedCodecBackend().running());

  audioengine::stop();
  audiotransport::stop();
  audio::resetBoardAudioStatusForTest();
  return 0;
}

// A tone whose backend is stopped underneath it (the engine's dead-I2S path)
// must not keep the engine on hold: the next service releases it.
static int testStaleToneOwnershipIsReleased() {
  audiohost::reset();
  audio::resetBoardAudioStatusForTest();
  audioengine::stop();
  audiotransport::stop();
  audiotransport::hostResetStats();
  CHECK(audiotransport::start(board::CONFIG_LCD_ST77916));
  CHECK(audioengine::start(board::CONFIG_LCD_ST77916));
  CHECK(startAudioToneTest(board::CONFIG_LCD_ST77916, 1000) == nullptr);
  audio::sharedCodecBackend().stop();
  serviceAudioToneTest();
  CHECK(!audioToneTestRunning());

  queueSenderStream(6);
  audiohost::setMillis(250);
  CHECK(audioengine::host::runEngineTaskIterations(2));
  CHECK(audioengine::streamActive());

  audioengine::stop();
  audiotransport::stop();
  audio::resetBoardAudioStatusForTest();
  return 0;
}

static bool anyPinOrClockEvent() {
  for (const auto &event : audiohost::hardwareEvents()) {
    if (event.kind != audiohost::HardwareEventKind::WireBegin &&
        event.kind != audiohost::HardwareEventKind::WireTransmission &&
        event.kind != audiohost::HardwareEventKind::WireRequest) {
      return true;
    }
  }
  return false;
}

static bool ampDrivenHigh(int pin) {
  for (const auto &event : audiohost::hardwareEvents()) {
    if (event.kind == audiohost::HardwareEventKind::DigitalWrite &&
        event.value == pin * 10 + HIGH) {
      return true;
    }
  }
  return false;
}

// The 1.85C V1 carries PCM5101A + ICS-43434, neither of which has an I2C
// interface, so nothing answers at 0x18 or 0x40. Audio must stay off with no
// audio GPIO, clock, or codec register touched.
static int testIdentity185cV1() {
  const board::AudioConfig *audio =
      board::generatedAudioConfig(board::Variant::LcdSt77916);
  CHECK(audio != nullptr);
  audiohost::reset();
  audio::resetBoardAudioStatusForTest();
  audiohost::setI2cDevice(0x18, false);
  audiohost::setI2cDevice(0x40, false);
  CHECK(audio::boardAudioStatus(board::CONFIG_LCD_ST77916) ==
        audiobackend::DescriptorStatus::HardwareNotIdentified);
  CHECK(!anyPinOrClockEvent());
  CHECK(audiohost::wireRegisterWrites() == 0);
  CHECK(!audiotransport::start(board::CONFIG_LCD_ST77916));
  CHECK(!audioengine::start(board::CONFIG_LCD_ST77916));
  const char *error = startAudioToneTest(board::CONFIG_LCD_ST77916, 1000);
  CHECK(error != nullptr);
  CHECK(std::strcmp(
            error,
            "audio disabled: board revision is not safely distinguishable") ==
        0);
  audio::CodecSerialAudioBackend backend;
  CHECK(!backend.start(board::CONFIG_LCD_ST77916, *audio,
                       audiobackend::descriptorFormat(*audio)));
  CHECK(!anyPinOrClockEvent());
  CHECK(!ampDrivenHigh(audio->pinAmpEnable));
  CHECK(audiohost::wireRegisterWrites() == 0);
  audio::resetBoardAudioStatusForTest();
  return 0;
}

// The 1.85C V2: genuine ES8311 and ES7210 IDs. Audio is enabled, and the
// amplifier is driven off at identification rather than left floating.
static int testIdentity185cV2() {
  const board::AudioConfig *audio =
      board::generatedAudioConfig(board::Variant::LcdSt77916);
  CHECK(audio != nullptr);
  audiohost::reset();
  audio::resetBoardAudioStatusForTest();
  CHECK(audio::boardAudioStatus(board::CONFIG_LCD_ST77916) ==
        audiobackend::DescriptorStatus::Ready);
  CHECK(audiohost::wireRegisterWrites() == 0);
  const auto &events = audiohost::hardwareEvents();
  CHECK(events.size() >= 2);
  CHECK(events[events.size() - 2].kind ==
        audiohost::HardwareEventKind::PinMode);
  CHECK(events[events.size() - 2].value == audio->pinAmpEnable);
  CHECK(events.back().value == audio->pinAmpEnable * 10 + LOW);
  CHECK(!ampDrivenHigh(audio->pinAmpEnable));
  // The cached answer is reused: a second query does not probe again.
  const size_t before = events.size();
  CHECK(audio::boardAudioStatus(board::CONFIG_LCD_ST77916) ==
        audiobackend::DescriptorStatus::Ready);
  CHECK(audiohost::hardwareEvents().size() == before);
  audio::resetBoardAudioStatusForTest();
  return 0;
}

// An ACK is not identification: some other device strapped to 0x18, or only
// one of the two parts present, keeps audio off with the pins untouched.
static int testIdentityRejectsImpostors() {
  const board::AudioConfig *audio =
      board::generatedAudioConfig(board::Variant::LcdSt77916);
  CHECK(audio != nullptr);
  struct Case {
    bool codecPresent;
    uint8_t codecId1;
    bool micPresent;
    uint8_t micId1;
  } cases[] = {
      {true, 0x33, true, 0x72},   // wrong device at 0x18
      {true, 0x83, true, 0x00},   // wrong device at 0x40
      {true, 0x83, false, 0x72},  // codec alone
      {false, 0x83, true, 0x72},  // ADC alone
  };
  for (const Case &item : cases) {
    audiohost::reset();
    audio::resetBoardAudioStatusForTest();
    audiohost::setI2cDevice(0x18, item.codecPresent, 0xFD, item.codecId1,
                            0xFE, 0x11);
    audiohost::setI2cDevice(0x40, item.micPresent, 0x3D, item.micId1, 0x3E,
                            0x10);
    CHECK(audio::boardAudioStatus(board::CONFIG_LCD_ST77916) ==
          audiobackend::DescriptorStatus::HardwareNotIdentified);
    audio::CodecSerialAudioBackend backend;
    CHECK(!backend.start(board::CONFIG_LCD_ST77916, *audio,
                         audiobackend::descriptorFormat(*audio)));
    CHECK(!anyPinOrClockEvent());
    CHECK(audiohost::wireRegisterWrites() == 0);
  }
  audio::resetBoardAudioStatusForTest();
  return 0;
}

// The 0.85 has no touch controller, so its codec bus comes from the audio
// descriptor rather than the (absent) touch pins.
static int testControlBusWithoutTouch() {
  const board::AudioConfig *audio =
      board::generatedAudioConfig(board::Variant::LcdGc9107);
  CHECK(audio != nullptr);
  CHECK(board::CONFIG_LCD_GC9107.pinTouchSda == board::NO_PIN);
  const audiobackend::ControlBus bus =
      audiobackend::controlBus(board::CONFIG_LCD_GC9107, *audio);
  CHECK(bus.sda == 42 && bus.scl == 41);
  const board::AudioConfig *touchBus =
      board::generatedAudioConfig(board::Variant::TouchSt7789);
  CHECK(touchBus != nullptr);
  CHECK(touchBus->pinControlSda == board::NO_PIN);
  const audiobackend::ControlBus shared =
      audiobackend::controlBus(board::CONFIG_TOUCH_ST7789, *touchBus);
  CHECK(shared.sda == board::CONFIG_TOUCH_ST7789.pinTouchSda &&
        shared.scl == board::CONFIG_TOUCH_ST7789.pinTouchScl);
  return 0;
}

// Every board whose descriptor names ES8311 + ES7210 + NS4150B is enabled at
// runtime once identified, including both P4 carriers.
static int testIdentityEnablesEveryCodecBoard() {
  const board::Config *boards[] = {&board::CONFIG_AMOLED_CO5300,
                                   &board::CONFIG_LCD_ST77916,
                                   &board::CONFIG_LCD_GC9107,
                                   &board::CONFIG_TOUCH_ST7789,
                                   &board::CONFIG_P4_4B,
                                   &board::CONFIG_P4_4C,
                                   &board::CONFIG_P4_34C};
  for (const board::Config *config : boards) {
    const board::AudioConfig *audio =
        board::generatedAudioConfig(config->variant);
    CHECK(audio != nullptr);
    CHECK(board::supportsAudio(config->variant));
    CHECK(audiobackend::classify(*audio) ==
          audiobackend::DescriptorStatus::Ready);
    CHECK(audiobackend::matchesBoard(*config, *audio));
    audiohost::reset();
    audio::resetBoardAudioStatusForTest();
    CHECK(audio::boardAudioStatus(*config) ==
          audiobackend::DescriptorStatus::Ready);
    // The probe runs on the codec control bus: the touch bus, or the
    // descriptor's own pair on a board without touch.
    const audiobackend::ControlBus bus =
        audiobackend::controlBus(*config, *audio);
    CHECK(bus.sda != board::NO_PIN && bus.scl != board::NO_PIN);
    CHECK(audiohost::hardwareEvents().front().kind ==
          audiohost::HardwareEventKind::WireBegin);
    CHECK(audiohost::hardwareEvents().front().value ==
          bus.sda * 100 + bus.scl);
    // Once the boot verdict is cached, start() (which also runs on the
    // engine task) issues no I2C read: a read there would race the loop
    // task's touch and IMU reads on the unlocked Wire receive buffer.
    const size_t probeEvents = audiohost::hardwareEvents().size();
    audio::CodecSerialAudioBackend backend;
    CHECK(backend.start(*config, *audio,
                        audiobackend::descriptorFormat(*audio)));
    for (size_t index = probeEvents;
         index < audiohost::hardwareEvents().size(); ++index) {
      CHECK(audiohost::hardwareEvents()[index].kind !=
            audiohost::HardwareEventKind::WireRequest);
    }
    CHECK(ampDrivenHigh(audio->pinAmpEnable));
    backend.stop();
    CHECK(audiohost::hardwareEvents().back().kind ==
          audiohost::HardwareEventKind::I2sEnd);
  }
  audio::resetBoardAudioStatusForTest();
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
      {"identity-185c-v1", testIdentity185cV1},
      {"identity-185c-v2", testIdentity185cV2},
      {"identity-impostors", testIdentityRejectsImpostors},
      {"identity-every-codec-board", testIdentityEnablesEveryCodecBoard},
      {"control-bus-without-touch", testControlBusWithoutTouch},
      {"round3-peer-rejected", testRound3RejectedPeerOwnership},
      {"round3-peer-queue", testRound3QueueFullPeerOwnership},
      {"round3-engine-loop", testRound3EngineLoopSkipsRejectedPacket},
      {"round3-engine-metrics",
       testRound3EngineLoopObservesPlaybackMetrics},
      {"tone-service-leaves-stream",
       testToneServiceLeavesNetworkStreamRunning},
      {"failed-i2s-yields", testFailedI2sStopsBackendAndYields},
      {"tone-lifecycle", testToneLifecycleReleasesTheBackend},
      {"tone-stale-ownership", testStaleToneOwnershipIsReleased},
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
  // Quarter turns are advertised wherever the backend validated them, square
  // or not: on rectangular glass 90/270 is landscape.
  CHECK((deviceCapabilities() & deviceproto::CAP_ROTATE) != 0);
  {
    const board::Config *saved = bcfg;
    const board::Config *rectangular[] = {&board::CONFIG_LCD_ST7789_190,
                                          &board::CONFIG_LCD_ST7789,
                                          &board::CONFIG_TOUCH_JD9853};
    for (const board::Config *config : rectangular) {
      bcfg = config;
      CHECK(bcfg->panel->width != bcfg->panel->height);
      CHECK((deviceCapabilities() & deviceproto::CAP_ROTATE) != 0);
    }
    bcfg = saved;
  }
  // The joined network is announced, so a sender that only sees the panel over
  // WiFi can show which network it is on. Taken from the radio, not from the
  // saved credentials: it is the network actually joined.
  WiFi.setSSID("Studio WiFi");
  MDNS.clearTxt();
  addMdnsService();
  CHECK(MDNS.hasTxt("ssid"));
  CHECK(MDNS.txt("ssid") == "Studio WiFi");
  CHECK(MDNS.txt("name") == cfgName.c_str());
  CHECK(mdnsSsidIsCurrent());
  // Announced before WiFi joined (setup's timeout path, or a join between
  // setup and the first loop): the loop has to notice and re-announce.
  WiFi.setSSID("");
  addMdnsService();
  WiFi.setSSID("Studio WiFi");
  CHECK(!mdnsSsidIsCurrent());
  addMdnsService();
  CHECK(mdnsSsidIsCurrent());

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
  CHECK(classify(*v2) == DescriptorStatus::Ready);
  CHECK(runtimeStatus(*v2, false) == DescriptorStatus::HardwareNotIdentified);
  CHECK(runtimeStatus(*v2, true) == DescriptorStatus::Ready);
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
