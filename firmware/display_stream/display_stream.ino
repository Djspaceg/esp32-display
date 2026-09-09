// display_stream: UDP RGB565 frame receiver for the supported Waveshare
// ESP32 display boards (see board_config.h for the table).
//
// Pipeline (per docs/esp32-wireless-display-plan.md):
//   Mac sends raw RGB565 frames (big-endian / panel byte order) chunked
//   over UDP. Each packet: [frame_id u16 LE][band_index u16 LE]
//   [dirty_count u16 LE][payload]. Bands reassemble into the back buffer
//   of a double buffer; completed frames are pushed to the panel with
//   esp_lcd's interrupt-driven SPI/QSPI DMA.
//
// Why esp_lcd instead of Arduino_GFX for the push: Arduino_GFX's SPI paths
// busy-wait the CPU for the whole frame transfer. On the C6's single core
// that starves the WiFi/lwIP task and drops most UDP chunks (measured:
// throughput plateaued ~20fps with heavy loss). esp_lcd queues the transfer
// and returns; the CPU services WiFi while the SPI peripheral streams the
// frame, and an ISR callback tells us when the buffer is free.
//
// Frame geometry is a per-binary compile-time fact derived from the board
// table (bandproto::Geometry): bands are whole-row groups sized to the
// packet budget. On the 172x320 C6 panels that is 80 bands of 4 rows
// portrait / 86 of 2 landscape - byte-identical to the original hardcoded
// protocol; on the 466x466 S3 AMOLED it is 466 one-row bands.
//
// Buffer ownership (single writer per buffer at all times):
//   backBuf  - being filled by the UDP callback (lwIP task)
//   readyBuf - complete frame awaiting display (handoff slot)
//   dmaBuf   - currently being read by SPI DMA
// The UDP side only swaps into a buffer that DMA isn't reading; otherwise
// it keeps overwriting its current back buffer (recency over completeness).

#include <Adafruit_NeoPixel.h>
#include <ArduinoOTA.h>
#include <Update.h>
#include <AsyncUDP.h>
#include <ESPmDNS.h>
#include <Preferences.h>
#include <WiFi.h>
#include <esp_mac.h>
#include <esp_task_wdt.h>
#include <mbedtls/base64.h>

// Board table, runtime detection, and the shared panel bring-up. These live in
// firmware/libraries/espdisp_board so display_test builds the panel exactly the
// way this firmware does. panel_init.h pulls in the esp_lcd and SPI headers.
#include <board_config.h>
#include <board_detect.h>
#include <board_motion.h>
#include <board_power.h>
#include <board_touch.h>
#include <motion_orientation.h>
#include <panel_init.h>
#include <touch_gesture.h>
#include <touch_map.h>

#include "wifi_config.h"  // compile-time fallback WIFI_SSID / WIFI_PASSWORD (gitignored)

// Hardware-free and unit tested on the host (firmware/test/run_tests.sh).
// Included here rather than further down because the helpers below use them.
#include "panel_state.h"

// Up here for the same reason, and for one more: the Arduino build generates a
// prototype for every function in this sketch and inserts them all near the top
// of the file. Any function whose signature names a type from one of these
// headers - toWireGesture takes a deviceproto::TouchGesture - gets a prototype
// emitted above the point where the header used to be included, and the sketch
// failed to compile with "'deviceproto' has not been declared".
//
// All of them are header-only, self-contained, and unit tested standalone on the
// host, so nothing in this file has to be declared before them.
#include "band_protocol.h"
#include "band_compress.h"
#include "bc1.h"
#include "tile_protocol.h"
#include "device_protocol.h"
#include "control_queue.h"
#include "ota_policy.h"
#include "chip_identity.h"

// Doom remains a developer/profile-gated feature inside the universal S3 image.
#if defined(ESPDISP_DOOM_RUNTIME)
#include <doom_mode.h>
#endif

using namespace bandproto;

// The sketch is a set of modules in this folder (see docs/code-structure.md);
// this file keeps only setup() and loop()'s scheduling skeleton. State the
// skeleton reads lives behind these headers.
#include "app_state.h"
#include "control_apply.h"
#include "display_power.h"
#include "dma_gate.h"
#include "frame_pipeline.h"
#include "input_button.h"
#include "input_touch.h"
#include "mdns_announce.h"
#include "net_link.h"
#include "orientation.h"
#include "ota_service.h"
#include "prefs_store.h"
#include "serial_config.h"
#include "signal_led.h"
#include "telemetry.h"
#include "ui_screens.h"

