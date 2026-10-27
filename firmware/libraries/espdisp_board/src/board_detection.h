// Hardware-free declarative board detection evaluator.
//
// A candidate may also carry an analog sense guard: the millivolts read on one
// GPIO, with the internal pull-down enabled, must fall inside the candidate's
// window. It separates carriers whose I2C buses answer identically (the S3
// 1.3-inch and 1.9-inch carriers both expose only a QMI8658 at 0x6B on
// GPIO47/48). A guarded candidate never matches without a reading.
//
// A MIPI-DSI family may also identify its carrier by the panel controller
// itself: the ID bytes the panel returns to a DCS read. The P4 4B and 4C
// carriers wire identical I2C buses, so the controller ID separates them,
// together with a sense guard that reads each carrier's own wiring. A
// candidate either names the exact ID it requires, or accepts any completed
// read that no other candidate in the family claims; the validator requires
// the second kind to carry a sense guard.
//
// A candidate may also require the resolution stored in its GT9xx touch
// controller's config. It is the only runtime difference between two
// carriers that share a PCB and a panel controller but not the glass (the
// 3.4C and 4C). The register is read passively over I2C; nothing is written.
//
// A candidate may also require that an SPI panel controller answers, or that
// nothing does, on one family-wide set of panel lines. It separates the two
// XIAO ESP32-S3 boards, whose I2C buses are equally silent: the screen XIAO's
// ST7735 drives its SDA line in reply to RDDID, while on a bare XIAO the line
// only holds the level the host last left on it.
#pragma once

#include <stddef.h>
#include <stdint.h>

namespace boarddetectmodel {

enum class ProbeStatus : uint8_t {
  NotRun,
  Started,
  StartFailed,
  /// The bus started but cannot be trusted: CANARY_ADDRESS acknowledged or
  /// errored, or transactions errored and nothing acknowledged. It is stuck
  /// or back-powered, so neither its answers nor its silence are evidence.
  Discarded,
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
  DsiPanelId,
  DsiPanelIdOther,
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
  // A probe line is another board's audio amplifier enable. The probe's
  // pull-ups could switch that amplifier on, so it runs only while no earlier
  // probe has identified a board.
  bool quietAfterMatch = false;
};

/// No analog sense guard on this candidate.
static constexpr uint8_t NO_SENSE = 255;

/// What a candidate requires of the family's SPI panel readback.
enum class PanelReadback : uint8_t {
  NotChecked,
  /// A panel controller drove the data line in reply.
  Answers,
  /// The read completed and nothing drove the line.
  Silent,
};

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
  /// The controller ID a DsiPanelId candidate requires.
  uint8_t panelId[3] = {0, 0, 0};
  /// The GT9xx config resolution this candidate requires; 0x0 = not checked.
  uint16_t touchWidth = 0;
  uint16_t touchHeight = 0;
  /// What the family's SPI panel readback must have found.
  PanelReadback panelReadback = PanelReadback::NotChecked;
};

/// One analog sense reading, indexed like FamilyDetectionPlan::sensePins.
struct SenseEvidence {
  bool read = false;
  uint16_t millivolts = 0;
};

/// DCS "read display ID": three bytes on both MIPI-DSI controllers in use.
static const uint8_t DSI_PANEL_ID_COMMAND = 0x04;

/// How to reach a MIPI-DSI panel for its ID read. Every DSI candidate in a
/// family shares these facts, so the read runs before the carrier is known.
struct DsiIdProbePlan {
  uint8_t dataLanes;
  uint16_t laneMbps;
  int8_t resetPin;
  uint16_t resetLowMs;
  uint16_t resetReleaseWaitMs;
};

/// The ID bytes one DCS read returned. Unread when the read failed or timed
/// out. A completed read of all 0x00 or all 0xFF is still evidence: it can
/// never equal a declared ID (the validator refuses those), so it only reaches
/// a DsiPanelIdOther candidate, whose sense guard must also agree.
struct PanelIdEvidence {
  bool read = false;
  uint8_t id[3] = {0, 0, 0};
};

inline PanelIdEvidence panelIdEvidenceFromRead(bool ok, const uint8_t *id) {
  PanelIdEvidence evidence;
  if (!ok || id == nullptr) return evidence;
  evidence.read = true;
  for (int i = 0; i < 3; ++i) evidence.id[i] = id[i];
  return evidence;
}

/// GT9xx config register holding X output max then Y output max, each u16
/// little-endian, as the touch controller stores them for its glass.
static const uint16_t GT_CONFIG_RESOLUTION_REGISTER = 0x8048;

/// Where to read the touch controller's config resolution: its I2C bus and
/// the addresses it may answer on (GT9xx picks one at reset).
struct TouchConfigProbePlan {
  int8_t sda;
  int8_t scl;
  uint8_t addresses[2];
  uint8_t addressCount;
};

