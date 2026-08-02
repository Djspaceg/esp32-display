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

#include <AsyncUDP.h>
#include <ESPmDNS.h>
#include <WiFi.h>
#include <esp_task_wdt.h>

#include <driver/spi_master.h>
#include <esp_lcd_panel_io.h>
#include <esp_lcd_panel_ops.h>
#include <esp_lcd_panel_st7789.h>
#include <esp_lcd_panel_vendor.h>

#include "wifi_config.h"  // defines WIFI_SSID / WIFI_PASSWORD (gitignored)

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

// ---- BOOT button (GPIO9, ESP32-C6 boot strap; plain input after boot) ----
// Short press: toggle backlight high/low. Long press: flip display 180.
static const int PIN_BOOT = 9;
static const uint32_t LONG_PRESS_MS = 600;
static const uint32_t DEBOUNCE_MS = 30;
static const uint8_t BL_HIGH = 128;  // 50%, Waveshare's recommended ceiling
static const uint8_t BL_LOW = 24;    // ~10%

// ---- Protocol ----------------------------------------------------------
static const uint16_t UDP_PORT = 5568;
static const size_t FRAME_BYTES = (size_t)PANEL_W * PANEL_H * 2;  // 110080
static const size_t CHUNK_PAYLOAD = 1376;                         // 4 rows
static const uint16_t CHUNK_COUNT = FRAME_BYTES / CHUNK_PAYLOAD;  // 80
static const size_t HEADER_BYTES = 6;

// ---- Buffers -----------------------------------------------------------
static uint8_t *bufA = nullptr;
static uint8_t *bufB = nullptr;

static uint8_t *backBuf = nullptr;              // owned by UDP callback
static uint8_t *volatile readyBuf = nullptr;    // handoff: UDP -> loop
static uint8_t *volatile dmaBuf = nullptr;      // owned by SPI DMA

static uint16_t rxFrameId = 0;
static uint16_t rxChunksSeen = 0;
static bool rxFrameActive = false;
static uint8_t rxChunkBitmap[(80 + 7) / 8];      // dedup: WiFi retransmits duplicate chunks
static bool rxLandscape = false;                 // orientation of frame being assembled
static volatile bool readyLandscape = false;     // orientation of readyBuf
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
static uint32_t dmaQueuedAt = 0;  // for DMA-stall detection

// Reply endpoint: source of the most recent packet from the Mac. Used for
// the 1Hz heartbeat so the sender can detect blackholing (wrong IP after a
// reboot, WiFi drop) and see delivery stats. u32+u16 writes are effectively
// atomic on this 32-bit core.
static volatile uint32_t hbIp = 0;
static volatile uint16_t hbPort = 0;

AsyncUDP udp;

// ISR context: DMA finished reading dmaBuf; it's free for reuse.
static bool IRAM_ATTR onColorTransDone(esp_lcd_panel_io_handle_t,
                                       esp_lcd_panel_io_event_data_t *, void *) {
  dmaBuf = nullptr;
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
  if (len != HEADER_BYTES + CHUNK_PAYLOAD) {
    statBadLen = statBadLen + 1;
    return;
  }
  statPackets = statPackets + 1;

  uint16_t frameId = (uint16_t)data[0] | ((uint16_t)data[1] << 8);
  uint16_t chunkIndex = (uint16_t)data[2] | ((uint16_t)data[3] << 8);
  uint16_t chunkCount = (uint16_t)data[4] | ((uint16_t)data[5] << 8);
  // Top bit of chunk_count carries orientation: 0 = portrait (172x320),
  // 1 = landscape (320x172). Same byte count either way.
  bool landscape = (chunkCount & 0x8000) != 0;
  if ((chunkCount & 0x7FFF) != CHUNK_COUNT || chunkIndex >= CHUNK_COUNT) {
    return;  // geometry mismatch - sender misconfigured
  }

  if (!rxFrameActive) {
    rxFrameId = frameId;
    rxChunksSeen = 0;
    memset(rxChunkBitmap, 0, sizeof(rxChunkBitmap));
    rxFrameActive = true;
    rxLandscape = landscape;
  } else if (frameId != rxFrameId) {
    // Wraparound-aware ordering: only a NEWER frame abandons the current
    // one. Stale chunks (WiFi retransmissions delivered late, reordering)
    // are ignored - adopting them used to thrash the reassembler and kill
    // both frames.
    int16_t diff = (int16_t)(frameId - rxFrameId);
    if (diff <= 0) {
      // Late chunk of an older frame - ignore. But a persistent stream of
      // "stale" IDs means the sender restarted (its IDs reset to 0):
      // force-resync after ~2 frames' worth instead of rejecting for up
      // to 32k frames.
      static uint16_t staleStreak = 0;
      if (++staleStreak < 2 * CHUNK_COUNT) {
        return;
      }
      staleStreak = 0;
    }
    if (rxChunksSeen > 0) {
      statFramesDropped = statFramesDropped + 1;
    }
    rxFrameId = frameId;
    rxChunksSeen = 0;
    memset(rxChunkBitmap, 0, sizeof(rxChunkBitmap));
    rxLandscape = landscape;
  }

  // Duplicate chunks (802.11 retry artifacts) must not double-count toward
  // completion - that would display frames with holes.
  uint8_t mask = 1 << (chunkIndex & 7);
  if (rxChunkBitmap[chunkIndex >> 3] & mask) {
    return;
  }
  rxChunkBitmap[chunkIndex >> 3] |= mask;

  memcpy(backBuf + (size_t)chunkIndex * CHUNK_PAYLOAD, data + HEADER_BYTES,
         CHUNK_PAYLOAD);
  rxChunksSeen++;

  if (rxChunksSeen >= CHUNK_COUNT) {
    rxFrameActive = false;
    uint8_t *other = (backBuf == bufA) ? bufB : bufA;
    if (readyBuf == nullptr && other != dmaBuf) {
      // Hand off the completed frame; start filling the free buffer.
      readyLandscape = rxLandscape;
      readyBuf = backBuf;
      backBuf = other;
    } else {
      // No free buffer: keep this one, newer frames overwrite it.
      statFramesSkipped = statFramesSkipped + 1;
    }
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

// Poll the BOOT button: short press toggles backlight, long press (fires
// while still held) flips the display 180 degrees.
static void handleButton() {
  static bool wasDown = false;
  static bool longFired = false;
  static uint32_t downAt = 0;
  static bool blHigh = true;

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
      blHigh = !blHigh;
      analogWrite(PIN_BL, blHigh ? BL_HIGH : BL_LOW);
      Serial.printf("button: short press -> backlight %s\n", blHigh ? "high" : "low");
    }
  }
}

