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

// ---- Protocol (v2: dirty bands) -----------------------------------------
// The frame is tiled into row bands; the sender transmits only bands that
// changed since its previous frame (plus periodic keyframes). Packet:
//   [frame_id u16 LE][band_index u16 LE][dirty_count u16 LE][band payload]
// dirty_count = number of bands in THIS frame (bit15 = landscape).
// Bands are orientation-native so they align to whole rows:
//   portrait  172px rows: 4 rows x 344B = 1376B, 80 bands
//   landscape 320px rows: 2 rows x 640B = 1280B, 86 bands
static const uint16_t UDP_PORT = 5568;
static const size_t FRAME_BYTES = (size_t)PANEL_W * PANEL_H * 2;  // 110080
static const size_t HEADER_BYTES = 6;
static const uint16_t BANDS_PORTRAIT = 80;
static const uint16_t BANDS_LANDSCAPE = 86;
static const size_t BAND_BYTES_PORTRAIT = 1376;
static const size_t BAND_BYTES_LANDSCAPE = 1280;
static const int ROWS_PER_BAND_PORTRAIT = 4;
static const int ROWS_PER_BAND_LANDSCAPE = 2;
static const uint16_t MAX_BANDS = 86;
static const size_t BITMAP_BYTES = (MAX_BANDS + 7) / 8;

// ---- Buffers -----------------------------------------------------------
// bufA: persistent assembled frame, written by the UDP callback per band.
// bufB: DMA staging - dirty strips are memcpy'd here before queueing, so
//       SPI DMA never reads memory the network path is writing.
static uint8_t *bufA = nullptr;
static uint8_t *bufB = nullptr;

static uint16_t rxFrameId = 0;
static uint16_t rxBandsSeen = 0;
static uint16_t rxBandsExpected = 0;
static bool rxFrameActive = false;
static uint8_t rxBandBitmap[BITMAP_BYTES];       // dedup within the current frame
static bool rxLandscape = false;                 // orientation of frame being assembled
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
  uint16_t frameId = (uint16_t)data[0] | ((uint16_t)data[1] << 8);
  uint16_t bandIndex = (uint16_t)data[2] | ((uint16_t)data[3] << 8);
  uint16_t countField = (uint16_t)data[4] | ((uint16_t)data[5] << 8);
  bool landscape = (countField & 0x8000) != 0;
  uint16_t dirtyCount = countField & 0x7FFF;
  uint16_t totalBands = landscape ? BANDS_LANDSCAPE : BANDS_PORTRAIT;
  size_t bandBytes = landscape ? BAND_BYTES_LANDSCAPE : BAND_BYTES_PORTRAIT;

  if (len != HEADER_BYTES + bandBytes) {
    statBadLen = statBadLen + 1;
    return;
  }
  if (dirtyCount == 0 || dirtyCount > totalBands || bandIndex >= totalBands) {
    return;  // geometry mismatch - sender misconfigured
  }
  statPackets = statPackets + 1;

  if (!rxFrameActive) {
    rxFrameId = frameId;
    rxBandsSeen = 0;
    rxBandsExpected = dirtyCount;
    memset(rxBandBitmap, 0, sizeof(rxBandBitmap));
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
      if (++staleStreak < 2 * MAX_BANDS) {
        return;
      }
      staleStreak = 0;
    }
    if (rxBandsSeen > 0) {
      // Incomplete frame abandoned - but its bands are already applied to
      // bufA and marked in pendingDrawBitmap, so they still reach the
      // panel with the next completed frame (per-band recency).
      statFramesDropped = statFramesDropped + 1;
    }
    rxFrameId = frameId;
    rxBandsSeen = 0;
    rxBandsExpected = dirtyCount;
    memset(rxBandBitmap, 0, sizeof(rxBandBitmap));
    rxLandscape = landscape;
  }

  // Orientation flip invalidates everything in bufA (band geometry and
  // pixel layout both change). The sender guarantees a full keyframe on
  // flip, so dropping stale pending bands is safe.
  if (landscape != bufLandscape) {
    portENTER_CRITICAL(&drawMux);
    memset(pendingDrawBitmap, 0, sizeof(pendingDrawBitmap));
    portEXIT_CRITICAL(&drawMux);
    bufLandscape = landscape;
  }

  // Duplicate bands (802.11 retry artifacts) must not double-count toward
  // completion - that would complete frames with holes.
  uint8_t mask = 1 << (bandIndex & 7);
  if (rxBandBitmap[bandIndex >> 3] & mask) {
    return;
  }
  rxBandBitmap[bandIndex >> 3] |= mask;

  memcpy(bufA + (size_t)bandIndex * bandBytes, data + HEADER_BYTES, bandBytes);
  portENTER_CRITICAL(&drawMux);
  pendingDrawBitmap[bandIndex >> 3] |= mask;
  portEXIT_CRITICAL(&drawMux);
  rxBandsSeen++;

  if (rxBandsSeen >= rxBandsExpected) {
    rxFrameActive = false;
    pendingLandscape = rxLandscape;
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

    uint16_t totalBands = landscape ? BANDS_LANDSCAPE : BANDS_PORTRAIT;
    size_t bandBytes = landscape ? BAND_BYTES_LANDSCAPE : BAND_BYTES_PORTRAIT;
    int rowsPerBand = landscape ? ROWS_PER_BAND_LANDSCAPE : ROWS_PER_BAND_PORTRAIT;
    int drawWidth = landscape ? PANEL_H : PANEL_W;

    // Coalesce runs of contiguous dirty bands into single DMA transfers.
    // Contiguous bands are contiguous in memory, so a run needs just one
    // memcpy to staging and one draw_bitmap. Staging (bufB) keeps DMA reads
    // off the buffer the network task writes.
    int i = 0;
    bool drewAny = false;
    while (i < totalBands) {
      if (!(bands[i >> 3] & (1 << (i & 7)))) {
        i++;
        continue;
      }
      int runStart = i;
      while (i < totalBands && (bands[i >> 3] & (1 << (i & 7)))) {
        i++;
      }
      size_t off = (size_t)runStart * bandBytes;
      size_t bytes = (size_t)(i - runStart) * bandBytes;
      memcpy(bufB + off, bufA + off, bytes);
      dmaInFlight = dmaInFlight + 1;
      dmaQueuedAt = millis();
      // Queues async; blocks briefly only if the 2-deep transaction queue
      // is full. A failed queue never fires the completion callback, so
      // roll the counter back to avoid a permanent wedge.
      esp_err_t err = esp_lcd_panel_draw_bitmap(
          panel, 0, runStart * rowsPerBand, drawWidth, i * rowsPerBand,
          bufB + off);
      if (err != ESP_OK) {
        statDrawErrors = statDrawErrors + 1;
        dmaInFlight = dmaInFlight - 1;
      } else {
        drewAny = true;
      }
    }
    if (drewAny) {
      statFramesShown = statFramesShown + 1;
    }
  } else {
    delay(1);
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
    if (MDNS.begin("espdisplay")) {
      MDNS.addService("espdisp", "udp", UDP_PORT);
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
