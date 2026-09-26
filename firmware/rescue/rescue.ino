// Emergency rescue image, one per family, flashed by `tools/espdisp.py rescue`
// onto a board whose firmware kills its own USB right after boot.
//
// It does as little as possible: detect the board with the shared detector,
// bring up only that board's panel, draw RESCUE with the board's name, and
// keep USB serial alive so a real flash can follow. It never drives the chip's
// USB Serial/JTAG pads (rescue_model.h), reads and writes no NVS, and starts no
// radio. It reads one NVS key, the stored CFGBOARD override, because the real
// firmware flashed next would force that profile again; it shows it on the
// glass and in CFGINFO, and `CFGBOARD auto` removes only that key. Over serial
// it answers CFGSHOW with the identity fields of the stream firmware's
// CFGINFO reply plus cfgboard=.
#include <Arduino.h>
#include <esp_heap_caps.h>
#include <esp_mac.h>
#include <Preferences.h>

#include <board_config.h>
#include <board_detect.h>
#include <display_backend.h>

#include "rescue_model.h"

static const int BAND_ROWS = 16;
static const uint32_t HEARTBEAT_MS = 5000;

static board::Variant variant = board::Variant::Unknown;
static const board::Config *cfg = nullptr;
static rescuemodel::PinPlan pins = {};
static bool bridge = false;
static bool panelUp = false;
static esp_lcd_panel_handle_t panelHandle = nullptr;
static uint8_t storedBoard = 0;
static uint8_t deviceId[6] = {0};
static volatile int32_t dmaInFlight = 0;
static portMUX_TYPE dmaMux = portMUX_INITIALIZER_UNLOCKED;

// Every line goes to USB serial, and to the carrier's UART bridge when it has
// one: on those carriers the USB connector is the bridge.
static void say(const char *format, ...) __attribute__((format(printf, 1, 2)));
static void say(const char *format, ...) {
  char line[256];
  va_list args;
  va_start(args, format);
  vsnprintf(line, sizeof(line), format, args);
  va_end(args);
  Serial.println(line);
#if defined(CONFIG_IDF_TARGET_ESP32S3)
  if (bridge) Serial0.println(line);
#endif
}

static bool IRAM_ATTR onTransDone(esp_lcd_panel_io_handle_t,
                                  esp_lcd_panel_io_event_data_t *, void *) {
  portENTER_CRITICAL_ISR(&dmaMux);
  if (dmaInFlight > 0) dmaInFlight = dmaInFlight - 1;
  portEXIT_CRITICAL_ISR(&dmaMux);
  return false;
}

static bool waitDma() {
  const uint32_t start = millis();
  while (dmaInFlight != 0) {
    if (millis() - start > 500) return false;
    delay(1);
  }
  return true;
}

static const char *storedOverride() {
  return rescuemodel::effectiveOverride(
      storedBoard, board::COMPILED_PLATFORM.platform, board::COMPILED_VARIANT);
}

static bool drawScreen(esp_lcd_panel_handle_t panel) {
  char warning[rescuemodel::MAX_LINE_CHARS + 1] = {};
  if (storedOverride() != nullptr) {
    snprintf(warning, sizeof(warning), "CFGBOARD %s", storedOverride());
  }
  const rescuemodel::Screen screen = rescuemodel::layout(
      cfg->panel->width, cfg->panel->height, cfg->panel->roundDisplay,
      cfg->name, board::variantToken(variant),
      warning[0] != 0 ? warning : nullptr);
  const size_t bandBytes = (size_t)screen.width * BAND_ROWS * 2;
  uint8_t *band = (uint8_t *)heap_caps_malloc(bandBytes, MALLOC_CAP_DMA);
  if (band == nullptr) return false;
  bool ok = true;
  for (int y = 0; ok && y < screen.height; y += BAND_ROWS) {
    const int rows = screen.height - y < BAND_ROWS ? screen.height - y
                                                   : BAND_ROWS;
    rescuemodel::renderBand(screen, y, rows, band);
    portENTER_CRITICAL(&dmaMux);
    dmaInFlight = dmaInFlight + 1;
    portEXIT_CRITICAL(&dmaMux);
    if (boarddisplay::drawBitmap(panel, *cfg, 0, y, screen.width, y + rows,
                                 band) != ESP_OK) {
      portENTER_CRITICAL(&dmaMux);
      dmaInFlight = dmaInFlight - 1;
      portEXIT_CRITICAL(&dmaMux);
      ok = false;
    }
    ok = waitDma() && ok;
  }
  // A band still in flight after a timeout keeps its buffer.
  if (dmaInFlight == 0) heap_caps_free(band);
  return ok;
}