// Fill the whole panel with one RGB565 color (used for status feedback).
static void fillPanel(uint16_t rgb565) {
  uint8_t hi = rgb565 >> 8, lo = rgb565 & 0xFF;
  for (size_t i = 0; i < FRAME_BYTES; i += 2) {
    bufA[i] = hi;
    bufA[i + 1] = lo;
  }
  esp_lcd_panel_draw_bitmap(panel, 0, 0, PANEL_W, PANEL_H, bufA);
  delay(30);  // let DMA finish before bufA is reused
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
  backBuf = bufA;
  Serial.printf("buffers ok, free heap: %lu\n", (unsigned long)ESP.getFreeHeap());

  pinMode(PIN_BOOT, INPUT_PULLUP);
  pinMode(PIN_BL, OUTPUT);
  analogWrite(PIN_BL, BL_HIGH);  // 50% cap per Waveshare guidance
  if (!initDisplay()) {
    Serial.println("FATAL: display init failed");
    while (true) delay(1000);
  }
  fillPanel(0x2104);  // dark gray: display alive, waiting for WiFi

  WiFi.mode(WIFI_STA);
  WiFi.setAutoReconnect(true);  // rejoin on AP drop (default, but explicit)
  WiFi.setSleep(false);         // latency: don't doze between beacons
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
  while (WiFi.status() != WL_CONNECTED) {
    delay(200);
  }
  Serial.printf("WiFi up: %s\n", WiFi.localIP().toString().c_str());

  if (MDNS.begin("espdisplay")) {
    MDNS.addService("espdisp", "udp", UDP_PORT);
    Serial.println("mDNS: espdisplay.local, service _espdisp._udp");
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

  uint8_t *frame = readyBuf;
  if (frame != nullptr && dmaBuf == nullptr) {
    bool landscape = readyLandscape;
    dmaBuf = frame;
    readyBuf = nullptr;
    if (landscape != panelLandscape || madctlDirty) {
      applyPanelConfig(landscape);
    }
    // Queues the DMA transfer and returns; onColorTransDone releases dmaBuf.
    // A failed queue never fires the callback - releasing here prevents a
    // permanent pipeline wedge (observed once in the field).
    esp_err_t err;
    if (landscape) {
      err = esp_lcd_panel_draw_bitmap(panel, 0, 0, PANEL_H, PANEL_W, frame);
    } else {
      err = esp_lcd_panel_draw_bitmap(panel, 0, 0, PANEL_W, PANEL_H, frame);
    }
    if (err != ESP_OK) {
      statDrawErrors = statDrawErrors + 1;
      dmaBuf = nullptr;
    } else {
      dmaQueuedAt = millis();
      statFramesShown = statFramesShown + 1;
    }
  } else {
    delay(1);
  }

  // DMA-stall failsafe: the 110KB transfer takes ~14ms at 80MHz. If the
  // completion callback hasn't released the buffer after 500ms, it's lost -
  // reclaim rather than wedge forever.
  if (dmaBuf != nullptr && millis() - dmaQueuedAt > 500) {
    statDrawErrors = statDrawErrors + 1;
    dmaBuf = nullptr;
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
