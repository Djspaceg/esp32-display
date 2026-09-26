// Runtime profile detection performed before any panel GPIO is configured.
//
// C6 probes its shared discriminator bus. S3 uses the 8 MiB flash identity for
// the GC9107 carrier and profile-specific I2C buses on larger-flash hardware,
// plus input-only analog sense pins where two carriers share one I2C bus.
// S3 accepts exactly one candidate; zero or multiple candidates remain Unknown
// so the firmware can stay serial-only until an operator uses CFGBOARD.
#pragma once

#include <Arduino.h>
#include <Wire.h>
#if defined(CONFIG_IDF_TARGET_ESP32S3)
#include <driver/gpio.h>
#include <driver/rtc_io.h>
#include <esp_adc/adc_cali.h>
#include <esp_adc/adc_cali_scheme.h>
#include <esp_adc/adc_oneshot.h>
#endif

#include <board_config.h>

namespace boarddetect {

inline const char *knownC6DeviceHint(uint8_t address) {
  if (address == 0x63 || address == 0x51) return " (AXS5106L touch)";
  if (address == 0x6B || address == 0x6A) return " (QMI8658A IMU)";
  return "";
}

inline const char *probeProfile(
    const boarddetectmodel::FamilyDetectionPlan &family, uint8_t probeIndex) {
  for (uint8_t i = 0; i < family.candidateCount; ++i) {
    if (family.candidates[i].probeIndex == probeIndex) {
      return board::variantToken(
          (board::Variant)family.candidates[i].variantValue);
    }
  }
  return "unknown";
}

inline boarddetectmodel::ProbeEvidence collectI2cEvidence(
    const boarddetectmodel::I2cProbePlan &plan, const char *target,
    const char *profile, bool verbose) {
  using boarddetectmodel::ProbeEvidence;
  using boarddetectmodel::ProbeRelease;
  using boarddetectmodel::ProbeStatus;

  if (plan.resetPin != board::NO_PIN) {
    pinMode(plan.resetPin, OUTPUT);
    digitalWrite(plan.resetPin, LOW);
    delay(plan.resetLowMs);
    digitalWrite(plan.resetPin, HIGH);
    delay(plan.resetReleaseWaitMs);
  }

  const bool busOk = Wire.begin(plan.sda, plan.scl, plan.frequencyHz);
  uint8_t found = 0;
  bool canaryAcked = false;
  if (!busOk) {
    if (verbose) {
      Serial.printf("board: WARN %s %s probe bus would not start\n",
                    target, profile);
    }
  } else if (plan.addressCount > 0) {
    Wire.beginTransmission(boarddetectmodel::CANARY_ADDRESS);
    canaryAcked = Wire.endTransmission() == 0;
    if (canaryAcked && verbose) {
      Serial.printf("board: WARN %s %s bus SDA=%d SCL=%d acknowledged reserved "
                    "0x%02X; ignoring it as stuck or back-powered\n",
                    target, profile, plan.sda, plan.scl,
                    boarddetectmodel::CANARY_ADDRESS);
    }
    for (uint8_t i = 0; i < plan.addressCount && !canaryAcked; ++i) {
      const uint8_t address = plan.addresses[i];
      Wire.beginTransmission(address);
      if (Wire.endTransmission() != 0) continue;
      ++found;
      if (verbose) {
        Serial.printf(
            "board: %s %s signal at 0x%02X on SDA=%d SCL=%d\n",
            target, profile, address, plan.sda, plan.scl);
      }
    }
  } else {
    for (uint8_t address = plan.scanFirst; address <= plan.scanLast;
         ++address) {
      Wire.beginTransmission(address);
      if (Wire.endTransmission() != 0) continue;
      ++found;
      if (verbose) {
        Serial.printf("board: I2C device at 0x%02X%s\n", address,
                      knownC6DeviceHint(address));
      }
    }
  }

  const bool release =
      plan.release == ProbeRelease::Always ||
      (plan.release == ProbeRelease::OnSuccessNoAck && busOk && found == 0);
  if (release) {
    if (busOk) Wire.end();
    pinMode(plan.sda, INPUT);
    pinMode(plan.scl, INPUT);
    if (plan.resetPin != board::NO_PIN) pinMode(plan.resetPin, INPUT);
  }
  if (plan.addressCount > 0) {
    return boarddetectmodel::addressProbeEvidence(busOk, found, canaryAcked);
  }
  return {
      busOk ? ProbeStatus::Started : ProbeStatus::StartFailed,
      found,
  };
}

/// Read one detection sense pin: calibrated millivolts with the internal
/// pull-down enabled, so a bare header pin reads near zero instead of
/// floating, then hand the pin back as a plain input. Input-only; nothing is
/// driven.
///
/// The ADC is driven through the IDF oneshot API on a unit this function owns
/// and deletes, rather than analogReadMilliVolts, because the Arduino wrapper
/// reports every failure as 0 mV, and 0 mV is a valid low reading: a failed
/// read on the 1.9 would select the 1.3 and hand it the 1.9's USB pins. Every
/// step is checked and any failure leaves the evidence unread, which no guarded
/// candidate accepts; missing calibration eFuses fall back to the nominal
/// raw-count scale instead. Channel configuration clears the pad's pulls, so
/// the pull-down is enabled after it, on both the RTC and digital pad paths.
/// The median of five samples rides out single-sample ADC noise.
inline boarddetectmodel::SenseEvidence collectSense(int8_t pin,
                                                    bool verbose) {
  boarddetectmodel::SenseEvidence evidence;
#if defined(CONFIG_IDF_TARGET_ESP32S3)
  adc_unit_t unit = ADC_UNIT_1;
  adc_channel_t channel = ADC_CHANNEL_0;
  if (pin < 0 || adc_oneshot_io_to_channel(pin, &unit, &channel) != ESP_OK) {
    if (verbose) Serial.printf("board: sense GPIO%d is not an ADC pin\n", pin);
    return evidence;
  }
  adc_oneshot_unit_handle_t adc = nullptr;
  adc_oneshot_unit_init_cfg_t unitConfig = {};
  unitConfig.unit_id = unit;
  unitConfig.ulp_mode = ADC_ULP_MODE_DISABLE;
  if (adc_oneshot_new_unit(&unitConfig, &adc) != ESP_OK) {
    if (verbose) Serial.printf("board: sense GPIO%d ADC unit unavailable\n", pin);
    return evidence;
  }
  adc_oneshot_chan_cfg_t channelConfig = {};
  channelConfig.atten = ADC_ATTEN_DB_12;
  channelConfig.bitwidth = ADC_BITWIDTH_DEFAULT;
  adc_cali_handle_t calibration = nullptr;
  adc_cali_curve_fitting_config_t calibrationConfig = {};
  calibrationConfig.unit_id = unit;
  calibrationConfig.chan = channel;
  calibrationConfig.atten = channelConfig.atten;
  calibrationConfig.bitwidth = channelConfig.bitwidth;
  bool ok = adc_oneshot_config_channel(adc, channel, &channelConfig) == ESP_OK;
  // Calibration is optional: a chip without the calibration eFuses still gets
  // a reading on the nominal raw-count scale rather than no reading at all,
  // which would leave the 1.3 unable to auto-detect.
  const bool calibrated =
      ok && adc_cali_create_scheme_curve_fitting(&calibrationConfig,
                                                 &calibration) == ESP_OK;
  const gpio_num_t gpio = (gpio_num_t)pin;
  int raw[5] = {};
  int millivolts[5] = {};
  if (ok) {
    if (rtc_gpio_is_valid_gpio(gpio)) rtc_gpio_pulldown_en(gpio);
    gpio_pulldown_en(gpio);
    delay(5);
    for (uint8_t i = 0; ok && i < 5; ++i) {
      ok = adc_oneshot_read(adc, channel, &raw[i]) == ESP_OK &&
           (!calibrated ||
            adc_cali_raw_to_voltage(calibration, raw[i], &millivolts[i]) ==
                ESP_OK);
    }
    if (rtc_gpio_is_valid_gpio(gpio)) rtc_gpio_pulldown_dis(gpio);
    gpio_pulldown_dis(gpio);
  }
  if (calibration != nullptr) {
    adc_cali_delete_scheme_curve_fitting(calibration);
  }
  adc_oneshot_del_unit(adc);
  pinMode(pin, INPUT);
  if (!ok) {
    if (verbose) Serial.printf("board: sense GPIO%d read failed\n", pin);
    return evidence;
  }
  evidence = boarddetectmodel::senseEvidenceFromSamples(
      raw, calibrated ? millivolts : nullptr, 5);
  if (verbose && evidence.read) {
    Serial.printf("board: sense GPIO%d = %u mV (pull-down, %s)\n", pin,
                  (unsigned)evidence.millivolts,
                  calibrated ? "calibrated" : "nominal, no ADC calibration");
  }
#else
  (void)pin;
  (void)verbose;
#endif
  return evidence;
}

/// Whether any candidate guarded by sense index `sense` is still possible
/// after the I2C probes: its probe acked, or it has no probe. The sense pin is
/// only touched when its reading could decide something, so boards whose GPIO4
/// carries a panel or touch line never see the pull-down.
inline bool senseNeeded(const boarddetectmodel::FamilyDetectionPlan &plan,
                        uint8_t sense,
                        const boarddetectmodel::ProbeEvidence *evidence) {
  for (uint8_t i = 0; i < plan.candidateCount; ++i) {
    const auto &candidate = plan.candidates[i];
    if (candidate.senseIndex != sense) continue;
    if (candidate.probeIndex >= plan.probeCount) return true;
    if (evidence[candidate.probeIndex].ackCount > 0) return true;
  }
  return false;
}

inline board::Variant probeC6(bool verbose = true,
                              int *outFoundCount = nullptr) {
  const auto &plan =
      board::detectionPlanForPlatform(board::Platform::Esp32C6);
  boarddetectmodel::ProbeEvidence evidence = collectI2cEvidence(
      plan.probes[0], "C6", probeProfile(plan, 0), verbose);
  const board::DetectionResult result = board::detectFromEvidence(
      board::Platform::Esp32C6, 0, &evidence, 1);
  if (outFoundCount != nullptr) *outFoundCount = evidence.ackCount;
  if (verbose) {
    Serial.printf("board: C6 probe found %u device(s) -> %s\n",
                  (unsigned)evidence.ackCount,
                  board::configFor(result.variant).name);
  }
  return result.variant;
}

inline board::Variant probeC3(bool verbose = true,
                              int *outFoundCount = nullptr) {
  const board::DetectionResult result = board::detectFromEvidence(
      board::Platform::Esp32C3, ESP.getFlashChipSize(), nullptr, 0);
  if (outFoundCount != nullptr) {
    *outFoundCount = result.matchedCandidates;
  }
  if (verbose) {
    Serial.printf("board: C3 detection -> %s\n",
                  board::configFor(result.variant).name);
  }
  return result.variant;
}

inline board::Variant probeS3(bool verbose = true,
                              int *outCandidateCount = nullptr) {
  const uint32_t flashBytes = ESP.getFlashChipSize();
  const auto &plan =
      board::detectionPlanForPlatform(board::Platform::Esp32S3);
  boarddetectmodel::ProbeEvidence
      evidence[board::GENERATED_MAX_PROBE_COUNT] = {};
  for (uint8_t i = 0; i < plan.probeCount; ++i) {
    const auto &probe = plan.probes[i];
    if (!boarddetectmodel::flashMatches(
            flashBytes, probe.flashMinExclusive,
            probe.flashMaxInclusive)) {
      continue;
    }
    if (!boarddetectmodel::shouldRunProbe(plan, i, evidence)) {
      if (verbose) {
        Serial.printf("board: S3 %s probe skipped; an earlier bus answered\n",
                      probeProfile(plan, i));
      }
      continue;
    }
    evidence[i] = collectI2cEvidence(
        probe, "S3", probeProfile(plan, i), verbose);
  }
  boarddetectmodel::SenseEvidence
      senses[board::GENERATED_MAX_SENSE_COUNT > 0
                 ? board::GENERATED_MAX_SENSE_COUNT
                 : 1] = {};
  for (uint8_t i = 0; i < plan.senseCount; ++i) {
    if (senseNeeded(plan, i, evidence)) {
      senses[i] = collectSense(plan.sensePins[i], verbose);
    }
  }
  const board::DetectionResult result = board::detectFromEvidence(
      board::Platform::Esp32S3, flashBytes, evidence, plan.probeCount,
      senses, plan.senseCount);
  if (outCandidateCount != nullptr) {
    *outCandidateCount = result.matchedCandidates;
  }
  if (verbose) {
    if (result.variant == board::Variant::Unknown) {
      Serial.printf("board: S3 detection found %d compatible profiles; "
                    "serial-only until CFGBOARD resolves one\n",
                    result.matchedCandidates);
    } else {
      Serial.printf("board: S3 detection -> %s\n",
                    board::configFor(result.variant).name);
    }
  }
  return result.variant;
}

inline board::Variant probe(bool verbose = true,
                            int *outFoundCount = nullptr) {
#if defined(CONFIG_IDF_TARGET_ESP32P4)
  const board::DetectionResult result = board::detectFromEvidence(
      board::Platform::Esp32P4, ESP.getFlashChipSize(), nullptr, 0);
  if (outFoundCount != nullptr) {
    *outFoundCount = result.matchedCandidates;
  }
  return result.variant;
#elif defined(CONFIG_IDF_TARGET_ESP32S3)
  return probeS3(verbose, outFoundCount);
#elif defined(CONFIG_IDF_TARGET_ESP32C3)
  return probeC3(verbose, outFoundCount);
#else
  return probeC6(verbose, outFoundCount);
#endif
}

}  // namespace boarddetect