static void bringUpPanel() {
  const size_t bandBytes = (size_t)cfg->panel->width * BAND_ROWS * 2;
  esp_lcd_panel_handle_t panel = nullptr;
  if (!boarddisplay::init(*cfg, SPI2_HOST, bandBytes, onTransDone, nullptr,
                          nullptr, &panel)) {
    say("rescue: panel init failed; serial only");
    return;
  }
  boarddisplay::applyOrientation(panel, *cfg, false, 0);
  if (!drawScreen(panel)) {
    say("rescue: panel draw failed; serial only");
    return;
  }
  panelHandle = panel;
  panelUp = true;
  if (cfg->isDsi() || !cfg->hasBacklightPin()) {
    boarddisplay::setBrightness(panel, *cfg, 200);
  } else if (pins.backlight) {
    pinMode(cfg->pinBl, OUTPUT);
    digitalWrite(cfg->pinBl, cfg->backlightInverted ? LOW : HIGH);
  } else {
    say("rescue: panel %ux%u drawn, but backlight GPIO%d is a USB pin; left "
        "off, so the glass stays dark", cfg->panel->width, cfg->panel->height,
        cfg->pinBl);
    return;
  }
  say("rescue: panel %ux%u shows RESCUE", cfg->panel->width,
      cfg->panel->height);
}

static const char *profileToken() { return board::variantToken(variant); }

static const char *targetToken() { return board::targetToken(variant); }

static void reportIdentity() {
  const char *forced = storedOverride();
  say("CFGINFO id=%02x%02x%02x%02x%02x%02x board=%s profile=%s target=%s "
      "chip=%s partition=%s cfgboard=%s",
      deviceId[0], deviceId[1], deviceId[2], deviceId[3], deviceId[4],
      deviceId[5], profileToken(), profileToken(), targetToken(),
      board::COMPILED_PLATFORM.chipToken,
      board::COMPILED_PLATFORM.partitionToken,
      forced != nullptr ? forced : "auto");
}

static void reportOverride() {
  if (storedOverride() == nullptr) return;
  say("rescue: WARNING stored CFGBOARD %s; the real firmware will force it "
      "again. Send CFGBOARD auto to clear it before flashing.",
      storedOverride());
}

// `CFGBOARD auto` is the stream firmware's own way to undo a forced profile.
// Here it removes only that key and leaves every other setting in NVS alone.
static void clearOverride() {
  Preferences prefs;
  if (!prefs.begin("espdisp", false)) {
    say("CFGERR NVS unavailable; override not cleared");
    return;
  }
  const bool cleared = !prefs.isKey("board") || prefs.remove("board");
  prefs.end();
  if (!cleared) {
    say("CFGERR could not clear the stored CFGBOARD override");
    return;
  }
  storedBoard = 0;
  say("CFGOK board=auto (stored override cleared)");
  if (panelUp && !drawScreen(panelHandle)) say("rescue: panel redraw failed");
}

static void reportStatus() {
  const char *forced = storedOverride();
  say("rescue: board=%s panel=%s cfgboard=%s; waiting for a real flash",
      profileToken(), panelUp ? "on" : "off",
      forced != nullptr ? forced : "auto");
}

