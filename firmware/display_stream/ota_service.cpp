#include "ota_service.h"

#include <Arduino.h>
#include <ArduinoOTA.h>
#include <Preferences.h>
#include <Update.h>
#include <WiFi.h>

#include <esp_task_wdt.h>

#include "app_state.h"
#include "display_power.h"
#include "ota_policy.h"
#include "ui_screens.h"


// ---- OTA (ArduinoOTA over WiFi, LAN only) -------------------------------
// Fails closed, deliberately: an unpassworded ArduinoOTA is an unauthenticated
// remote-code-execution path for anything that can reach this panel. There is no
// default password and none is generated - with nothing stored, OTA does not
// start and CAP_OTA is not advertised, which is the state every panel already
// ships in. Set one with CFGOTAPW over USB.
//
// The plaintext is deliberately NOT kept in a global. It is read from NVS into a
// local inside startOtaIfConfigured() and handed to ArduinoOTA, which stores only
// SHA256(password) (verified in the core's ArduinoOTA.cpp setPassword). The two
// flags below are all that stays resident.
const uint16_t OTA_PORT = 3232;  // ArduinoOTA's own default port
bool otaConfigured = false;      // a password is stored in NVS
bool otaActive = false;          // begin() has run, handle() is live

// The two flags collapsed into the one thing anybody is told, so the capability
// bit and CFGSHOW's ota= cannot drift apart. The rules live in ota_policy.h
// where they are tested on the host.
otapolicy::Status currentOtaStatus() {
  return otapolicy::status(otaActive, otaConfigured);
}
// Set for the duration of a write. The whole transfer happens inside one
// ArduinoOTA.handle() call, so the loop does not normally iterate while this is
// set; it exists so that if it ever does, nothing repaints over the progress
// screen and no DMA is queued underneath the flash writes.
volatile bool otaInProgress = false;
static uint8_t otaShownPercent = 0;
// First ArduinoOTA error from the current attempt. Core 3.3.11 invokes
// OTA_CONNECT_ERROR and then falls through to Update.end(), which invokes
// OTA_END_ERROR with "Aborted". Without remembering the first callback, the
// second one overwrites the useful "connect lost" screen with "bad image".
static int otaPrimaryError = -1;
// The dimmed states onStart clears so an update is visible, held so onError can
// put them back. A successful push reboots, so only the failure path needs them.
// See otapolicy::SavedPanelState for why this is a type rather than two bools:
// onError is reachable without onStart, and restoring in that case woke a
// sleeping panel for anything on the LAN that got the password wrong.
static otapolicy::SavedPanelState otaSavedPanel;
// Bring OTA up, if it is configured and the radio is ready.
//
// Returns true only on the transition to active, so the caller knows the mDNS
// caps TXT record needs re-announcing.
//
// Fails closed at every step: no stored password means no listener and no
// CAP_OTA. The password is read into a local and handed straight to ArduinoOTA,
// which keeps only SHA256(password) - so the plaintext exists in RAM for the
// length of this call and not for the uptime of the panel.
bool startOtaIfConfigured() {
  if (otaActive || !otaConfigured) {
    return false;
  }
  if (WiFi.status() != WL_CONNECTED) {
    return false;  // nothing to bind a socket to yet; retried from the loop
  }

  String otaPassword;
  {
    Preferences prefs;
    prefs.begin("espdisp", true /* read-only */);
    otaPassword = prefs.getString("otapw", "");
    prefs.end();
  }
  if (otaPassword.isEmpty()) {
    otaConfigured = false;  // cleared behind our back; stop retrying
    return false;
  }

  ArduinoOTA.setHostname(cfgName.c_str());  // <name>.local, not esp32-<mac>
  ArduinoOTA.setPassword(otaPassword.c_str());
  ArduinoOTA.setPort(OTA_PORT);
  ArduinoOTA.setMdnsEnabled(false);  // addMdnsService() owns every registration

  ArduinoOTA.onStart([]() {
    // Fed here so the drawing below gets its own watchdog interval instead of
    // sharing the one that started at the top of loop(). The draw is bounded at
    // ~700ms by construction - waitForDmaIdle(200) on the way into drawOtaScreen
    // and waitForDmaIdle(500) on the way out, plus a full-frame push - which is a
    // sum of two limits this file sets, not a measurement. Against a 10s timeout
    // it plainly fits; this costs one line and removes the need to care.
    //
    // An earlier version of this comment said Update.begin() erases the whole
    // 0x140000 app slot before any data arrives, and that this reset covers that
    // erase. Both halves are wrong, read out of the core rather than assumed:
    // UpdateClass::begin() (Updater.cpp:184) resets state, picks the partition
    // with esp_ota_get_next_update_partition, and allocates a sector buffer - it
    // erases nothing. The erase is per-64KB block inside _writeBuffer()
    // (Updater.cpp:665) as data arrives, so it falls between two progress
    // callbacks, each of which already feeds the watchdog. And _runUpdate calls
    // _updater->begin() at ArduinoOTA.cpp:343, before _start_callback() at 357,
    // so a reset here could not have covered it even if it did erase - a panic
    // would have happened inside begin(), upstream of this callback.
    esp_task_wdt_reset();
    otaInProgress = true;
    otaShownPercent = 0;
    otaPrimaryError = -1;
    // Make the update visible whatever state the panel was in: a push that
    // arrives while the Mac's displays are asleep would otherwise happen behind
    // a dark screen. Saved so a FAILED push can put it back - on success the
    // board reboots and the sender re-establishes both, but a failure leaves this
    // firmware running and the panel should go back to the state the Mac put it
    // in rather than sitting lit until the 45s idle timer notices.
    otaSavedPanel.save(displaySleeping, idleActive);
    displaySleeping = false;
    idleActive = false;
    applyBacklight();
    Serial.println("ota: update starting");
    drawOtaScreen("updating", 0);
    // Belt and braces. _runUpdate calls _progress_callback(0, _size) immediately
    // after _start_callback() returns (ArduinoOTA.cpp:359), and onProgress resets
    // the watchdog as its first statement, ahead of its own early return - so
    // this interval is already ended microseconds from now and this line changes
    // nothing today. It is here so the draw above stays covered if a future core
    // stops making that opening progress call.
    esp_task_wdt_reset();
  });

  ArduinoOTA.onProgress([](unsigned int done, unsigned int total) {
    // The whole transfer runs inside ArduinoOTA.handle(), which does not return
    // to the top of loop() until it is finished - so the 10s task watchdog is
    // fed from here or a legitimate update panics the board partway through.
    esp_task_wdt_reset();
    if (total == 0) {
      return;
    }
    uint8_t percent = (uint8_t)((uint64_t)done * 100u / total);
    // Repaint in 5% steps. This callback fires once per 1460-byte chunk (~770
    // times for a 1.1MB image) and a full-frame push costs tens of milliseconds,
    // so redrawing on every call would slow the update down for no extra
    // information.
    if (percent < otaShownPercent + 5 && percent != 100) {
      return;
    }
    otaShownPercent = percent;
    Serial.printf("ota: %u%%\n", (unsigned)percent);
    drawOtaScreen("updating", (int)percent);
  });

  ArduinoOTA.onEnd([]() {
    // ArduinoOTA reboots ~100ms after this returns (setRebootOnSuccess is left
    // at its default), so this is the last thing the old firmware draws.
    Serial.println("ota: complete, rebooting");
    drawOtaScreen("rebooting", 100);
    otaInProgress = false;
    // Success owes the panel nothing back - the reboot re-establishes both flags
    // from the sender - but drop the saved state here rather than letting the
    // reboot be what clears it. Otherwise "nothing saved crosses a push" rests on
    // _rebootOnSuccess still being true, which is a core default this sketch never
    // sets and which only the comment above records. One call makes the invariant
    // hold from this side instead of depending on that.
    otaSavedPanel.discard();
    otaPrimaryError = -1;
  });

  ArduinoOTA.onError([](ota_error_t error) {
    otaInProgress = false;
    const char *detail = error == OTA_END_ERROR ? Update.errorString() : "";

    // Core 3.3.11 does not return after its reverse TCP connect fails. It first
    // reports OTA_CONNECT_ERROR, then calls Update.end() with zero bytes written,
    // which reports OTA_END_ERROR / Aborted. The second callback is fallout from
    // the first failure, not an image verdict, and must not replace the useful
    // message already on the glass.
    if (otaPrimaryError == (int)OTA_CONNECT_ERROR &&
        error == OTA_END_ERROR && strcmp(detail, "Aborted") == 0) {
      Serial.println(
          "ota: ignored secondary end error after connect failure (Aborted)");
      return;
    }
    if (error != OTA_END_ERROR || otaPrimaryError < 0) {
      otaPrimaryError = (int)error;
    }

    const char *what = "failed";
    switch (error) {
      case OTA_AUTH_ERROR:
        what = "bad password";
        break;
      case OTA_BEGIN_ERROR:
        what = "no free slot";
        break;
      case OTA_CONNECT_ERROR:
        what = "connect lost";
        break;
      case OTA_RECEIVE_ERROR:
        what = "transfer lost";
        break;
      case OTA_END_ERROR:
        if (strcmp(detail, "MD5 Check Failed") == 0) {
          what = "md5 failed";
        } else if (strcmp(detail, "Wrong Magic Byte") == 0) {
          what = "wrong image";
        } else if (strcmp(detail, "Could Not Activate The Firmware") == 0) {
          what = "image refused";
        } else if (strcmp(detail, "Aborted") == 0) {
          what = "incomplete";
        } else if (strstr(detail, "Flash ") == detail) {
          what = "flash failed";
        } else {
          what = "bad image";
        }
        break;
    }
    if (error == OTA_END_ERROR) {
      Serial.printf("ota: %s (error %d, detail: %s)\n", what, (int)error,
                    detail[0] ? detail : "unknown");
    } else {
      Serial.printf("ota: %s (error %d)\n", what, (int)error);
    }
    // Leave the reason on the glass rather than snapping back to the stream: a
    // failed push is exactly when someone is standing in front of the panel. The
    // next completed frame overwrites it, and a rejected image never touched the
    // running slot - the panel is still on the firmware it booted.
    drawOtaScreen(what, -1);
    // Then put back what onStart cleared, if onStart ran on this push at all -
    // take() answers false when it did not, and this callback is reachable
    // without it (a wrong password never gets that far; see SavedPanelState).
    // Restoring unconditionally lit a panel the Mac had put to sleep, for
    // anything on the LAN willing to guess the password wrong.
    //
    // Deliberately after the draw, not before it. If the panel really was asleep
    // the reason then goes dark almost immediately, which is the right way round
    // - obeying the sender beats leaving a message nobody is there to read, and
    // the reason is on the serial line either way.
    if (otaSavedPanel.take(displaySleeping, idleActive)) {
      applyBacklight();
    }
  });

  // begin() returns void in core 3.3.11 (verified in ArduinoOTA.cpp: on a failed
  // UDP bind it logs "udp bind failed" and returns with itself uninitialised),
  // and there is no accessor for that state. So the preconditions above - a
  // stored password and an associated radio - are the whole of what can be
  // checked before advertising CAP_OTA. UNVERIFIED without hardware: that the
  // bind succeeds in practice. If it ever does not, handle() is a no-op and a
  // push simply times out; nothing else misbehaves.
  ArduinoOTA.begin();
  otaActive = true;
  Serial.printf("ota: listening on %s.local:%u (password required)\n",
                cfgName.c_str(), (unsigned)OTA_PORT);
  return true;
}
