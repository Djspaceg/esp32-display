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
#include <esp_attr.h>
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
#include "wifi_supervisor.h"

// Doom remains a developer/profile-gated feature inside supported family images.
#if defined(ESPDISP_DOOM_RUNTIME)
#include <doom_mode.h>
// Quake rides on the Doom runtime on the P4 and S3 images (quake_build.h decides).
#include <quake_mode.h>
#endif

using namespace bandproto;

// The sketch is a set of modules in this folder (see docs/code-structure.md);
// this file keeps only setup() and loop()'s scheduling skeleton. State the
// skeleton reads lives behind these headers.
#include "app_state.h"
#include "audio_engine.h"
#include "audio_test.h"
#include "audio_transport.h"
#include "boot_menu.h"
#include "boot_screen.h"
#include "control_apply.h"
#include "coprocessor_service.h"
#include "display_power.h"
#include "dma_gate.h"
#include "fault_inject.h"
#include "frame_pipeline.h"
#include "input_button.h"
#include "input_map.h"
#include "input_touch.h"
#include "mdns_announce.h"
#include "net_link.h"
#include "orientation.h"
#include "ota_service.h"
#include "stream_update_service.h"
#include "prefs_store.h"
#include "serial_config.h"
#include "serial_out.h"
#include "signal_led.h"
#include "telemetry.h"
#include "ui_screens.h"
#include "wifi_worker.h"
#include "mem_diag.h"

namespace {

constexpr uint32_t WIFI_RESTART_COOKIE = 0x57494649;

struct WifiRestartCookie {
  uint32_t value;
  uint32_t inverse;
};

RTC_NOINIT_ATTR WifiRestartCookie wifiRestartCookie;
wifisupervisor::Supervisor wifiSupervisor;

bool wifiRestartAlreadyAttempted() {
  return wifiRestartCookie.value == WIFI_RESTART_COOKIE &&
         wifiRestartCookie.inverse == ~WIFI_RESTART_COOKIE;
}

void markWifiRestartAttempted() {
  wifiRestartCookie.value = WIFI_RESTART_COOKIE;
  wifiRestartCookie.inverse = ~WIFI_RESTART_COOKIE;
}

void clearWifiRestartAttempted() {
  wifiRestartCookie.value = 0;
  wifiRestartCookie.inverse = 0;
}

}  // namespace

void setup() {
  const uint32_t setupEnteredAtMs = millis();
  // Size the TX ring deliberately, BEFORE begin(), which is the only point it
  // can be changed. Left unset, HWCDC installs a 256-byte ring, and the CFGSHOW
  // identity reply is longer than that: a raw capture showed it cut at exactly
  // byte 256 with the tail and its newline abandoned, which is what made the
  // next telemetry line look spliced onto the reply. serial_line.h now also
  // refuses to hand the transport more than it has room for, so this size
  // governs throughput rather than correctness - but the longest line should
  // still fit in one pass. Kept well clear of serialout::LINE_BYTES.
  Serial.setTxBufferSize(2048);
  Serial.begin(115200);
  serialout::begin();
  // Before anything starts the WiFi or ESP-Hosted link, so the mem line's
  // allocation-failure count covers their buffers.
  memdiag::begin();
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
  // No wait for a USB host here: that is up to 5 s on a board running from a
  // charger, and the boot screen goes first (see below). The core keeps what is
  // printed until then in the TX ring sized above.
  Serial.println("=== display_stream (esp_lcd DMA) ===");
  faultinject::announce();
  Serial.printf("firmware %s (source %s), frame protocol %u, control protocol %u\n",
                FW_VERSION, FW_SOURCE, deviceproto::FRAME_PROTOCOL_VERSION,
                deviceproto::CONTROL_PROTOCOL_VERSION);
  wifiSupervisor.begin(wifiRestartAlreadyAttempted());
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
    // Which stored WAD the boot menu chose (boot_menu.cpp), consumed with the
    // request; none means the bundled doom1.wad. Removed even without a
    // request, so a stale one can never pick a later boot's WAD.
    if (doomPrefs.isKey("doomwad")) {
      if (doomRequested) {
        const String wad = doomPrefs.getString("doomwad", "");
        doom_select_store_wad(wad.c_str());
        Serial.printf("doom: playing %s from the game store\n", wad.c_str());
      }
      doomPrefs.remove("doomwad");
    }
    doomPrefs.end();
  }