void setup() {
  Serial.begin(115200);
  // A host that opens the CDC port but stops draining it would otherwise
  // block every Serial write and hang the whole loop task (observed as
  // total silence + frozen pipeline). Never wait on USB.
#if !defined(CONFIG_IDF_TARGET_ESP32P4)
  // setTxTimeoutMs is not exposed by the P4 UART-bridge Serial type. The SDK
  // availability guard is separate from the platform policy deciding use.
  if (board::COMPILED_PLATFORM.serial == board::SerialTransport::NativeUsbCdc) {
    Serial.setTxTimeoutMs(0);
  }
#endif
  unsigned long start = millis();
  while (!Serial && millis() - start < 5000) {
    delay(50);
  }
  Serial.println("=== display_stream (esp_lcd DMA) ===");
  Serial.printf("firmware %s, frame protocol %u, control protocol %u\n",
                FW_VERSION, deviceproto::FRAME_PROTOCOL_VERSION,
                deviceproto::CONTROL_PROTOCOL_VERSION);
  if (!chipidentity::readDeviceId(deviceId)) {
    Serial.println("FATAL: could not read stable chip identity");
    while (true) delay(1000);
  }

#if defined(ESPDISP_DOOM_RUNTIME)
  // Consume before doing anything fallible so a missing/corrupt WAD or a Doom
  // crash cannot create a reboot loop. Entry is deferred until runtime profile
  // detection has proved this is the CO5300 carrier.
  Preferences doomPrefs;
  bool doomRequested = false;
  if (!doomPrefs.begin("espdisp", false)) {
    Serial.println("doom: NVS unavailable; ignoring one-shot request");
  } else {
    bool requested = doomPrefs.getBool("doomonce", false);
    if (requested) {
      doomRequested = doomPrefs.remove("doomonce") &&
                      !doomPrefs.isKey("doomonce");
      if (!doomRequested) {
        Serial.println("doom: could not consume one-shot request; staying normal");
      }
    }
    doomPrefs.end();
  }
#endif

  // Load persisted settings before anything is drawn or the radio starts:
  // orientation and brightness must be known for the very first fill, and
  // the device name before WiFi latches its DHCP hostname.
  bool ssidFromNvs = false;
  uint8_t boardOverride = 0;
  {
    Preferences prefs;
    prefs.begin("espdisp", true /* read-only */);
    ssidFromNvs = prefs.isKey("ssid");
    // Operator override from CFGBOARD, 0 = auto-detect. Only an explicit
    // override is persisted; the auto-detected value deliberately is not. A
    // cached auto-detection would be sticky, and the one misdetection with
    // electrical consequences (a Touch board mistaken for a non-touch one)
    // would then survive every subsequent boot instead of being re-tested.
    boardOverride = prefs.getUChar("board", 0);
    cfgSsid = prefs.getString("ssid", WIFI_SSID);
    cfgPass = prefs.getString("pass", WIFI_PASSWORD);
    cfgName = prefs.getString("name", "");
    // Physical orientation and brightness are properties of how the board is
    // mounted, so they belong in flash - re-flipping after every reflash is
    // needless. NVS survives sketch uploads (only the app partition is
    // rewritten); a full flash erase does reset them.
    //
    // "rot" (quarter turns 0-3) supersedes the old "flip" bool. A panel
    // flashed before rotation existed has only "flip", so that key is the
    // fallback (flip true -> rot 2) - an upgraded panel keeps its mounting
    // without anyone touching it. saveDisplayPrefs writes "rot" from then on.
    if (prefs.isKey("rot")) {
      panelRotation = (uint8_t)(prefs.getUChar("rot", 0) & 3);
    } else {
      panelRotation = prefs.getBool("flip", false) ? 2 : 0;
    }
    // A panel a user turned off must stay off across a reboot - the whole
    // point of a standing instruction is that it survives the events that
    // would otherwise clear a transient one.
    panelManuallyOff = prefs.getBool("pwroff", false);
    // Migrate the old high/low flag: devices flashed before continuous
    // brightness have "blhigh" and no "bllevel".
    userBlLevel = prefs.getUChar(
        "bllevel", prefs.getBool("blhigh", true) ? BL_HIGH : BL_LOW);
    if (userBlLevel == 0) userBlLevel = BL_HIGH;
    // The screensaver template a sender pushed, restored so a reboot shows
    // the user's own card rather than falling back to the panel's built-in
    // one until the sender happens to reconnect and push again - the whole
    // point of a template being something the user set is that it survives
    // the events that would otherwise clear a transient one (same reasoning
    // as "pwroff" above).
    //
    // idleTextAt is deliberately LEFT AT ITS DEFAULT OF 0, not set to
    // millis(): the panel has no RTC, so a restored template's true age is
    // unknown and could be weeks old, and stamping "now" would claim the
    // sender just pushed it, which is worse than the truth. Left at 0, the
    // "as of" line drawIdleScreen() prints reads as time-since-boot instead -
    // an honest lower bound rather than a fabricated "just now".
    String storedIdleText = prefs.getString("idletxt", "");
    idleText = deviceproto::decodeIdleTextFromStorage(storedIdleText.c_str());
    // What was just read back out IS what NVS already holds, by definition -
    // recording it here is what stops the first periodic check from treating
    // a freshly booted panel's own restored content as a change worth
    // rewriting.
    lastSavedIdleText = idleText;
    // Only whether a password exists, never the password: it is read again, into
    // a local, at the point ArduinoOTA needs it. An empty stored value counts as
    // absent so a blank string can never enable an unpassworded OTA.
    otaConfigured = !prefs.getString("otapw", "").isEmpty();
    prefs.end();
  }
  // Report the actual source, not a value comparison: stored credentials
  // often equal the compiled ones, and claiming "compiled default" then
  // sends you hunting for a config that is in fact saved.
  Serial.printf("WiFi credentials: \"%s\" (%s)\n", cfgSsid.c_str(),
                ssidFromNvs ? "from NVS" : "compiled default");
  Serial.printf("display prefs: rotation=%u backlight=%u (%s)\n", panelRotation,
                userBlLevel, blIsHigh() ? "high" : "low");
  Serial.printf("idle text restored from NVS: %u lines\n",
                (unsigned)idleText.lineCount);

  if (cfgName.isEmpty()) {
    cfgName = defaultDeviceName();
  }

  // Resolve one physical profile before any panel GPIO or frame geometry is
  // configured. A stored CFGBOARD value is accepted only inside this artifact's
  // chip family. Automatic S3 detection requires exactly one candidate; an
  // absent or ambiguous identity stays serial-only so CFGBOARD remains a safe
  // recovery path instead of guessing a pin map.
  if (board::COMPILED_VARIANT != board::Variant::Unknown) {
    boardVariant = board::COMPILED_VARIANT;
  } else {
    const board::Variant forced = board::variantFromStored(boardOverride);
    if (forced != board::Variant::Unknown &&
        board::variantMatchesPlatform(
            forced, board::COMPILED_PLATFORM.platform)) {
      boardVariant = forced;
      Serial.printf("board: forced to %s by CFGBOARD\n",
                    board::variantToken(forced));
    } else {
      if (forced != board::Variant::Unknown) {
        Serial.printf("board: ignoring cross-family CFGBOARD value %s\n",
                      board::variantToken(forced));
      }
      boardVariant = boarddetect::probe();
    }
  }
  if (boardVariant == board::Variant::Unknown) {
    beginSerialRecovery();
    Serial.println("board: FATAL no unique compatible profile; display, network, "
                   "and streaming remain disabled");
    Serial.println("board: use CFGBOARD <profile> over serial to recover");
    while (true) {
      handleSerialConfig();
      delay(20);
    }
  }
  bcfg = &board::configFor(boardVariant);
  beginSerialConfig(*bcfg);
  if (!board::variantMatchesPlatform(
          boardVariant, board::COMPILED_PLATFORM.platform)) {
    Serial.println("board: FATAL resolved profile belongs to another family");
    while (true) {
      handleSerialConfig();
      delay(20);
    }
  }
  configurePanelGeometry(*bcfg);
#if defined(ESPDISP_DOOM_RUNTIME)
  if (doomRequested) {
    if (boardVariant != board::Variant::AmoledCo5300) {
      Serial.printf("doom: profile %s is not eligible; continuing normal boot\n",
                    board::variantToken(boardVariant));
    } else {
      // This boot intentionally skips normal frame buffers, WiFi, mDNS, OTA,
      // UDP receive, and loop-task watchdog enrollment.
      panelRotation = 0;
      panelManuallyOff = false;
      displaySleeping = false;
      userBlLevel = BL_HIGH;
      pinMode(bcfg->pinBootButton, INPUT_PULLUP);
      if (!initDisplay()) {
        Serial.println("doom: display init failed; restarting normal firmware");
        delay(50);
        ESP.restart();
        return;
      }
      applyPanelConfig(false);
      applyBacklight();
      doom_enter();
      Serial.println("doom: exited or unavailable; restarting normal firmware");
      Serial.flush();
      delay(50);
      ESP.restart();
      return;
    }
  }
#endif
  if (!initializeFramePipeline()) {
    Serial.println("FATAL: could not initialize runtime frame geometry");
    while (true) delay(1000);
  }
  bufA = (uint8_t *)heap_caps_malloc(FRAME_BYTES, FRAME_BUF_CAPS);
  bufB = (uint8_t *)heap_caps_malloc(FRAME_BYTES, FRAME_BUF_CAPS);
  if (!bufA || !bufB) {
    Serial.println("FATAL: frame buffer alloc failed");
    while (true) delay(1000);
  }
  memset(bufA, 0, FRAME_BYTES);
  Serial.printf("buffers ok, free heap: %lu\n", (unsigned long)ESP.getFreeHeap());
  Serial.printf("board: %s (family=%s profile=%s)\n", bcfg->name,
                board::targetToken(boardVariant),
                board::variantToken(boardVariant));
  Serial.printf("  driver=%s bus=%s %ux%u pclk=%luMHz\n",
                bcfg->panel->driver == board::PanelDriver::St7703    ? "ST7703"
                : bcfg->panel->driver == board::PanelDriver::Co5300 ? "CO5300"
                : bcfg->panel->driver == board::PanelDriver::St77916 ? "ST77916"
                : bcfg->panel->driver == board::PanelDriver::Gc9107  ? "GC9107"
                : bcfg->panel->driver == board::PanelDriver::Jd9853  ? "JD9853"
                                                                    : "ST7789",
                bcfg->isDsi() ? "mipi-dsi" : (bcfg->isQspi() ? "qspi" : "spi"),
                bcfg->panel->width, bcfg->panel->height,
                (unsigned long)(bcfg->panel->pixelClockHz / 1000000));
  Serial.printf("  sclk=%d d0/mosi=%d d1=%d d2=%d d3=%d cs=%d dc=%d rst=%d bl=%d boot=%d led=%d\n",
                bcfg->pinSclk, bcfg->pinMosi, bcfg->pinData1, bcfg->pinData2,
                bcfg->pinData3, bcfg->pinCs, bcfg->pinDc, bcfg->pinRst,
                bcfg->pinBl, bcfg->pinBootButton, bcfg->pinRgbLed);

  // Only construct the LED driver on a board that has one - begin() drives the
  // pin, and GPIO8 has no known function on the Touch board.
  if (bcfg->hasRgbLed()) {
    // NEO_RGB, not the usual NEO_GRB. This was measured with CFGLED on the C6;
    // the 0.85-inch S3 follows Waveshare's explicit Arduino RGB declaration and
    // still requires physical red/green/blue validation.
    rgbLed = new Adafruit_NeoPixel(RGB_COUNT, bcfg->pinRgbLed,
                                   NEO_RGB + NEO_KHZ800);
    rgbLed->begin();
    rgbLed->setBrightness(RGB_LED_BRIGHTNESS);
    updateSignalLed();  // red until WiFi is up
  }

  if (bcfg->hasBootButton()) {
    pinMode(bcfg->pinBootButton, INPUT_PULLUP);
  }
  if (bcfg->hasBacklightPin() && !bcfg->isDsi()) {
    // A PWM backlight exists independently of the panel, so light it early -
    // the boot status fills are pointless over a dark backlight.
    pinMode(bcfg->pinBl, OUTPUT);
    applyBacklight();
  }
  if (!initDisplay()) {
    Serial.println("FATAL: display init failed");
    while (true) delay(1000);
  }
  // Apply the saved flip up front so even the boot status fills land the
  // right way up, not just streamed frames.
  applyPanelConfig(false);
  // Panel-command brightness (the AMOLED) needs the panel up before it can
  // apply; its init table ends at full brightness, so this restores the
  // user's saved level. A harmless repeat on PWM boards.
  applyBacklight();
  fillPanel(0x2104);  // dark gray: display alive, waiting for WiFi

  // Touch, before WiFi: the capability bits mDNS advertises depend on whether
  // the controller answered, so this has to be settled before we announce.
  touchCalibration = bcfg->variant == board::Variant::P4_4B
      ? touchmap::GT911_ON_ST7703_4B
      : bcfg->variant == board::Variant::AmoledCo5300
      ? touchmap::CST9217_ON_CO5300
      : bcfg->variant == board::Variant::LcdSt77916
          ? touchmap::CST816_ON_ST77916
          : bcfg->variant == board::Variant::TouchSt7789
              ? touchmap::CST816_ON_ST7789_240
              : touchmap::AXS5106L_ON_C6;
  touchAvailable = boardtouch::init(*bcfg);
  // Battery telemetry, for the same reason and before announce: CAP_BATTERY
  // depends on either the AXP2101 PMU or a configured ADC divider being usable.
  // The C6 ADC has no charger-status input; the 0.85-inch S3 has an active-low
  // charge input but still cannot infer external power or standby.
  batteryAvailable = boardpower::init(*bcfg);
  // Motion also precedes mDNS so diagnostics start from a settled hardware
  // verdict. Rectangular C6 panels are read but never automatically rotated;
  // their host raster geometry cannot represent odd firmware-only quadrants.
  motionAvailable = boardmotion::init(*bcfg);
  // The device name doubles as the DHCP hostname (option 12), so the router
  // lists this board by name instead of "esp32c6-XXXXXX". This MUST precede
  // WiFi.mode(): the core latches the hostname onto the STA netif inside
  // mode() when entering STA, so setting it after has no effect on DHCP.
  WiFi.setHostname(cfgName.c_str());

  if (bcfg->platform->wifi == board::WifiTopology::HostedCoprocessor) {
    Serial.println("WiFi: starting ESP-Hosted link to the carrier C6 coprocessor");
  }
  WiFi.mode(WIFI_STA);
  WiFi.setAutoReconnect(true);  // rejoin on AP drop (default, but explicit)
  WiFi.setSleep(false);         // latency: don't doze between beacons
  WiFi.begin(cfgSsid.c_str(), cfgPass.c_str());
  // Bounded wait that keeps servicing serial config: with wrong credentials
  // (mistyped, or the board moved to a new network) an unbounded wait would
  // make the device unconfigurable - CFGWIFI over USB must always work.
  uint32_t wifiWaitStart = millis();
  while (WiFi.status() != WL_CONNECTED) {
    handleSerialConfig();
    delay(100);
    if (millis() - wifiWaitStart > 30000) {
      Serial.printf("WiFi connect timeout for \"%s\" - continuing; fix via "
                    "CFGWIFI over USB or wait for auto-reconnect\n",
                    cfgSsid.c_str());
      break;
    }
  }
  if (WiFi.status() == WL_CONNECTED) {
    Serial.printf("WiFi up: %s (dhcp hostname \"%s\")\n",
                  WiFi.localIP().toString().c_str(), WiFi.getHostname());
  }

  // OTA before the announce, not after, even though ArduinoOTA is the later
  // arrival here: addMdnsService() bakes deviceCapabilities() into the caps TXT
  // record and registers _arduino._tcp, so both would be wrong if OTA came up
  // afterwards. Nothing in ArduinoOTA forces the opposite order - with
  // setMdnsEnabled(false) its begin() only binds a UDP socket, which needs the
  // radio (checked inside) and not mDNS.
  if (otaConfigured) {
    startOtaIfConfigured();
  } else {
    Serial.println("ota: disabled (no password set; enable with CFGOTAPW)");
  }

  if (MDNS.begin(cfgName.c_str())) {
    addMdnsService();
    Serial.printf("mDNS: %s.local, service _espdisp._udp%s\n", cfgName.c_str(),
                  otaActive ? " + _arduino._tcp" : "");
  } else {
    Serial.println("WARN: mDNS failed to start");
  }

  // Ready fill, honest about the radio. The WiFi wait above is bounded and
  // falls through on timeout, so painting "connected" unconditionally told
  // you the network was fine on a board that never associated.
  if (WiFi.status() == WL_CONNECTED) {
    fillPanel(0x0210);  // dark teal: WiFi up, waiting for stream
  } else {
    fillPanel(0x9000);  // dark red: no WiFi - fix with CFGWIFI over USB
  }

  if (startInboundTransport()) {
    Serial.printf("UDP listening on %u\n", UDP_PORT);
  } else {
    Serial.println("FATAL: UDP listen failed");
  }

  // Arm the status card: if no sender ever appears, the device announces
  // its name/IP/signal over the ready fill instead of sitting mute.
  lastSenderPacketAt = millis();

  // Task watchdog on the loop task: any unforeseen hang panics and reboots;
  // the Mac's heartbeat supervision then reconnects automatically. The
  // Arduino core usually pre-initializes the TWDT, so try init then
  // reconfigure to our timeout either way.
  esp_task_wdt_config_t wdtConfig = {};
  wdtConfig.timeout_ms = 10000;
  wdtConfig.idle_core_mask = 0;
  wdtConfig.trigger_panic = true;
  if (esp_task_wdt_init(&wdtConfig) != ESP_OK) {
    esp_task_wdt_reconfigure(&wdtConfig);
  }
  esp_task_wdt_add(NULL);
}

