// Display bring-up test for Waveshare ESP32-C6-LCD-1.47 (ST7789, 172x320).
//
// Verifies: pin mapping, SPI clock, panel offsets, orientation, color order.
// Draws a border, color bars, and corner markers so any offset/rotation
// mistake is immediately visible.
//
// Pins (from Waveshare wiki for the non-touch board):
//   MOSI=GPIO6  SCLK=GPIO7  CS=GPIO14  DC=GPIO15  RST=GPIO21  BL=GPIO22

#include <Arduino_GFX_Library.h>

static const int PIN_MOSI = 6;
static const int PIN_SCLK = 7;
static const int PIN_CS = 14;
static const int PIN_DC = 15;
static const int PIN_RST = 21;
static const int PIN_BL = 22;

// 172x320 panel on a 240x320-native ST7789: centered, so column offset 34.
static const int16_t PANEL_W = 172;
static const int16_t PANEL_H = 320;
static const uint8_t COL_OFFSET = 34;
static const uint8_t ROW_OFFSET = 0;

static const uint32_t SPI_HZ = 80000000;  // plan target; fall back to 40MHz if unstable

Arduino_DataBus *bus = new Arduino_ESP32SPI(PIN_DC, PIN_CS, PIN_SCLK, PIN_MOSI,
                                            GFX_NOT_DEFINED /* MISO */);
Arduino_GFX *gfx = new Arduino_ST7789(bus, PIN_RST, 0 /* rotation */, true /* IPS */,
                                      PANEL_W, PANEL_H,
                                      COL_OFFSET, ROW_OFFSET, COL_OFFSET, ROW_OFFSET);

void setup() {
  Serial.begin(115200);
  unsigned long start = millis();
  while (!Serial && millis() - start < 6000) {
    delay(50);
  }

  Serial.println("=== display_test: ST7789 bring-up ===");

  // Backlight: PWM at 50% max per Waveshare overheating warning.
  pinMode(PIN_BL, OUTPUT);
  analogWrite(PIN_BL, 128);

  if (!gfx->begin(SPI_HZ)) {
    Serial.println("ERROR: gfx->begin() failed");
    while (true) delay(1000);
  }
  Serial.printf("gfx->begin OK at %lu Hz\n", (unsigned long)SPI_HZ);

  // Full-screen fills to spot color-order / inversion problems.
  gfx->fillScreen(RGB565_RED);
  delay(600);
  gfx->fillScreen(RGB565_GREEN);
  delay(600);
  gfx->fillScreen(RGB565_BLUE);
  delay(600);
  gfx->fillScreen(RGB565_BLACK);

  // 1px white border: if offsets are wrong, an edge will be cut off or
  // garbage columns appear.
  gfx->drawRect(0, 0, PANEL_W, PANEL_H, RGB565_WHITE);

  // Color bars.
  const uint16_t bars[] = {RGB565_RED, RGB565_GREEN, RGB565_BLUE,
                           RGB565_YELLOW, RGB565_CYAN, RGB565_MAGENTA};
  int barH = 30;
  for (int i = 0; i < 6; i++) {
    gfx->fillRect(6, 40 + i * (barH + 4), PANEL_W - 12, barH, bars[i]);
  }

  // Corner markers.
  gfx->fillTriangle(2, 2, 22, 2, 2, 22, RGB565_WHITE);            // top-left
  gfx->fillCircle(PANEL_W - 12, PANEL_H - 12, 8, RGB565_ORANGE);  // bottom-right

  gfx->setTextColor(RGB565_WHITE);
  gfx->setTextSize(2);
  gfx->setCursor(10, 10);
  gfx->print("ST7789 OK");
  gfx->setTextSize(1);
  gfx->setCursor(10, PANEL_H - 40);
  gfx->print("80MHz SPI, 172x320");

  delay(2000);

  // Timing check: how long does a full-frame fill take at this SPI clock?
  uint32_t t0 = micros();
  for (int i = 0; i < 10; i++) {
    gfx->fillScreen(bars[i % 6]);
  }
  uint32_t dt = micros() - t0;
  float ms_per_frame = dt / 10.0f / 1000.0f;
  Serial.printf("fillScreen x10: %.2f ms/frame -> ceiling ~%.1f fps\n",
                ms_per_frame, 1000.0f / ms_per_frame);

  gfx->fillScreen(RGB565_BLACK);
  gfx->drawRect(0, 0, PANEL_W, PANEL_H, RGB565_WHITE);
  gfx->setTextSize(2);
  gfx->setCursor(10, 10);
  gfx->print("ST7789 OK");
  gfx->setCursor(10, 40);
  gfx->printf("%.1f fps", 1000.0f / ms_per_frame);
  Serial.println("DONE - inspect panel");
}

void loop() {
  delay(5000);
  Serial.println("(display test idle)");
}
