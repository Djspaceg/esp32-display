// Read-only carrier diagnostic. It never initializes a display bus and writes
// no flash; fixed targets scan only their configured I2C bus.
#include <Arduino.h>
#include <Wire.h>
#include <esp_mac.h>

#include <board_config.h>
#include <board_detect.h>
#include <platform_config.h>

void setup() {
  Serial.begin(115200);
#if !defined(CONFIG_IDF_TARGET_ESP32P4)
  Serial.setTxTimeoutMs(0);
#endif
  unsigned long start = millis();
  while (!Serial && millis() - start < 8000) delay(50);
  delay(200);

  Serial.println();
  Serial.println("=== esp32-display carrier probe (no display writes) ===");
  uint8_t identity[6] = {0};
#if defined(CONFIG_IDF_TARGET_ESP32P4)
  esp_efuse_mac_get_default(identity);
#else
  esp_read_mac(identity, ESP_MAC_WIFI_STA);
#endif
  Serial.printf(
      "chip=%s rev=%d flash=%dMB base=%02x%02x%02x%02x%02x%02x\n",
      ESP.getChipModel(), ESP.getChipRevision(),
      ESP.getFlashChipSize() / (1024 * 1024), identity[0], identity[1],
      identity[2], identity[3], identity[4], identity[5]);

#if defined(CONFIG_IDF_TARGET_ESP32P4)
  const board::Config &cfg = board::configFor(board::COMPILED_VARIANT);
  Serial.printf("platform=%s target=%s board=%s\n", cfg.platform->chipToken,
                board::targetToken(cfg.variant), board::variantToken(cfg.variant));
  Serial.printf("I2C scan only: SDA=%d SCL=%d\n", cfg.pinTouchSda,
                cfg.pinTouchScl);
  int found = 0;
  if (Wire.begin(cfg.pinTouchSda, cfg.pinTouchScl, 100000)) {
    for (uint8_t address = 1; address < 0x7F; ++address) {
      Wire.beginTransmission(address);
      if (Wire.endTransmission() == 0) {
        Serial.printf("  found 0x%02X\n", address);
        ++found;
      }
    }
  }
  Serial.printf("scan complete: %d devices; expected GT911 at 0x5D or 0x14\n",
                found);
#else
  Serial.printf("Scanning C6 discriminator I2C on SDA=%d SCL=%d\n",
                board::PIN_PROBE_SDA, board::PIN_PROBE_SCL);
  int found = 0;
  board::Variant variant = boarddetect::probe(true, &found);
  const board::Config &cfg = board::configFor(variant);
  Serial.printf("VERDICT: %s target=%s board=%s devices=%d\n", cfg.name,
                board::targetToken(variant), board::variantToken(variant), found);
#endif
}

void loop() {
  delay(5000);
  Serial.println("(probe complete; reset to repeat)");
}