/// The config resolution a touch controller returned. Unread when no
/// address answered or the read failed.
struct TouchConfigEvidence {
  bool read = false;
  uint16_t width = 0;
  uint16_t height = 0;
};

inline TouchConfigEvidence touchConfigEvidenceFromRead(bool ok,
                                                       const uint8_t *bytes) {
  TouchConfigEvidence evidence;
  if (!ok || bytes == nullptr) return evidence;
  evidence.read = true;
  evidence.width = (uint16_t)(bytes[0] | (bytes[1] << 8));
  evidence.height = (uint16_t)(bytes[2] | (bytes[3] << 8));
  return evidence;
}

/// The SPI panel lines a readback drives: the panel's clock, its one data
/// line (written, then left floating and read), chip select, data/command and
/// reset. Every readback candidate in a family shares them; on a board whose
/// panel is absent they are unconnected pads.
struct SpiReadbackProbePlan {
  int8_t sclk;
  int8_t sda;
  int8_t cs;
  int8_t dc;
  int8_t rst;
};

/// MIPI DCS "read display ID". In the ST7735's 4-line serial mode the reply
/// comes back on SDA after one dummy clock.
static const uint8_t SPI_READBACK_COMMAND = 0x04;
/// Bits clocked in after the command: the dummy bit, the three ID bytes and
/// seven more, exactly as the screen XIAO's bench read was taken.
static const uint8_t SPI_READBACK_BITS = 32;
/// The bench read's timing: reset held low 20 ms, 150 ms before the command,
/// 50 us half periods while writing and 200 us of settling either side of
/// each read edge. The line is read floating: on the bench, with the ESP32's
/// own pull-up or pull-down enabled the screen XIAO's reply read as all ones
/// or all zeros, the same as a bare XIAO's.
static const uint16_t SPI_READBACK_RESET_LOW_MS = 20;
static const uint16_t SPI_READBACK_RESET_WAIT_MS = 150;
static const uint16_t SPI_READBACK_WRITE_HALF_US = 50;
static const uint16_t SPI_READBACK_READ_SETTLE_US = 200;

/// The bits one readback clocked in. Unread when the read could not run.
struct PanelReadbackEvidence {
  bool read = false;
  bool answered = false;
  uint32_t bits = 0;
};

/// Level changes between successive bits of a reading.
inline uint8_t readbackTransitions(uint32_t bits, uint8_t count) {
  uint8_t transitions = 0;
  for (uint8_t i = 1; i < count; ++i) {
    if (((bits >> i) & 1u) != ((bits >> (i - 1)) & 1u)) ++transitions;
  }
  return transitions;
}

/// A floating line nobody drives keeps the level the host left on it, or at
/// most drifts slowly to the other one (leakage, a finger): one level change
/// at most. A controller's reply changes level again and again (the screen
/// XIAO's bench readings 41BB07FF, 41800000 and 41BBFFFF have 4 to 10), so
/// two or more changes is a panel answering. `bits` holds the first bit
/// clocked in as its most significant of `count`; a count outside 1..32 is no
/// reading.
inline PanelReadbackEvidence panelReadbackEvidenceFromBits(uint32_t bits,
                                                           uint8_t count) {
  PanelReadbackEvidence evidence;
  if (count == 0 || count > 32) return evidence;
  const uint32_t mask = count == 32 ? 0xFFFFFFFFu : ((1u << count) - 1u);
  evidence.read = true;
  evidence.bits = bits & mask;
  evidence.answered = readbackTransitions(evidence.bits, count) >= 2;
  return evidence;
}

struct FamilyDetectionPlan {
  const I2cProbePlan *probes;
  uint8_t probeCount;
  const CandidateRule *candidates;
  uint8_t candidateCount;
  ResolutionPolicy resolution;
  const int8_t *sensePins = nullptr;
  uint8_t senseCount = 0;
  const DsiIdProbePlan *dsiIdProbe = nullptr;
  const TouchConfigProbePlan *touchConfigProbe = nullptr;
  const SpiReadbackProbePlan *panelReadbackProbe = nullptr;
};

/// The panel-readback half of a candidate. A candidate that checks nothing
/// passes; the others need a completed read with the answer they name.
inline bool panelReadbackMatches(const CandidateRule &candidate,
                                 const PanelReadbackEvidence *readback) {
  if (candidate.panelReadback == PanelReadback::NotChecked) return true;
  if (readback == nullptr || !readback->read) return false;
  return readback->answered ==
         (candidate.panelReadback == PanelReadback::Answers);
}

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

inline bool panelIdEquals(const CandidateRule &candidate,
                          const PanelIdEvidence &evidence) {
  return evidence.read && evidence.id[0] == candidate.panelId[0] &&
         evidence.id[1] == candidate.panelId[1] &&
         evidence.id[2] == candidate.panelId[2];
}

