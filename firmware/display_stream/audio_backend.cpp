#include "audio_backend.h"

#include <Arduino.h>
#if defined(ESPDISP_AUDIO_RUNTIME)
#include <ESP_I2S.h>
#include <Wire.h>

#include <new>
#endif

namespace audio {
CodecSerialAudioBackend &sharedCodecBackend() {
  static CodecSerialAudioBackend backend;
  return backend;
}

namespace {

// One probe per boot: capability bits, mDNS records, and every later start
// agree on the same answer.
bool statusKnown = false;
board::Variant statusVariant = {};
audiobackend::DescriptorStatus cachedStatus =
    audiobackend::DescriptorStatus::NoAudio;

}  // namespace

audiobackend::DescriptorStatus boardAudioStatus(
    const board::Config &boardConfig) {
  if (statusKnown && statusVariant == boardConfig.variant) return cachedStatus;
  const board::AudioConfig *audioConfig =
      board::generatedAudioConfig(boardConfig.variant);
  audiobackend::DescriptorStatus status =
      audioConfig == nullptr ? audiobackend::DescriptorStatus::NoAudio
                             : audiobackend::classify(*audioConfig);
  if (status == audiobackend::DescriptorStatus::Ready) {
    const audiobackend::CodecProbe probe =
        probeCodecs(boardConfig, *audioConfig);
    const bool identified = audiobackend::codecsIdentified(probe);
    status = audiobackend::runtimeStatus(*audioConfig, identified);
    Serial.printf(
        "audio: codec 0x%02x %s id=%02x%02x, adc 0x%02x %s id=%02x%02x: %s\n",
        (unsigned)audioConfig->codecI2cAddress,
        probe.codecRead ? "read" : "no-ack", (unsigned)probe.codecId1,
        (unsigned)probe.codecId2, (unsigned)audioConfig->micI2cAddress,
        probe.micRead ? "read" : "no-ack", (unsigned)probe.micId1,
        (unsigned)probe.micId0,
        identified ? "ES8311+ES7210 identified, amp held off"
                   : "not identified, audio pins untouched");
    if (identified) {
      pinMode(audioConfig->pinAmpEnable, OUTPUT);
      digitalWrite(audioConfig->pinAmpEnable, LOW);
    }
  }
  statusKnown = true;
  statusVariant = boardConfig.variant;
  cachedStatus = status;
  return status;
}

#if defined(ESPDISP_HOST_AUDIO_TEST)
void resetBoardAudioStatusForTest() {
  statusKnown = false;
  cachedStatus = audiobackend::DescriptorStatus::NoAudio;
}
#endif

#if defined(ESPDISP_AUDIO_RUNTIME)
namespace {

// Fixed storage rather than a plain global, so releaseI2s() can rebuild the
// object in place, at the same address, after deleting channels behind its
// back.
alignas(I2SClass) uint8_t audioI2sStorage[sizeof(I2SClass)];
I2SClass *audioI2sObject = nullptr;

I2SClass &audioI2s() {
  if (audioI2sObject == nullptr) {
    audioI2sObject = new (audioI2sStorage) I2SClass();
  }
  return *audioI2sObject;
}

// The core's begin() creates the channel before configuring it, so a
// configuration that fails - an I2S DMA descriptor allocation, on a P4 short
// of internal DMA RAM - returns false with the channel still allocated. Its
// end() disables each channel before deleting it and returns on the first
// error, and a channel that was never enabled cannot be disabled, so end()
// leaves it allocated too. Every later begin() then fails with "no available
// channel found" until a reboot. end() clears a handle only once it has
// deleted it, so a handle still set after end() is a live channel: delete it
// here, then rebuild the object so it forgets the deleted handles. Disable
// first (an error there just means it never ran): the driver refuses to
// delete a running channel, and a refused delete keeps its handle, so the
// object is rebuilt only once every live handle is really gone.
bool deleteChannel(i2s_chan_handle_t channel) {
  if (channel == nullptr) return true;
  i2s_channel_disable(channel);
  return i2s_del_channel(channel) == ESP_OK;
}

void releaseI2s() {
  I2SClass &i2s = audioI2s();
  i2s.end();
  i2s_chan_handle_t tx = i2s.txChan();
  i2s_chan_handle_t rx = i2s.rxChan();
  if (tx == nullptr && rx == nullptr) return;
  const bool txGone = deleteChannel(tx);
  const bool rxGone = deleteChannel(rx);
  if (!txGone || !rxGone) {
    Serial.println("audio: ERROR could not release the I2S channel");
    return;
  }
  i2s.~I2SClass();
  audioI2sObject = new (audioI2sStorage) I2SClass();
}

constexpr uint32_t CONTROL_I2C_HZ = 400000;
constexpr uint32_t CODEC_SETTLE_MS = 10;
constexpr size_t PRIME_FRAMES = 80;
// Playback-only primes one whole I2SClass DMA buffer (240 frames), so a
// caller that writes whole buffers starts aligned to them: ESP-IDF drops a
// partly filled buffer when its free queue runs short, which is a hole.
constexpr size_t PLAYBACK_ONLY_PRIME_FRAMES = 240;

// ES8311 registers used by the vendor initialization sequence.
constexpr uint8_t ES8311_RESET = 0x00;
constexpr uint8_t ES8311_CLOCK1 = 0x01;
constexpr uint8_t ES8311_CLOCK2 = 0x02;
constexpr uint8_t ES8311_CLOCK3 = 0x03;
constexpr uint8_t ES8311_CLOCK4 = 0x04;
constexpr uint8_t ES8311_CLOCK5 = 0x05;
constexpr uint8_t ES8311_CLOCK6 = 0x06;
constexpr uint8_t ES8311_CLOCK7 = 0x07;
constexpr uint8_t ES8311_CLOCK8 = 0x08;
constexpr uint8_t ES8311_SDP_IN = 0x09;
constexpr uint8_t ES8311_SDP_OUT = 0x0A;
constexpr uint8_t ES8311_SYSTEM0D = 0x0D;
constexpr uint8_t ES8311_SYSTEM0E = 0x0E;
constexpr uint8_t ES8311_SYSTEM12 = 0x12;
constexpr uint8_t ES8311_SYSTEM13 = 0x13;
constexpr uint8_t ES8311_ADC1C = 0x1C;
constexpr uint8_t ES8311_DAC_MUTE = 0x31;
constexpr uint8_t ES8311_DAC_VOLUME = 0x32;
constexpr uint8_t ES8311_DAC_RAMP = 0x37;

// ES7210 registers used by the vendor two-channel capture sequence.
constexpr uint8_t ES7210_RESET = 0x00;
constexpr uint8_t ES7210_CLOCK_OFF = 0x01;
constexpr uint8_t ES7210_MAIN_CLOCK = 0x02;
constexpr uint8_t ES7210_LRCK_HIGH = 0x04;
constexpr uint8_t ES7210_LRCK_LOW = 0x05;
constexpr uint8_t ES7210_POWER_DOWN = 0x06;
constexpr uint8_t ES7210_OSR = 0x07;
constexpr uint8_t ES7210_TIME0 = 0x09;
constexpr uint8_t ES7210_TIME1 = 0x0A;
constexpr uint8_t ES7210_SDP1 = 0x11;
constexpr uint8_t ES7210_SDP2 = 0x12;
constexpr uint8_t ES7210_ANALOG = 0x40;
constexpr uint8_t ES7210_MIC12_BIAS = 0x41;
constexpr uint8_t ES7210_MIC34_BIAS = 0x42;
constexpr uint8_t ES7210_MIC1_GAIN = 0x43;
constexpr uint8_t ES7210_MIC2_GAIN = 0x44;
constexpr uint8_t ES7210_MIC1_POWER = 0x47;
constexpr uint8_t ES7210_MIC2_POWER = 0x48;
constexpr uint8_t ES7210_MIC3_POWER = 0x49;
constexpr uint8_t ES7210_MIC4_POWER = 0x4A;
constexpr uint8_t ES7210_MIC12_POWER = 0x4B;
constexpr uint8_t ES7210_MIC34_POWER = 0x4C;

}  // namespace

bool CodecSerialAudioBackend::writeRegister(uint8_t address, uint8_t reg,
                                            uint8_t value) {
  Wire.beginTransmission(address);
  Wire.write(reg);
  Wire.write(value);
  return Wire.endTransmission() == 0;
}

namespace {

bool readRegisterOnce(uint8_t address, uint8_t reg, uint8_t &value) {
  Wire.beginTransmission(address);
  Wire.write(reg);
  if (Wire.endTransmission() != 0) return false;
  if (Wire.requestFrom(address, (size_t)1) != 1) return false;
  value = (uint8_t)Wire.read();
  return true;
}

// One retry: Espressif's ES8311 driver repeats a write because the first
// transaction occasionally fails. A miss here only ever fails closed.
bool readRegister(uint8_t address, uint8_t reg, uint8_t &value) {
  return readRegisterOnce(address, reg, value) ||
         readRegisterOnce(address, reg, value);
}

}  // namespace

audiobackend::CodecProbe probeCodecs(const board::Config &boardConfig,
                                     const board::AudioConfig &audioConfig) {
  audiobackend::CodecProbe probe = {};
  const audiobackend::ControlBus bus =
      audiobackend::controlBus(boardConfig, audioConfig);
  if (audioConfig.codecI2cAddress == 0 || audioConfig.micI2cAddress == 0 ||
      bus.sda == board::NO_PIN || bus.scl == board::NO_PIN ||
      !Wire.begin(bus.sda, bus.scl, CONTROL_I2C_HZ)) {
    return probe;
  }
  probe.codecRead =
      readRegister(audioConfig.codecI2cAddress,
                   audiobackend::ES8311_CHIP_ID1_REG, probe.codecId1) &&
      readRegister(audioConfig.codecI2cAddress,
                   audiobackend::ES8311_CHIP_ID2_REG, probe.codecId2);
  probe.micRead =
      readRegister(audioConfig.micI2cAddress,
                   audiobackend::ES7210_CHIP_ID1_REG, probe.micId1) &&
      readRegister(audioConfig.micI2cAddress,
                   audiobackend::ES7210_CHIP_ID0_REG, probe.micId0);
  return probe;
}

void CodecSerialAudioBackend::disableAmp() {
  if (!configured_ || config_.pinAmpEnable == board::NO_PIN) return;
  pinMode(config_.pinAmpEnable, OUTPUT);
  digitalWrite(config_.pinAmpEnable, LOW);
}

bool CodecSerialAudioBackend::setCodecMuted(bool muted) {
  return writeRegister(config_.codecI2cAddress, ES8311_DAC_MUTE,
                       muted ? 0x60 : 0x00);
}

bool CodecSerialAudioBackend::initializeEs8311() {
  // The Arduino I2S layer emits a 256*Fs MCLK. For every rate accepted by
  // supportsCodecClock(), the ES8311 vendor table uses the same 256*Fs
  // divider tuple: pre-div 1, ADC/DAC div 1, BCLK div 4, LRCK div 256.
  bool ok = writeRegister(config_.codecI2cAddress, ES8311_RESET, 0x1F);
  ok = writeRegister(config_.codecI2cAddress, ES8311_RESET, 0x00) && ok;
  ok = writeRegister(config_.codecI2cAddress, ES8311_RESET, 0x80) && ok;
  ok = writeRegister(config_.codecI2cAddress, ES8311_CLOCK1, 0x3F) && ok;
  ok = writeRegister(config_.codecI2cAddress, ES8311_CLOCK2, 0x00) && ok;
  ok = writeRegister(config_.codecI2cAddress, ES8311_CLOCK3, 0x10) && ok;
  ok = writeRegister(config_.codecI2cAddress, ES8311_CLOCK4, 0x10) && ok;
  ok = writeRegister(config_.codecI2cAddress, ES8311_CLOCK5, 0x00) && ok;
  ok = writeRegister(config_.codecI2cAddress, ES8311_CLOCK6, 0x03) && ok;
  ok = writeRegister(config_.codecI2cAddress, ES8311_CLOCK7, 0x00) && ok;
  ok = writeRegister(config_.codecI2cAddress, ES8311_CLOCK8, 0xFF) && ok;
  ok = writeRegister(config_.codecI2cAddress, ES8311_SDP_IN, 0x0C) && ok;
  ok = writeRegister(config_.codecI2cAddress, ES8311_SDP_OUT, 0x0C) && ok;
  ok = writeRegister(config_.codecI2cAddress, ES8311_SYSTEM0D, 0x01) && ok;
  ok = writeRegister(config_.codecI2cAddress, ES8311_SYSTEM0E, 0x02) && ok;
  ok = writeRegister(config_.codecI2cAddress, ES8311_SYSTEM12, 0x00) && ok;
  ok = writeRegister(config_.codecI2cAddress, ES8311_SYSTEM13, 0x10) && ok;
  ok = writeRegister(config_.codecI2cAddress, ES8311_ADC1C, 0x6A) && ok;
  ok = writeRegister(config_.codecI2cAddress, ES8311_DAC_RAMP, 0x08) && ok;
  return setCodecMuted(true) && ok;
}

bool CodecSerialAudioBackend::initializeEs7210() {
  audiobackend::Es7210Clock clock = {};
  if (!audiobackend::es7210Clock(format_.sampleRateHz, clock)) return false;

  bool ok = writeRegister(config_.micI2cAddress, ES7210_RESET, 0xFF);
  ok = writeRegister(config_.micI2cAddress, ES7210_RESET, 0x41) && ok;
  ok = writeRegister(config_.micI2cAddress, ES7210_CLOCK_OFF, 0x1F) && ok;
  ok = writeRegister(config_.micI2cAddress, ES7210_TIME0, 0x30) && ok;
  ok = writeRegister(config_.micI2cAddress, ES7210_TIME1, 0x30) && ok;
  ok = writeRegister(config_.micI2cAddress, ES7210_ANALOG, 0xC3) && ok;
  ok = writeRegister(config_.micI2cAddress, ES7210_MIC12_BIAS, 0x70) && ok;
  ok = writeRegister(config_.micI2cAddress, ES7210_MIC34_BIAS, 0x70) && ok;
  ok = writeRegister(config_.micI2cAddress, ES7210_MAIN_CLOCK, 0xC1) && ok;
  ok = writeRegister(config_.micI2cAddress, ES7210_MAIN_CLOCK,
                     clock.mainClock) && ok;
  ok = writeRegister(config_.micI2cAddress, ES7210_OSR, clock.osr) && ok;
  ok = writeRegister(config_.micI2cAddress, ES7210_LRCK_HIGH,
                     clock.lrckHigh) && ok;
  ok = writeRegister(config_.micI2cAddress, ES7210_LRCK_LOW,
                     clock.lrckLow) && ok;
  ok = writeRegister(config_.micI2cAddress, ES7210_SDP1, 0x60) && ok;
  ok = writeRegister(config_.micI2cAddress, ES7210_SDP2, 0x00) && ok;

  // Power only the descriptor's selected slot count. The current 1.75C row
  // selects two slots, but one-channel descriptors remain a parameter change.
  ok = writeRegister(config_.micI2cAddress, ES7210_MIC12_POWER, 0x00) && ok;
  ok = writeRegister(config_.micI2cAddress, ES7210_MIC34_POWER, 0xFF) && ok;
  ok = writeRegister(config_.micI2cAddress, ES7210_MIC1_GAIN, 0x10) && ok;
  if (config_.captureChannels > 1) {
    ok = writeRegister(config_.micI2cAddress, ES7210_MIC2_GAIN, 0x10) && ok;
  }
  ok = writeRegister(config_.micI2cAddress, ES7210_CLOCK_OFF, 0x14) && ok;
  ok = writeRegister(config_.micI2cAddress, ES7210_POWER_DOWN, 0x00) && ok;
  ok = writeRegister(config_.micI2cAddress, ES7210_MIC1_POWER, 0x00) && ok;
  ok = writeRegister(config_.micI2cAddress, ES7210_MIC2_POWER,
                     config_.captureChannels > 1 ? 0x00 : 0xFF) && ok;
  ok = writeRegister(config_.micI2cAddress, ES7210_MIC3_POWER, 0xFF) && ok;
  ok = writeRegister(config_.micI2cAddress, ES7210_MIC4_POWER, 0xFF) && ok;
  return ok;
}

bool CodecSerialAudioBackend::start(
    const board::Config &boardConfig, const board::AudioConfig &audioConfig,
    const audiobackend::Format &format) {
  return startWith(boardConfig, audioConfig, format, true);
}

bool CodecSerialAudioBackend::startPlaybackOnly(
    const board::Config &boardConfig, const board::AudioConfig &audioConfig,
    const audiobackend::Format &format) {
  return startWith(boardConfig, audioConfig, format, false);
}

void CodecSerialAudioBackend::powerDownEs7210() {
  writeRegister(config_.micI2cAddress, ES7210_MIC1_POWER, 0xFF);
  writeRegister(config_.micI2cAddress, ES7210_MIC2_POWER, 0xFF);
  writeRegister(config_.micI2cAddress, ES7210_MIC3_POWER, 0xFF);
  writeRegister(config_.micI2cAddress, ES7210_MIC4_POWER, 0xFF);
  writeRegister(config_.micI2cAddress, ES7210_MIC12_POWER, 0xFF);
  writeRegister(config_.micI2cAddress, ES7210_MIC34_POWER, 0xFF);
  writeRegister(config_.micI2cAddress, ES7210_CLOCK_OFF, 0x7F);
  writeRegister(config_.micI2cAddress, ES7210_POWER_DOWN, 0x07);
}

bool CodecSerialAudioBackend::startWith(
    const board::Config &boardConfig, const board::AudioConfig &audioConfig,
    const audiobackend::Format &format, bool capture) {
  if (!audiobackend::matchesBoard(boardConfig, audioConfig) ||
      audiobackend::classify(audioConfig) !=
          audiobackend::DescriptorStatus::Ready ||
      format.bitsPerSample != 16 ||
      format.sampleRateHz != audioConfig.playbackRateHz ||
      format.channels != audioConfig.playbackChannels ||
      !audiobackend::supportsCodecClock(format.sampleRateHz)) {
    return false;
  }
  // Positive identification comes before the first audio GPIO or clock: on
  // wrong hardware the amplifier-enable net may be something else entirely.
  // The per-boot verdict is used rather than a fresh probe, because start()
  // also runs on the engine task and an I2C read there would race the loop
  // task's touch and IMU reads on the shared, unlocked Wire receive buffer.
  if (boardAudioStatus(boardConfig) != audiobackend::DescriptorStatus::Ready) {
    return false;
  }

  stop();
  config_ = audioConfig;
  format_ = format;
  configured_ = true;
  capture_ = capture;
  disableAmp();

  audioI2s().setPins(config_.pinPlaybackBclk, config_.pinPlaybackLrck,
                   config_.pinDout, capture_ ? config_.pinDin : board::NO_PIN,
                   config_.pinPlaybackMclk);
  const i2s_slot_mode_t slots =
      format_.channels == 1 ? I2S_SLOT_MODE_MONO : I2S_SLOT_MODE_STEREO;
  if (!audioI2s().begin(I2S_MODE_STD, format_.sampleRateHz,
                        I2S_DATA_BIT_WIDTH_16BIT, slots)) {
    stop();
    return false;
  }

  // Written in PRIME_FRAMES pieces, so the stack holds the streaming
  // prime's buffer whichever path runs.
  int16_t silence[PRIME_FRAMES * 2] = {};
  const size_t silenceBytes =
      PRIME_FRAMES * format_.channels * sizeof(int16_t);
  const size_t primeFrames =
      capture_ ? PRIME_FRAMES : PLAYBACK_ONLY_PRIME_FRAMES;
  static_assert(PLAYBACK_ONLY_PRIME_FRAMES % PRIME_FRAMES == 0,
                "the playback-only prime is whole streaming primes");
  for (size_t primed = 0; primed < primeFrames; primed += PRIME_FRAMES) {
    if (audioI2s().write(silence, silenceBytes) != silenceBytes) {
      stop();
      return false;
    }
  }
  if (!capture_) powerDownEs7210();
  if (!initializeEs8311() || (capture_ && !initializeEs7210()) ||
      !setGain(audiobackend::dacVolumePercent(config_))) {
    stop();
    return false;
  }

  delay(CODEC_SETTLE_MS);
  if (!setCodecMuted(false)) {
    stop();
    return false;
  }
  delay(CODEC_SETTLE_MS);
  digitalWrite(config_.pinAmpEnable, HIGH);
  running_ = true;
  return true;
}

size_t CodecSerialAudioBackend::writeFrames(const int16_t *samples,
                                            size_t frameCount) {
  if (!running_ || samples == nullptr) return 0;
  const size_t bytes =
      frameCount * format_.channels * sizeof(int16_t);
  return audioI2s().write(samples, bytes) / (format_.channels * sizeof(int16_t));
}

bool CodecSerialAudioBackend::readCodecRegister(uint8_t reg,
                                                uint8_t &value) {
  return running_ && readRegister(config_.codecI2cAddress, reg, value);
}

int CodecSerialAudioBackend::ampEnableLevel() const {
  // pinMode(OUTPUT) keeps the pad's input enabled, so this reads the level
  // actually on the amplifier's enable net.
  return running_ ? digitalRead(config_.pinAmpEnable) : -1;
}

void CodecSerialAudioBackend::setAmpEnabled(bool enabled) {
  if (running_) digitalWrite(config_.pinAmpEnable, enabled ? HIGH : LOW);
}

size_t CodecSerialAudioBackend::readFrames(int16_t *samples,
                                           size_t frameCount) {
  if (!running_ || !capture_ || samples == nullptr) return 0;
  const size_t bytes =
      frameCount * config_.captureChannels * sizeof(int16_t);
  return audioI2s().readBytes(reinterpret_cast<char *>(samples), bytes) /
         (config_.captureChannels * sizeof(int16_t));
}

bool CodecSerialAudioBackend::setGain(uint8_t percent) {
  return writeRegister(config_.codecI2cAddress, ES8311_DAC_VOLUME,
                       audiobackend::es8311DacVolumeRegister(percent));
}

void CodecSerialAudioBackend::stop() {
  if (!configured_ && !running_) return;
  disableAmp();
  if (config_.codecI2cAddress != 0) {
    setCodecMuted(true);
  }
  if (config_.micI2cAddress != 0) powerDownEs7210();
  releaseI2s();
  config_ = {};
  format_ = {};
  configured_ = false;
  running_ = false;
  capture_ = false;
}

#else

bool CodecSerialAudioBackend::writeRegister(uint8_t, uint8_t, uint8_t) {
  return false;
}

audiobackend::CodecProbe probeCodecs(const board::Config &,
                                     const board::AudioConfig &) {
  return {};
}

void CodecSerialAudioBackend::disableAmp() {}

bool CodecSerialAudioBackend::setCodecMuted(bool) { return false; }

bool CodecSerialAudioBackend::initializeEs8311() { return false; }

bool CodecSerialAudioBackend::initializeEs7210() { return false; }

void CodecSerialAudioBackend::powerDownEs7210() {}

bool CodecSerialAudioBackend::startWith(const board::Config &,
                                        const board::AudioConfig &,
                                        const audiobackend::Format &, bool) {
  return false;
}

bool CodecSerialAudioBackend::startPlaybackOnly(
    const board::Config &, const board::AudioConfig &,
    const audiobackend::Format &) {
  return false;
}

bool CodecSerialAudioBackend::start(
    const board::Config &, const board::AudioConfig &,
    const audiobackend::Format &) {
  return false;
}

size_t CodecSerialAudioBackend::writeFrames(const int16_t *, size_t) {
  return 0;
}

size_t CodecSerialAudioBackend::readFrames(int16_t *, size_t) { return 0; }

bool CodecSerialAudioBackend::readCodecRegister(uint8_t, uint8_t &) {
  return false;
}

int CodecSerialAudioBackend::ampEnableLevel() const { return -1; }

void CodecSerialAudioBackend::setAmpEnabled(bool) {}

bool CodecSerialAudioBackend::setGain(uint8_t) { return false; }

void CodecSerialAudioBackend::stop() {
  configured_ = false;
  running_ = false;
}

#endif
}  // namespace audio
