// Hardware-free declarative board detection evaluator.
//
// A candidate may also carry an analog sense guard: the millivolts read on one
// GPIO, with the internal pull-down enabled, must fall inside the candidate's
// window. It separates carriers whose I2C buses answer identically (the S3
// 1.3-inch and 1.9-inch carriers both expose only a QMI8658 at 0x6B on
// GPIO47/48). A guarded candidate never matches without a reading.
#pragma once

#include <stddef.h>
#include <stdint.h>

namespace boarddetectmodel {

enum class ProbeStatus : uint8_t {
  NotRun,
  Started,
  StartFailed,
};

enum class ProbeRelease : uint8_t {
  Never,
  Always,
  OnSuccessNoAck,
};

enum class CandidateMatch : uint8_t {
  Always,
  FlashRange,
  I2cAnyAck,
  I2cNoAck,
  I2cAnyAckOrStartFailure,
};

enum class ResolutionPolicy : uint8_t {
  FirstMatch,
  ExactlyOne,
};

struct ProbeEvidence {
  ProbeStatus status = ProbeStatus::NotRun;
  uint8_t ackCount = 0;
};

struct I2cProbePlan {
  uint32_t flashMinExclusive;
  uint32_t flashMaxInclusive;
  int8_t sda;
  int8_t scl;
  uint32_t frequencyHz;
  uint8_t scanFirst;
  uint8_t scanLast;
  uint8_t addresses[4];
  uint8_t addressCount;
  int8_t resetPin;
  uint16_t resetLowMs;
  uint16_t resetReleaseWaitMs;
  ProbeRelease release;
};

/// No analog sense guard on this candidate.
static constexpr uint8_t NO_SENSE = 255;

struct CandidateRule {
  uint8_t variantValue;
  CandidateMatch match;
  uint8_t probeIndex;
  uint32_t flashMinExclusive;
  uint32_t flashMaxInclusive;
  /// Index into FamilyDetectionPlan::sensePins, or NO_SENSE.
  uint8_t senseIndex = NO_SENSE;
  /// Inclusive millivolt window; 0 for max means unbounded.
  uint16_t senseMinMv = 0;
  uint16_t senseMaxMv = 0;
};

/// One analog sense reading, indexed like FamilyDetectionPlan::sensePins.
struct SenseEvidence {
  bool read = false;
  uint16_t millivolts = 0;
};

struct FamilyDetectionPlan {
  const I2cProbePlan *probes;
  uint8_t probeCount;
  const CandidateRule *candidates;
  uint8_t candidateCount;
  ResolutionPolicy resolution;
  const int8_t *sensePins = nullptr;
  uint8_t senseCount = 0;
};

/// Nominal millivolts for a raw 12-bit sample at 12 dB attenuation (about
/// 0-3100 mV full scale). Used only when the chip carries no ADC calibration
/// eFuses; the uncalibrated error of roughly 10 percent sits well inside the
/// sense windows, so such a chip still detects instead of falling to CFGBOARD.
constexpr int nominalSenseMillivolts(int raw) {
  return raw <= 0 ? 0 : (raw >= 4095 ? 3100 : (raw * 3100) / 4095);
}

/// Turn one sense pin's ADC samples into evidence: the median millivolts of
/// `count` samples. `calibratedMillivolts` holds the calibration scheme's
/// conversion of each raw sample, or is nullptr when the chip has no ADC
/// calibration, in which case the nominal raw-count scale is used. Any negative
/// sample means a failed read, and no samples means no evidence; both leave the
/// evidence unread.
inline SenseEvidence senseEvidenceFromSamples(const int *raw,
                                              const int *calibratedMillivolts,
                                              size_t count) {
  SenseEvidence evidence;
  if (raw == nullptr || count == 0 || count > 16) return evidence;
  uint16_t millivolts[16] = {};
  for (size_t i = 0; i < count; ++i) {
    if (raw[i] < 0) return evidence;
    const int value = calibratedMillivolts != nullptr
                          ? calibratedMillivolts[i]
                          : nominalSenseMillivolts(raw[i]);
    if (value < 0) return evidence;
    millivolts[i] = (uint16_t)(value > 0xFFFF ? 0xFFFF : value);
  }
  for (size_t i = 1; i < count; ++i) {
    for (size_t j = i; j > 0 && millivolts[j - 1] > millivolts[j]; --j) {
      const uint16_t swap = millivolts[j];
      millivolts[j] = millivolts[j - 1];
      millivolts[j - 1] = swap;
    }
  }
  evidence.read = true;
  evidence.millivolts = millivolts[count / 2];
  return evidence;
}

inline bool senseMatches(const CandidateRule &candidate,
                         const SenseEvidence *senses, size_t senseCount) {
  if (candidate.senseIndex == NO_SENSE) return true;
  if (senses == nullptr || candidate.senseIndex >= senseCount) return false;
  const SenseEvidence &sense = senses[candidate.senseIndex];
  if (!sense.read) return false;
  if (sense.millivolts < candidate.senseMinMv) return false;
  return candidate.senseMaxMv == 0 || sense.millivolts <= candidate.senseMaxMv;
}

struct Evaluation {
  uint8_t variantValue;
  uint8_t matchedCandidates;
};

constexpr bool flashMatches(uint32_t flashBytes, uint32_t minExclusive,
                            uint32_t maxInclusive) {
  if (minExclusive != 0 && flashBytes <= minExclusive) return false;
  if (maxInclusive != 0 && flashBytes > maxInclusive) return false;
  return flashBytes != 0 || (minExclusive == 0 && maxInclusive == 0);
}

/// A reserved 7-bit address no device may hold. An address-list probe also
/// addresses it: if it "answers", SDA is being held low - a stuck bus, or an
/// unpowered chip clamping the line, as the CrowPanel knob's GC9A01 does to
/// GPIO11 while its supply rail is off - and every acknowledgement on that bus
/// is meaningless.
static const uint8_t CANARY_ADDRESS = 0x7F;

/// Evidence from one address-list probe, discarding acknowledgements from a
/// bus that also acknowledged CANARY_ADDRESS.
inline ProbeEvidence addressProbeEvidence(bool busStarted, uint8_t ackCount,
                                          bool canaryAcked) {
  if (!busStarted) return {ProbeStatus::StartFailed, 0};
  return {ProbeStatus::Started, canaryAcked ? (uint8_t)0 : ackCount};
}

/// Whether probe `index` should run given the evidence gathered so far. A probe
/// with a reset line drives that GPIO push-pull (on the CrowPanel knob it is the
/// panel supply rail), which is only justified while no earlier probe has
/// identified its board: once one has, this probe could only add a second
/// candidate, and on that board the line is some other net.
inline bool shouldRunProbe(const FamilyDetectionPlan &plan, uint8_t index,
                           const ProbeEvidence *evidence) {
  if (index >= plan.probeCount) return false;
  if (plan.probes[index].resetPin < 0) return true;
  for (uint8_t i = 0; i < index; ++i) {
    if (evidence[i].status == ProbeStatus::Started &&
        evidence[i].ackCount > 0) {
      return false;
    }
  }
  return true;
}

inline bool candidateMatches(const CandidateRule &candidate,
                             uint32_t flashBytes,
                             const ProbeEvidence *evidence,
                             size_t evidenceCount) {
  if (!flashMatches(flashBytes, candidate.flashMinExclusive,
                    candidate.flashMaxInclusive)) {
    return false;
  }
  if (candidate.match == CandidateMatch::Always) return true;
  if (candidate.match == CandidateMatch::FlashRange) return true;
  if (candidate.probeIndex >= evidenceCount || evidence == nullptr) {
    return false;
  }
  const ProbeEvidence &probe = evidence[candidate.probeIndex];
  switch (candidate.match) {
    case CandidateMatch::I2cAnyAck:
      return probe.status == ProbeStatus::Started && probe.ackCount > 0;
    case CandidateMatch::I2cNoAck:
      return probe.status == ProbeStatus::Started && probe.ackCount == 0;
    case CandidateMatch::I2cAnyAckOrStartFailure:
      return probe.status == ProbeStatus::StartFailed ||
             (probe.status == ProbeStatus::Started && probe.ackCount > 0);
    case CandidateMatch::Always:
    case CandidateMatch::FlashRange:
      return true;
  }
  return false;
}

inline Evaluation evaluate(const FamilyDetectionPlan &plan,
                           uint32_t flashBytes,
                           const ProbeEvidence *evidence,
                           size_t evidenceCount,
                           const SenseEvidence *senses = nullptr,
                           size_t senseCount = 0) {
  uint8_t selected = 0;
  uint8_t matches = 0;
  for (uint8_t i = 0; i < plan.candidateCount; ++i) {
    const CandidateRule &candidate = plan.candidates[i];
    if (!candidateMatches(candidate, flashBytes, evidence, evidenceCount) ||
        !senseMatches(candidate, senses, senseCount)) {
      continue;
    }
    if (matches == 0) selected = candidate.variantValue;
    ++matches;
  }
  if (plan.resolution == ResolutionPolicy::ExactlyOne && matches != 1) {
    selected = 0;
  }
  if (plan.resolution == ResolutionPolicy::FirstMatch && matches == 0) {
    selected = 0;
  }
  return {selected, matches};
}

}  // namespace boarddetectmodel