/// The panel-ID half of a candidate. Other kinds pass. DsiPanelIdOther accepts
/// an answered ID only when no DsiPanelId candidate of the same plan claims it,
/// so the two kinds can never both match one reading.
inline bool panelIdMatches(const FamilyDetectionPlan &plan,
                           const CandidateRule &candidate,
                           const PanelIdEvidence *panelId) {
  if (candidate.match != CandidateMatch::DsiPanelId &&
      candidate.match != CandidateMatch::DsiPanelIdOther) {
    return true;
  }
  if (panelId == nullptr || !panelId->read) return false;
  if (candidate.match == CandidateMatch::DsiPanelId) {
    return panelIdEquals(candidate, *panelId);
  }
  for (uint8_t i = 0; i < plan.candidateCount; ++i) {
    const CandidateRule &other = plan.candidates[i];
    if (other.match == CandidateMatch::DsiPanelId &&
        panelIdEquals(other, *panelId)) {
      return false;
    }
  }
  return true;
}

/// The touch-config half of a candidate: a candidate that names a resolution
/// matches only a read that returned exactly it.
inline bool touchConfigMatches(const CandidateRule &candidate,
                               const TouchConfigEvidence *touch) {
  if (candidate.touchWidth == 0 && candidate.touchHeight == 0) return true;
  return touch != nullptr && touch->read &&
         touch->width == candidate.touchWidth &&
         touch->height == candidate.touchHeight;
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

/// Evidence from one address-list probe. A bus that also acknowledged
/// CANARY_ADDRESS is Discarded rather than silent: an i2c_no_ack candidate
/// (the XIAO, against the 0.85's stuck codec bus) must not match it.
inline ProbeEvidence addressProbeEvidence(bool busStarted, uint8_t ackCount,
                                          bool canaryAcked) {
  if (!busStarted) return {ProbeStatus::StartFailed, 0};
  if (canaryAcked) return {ProbeStatus::Discarded, 0};
  return {ProbeStatus::Started, ackCount};
}

/// One address-list probe on a started bus, with each address transaction
/// behind `acked(address)`. Acknowledgements are discarded when the bus also
/// acknowledges CANARY_ADDRESS (stuck or back-powered), checked both before
/// and after the list: another driver can pull a line low partway through (on
/// a 1.75C, GPIO11 is the touch interrupt and the 1.85C bus's SDA), which
/// acknowledges every later address, and the trailing canary sees it too.
template <typename Acked>
inline ProbeEvidence addressListEvidence(const I2cProbePlan &plan,
                                         Acked acked) {
  if (acked(CANARY_ADDRESS)) return addressProbeEvidence(true, 0, true);
  uint8_t found = 0;
  for (uint8_t i = 0; i < plan.addressCount; ++i) {
    if (acked(plan.addresses[i])) ++found;
  }
  const bool trailingCanary = found > 0 && acked(CANARY_ADDRESS);
  return addressProbeEvidence(true, found, trailingCanary);
}

/// How one address transaction ended. Only an ACK or a NACK says anything
/// about the address. On Arduino-ESP32 3.3 a zero-length probe ends in a
/// timeout (SCL held low, or a device stretching past it) or a driver error
/// otherwise, and either says the bus could not run the transaction.
enum class AddressReply : uint8_t { Ack, Nack, BusError };

/// addressListEvidence over transactions that may also fail outright. An
/// error vetoes silence, never a real ACK: a 0.85 codec bus with SCL stuck
/// low times out on every address, the canary included, and must not read as
/// the XIAO's clean silence, while a stuck SCL can never produce an ACK, so a
/// device that acked beside one that timed out (the 1.85C's TCA9554 beside a
/// slow touch chip) is still evidence. An error on the canary itself discards
/// the bus, like a canary that acked.
template <typename Reply>
inline ProbeEvidence addressReplyEvidence(const I2cProbePlan &plan,
                                          Reply reply) {
  bool busError = false;
  bool canaryError = false;
  const ProbeEvidence evidence =
      addressListEvidence(plan, [&](uint8_t address) {
        const AddressReply answer = reply(address);
        if (answer == AddressReply::BusError) {
          busError = true;
          if (address == CANARY_ADDRESS) canaryError = true;
        }
        return answer == AddressReply::Ack;
      });
  if (canaryError || (busError && evidence.ackCount == 0)) {
    return {ProbeStatus::Discarded, 0};
  }
  return evidence;
}

/// Whether probe `index` should run given the evidence gathered so far. A probe
/// with a reset line drives that GPIO push-pull (on the CrowPanel knob it is the
/// panel supply rail), and a quietAfterMatch probe pulls up a line that is
/// another board's amplifier enable (the 1.75C's SDA is the 1.85C V2's
/// GPIO15). Either is only justified while no earlier probe has identified its
/// board: once one has, this probe could only add a second candidate, and on
/// that board the line is some other net.
inline bool shouldRunProbe(const FamilyDetectionPlan &plan, uint8_t index,
                           const ProbeEvidence *evidence) {
  if (index >= plan.probeCount) return false;
  if (plan.probes[index].resetPin < 0 && !plan.probes[index].quietAfterMatch) {
    return true;
  }
  for (uint8_t i = 0; i < index; ++i) {
    if (evidence[i].status == ProbeStatus::Started &&
        evidence[i].ackCount > 0) {
      return false;
    }
  }
  return true;
}

/// The I2C probe loop, with the electrical work behind `collect(index)` and the
/// skip report behind `skipped(index)`. probeS3 runs it against the real bus;
/// host tests run the same loop and skip rules against a simulated one.
template <typename Collect, typename Skipped>
inline void runI2cProbes(const FamilyDetectionPlan &plan, uint32_t flashBytes,
                         ProbeEvidence *evidence, Collect collect,
                         Skipped skipped) {
  for (uint8_t i = 0; i < plan.probeCount; ++i) {
    const I2cProbePlan &probe = plan.probes[i];
    if (!flashMatches(flashBytes, probe.flashMinExclusive,
                      probe.flashMaxInclusive)) {
      continue;
    }
    if (!shouldRunProbe(plan, i, evidence)) {
      skipped(i);
      continue;
    }
    evidence[i] = collect(i);
  }
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
  // Decided by panelIdMatches, which needs the whole plan.
  if (candidate.match == CandidateMatch::DsiPanelId ||
      candidate.match == CandidateMatch::DsiPanelIdOther) {
    return true;
  }
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
    case CandidateMatch::DsiPanelId:
    case CandidateMatch::DsiPanelIdOther:
      return true;
  }
  return false;
}

