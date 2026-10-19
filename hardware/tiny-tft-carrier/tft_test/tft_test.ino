// First-light test for the tiny TFT carrier: a Seeed XIAO ESP32-S3 or
// ESP32-C6 with the Questwise 0.42" 96x54 TFT breakout on the carrier.
//
// Needs the "GFX Library for Arduino" (Arduino_GFX) library. Board:
// "XIAO_ESP32S3" or "XIAO_ESP32C6" in the esp32 core.
//
// What you should see: a white one-pixel frame touching all four edges,
// red / green / blue bars, and "96x54" text. A frame that is cut off or has a
// gap on one side means the column or row offset is wrong.

#include <Arduino_GFX_Library.h>

// Carrier wiring, fixed by the board. XIAO pin = GPIO on each chip.
#if CONFIG_IDF_TARGET_ESP32S3
static const int8_t PIN_SCLK = 7;  // D8
static const int8_t PIN_SDIN = 9;  // D10
static const int8_t PIN_DC = 4;    // D3
static const int8_t PIN_RES = 5;   // D4
static const int8_t PIN_CS = 6;    // D5
static const int8_t PIN_BL = 2;    // D1, only connected when JP1 is bridged
#elif CONFIG_IDF_TARGET_ESP32C6
static const int8_t PIN_SCLK = 19; // D8
static const int8_t PIN_SDIN = 18; // D10
static const int8_t PIN_DC = 21;   // D3
static const int8_t PIN_RES = 22;  // D4
static const int8_t PIN_CS = 23;   // D5
static const int8_t PIN_BL = 1;    // D1, only connected when JP1 is bridged
#else
#error "Build for a XIAO ESP32-S3 or XIAO ESP32-C6"
#endif

// Panel geometry from the seller's library (green-tab init, column offset 16,
// row offset 0, rotation 0). The offsets for rotation 2 assume a 132x162
// controller memory and are untested.
static const int16_t TFT_W = 96;
static const int16_t TFT_H = 54;
static const uint8_t COL_OFFSET = 16;
static const uint8_t ROW_OFFSET = 0;
static const uint8_t COL_OFFSET_ROT2 = 132 - TFT_W - COL_OFFSET;
static const uint8_t ROW_OFFSET_ROT2 = 162 - TFT_H - ROW_OFFSET;

// 15 MHz is the ST7735 datasheet write-clock limit; raise it only after the
// screen works.
static const int32_t SPI_HZ = 15000000;

Arduino_DataBus *bus = new Arduino_ESP32SPI(PIN_DC, PIN_CS, PIN_SCLK, PIN_SDIN, GFX_NOT_DEFINED);
Arduino_GFX *gfx = new Arduino_ST7735(bus, PIN_RES, 0 /* rotation */, false /* not IPS */,
                                      TFT_W, TFT_H, COL_OFFSET, ROW_OFFSET,
                                      COL_OFFSET_ROT2, ROW_OFFSET_ROT2, true /* BGR */);

// Power, frame-rate and gamma registers the seller's library sends for this
// panel (its Rcmd1 and Rcmd3 tables). Arduino_GFX's own ST7735 init skips the
// power settings, so send them after begin().
static void sendSellerInit()
{
  static const uint8_t seq[] = {
      // command, data count, data...
      0xB1, 3, 0x01, 0x2C, 0x2D,                         // FRMCTR1
      0xB2, 3, 0x01, 0x2C, 0x2D,                         // FRMCTR2
      0xB3, 6, 0x01, 0x2C, 0x2D, 0x01, 0x2C, 0x2D,       // FRMCTR3
      0xB4, 1, 0x07,                                     // INVCTR
      0xC0, 3, 0xA2, 0x02, 0x84,                         // PWCTR1
      0xC1, 1, 0xC5,                                     // PWCTR2
      0xC2, 2, 0x0A, 0x00,                               // PWCTR3
      0xC3, 2, 0x8A, 0x2A,                               // PWCTR4
      0xC4, 2, 0x8A, 0xEE,                               // PWCTR5
      0xC5, 1, 0x0E,                                     // VMCTR1
      0xE0, 16, 0x02, 0x1C, 0x07, 0x12, 0x37, 0x32, 0x29, 0x2D,
      0x29, 0x25, 0x2B, 0x39, 0x00, 0x01, 0x03, 0x10,    // GMCTRP1
      0xE1, 16, 0x03, 0x1D, 0x07, 0x06, 0x2E, 0x2C, 0x29, 0x2D,
      0x2E, 0x2E, 0x37, 0x3F, 0x00, 0x00, 0x02, 0x10,    // GMCTRN1
  };
  bus->beginWrite();
  for (size_t i = 0; i < sizeof(seq);)
  {
    uint8_t cmd = seq[i++];
    uint8_t n = seq[i++];
    bus->writeCommand(cmd);
    while (n--)
    {
      bus->write(seq[i++]);
    }
  }
  bus->endWrite();
}

static void drawTestCard()
{
  gfx->fillScreen(RGB565_BLACK);
  int16_t bar = (TFT_W - 4) / 3;
  gfx->fillRect(2, 2, bar, TFT_H - 4, RGB565_RED);
  gfx->fillRect(2 + bar, 2, bar, TFT_H - 4, RGB565_GREEN);
  gfx->fillRect(2 + 2 * bar, 2, bar, TFT_H - 4, RGB565_BLUE);
  gfx->drawRect(0, 0, TFT_W, TFT_H, RGB565_WHITE);
  gfx->setTextColor(RGB565_WHITE, RGB565_BLACK);
  gfx->setTextSize(1);
  gfx->setCursor(33, 23);
  gfx->print("96x54");
}

void setup()
{
  Serial.begin(115200);

  // With JP1 open this pin is not connected and this does nothing.
  pinMode(PIN_BL, OUTPUT);
  digitalWrite(PIN_BL, HIGH);

  if (!gfx->begin(SPI_HZ))
  {
    Serial.println("tft_test: gfx->begin() failed");
  }
  sendSellerInit();
  gfx->setRotation(0);
  drawTestCard();
  Serial.printf("tft_test: SCLK=%d SDIN=%d DC=%d RES=%d CS=%d BL=%d\n",
                PIN_SCLK, PIN_SDIN, PIN_DC, PIN_RES, PIN_CS, PIN_BL);
}

void loop()
{
  // Blink the backlight every 2 s; visible only with JP1 bridged.
  static uint32_t last = 0;
  static bool on = true;
  if (millis() - last >= 2000)
  {
    last = millis();
    on = !on;
    digitalWrite(PIN_BL, on ? HIGH : LOW);
  }
}
