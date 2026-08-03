// Control command admission, de-duplication, and queueing. Hardware-free so
// the rules can be tested on the host instead of only on a panel.
//
// This logic lived inline in the UDP callback as ten module-level variables and
// three separate ring-buffer updates, which made the one subtle rule in it
// impossible to check: a duplicate must be acknowledged again only once the
// original has actually been applied.
//
// Two rings are needed for that. The "recent" ring advances when a command is
// accepted, the "applied" ring only when the loop has carried it out. A
// duplicate arriving in the window between the two must be neither re-enqueued
// nor acknowledged, because acknowledging it would tell the sender a change had
// taken effect that has not yet happened.
//
// Not thread-safe by design: the caller owns the critical section, since the
// locking primitive is platform-specific and this file is not.
#pragma once

#include <stddef.h>
#include <stdint.h>

#include "device_protocol.h"

namespace controlq {

static const uint8_t QUEUE_CAPACITY = 8;

enum class Admission : uint8_t {
  // New command, queued for the loop to apply.
  Enqueued,
  // Duplicate of a command still waiting to be applied, or the queue is full.
  // Either way there is nothing to say yet.
  Dropped,
  // Duplicate of a command already applied: acknowledge it again, because the
  // sender repeats commands and its first acknowledgement may have been lost.
  ReplayAck,
};

class ControlQueue {
 public:
  /// Decide what to do with an arriving command, enqueueing it if it is new.
  Admission offer(const deviceproto::ControlCommand &command) {
    const bool applied = contains(appliedSequences_, appliedCount_, command.sequence);
    const bool recent =
        applied || contains(recentSequences_, recentCount_, command.sequence);

    if (recent) {
      if (applied) {
        duplicateAck_ = command;
        hasDuplicateAck_ = true;
        return Admission::ReplayAck;
      }
      return Admission::Dropped;
    }
    if (queueCount_ >= QUEUE_CAPACITY) {
      return Admission::Dropped;
    }

    queue_[queueTail_] = command;
    queueTail_ = advance(queueTail_);
    queueCount_++;
    remember(recentSequences_, recentCount_, recentNext_, command.sequence);
    return Admission::Enqueued;
  }

  /// Pop the next command for the loop to apply.
  bool take(deviceproto::ControlCommand &out) {
    if (queueCount_ == 0) return false;
    out = queue_[queueHead_];
    queueHead_ = advance(queueHead_);
    queueCount_--;
    return true;
  }

  /// Record that a command has actually been carried out, which is what makes
  /// later duplicates of it worth acknowledging.
  void markApplied(uint16_t sequence) {
    remember(appliedSequences_, appliedCount_, appliedNext_, sequence);
  }

  /// Pop the duplicate awaiting a repeated acknowledgement, if any.
  bool takeDuplicateAck(deviceproto::ControlCommand &out) {
    if (!hasDuplicateAck_) return false;
    out = duplicateAck_;
    hasDuplicateAck_ = false;
    return true;
  }

  uint8_t pending() const { return queueCount_; }
  bool hasDuplicateAck() const { return hasDuplicateAck_; }

 private:
  static uint8_t advance(uint8_t index) {
    return (uint8_t)((index + 1) % QUEUE_CAPACITY);
  }

  static bool contains(const uint16_t *ring, uint8_t count, uint16_t sequence) {
    for (uint8_t i = 0; i < count; i++) {
      if (ring[i] == sequence) return true;
    }
    return false;
  }

  static void remember(uint16_t *ring, uint8_t &count, uint8_t &next,
                       uint16_t sequence) {
    ring[next] = sequence;
    next = advance(next);
    if (count < QUEUE_CAPACITY) count++;
  }

  deviceproto::ControlCommand queue_[QUEUE_CAPACITY] = {};
  uint8_t queueHead_ = 0;
  uint8_t queueTail_ = 0;
  uint8_t queueCount_ = 0;

  uint16_t recentSequences_[QUEUE_CAPACITY] = {0};
  uint8_t recentCount_ = 0;
  uint8_t recentNext_ = 0;

  uint16_t appliedSequences_[QUEUE_CAPACITY] = {0};
  uint8_t appliedCount_ = 0;
  uint8_t appliedNext_ = 0;

  deviceproto::ControlCommand duplicateAck_ = {};
  bool hasDuplicateAck_ = false;
};

}  // namespace controlq
