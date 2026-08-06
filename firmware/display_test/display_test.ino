// Panel bring-up test for BOTH Waveshare ESP32-C6 1.47" boards.
//
//   ESP32-C6-LCD-1.47        ST7789, 172x320
//   ESP32-C6-Touch-LCD-1.47  JD9853, 172x320
//
// The board is detected at boot (I2C probe, see board_detect.h) and the pins,
// driver, gap and inversion all come from the board table. One binary, either
// board - the same arrangement display_stream uses.
//
// This uses esp_lcd through the shared boardpanel::init, not Arduino_GFX, on
// purpose: it is the code path the real firmware runs, so a pass here means
// something about the firmware. It also gives us the 80MHz DMA figure that the
// streaming throughput budget depends on.
//
// Everything drawn is described over serial as it is drawn, because a panel test
// is only useful if you can tell what "correct" looks like. Compare the panel
// against the log.

#include <Arduino.h>
#include <esp_heap_caps.h>

#include <board_config.h>
#include <board_detect.h>
#include <panel_init.h>

static const int16_t PANEL_W = 172;
static const int16_t PANEL_H = 320;
static const uint32_t SPI_HZ = 80000000;
static const size_t FRAME_BYTES = (size_t)PANEL_W * PANEL_H * 2;

// RGB565. Stored big-endian in the buffer, which is panel byte order.
static const uint16_t C_BLACK = 0x0000;
static const uint16_t C_WHITE = 0xFFFF;
static const uint16_t C_RED = 0xF800;
static const uint16_t C_GREEN = 0x07E0;
static const uint16_t C_BLUE = 0x001F;
static const uint16_t C_YELLOW = 0xFFE0;
static const uint16_t C_CYAN = 0x07FF;
static const uint16_t C_MAGENTA = 0xF81F;

static board::Variant variant = board::Variant::Unknown;
static const board::Config *cfg = nullptr;
static esp_lcd_panel_handle_t panel = nullptr;
static uint8_t *fb = nullptr;
static volatile int32_t dmaInFlight = 0;

static bool IRAM_ATTR onTransDone(esp_lcd_panel_io_handle_t,
                                  esp_lcd_panel_io_event_data_t *, void *) {
  if (dmaInFlight > 0) dmaInFlight = dmaInFlight - 1;
  return false;
}

// Wait for queued transfers to land before touching the buffer again. Bounded,
// because a wedged DMA should report itself rather than hang the test.
static bool waitDma(uint32_t timeoutMs = 500) {
  uint32_t start = millis();
  while (dmaInFlight != 0) {
    if (millis() - start > timeoutMs) {
      Serial.println("  WARN: DMA completion timeout");
      dmaInFlight = 0;
      return false;
    }
    delay(1);
  }
  return true;
}

static void push(int w, int h) {
  dmaInFlight = dmaInFlight + 1;
  if (esp_lcd_panel_draw_bitmap(panel, 0, 0, w, h, fb) != ESP_OK) {
    dmaInFlight = dmaInFlight - 1;
    Serial.println("  ERROR: draw_bitmap failed");
  }
  waitDma();
}

static void fill(int w, int h, uint16_t color) {
  uint8_t hi = color >> 8, lo = color & 0xFF;
  size_t bytes = (size_t)w * h * 2;
  for (size_t i = 0; i < bytes; i += 2) {
    fb[i] = hi;
    fb[i + 1] = lo;
  }
}

static void rect(int bufW, int bufH, int x, int y, int w, int h, uint16_t color) {
  uint8_t hi = color >> 8, lo = color & 0xFF;
  for (int py = y; py < y + h; py++) {
    if (py < 0 || py >= bufH) continue;
    for (int px = x; px < x + w; px++) {
      if (px < 0 || px >= bufW) continue;
      size_t off = ((size_t)py * bufW + px) * 2;
      fb[off] = hi;
      fb[off + 1] = lo;
    }
  }
}

static void border(int w, int h, uint16_t color) {
  rect(w, h, 0, 0, w, 1, color);
  rect(w, h, 0, h - 1, w, 1, color);
  rect(w, h, 0, 0, 1, h, color);
  rect(w, h, w - 1, 0, 1, h, color);
}

// Four differently-coloured corners plus a 1px border. This single pattern
// checks three things at once: the gap/offset (border visible on all four
// edges, no wrapped or missing columns), the orientation, and the mirroring
// (which corner is which).
static void drawCornerCard(int w, int h) {
  const int m = 26;
  fill(w, h, C_BLACK);
  border(w, h, C_WHITE);
  rect(w, h, 2, 2, m, m, C_WHITE);              // top-left
  rect(w, h, w - m - 2, 2, m, m, C_RED);        // top-right
  rect(w, h, 2, h - m - 2, m, m, C_GREEN);      // bottom-left
  rect(w, h, w - m - 2, h - m - 2, m, m, C_BLUE);  // bottom-right
  // Centre stripe marks the long axis so portrait vs landscape is unmistakable.
  rect(w, h, w / 2 - 2, h / 4, 4, h / 2, C_YELLOW);
  push(w, h);
  Serial.printf(
      "  expect: %dx%d, 1px white border on all 4 edges, corners "
      "TL=white TR=red BL=green BR=blue, yellow bar down the middle\n",
      w, h);
}

