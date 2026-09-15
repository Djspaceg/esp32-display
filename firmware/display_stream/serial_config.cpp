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
#include "serial_config_protocol.h"
#include "signal_led.h"
#include "telemetry.h"
#include "tile_bench.h"
#include "ui_screens.h"
#include "wifi_presets.h"


static Stream *selectedConfigPort = &Serial;
static Stream *replyConfigPort = &Serial;
static Stream *recoveryConfigPort = nullptr;

static Stream &configSerial() {
  return *replyConfigPort;
}

void beginSerialConfig(const board::Config &cfg) {
  recoveryConfigPort = nullptr;
#if defined(CONFIG_IDF_TARGET_ESP32S3)
  if (cfg.serialTransport() == board::SerialTransport::UartBridge &&
      cfg.pinSerialRx != board::NO_PIN && cfg.pinSerialTx != board::NO_PIN) {
    Serial0.begin(115200, SERIAL_8N1, cfg.pinSerialRx, cfg.pinSerialTx);
    selectedConfigPort = &Serial0;
    replyConfigPort = selectedConfigPort;
    return;
  }
#endif
  selectedConfigPort = &Serial;
  replyConfigPort = selectedConfigPort;
}

void beginSerialRecovery() {
#if defined(CONFIG_IDF_TARGET_ESP32S3)
  // The profile is unknown, so keep native CDC active for existing S3 boards
  // and additionally service the 1.3-inch carrier's CH343 UART. Only CFGBOARD
  // is accepted until a profile resolves; no panel or peripheral pin is driven.
  Serial0.begin(115200, SERIAL_8N1,
                board::CONFIG_LCD_ST7789_130.pinSerialRx,
                board::CONFIG_LCD_ST7789_130.pinSerialTx);
  recoveryConfigPort = &Serial0;
  Serial0.println("board: profile unresolved; use CFGBOARD <profile>");
#endif
}
// Serial configuration protocol (USB CDC), so credentials can change
// without reflashing:
//   CFGWIFI <base64 ssid> <base64 password>\n  -> save to NVS, reply
//     CFGOK, reboot onto the new network (empty password = open network)
//   CFGOTAPW <base64 password> | CFGOTAPW clear\n  -> enable/disable OTA
//   CFGSHOW\n  -> CFGINFO ssid=... ip=... rssi=...
// Base64 avoids every quoting hazard SSIDs and passwords can contain.
static void processConfigLine(char *line) {
  if (bcfg == nullptr && strncmp(line, "CFGBOARD ", 9) != 0) {
    configSerial().println(
        "CFGERR profile unresolved; use CFGBOARD <profile> or CFGBOARD auto");
    return;
  }

  const wifipresets::ParsedCommand wifiCommand =
      wifipresets::parseCommand(line);
  if (wifiCommand.kind != wifipresets::CommandKind::Unknown) {
    if (wifiCommand.error != wifipresets::CommandError::None) {
      configSerial().println(
          wifipresets::commandErrorText(wifiCommand.error));
      return;
    }

    char reply[192] = {};
    switch (wifiCommand.kind) {
      case wifipresets::CommandKind::Set: {
        const WifiStoreResult result =
            saveWifiPreset(wifiCommand.slot, wifiCommand.credentials);
        if (result.status != WifiStoreStatus::Ok) {
          wifipresets::formatSaveFailedReply(reply, sizeof(reply),
                                             wifiCommand.slot);
        } else {
          wifipresets::formatSavedReply(
              reply, sizeof(reply), wifiCommand.slot,
              wifiCommand.credentials.ssidLength,
              wifiCommand.credentials.passwordLength > 0, result.activeSlot);
        }
        configSerial().println(reply);
        return;
      }
      case wifipresets::CommandKind::Clear: {
        const WifiStoreResult result = clearWifiPreset(wifiCommand.slot);
        if (result.status != WifiStoreStatus::Ok) {
          wifipresets::formatSaveFailedReply(reply, sizeof(reply),
                                             wifiCommand.slot);
        } else {
          wifipresets::formatClearedReply(reply, sizeof(reply),
                                          wifiCommand.slot, result.activeSlot);
        }
        configSerial().println(reply);
        return;
      }
      case wifipresets::CommandKind::Use: {
        const WifiStoreStatus status = selectWifiPreset(wifiCommand.slot);
        if (status == WifiStoreStatus::Unavailable) {
          wifipresets::formatUnavailableReply(reply, sizeof(reply),
                                              wifiCommand.slot);
          configSerial().println(reply);
          return;
        }
        if (status != WifiStoreStatus::Ok) {
          wifipresets::formatSaveFailedReply(reply, sizeof(reply),
                                             wifiCommand.slot);
          configSerial().println(reply);
          return;
        }
        showInfoBar("SWITCHING");
        wifipresets::formatSelectedReply(reply, sizeof(reply),
                                         wifiCommand.slot);
        configSerial().println(reply);
        configSerial().flush();
        delay(200);
        ESP.restart();
        return;
      }
      case wifipresets::CommandKind::ShowRoster: {
        const bool local =
            bcfg->hasBootButton() || (bcfg->hasTouch() && touchAvailable);
        wifipresets::formatRosterReply(
            reply, sizeof(reply), validWifiPresetMask(),
            activeWifiPresetSlot(), local);
        configSerial().println(reply);
        return;
      }
      case wifipresets::CommandKind::ShowSlot: {
        wifipresets::Credentials credentials;
        if (!loadWifiPreset(wifiCommand.slot, credentials)) {
          wifipresets::formatInvalidSlotReply(reply, sizeof(reply),
                                              wifiCommand.slot);
          configSerial().println(reply);
          return;
        }
        unsigned char ssid64[48];
        size_t ssid64Length = 0;
        if (mbedtls_base64_encode(
                ssid64, sizeof(ssid64) - 1, &ssid64Length, credentials.ssid,
                credentials.ssidLength) != 0) {
          wifipresets::formatInvalidSlotReply(reply, sizeof(reply),
                                              wifiCommand.slot);
          configSerial().println(reply);
          return;
        }
        ssid64[ssid64Length] = 0;
        wifipresets::formatValidSlotReply(
            reply, sizeof(reply), wifiCommand.slot,
            activeWifiPresetSlot() == wifiCommand.slot,
            (const char *)ssid64, credentials.passwordLength > 0);
        configSerial().println(reply);
        return;
      }
      case wifipresets::CommandKind::Unknown:
        break;
    }
  }

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
      configSerial().println("CFGERR bad base64 ssid (max 32 bytes)");
      return;
    }
    ssid[ssidLen] = 0;
    if (ssidLen == 0) {
      configSerial().println("CFGERR empty ssid");
      return;
    }
    if (!keepPassword) {
      if (mbedtls_base64_decode(pass, sizeof(pass) - 1, &passLen,
                                (const unsigned char *)b64Pass, strlen(b64Pass)) != 0) {
        configSerial().println("CFGERR bad base64 password (max 64 bytes)");
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
    prefs.putUChar("wfactive", wifipresets::ACTIVE_DIRECT);
    prefs.end();

    configSerial().printf("CFGOK saved \"%s\"%s, restarting\n", (const char *)ssid,
                  keepPassword ? " (password kept)" : "");
    configSerial().flush();
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
      configSerial().println("CFGERR bad base64");
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
      configSerial().println("CFGERR name has no hostname-safe characters");
      return;
    }
    Preferences prefs;
    prefs.begin("espdisp", false);
    prefs.putString("name", clean);
    prefs.end();
    configSerial().printf("CFGOK name \"%s\", restarting\n", clean);
    configSerial().flush();
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
    configSerial().printf("CFGOK flip180=%d rot=%u (saved; applies with next frame)\n",
                  want != 0, panelRotation);
  } else if (strncmp(line, "CFGROT ", 7) == 0) {
    // Set the mounting rotation in clockwise quarter turns: CFGROT 0|1|2|3.
    // Quarter turns (1 and 3) require a square panel whose backend has passed
    // physical transform validation. Rectangular panels use sender landscape;
    // a backend without validated quarter turns fails closed through its
    // PanelConfig.
    int want = atoi(line + 7);
    if (want < 0 || want > 3) {
      configSerial().println("CFGERR expected: CFGROT 0|1|2|3");
      return;
    }
    if ((want & 1) != 0 &&
        (bcfg->panel->width != bcfg->panel->height ||
         !bcfg->panel->supportsCommandRotation)) {
      configSerial().printf("CFGERR rotation %d unsupported by %s (%ux%u); "
                    "only 0 and 2 apply here\n",
                    want, bcfg->name, bcfg->panel->width,
                    bcfg->panel->height);
      return;
    }
    panelRotation = (uint8_t)want;
    madctlDirty = true;
    saveDisplayPrefs();
    configSerial().printf("CFGOK rot=%u (saved; applies with next frame)\n",
                  panelRotation);
  } else if (strncmp(line, "CFGMIRRORX ", 11) == 0) {
    int want;
    char extra;
    if (sscanf(line + 11, "%d %c", &want, &extra) != 1 ||
        (want != 0 && want != 1)) {
      configSerial().println("CFGERR expected: CFGMIRRORX 0|1");
      return;
    }
    if (bcfg->isDsi()) {
      configSerial().println(
          "CFGERR X-axis mirroring is not supported by this panel backend");
      return;
    }
    panelMirrorX = want != 0;
    madctlDirty = true;
    saveDisplayPrefs();
    configSerial().printf(
        "CFGOK mirrorx=%d (saved; applies with next frame)\n", panelMirrorX);
  } else if (strncmp(line, "CFGFIXEDBL ", 11) == 0) {
    int want;
    char extra;
    if (sscanf(line + 11, "%d %c", &want, &extra) != 1 ||
        want < 0 || want > 255) {
      configSerial().println("CFGERR expected: CFGFIXEDBL 0|1..255");
      return;
    }
    fixedBlLevel = (uint8_t)want;
    saveDisplayPrefs();
    applyBacklight();
    if (fixedBlLevel == 0) {
      configSerial().println(
          "CFGOK blfixed=0 (normal brightness controls restored), restarting");
    } else {
      configSerial().printf(
          "CFGOK blfixed=%u (brightness controls disabled), restarting\n",
          fixedBlLevel);
    }
    configSerial().flush();
    delay(200);
    ESP.restart();
  } else if (strncmp(line, "CFGPOWER ", 9) == 0) {
    // Manual on/off without the network path: CFGPOWER 0|1. Mirrors the
    // Power control opcode exactly (same flag, same NVS key, same priority
    // over touch-wake) so a bench test over serial behaves identically to a
    // toggle from the app. Persisted, so it survives a reboot too.
    int want = atoi(line + 9);
    if (want != 0 && want != 1) {
      configSerial().println("CFGERR expected: CFGPOWER 0|1");
      return;
    }
    panelManuallyOff = want == 0;
    saveDisplayPrefs();
    applyBacklight();
    configSerial().printf("CFGOK pwr=%s (saved)\n", panelManuallyOff ? "off" : "on");
  } else if (serialcfg::hasBrightnessVerb(line)) {
    uint8_t level = 0;
    if (!serialcfg::parseBrightness(line, level)) {
      configSerial().println("CFGERR expected: CFGBRIGHT <1-255>");
      return;
    }
    userBlLevel = level;
    saveDisplayPrefs();
    applyBacklight();
    configSerial().printf("CFGOK bllevel=%u (saved)\n", (unsigned)userBlLevel);
  } else if (strncmp(line, "CFGBOARD ", 9) == 0) {
    // Override C6/S3 board auto-detection. Compile-fixed P4 parses every
    // profile token for telemetry round-trips but rejects overrides below.
    // The escape hatch for a board whose I2C peripherals do not answer, and the
    // way to undo a wrong forcing ("auto"). Reboots, because the pin map and
    // panel driver are chosen during setup and cannot be swapped underneath a
    // running panel.
    const char *token = line + 9;
    board::Variant want = board::variantFromName(token);
    bool isAuto = strcmp(token, "auto") == 0;
    if (want == board::Variant::Unknown && !isAuto) {
      configSerial().println(
          "CFGERR expected: CFGBOARD st7789|jd9853|gc9107|st7789-130|st7789-154|co5300|st77916|auto");
      return;
    }
    if (board::COMPILED_VARIANT != board::Variant::Unknown) {
      configSerial().printf("CFGERR profile is fixed internally for family %s (%s)\n",
                    board::targetToken(board::COMPILED_VARIANT),
                    board::variantToken(board::COMPILED_VARIANT));
      return;
    }
    if (want != board::Variant::Unknown &&
        !board::variantMatchesPlatform(
            want, board::COMPILED_PLATFORM.platform)) {
      configSerial().printf("CFGERR profile %s is not compatible with family %s\n",
                    board::variantToken(want),
                    board::COMPILED_PLATFORM.chipToken);
      return;
    }
    Preferences prefs;
    prefs.begin("espdisp", false);
    prefs.putUChar("board", (uint8_t)want);
    prefs.end();
    configSerial().printf("CFGOK board=%s, restarting\n", board::variantToken(want));
    configSerial().flush();
    delay(200);
    ESP.restart();
  } else if (strncmp(line, "CFGLED ", 7) == 0) {
    // Diagnostic: show a literal color for 10s (CFGLED <r> <g> <b>, 0-255).
    // Lets channel-order problems be diagnosed over serial: send pure red,
    // ask what color appears.
    int r, g, b;
    if (sscanf(line + 7, "%d %d %d", &r, &g, &b) != 3) {
      configSerial().println("CFGERR expected: CFGLED <r> <g> <b>");
      return;
    }
    if (rgbLed == nullptr) {
      // Say so rather than accepting silently: on this board the command has
      // nothing to drive, and a bare CFGOK would look like the LED is broken.
      configSerial().printf("CFGERR no addressable LED on %s\n", bcfg->name);
      return;
    }
    rgbLed->fill(rgbLed->Color(r & 0xFF, g & 0xFF, b & 0xFF));
    rgbLed->show();
    ledOverrideUntil = millis() + 10000;
    configSerial().printf("CFGOK led r=%d g=%d b=%d for 10s\n", r & 0xFF, g & 0xFF, b & 0xFF);
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
      configSerial().printf("CFGINFO rxyield=%d partialms=%lu drawcap=%d rxprio=%u "
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
      configSerial().println("CFGERR expected: CFGTUNE "
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
        configSerial().println("CFGERR no receive task (transport not started)");
        return;
      }
      vTaskPrioritySet(rxTaskHandle, (UBaseType_t)value);
    } else if (strcmp(name, "loopprio") == 0 && value >= 1 && value <= 18) {
      vTaskPrioritySet(nullptr, (UBaseType_t)value);
    } else {
      configSerial().println("CFGERR bad knob or out of range (rxyield 1-256, "
                     "partialms 1-1000, drawcap 1-450, rxprio 1-18, "
                     "loopprio 1-18)");
      return;
    }
    configSerial().printf("CFGOK rxyield=%d partialms=%lu drawcap=%d rxprio=%u "
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
      configSerial().println("CFGERR expected: CFGRXCORE <0|1>");
      return;
    }
    Preferences prefs;
    prefs.begin("espdisp", false);
    prefs.putUChar("rxcore", (uint8_t)(arg[0] - '0'));
    prefs.end();
    configSerial().printf("CFGOK rxcore=%c, restarting\n", arg[0]);
    configSerial().flush();
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
      configSerial().println("CFGOK ota password cleared (OTA off), restarting");
      configSerial().flush();
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
        configSerial().println("CFGERR bad base64 password");
        return;
      case otapolicy::Verdict::EmbeddedNul:
        // Refused rather than stored: putString below would cut the password at
        // that byte, ArduinoOTA's setPassword would hash the same short prefix,
        // and espota cannot pass a 0x00 in argv anyway - so this password can
        // never work end to end, and accepting it would leave the panel
        // listening with a secret shorter than the floor above promises.
        // otapolicy::verifyPassword documents the full chain.
        configSerial().println("CFGERR ota password must not contain a 0x00 byte "
                       "(it would be stored truncated; try another)");
        return;
      case otapolicy::Verdict::TooShort:
        // Refused rather than accepted: this one password is the only thing
        // between the LAN and a firmware write, espota can be retried as fast
        // as the panel will answer, and a weak one is worse than no OTA at all.
        configSerial().printf("CFGERR ota password must be at least %u bytes "
                      "(or: CFGOTAPW clear)\n",
                      (unsigned)otapolicy::PASSWORD_MIN_BYTES);
        return;
      case otapolicy::Verdict::TooLong:
        configSerial().printf("CFGERR ota password must be at most %u bytes\n",
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
    configSerial().printf("CFGOK ota password set (%u bytes), restarting\n",
                  (unsigned)pwLen);
    configSerial().flush();
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
    char extension[64];
    serialcfg::formatShowExtension(
        extension, sizeof(extension), deviceCapabilities(), userBlLevel,
        FW_VERSION);
    // ota= is three-valued on purpose: "off" (no password stored), "pending" (a
    // password is stored but the radio was not ready when setup ran, so nothing
    // is listening yet), "on" (listening). Reporting only on/off would make a
    // panel that simply booted without WiFi look misconfigured. The mapping is
    // otapolicy::statusToken, tested on the host.
    // flip= stays (derived: rotation == 2) so anything parsing the old field
    // keeps reading the truth; rot= carries the full quarter-turn value.
    // The extension appends the same caps bitset EINF and mDNS report, so a USB
    // sender can distinguish installed command support from board identity.
    configSerial().printf(
        "CFGINFO ssid64=%s name64=%s id=%02x%02x%02x%02x%02x%02x "
        // mirrorx= and blfixed= come from the prism/fixed-backlight work;
        // caps=, bllevel= and fw= are appended by formatShowExtension above, so they
        // are deliberately NOT repeated here - a duplicated key in CFGINFO
        // would make the field ambiguous to every parser reading it.
        "connected=%d ip=%s rssi=%d flip=%d rot=%u mirrorx=%d auto=%u "
        "effective=%u motion=%d bl=%s blfixed=%u pwr=%s "
        "board=%s profile=%s target=%s chip=%s partition=%s bat=%d "
        "ota=%s ssid=%s%s\n",
        (const char *)b64, (const char *)name64,
        deviceId[0], deviceId[1], deviceId[2],
        deviceId[3], deviceId[4], deviceId[5],
        WiFi.status() == WL_CONNECTED,
        WiFi.localIP().toString().c_str(), (int)WiFi.RSSI(),
        panelRotation == 2, panelRotation, panelMirrorX,
        automaticRotation, effectivePanelRotation(), motionAvailable,
        blIsHigh() ? "high" : "low", fixedBlLevel,
        panelManuallyOff ? "off" : "on",
        board::variantToken(boardVariant), board::variantToken(boardVariant),
        board::targetToken(boardVariant), bcfg->platform->chipToken,
        bcfg->platform->partitionToken,
        batteryPercentOrUnknown(),
        otapolicy::statusToken(currentOtaStatus()), cfgSsid.c_str(), extension);
  }
  // Anything else on serial is ignored (a monitor typing away is harmless).
}

struct SerialConfigLineState {
  char line[256] = {0};
  size_t length = 0;
};

static void serviceSerialConfigPort(Stream &port, SerialConfigLineState &state) {
  while (port.available() > 0) {
    char c = (char)port.read();
    if (c == '\n' || c == '\r') {
      if (state.length > 0) {
        state.line[state.length] = 0;
        state.length = 0;
        replyConfigPort = &port;
        processConfigLine(state.line);
      }
    } else if (state.length < sizeof(state.line) - 1) {
      state.line[state.length++] = c;
    } else {
      state.length = 0;  // oversized garbage: reset
    }
  }
}

void handleSerialConfig() {
  static SerialConfigLineState selectedState;
  static SerialConfigLineState recoveryState;
  serviceSerialConfigPort(*selectedConfigPort, selectedState);
  if (recoveryConfigPort != nullptr &&
      recoveryConfigPort != selectedConfigPort) {
    serviceSerialConfigPort(*recoveryConfigPort, recoveryState);
  }
  replyConfigPort = selectedConfigPort;
}
