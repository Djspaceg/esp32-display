// Board variant probe for the Waveshare ESP32-C6 1.47" LCD boards.
//
//   ESP32-C6-LCD-1.47        ST7789, no I2C peripherals onboard
//   ESP32-C6-Touch-LCD-1.47  JD9853, AXS5106L touch + QMI8658A IMU on the
//                            shared I2C bus (SDA=GPIO18, SCL=GPIO19)
//
// display_stream now performs this detection itself at every boot, so this
// sketch is no longer required to pick a firmware build - it is a diagnostic.
// Reach for it when a board is behaving as though it were the other one, or to
// see the raw I2C scan without the rest of the firmware running.
//
// It calls the same boarddetect::probe() the firmware does, on purpose: a probe
// tool that implements its own detection can disagree with the firmware, which
// is precisely the confusion it is supposed to resolve.

#include <Arduino.h>

#include <board_config.h>
#include <board_detect.h>

void setup() {
  Serial.begin(115200);
  Serial.setTxTimeoutMs(0);
  // Native USB CDC: wait for the host to open the port.
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
  Serial.printf("Scanning I2C on SDA=GPIO%d SCL=GPIO%d ...\n",
                board::PIN_PROBE_SDA, board::PIN_PROBE_SCL);

  int found = 0;
  board::Variant variant = boarddetect::probe(true, &found);
  const board::Config &cfg = board::configFor(variant);

  Serial.printf("VERDICT: %s\n", cfg.name);
  Serial.printf("  token (for CFGBOARD): %s\n", board::variantToken(variant));
  Serial.printf("  LCD pins: SCLK=%d MOSI=%d CS=%d DC=%d RST=%d BL=%d\n",
                cfg.pinSclk, cfg.pinMosi, cfg.pinCs, cfg.pinDc, cfg.pinRst,
                cfg.pinBl);
  Serial.printf("  BOOT button: GPIO%d\n", cfg.pinBootButton);
  if (cfg.hasRgbLed()) {
    Serial.printf("  addressable RGB LED: GPIO%d\n", cfg.pinRgbLed);
  } else {
    Serial.println("  addressable RGB LED: none on this board");
  }
  if (found == 0) {
    Serial.println("  (an empty bus is what identifies the non-touch board)");
  }
}

void loop() {
  delay(5000);
  Serial.println("(probe finished - see verdict above; resets repeat it)");
}
