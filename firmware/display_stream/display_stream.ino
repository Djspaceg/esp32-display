// display_stream: UDP RGB565 frame receiver for Waveshare ESP32-C6-LCD-1.47.
//
// Pipeline (per docs/esp32-wireless-display-plan.md):
//   Mac sends raw RGB565 frames (172x320, big-endian / panel byte order)
//   chunked over UDP. Each packet: [frame_id u16 LE][chunk_index u16 LE]
//   [chunk_count u16 LE][payload]. Chunks reassemble into the back buffer
//   of a double buffer; completed frames are pushed to the ST7789 with
//   esp_lcd's interrupt-driven SPI DMA at 80MHz.
//
// Why esp_lcd instead of Arduino_GFX for the push: Arduino_GFX's SPI paths
// busy-wait the CPU for the whole ~14-24ms frame transfer. On the C6's
// single core that starves the WiFi/lwIP task and drops most UDP chunks
// (measured: throughput plateaued ~20fps with heavy loss). esp_lcd queues
// the transfer and returns; the CPU services WiFi while the SPI peripheral
// streams the frame, and an ISR callback tells us when the buffer is free.
//
// Chunk payload is 1376 bytes = 4 rows (4 * 172 * 2): exactly 80 chunks per
// frame, every packet 1382B, under conservative MTU.
//
// Buffer ownership (single writer per buffer at all times):
//   backBuf  - being filled by the UDP callback (lwIP task)
//   readyBuf - complete frame awaiting display (handoff slot)
//   dmaBuf   - currently being read by SPI DMA
// The UDP side only swaps into a buffer that DMA isn't reading; otherwise
// it keeps overwriting its current back buffer (recency over completeness).

#include <Adafruit_NeoPixel.h>
#include <AsyncUDP.h>
#include <ESPmDNS.h>
#include <Preferences.h>
#include <WiFi.h>
#include <esp_mac.h>
#include <esp_task_wdt.h>
#include <mbedtls/base64.h>

#include <driver/spi_master.h>
#include <esp_lcd_panel_io.h>
#include <esp_lcd_panel_ops.h>
#include <esp_lcd_panel_st7789.h>
#include <esp_lcd_panel_vendor.h>

#include "wifi_config.h"  // compile-time fallback WIFI_SSID / WIFI_PASSWORD (gitignored)

// WiFi credentials live in NVS flash and are reconfigurable over the USB
// serial port without reflashing (see handleSerialConfig). The compiled-in
// wifi_config.h values are only the first-boot fallback.
static String cfgSsid;
static String cfgPass;

// Device name: mDNS hostname + service instance name, so multiple panels
// coexist and the Mac discovers them by browsing _espdisp._udp instead of
// resolving a hardcoded hostname. Default is unique per board
// (espdisplay-XXXX from the MAC); changeable via CFGNAME over USB.
static String cfgName;

// Reads the MAC straight from eFuse rather than via WiFi.macAddress(),
// because the name is needed before WiFi is initialized: the DHCP hostname
// is latched inside WiFi.mode() when entering STA mode.
static String defaultDeviceName() {
  uint8_t mac[6] = {0};
  esp_read_mac(mac, ESP_MAC_WIFI_STA);
  char buf[24];
  snprintf(buf, sizeof(buf), "espdisplay-%02x%02x", mac[4], mac[5]);
  return String(buf);
}

// ---- Display ----------------------------------------------------------
static const int PIN_MOSI = 6;
static const int PIN_SCLK = 7;
static const int PIN_CS = 14;
static const int PIN_DC = 15;
static const int PIN_RST = 21;
static const int PIN_BL = 22;

static const int16_t PANEL_W = 172;
static const int16_t PANEL_H = 320;
static const int COL_OFFSET = 34;  // 172-wide panel centered on 240-wide ST7789 RAM
static const int ROW_OFFSET = 0;
static const uint32_t SPI_HZ = 80000000;

static esp_lcd_panel_handle_t panel = nullptr;