void loop() {
  esp_task_wdt_reset();

  if (otaActive) {
    // An entire update happens inside this one call: handle() runs the transfer
    // to completion, feeding the watchdog from the progress callback, and either
    // reboots (success) or clears otaInProgress (failure) before returning. The
    // guard below is therefore belt and braces - if a future core version ever
    // returns between chunks, nothing beneath it may run: no frame may be drawn
    // over the progress screen, and no DMA may be queued while flash is being
    // written.
    ArduinoOTA.handle();
    if (otaInProgress) {
      return;
    }
  }

  handleButton();
  handleSerialConfig();
  applyPendingControl();
  updateIdentify();
  serviceTouch();
  serviceAutoRotation();
  if (dmaInFlight == 0) clearInfoBarIfExpired();
  static uint32_t lastIdleTextCheck = 0;
  if ((uint32_t)(millis() - lastIdleTextCheck) >= IDLE_TEXT_SAVE_INTERVAL_MS) {
    lastIdleTextCheck = millis();
    saveIdleTextPrefsIfChanged();
  }
  if (restartAt != 0 && (int32_t)(millis() - restartAt) >= 0) {
    Serial.flush();
    delay(50);
    ESP.restart();
  }

  serviceRotationRepaint();

  serviceStreamDraw();

  // Signal-survey refresh: a live meter that only updates on entry is a
  // photograph. Half a second tracks a walk around a room; skipped while
  // DMA is busy rather than gated, because a beat late is fine.
  if (surveyActive && dmaInFlight == 0 &&
      (uint32_t)(millis() - lastSurveyDrawAt) >= 500) {
    drawSurveyScreen();
  }

  // Display sleep: the Mac's screens slept, so stale pixels are pointless -
  // kill the backlight (heat + burn-in). Any drawn frame wakes it above.
  if (sleepRequested) {
    sleepRequested = false;
    if (!displaySleeping) {
      displaySleeping = true;
      idleActive = false;
      applyBacklight();
      Serial.println("display sleeping (ESLP from sender)");
    }
  }
  if (wakeRequested) {
    wakeRequested = false;
    if (displaySleeping || idleActive) {
      displaySleeping = false;
      idleActive = false;
      applyBacklight();
      Serial.println("display awake (EWAK from sender)");
    }
  }

  // Status card: the sender has stopped talking to us entirely (crashed,
  // quit, WiFi down, Mac asleep without telling us). Show where to find
  // this device, dimmed, repositioning against burn-in. Static content is
  // explicitly NOT this state - keepalives keep arriving for a still photo.
  // millisSince, not a plain subtraction: lastSenderPacketAt is written by a
  // higher-priority receive task/callback concurrently with this read, and a
  // packet landing between millis() and reading lastSenderPacketAt below can
  // leave lastSenderPacketAt newer than the millis() already captured. A
  // plain "now - last" then underflows to roughly UINT32_MAX ms - this is
  // exactly what put "sender silent 4294967s" in the serial log while the
  // sender was actively streaming, flashing idleActive on for one loop
  // iteration and off the next. See millisSince's doc comment.
  uint32_t senderSilence = panelstate::millisSince(millis(), lastSenderPacketAt);
  if (!displaySleeping && !surveyActive && dmaInFlight == 0 &&
      lastSenderPacketAt != 0 && senderSilence > SENDER_GONE_MS) {
    if (!idleActive) {
      idleActive = true;
      applyBacklight();
      drawIdleScreen();
      Serial.printf("sender silent %lus - status card on\n",
                    (unsigned long)(senderSilence / 1000));
    } else if (millis() - lastIdleDrawAt > IDLE_REPOSITION_MS) {
      drawIdleScreen();  // new random position, fresh RSSI/IP
    }
  } else if (idleActive && senderSilence < SENDER_GONE_MS) {
    // Sender came back but has no new pixels to send (static content):
    // restore brightness without waiting for a frame.
    idleActive = false;
    applyBacklight();
    Serial.println("sender back - status card off");
  }

  // DMA-stall failsafe: strips take ~14ms worst case at 80MHz. If completion
  // callbacks haven't drained the counter after 500ms, they're lost -
  // reclaim rather than wedge forever.
  if (dmaInFlight != 0 && millis() - dmaQueuedAt > 500) {
    statDrawErrors = statDrawErrors + 1;
    dmaInFlight = 0;
  }

  // WiFi association fully lost for over a minute: autoReconnect isn't
  // getting us back, reboot for a clean radio state.
  static uint32_t wifiDownSince = 0;
  if (WiFi.status() == WL_CONNECTED) {
    wifiDownSince = 0;
    // Deferred OTA start. setup()'s WiFi wait is bounded and falls through on
    // timeout, so a panel that associated a moment later would otherwise have no
    // OTA until its next reboot. Cheap to leave here: the call is a flag test
    // once OTA is up, or once it is known to be unconfigured.
    if (startOtaIfConfigured()) {
      addMdnsService();  // caps TXT and _arduino._tcp were announced without OTA
    }
  } else if (wifiDownSince == 0) {
    wifiDownSince = millis();
  } else if (millis() - wifiDownSince > 60000) {
    Serial.println("WiFi down >60s, restarting");
    Serial.flush();
    delay(100);
    ESP.restart();
  }

  // Silent-but-associated failsafe: the heal below needs packets flowing to
  // detect trouble, but a link can rot so badly that nothing arrives at all
  // (measured: still associated at RSSI -92, multicast/mDNS dead, so the Mac
  // could not even resolve us). Association alone is not health. If nothing
  // has arrived for 2 minutes and the signal is poor, re-associate - it is
  // cheap, and the panel is useless in this state anyway.
  static uint32_t lastPacketSeenAt = 0;
  static uint32_t lastPacketsForIdle = 0;
  static uint32_t lastIdleReassoc = 0;
  if (statPackets != lastPacketsForIdle) {
    lastPacketsForIdle = statPackets;
    lastPacketSeenAt = millis();
  } else if (lastPacketSeenAt == 0) {
    lastPacketSeenAt = millis();
  }
  if (millis() - lastPacketSeenAt > 120000 && WiFi.RSSI() < -85 &&
      millis() - lastIdleReassoc > 120000) {
    lastIdleReassoc = millis();
    Serial.printf("idle+weak link (rssi=%d), re-associating\n", (int)WiFi.RSSI());
    WiFi.disconnect();
    WiFi.reconnect();
  }

  // Link supervisor: if the sender is actively pushing chunks (packets
  // climbing) but no frame has completed in 20s, the WiFi association has
  // rotted (observed: RSSI decayed to -81 and stayed; a fresh association
  // on the same radio read -56 with perfect delivery). Heal in stages:
  // reconnect WiFi first, hard-reboot if that doesn't take - the Mac's
  // heartbeat supervision reconnects automatically either way.
  static uint32_t lastLinkCheck = 0;
  static uint32_t lastShownVal = 0;
  static uint32_t lastShownChangeAt = 0;
  static uint32_t lastPacketsVal = 0;
  static uint8_t healStage = 0;
  static uint32_t healStartedAt = 0;
  if (millis() - lastLinkCheck >= 5000) {
    lastLinkCheck = millis();
    if (statFramesShown != lastShownVal) {
      lastShownVal = statFramesShown;
      lastShownChangeAt = millis();
      if (healStage != 0) {
        Serial.println("link heal: recovered");
        healStage = 0;
      }
    }
    uint32_t packetsDelta = statPackets - lastPacketsVal;
    lastPacketsVal = statPackets;
    // With dirty bands, low steady packet flow is normal for static
    // content; require sustained volume before judging the link rotten.
    // The threshold is two keyframes' worth of bands for this panel's
    // geometry, whatever that geometry is.
    bool starving = packetsDelta > 2u * PANEL_GEOMETRY.maxBandCount() &&
                    millis() - lastShownChangeAt > 20000;
    if (starving && healStage == 0) {
      Serial.printf("link heal: reconnecting WiFi (rssi=%d)\n", (int)WiFi.RSSI());
      WiFi.disconnect();
      WiFi.reconnect();
      healStage = 1;
      healStartedAt = millis();
    } else if (starving && healStage == 1 &&
               millis() - healStartedAt > 30000) {
      Serial.println("link heal: reconnect insufficient, restarting");
      Serial.flush();
      delay(100);
      ESP.restart();
    }
  }

  // After a heal reconnect completes, re-announce mDNS so the Mac's
  // re-resolution finds us. MDNS.end() below is mdns_free(): it drops every
  // registration, OTA's _arduino._tcp included, which is why addMdnsService()
  // owns that registration rather than ArduinoOTA - re-announcing here restores
  // OTA discovery with it. ArduinoOTA's own UDP socket is untouched by any of
  // this, so the listener never stops; only its advertisement would have.
  static bool mdnsRestartPending = false;
  static uint8_t lastHealStage = 0;
  if (healStage == 1 && lastHealStage == 0) {
    mdnsRestartPending = true;
  }
  lastHealStage = healStage;
  if (mdnsRestartPending && WiFi.status() == WL_CONNECTED) {
    mdnsRestartPending = false;
    MDNS.end();
    if (MDNS.begin(cfgName.c_str())) {
      addMdnsService();
      Serial.printf("mDNS re-announced, IP %s\n", WiFi.localIP().toString().c_str());
    }
  }

  // 1Hz heartbeat back to the sender: "EHB1" + 5 x u32 LE stats. Lets the
  // Mac detect blackholing and auto-tune its send pacing from real drops.
  static uint32_t lastHeartbeat = 0;
  if (hbPort != 0 && millis() - lastHeartbeat >= 1000) {
    lastHeartbeat = millis();
    uint8_t pkt[24];
    memcpy(pkt, "EHB1", 4);
    uint32_t vals[5] = {statFramesShown, statFramesDropped, statFramesPartial,
                        statPackets, (uint32_t)ESP.getFreeHeap()};
    for (int i = 0; i < 5; i++) {
      pkt[4 + i * 4] = vals[i] & 0xFF;
      pkt[5 + i * 4] = (vals[i] >> 8) & 0xFF;
      pkt[6 + i * 4] = (vals[i] >> 16) & 0xFF;
      pkt[7 + i * 4] = (vals[i] >> 24) & 0xFF;
    }
    sendToSender(pkt, sizeof(pkt));
  }

  // Versioned capabilities and live state for the manager window. EHB1
  // remains unchanged for compatibility with older senders.
  static uint32_t lastInfo = 0;
  if (hbPort != 0 && millis() - lastInfo >= 2000) {
    lastInfo = millis();
    sendDeviceInfo();
  }

  // Battery, well slower than EINF's 2s. A cell does not move perceptibly in
  // ten seconds, and each sample is either a small PMU read or eight local ADC
  // samples. Unlike the two timers above this is not gated on hbPort: the sample
  // feeds the serial status line and CFGSHOW, which are the only way to read a
  // battery on a panel no sender has found yet. sendBatteryStatus() does the
  // hbPort check itself before it puts anything on the wire, and returns
  // immediately on a board with no battery telemetry source.
  static uint32_t lastBatteryPoll = 0;
  if (millis() - lastBatteryPoll >= 10000) {
    lastBatteryPoll = millis();
    sendBatteryStatus();
  }

  static uint32_t lastLedUpdate = 0;
  if (millis() - lastLedUpdate >= 2000) {
    lastLedUpdate = millis();
    updateSignalLed();
  }

  static uint32_t lastReport = 0;
  if (millis() - lastReport >= 5000) {
    lastReport = millis();
    Serial.printf("frames=%lu dropped=%lu partial=%lu packets=%lu badlen=%lu drawerr=%lu heap=%lu rssi=%d\n",
                  (unsigned long)statFramesShown, (unsigned long)statFramesDropped,
                  (unsigned long)statFramesPartial, (unsigned long)statPackets,
                  (unsigned long)statBadLen, (unsigned long)statDrawErrors,
                  (unsigned long)ESP.getFreeHeap(), (int)WiFi.RSSI());
#if defined(CONFIG_IDF_TARGET_ESP32S3)
    reportTileDrawStats();
#endif
    reportMotionDiagnostics();
    reportBatteryLine();
  }
}
