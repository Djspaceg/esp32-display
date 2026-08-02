// Board variant probe for Waveshare ESP32-C6 1.47" LCD boards.
//
// Two candidate boards share this form factor but differ in LCD driver
// and pin mapping:
//   - ESP32-C6-LCD-1.47        : ST7789, no I2C peripherals onboard
//   - ESP32-C6-Touch-LCD-1.47  : JD9853, AXS5106L touch + QMI8658A IMU
//                                on shared I2C bus (SDA=GPIO18, SCL=GPIO19)
//
// Strategy: scan the I2C bus on GPIO18/19. If we find devices (expected
// addresses per Waveshare FAQ: 0x51, 0x6B, 0x7E), it's the Touch variant
// (JD9853). An empty bus strongly suggests the non-touch ST7789 variant.

#include <Wire.h>

static const int PIN_SDA = 18;
static const int PIN_SCL = 19;
static const int PIN_TP_RST = 20;  // touch reset on the Touch variant

void setup() {
  Serial.begin(115200);
  // Native USB CDC: wait for the host to open the port (up to ~8s).
  unsigned long start = millis();
  while (!Serial && millis() - start < 8000) {
    delay(50);
  }
  delay(200);

  Serial.println();
  Serial.println("=== ESP32-C6 LCD board variant probe ===");
  Serial.printf("Chip: %s rev %d, %d MB flash, %lu bytes free heap\n",
                ESP.getChipModel(), ESP.getChipRevision(),
                ESP.getFlashChipSize() / (1024 * 1024),
                (unsigned long)ESP.getFreeHeap());

  // Release touch controller from reset in case it holds the bus.
  pinMode(PIN_TP_RST, OUTPUT);
  digitalWrite(PIN_TP_RST, LOW);
  delay(20);
  digitalWrite(PIN_TP_RST, HIGH);
  delay(100);

  Wire.begin(PIN_SDA, PIN_SCL, 100000);

  Serial.println("Scanning I2C on SDA=GPIO18 SCL=GPIO19 ...");
  int found = 0;
  for (uint8_t addr = 0x08; addr < 0x78; addr++) {
    Wire.beginTransmission(addr);
    uint8_t err = Wire.endTransmission();
    if (err == 0) {
      found++;
      const char *guess = "";
      if (addr == 0x51 || addr == 0x63) guess = " (AXS5106L touch?)";
      if (addr == 0x6B || addr == 0x6A) guess = " (QMI8658A IMU?)";
      if (addr == 0x7E) guess = " (per Waveshare FAQ)";
      Serial.printf("  found device at 0x%02X%s\n", addr, guess);
    }
  }

  Serial.printf("I2C scan complete: %d device(s) found\n", found);
  if (found > 0) {
    Serial.println("VERDICT: Touch variant (ESP32-C6-Touch-LCD-1.47, JD9853)");
    Serial.println("  LCD pins: SCLK=1 MOSI=2 CS=14 DC=15 RST=22 BL=23");
  } else {
    Serial.println("VERDICT: likely non-touch variant (ESP32-C6-LCD-1.47, ST7789)");
    Serial.println("  LCD pins: SCLK=7 MOSI=6 CS=14 DC=15 RST=21 BL=22");
  }
}

void loop() {
  delay(5000);
  Serial.println("(probe finished - see verdict above; resets repeat it)");
}
