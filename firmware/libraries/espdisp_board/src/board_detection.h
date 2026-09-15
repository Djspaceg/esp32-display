// Hardware-free declarative board detection evaluator.
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

struct CandidateRule {
  uint8_t variantValue;
  CandidateMatch match;
  uint8_t probeIndex;
  uint32_t flashMinExclusive;
  uint32_t flashMaxInclusive;
};

struct FamilyDetectionPlan {
  const I2cProbePlan *probes;
  uint8_t probeCount;
  const CandidateRule *candidates;
  uint8_t candidateCount;
  ResolutionPolicy resolution;
};

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
                           size_t evidenceCount) {
  uint8_t selected = 0;
  uint8_t matches = 0;
  for (uint8_t i = 0; i < plan.candidateCount; ++i) {
    const CandidateRule &candidate = plan.candidates[i];
    if (!candidateMatches(candidate, flashBytes, evidence, evidenceCount)) {
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
