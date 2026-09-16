#pragma once

#include <stdint.h>

namespace wifisupervisor {

constexpr uint32_t INITIAL_RETRY_MS = 5000;
constexpr uint32_t MAX_RETRY_MS = 60000;
constexpr uint32_t RADIO_FAULT_RESTART_MS = 60000;

enum class LinkState : uint8_t {
  Connected,
  NetworkUnavailable,
  RadioUnresponsive,
};

struct Decision {
  bool reconnect = false;
  bool restart = false;
  uint32_t nextRetryMs = 0;
};

class Supervisor {
 public:
  explicit Supervisor(bool restartAlreadyAttempted = false) {
    begin(restartAlreadyAttempted);
  }

  void begin(bool restartAlreadyAttempted) {
    disconnected_ = false;
    radioFaultActive_ = false;
    restartAlreadyAttempted_ = restartAlreadyAttempted;
    retryDelayMs_ = INITIAL_RETRY_MS;
    nextRetryAt_ = 0;
    radioFaultSince_ = 0;
  }

  Decision update(uint32_t now, LinkState state) {
    Decision decision;
    if (state == LinkState::Connected) {
      disconnected_ = false;
      radioFaultActive_ = false;
      retryDelayMs_ = INITIAL_RETRY_MS;
      return decision;
    }

    if (!disconnected_) {
      disconnected_ = true;
      retryDelayMs_ = INITIAL_RETRY_MS;
      nextRetryAt_ = now + retryDelayMs_;
    } else if (deadlineReached(now, nextRetryAt_)) {
      decision.reconnect = true;
      retryDelayMs_ =
          retryDelayMs_ >= MAX_RETRY_MS / 2 ? MAX_RETRY_MS : retryDelayMs_ * 2;
      nextRetryAt_ = now + retryDelayMs_;
      decision.nextRetryMs = retryDelayMs_;
    }

    if (state == LinkState::RadioUnresponsive) {
      if (!radioFaultActive_) {
        radioFaultActive_ = true;
        radioFaultSince_ = now;
      }
    }
    if (radioFaultActive_ &&
        now - radioFaultSince_ >= RADIO_FAULT_RESTART_MS &&
        requestRadioRestart()) {
      decision.reconnect = false;
      decision.restart = true;
    }
    return decision;
  }

  void noteReconnectResult(uint32_t now, bool commandAccepted) {
    if (commandAccepted) {
      radioFaultActive_ = false;
    } else if (!radioFaultActive_) {
      radioFaultActive_ = true;
      radioFaultSince_ = now;
    }
  }

  bool requestRadioRestart() {
    if (restartAlreadyAttempted_) return false;
    restartAlreadyAttempted_ = true;
    return true;
  }

  bool noteHealthyFrame() {
    if (!restartAlreadyAttempted_) return false;
    restartAlreadyAttempted_ = false;
    return true;
  }

  bool restartAlreadyAttempted() const {
    return restartAlreadyAttempted_;
  }

 private:
  static bool deadlineReached(uint32_t now, uint32_t deadline) {
    return (int32_t)(now - deadline) >= 0;
  }

  bool disconnected_ = false;
  bool radioFaultActive_ = false;
  bool restartAlreadyAttempted_ = false;
  uint32_t retryDelayMs_ = INITIAL_RETRY_MS;
  uint32_t nextRetryAt_ = 0;
  uint32_t radioFaultSince_ = 0;
};

}  // namespace wifisupervisor
