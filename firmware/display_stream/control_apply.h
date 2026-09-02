// Management controls and pushed idle text. Both arrive on the network
// task and are consumed by the loop task, so both live behind controlMux;
// the queue-and-dedup logic itself is controlq::ControlQueue (host-tested).
#pragma once

#include <Arduino.h>

#include "control_queue.h"
#include "device_protocol.h"

// Guards `controls`, `idleText`, and `idleTextAt`. Producers: the inbound
// dispatch (net_link.cpp). Consumers: applyPendingControl() and the idle-text
// readers (ui_screens.cpp, prefs_store.cpp).
extern portMUX_TYPE controlMux;
extern controlq::ControlQueue controls;

// Lines the sender asked the panel to show on its status card, with when
// they arrived. lastSavedIdleText is the copy NVS last held (prefs_store.cpp
// bounds flash wear against it).
extern deviceproto::IdleTextMessage idleText;
extern uint32_t idleTextAt;
extern deviceproto::IdleTextMessage lastSavedIdleText;

// Deferred restart request (control opcode / loop timer).
extern uint32_t restartAt;

// Apply one queued control command on the loop task.
void applyPendingControl();
