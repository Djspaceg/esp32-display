#include "serial_config.h"

#include <Arduino.h>
#include <Preferences.h>
#include <WiFi.h>
#include <mbedtls/base64.h>

#include <board_config.h>

#include "app_state.h"
#include "display_power.h"
#include "frame_pipeline.h"
#include "net_link.h"
#include "orientation.h"
#include "ota_policy.h"
#include "ota_service.h"
#include "prefs_store.h"
#include "signal_led.h"
#include "telemetry.h"
#include "tile_bench.h"


// Serial configuration protocol (USB CDC), so credentials can change
// without reflashing:
//   CFGWIFI <base64 ssid> <base64 password>\n  -> save to NVS, reply
//     CFGOK, reboot onto the new network (empty password = open network)
//   CFGOTAPW <base64 password> | CFGOTAPW clear\n  -> enable/disable OTA
//   CFGSHOW\n  -> CFGINFO ssid=... ip=... rssi=...
// Base64 avoids every quoting hazard SSIDs and passwords can contain.
static void processConfigLine(char *line) {
  if (strncmp(line, "CFGWIFI ", 8) == 0) {
    // CFGWIFI <b64 ssid> <b64 pass>  set both (empty pass = open network)
    // CFGWIFI <b64 ssid>             keep the password currently in use
    // The second form exists so changing the SSID (or just re-saving)
    // doesn't force the user to retype their password - and so a blank
    // field can never silently wipe a working password.
    char *b64Ssid = line + 8;
    char *sep = strchr(b64Ssid, ' ');
    bool keepPassword = (sep == nullptr);
    char *b64Pass = nullptr;
    if (!keepPassword) {
      *sep = 0;
      b64Pass = sep + 1;
    }

    unsigned char ssid[33], pass[65];
    size_t ssidLen = 0, passLen = 0;
    if (mbedtls_base64_decode(ssid, sizeof(ssid) - 1, &ssidLen,
                              (const unsigned char *)b64Ssid, strlen(b64Ssid)) != 0) {
      Serial.println("CFGERR bad base64 ssid (max 32 bytes)");
      return;
    }
    ssid[ssidLen] = 0;
    if (ssidLen == 0) {
      Serial.println("CFGERR empty ssid");
      return;
    }
    if (!keepPassword) {
      if (mbedtls_base64_decode(pass, sizeof(pass) - 1, &passLen,
                                (const unsigned char *)b64Pass, strlen(b64Pass)) != 0) {
        Serial.println("CFGERR bad base64 password (max 64 bytes)");
        return;
      }
      pass[passLen] = 0;
    }

    Preferences prefs;
    prefs.begin("espdisp", false);
    prefs.putString("ssid", (const char *)ssid);
    // When keeping, persist the *effective* password (which may have come
    // from the compiled fallback) so "keep" means exactly "what works now"
    // regardless of where it came from.
    prefs.putString("pass", keepPassword ? cfgPass : String((const char *)pass));
    prefs.end();

    Serial.printf("CFGOK saved \"%s\"%s, restarting\n", (const char *)ssid,
                  keepPassword ? " (password kept)" : "");
    Serial.flush();
    delay(200);
    ESP.restart();
  } else if (strncmp(line, "CFGNAME ", 8) == 0) {
    // Set the device name (mDNS hostname + service instance). Base64 like
    // CFGWIFI; sanitized to hostname-safe [a-z0-9-], max 32 chars.
    unsigned char raw[48];
    size_t rawLen = 0;
    if (mbedtls_base64_decode(raw, sizeof(raw) - 1, &rawLen,
                              (const unsigned char *)(line + 8),
                              strlen(line + 8)) != 0) {
      Serial.println("CFGERR bad base64");
      return;
    }
    raw[rawLen] = 0;
    char clean[33];
    size_t n = 0;
    for (size_t i = 0; i < rawLen && n < sizeof(clean) - 1; i++) {
      char c = (char)tolower(raw[i]);
      if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-') {
        clean[n++] = c;
      } else if (c == ' ' || c == '_') {
        clean[n++] = '-';
      }
    }
    clean[n] = 0;
    if (n == 0) {
      Serial.println("CFGERR name has no hostname-safe characters");
      return;
    }
    Preferences prefs;
    prefs.begin("espdisp", false);
    prefs.putString("name", clean);
    prefs.end();
    Serial.printf("CFGOK name \"%s\", restarting\n", clean);
    Serial.flush();
    delay(200);
    ESP.restart();
  } else if (strncmp(line, "CFGFLIP ", 8) == 0) {
    // Set the 180-degree flip without the button: CFGFLIP 0|1. Kept beside
    // CFGROT for old tooling and muscle memory; it maps onto the same stored
    // rotation (1 -> rot 2, 0 -> rot 0). Persisted, and applied on the next
    // drawn frame.
    int want = atoi(line + 8);
    panelRotation = want != 0 ? 2 : 0;
    madctlDirty = true;
    saveDisplayPrefs();
    Serial.printf("CFGOK flip180=%d rot=%u (saved; applies with next frame)\n",
                  want != 0, panelRotation);
  } else if (strncmp(line, "CFGROT ", 7) == 0) {
    // Set the mounting rotation in clockwise quarter turns: CFGROT 0|1|2|3.
    // Quarter turns (1 and 3) are refused on rectangular glass for the same
    // reason CAP_ROTATE is not advertised there: a physical 90-degree turn
    // of those panels is what the sender's landscape mechanism expresses,
    // and a MADCTL quarter turn would fight it. Persisted, and applied on
    // the next drawn frame.
    int want = atoi(line + 7);
    if (want < 0 || want > 3) {
      Serial.println("CFGERR expected: CFGROT 0|1|2|3");
      return;
    }
    if ((want & 1) != 0 && bcfg->panelW != bcfg->panelH) {
      Serial.printf("CFGERR rotation %d needs a square panel (%s is %ux%u); "
                    "only 0 and 2 apply here\n",
                    want, bcfg->name, bcfg->panelW, bcfg->panelH);
      return;
    }
    panelRotation = (uint8_t)want;
    madctlDirty = true;
    saveDisplayPrefs();
    Serial.printf("CFGOK rot=%u (saved; applies with next frame)\n",
                  panelRotation);
  } else if (strncmp(line, "CFGPOWER ", 9) == 0) {
    // Manual on/off without the network path: CFGPOWER 0|1. Mirrors the
    // Power control opcode exactly (same flag, same NVS key, same priority
    // over touch-wake) so a bench test over serial behaves identically to a
    // toggle from the app. Persisted, so it survives a reboot too.
    int want = atoi(line + 9);
    if (want != 0 && want != 1) {
      Serial.println("CFGERR expected: CFGPOWER 0|1");
      return;
    }
    panelManuallyOff = want == 0;
    saveDisplayPrefs();
    applyBacklight();
    Serial.printf("CFGOK pwr=%s (saved)\n", panelManuallyOff ? "off" : "on");
  } else if (strncmp(line, "CFGBOARD ", 9) == 0) {
    // Override C6 board auto-detection. Fixed S3 builds parse every profile
    // token for telemetry round-trips but reject overrides below.
    // The escape hatch for a board whose I2C peripherals do not answer, and the
    // way to undo a wrong forcing ("auto"). Reboots, because the pin map and
    // panel driver are chosen during setup and cannot be swapped underneath a
    // running panel.
    const char *token = line + 9;
    board::Variant want = board::variantFromName(token);
    bool isAuto = strcmp(token, "auto") == 0;
    if (want == board::Variant::Unknown && !isAuto) {
      Serial.println(
          "CFGERR expected: CFGBOARD st7789|jd9853|gc9107|st7789-154|co5300|st77916|auto");
      return;
    }
    if (board::COMPILED_VARIANT != board::Variant::Unknown) {
      // Single-board chips have nothing to override: the variant is a
      // compile-time fact there, and persisting a wrong answer would only
      // manufacture a broken boot.
      Serial.printf("CFGERR board is fixed at compile time on this chip (%s)\n",
                    board::variantToken(board::COMPILED_VARIANT));
      return;
    }
    if (want != board::Variant::Unknown) {
      const board::Config &wantCfg = board::configFor(want);
      if (wantCfg.panelW != PANEL_GEOMETRY.width ||
          wantCfg.panelH != PANEL_GEOMETRY.height) {
        // Buffers, band layout, and the mDNS advertisement in this binary are
        // sized for the compiled resolution; forcing a board with different
        // glass cannot work, so refuse rather than persist a broken boot.
        Serial.printf("CFGERR %s is %ux%u; this binary is built for %ux%u\n",
                      board::variantToken(want), wantCfg.panelW, wantCfg.panelH,
                      PANEL_GEOMETRY.width, PANEL_GEOMETRY.height);
        return;
      }
    }
    Preferences prefs;
    prefs.begin("espdisp", false);
    prefs.putUChar("board", (uint8_t)want);
    prefs.end();
    Serial.printf("CFGOK board=%s, restarting\n", board::variantToken(want));
    Serial.flush();
    delay(200);
    ESP.restart();
  } else if (strncmp(line, "CFGLED ", 7) == 0) {
    // Diagnostic: show a literal color for 10s (CFGLED <r> <g> <b>, 0-255).
    // Lets channel-order problems be diagnosed over serial: send pure red,
    // ask what color appears.
    int r, g, b;
    if (sscanf(line + 7, "%d %d %d", &r, &g, &b) != 3) {
      Serial.println("CFGERR expected: CFGLED <r> <g> <b>");
      return;
    }
    if (rgbLed == nullptr) {
      // Say so rather than accepting silently: on this board the command has
      // nothing to drive, and a bare CFGOK would look like the LED is broken.
      Serial.printf("CFGERR no addressable LED on %s\n", bcfg->name);
      return;
    }
    rgbLed->fill(rgbLed->Color(r & 0xFF, g & 0xFF, b & 0xFF));
    rgbLed->show();
    ledOverrideUntil = millis() + 10000;
    Serial.printf("CFGOK led r=%d g=%d b=%d for 10s\n", r & 0xFF, g & 0xFF, b & 0xFF);
#if defined(CONFIG_IDF_TARGET_ESP32S3)
  } else if (strcmp(line, "CFGBENCH") == 0) {
    // Tile-stream phase-0 measurements; see runTileBench above. Blocks the
    // loop for a few seconds while it runs, which is fine over USB.
    runTileBench();
  } else if (strncmp(line, "CFGTUNE", 7) == 0) {
    // Read or set the tile path's experiment knobs, live:
    //   CFGTUNE                    print the current values
    //   CFGTUNE rxyield <1-256>    datagrams drained between yields
    //   CFGTUNE partialms <1-1000> how long tiles wait for their frame
    //   CFGTUNE drawcap <1-450>    draw calls per loop iteration
    //   CFGTUNE rxprio <1-18>      udpReceiveTask priority (boot: 9)
    //   CFGTUNE loopprio <1-18>    loopTask (draw) priority (boot: 1)
    //
    // The two priority knobs exist for section 17.6 item 3: the draw loop is
    // starved by the receive task (17.2's ~10x per-call inflation under
    // load), and the candidate fixes - lower rx below the draw, or raise the
    // draw to meet it - are scheduling arms that have never been measured.
    // Both are bounded to 1-18: 0 would contend with the idle task that
    // feeds the task watchdog, and 19+ would preempt the WiFi/lwIP tasks
    // (18+) that feed the receive path itself. loopprio uses the calling
    // task's own handle - handleSerialConfig only ever runs on loopTask
    // (setup()'s WiFi wait and loop() are its two call sites).
    //
    // Exists for measurement discipline rather than for users. The run-to-run
    // spread here is ~4 fps peak-to-peak at the operating point (section
    // 17.11), so resolving a smaller effect needs the A/B arms INTERLEAVED
    // over many samples - and at ~2 minutes per reflash, a compiled-in
    // constant makes interleaving so expensive that blocked sampling becomes
    // inevitable. Blocked sampling is what let this project accept a false
    // positive it then had to retract.
    //
    // Deliberately NOT persisted to NVS: a knob left somewhere odd by an
    // abandoned experiment would silently bias every later measurement, and a
    // reboot is the cheapest possible reset. Values are refused rather than
    // clamped, so a typo cannot quietly become a data point.
    const char *arg = line + 7;
    while (*arg == ' ') arg++;
    if (*arg == '\0') {
      // CFGINFO, like CFGSHOW's reply: the tooling only recognises CFGOK,
      // CFGERR and CFGINFO as replies (CFG_PREFIXES in espdisp.py), so a line
      // starting with anything else reads as no answer at all and times out.
      Serial.printf("CFGINFO rxyield=%d partialms=%lu drawcap=%d rxprio=%u "
                    "loopprio=%u\n",
                    tuneRxDrainYieldEvery,
                    (unsigned long)tunePartialDrawMs, tuneDrawCallCap,
                    rxTaskHandle != nullptr
                        ? (unsigned)uxTaskPriorityGet(rxTaskHandle)
                        : 0u,
                    (unsigned)uxTaskPriorityGet(nullptr));
      return;
    }
    char name[16] = {0};
    int value = 0;
    if (sscanf(arg, "%15s %d", name, &value) != 2) {
      Serial.println("CFGERR expected: CFGTUNE "
                     "<rxyield|partialms|drawcap|rxprio|loopprio> <n>");
      return;
    }
    if (strcmp(name, "rxyield") == 0 && value >= 1 && value <= 256) {
      tuneRxDrainYieldEvery = value;
    } else if (strcmp(name, "partialms") == 0 && value >= 1 && value <= 1000) {
      tunePartialDrawMs = (uint32_t)value;
    } else if (strcmp(name, "drawcap") == 0 && value >= 1 && value <= 450) {
      tuneDrawCallCap = value;
    } else if (strcmp(name, "rxprio") == 0 && value >= 1 && value <= 18) {
      // Refused rather than ignored when the transport never started: a
      // silently absorbed knob would bias the measurement it exists for.
      if (rxTaskHandle == nullptr) {
        Serial.println("CFGERR no receive task (transport not started)");
        return;
      }
      vTaskPrioritySet(rxTaskHandle, (UBaseType_t)value);
    } else if (strcmp(name, "loopprio") == 0 && value >= 1 && value <= 18) {
      vTaskPrioritySet(nullptr, (UBaseType_t)value);
    } else {
      Serial.println("CFGERR bad knob or out of range (rxyield 1-256, "
                     "partialms 1-1000, drawcap 1-450, rxprio 1-18, "
                     "loopprio 1-18)");
      return;
    }
    Serial.printf("CFGOK rxyield=%d partialms=%lu drawcap=%d rxprio=%u "
                  "loopprio=%u (not persisted)\n",
                  tuneRxDrainYieldEvery, (unsigned long)tunePartialDrawMs,
                  tuneDrawCallCap,
                  rxTaskHandle != nullptr
                      ? (unsigned)uxTaskPriorityGet(rxTaskHandle)
                      : 0u,
                  (unsigned)uxTaskPriorityGet(nullptr));
  } else if (strncmp(line, "CFGRXCORE ", 10) == 0) {
    // Pin the receive task to core 0 or 1 and restart to apply - task
    // affinity is fixed at creation, so unlike the CFGTUNE knobs this one
    // persists (the CFGBOARD pattern) and takes a reboot. See the comment in
    // startInboundTransport for the hypothesis it exists to test; 1 is the
    // boot default every measurement so far was taken under.
    const char *arg = line + 10;
    while (*arg == ' ') arg++;
    if (strcmp(arg, "0") != 0 && strcmp(arg, "1") != 0) {
      Serial.println("CFGERR expected: CFGRXCORE <0|1>");
      return;
    }
    Preferences prefs;
    prefs.begin("espdisp", false);
    prefs.putUChar("rxcore", (uint8_t)(arg[0] - '0'));
    prefs.end();
    Serial.printf("CFGOK rxcore=%c, restarting\n", arg[0]);
    Serial.flush();
    delay(200);
    ESP.restart();
#endif
  } else if (strncmp(line, "CFGOTAPW ", 9) == 0) {
    // Set or clear the OTA password:
    //   CFGOTAPW <b64 password>  enable OTA with this password
    //   CFGOTAPW clear           forget it, which turns OTA off again
    // Base64 for exactly the reason CFGWIFI uses it - a password may contain
    // any character a shell or a space-delimited line would eat. One byte is
    // still refused, and it is refused rather than mangled: a 0x00 anywhere in
    // the decoded password is rejected below, because NVS, ArduinoOTA and espota
    // all handle it as a C string. "clear" cannot
    // collide with a real payload because it is recognised as a literal BEFORE
    // any decode is attempted, which is a property of the order below rather
    // than of the string (see otapolicy::classifyArgument, which owns and
    // documents that; an earlier comment here claimed five characters can never
    // be valid base64, which is a claim about decoders and not one to rely on).
    //
    // Both forms restart. OTA is brought up during setup and its bit is baked
    // into the mDNS caps TXT record there, so a reboot is the honest way to make
    // the panel's advertisement agree with its state.
    const char *arg = line + 9;
    Preferences prefs;
    if (otapolicy::classifyArgument(arg) == otapolicy::Argument::Clear) {
      prefs.begin("espdisp", false);
      prefs.remove("otapw");
      prefs.end();
      Serial.println("CFGOK ota password cleared (OTA off), restarting");
      Serial.flush();
      delay(200);
      ESP.restart();
      return;
    }
    // Sized so the decode cannot fail for want of room, which keeps "not
    // base64" and "too long" distinguishable: the config line is 256 bytes
    // including its terminator, so the argument is at most 246 characters and
    // decodes to at most 185 bytes. The length policy is then applied to the
    // result rather than being an accident of this buffer's size.
    unsigned char pw[193];
    size_t pwLen = 0;
    const bool decoded = mbedtls_base64_decode(pw, sizeof(pw) - 1, &pwLen,
                                               (const unsigned char *)arg,
                                               strlen(arg)) == 0;
    switch (otapolicy::verifyPassword(decoded, pw, pwLen)) {
      case otapolicy::Verdict::NotBase64:
        Serial.println("CFGERR bad base64 password");
        return;
      case otapolicy::Verdict::EmbeddedNul:
        // Refused rather than stored: putString below would cut the password at
        // that byte, ArduinoOTA's setPassword would hash the same short prefix,
        // and espota cannot pass a 0x00 in argv anyway - so this password can
        // never work end to end, and accepting it would leave the panel
        // listening with a secret shorter than the floor above promises.
        // otapolicy::verifyPassword documents the full chain.
        Serial.println("CFGERR ota password must not contain a 0x00 byte "
                       "(it would be stored truncated; try another)");
        return;
      case otapolicy::Verdict::TooShort:
        // Refused rather than accepted: this one password is the only thing
        // between the LAN and a firmware write, espota can be retried as fast
        // as the panel will answer, and a weak one is worse than no OTA at all.
        Serial.printf("CFGERR ota password must be at least %u bytes "
                      "(or: CFGOTAPW clear)\n",
                      (unsigned)otapolicy::PASSWORD_MIN_BYTES);
        return;
      case otapolicy::Verdict::TooLong:
        Serial.printf("CFGERR ota password must be at most %u bytes\n",
                      (unsigned)otapolicy::PASSWORD_MAX_BYTES);
        return;
      case otapolicy::Verdict::Accept:
        break;
    }
    pw[pwLen] = 0;
    prefs.begin("espdisp", false);
    prefs.putString("otapw", (const char *)pw);
    prefs.end();
    // The length, never the password - not even a prefix of it.
    Serial.printf("CFGOK ota password set (%u bytes), restarting\n",
                  (unsigned)pwLen);
    Serial.flush();
    delay(200);
    ESP.restart();
  } else if (strcmp(line, "CFGSHOW") == 0) {
    // ssid64 first: base64 keeps SSIDs with spaces parseable in a
    // space-delimited line. Plain ssid goes last, for humans on a monitor.
    unsigned char b64[48], name64[48];
    size_t b64Len = 0, name64Len = 0;
    mbedtls_base64_encode(b64, sizeof(b64) - 1, &b64Len,
                          (const unsigned char *)cfgSsid.c_str(), cfgSsid.length());
    b64[b64Len] = 0;
    mbedtls_base64_encode(name64, sizeof(name64) - 1, &name64Len,
                          (const unsigned char *)cfgName.c_str(), cfgName.length());
    name64[name64Len] = 0;
    // ota= is three-valued on purpose: "off" (no password stored), "pending" (a
    // password is stored but the radio was not ready when setup ran, so nothing
    // is listening yet), "on" (listening). Reporting only on/off would make a
    // panel that simply booted without WiFi look misconfigured. The mapping is
    // otapolicy::statusToken, tested on the host.
    // flip= stays (derived: rotation == 2) so anything parsing the old field
    // keeps reading the truth; rot= carries the full quarter-turn value.
    Serial.printf(
        "CFGINFO ssid64=%s name64=%s id=%02x%02x%02x%02x%02x%02x "
        "connected=%d ip=%s rssi=%d flip=%d rot=%u auto=%u effective=%u "
        "motion=%d bl=%s pwr=%s board=%s target=%s bat=%d ota=%s ssid=%s\n",
        (const char *)b64, (const char *)name64,
        deviceId[0], deviceId[1], deviceId[2],
        deviceId[3], deviceId[4], deviceId[5],
        WiFi.status() == WL_CONNECTED,
        WiFi.localIP().toString().c_str(), (int)WiFi.RSSI(),
        panelRotation == 2, panelRotation,
        automaticRotation, effectivePanelRotation(), motionAvailable,
        blIsHigh() ? "high" : "low", panelManuallyOff ? "off" : "on",
        board::variantToken(boardVariant), board::targetToken(boardVariant),
        batteryPercentOrUnknown(),
        otapolicy::statusToken(currentOtaStatus()), cfgSsid.c_str());
  }
  // Anything else on serial is ignored (a monitor typing away is harmless).
}

void handleSerialConfig() {
  static char line[256];
  static size_t lineLen = 0;
  while (Serial.available() > 0) {
    char c = (char)Serial.read();
    if (c == '\n' || c == '\r') {
      if (lineLen > 0) {
        line[lineLen] = 0;
        lineLen = 0;
        processConfigLine(line);
      }
    } else if (lineLen < sizeof(line) - 1) {
      line[lineLen++] = c;
    } else {
      lineLen = 0;  // oversized garbage: reset
    }
  }
}