void setup() {
  Serial.begin(115200);
  Serial.setTxTimeoutMs(0);
  unsigned long start = millis();
  while (!Serial && millis() - start < 6000) delay(50);

  Serial.println();
  Serial.println("=== display_test: dual-board panel bring-up ===");
  Serial.printf("chip %s rev %d, %d MB flash, heap %lu\n", ESP.getChipModel(),
                ESP.getChipRevision(), ESP.getFlashChipSize() / (1024 * 1024),
                (unsigned long)ESP.getFreeHeap());

  // Detect before touching any panel or LED pin. See board_detect.h.
  variant = boarddetect::probe();
  cfg = &board::configFor(variant);
  Serial.printf("board: %s\n", cfg->name);
  Serial.printf("  driver=%s sclk=%d mosi=%d cs=%d dc=%d rst=%d bl=%d\n",
                cfg->driver == board::PanelDriver::Jd9853 ? "JD9853" : "ST7789",
                cfg->pinSclk, cfg->pinMosi, cfg->pinCs, cfg->pinDc, cfg->pinRst,
                cfg->pinBl);
  Serial.printf("  boot_button=%d rgb_led=%d gap=%u invert=%d\n",
                cfg->pinBootButton, cfg->pinRgbLed, cfg->colOffset,
                cfg->invertColor);

  fb = (uint8_t *)heap_caps_malloc(FRAME_BYTES, MALLOC_CAP_DMA);
  if (!fb) {
    Serial.println("FATAL: framebuffer alloc failed");
    while (true) delay(1000);
  }

  // Backlight at Waveshare's recommended 50% ceiling.
  pinMode(cfg->pinBl, OUTPUT);
  analogWrite(cfg->pinBl, 128);

  if (!boardpanel::init(*cfg, SPI2_HOST, SPI_HZ, FRAME_BYTES, onTransDone,
                        nullptr, nullptr, &panel)) {
    Serial.println("FATAL: panel init failed");
    while (true) delay(1000);
  }
  Serial.printf("panel init OK at %lu Hz\n", (unsigned long)SPI_HZ);
  boardpanel::applyOrientation(panel, *cfg, false /* portrait */, false);

  // Full-screen primaries. This is the colour-order and inversion check: if
  // RGB element order were wrong, red and blue would swap; if inversion were
  // wrong, every colour would come out as its complement.
  struct {
    const char *name;
    uint16_t color;
  } primaries[] = {{"RED", C_RED},
                   {"GREEN", C_GREEN},
                   {"BLUE", C_BLUE},
                   {"WHITE", C_WHITE},
                   {"BLACK", C_BLACK}};
  for (auto &p : primaries) {
    Serial.printf("fill: whole panel should be %s\n", p.name);
    fill(PANEL_W, PANEL_H, p.color);
    push(PANEL_W, PANEL_H);
    delay(700);
  }

  Serial.println("portrait corner card:");
  drawCornerCard(PANEL_W, PANEL_H);
  delay(2500);

  Serial.println("portrait, flipped 180 (same card, upside down):");
  boardpanel::applyOrientation(panel, *cfg, false, true /* flip180 */);
  drawCornerCard(PANEL_W, PANEL_H);
  Serial.println("  expect: corners now TL=blue TR=green BL=red BR=white");
  delay(2500);

  Serial.println("landscape:");
  boardpanel::applyOrientation(panel, *cfg, true /* landscape */, false);
  drawCornerCard(PANEL_H, PANEL_W);
  delay(2500);

  // Back to portrait for the benchmark and the resting pattern.
  boardpanel::applyOrientation(panel, *cfg, false, false);

  // Full-frame push timing at this clock. This is the number the streaming
  // pipeline's fps ceiling comes from, so it is worth measuring per board
  // rather than assuming the two panels clock the same.
  const uint16_t bench[] = {C_RED, C_GREEN, C_BLUE, C_YELLOW, C_CYAN, C_MAGENTA};
  fill(PANEL_W, PANEL_H, C_BLACK);
  push(PANEL_W, PANEL_H);
  uint32_t t0 = micros();
  const int iterations = 20;
  for (int i = 0; i < iterations; i++) {
    fill(PANEL_W, PANEL_H, bench[i % 6]);
    push(PANEL_W, PANEL_H);
  }
  uint32_t elapsed = micros() - t0;
  float msPerFrame = elapsed / (float)iterations / 1000.0f;
  Serial.printf("full-frame push x%d: %.2f ms/frame -> ceiling ~%.1f fps\n",
                iterations, msPerFrame, 1000.0f / msPerFrame);
  Serial.println("  note: includes the CPU fill, so the true SPI ceiling is a"
                 " little higher");

  Serial.println("resting on the portrait corner card");
  drawCornerCard(PANEL_W, PANEL_H);
  Serial.println("DONE - compare the panel against the expectations above");
}

void loop() {
  delay(10000);
  Serial.printf("(idle) board=%s heap=%lu\n", board::variantToken(variant),
                (unsigned long)ESP.getFreeHeap());
}