// ---- Onboard RGB LED(s): WiFi signal quality indicator ------------------
// WS2812-style addressable LED(s) on GPIO8, glowing through the board's
// acrylic layer. Driven as a short strip with every pixel the same color:
// data past the real LED count is ignored, so this works whether the board
// has one LED or several.
static const int PIN_RGB = 8;
static const int RGB_COUNT = 8;         // safe upper bound, extras ignored
static const uint8_t RGB_LED_BRIGHTNESS = 28;  // subtle glow, not a lamp
static uint32_t ledOverrideUntil = 0;          // CFGLED diagnostic hold
// NEO_RGB, not the usual NEO_GRB: this board's LED takes red first.
// (Diagnosed with CFGLED - pure red displayed as green under GRB.)
Adafruit_NeoPixel rgbLed(RGB_COUNT, PIN_RGB, NEO_RGB + NEO_KHZ800);

// ---- BOOT button (GPIO9, ESP32-C6 boot strap; plain input after boot) ----
// Short press: toggle backlight high/low. Long press: flip display 180.
static const int PIN_BOOT = 9;
static const uint32_t LONG_PRESS_MS = 600;
static const uint32_t DEBOUNCE_MS = 30;
static const uint8_t BL_HIGH = 128;  // 50%, Waveshare's recommended ceiling
static const uint8_t BL_LOW = 24;    // ~10%
static bool userBlHigh = true;       // user's brightness choice (BOOT short press)

// ---- Idle screen & display sleep ----------------------------------------
// No frames for a while -> overlay device name / IP / signal on the last
// frame at reduced backlight, repositioning periodically to avoid burn-in.
// "ESLP" packet from the Mac (its displays slept) -> backlight fully off;
// any arriving frame wakes both states.
static const uint32_t IDLE_AFTER_MS = 60000;
static const uint32_t IDLE_REPOSITION_MS = 30000;
static const uint8_t BL_IDLE = 10;
static bool idleActive = false;
static uint32_t lastFrameShownAt = 0;
static uint32_t lastIdleDrawAt = 0;
static volatile bool sleepRequested = false;  // set by UDP task on ESLP
static bool displaySleeping = false;

// ---- Protocol (v2: dirty bands) -----------------------------------------
// All wire-format constants and the reassembly/coalescing decision logic
// live in band_protocol.h, which is hardware-free and unit tested on the
// host (firmware/test/run_tests.sh).
#include "band_protocol.h"
using namespace bandproto;

static const uint16_t UDP_PORT = 5568;
static const size_t FRAME_BYTES = (size_t)PANEL_W * PANEL_H * 2;  // 110080

// ---- Buffers -----------------------------------------------------------
// bufA: persistent assembled frame, written by the UDP callback per band.
// bufB: DMA staging - dirty strips are memcpy'd here before queueing, so
//       SPI DMA never reads memory the network path is writing.
static uint8_t *bufA = nullptr;
static uint8_t *bufB = nullptr;

static Reassembler reassembler;                  // tested logic: band_protocol.h
static bool bufLandscape = false;                // orientation of bufA's content

// Bands applied to bufA but not yet drawn. Accumulates across frames so
// bands from an abandoned partial frame still reach the panel with the next
// completed frame. Guarded by drawMux (UDP callback runs in the lwIP task).
static uint8_t pendingDrawBitmap[BITMAP_BYTES];
static portMUX_TYPE drawMux = portMUX_INITIALIZER_UNLOCKED;
static volatile uint32_t framesCompleted = 0;    // completion signal: UDP -> loop
static volatile bool pendingLandscape = false;   // orientation for the pending draw

static bool panelLandscape = false;              // current panel MADCTL state
static bool panelFlip180 = false;                // user flip via BOOT long press
static bool madctlDirty = false;                 // panel config needs reapplying

// Stats.
static volatile uint32_t statFramesShown = 0;
static volatile uint32_t statFramesDropped = 0;  // incomplete, abandoned
static volatile uint32_t statFramesSkipped = 0;  // complete but no free buffer
static volatile uint32_t statPackets = 0;
static volatile uint32_t statBadLen = 0;
static volatile uint32_t statDrawErrors = 0;
static volatile int32_t dmaInFlight = 0;  // queued strip draws not yet completed
static uint32_t dmaQueuedAt = 0;          // for DMA-stall detection

