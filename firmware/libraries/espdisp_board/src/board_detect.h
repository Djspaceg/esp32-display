// Runtime profile detection performed before any panel GPIO is configured.
//
// C6 probes its shared discriminator bus. S3 uses the 8 MiB flash identity for
// the GC9107 carrier and profile-specific I2C buses on larger-flash hardware.
// S3 accepts exactly one candidate; zero or multiple candidates remain Unknown
// so the firmware can stay serial-only until an operator uses CFGBOARD.
#pragma once

#include <Arduino.h>
#include <Wire.h>

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
  const board::DetectionResult result = board::detectFromEvidence(
      board::Platform::Esp32S3, flashBytes, evidence, plan.probeCount);
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