#endif
#if defined(ESPDISP_QUAKE_RUNTIME)
  // Quake's one-shot request, consumed as early and for the same reason: a
  // missing pak or a Quake crash comes back up streaming instead of looping.
  bool quakeRequested = false;
  {
    Preferences quakePrefs;
    if (!quakePrefs.begin("espdisp", false)) {
      Serial.println("quake: NVS unavailable; ignoring one-shot request");
    } else {
      if (quakePrefs.getBool("quakeonce", false)) {
        quakeRequested = quakePrefs.remove("quakeonce") &&
                         !quakePrefs.isKey("quakeonce");
        if (!quakeRequested) {
          Serial.println(
              "quake: could not consume one-shot request; staying normal");
        }
      }
      quakePrefs.end();
    }
  }
#endif
  // The boot-menu request a triple press saved, consumed just as early: a
  // menu that crashed must not reopen on every boot.
  const bool bootMenuRequested = takeBootMenuRequest();

  // Load persisted settings before anything is drawn or the radio starts:
  // orientation and brightness must be known for the very first fill, and
  // the device name before WiFi latches its DHCP hostname.
  const WifiCredentialLoadResult wifiLoad = loadEffectiveWifiCredentials(
      WIFI_SSID, WIFI_PASSWORD, cfgSsid, cfgPass);
  const bool ssidFromNvs = wifiLoad.ssidFromNvs;
  wifiCredentialPresetSlot = wifiLoad.activeSlot;
  wifiLegacyMirrorPending = wifiCredentialPresetSlot != 0;
  uint8_t boardOverride = 0;
  {
    Preferences prefs;
    prefs.begin("espdisp", true /* read-only */);
    // Operator override from CFGBOARD, 0 = auto-detect. Only an explicit
    // override is persisted; the auto-detected value deliberately is not. A
    // cached auto-detection would be sticky, and the one misdetection with
    // electrical consequences (a Touch board mistaken for a non-touch one)
    // would then survive every subsequent boot instead of being re-tested.
    boardOverride = prefs.getUChar("board", 0);
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
    panelMirrorX = prefs.getBool("mirrorx", false);
    automaticRotationEnabled = prefs.getBool("autorot", true);
    // A panel a user turned off must stay off across a reboot - the whole
    // point of a standing instruction is that it survives the events that
    // would otherwise clear a transient one.
    panelManuallyOff = prefs.getBool("pwroff", false);
    setBrightnessLevels(
        prefs.getUChar("bllow", BL_LOW),
        prefs.getUChar("blhigh", BL_HIGH),
        prefs.getUChar("blidle", BL_IDLE),
        prefs.getUChar("blsurvey", BL_SURVEY));
    // Migrate the old high/low flag: devices flashed before continuous
    // brightness have "blhigh" and no "bllevel".
    userBlLevel = prefs.getUChar(
        "bllevel", prefs.getBool("blhigh", true) ? BL_HIGH : BL_LOW);
    if (userBlLevel == 0) userBlLevel = BL_HIGH;
    fixedBlLevel = prefs.getUChar("blfixed", 0);
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
  Serial.printf(
      "display prefs: rotation=%u auto=%d mirrorX=%d backlight=%u (%s) "
      "levels=%u/%u/%u/%u fixed=%u\n",
      panelRotation, automaticRotationEnabled, panelMirrorX, userBlLevel,
      blIsHigh() ? "high" : "low", BL_LOW, BL_HIGH, BL_IDLE, BL_SURVEY,
      fixedBlLevel);
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
    boarddetect::darkenUnresolvedBacklight(board::COMPILED_PLATFORM.platform);
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

  // A game boot takes the panel as the game wants it, so its first pixel is
  // already the right way up and lit.
#if defined(ESPDISP_DOOM_RUNTIME)
  const bool doomBoot = doomRequested && board::supportsDoom(boardVariant);
  if (doomRequested && !doomBoot) {
    Serial.printf("doom: profile %s is not eligible; continuing normal boot\n",
                  board::variantToken(boardVariant));
  }
#else
  const bool doomBoot = false;
#endif
#if defined(ESPDISP_QUAKE_RUNTIME)
  const bool quakeBoot =
      !doomBoot && quakeRequested && quakeSupportsBoard(boardVariant);
  if (quakeRequested && !doomBoot && !quakeBoot) {
    Serial.printf("quake: profile %s is not eligible; continuing normal boot\n",
                  board::variantToken(boardVariant));
  }
#else
  const bool quakeBoot = false;
#endif
  if (doomBoot || quakeBoot) {
    panelRotation = 0;
    panelManuallyOff = false;
    displaySleeping = false;
    userBlLevel = BL_HIGH;
    pinMode(bcfg->pinBootButton, INPUT_PULLUP);
  }

  // The boot screen, as early as the hardware allows: the profile (and so the
  // pin map) is known, and nothing else has started - no frame buffers, WiFi,
  // C6 link, mDNS or audio. The backlight stays dark until the first full
  // screen is on the panel, so what lights up is the boot screen rather than
  // whatever the panel's memory held.
  if (bcfg->hasBacklightPin() && !bcfg->isDsi()) {
    pinMode(bcfg->pinBl, OUTPUT);
    driveBrightness(0);
  }
  const uint32_t panelInitStartedAtMs = millis();
  if (!initDisplay()) {
    if (doomBoot || quakeBoot) {
      Serial.println("game: display init failed; restarting normal firmware");
      delay(50);
      ESP.restart();
      return;
    }
    Serial.println("FATAL: display init failed");
    while (true) delay(1000);
  }
  // Panel-command brightness (the AMOLED) ends its init table at full
  // brightness; dark until the screen is drawn.
  driveBrightness(0);
  // Apply the saved rotation up front so even the boot screen lands the right
  // way up - landscape-shaped on rectangular glass mounted at rotation 1 or 3.
  adoptLocalFrameShape();
  applyPanelConfig(bufLandscape);
  const uint32_t bootScreenStartedAtMs = millis();
  bootscreen::show(bootscreen::Stage::Starting);
  // Restores the user's saved level (or keeps a panel the user turned off,
  // off).
  applyBacklight();
  // The time before setup() is the bootloader's and the core's.
  Serial.printf("boot screen: first pixel %lu ms after app start (setup() "
                "entered at %lu ms, panel init %lu ms, drawing %lu ms)\n",
                (unsigned long)millis(), (unsigned long)setupEnteredAtMs,
                (unsigned long)(bootScreenStartedAtMs - panelInitStartedAtMs),
                (unsigned long)(millis() - bootScreenStartedAtMs));

  // Bench logging: wait (bounded) for a USB host to open the port, now that
  // the panel is not waiting on it.
  const unsigned long serialWaitStart = millis();
  while (!Serial && millis() - serialWaitStart < 5000) {
    delay(50);
  }

#if defined(ESPDISP_DOOM_RUNTIME)
  if (doomBoot) {
    // This boot intentionally skips normal frame buffers, WiFi, mDNS, OTA,
    // UDP receive, and loop-task watchdog enrollment.
    // A Doom start failure restarts from inside doom_enter() with its
    // reason on Serial and the panel, so a return is the player leaving.
    doom_enter();
    Serial.println("doom: exited; restarting normal firmware");
    Serial.flush();
    delay(50);
    ESP.restart();
    return;
  }
#endif
#if defined(ESPDISP_QUAKE_RUNTIME)
  if (quakeBoot) {
    // The same isolated boot as Doom's above: no frame buffers, WiFi,
    // mDNS, OTA, UDP receive or loop-task watchdog.
    // Every way out of quake_enter() restarts: the player leaving, or a
    // failure with its reason on Serial and the panel.
    quake_enter();
  }
#endif
  bootscreen::advance(bootscreen::Stage::Preparing);
  if (!initializeFramePipeline()) {
    Serial.println("FATAL: could not initialize runtime frame geometry");
    bootscreen::fail("start failed");
    while (true) delay(1000);
  }
  bufB = (uint8_t *)heap_caps_malloc(frameDrawBytes(), FRAME_BUF_CAPS);
  bufA = (uint8_t *)heap_caps_malloc(frameSourceBytes(), FRAME_SOURCE_BUF_CAPS);
  if (!bufA || !bufB) {
    Serial.printf(
        "FATAL: frame buffer alloc failed frame=%u source_caps=0x%lx "
        "draw_caps=0x%lx free=%u largest_source=%u largest_draw=%u\n",
        (unsigned)frameSourceBytes(), (unsigned long)FRAME_SOURCE_BUF_CAPS,
        (unsigned long)FRAME_BUF_CAPS,
        (unsigned)heap_caps_get_free_size(MALLOC_CAP_8BIT),
        (unsigned)heap_caps_get_largest_free_block(FRAME_SOURCE_BUF_CAPS),
        (unsigned)heap_caps_get_largest_free_block(FRAME_BUF_CAPS));
    bootscreen::fail("memory error");
    while (true) delay(1000);
  }
  memset(bufA, 0, frameSourceBytes());
  Serial.printf("buffers ok, free heap: %lu\n", (unsigned long)ESP.getFreeHeap());
  Serial.printf("board: %s (family=%s profile=%s)\n", bcfg->name,
                board::targetToken(boardVariant),
                board::variantToken(boardVariant));
  Serial.printf("  driver=%s bus=%s %ux%u pclk=%luMHz\n",
                bcfg->panel->driver == board::PanelDriver::St7703    ? "ST7703"
                : bcfg->panel->driver == board::PanelDriver::Jd9365 ? "JD9365"
                : bcfg->panel->driver == board::PanelDriver::Co5300 ? "CO5300"
                : bcfg->panel->driver == board::PanelDriver::St77916 ? "ST77916"
                : bcfg->panel->driver == board::PanelDriver::Gc9107  ? "GC9107"
                : bcfg->panel->driver == board::PanelDriver::St7735  ? "ST7735"
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
    // The 1.9-inch S3 opts into GRB, matching Waveshare's WS2812 demos.
    rgbLed = new Adafruit_NeoPixel(
        RGB_COUNT, bcfg->pinRgbLed,
        (bcfg->rgbLedGrb ? NEO_GRB : NEO_RGB) + NEO_KHZ800);
    rgbLed->begin();
    rgbLed->setBrightness(RGB_LED_BRIGHTNESS);
    updateSignalLed();  // red until WiFi is up
  }

  loadInputMap();
  if (bcfg->hasBootButton() || bcfg->hasEncoder()) {
    initializeButtonInput();
  }

  bootscreen::advance(bootscreen::Stage::Sensors);
  // Touch, before WiFi: the capability bits mDNS advertises depend on whether
  // the controller answered, so this has to be settled before we announce.
  touchCalibration = bcfg->variant == board::Variant::P4_4B
      ? touchmap::GT911_ON_ST7703_4B
      : bcfg->variant == board::Variant::P4_4C
      ? touchmap::GT911_ON_JD9365_4C
      : bcfg->variant == board::Variant::P4_34C
      ? touchmap::GT911_ON_JD9365_34C
      : bcfg->variant == board::Variant::AmoledCo5300
      ? touchmap::CST9217_ON_CO5300
      : bcfg->variant == board::Variant::LcdSt77916
          ? touchmap::CST816_ON_ST77916
          : bcfg->variant == board::Variant::C3_2424S012
              ? touchmap::CST816_ON_C3_2424S012
          : bcfg->variant == board::Variant::ElecrowKnob128
              ? touchmap::CST816_ON_ELECROW_KNOB_128
          : bcfg->variant == board::Variant::LilygoTwatchS3
              ? touchmap::FT6336_ON_TWATCH_S3
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
  boardmotion::dumpState(*bcfg);

  // The boot-mode menu, after the panel, touch, and BOOT input are up and
  // before the radio starts. It returns for streaming, the default and what
  // an untouched countdown chooses; a game restarts through its one-shot
  // flag and is entered by the Doom branch above on the next boot.
  if (runBootMenuIfDue(bootMenuRequested)) {
    bootscreen::redraw();
  }
  // The device name doubles as the DHCP hostname (option 12), so the router
  // lists this board by name instead of "esp32c6-XXXXXX". This MUST precede
  // WiFi.mode(): the core latches the hostname onto the STA netif inside
  // mode() when entering STA, so setting it after has no effect on DHCP.
  WiFi.setHostname(cfgName.c_str());

  if (bcfg->platform->wifi == board::WifiTopology::HostedCoprocessor) {
    bootscreen::advance(bootscreen::Stage::WifiLink);
    Serial.println("WiFi: starting ESP-Hosted link to the carrier C6 coprocessor");
  }
  // Why a join failed, which the timeout line below cannot say: a wrong
  // password (handshake timeout, auth fail) and a network the radio never
  // heard (no AP found) end the same way otherwise. Native radios only; the
  // P4's hosted link is left exactly as it was.
  if (bcfg->platform->wifi == board::WifiTopology::Native) {
    WiFi.onEvent(
        [](WiFiEvent_t, WiFiEventInfo_t info) {
          // The reasons that tell a join apart (esp_wifi_types.h
          // wifi_err_reason_t); anything else is logged by number.
          const uint16_t reason = info.wifi_sta_disconnected.reason;
          const char *name = reason == 2     ? "auth expired"
                             : reason == 8   ? "left (asked to)"
                             : reason == 15  ? "4-way handshake timeout"
                             : reason == 201 ? "no AP found"
                             : reason == 202 ? "auth failed"
                             : reason == 203 ? "assoc failed"
                             : reason == 204 ? "handshake timeout"
                             : reason == 205 ? "connection failed"
                             : reason == 210 ? "no AP with compatible security"
                             : reason == 211 ? "no AP in auth-mode threshold"
                             : reason == 212 ? "no AP in RSSI threshold"
                                             : "other";
          Serial.printf("WiFi: disconnected, reason %u (%s), rssi %d\n",
                        (unsigned)reason, name,
                        (int)info.wifi_sta_disconnected.rssi);
        },
        ARDUINO_EVENT_WIFI_STA_DISCONNECTED);
  }
  WiFi.mode(WIFI_STA);
  WiFi.setAutoReconnect(false);  // the loop owns the bounded retry backoff
  WiFi.setSleep(false);         // latency: don't doze between beacons
  WiFi.begin(cfgSsid.c_str(), cfgPass.c_str());
  // Bounded wait that keeps servicing serial config: with wrong credentials
  // (mistyped, or the board moved to a new network) an unbounded wait would
  // make the device unconfigurable - CFGWIFI over USB must always work.
  uint32_t wifiWaitStart = millis();
  bootscreen::advance(bootscreen::Stage::JoiningWifi);
  while (WiFi.status() != WL_CONNECTED) {
    handleSerialConfig();
    delay(100);
    bootscreen::joining(millis() - wifiWaitStart, 30000);
    if (millis() - wifiWaitStart > 30000) {
      Serial.printf("WiFi connect timeout for \"%s\" - continuing; fix via "
                    "CFGWIFI over USB or wait for auto-reconnect\n",
                    cfgSsid.c_str());
      break;
    }
  }
  if (bcfg->platform->wifi == board::WifiTopology::HostedCoprocessor) {
    coprocessorsvc::probe();
  }
  if (WiFi.status() == WL_CONNECTED) {
    wifiLegacyMirrorPending =
        !mirrorEffectiveWifiToLegacyAfterConnection();
    Serial.printf("WiFi up: %s (dhcp hostname \"%s\")\n",
                  WiFi.localIP().toString().c_str(), WiFi.getHostname());
  }

  bootscreen::advance(bootscreen::Stage::Audio);
  const bool audioTransportReady = audiotransport::start(*bcfg);
  const bool audioEngineReady =
      audioTransportReady && audioengine::start(*bcfg);
  if (audioTransportReady && audioEngineReady) {
    audioAvailable = true;
    Serial.printf(
        "audio: UDP %u ready (version=%u rcvbuf=%d queue=%u "
        "watermarks=%lu/%lu/%lums maxppm=%ld)\n",
        (unsigned)audioproto::UDP_PORT, (unsigned)audioproto::VERSION,
        audiotransport::tuneReceiveBufferBytes,
        (unsigned)audiotransport::QUEUE_DEPTH,
        (unsigned long)audioengine::tuneLowWatermarkMs,
        (unsigned long)audioengine::tuneTargetWatermarkMs,
        (unsigned long)audioengine::tuneHighWatermarkMs,
        (long)audioengine::tuneMaxCorrectionPpm);
  } else {
    audioengine::stop();
    audiotransport::stop();
    Serial.println("audio: disabled for this runtime profile");
  }

  bootscreen::advance(bootscreen::Stage::Services);
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
  const bool wifiUpAtReady = WiFi.status() == WL_CONNECTED;

  // Before the watchdog below: from here on loop() never waits on the WiFi
  // driver itself (see wifi_worker.h).
  if (!wifiworker::start()) {
    Serial.println("WARN: WiFi worker failed to start; RSSI reads unknown");
  }

  if (startInboundTransport()) {
    Serial.printf("UDP listening on %u\n", UDP_PORT);
  } else {
    Serial.println("FATAL: UDP listen failed");
  }

  // Ready, honest about the radio. The WiFi wait above is bounded and falls
  // through on timeout, so saying "ready" unconditionally would tell you the
  // network was fine on a board that never associated (fix with CFGWIFI over
  // USB). Stays up until a stream, the status card or another screen replaces
  // it.
  bootscreen::advance(wifiUpAtReady ? bootscreen::Stage::Ready
                                    : bootscreen::Stage::NoWifi);

  // Arm the status card: if no sender ever appears, the device announces
  // its name/IP/signal in place of the boot screen instead of sitting mute.
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

// 1Hz heartbeat and 2s EINF back to the sender. Its own function because a
// stream-channel update keeps them going: the sender's link supervisor
// reconnects after 10s without a heartbeat, and a reconnect opens a new
// socket the update session is not bound to.
static void serviceSenderTelemetry();

void loop() {
  esp_task_wdt_reset();

  // A stream-channel update owns the loop the way ArduinoOTA's handle() does,
  // except that it returns between chunks so the telemetry above still flows.
  if (streamupdatesvc::service()) {
    serviceSenderTelemetry();
    return;
  }

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
  serviceAudioToneTest();
  applyPendingControl();
  applyPendingInputMap();
  updateIdentify();
  serviceTouch();
  serviceAutoRotation();
  if (!wifiSelectorActive && dmaInFlight == 0) clearInfoBarIfExpired();
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

  serviceWifiSelectorTimeout();

  // Signal-survey refresh: a live meter that only updates on entry is a
  // photograph. Half a second tracks a walk around a room; skipped while
  // DMA is busy rather than gated, because a beat late is fine.
  if (surveyActive && !wifiSelectorActive && dmaInFlight == 0 &&
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

  // DMA-stall monitor: elapsed time cannot prove hardware released a source.
  // Keep ownership intact and report the stall once; subsequent draws fail
  // closed until the completion callback arrives.
  static bool dmaStallReported = false;
  if (dmaInFlight != 0 && millis() - dmaQueuedAt > 500) {
    if (!dmaStallReported) {
      statDrawErrors = statDrawErrors + 1;
      Serial.printf(
          "display: DMA stalled >500ms; ownership retained in_flight=%ld\n",
          (long)dmaInFlight);
      dmaStallReported = true;
    }
  } else if (dmaInFlight == 0) {
    dmaStallReported = false;
  }

  // A missing AP or rejected credential is normal. Keep serial configuration
  // and the status card alive while retrying with a bounded backoff. A stopped
  // WiFi layer or a reconnect command the driver rejects is different, so it
  // retains a one-shot reboot watchdog.
  const wl_status_t wifiStatus = WiFi.status();
  const bool wifiConnected = wifiStatus == WL_CONNECTED;
  static bool wifiWasConnected = wifiConnected;
  const bool wifiConnectionRestored =
      wifisupervisor::connectionRestored(wifiWasConnected, wifiConnected);
  static uint32_t lastWifiMirrorAttempt = 0;
  if (wifiConnectionRestored) {
    wifiLegacyMirrorPending = wifiCredentialPresetSlot != 0;
    restartMdnsService();
    // A board that came up without WiFi and joined later stops saying so.
    if (bootscreen::showing()) bootscreen::advance(bootscreen::Stage::Ready);
  }
  wifiWasConnected = wifiConnected;
  // A join the edge above never saw - between setup's announce and the first
  // loop - leaves the ssid record empty. Checked every 5s, so a failing mDNS
  // restart is retried at that pace rather than every loop. The check reads
  // the WiFi worker's cached SSID, so it never waits on a hosted RPC.
  static uint32_t lastSsidRecordCheck = 0;
  if (wifiConnected && millis() - lastSsidRecordCheck >= 5000) {
    lastSsidRecordCheck = millis();
    if (!mdnsSsidIsCurrent()) restartMdnsService();
  }
  if (wifiConnected && wifiLegacyMirrorPending &&
      (lastWifiMirrorAttempt == 0 ||
       millis() - lastWifiMirrorAttempt >= 5000)) {
    lastWifiMirrorAttempt = millis();
    wifiLegacyMirrorPending =
        !mirrorEffectiveWifiToLegacyAfterConnection();
  }
  if (wifiConnected) {
    // Deferred OTA start. setup()'s WiFi wait is bounded and falls through on
    // timeout, so a panel that associated a moment later would otherwise have no
    // OTA until its next reboot. Cheap to leave here: the call is a flag test
    // once OTA is up, or once it is known to be unconfigured.
    if (startOtaIfConfigured()) {
      addMdnsService();  // caps TXT and _arduino._tcp were announced without OTA
    }
  }
  // Associated but the co-processor has stopped answering (P4): the watchdog
  // reboot used to recover this by accident; the supervisor now restarts once.
  const bool coprocessorSilent = wifiConnected && wifiworker::coprocessorSilent();
  static bool coprocessorSilentReported = false;
  if (coprocessorSilent != coprocessorSilentReported) {
    coprocessorSilentReported = coprocessorSilent;
    Serial.println(coprocessorSilent
                       ? "WiFi co-processor not answering; treating radio as down"
                       : "WiFi co-processor answering again");
  }
  const wifisupervisor::LinkState wifiLinkState =
      coprocessorSilent
          ? wifisupervisor::LinkState::CoprocessorSilent
      : wifiConnected
          ? wifisupervisor::LinkState::Connected
          : wifiStatus == WL_STOPPED || wifiStatus == WL_NO_SHIELD
                ? wifisupervisor::LinkState::RadioUnresponsive
                : wifisupervisor::LinkState::NetworkUnavailable;
  const wifisupervisor::Decision wifiDecision =
      wifiSupervisor.update(millis(), wifiLinkState);
  if (wifiDecision.reconnect) {
    Serial.printf("WiFi down; retrying (next in %lus)\n",
                  (unsigned long)(wifiDecision.nextRetryMs / 1000));
    wifiworker::requestReconnect();
  }
  bool reconnectAccepted = false;
  if (wifiworker::takeReconnectResult(reconnectAccepted)) {
    wifiSupervisor.noteReconnectResult(millis(), reconnectAccepted);
  }
  if (wifiDecision.restart) {
    markWifiRestartAttempted();
    Serial.println(coprocessorSilent
                       ? "WiFi co-processor silent >90s; restarting once"
                       : "WiFi radio unavailable >60s; restarting once");
    Serial.flush();
    delay(100);
    ESP.restart();
    return;
  }

  static uint32_t lastHealthyFrame = 0;
  if (statFramesShown != lastHealthyFrame) {
    lastHealthyFrame = statFramesShown;
    if (wifiSupervisor.noteHealthyFrame()) {
      clearWifiRestartAttempted();
      Serial.println("WiFi recovery watchdog re-armed after a complete frame");
    }
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
  const int idleRssi = wifiworker::rssi();
  if (millis() - lastPacketSeenAt > 120000 && idleRssi != 0 &&
      idleRssi < -85 && millis() - lastIdleReassoc > 120000) {
    lastIdleReassoc = millis();
    Serial.printf("idle+weak link (rssi=%d), re-associating\n", idleRssi);
    wifiworker::requestReassociate();
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
      Serial.printf("link heal: reconnecting WiFi (rssi=%d)\n",
                    wifiworker::rssi());
      wifiworker::requestReassociate();
      healStage = 1;
      healStartedAt = millis();
    } else if (starving && healStage == 1 &&
               millis() - healStartedAt > 30000) {
      if (wifiSupervisor.requestRadioRestart()) {
        markWifiRestartAttempted();
        Serial.println("link heal: reconnect insufficient, restarting once");
        Serial.flush();
        delay(100);
        ESP.restart();
        return;
      }
      Serial.println("link heal: restart already attempted; staying online");
      healStage = 2;
    }
  }

  serviceSenderTelemetry();

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

  // The PWR key (AXP2101 boards only). Its press bits latch in the PMU, so a
  // slow poll misses nothing; 50 ms keeps the log close to the press.
  static uint32_t lastPowerKeyPoll = 0;
  if (millis() - lastPowerKeyPoll >= 50) {
    lastPowerKeyPoll = millis();
    servicePowerKey();
  }

  static uint32_t lastLedUpdate = 0;
  if (millis() - lastLedUpdate >= 2000) {
    lastLedUpdate = millis();
    updateSignalLed();
  }

  static uint32_t lastReport = 0;
  if (millis() - lastReport >= 5000) {
    lastReport = millis();
    // One guard over the whole group so this multi-line report cannot be split
    // by a config reply landing between its lines. Recursive, so the callees
    // below may take it again.
    serialout::LineGuard reportGuard;
    serialout::printfLine(Serial,
                  "frames=%lu dropped=%lu partial=%lu packets=%lu badlen=%lu drawerr=%lu heap=%lu rssi=%d",
                  (unsigned long)statFramesShown, (unsigned long)statFramesDropped,
                  (unsigned long)statFramesPartial, (unsigned long)statPackets,
                  (unsigned long)statBadLen, (unsigned long)statDrawErrors,
                  (unsigned long)ESP.getFreeHeap(), wifiworker::rssi());
    {
      // A separate line, so the status line above stays exactly as the
      // app's and the tools' parsers read it.
      char memLine[192];
      memreport::formatLine(memLine, sizeof(memLine), memdiag::sample());
      serialout::printfLine(Serial, "%s", memLine);
    }
#if defined(CONFIG_IDF_TARGET_ESP32S3)
    reportTileDrawStats();
#endif
    reportMotionDiagnostics();
    reportBatteryLine();
  }
}

static void serviceSenderTelemetry() {
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
}