void setup() {
  Serial.setTxBufferSize(1024);
  Serial.begin(115200);
#if !defined(CONFIG_IDF_TARGET_ESP32P4)
  // Never block on a host that is not reading.
  Serial.setTxTimeoutMs(0);
#endif
  const uint32_t start = millis();
  while (!Serial && millis() - start < 2000) delay(20);

#if defined(CONFIG_IDF_TARGET_ESP32P4)
  esp_efuse_mac_get_default(deviceId);
#else
  esp_read_mac(deviceId, ESP_MAC_WIFI_STA);
#endif
  say("");
  say("=== espdisp rescue image (%s) ===", board::COMPILED_PLATFORM.chipToken);
  say("rescue: chip=%s rev=%d flash=%uMB", ESP.getChipModel(),
      ESP.getChipRevision(), (unsigned)(ESP.getFlashChipSize() >> 20));
  {
    Preferences prefs;
    if (prefs.begin("espdisp", true)) {
      storedBoard = prefs.getUChar("board", 0);
      prefs.end();
    }
  }

  variant = board::COMPILED_VARIANT != board::Variant::Unknown
                ? board::COMPILED_VARIANT
                : boarddetect::probe(true);
  if (variant == board::Variant::Unknown ||
      !board::variantMatchesPlatform(variant,
                                     board::COMPILED_PLATFORM.platform)) {
    variant = board::Variant::Unknown;
#if defined(CONFIG_IDF_TARGET_ESP32S3)
    // As the stream firmware does while unresolved: also answer on the 1.3
    // carrier's bridge, whose pins are the chip's own UART0 console.
    Serial0.begin(115200, SERIAL_8N1,
                  board::CONFIG_LCD_ST7789_130.pinSerialRx,
                  board::CONFIG_LCD_ST7789_130.pinSerialTx);
    bridge = true;
#endif
    say("rescue: board not identified; no panel, serial only");
    reportOverride();
    reportIdentity();
    return;
  }

  cfg = &board::configFor(variant);
  pins = rescuemodel::planPins(*cfg);
#if defined(CONFIG_IDF_TARGET_ESP32S3)
  if (pins.uartBridge) {
    Serial0.begin(115200, SERIAL_8N1, cfg->pinSerialRx, cfg->pinSerialTx);
    bridge = true;
  }
#endif
  say("rescue: detected %s (%s)", cfg->name, profileToken());
  if (pins.panel) {
    bringUpPanel();
  } else {
    say("rescue: panel wiring uses USB pin GPIO%d; panel left off",
        pins.blockedPin);
  }
  reportOverride();
  reportIdentity();
}

static void serviceSerial(Stream &port, char *line, size_t &length) {
  while (port.available() > 0) {
    const char c = (char)port.read();
    if (c != '\n' && c != '\r') {
      if (length < 63) line[length++] = c;
      continue;
    }
    line[length] = 0;
    if (strcmp(line, "CFGSHOW") == 0) {
      reportIdentity();
    } else if (strcmp(line, "CFGBOARD auto") == 0) {
      clearOverride();
    } else if (strncmp(line, "CFGBOARD ", 9) == 0) {
      say("CFGERR the rescue image only accepts CFGBOARD auto");
    }
    length = 0;
  }
}

void loop() {
  static char usbLine[64];
  static size_t usbLength = 0;
  serviceSerial(Serial, usbLine, usbLength);
#if defined(CONFIG_IDF_TARGET_ESP32S3)
  static char bridgeLine[64];
  static size_t bridgeLength = 0;
  if (bridge) serviceSerial(Serial0, bridgeLine, bridgeLength);
#endif
  static uint32_t lastBeat = 0;
  if (millis() - lastBeat >= HEARTBEAT_MS) {
    lastBeat = millis();
    reportStatus();
  }
  delay(10);
}
