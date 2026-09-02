// ArduinoOTA bring-up and state. Fails closed: no stored password means no
// listener and no CAP_OTA (the tested policy lives in ota_policy.h).
#pragma once

#include <stdint.h>

#include "ota_policy.h"

extern const uint16_t OTA_PORT;
extern bool otaConfigured;          // a password is stored in NVS
extern bool otaActive;              // begin() has run, handle() is live
extern volatile bool otaInProgress; // a write is happening right now

otapolicy::Status currentOtaStatus();

// Bring OTA up if configured and the radio is ready. Returns true only on
// the transition to active, so the caller knows to re-announce mDNS.
bool startOtaIfConfigured();
