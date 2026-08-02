// display_stream: UDP RGB565 frame receiver for Waveshare ESP32-C6-LCD-1.47.
//
// Pipeline (per docs/esp32-wireless-display-plan.md):
//   Mac sends raw RGB565 frames (172x320, big-endian / panel byte order)
//   chunked over UDP. Each packet: [frame_id u16 LE][chunk_index u16 LE]
//   [chunk_count u16 LE][payload]. We reassemble into the back buffer of a
//   double buffer; on completion, swap and push the front buffer to the
//   ST7789 over 80MHz SPI in one bulk DMA write.
//
// Chunk payload is 1376 bytes = 4 rows (4 * 172 * 2), so a frame is exactly
// 80 chunks and every packet (1382B) stays under conservative MTU.
//
// Reassembly happens in the AsyncUDP callback (lwIP task); the SPI push
// happens in loop() (Arduino task). Missing chunks: if packets from a newer
// frame arrive while the current one is incomplete, the old frame is
// abandoned (favor recency over completeness).

#include <Arduino_GFX_Library.h>
#include <AsyncUDP.h>
#include <ESPmDNS.h>
#include <WiFi.h>

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
static const uint8_t COL_OFFSET = 34;
static const uint8_t ROW_OFFSET = 0;
static const uint32_t SPI_HZ = 80000000;

Arduino_DataBus *bus = new Arduino_ESP32SPIDMA(PIN_DC, PIN_CS, PIN_SCLK, PIN_MOSI,
                                               GFX_NOT_DEFINED /* MISO */);
Arduino_GFX *gfx = new Arduino_ST7789(bus, PIN_RST, 0, true /* IPS */,
                                      PANEL_W, PANEL_H,
                                      COL_OFFSET, ROW_OFFSET, COL_OFFSET, ROW_OFFSET);

// ---- Protocol ----------------------------------------------------------
static const uint16_t UDP_PORT = 5568;
static const size_t FRAME_BYTES = (size_t)PANEL_W * PANEL_H * 2;  // 110080
static const size_t CHUNK_PAYLOAD = 1376;                         // 4 rows
static const uint16_t CHUNK_COUNT = FRAME_BYTES / CHUNK_PAYLOAD;  // 80
static const size_t HEADER_BYTES = 6;

// ---- Double buffer -----------------------------------------------------
static uint8_t *bufA = nullptr;
static uint8_t *bufB = nullptr;

// Owned by the UDP callback (lwIP task):
static uint8_t *backBuf = nullptr;
static uint16_t rxFrameId = 0;
static uint16_t rxChunksSeen = 0;
static bool rxFrameActive = false;

// Handoff to loop(): pointer written by callback, consumed by loop.
static uint8_t *volatile readyBuf = nullptr;

// Stats.
static volatile uint32_t statFramesShown = 0;
static volatile uint32_t statFramesDropped = 0;   // incomplete, abandoned
static volatile uint32_t statFramesSkipped = 0;   // complete but display busy
static volatile uint32_t statPackets = 0;

AsyncUDP udp;

static void onPacket(AsyncUDPPacket packet) {
  const uint8_t *data = packet.data();
  size_t len = packet.length();
  if (len != HEADER_BYTES + CHUNK_PAYLOAD) {
    return;  // not a valid chunk
  }
  statPackets = statPackets + 1;

  uint16_t frameId = (uint16_t)data[0] | ((uint16_t)data[1] << 8);
  uint16_t chunkIndex = (uint16_t)data[2] | ((uint16_t)data[3] << 8);
  uint16_t chunkCount = (uint16_t)data[4] | ((uint16_t)data[5] << 8);
  if (chunkCount != CHUNK_COUNT || chunkIndex >= CHUNK_COUNT) {
    return;  // geometry mismatch - sender misconfigured
  }

  if (!rxFrameActive || frameId != rxFrameId) {
    // New frame begins. If the previous one was mid-assembly, drop it.
    if (rxFrameActive && rxChunksSeen > 0) {
      statFramesDropped = statFramesDropped + 1;
    }
    rxFrameId = frameId;
    rxChunksSeen = 0;
    rxFrameActive = true;
  }

  memcpy(backBuf + (size_t)chunkIndex * CHUNK_PAYLOAD, data + HEADER_BYTES,
         CHUNK_PAYLOAD);
  rxChunksSeen++;

  // Note: duplicate chunks would double-count, but UDP duplication on a
  // local WLAN is rare enough that a full bitmap isn't worth the cycles.
  if (rxChunksSeen >= CHUNK_COUNT) {
    rxFrameActive = false;
    if (readyBuf == nullptr) {
      // Hand the completed buffer to loop() and start filling the other.
      readyBuf = backBuf;
      backBuf = (backBuf == bufA) ? bufB : bufA;
    } else {
      // Display still busy with the previous frame: keep the buffer,
      // next frame overwrites it (recency wins).
      statFramesSkipped = statFramesSkipped + 1;
    }
  }
}

void setup() {
  Serial.begin(115200);
  unsigned long start = millis();
  while (!Serial && millis() - start < 5000) {
    delay(50);
  }
  Serial.println("=== display_stream ===");

  bufA = (uint8_t *)heap_caps_malloc(FRAME_BYTES, MALLOC_CAP_8BIT);
  bufB = (uint8_t *)heap_caps_malloc(FRAME_BYTES, MALLOC_CAP_8BIT);
  if (!bufA || !bufB) {
    Serial.println("FATAL: frame buffer alloc failed");
    while (true) delay(1000);
  }
  backBuf = bufA;
  Serial.printf("buffers ok, free heap: %lu\n", (unsigned long)ESP.getFreeHeap());

  pinMode(PIN_BL, OUTPUT);
  analogWrite(PIN_BL, 128);  // 50% cap per Waveshare guidance
  if (!gfx->begin(SPI_HZ)) {
    Serial.println("FATAL: display init failed");
    while (true) delay(1000);
  }
  gfx->fillScreen(RGB565_BLACK);
  gfx->setTextColor(RGB565_WHITE);
  gfx->setTextSize(1);
  gfx->setCursor(8, 8);
  gfx->print("connecting to WiFi...");

  WiFi.mode(WIFI_STA);
  WiFi.setSleep(false);  // latency: don't doze between beacons
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

  gfx->fillScreen(RGB565_BLACK);
  gfx->setCursor(8, 8);
  gfx->print("ready ");
  gfx->print(WiFi.localIP());
  gfx->setCursor(8, 24);
  gfx->printf("udp :%u  espdisplay.local", UDP_PORT);

  if (udp.listen(UDP_PORT)) {
    udp.onPacket(onPacket);
    Serial.printf("UDP listening on %u\n", UDP_PORT);
  } else {
    Serial.println("FATAL: UDP listen failed");
  }
}

void loop() {
  uint8_t *frame = readyBuf;
  if (frame != nullptr) {
    // Bulk big-endian push: sender already swapped to panel byte order.
    gfx->draw16bitBeRGBBitmap(0, 0, (uint16_t *)frame, PANEL_W, PANEL_H);
    readyBuf = nullptr;
    statFramesShown = statFramesShown + 1;
  } else {
    delay(1);
  }

  static uint32_t lastReport = 0;
  if (millis() - lastReport >= 5000) {
    lastReport = millis();
    Serial.printf("frames=%lu dropped=%lu skipped=%lu packets=%lu heap=%lu\n",
                  (unsigned long)statFramesShown, (unsigned long)statFramesDropped,
                  (unsigned long)statFramesSkipped, (unsigned long)statPackets,
                  (unsigned long)ESP.getFreeHeap());
  }
}