// Reply endpoint: source of the most recent packet from the Mac. Used for
// the 1Hz heartbeat so the sender can detect blackholing (wrong IP after a
// reboot, WiFi drop) and see delivery stats. u32+u16 writes are effectively
// atomic on this 32-bit core.
static volatile uint32_t hbIp = 0;
static volatile uint16_t hbPort = 0;

AsyncUDP udp;

// ISR context: one queued strip transfer finished.
static bool IRAM_ATTR onColorTransDone(esp_lcd_panel_io_handle_t,
                                       esp_lcd_panel_io_event_data_t *, void *) {
  if (dmaInFlight > 0) {
    dmaInFlight = dmaInFlight - 1;
  }
  return false;
}

static void onPacket(AsyncUDPPacket packet) {
  const uint8_t *data = packet.data();
  size_t len = packet.length();

  // Any packet from the sender refreshes the heartbeat reply endpoint.
  hbIp = (uint32_t)packet.remoteIP();
  hbPort = packet.remotePort();

  if (len == 4 && memcmp(data, "EPNG", 4) == 0) {
    return;  // keepalive ping: endpoint refresh only
  }
  if (len == 4 && memcmp(data, "ESLP", 4) == 0) {
    sleepRequested = true;  // Mac's displays slept: loop turns backlight off
    return;
  }
  bandproto::Header h = parseHeader(data);
  if (len != HEADER_BYTES + bandBytes(h.landscape)) {
    statBadLen = statBadLen + 1;
    return;
  }

  bool droppedFrame = false;
  ChunkAction action = reassembler.onChunk(h, droppedFrame);
  if (droppedFrame) {
    // Incomplete frame abandoned - but its bands are already applied to
    // bufA and marked in pendingDrawBitmap, so they still reach the panel
    // with the next completed frame (per-band recency).
    statFramesDropped = statFramesDropped + 1;
  }
  if (action == ChunkAction::Reject) {
    return;  // geometry mismatch - sender misconfigured
  }
  statPackets = statPackets + 1;
  if (action == ChunkAction::IgnoreStale || action == ChunkAction::Duplicate) {
    return;
  }

  // Orientation flip invalidates everything in bufA (band geometry and
  // pixel layout both change). The sender guarantees a full keyframe on
  // flip, so dropping stale pending bands is safe.
  if (h.landscape != bufLandscape) {
    portENTER_CRITICAL(&drawMux);
    memset(pendingDrawBitmap, 0, sizeof(pendingDrawBitmap));
    portEXIT_CRITICAL(&drawMux);
    bufLandscape = h.landscape;
  }

  memcpy(bufA + (size_t)h.bandIndex * bandBytes(h.landscape),
         data + HEADER_BYTES, bandBytes(h.landscape));
  portENTER_CRITICAL(&drawMux);
  pendingDrawBitmap[h.bandIndex >> 3] |= 1 << (h.bandIndex & 7);
  portEXIT_CRITICAL(&drawMux);

  if (action == ChunkAction::ApplyComplete) {
    pendingLandscape = h.landscape;
    framesCompleted = framesCompleted + 1;  // loop draws the pending bands
  }
}

