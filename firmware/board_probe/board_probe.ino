// Read-only carrier diagnostic. It writes no flash and draws nothing. On P4
// it briefly brings up the DSI command bus to read the panel controller's ID,
// which is how that family tells its carriers apart.
#include <Arduino.h>
#include <Wire.h>
#include <esp_mac.h>

#include <board_config.h>
#include <board_detect.h>
#include <platform_config.h>

void setup() {
  Serial.begin(115200);
#if !defined(CONFIG_IDF_TARGET_ESP32P4) && ARDUINO_USB_CDC_ON_BOOT
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
  // Both P4 carriers share this bus; only the DSI panel ID tells them apart.
  const int8_t sda = board::CONFIG_P4_4B.pinTouchSda;
  const int8_t scl = board::CONFIG_P4_4B.pinTouchScl;
  Serial.printf("I2C scan only: SDA=%d SCL=%d\n", sda, scl);
  int found = 0;
  if (Wire.begin(sda, scl, 100000)) {
    for (uint8_t address = 1; address < 0x7F; ++address) {
      Wire.beginTransmission(address);
      if (Wire.endTransmission() == 0) {
        Serial.printf("  found 0x%02X\n", address);
        ++found;
      }
    }
    Wire.end();
  }
  Serial.printf("scan complete: %d devices; expected GT911 at 0x5D or 0x14\n",
                found);
  int candidates = 0;
  const board::Variant variant = boarddetect::probe(true, &candidates);
  Serial.printf("VERDICT: target=%s board=%s candidates=%d\n",
                board::targetToken(variant), board::variantToken(variant),
                candidates);
#else
#if defined(CONFIG_IDF_TARGET_ESP32S3)
  Serial.println("Scanning S3 profile discriminator buses");
#else
  Serial.printf("Scanning C6 discriminator I2C on SDA=%d SCL=%d\n",
                board::PIN_PROBE_SDA, board::PIN_PROBE_SCL);
#endif
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
