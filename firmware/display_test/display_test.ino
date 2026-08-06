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
#include <board_touch.h>
#include <panel_init.h>
#include <touch_map.h>

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

// Push a sub-rectangle from a caller-supplied buffer. Touch feedback uses this
// rather than redrawing the whole frame: a full push is ~13ms, which would make
// the marker visibly lag a moving finger.
static void pushRect(int x0, int y0, int w, int h, const uint8_t *buf) {
  dmaInFlight = dmaInFlight + 1;
  if (esp_lcd_panel_draw_bitmap(panel, x0, y0, x0 + w, y0 + h, buf) != ESP_OK) {
    dmaInFlight = dmaInFlight - 1;
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

// ---- Touch mode --------------------------------------------------------
// Interactive check that touch_map.h agrees with what the panel is showing.
// A marker is drawn wherever the mapped touch lands, so if the transform is
// wrong the marker appears somewhere other than under your finger - and the
// four corner colours tell you *how* it is wrong (mirrored, swapped, or both).
//
// The BOOT button cycles orientation, because the mapping has four cases and
// three of them are only reachable once the panel has been rotated.
static const int MARKER = 16;
static uint8_t markerBuf[MARKER * MARKER * 2];
static bool touchReady = false;
static uint8_t orientationIndex = 0;  // bit0 = landscape, bit1 = flip180

static bool orientLandscape() { return (orientationIndex & 1) != 0; }
static bool orientFlip() { return (orientationIndex & 2) != 0; }

static const char *orientName() {
  switch (orientationIndex & 3) {
    case 0:
      return "portrait";
    case 1:
      return "landscape";
    case 2:
      return "portrait flipped 180";
    default:
      return "landscape flipped 180";
  }
}

static void enterTouchOrientation() {
  boardpanel::applyOrientation(panel, *cfg, orientLandscape(), orientFlip());
  int w = touchmap::frameWidth(orientLandscape());
  int h = touchmap::frameHeight(orientLandscape());
  drawCornerCard(w, h);
  Serial.printf("touch mode: %s (%dx%d) - press BOOT to rotate\n", orientName(),
                w, h);
}

// ---- BOOT button diagnostics -------------------------------------------
// Waveshare's pinout table for the Touch board says the BOOT button is GPIO8.
// The non-touch board wires it to GPIO9, and the Touch board's table omits GPIO9
// entirely, so "GPIO8" is an assumption rather than a measurement - and
// display_stream trusts it for the short-press backlight toggle and long-press
// flip. If it is wrong, those controls silently do nothing on this board.
//
// So watch both candidates and report which one actually moves. This only runs
// in touch mode, i.e. only on the Touch board, so reading GPIO8 here can never
// disturb the non-touch board's LED.
static const int8_t BUTTON_PROBE_PINS[] = {8, 9};
static const size_t BUTTON_PROBE_COUNT =
    sizeof(BUTTON_PROBE_PINS) / sizeof(BUTTON_PROBE_PINS[0]);
static bool buttonProbeLast[BUTTON_PROBE_COUNT];

static void reportButtonPins(const char *why) {
  Serial.printf("button [%s]:", why);
  for (size_t i = 0; i < BUTTON_PROBE_COUNT; i++) {
    Serial.printf(" GPIO%d=%s", BUTTON_PROBE_PINS[i],
                  digitalRead(BUTTON_PROBE_PINS[i]) == LOW ? "LOW" : "HIGH");
  }
  Serial.printf("  (table says BOOT=GPIO%d)  orientation=%s\n",
                cfg->pinBootButton, orientName());
}

static void setupTouchMode() {
  touchReady = boardtouch::init(*cfg);
  if (!touchReady) {
    Serial.println("touch mode: unavailable on this board, idling instead");
    return;
  }
  for (size_t i = 0; i < sizeof(markerBuf); i += 2) {
    markerBuf[i] = 0xF8;  // magenta, RGB565 big-endian: stands out on the card
    markerBuf[i + 1] = 0x1F;
  }
  for (size_t i = 0; i < BUTTON_PROBE_COUNT; i++) {
    pinMode(BUTTON_PROBE_PINS[i], INPUT_PULLUP);
    buttonProbeLast[i] = digitalRead(BUTTON_PROBE_PINS[i]) == LOW;
  }
  orientationIndex = 0;
  enterTouchOrientation();
  reportButtonPins("at rest");
  Serial.println("touch the coloured corners; the marker should land under your"
                 " finger");
  Serial.println("send 'r' over serial to rotate, 'b' to re-read the buttons");
}

// Serial control, so rotating through the four orientations does not depend on
// the button working - which is the very thing under suspicion.
static void handleTouchSerial() {
  while (Serial.available() > 0) {
    char c = (char)Serial.read();
    if (c == 'r' || c == 'R') {
      orientationIndex = (uint8_t)((orientationIndex + 1) & 3);
      enterTouchOrientation();
    } else if (c == 'b' || c == 'B') {
      reportButtonPins("polled");
    }
  }
}

static void serviceTouchMode() {
  handleTouchSerial();

  // Watch every candidate button pin, report any edge, and rotate on a falling
  // edge of whichever one turns out to be real.
  for (size_t i = 0; i < BUTTON_PROBE_COUNT; i++) {
    bool down = digitalRead(BUTTON_PROBE_PINS[i]) == LOW;
    if (down == buttonProbeLast[i]) {
      continue;
    }
    delay(30);  // debounce; this loop has nothing else to do
    down = digitalRead(BUTTON_PROBE_PINS[i]) == LOW;
    if (down == buttonProbeLast[i]) {
      continue;  // bounce, not a real edge
    }
    buttonProbeLast[i] = down;
    Serial.printf("button: GPIO%d -> %s\n", BUTTON_PROBE_PINS[i],
                  down ? "LOW (pressed)" : "HIGH (released)");
    if (down) {
      orientationIndex = (uint8_t)((orientationIndex + 1) & 3);
      enterTouchOrientation();
    }
  }

  // Periodic heartbeat, so a log capture shows pin state even if nothing is
  // being pressed or touched.
  static uint32_t lastBeat = 0;
  if (millis() - lastBeat > 5000) {
    lastBeat = millis();
    reportButtonPins("idle");
  }

  boardtouch::Sample s;
  if (!boardtouch::poll(s)) {
    return;
  }
  if (!s.pressed) {
    Serial.println("touch: release");
    return;
  }

  touchmap::Point p =
      touchmap::map((int16_t)s.rawX, (int16_t)s.rawY, orientLandscape(),
                    orientFlip());
  int w = touchmap::frameWidth(orientLandscape());
  int h = touchmap::frameHeight(orientLandscape());

  // Keep the whole marker on screen so the pushed rect always matches the
  // buffer size.
  int x0 = p.x - MARKER / 2;
  int y0 = p.y - MARKER / 2;
  if (x0 < 0) x0 = 0;
  if (y0 < 0) y0 = 0;
  if (x0 > w - MARKER) x0 = w - MARKER;
  if (y0 > h - MARKER) y0 = h - MARKER;
  pushRect(x0, y0, MARKER, MARKER, markerBuf);

  Serial.printf("touch: raw=(%u,%u) -> mapped=(%d,%d) fingers=%u  [%s]\n",
                s.rawX, s.rawY, p.x, p.y, s.points, orientName());
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

  Serial.println("DONE - compare the panel against the expectations above");

  setupTouchMode();
}

void loop() {
  if (touchReady) {
    serviceTouchMode();
    delay(2);  // the interrupt sets a flag; nothing here needs to spin
    return;
  }
  delay(10000);
  Serial.printf("(idle) board=%s heap=%lu\n", board::variantToken(variant),
                (unsigned long)ESP.getFreeHeap());
}