/// Whether the family's SPI panel readback should run after the I2C probes:
/// only while a candidate that checks it can still match. The readback drives
/// one board's panel lines, so it never runs on a board the probes have
/// already placed elsewhere (an answering 0.85 codec bus, larger flash).
inline bool panelReadbackNeeded(const FamilyDetectionPlan &plan,
                                uint32_t flashBytes,
                                const ProbeEvidence *evidence,
                                size_t evidenceCount) {
  if (plan.panelReadbackProbe == nullptr) return false;
  for (uint8_t i = 0; i < plan.candidateCount; ++i) {
    const CandidateRule &candidate = plan.candidates[i];
    if (candidate.panelReadback != PanelReadback::NotChecked &&
        candidateMatches(candidate, flashBytes, evidence, evidenceCount)) {
      bool otherProbeAnswered = false;
      for (size_t probe = 0; probe < evidenceCount; ++probe) {
        if (probe != candidate.probeIndex &&
            evidence[probe].status == ProbeStatus::Started &&
            evidence[probe].ackCount > 0) {
          otherProbeAnswered = true;
          break;
        }
      }
      if (!otherProbeAnswered) {
        return true;
      }
    }
  }
  return false;
}

inline bool panelReadbackFallbackMatches(const CandidateRule &candidate,
                                         const ProbeEvidence *evidence,
                                         size_t evidenceCount) {
  if (candidate.panelReadback == PanelReadback::NotChecked) return true;
  for (size_t probe = 0; probe < evidenceCount; ++probe) {
    if (probe != candidate.probeIndex &&
        evidence[probe].status == ProbeStatus::Started &&
        evidence[probe].ackCount > 0) {
      return false;
    }
  }
  return true;
}

inline Evaluation evaluate(const FamilyDetectionPlan &plan,
                           uint32_t flashBytes,
                           const ProbeEvidence *evidence,
                           size_t evidenceCount,
                           const SenseEvidence *senses = nullptr,
                           size_t senseCount = 0,
                           const PanelIdEvidence *panelId = nullptr,
                           const TouchConfigEvidence *touchConfig = nullptr,
                           const PanelReadbackEvidence *readback = nullptr) {
  uint8_t selected = 0;
  uint8_t matches = 0;
  for (uint8_t i = 0; i < plan.candidateCount; ++i) {
    const CandidateRule &candidate = plan.candidates[i];
    if (!candidateMatches(candidate, flashBytes, evidence, evidenceCount) ||
        !senseMatches(candidate, senses, senseCount) ||
        !panelIdMatches(plan, candidate, panelId) ||
        !touchConfigMatches(candidate, touchConfig) ||
        !panelReadbackMatches(candidate, readback) ||
        !panelReadbackFallbackMatches(candidate, evidence, evidenceCount)) {
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
