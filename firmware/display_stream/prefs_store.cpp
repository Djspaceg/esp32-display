#include "prefs_store.h"

#include <Arduino.h>
#include <Preferences.h>

#include "app_state.h"
#include "control_apply.h"
#include "device_protocol.h"
#include "display_power.h"
#include "orientation.h"

// NVS. This is what actually bounds flash wear for a template built from
// live tokens ({uptime}, {rssi}) - see saveIdleTextPrefsIfChanged's comment
// for why a reactive, push-triggered check cannot. One minute is short
// enough that a genuinely new template (the case this whole mechanism
// exists for) is saved promptly, and long enough that a template ticking
// with every 2-second EINF still costs at most one write a minute rather
// than one every few seconds.
const uint32_t IDLE_TEXT_SAVE_INTERVAL_MS = 60000;

// Persist the physical-mounting settings. Only written on a button press or an
// explicit command, so NVS wear is a non-issue.
void saveDisplayPrefs() {
  Preferences prefs;
  prefs.begin("espdisp", false);
  // "rot" supersedes the old "flip" bool (flip true == rot 2). setup() still
  // reads "flip" when no "rot" exists, so a panel upgraded in place keeps its
  // mounting; the old key is left alone rather than deleted, so a downgrade
  // to older firmware also keeps the 180 the two encodings agree on.
  prefs.putUChar("rot", panelRotation);
  prefs.putUChar("bllevel", userBlLevel);
  prefs.putBool("pwroff", panelManuallyOff);
  prefs.end();
}

// If the idle text held in RAM differs from what NVS last had, write it.
// Called from loop() on IDLE_TEXT_SAVE_INTERVAL_MS, never from the network
// path: see the comment in the ETXT branch of handleInbound for why a
// template built from live tokens ({uptime}, {rssi}) needs a time-bounded
// check rather than a reactive one to keep flash wear bounded at all - the
// EXPANDED TEXT legitimately changes on nearly every push for exactly the
// templates most likely to be in real use, so "did the content change"
// alone does not throttle anything for those.
//
// A device that reboots between checks loses at most one interval's worth of
// freshness in the saved copy - the same trade every polled-write scheme
// like this makes, and cheap next to what it buys: a screensaver template
// that used to vanish on every reboot now needs a genuinely unlucky timing
// window (a change landing in the last IDLE_TEXT_SAVE_INTERVAL_MS before a
// crash) to lose anything at all.
void saveIdleTextPrefsIfChanged() {
  deviceproto::IdleTextMessage snapshot;
  portENTER_CRITICAL(&controlMux);
  snapshot = idleText;
  portEXIT_CRITICAL(&controlMux);

  if (deviceproto::idleTextEqual(snapshot, lastSavedIdleText)) return;

  char encoded[deviceproto::IDLE_TEXT_MAX_BYTES];
  size_t n = deviceproto::encodeIdleTextForStorage(
      snapshot, encoded, sizeof(encoded));
  // A message that could not be encoded (should not happen: the buffer is
  // sized for the protocol's own maximum) is left as whatever NVS already
  // held rather than saving something truncated. lastSavedIdleText is
  // deliberately NOT updated here, so the next check retries rather than
  // treating a failed encode as if it had succeeded.
  if (n == 0 && snapshot.lineCount > 0) return;

  Preferences prefs;
  prefs.begin("espdisp", false);
  prefs.putString("idletxt", encoded);
  prefs.end();
  lastSavedIdleText = snapshot;
  Serial.printf("idle text saved to NVS (%u lines, %u bytes)\n",
                (unsigned)snapshot.lineCount, (unsigned)n);
}