static bool initDisplay() {
  spi_bus_config_t buscfg = {};
  buscfg.mosi_io_num = PIN_MOSI;
  buscfg.miso_io_num = -1;
  buscfg.sclk_io_num = PIN_SCLK;
  buscfg.quadwp_io_num = -1;
  buscfg.quadhd_io_num = -1;
  buscfg.max_transfer_sz = (int)FRAME_BYTES;
  if (spi_bus_initialize(SPI2_HOST, &buscfg, SPI_DMA_CH_AUTO) != ESP_OK) {
    return false;
  }

  esp_lcd_panel_io_spi_config_t io_config = {};
  io_config.cs_gpio_num = PIN_CS;
  io_config.dc_gpio_num = PIN_DC;
  io_config.spi_mode = 0;
  io_config.pclk_hz = SPI_HZ;
  io_config.trans_queue_depth = 2;
  io_config.on_color_trans_done = onColorTransDone;
  io_config.user_ctx = nullptr;
  io_config.lcd_cmd_bits = 8;
  io_config.lcd_param_bits = 8;

  esp_lcd_panel_io_handle_t io = nullptr;
  if (esp_lcd_new_panel_io_spi((esp_lcd_spi_bus_handle_t)SPI2_HOST, &io_config,
                               &io) != ESP_OK) {
    return false;
  }

  esp_lcd_panel_dev_config_t panel_config = {};
  panel_config.reset_gpio_num = PIN_RST;
  panel_config.rgb_ele_order = LCD_RGB_ELEMENT_ORDER_RGB;
  panel_config.data_endian = LCD_RGB_DATA_ENDIAN_BIG;  // buffer arrives panel-ready
  panel_config.bits_per_pixel = 16;
  if (esp_lcd_new_panel_st7789(io, &panel_config, &panel) != ESP_OK) {
    return false;
  }

  esp_lcd_panel_reset(panel);
  esp_lcd_panel_init(panel);
  esp_lcd_panel_invert_color(panel, true);  // IPS panel
  esp_lcd_panel_set_gap(panel, COL_OFFSET, ROW_OFFSET);
  esp_lcd_panel_disp_on_off(panel, true);
  return true;
}

// Apply orientation + user flip to the panel. MADCTL affects how incoming
// pixel writes are addressed (not the scan-out), so the change becomes
// visible on the next drawn frame.
//   portrait:  MADCTL 0        flipped: MX|MY
//   landscape: MV|MX           flipped: MV|MY
// The 34px centering gap sits on the physical-column axis (172px), which is
// symmetric in the 240-wide RAM, so gaps are unaffected by mirroring.
static void applyPanelConfig(bool landscape) {
  bool mx = landscape ? !panelFlip180 : panelFlip180;
  bool my = panelFlip180;
  esp_lcd_panel_swap_xy(panel, landscape);
  esp_lcd_panel_mirror(panel, mx, my);
  esp_lcd_panel_set_gap(panel, landscape ? 0 : COL_OFFSET,
                        landscape ? COL_OFFSET : 0);
  panelLandscape = landscape;
  madctlDirty = false;
}

// Serial configuration protocol (USB CDC), so credentials can change
// without reflashing:
//   CFGWIFI <base64 ssid> <base64 password>\n  -> save to NVS, reply
//     CFGOK, reboot onto the new network (empty password = open network)
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
  } else if (strncmp(line, "CFGLED ", 7) == 0) {
    // Diagnostic: show a literal color for 10s (CFGLED <r> <g> <b>, 0-255).
    // Lets channel-order problems be diagnosed over serial: send pure red,
    // ask what color appears.
    int r, g, b;
    if (sscanf(line + 7, "%d %d %d", &r, &g, &b) != 3) {
      Serial.println("CFGERR expected: CFGLED <r> <g> <b>");
      return;
    }
    rgbLed.fill(rgbLed.Color(r & 0xFF, g & 0xFF, b & 0xFF));
    rgbLed.show();
    ledOverrideUntil = millis() + 10000;
    Serial.printf("CFGOK led r=%d g=%d b=%d for 10s\n", r & 0xFF, g & 0xFF, b & 0xFF);
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
    Serial.printf("CFGINFO ssid64=%s name64=%s connected=%d ip=%s rssi=%d ssid=%s\n",
                  (const char *)b64, (const char *)name64,
                  WiFi.status() == WL_CONNECTED,
                  WiFi.localIP().toString().c_str(), (int)WiFi.RSSI(),
                  cfgSsid.c_str());
  }
  // Anything else on serial is ignored (a monitor typing away is harmless).
}

