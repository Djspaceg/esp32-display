#include "audio_backend.h"

#include <Arduino.h>
#if defined(CONFIG_IDF_TARGET_ESP32S3)
#include <ESP_I2S.h>
#include <Wire.h>
#endif

namespace audio {
#if defined(CONFIG_IDF_TARGET_ESP32S3)
namespace {

I2SClass audioI2s;

constexpr uint32_t CONTROL_I2C_HZ = 400000;
constexpr uint8_t STARTUP_GAIN_PERCENT = 35;
constexpr uint32_t CODEC_SETTLE_MS = 10;
constexpr size_t PRIME_FRAMES = 80;

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
  stop();
  config_ = audioConfig;
  format_ = format;
  configured_ = true;
  disableAmp();

  if (audiobackend::classify(config_) !=
          audiobackend::DescriptorStatus::Ready ||
      format_.bitsPerSample != 16 ||
      format_.sampleRateHz != config_.playbackRateHz ||
      format_.channels != config_.playbackChannels ||
      !audiobackend::supportsCodecClock(format_.sampleRateHz) ||
      boardConfig.pinTouchSda == board::NO_PIN ||
      boardConfig.pinTouchScl == board::NO_PIN) {
    return false;
  }

  audioI2s.setPins(config_.pinPlaybackBclk, config_.pinPlaybackLrck,
                   config_.pinDout, config_.pinDin,
                   config_.pinPlaybackMclk);
  const i2s_slot_mode_t slots =
      format_.channels == 1 ? I2S_SLOT_MODE_MONO : I2S_SLOT_MODE_STEREO;
  if (!audioI2s.begin(I2S_MODE_STD, format_.sampleRateHz,
                      I2S_DATA_BIT_WIDTH_16BIT, slots)) {
    return false;
  }

  int16_t silence[PRIME_FRAMES * 2] = {};
  const size_t silenceBytes =
      PRIME_FRAMES * format_.channels * sizeof(int16_t);
  if (audioI2s.write(silence, silenceBytes) != silenceBytes) {
    audioI2s.end();
    return false;
  }
  if (!Wire.begin(boardConfig.pinTouchSda, boardConfig.pinTouchScl,
                  CONTROL_I2C_HZ) ||
      !initializeEs8311() || !initializeEs7210() ||
      !setGain(STARTUP_GAIN_PERCENT)) {
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
  return audioI2s.write(samples, bytes) / (format_.channels * sizeof(int16_t));
}

size_t CodecSerialAudioBackend::readFrames(int16_t *samples,
                                           size_t frameCount) {
  if (!running_ || samples == nullptr) return 0;
  const size_t bytes =
      frameCount * config_.captureChannels * sizeof(int16_t);
  return audioI2s.readBytes(reinterpret_cast<char *>(samples), bytes) /
         (config_.captureChannels * sizeof(int16_t));
}

bool CodecSerialAudioBackend::setGain(uint8_t percent) {
  if (percent > 100) percent = 100;
  const uint8_t reg =
      percent == 0 ? 0 : (uint8_t)(((uint16_t)percent * 256U) / 100U - 1U);
  return writeRegister(config_.codecI2cAddress, ES8311_DAC_VOLUME, reg);
}

void CodecSerialAudioBackend::stop() {
  disableAmp();
  if (config_.codecI2cAddress != 0) {
    setCodecMuted(true);
  }
  if (config_.micI2cAddress != 0) {
    writeRegister(config_.micI2cAddress, ES7210_MIC1_POWER, 0xFF);
    writeRegister(config_.micI2cAddress, ES7210_MIC2_POWER, 0xFF);
    writeRegister(config_.micI2cAddress, ES7210_MIC3_POWER, 0xFF);
    writeRegister(config_.micI2cAddress, ES7210_MIC4_POWER, 0xFF);
    writeRegister(config_.micI2cAddress, ES7210_MIC12_POWER, 0xFF);
    writeRegister(config_.micI2cAddress, ES7210_MIC34_POWER, 0xFF);
    writeRegister(config_.micI2cAddress, ES7210_CLOCK_OFF, 0x7F);
    writeRegister(config_.micI2cAddress, ES7210_POWER_DOWN, 0x07);
  }
  audioI2s.end();
  running_ = false;
}

#else

bool CodecSerialAudioBackend::writeRegister(uint8_t, uint8_t, uint8_t) {
  return false;
}

void CodecSerialAudioBackend::disableAmp() {}

bool CodecSerialAudioBackend::setCodecMuted(bool) { return false; }

bool CodecSerialAudioBackend::initializeEs8311() { return false; }

bool CodecSerialAudioBackend::initializeEs7210() { return false; }

bool CodecSerialAudioBackend::start(
    const board::Config &, const board::AudioConfig &,
    const audiobackend::Format &) {
  return false;
}

size_t CodecSerialAudioBackend::writeFrames(const int16_t *, size_t) {
  return 0;
}

size_t CodecSerialAudioBackend::readFrames(int16_t *, size_t) { return 0; }

bool CodecSerialAudioBackend::setGain(uint8_t) { return false; }

void CodecSerialAudioBackend::stop() {
  configured_ = false;
  running_ = false;
}

#endif
}  // namespace audio