static void handleSerialConfig() {
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

#include "font5x7.h"  // classic 5x7 ASCII font (Adafruit GFX, BSD license)

// Draw scaled 5x7 text into an RGB565 big-endian buffer of bufW x bufH.
static void drawText(uint8_t *buf, int bufW, int bufH, int x, int y,
                     const char *s, uint16_t color, int scale) {
  for (; *s; s++) {
    for (int col = 0; col < 5; col++) {
      uint8_t bits = font[(size_t)(unsigned char)*s * 5 + col];
      for (int row = 0; row < 7; row++) {
        if (!(bits & (1 << row))) {
          continue;
        }
        for (int sy = 0; sy < scale; sy++) {
          for (int sx = 0; sx < scale; sx++) {
            int px = x + col * scale + sx;
            int py = y + row * scale + sy;
            if (px < 0 || py < 0 || px >= bufW || py >= bufH) {
              continue;
            }
            size_t off = ((size_t)py * bufW + px) * 2;
            buf[off] = color >> 8;
            buf[off + 1] = color & 0xFF;
          }
        }
      }
    }
    x += 6 * scale;
  }
}

// White text with a 1px black outline so it reads over any frame content.
static void drawOutlinedText(uint8_t *buf, int bufW, int bufH, int x, int y,
                             const char *s, int scale) {
  for (int dy = -1; dy <= 1; dy++) {
    for (int dx = -1; dx <= 1; dx++) {
      if (dx || dy) {
        drawText(buf, bufW, bufH, x + dx, y + dy, s, 0x0000, scale);
      }
    }
  }
  drawText(buf, bufW, bufH, x, y, s, 0xFFFF, scale);
}

// Compose the idle card over the (pristine) last frame in bufA and push it.
// Text position moves on every draw to avoid burn-in.
static void drawIdleScreen() {
  int w = bufLandscape ? PANEL_H : PANEL_W;
  int hgt = bufLandscape ? PANEL_W : PANEL_H;

  char lineIp[24], lineWifi[24];
  const char *lineName = cfgName.c_str();
  snprintf(lineIp, sizeof(lineIp), "%s", WiFi.localIP().toString().c_str());
  if (WiFi.status() == WL_CONNECTED) {
    snprintf(lineWifi, sizeof(lineWifi), "wifi %d dBm", (int)WiFi.RSSI());
  } else {
    snprintf(lineWifi, sizeof(lineWifi), "wifi down");
  }
  const char *lines[3] = {lineName, lineIp, lineWifi};

  const int scale = 2;
  const int lineH = 9 * scale;  // 7px glyph + spacing
  size_t maxLen = 0;
  for (int i = 0; i < 3; i++) {
    size_t n = strlen(lines[i]);
    if (n > maxLen) maxLen = n;
  }
  int blockW = (int)maxLen * 6 * scale;
  int blockH = 3 * lineH;

  // Pseudo-random position within margins; esp_random is hardware RNG.
  int maxX = w - blockW - 4;
  int maxY = hgt - blockH - 4;
  int x = 4 + (maxX > 4 ? (int)(esp_random() % (uint32_t)(maxX - 3)) : 0);
  int y = 4 + (maxY > 4 ? (int)(esp_random() % (uint32_t)(maxY - 3)) : 0);

  memcpy(bufB, bufA, FRAME_BYTES);  // bufA stays pristine for the overlay
  for (int i = 0; i < 3; i++) {
    drawOutlinedText(bufB, w, hgt, x, y + i * lineH, lines[i], scale);
  }

  dmaInFlight = dmaInFlight + 1;
  dmaQueuedAt = millis();
  if (esp_lcd_panel_draw_bitmap(panel, 0, 0, w, hgt, bufB) != ESP_OK) {
    statDrawErrors = statDrawErrors + 1;
    dmaInFlight = dmaInFlight - 1;
  }
  lastIdleDrawAt = millis();
}

// WiFi signal quality on the RGB LED(s): green is strong, fading through
// yellow and orange to red as RSSI drops; red also means disconnected.
//   >= -55 dBm  green      solid, excellent
//   -55..-90    gradient   green -> yellow -> orange -> red
//   down / < -90  red
static void updateSignalLed() {
  if (millis() < ledOverrideUntil) {
    return;  // a CFGLED test color is being shown
  }
  uint8_t r, g;
  if (WiFi.status() != WL_CONNECTED) {
    r = 255;
    g = 0;
  } else {
    // Smooth with an EMA: instantaneous RSSI jitters a few dB between
    // reads, which made the color visibly flicker at the band edges.
    static float rssiAvg = 0;
    int rssi = WiFi.RSSI();
    rssiAvg = (rssiAvg == 0) ? rssi : rssiAvg * 0.7f + rssi * 0.3f;
    float clamped = rssiAvg;
    if (clamped > -55) clamped = -55;
    if (clamped < -90) clamped = -90;
    // 0.0 at -90 (red) .. 1.0 at -55 (green)
    float t = (clamped + 90) / 35.0f;
    r = (uint8_t)(255 * (1.0f - t));
    g = (uint8_t)(255 * t);
  }
  rgbLed.fill(rgbLed.Color(r, g, 0));
  rgbLed.show();
}

// Poll the BOOT button: short press toggles backlight, long press (fires
// while still held) flips the display 180 degrees.
static void handleButton() {
  static bool wasDown = false;
  static bool longFired = false;
  static uint32_t downAt = 0;

  bool down = digitalRead(PIN_BOOT) == LOW;
  uint32_t now = millis();

  if (down && !wasDown) {
    wasDown = true;
    longFired = false;
    downAt = now;
  } else if (down && wasDown && !longFired && now - downAt >= LONG_PRESS_MS) {
    longFired = true;
    panelFlip180 = !panelFlip180;
    madctlDirty = true;
    Serial.printf("button: long press -> flip180=%d\n", panelFlip180);
  } else if (!down && wasDown) {
    wasDown = false;
    if (!longFired && now - downAt >= DEBOUNCE_MS) {
      userBlHigh = !userBlHigh;
      analogWrite(PIN_BL, userBlHigh ? BL_HIGH : BL_LOW);
      Serial.printf("button: short press -> backlight %s\n", userBlHigh ? "high" : "low");
    }
  }
}

// Fill the whole panel with one RGB565 color (used for status feedback).
// Draws from staging (bufB) - bufA belongs to the network path.
static void fillPanel(uint16_t rgb565) {
  uint8_t hi = rgb565 >> 8, lo = rgb565 & 0xFF;
  for (size_t i = 0; i < FRAME_BYTES; i += 2) {
    bufB[i] = hi;
    bufB[i + 1] = lo;
  }
  dmaInFlight = dmaInFlight + 1;  // its completion fires onColorTransDone
  if (esp_lcd_panel_draw_bitmap(panel, 0, 0, PANEL_W, PANEL_H, bufB) != ESP_OK) {
    dmaInFlight = dmaInFlight - 1;
  }
  delay(30);  // let DMA finish before bufB is reused
}

void setup() {
  Serial.begin(115200);
  // A host that opens the CDC port but stops draining it would otherwise
  // block every Serial write and hang the whole loop task (observed as
  // total silence + frozen pipeline). Never wait on USB.
  Serial.setTxTimeoutMs(0);
  unsigned long start = millis();
  while (!Serial && millis() - start < 5000) {
    delay(50);
  }
  Serial.println("=== display_stream (esp_lcd DMA) ===");

  bufA = (uint8_t *)heap_caps_malloc(FRAME_BYTES, MALLOC_CAP_DMA);
  bufB = (uint8_t *)heap_caps_malloc(FRAME_BYTES, MALLOC_CAP_DMA);
  if (!bufA || !bufB) {
    Serial.println("FATAL: frame buffer alloc failed");
    while (true) delay(1000);
  }
  // Undelivered bands must show black, not heap garbage.
  memset(bufA, 0, FRAME_BYTES);
  Serial.printf("buffers ok, free heap: %lu\n", (unsigned long)ESP.getFreeHeap());

  rgbLed.begin();
  rgbLed.setBrightness(RGB_LED_BRIGHTNESS);
  updateSignalLed();  // red until WiFi is up

  pinMode(PIN_BOOT, INPUT_PULLUP);
  pinMode(PIN_BL, OUTPUT);
  analogWrite(PIN_BL, BL_HIGH);  // 50% cap per Waveshare guidance
  if (!initDisplay()) {
    Serial.println("FATAL: display init failed");
    while (true) delay(1000);
  }
  fillPanel(0x2104);  // dark gray: display alive, waiting for WiFi

  bool ssidFromNvs = false;
  {
    Preferences prefs;
    prefs.begin("espdisp", true /* read-only */);
    ssidFromNvs = prefs.isKey("ssid");
    cfgSsid = prefs.getString("ssid", WIFI_SSID);
    cfgPass = prefs.getString("pass", WIFI_PASSWORD);
    cfgName = prefs.getString("name", "");
    prefs.end();
  }
  // Report the actual source, not a value comparison: stored credentials
  // often equal the compiled ones, and claiming "compiled default" then
  // sends you hunting for a config that is in fact saved.
  Serial.printf("WiFi credentials: \"%s\" (%s)\n", cfgSsid.c_str(),
                ssidFromNvs ? "from NVS" : "compiled default");

  if (cfgName.isEmpty()) {
    cfgName = defaultDeviceName();
  }
  // The device name doubles as the DHCP hostname (option 12), so the router
  // lists this board by name instead of "esp32c6-XXXXXX". This MUST precede
  // WiFi.mode(): the core latches the hostname onto the STA netif inside
  // mode() when entering STA, so setting it after has no effect on DHCP.
  WiFi.setHostname(cfgName.c_str());

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

  if (MDNS.begin(cfgName.c_str())) {
    MDNS.setInstanceName(cfgName);
    MDNS.addService("espdisp", "udp", UDP_PORT);
    MDNS.addServiceTxt("espdisp", "udp", "name", cfgName);
    MDNS.addServiceTxt("espdisp", "udp", "res", "172x320");
    Serial.printf("mDNS: %s.local, service _espdisp._udp\n", cfgName.c_str());
  } else {
    Serial.println("WARN: mDNS failed to start");
  }

  fillPanel(0x0210);  // dark teal: WiFi up, waiting for stream

  if (udp.listen(UDP_PORT)) {
    udp.onPacket(onPacket);
    Serial.printf("UDP listening on %u\n", UDP_PORT);
  } else {
    Serial.println("FATAL: UDP listen failed");
  }

  // Arm the idle screen: if no stream arrives, the device announces its
  // name/IP/signal over the ready fill instead of sitting mute.
  lastFrameShownAt = millis();

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
  handleButton();
  handleSerialConfig();

  static uint32_t lastCompleted = 0;
  if (framesCompleted != lastCompleted && dmaInFlight == 0) {
    lastCompleted = framesCompleted;

    // Snapshot-and-clear the pending set; the UDP task keeps marking bands
    // for the next frame while we draw this one.
    uint8_t bands[BITMAP_BYTES];
    portENTER_CRITICAL(&drawMux);
    memcpy(bands, pendingDrawBitmap, sizeof(bands));
    memset(pendingDrawBitmap, 0, sizeof(pendingDrawBitmap));
    bool landscape = pendingLandscape;
    portEXIT_CRITICAL(&drawMux);

    if (landscape != panelLandscape || madctlDirty) {
      applyPanelConfig(landscape);
    }

    int drawWidth = landscape ? PANEL_H : PANEL_W;
    size_t bandLen = bandBytes(landscape);
    int bandRows = rowsPerBand(landscape);

    // Coalesce runs of contiguous dirty bands into single DMA transfers.
    // Contiguous bands are contiguous in memory, so a run needs just one
    // memcpy to staging and one draw_bitmap. Staging (bufB) keeps DMA reads
    // off the buffer the network task writes.
    bool drewAny = false;
    forEachRun(bands, bandCount(landscape), [&](int runStart, int runEnd) {
      size_t off = (size_t)runStart * bandLen;
      size_t bytes = (size_t)(runEnd - runStart) * bandLen;
      memcpy(bufB + off, bufA + off, bytes);
      dmaInFlight = dmaInFlight + 1;
      dmaQueuedAt = millis();
      // Queues async; blocks briefly only if the 2-deep transaction queue
      // is full. A failed queue never fires the completion callback, so
      // roll the counter back to avoid a permanent wedge.
      esp_err_t err = esp_lcd_panel_draw_bitmap(
          panel, 0, runStart * bandRows, drawWidth, runEnd * bandRows,
          bufB + off);
      if (err != ESP_OK) {
        statDrawErrors = statDrawErrors + 1;
        dmaInFlight = dmaInFlight - 1;
      } else {
        drewAny = true;
      }
    });
    if (drewAny) {
      statFramesShown = statFramesShown + 1;
      lastFrameShownAt = millis();
      if (idleActive || displaySleeping) {
        idleActive = false;
        displaySleeping = false;
        analogWrite(PIN_BL, userBlHigh ? BL_HIGH : BL_LOW);
      }
    }
  } else {
    delay(1);
  }

  // Display sleep: the Mac's screens slept, so stale pixels are pointless -
  // kill the backlight (heat + burn-in). Any drawn frame wakes it above.
  if (sleepRequested) {
    sleepRequested = false;
    if (!displaySleeping) {
      displaySleeping = true;
      idleActive = false;
      analogWrite(PIN_BL, 0);
      Serial.println("display sleeping (ESLP from sender)");
    }
  }

  // Idle screen: no frames for a while -> overlay device info on the last
  // frame at reduced backlight, repositioning periodically against burn-in.
  if (!displaySleeping && dmaInFlight == 0 && lastFrameShownAt != 0 &&
      millis() - lastFrameShownAt > IDLE_AFTER_MS) {
    if (!idleActive) {
      idleActive = true;
      analogWrite(PIN_BL, BL_IDLE);
      drawIdleScreen();
      Serial.println("idle screen on");
    } else if (millis() - lastIdleDrawAt > IDLE_REPOSITION_MS) {
      drawIdleScreen();  // new random position, fresh RSSI/IP
    }
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
    bool starving = packetsDelta > 2 * MAX_BANDS &&
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
  // re-resolution finds us.
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
      MDNS.setInstanceName(cfgName);
      MDNS.addService("espdisp", "udp", UDP_PORT);
      MDNS.addServiceTxt("espdisp", "udp", "name", cfgName);
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
    uint32_t vals[5] = {statFramesShown, statFramesDropped, statFramesSkipped,
                        statPackets, (uint32_t)ESP.getFreeHeap()};
    for (int i = 0; i < 5; i++) {
      pkt[4 + i * 4] = vals[i] & 0xFF;
      pkt[5 + i * 4] = (vals[i] >> 8) & 0xFF;
      pkt[6 + i * 4] = (vals[i] >> 16) & 0xFF;
      pkt[7 + i * 4] = (vals[i] >> 24) & 0xFF;
    }
    udp.writeTo(pkt, sizeof(pkt), IPAddress(hbIp), hbPort);
  }

  static uint32_t lastLedUpdate = 0;
  if (millis() - lastLedUpdate >= 2000) {
    lastLedUpdate = millis();
    updateSignalLed();
  }

  static uint32_t lastReport = 0;
  if (millis() - lastReport >= 5000) {
    lastReport = millis();
    Serial.printf("frames=%lu dropped=%lu skipped=%lu packets=%lu badlen=%lu drawerr=%lu heap=%lu rssi=%d\n",
                  (unsigned long)statFramesShown, (unsigned long)statFramesDropped,
                  (unsigned long)statFramesSkipped, (unsigned long)statPackets,
                  (unsigned long)statBadLen, (unsigned long)statDrawErrors,
                  (unsigned long)ESP.getFreeHeap(), (int)WiFi.RSSI());
  }
}
