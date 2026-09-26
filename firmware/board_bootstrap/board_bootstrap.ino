// Descriptor-free carrier discovery firmware.
//
// Startup is input-only: no panel bus, backlight, reset, power, or arbitrary
// GPIO output is configured. I2C commands release Wire and return both pins to
// INPUT. Commands that can drive hardware require the literal CONFIRM token;
// tools/espdisp.py prints the exact pins and levels first.
#include <Arduino.h>
#include <Wire.h>
#include <driver/gpio.h>
#include <esp_heap_caps.h>
#include <esp_lcd_panel_io.h>
#include <esp_mac.h>

#include "bootstrap_protocol.h"

// board_config.h's P4 compile guard normally requires the one shipping carrier
// selector. The bootstrap constructs a runtime candidate Config and never reads
// CONFIG_P4_4B, but the selector is still needed to compile the shared DSI
// backend and its types.
#if defined(CONFIG_IDF_TARGET_ESP32P4) && !defined(ESPDISP_BOARD_P4_4B)
#define ESPDISP_BOARD_P4_4B 1
#endif

#include <board_config.h>
#include <display_backend.h>

static const size_t LINE_BYTES = 1024;
static const size_t DMA_BYTES = 16384;
static char lineBuffer[LINE_BYTES];
static size_t lineLength = 0;

static board::PanelConfig candidatePanel = {};
static board::Config candidateConfig = {};
static esp_lcd_panel_io_handle_t panelIo = nullptr;
static esp_lcd_panel_handle_t panel = nullptr;
static uint8_t *framebuffer = nullptr;
static size_t framebufferBytes = 0;
static bool panelReady = false;
static volatile int dmaInFlight = 0;
#if !defined(CONFIG_IDF_TARGET_ESP32P4)
DMA_ATTR static uint8_t dmaBuffer[DMA_BYTES];
#endif

struct PanelValues {
  char driver[16] = "";
  char bus[16] = "";
  long width = 0;
  long height = 0;
  long clock = 0;
  long mode = 0;
  long col = 0;
  long row = 0;
  long invert = 0;
  long lanes = 0;
  long laneMbps = 0;
  long hbp = 0;
  long hpw = 0;
  long hfp = 0;
  long vbp = 0;
  long vpw = 0;
  long vfp = 0;
  long sclk = -1;
  long mosi = -1;
  long data1 = -1;
  long data2 = -1;
  long data3 = -1;
  long cs = -1;
  long dc = -1;
  long rst = -1;
  long bl = -1;
  long blEnable = -1;
  long blInvert = 0;
  long i2cSda = -1;
  long i2cScl = -1;
  long panelExio = 0;
};

static bool IRAM_ATTR onTransferDone(esp_lcd_panel_io_handle_t,
                                    esp_lcd_panel_io_event_data_t *, void *) {
  if (dmaInFlight > 0) dmaInFlight--;
  return false;
}

static void ok(const char *payload) {
  Serial.print("BOOTOK ");
  Serial.println(payload);
}

static void error(const char *message) {
  Serial.print("BOOTERR {\"error\":\"");
  Serial.print(message);
  Serial.println("\"}");
}

static bool parseLong(const char *text, long &value) {
  return bootstrapproto::parseBoundedLong(text, LONG_MIN, LONG_MAX, value);
}

static bool validPin(long pin) {
  return pin >= 0 && pin <= 127 && GPIO_IS_VALID_GPIO((gpio_num_t)pin);
}

static bool validOptionalPin(long pin) {
  return pin == -1 || validPin(pin);
}

static bool distinctPins(const long *pins, size_t count) {
  for (size_t i = 0; i < count; ++i) {
    if (pins[i] < 0) continue;
    for (size_t j = i + 1; j < count; ++j) {
      if (pins[i] == pins[j]) return false;
    }
  }
  return true;
}

static bool requireConfirm(char **tokens, int count) {
  if (count < 2 || strcmp(tokens[1], "CONFIRM") != 0) {
    error("drive command requires literal CONFIRM");
    return false;
  }
  return true;
}

static bool startI2c(int sda, int scl, uint32_t frequency = 100000) {
  if (!validPin(sda) || !validPin(scl) || sda == scl) return false;
  if (Wire.begin(sda, scl, frequency)) return true;
  Wire.end();
  pinMode(sda, INPUT);
  pinMode(scl, INPUT);
  return false;
}

static void releaseI2c(int sda, int scl) {
  Wire.end();
  if (validPin(sda)) pinMode(sda, INPUT);
  if (validPin(scl)) pinMode(scl, INPUT);
}

static bool readI2cRegister(uint8_t address, uint16_t reg, uint8_t regWidth,
                            uint8_t *out, size_t len) {
  Wire.beginTransmission(address);
  if (regWidth == 2) Wire.write((uint8_t)(reg >> 8));
  Wire.write((uint8_t)reg);
  if (Wire.endTransmission() != 0) return false;
  Wire.requestFrom(address, len);
  if (Wire.available() != (int)len) return false;
  Wire.readBytes(out, len);
  return true;
}

static bool writeI2cRegister(uint8_t address, uint16_t reg, uint8_t regWidth,
                             const uint8_t *data, size_t len) {
  Wire.beginTransmission(address);
  if (regWidth == 2) Wire.write((uint8_t)(reg >> 8));
  Wire.write((uint8_t)reg);
  for (size_t i = 0; i < len; ++i) Wire.write(data[i]);
  return Wire.endTransmission() == 0;
}

static bool tcaSetOutput(uint8_t address, uint8_t exio, bool high) {
  if (exio < 1 || exio > 8) return false;
  uint8_t output = 0;
  uint8_t config = 0;
  if (!readI2cRegister(address, 0x01, 1, &output, 1) ||
      !readI2cRegister(address, 0x03, 1, &config, 1)) {
    return false;
  }
  const uint8_t bit = (uint8_t)(1u << (exio - 1));
  output = high ? (uint8_t)(output | bit) : (uint8_t)(output & ~bit);
  config &= (uint8_t)~bit;
  return writeI2cRegister(address, 0x01, 1, &output, 1) &&
         writeI2cRegister(address, 0x03, 1, &config, 1);
}

static void handleInfo() {
  uint8_t identity[6] = {0};
#if defined(CONFIG_IDF_TARGET_ESP32P4)
  esp_efuse_mac_get_default(identity);
#else
  esp_read_mac(identity, ESP_MAC_WIFI_STA);
#endif
  char payload[256];
  snprintf(
      payload, sizeof(payload),
      "{\"chip\":\"%s\",\"revision\":%d,\"flash_bytes\":%lu,"
      "\"psram_bytes\":%lu,\"base_mac\":\"%02x:%02x:%02x:%02x:%02x:%02x\"}",
      ESP.getChipModel(), ESP.getChipRevision(),
      (unsigned long)ESP.getFlashChipSize(),
      (unsigned long)ESP.getPsramSize(), identity[0], identity[1], identity[2],
      identity[3], identity[4], identity[5]);
  // Match esptool's normalized tokens rather than Arduino's display spelling.
  for (char *p = payload; *p != '\0'; ++p) {
    if (*p >= 'A' && *p <= 'Z') *p = (char)(*p - 'A' + 'a');
    if (*p == '-') memmove(p, p + 1, strlen(p));
  }
  ok(payload);
}

static void handleI2cScan(char **tokens, int count) {
  if (!requireConfirm(tokens, count) || count != 5) return;
  bootstrapproto::I2cScanArgs args = {};
  if (!bootstrapproto::parseI2cScanArgs(tokens[3], tokens[4], args) ||
      !validPin(args.sda) || !validPin(args.scl) ||
      !startI2c(args.sda, args.scl)) {
    error("I2C scan bus would not start");
    return;
  }
  char addresses[512] = "";
  size_t used = 0;
  for (uint8_t address = 0x08; address <= 0x77; ++address) {
    Wire.beginTransmission(address);
    if (Wire.endTransmission() != 0) continue;
    const int written = snprintf(
        addresses + used, sizeof(addresses) - used, "%s%u",
        used == 0 ? "" : ",", (unsigned)address);
    if (written < 0 || (size_t)written >= sizeof(addresses) - used) break;
    used += (size_t)written;
  }
  releaseI2c(args.sda, args.scl);
  char payload[600];
  snprintf(payload, sizeof(payload), "{\"addresses\":[%s]}", addresses);
  ok(payload);
}

static void handleI2cRead(char **tokens, int count) {
  if (!requireConfirm(tokens, count) || count != 9) return;
  bootstrapproto::I2cReadArgs args = {};
  if (!bootstrapproto::parseI2cReadArgs(
          tokens[3], tokens[4], tokens[5], tokens[6], tokens[7], tokens[8],
          args) ||
      !validPin(args.sda) || !validPin(args.scl) ||
      !startI2c(args.sda, args.scl)) {
    error("I2C_READ arguments are outside safe bounds");
    return;
  }
  uint8_t data[32] = {0};
  const bool readOk = readI2cRegister(
      args.address, args.reg, args.regWidth, data, args.length);
  releaseI2c(args.sda, args.scl);
  if (!readOk) {
    error("I2C register read failed");
    return;
  }
  char hex[65] = "";
  for (size_t i = 0; i < args.length; ++i) {
    snprintf(hex + i * 2, sizeof(hex) - (size_t)i * 2, "%02x", data[i]);
  }
  char payload[96];
  snprintf(payload, sizeof(payload), "{\"data\":\"%s\"}", hex);
  ok(payload);
}

static void handleGpioWatch(char **tokens, int count) {
  if (count != 3) {
    error("GPIO_WATCH expects duration_ms pin,pin");
    return;
  }
  long duration = 0;
  if (!parseLong(tokens[1], duration) || duration < 100 || duration > 30000) {
    error("GPIO_WATCH duration must be 100..30000ms");
    return;
  }
  int pins[32] = {0};
  int initial[32] = {0};
  int pinCount = 0;
  char *save = nullptr;
  for (char *item = strtok_r(tokens[2], ",", &save);
       item != nullptr && pinCount < 32;
       item = strtok_r(nullptr, ",", &save)) {
    long pin = 0;
    if (!parseLong(item, pin) || !validPin(pin)) {
      error("GPIO_WATCH includes an invalid pin");
      return;
    }
    pins[pinCount] = (int)pin;
    pinMode((int)pin, INPUT);
    initial[pinCount] = digitalRead((int)pin);
    pinCount++;
  }
  if (pinCount == 0) {
    error("GPIO_WATCH has no pins");
    return;
  }
  const uint32_t started = millis();
  int changedPin = -1;
  int changedFrom = 0;
  int changedTo = 0;
  while ((uint32_t)(millis() - started) < (uint32_t)duration) {
    for (int i = 0; i < pinCount; ++i) {
      const int level = digitalRead(pins[i]);
      if (level != initial[i]) {
        changedPin = pins[i];
        changedFrom = initial[i];
        changedTo = level;
        break;
      }
    }
    if (changedPin >= 0) break;
    delay(2);
  }
  if (changedPin < 0) {
    error("GPIO watch saw no level change");
    return;
  }
  char payload[96];
  snprintf(payload, sizeof(payload),
           "{\"pin\":%d,\"from\":%d,\"to\":%d}",
           changedPin, changedFrom, changedTo);
  ok(payload);
}

static void handleImuRead(char **tokens, int count) {
  if (!requireConfirm(tokens, count) || count != 5) return;
  bootstrapproto::ImuArgs args = {};
  if (!bootstrapproto::parseImuArgs(
          tokens[2], tokens[3], tokens[4], args) ||
      !validPin(args.sda) || !validPin(args.scl) ||
      !startI2c(args.sda, args.scl, 400000)) {
    error("IMU_READ arguments are invalid");
    return;
  }
  uint8_t data[6] = {0};
  const bool readOk = readI2cRegister(
      args.address, 0x35, 1, data, sizeof(data));
  releaseI2c(args.sda, args.scl);
  if (!readOk) {
    error("IMU raw vector read failed");
    return;
  }
  const int16_t x = (int16_t)((uint16_t)data[0] | ((uint16_t)data[1] << 8));
  const int16_t y = (int16_t)((uint16_t)data[2] | ((uint16_t)data[3] << 8));
  const int16_t z = (int16_t)((uint16_t)data[4] | ((uint16_t)data[5] << 8));
  char payload[96];
  snprintf(payload, sizeof(payload), "{\"x\":%d,\"y\":%d,\"z\":%d}", x, y, z);
  ok(payload);
}

static void handleImuConfig(char **tokens, int count) {
  if (!requireConfirm(tokens, count) || count != 5) return;
  bootstrapproto::ImuArgs args = {};
  if (!bootstrapproto::parseImuArgs(
          tokens[2], tokens[3], tokens[4], args) ||
      !validPin(args.sda) || !validPin(args.scl) ||
      !startI2c(args.sda, args.scl, 400000)) {
    error("IMU_CONFIG arguments are invalid");
    return;
  }
  uint8_t identity = 0;
  bool configured = readI2cRegister(
      args.address, 0x00, 1, &identity, 1) && identity == 0x05;
  const uint8_t reset = 0xB0;
  if (configured) {
    configured = writeI2cRegister(
        args.address, 0x60, 1, &reset, 1);
  }
  delay(20);
  const uint8_t ctrl1 = 0x60;
  const uint8_t ctrl2 = 0x13;
  const uint8_t ctrl7 = 0x01;
  if (configured) {
    configured =
        writeI2cRegister(args.address, 0x02, 1, &ctrl1, 1) &&
        writeI2cRegister(args.address, 0x03, 1, &ctrl2, 1) &&
        writeI2cRegister(args.address, 0x08, 1, &ctrl7, 1);
  }
  delay(10);
  releaseI2c(args.sda, args.scl);
  if (!configured) {
    error("WHOAMI-confirmed QMI8658 configuration failed");
    return;
  }
  ok("{\"status\":\"ok\"}");
}

static bool assignPanelValue(PanelValues &values, char *assignment) {
  char *equals = strchr(assignment, '=');
  if (equals == nullptr) return false;
  *equals = '\0';
  const char *key = assignment;
  const char *raw = equals + 1;
  if (strcmp(key, "driver") == 0) {
    strlcpy(values.driver, raw, sizeof(values.driver));
    return true;
  }
  if (strcmp(key, "bus") == 0) {
    strlcpy(values.bus, raw, sizeof(values.bus));
    return true;
  }
  long parsed = 0;
  if (!parseLong(raw, parsed)) return false;
#define PANEL_NUMBER(name, field) \
  if (strcmp(key, name) == 0) { values.field = parsed; return true; }
  PANEL_NUMBER("width", width)
  PANEL_NUMBER("height", height)
  PANEL_NUMBER("clock", clock)
  PANEL_NUMBER("mode", mode)
  PANEL_NUMBER("col", col)
  PANEL_NUMBER("row", row)
  PANEL_NUMBER("invert", invert)
  PANEL_NUMBER("lanes", lanes)
  PANEL_NUMBER("lane_mbps", laneMbps)
  PANEL_NUMBER("hbp", hbp)
  PANEL_NUMBER("hpw", hpw)
  PANEL_NUMBER("hfp", hfp)
  PANEL_NUMBER("vbp", vbp)
  PANEL_NUMBER("vpw", vpw)
  PANEL_NUMBER("vfp", vfp)
  PANEL_NUMBER("sclk", sclk)
  PANEL_NUMBER("mosi", mosi)
  PANEL_NUMBER("data1", data1)
  PANEL_NUMBER("data2", data2)
  PANEL_NUMBER("data3", data3)
  PANEL_NUMBER("cs", cs)
  PANEL_NUMBER("dc", dc)
  PANEL_NUMBER("rst", rst)
  PANEL_NUMBER("bl", bl)
  PANEL_NUMBER("bl_enable", blEnable)
  PANEL_NUMBER("bl_invert", blInvert)
  PANEL_NUMBER("i2c_sda", i2cSda)
  PANEL_NUMBER("i2c_scl", i2cScl)
  PANEL_NUMBER("panel_exio", panelExio)
#undef PANEL_NUMBER
  return false;
}

static bool selectPanelTypes(const PanelValues &values) {
  if (strcmp(values.bus, "spi") == 0) {
    candidatePanel.bus = board::PanelBus::Spi;
  } else if (strcmp(values.bus, "qspi") == 0) {
    candidatePanel.bus = board::PanelBus::Qspi;
  } else if (strcmp(values.bus, "mipi_dsi") == 0) {
    candidatePanel.bus = board::PanelBus::MipiDsi;
  } else {
    return false;
  }
  if (strcmp(values.driver, "st7789") == 0) {
    candidatePanel.driver = board::PanelDriver::St7789;
    candidatePanel.profile = values.width == 172
        ? board::PanelProfile::St7789_172x320
        : board::PanelProfile::St7789_240x240;
  } else if (strcmp(values.driver, "jd9853") == 0) {
    candidatePanel.driver = board::PanelDriver::Jd9853;
    candidatePanel.profile = board::PanelProfile::Jd9853_172x320;
  } else if (strcmp(values.driver, "co5300") == 0) {
    candidatePanel.driver = board::PanelDriver::Co5300;
    candidatePanel.profile = board::PanelProfile::Co5300_466x466;
  } else if (strcmp(values.driver, "st77916") == 0) {
    candidatePanel.driver = board::PanelDriver::St77916;
    candidatePanel.profile = board::PanelProfile::St77916_360x360;
  } else if (strcmp(values.driver, "gc9107") == 0) {
    candidatePanel.driver = board::PanelDriver::Gc9107;
    candidatePanel.profile = values.width == 128
        ? board::PanelProfile::Gc9107_128x128
        : board::PanelProfile::Gc9107_240x240;
  } else if (strcmp(values.driver, "st7703") == 0) {
    candidatePanel.driver = board::PanelDriver::St7703;
    candidatePanel.profile = board::PanelProfile::St7703_720x720;
  } else {
    return false;
  }
#if defined(CONFIG_IDF_TARGET_ESP32P4)
  return candidatePanel.driver == board::PanelDriver::St7703 &&
         candidatePanel.bus == board::PanelBus::MipiDsi;
#elif defined(CONFIG_IDF_TARGET_ESP32S3)
  return candidatePanel.driver == board::PanelDriver::St7789 ||
         candidatePanel.driver == board::PanelDriver::Co5300 ||
         candidatePanel.driver == board::PanelDriver::St77916 ||
         candidatePanel.driver == board::PanelDriver::Gc9107;
#elif defined(CONFIG_IDF_TARGET_ESP32C3)
  return candidatePanel.driver == board::PanelDriver::Gc9107;
#else
  return candidatePanel.driver == board::PanelDriver::St7789 ||
         candidatePanel.driver == board::PanelDriver::Jd9853;
#endif
}

static bool safePanelValues(const PanelValues &values) {
  const long optionalPins[] = {
      values.sclk, values.mosi, values.data1, values.data2, values.data3,
      values.cs, values.dc, values.rst, values.bl, values.blEnable,
      values.i2cSda, values.i2cScl,
  };
  for (long pin : optionalPins) {
    if (!validOptionalPin(pin)) return false;
  }
  if (values.col < 0 || values.col > 255 ||
      values.row < 0 || values.row > 255 ||
      (values.invert != 0 && values.invert != 1) ||
      (values.blInvert != 0 && values.blInvert != 1) ||
      values.panelExio < 0 || values.panelExio > 8) {
    return false;
  }
  if (values.panelExio > 0 &&
      (!validPin(values.i2cSda) || !validPin(values.i2cScl) ||
       values.i2cSda == values.i2cScl)) {
    return false;
  }

  long driven[10] = {-1, -1, -1, -1, -1, -1, -1, -1, -1, -1};
  size_t count = 0;
  if (strcmp(values.bus, "spi") == 0) {
    if (!validPin(values.sclk) || !validPin(values.mosi) ||
        !validPin(values.cs) || !validPin(values.dc) ||
        values.data1 != -1 || values.data2 != -1 || values.data3 != -1) {
      return false;
    }
    driven[count++] = values.sclk;
    driven[count++] = values.mosi;
    driven[count++] = values.cs;
    driven[count++] = values.dc;
  } else if (strcmp(values.bus, "qspi") == 0) {
    if (!validPin(values.sclk) || !validPin(values.mosi) ||
        !validPin(values.data1) || !validPin(values.data2) ||
        !validPin(values.data3) || !validPin(values.cs) ||
        values.dc != -1) {
      return false;
    }
    driven[count++] = values.sclk;
    driven[count++] = values.mosi;
    driven[count++] = values.data1;
    driven[count++] = values.data2;
    driven[count++] = values.data3;
    driven[count++] = values.cs;
  } else if (strcmp(values.bus, "mipi_dsi") == 0) {
    if (values.sclk != -1 || values.mosi != -1 || values.data1 != -1 ||
        values.data2 != -1 || values.data3 != -1 || values.cs != -1 ||
        values.dc != -1 || values.panelExio != 0 ||
        !validPin(values.bl) || values.lanes < 1 || values.lanes > 4 ||
        values.laneMbps < 80 || values.laneMbps > 1500 ||
        values.hbp < 0 || values.hbp > 65535 ||
        values.hpw < 0 || values.hpw > 65535 ||
        values.hfp < 0 || values.hfp > 65535 ||
        values.vbp < 0 || values.vbp > 65535 ||
        values.vpw < 0 || values.vpw > 65535 ||
        values.vfp < 0 || values.vfp > 65535) {
      return false;
    }
    driven[count++] = values.bl;
    driven[count++] = values.blEnable;
  } else {
    return false;
  }
  driven[count++] = values.rst;
  if (values.panelExio > 0) {
    driven[count++] = values.i2cSda;
    driven[count++] = values.i2cScl;
  }
  return distinctPins(driven, count);
}

static const board::PlatformConfig *currentPlatform() {
#if defined(CONFIG_IDF_TARGET_ESP32P4)
  return &board::PLATFORM_ESP32_P4;
#elif defined(CONFIG_IDF_TARGET_ESP32S3)
  return &board::PLATFORM_ESP32_S3;
#elif defined(CONFIG_IDF_TARGET_ESP32C3)
  return &board::PLATFORM_ESP32_C3;
#else
  return &board::PLATFORM_ESP32_C6;
#endif
}

static bool waitDma(uint32_t timeoutMs = 1000) {
  const uint32_t started = millis();
  while (dmaInFlight > 0) {
    if ((uint32_t)(millis() - started) > timeoutMs) {
      dmaInFlight = 0;
      return false;
    }
    delay(1);
  }
  return true;
}

static bool pushRect(int x0, int y0, int x1, int y1,
                     const uint8_t *pixels) {
  dmaInFlight++;
  if (boarddisplay::drawBitmap(
          panel, candidateConfig, x0, y0, x1, y1, pixels) != ESP_OK) {
    dmaInFlight--;
    return false;
  }
  return waitDma();
}

static bool pushFrame() {
  if (!panelReady || framebuffer == nullptr) return false;
#if defined(CONFIG_IDF_TARGET_ESP32P4)
  return pushRect(0, 0, candidatePanel.width, candidatePanel.height, framebuffer);
#else
  const int width = candidatePanel.width;
  const int height = candidatePanel.height;
  const int rowsPerChunk = max(1, (int)(DMA_BYTES / ((size_t)width * 2)));
  for (int y = 0; y < height; y += rowsPerChunk) {
    const int rows = min(rowsPerChunk, height - y);
    const size_t bytes = (size_t)rows * width * 2;
    memcpy(dmaBuffer, framebuffer + (size_t)y * width * 2, bytes);
    if (!pushRect(0, y, width, y + rows, dmaBuffer)) return false;
  }
  return true;
#endif
}

static void fillFrame(uint16_t color) {
  const uint8_t high = (uint8_t)(color >> 8);
  const uint8_t low = (uint8_t)color;
  for (size_t offset = 0; offset < framebufferBytes; offset += 2) {
    framebuffer[offset] = high;
    framebuffer[offset + 1] = low;
  }
}

static void pixel(int x, int y, uint16_t color) {
  if (x < 0 || y < 0 || x >= candidatePanel.width ||
      y >= candidatePanel.height) {
    return;
  }
  const size_t offset = ((size_t)y * candidatePanel.width + x) * 2;
  framebuffer[offset] = (uint8_t)(color >> 8);
  framebuffer[offset + 1] = (uint8_t)color;
}

static void rectangle(int x, int y, int width, int height, uint16_t color) {
  if (width <= 0 || height <= 0) return;
  const int64_t right = (int64_t)x + width;
  const int64_t bottom = (int64_t)y + height;
  const int x0 = x < 0 ? 0 : x;
  const int y0 = y < 0 ? 0 : y;
  const int x1 = right > candidatePanel.width
      ? candidatePanel.width
      : (int)right;
  const int y1 = bottom > candidatePanel.height
      ? candidatePanel.height
      : (int)bottom;
  for (int py = y0; py < y1; ++py) {
    for (int px = x0; px < x1; ++px) pixel(px, py, color);
  }
}

static void handlePanelConfig(char **tokens, int count) {
  if (!requireConfirm(tokens, count)) return;
  if (panelReady) {
    error("panel is already configured; reset before changing candidate pins");
    return;
  }
  PanelValues values;
  for (int i = 2; i < count; ++i) {
    if (!assignPanelValue(values, tokens[i])) {
      error("PANEL_CONFIG contains an unknown or malformed field");
      return;
    }
  }
  if (values.width < 1 || values.width > 1024 ||
      values.height < 1 || values.height > 1024 ||
      values.clock < 1000000 || values.clock > 120000000 ||
      values.mode < 0 || values.mode > 3 || !selectPanelTypes(values) ||
      !safePanelValues(values)) {
    error("candidate panel is unsupported on this confirmed chip family");
    return;
  }

  candidatePanel.width = (uint16_t)values.width;
  candidatePanel.height = (uint16_t)values.height;
  candidatePanel.pixelClockHz = (uint32_t)values.clock;
  candidatePanel.spiMode = (uint8_t)values.mode;
  candidatePanel.colOffset = (uint8_t)values.col;
  candidatePanel.rowOffset = (uint8_t)values.row;
  candidatePanel.orientationOffset = 0;
  candidatePanel.invertColor = values.invert != 0;
  candidatePanel.roundDisplay = values.width == values.height;
  candidatePanel.supportsCommandRotation =
      candidatePanel.bus != board::PanelBus::MipiDsi;
  candidatePanel.dsiDataLanes = (uint8_t)values.lanes;
  candidatePanel.dsiLaneMbps = (uint16_t)values.laneMbps;
  candidatePanel.hsyncBackPorch = (uint16_t)values.hbp;
  candidatePanel.hsyncPulseWidth = (uint16_t)values.hpw;
  candidatePanel.hsyncFrontPorch = (uint16_t)values.hfp;
  candidatePanel.vsyncBackPorch = (uint16_t)values.vbp;
  candidatePanel.vsyncPulseWidth = (uint16_t)values.vpw;
  candidatePanel.vsyncFrontPorch = (uint16_t)values.vfp;

  candidateConfig.variant = board::Variant::Unknown;
  candidateConfig.name = "bootstrap candidate";
  candidateConfig.platform = currentPlatform();
  candidateConfig.panel = &candidatePanel;
  candidateConfig.pinSclk = (int8_t)values.sclk;
  candidateConfig.pinMosi = (int8_t)values.mosi;
  candidateConfig.pinData1 = (int8_t)values.data1;
  candidateConfig.pinData2 = (int8_t)values.data2;
  candidateConfig.pinData3 = (int8_t)values.data3;
  candidateConfig.pinCs = (int8_t)values.cs;
  candidateConfig.pinDc = (int8_t)values.dc;
  candidateConfig.pinRst = (int8_t)values.rst;
  candidateConfig.pinBl = (int8_t)values.bl;
  candidateConfig.pinBootButton = board::NO_PIN;
  candidateConfig.pinRgbLed = board::NO_PIN;
  candidateConfig.touch = board::TouchController::None;
  candidateConfig.pinTouchSda = (int8_t)values.i2cSda;
  candidateConfig.pinTouchScl = (int8_t)values.i2cScl;
  candidateConfig.pinTouchRst = board::NO_PIN;
  candidateConfig.pinTouchInt = board::NO_PIN;
  candidateConfig.power = board::PowerController::None;
  candidateConfig.pinBatteryAdc = board::NO_PIN;
  candidateConfig.batteryAdcScale = 0;
  candidateConfig.pinBatteryEnable = board::NO_PIN;
  candidateConfig.pinChargeStatus = board::NO_PIN;
  candidateConfig.motion = board::MotionController::None;
  candidateConfig.motionXAxis = 0;
  candidateConfig.motionXSign = 1;
  candidateConfig.motionYAxis = 1;
  candidateConfig.motionYSign = 1;
  candidateConfig.panelResetExio = (uint8_t)values.panelExio;
  candidateConfig.touchResetExio = 0;
  candidateConfig.pinBlEnable = (int8_t)values.blEnable;
  candidateConfig.backlightInverted = values.blInvert != 0;
  candidateConfig.pinSerialRx = board::NO_PIN;
  candidateConfig.pinSerialTx = board::NO_PIN;

  framebufferBytes = (size_t)values.width * values.height * 2;
  framebuffer = (uint8_t *)heap_caps_malloc(
      framebufferBytes, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
  if (framebuffer == nullptr) {
    framebuffer = (uint8_t *)heap_caps_malloc(
        framebufferBytes, MALLOC_CAP_8BIT);
  }
  if (framebuffer == nullptr) {
    error("candidate framebuffer allocation failed");
    return;
  }
  if (!boarddisplay::init(
          candidateConfig, SPI2_HOST, framebufferBytes, onTransferDone,
          nullptr, &panelIo, &panel)) {
    free(framebuffer);
    framebuffer = nullptr;
    framebufferBytes = 0;
    error("candidate panel initialization failed");
    return;
  }
  boarddisplay::applyOrientation(panel, candidateConfig, false, 0);
  panelReady = true;
  ok("{\"status\":\"ok\"}");
}

static void handlePanelReadId(char **tokens, int count) {
  if (!requireConfirm(tokens, count)) return;
  if (!panelReady || panelIo == nullptr) {
    error("panel is not configured");
    return;
  }
  if (candidatePanel.bus != board::PanelBus::Spi) {
    ok("{\"supported\":false,\"data\":\"\"}");
    return;
  }
  uint8_t id[3] = {0};
  const esp_err_t result = esp_lcd_panel_io_rx_param(
      panelIo, 0x04, id, sizeof(id));
  if (result != ESP_OK) {
    ok("{\"supported\":false,\"data\":\"\"}");
    return;
  }
  char payload[96];
  snprintf(payload, sizeof(payload),
           "{\"supported\":true,\"data\":\"%02x%02x%02x\"}",
           id[0], id[1], id[2]);
  ok(payload);
}

static void handlePanelFill(char **tokens, int count) {
  if (!requireConfirm(tokens, count)) return;
  if (!panelReady || count != 3) {
    error("PANEL_FILL expects CONFIRM color after panel setup");
    return;
  }
  uint16_t color = 0;
  if (strcmp(tokens[2], "red") == 0) color = 0xF800;
  else if (strcmp(tokens[2], "blue") == 0) color = 0x001F;
  else if (strcmp(tokens[2], "black") == 0) color = 0x0000;
  else if (strcmp(tokens[2], "white") == 0) color = 0xFFFF;
  else {
    error("unsupported fill color");
    return;
  }
  fillFrame(color);
  if (!pushFrame()) {
    error("panel fill transfer failed");
    return;
  }
  ok("{\"status\":\"ok\"}");
}

static void handlePanelEdges(char **tokens, int count) {
  if (!requireConfirm(tokens, count)) return;
  if (!panelReady) {
    error("panel is not configured");
    return;
  }
  bootstrapproto::PanelEdgesArgs args = {};
  const char *assignments[46] = {nullptr};
  for (int i = 2; i < count; ++i) assignments[i - 2] = tokens[i];
  if (!bootstrapproto::parsePanelEdgesArgs(
          assignments, (size_t)(count - 2),
          candidatePanel.width, candidatePanel.height, args)) {
    error("PANEL_EDGES arguments are invalid");
    return;
  }
  boarddisplay::applyOrientation(
      panel, candidateConfig, false, (uint8_t)args.orientation);
  fillFrame(0x0000);
  rectangle(0, 0, candidatePanel.width, 3, 0xFFFF);
  rectangle(0, candidatePanel.height - 3, candidatePanel.width, 3, 0xFFFF);
  rectangle(0, 0, 3, candidatePanel.height, 0xFFFF);
  rectangle(candidatePanel.width - 3, 0, 3, candidatePanel.height, 0xFFFF);
  if (args.hasMarker) {
    rectangle(args.markerX - 8, args.markerY - 1, 17, 3, 0xFFE0);
    rectangle(args.markerX - 1, args.markerY - 8, 3, 17, 0xFFE0);
  }
  if (!pushFrame()) {
    error("edge-marker transfer failed");
    return;
  }
  ok("{\"status\":\"ok\"}");
}

static void handlePanelGlyph(char **tokens, int count) {
  if (!requireConfirm(tokens, count)) return;
  if (!panelReady) {
    error("panel is not configured");
    return;
  }
  boarddisplay::applyOrientation(panel, candidateConfig, false, 0);
  fillFrame(0x0000);
  const int cx = candidatePanel.width / 2;
  const int cy = candidatePanel.height / 2;
  rectangle(cx - 45, cy - 4, 70, 9, 0xFFFF);
  for (int i = 0; i < 25; ++i) {
    rectangle(cx + 25 - i, cy - 24 + i, 3, 3, 0xF800);
    rectangle(cx + 25 - i, cy + 24 - i, 3, 3, 0xF800);
  }
  if (!pushFrame()) {
    error("mirror glyph transfer failed");
    return;
  }
  ok("{\"status\":\"ok\"}");
}

static void handleBacklight(char **tokens, int count) {
  if (!requireConfirm(tokens, count) || count != 4) return;
  long pin = 0, level = 0;
  if (!bootstrapproto::parseBoundedLong(tokens[2], -1, 127, pin) ||
      !bootstrapproto::parseBoundedLong(tokens[3], 0, 255, level) ||
      (pin >= 0 && !validPin(pin))) {
    error("BACKLIGHT expects pin level with level 0..255");
    return;
  }
  bool changed = false;
  if (pin == -1) {
    changed = panelReady &&
              boarddisplay::setBrightness(
                  panel, candidateConfig, (uint8_t)level);
  } else if (validPin(pin)) {
    pinMode((int)pin, OUTPUT);
    analogWrite((int)pin, (int)level);
    changed = true;
  }
  if (!changed) {
    error("backlight target is unavailable");
    return;
  }
  ok("{\"status\":\"ok\"}");
}

static void handleBacklightEnable(char **tokens, int count) {
  if (!requireConfirm(tokens, count) || count != 4) return;
  long pin = 0, level = 0;
  if (!bootstrapproto::parseBoundedLong(tokens[2], 0, 127, pin) ||
      !bootstrapproto::parseBoundedLong(tokens[3], 0, 1, level) ||
      !validPin(pin)) {
    error("BACKLIGHT_ENABLE expects valid_pin level_0_or_1");
    return;
  }
  pinMode((int)pin, OUTPUT);
  digitalWrite((int)pin, level ? HIGH : LOW);
  ok("{\"status\":\"ok\"}");
}

static void handleTouchConfig(char **tokens, int count) {
  if (!requireConfirm(tokens, count) || count != 11) return;
  bootstrapproto::TouchConfigArgs args = {};
  if (!bootstrapproto::parseTouchConfigArgs(
          tokens[2], tokens[3], tokens[4], tokens[5], tokens[6], tokens[7],
          tokens[8], tokens[9], tokens[10], args) ||
      !validPin(args.sda) || !validPin(args.scl) ||
      !validOptionalPin(args.reset) || !validOptionalPin(args.interrupt) ||
      !startI2c(args.sda, args.scl, 400000)) {
    error("TOUCH_CONFIG arguments are invalid");
    return;
  }
  bool configured = true;
  if (args.exio > 0) {
    configured = tcaSetOutput(args.expanderAddress, args.exio, false);
    delay(10);
    configured = tcaSetOutput(args.expanderAddress, args.exio, true) &&
                 configured;
    delay(50);
  } else if (args.reset >= 0 && !args.sharedReset) {
    pinMode(args.reset, OUTPUT);
    digitalWrite(args.reset, LOW);
    delay(args.controller == bootstrapproto::TouchController::Axs5106l
              ? 200
              : 10);
    digitalWrite(args.reset, HIGH);
    delay(args.controller == bootstrapproto::TouchController::Axs5106l
              ? 300
              : 50);
  }
  if (args.interrupt >= 0) pinMode(args.interrupt, INPUT);
  if (configured &&
      args.controller == bootstrapproto::TouchController::Cst9217) {
    configured = writeI2cRegister(
        args.address, 0xD101, 2, nullptr, 0);
    delay(10);
  }
  releaseI2c(args.sda, args.scl);
  if (!configured) {
    error("touch reset/configuration failed");
    return;
  }
  ok("{\"status\":\"ok\"}");
}

static void handleTouchRead(char **tokens, int count) {
  if (!requireConfirm(tokens, count) || count != 6) return;
  bootstrapproto::TouchReadArgs args = {};
  if (!bootstrapproto::parseTouchReadArgs(
          tokens[2], tokens[3], tokens[4], tokens[5], args) ||
      !validPin(args.sda) || !validPin(args.scl) ||
      !startI2c(args.sda, args.scl, 400000)) {
    error("TOUCH_READ arguments are invalid");
    return;
  }
  uint16_t x = 0;
  uint16_t y = 0;
  bool readOk = false;
  if (args.controller == bootstrapproto::TouchController::Axs5106l) {
    uint8_t data[14] = {0};
    readOk = readI2cRegister(args.address, 0x01, 1, data, sizeof(data));
    if (readOk && data[1] > 0) {
      x = (uint16_t)(((data[2] & 0x0F) << 8) | data[3]);
      y = (uint16_t)(((data[4] & 0x0F) << 8) | data[5]);
    } else {
      readOk = false;
    }
  } else if (args.controller == bootstrapproto::TouchController::Cst816) {
    uint8_t data[6] = {0};
    readOk = readI2cRegister(args.address, 0x01, 1, data, sizeof(data));
    if (readOk && data[1] > 0) {
      x = (uint16_t)(((data[2] & 0x0F) << 8) | data[3]);
      y = (uint16_t)(((data[4] & 0x0F) << 8) | data[5]);
    } else {
      readOk = false;
    }
  } else if (args.controller == bootstrapproto::TouchController::Gt911) {
    uint8_t status = 0;
    uint8_t point[8] = {0};
    readOk = readI2cRegister(
        args.address, 0x814E, 2, &status, 1);
    if (readOk && (status & 0x80) && (status & 0x0F)) {
      readOk = readI2cRegister(
          args.address, 0x8150, 2, point, sizeof(point));
      x = (uint16_t)(point[0] | ((uint16_t)point[1] << 8));
      y = (uint16_t)(point[2] | ((uint16_t)point[3] << 8));
    } else {
      readOk = false;
    }
    const uint8_t clear = 0;
    writeI2cRegister(args.address, 0x814E, 2, &clear, 1);
  } else if (args.controller == bootstrapproto::TouchController::Cst9217) {
    uint8_t data[15] = {0};
    readOk = readI2cRegister(
        args.address, 0xD000, 2, data, sizeof(data));
    const uint8_t ack = 0xAB;
    writeI2cRegister(args.address, 0xD000, 2, &ack, 1);
    if (readOk && data[6] == 0xAB && (data[5] & 0x7F) > 0) {
      x = (uint16_t)((data[1] << 4) | (data[3] >> 4));
      y = (uint16_t)((data[2] << 4) | (data[3] & 0x0F));
    } else {
      readOk = false;
    }
  }
  releaseI2c(args.sda, args.scl);
  if (!readOk) {
    error("no pressed touch sample was available");
    return;
  }
  char payload[64];
  snprintf(payload, sizeof(payload), "{\"x\":%u,\"y\":%u}",
           (unsigned)x, (unsigned)y);
  ok(payload);
}

static void handleAdcRead(char **tokens, int count) {
  if (count != 2) {
    error("ADC_READ expects pin");
    return;
  }
  long pin = 0;
  if (!parseLong(tokens[1], pin) || !validPin(pin)) {
    error("ADC_READ pin is invalid");
    return;
  }
  pinMode((int)pin, INPUT);
  const int raw = analogRead((int)pin);
  const uint32_t millivolts = analogReadMilliVolts((int)pin);
  char payload[96];
  snprintf(payload, sizeof(payload),
           "{\"raw\":%d,\"millivolts\":%lu}",
           raw, (unsigned long)millivolts);
  ok(payload);
}

static void dispatch(char *line) {
  char *tokens[48] = {nullptr};
  int count = 0;
  char *save = nullptr;
  for (char *token = strtok_r(line, " \t", &save);
       token != nullptr && count < 48;
       token = strtok_r(nullptr, " \t", &save)) {
    tokens[count++] = token;
  }
  if (count == 0) return;
  if (!bootstrapproto::commandAuthorized(
          tokens[0], count > 1 ? tokens[1] : nullptr)) {
    error("drive command requires literal CONFIRM");
    return;
  }
  if (strcmp(tokens[0], "INFO") == 0) handleInfo();
  else if (strcmp(tokens[0], "I2C_SCAN") == 0) handleI2cScan(tokens, count);
  else if (strcmp(tokens[0], "I2C_READ") == 0) handleI2cRead(tokens, count);
  else if (strcmp(tokens[0], "GPIO_WATCH") == 0) handleGpioWatch(tokens, count);
  else if (strcmp(tokens[0], "IMU_CONFIG") == 0)
    handleImuConfig(tokens, count);
  else if (strcmp(tokens[0], "IMU_READ") == 0) handleImuRead(tokens, count);
  else if (strcmp(tokens[0], "PANEL_CONFIG") == 0)
    handlePanelConfig(tokens, count);
  else if (strcmp(tokens[0], "PANEL_READ_ID") == 0)
    handlePanelReadId(tokens, count);
  else if (strcmp(tokens[0], "PANEL_FILL") == 0)
    handlePanelFill(tokens, count);
  else if (strcmp(tokens[0], "PANEL_EDGES") == 0)
    handlePanelEdges(tokens, count);
  else if (strcmp(tokens[0], "PANEL_GLYPH") == 0)
    handlePanelGlyph(tokens, count);
  else if (strcmp(tokens[0], "BACKLIGHT") == 0)
    handleBacklight(tokens, count);
  else if (strcmp(tokens[0], "BACKLIGHT_ENABLE") == 0)
    handleBacklightEnable(tokens, count);
  else if (strcmp(tokens[0], "TOUCH_CONFIG") == 0)
    handleTouchConfig(tokens, count);
  else if (strcmp(tokens[0], "TOUCH_READ") == 0)
    handleTouchRead(tokens, count);
  else if (strcmp(tokens[0], "ADC_READ") == 0)
    handleAdcRead(tokens, count);
  else error("unknown bootstrap command");
}

void setup() {
  Serial.begin(115200);
#if !defined(CONFIG_IDF_TARGET_ESP32P4) && ARDUINO_USB_CDC_ON_BOOT
  Serial.setTxTimeoutMs(0);
#endif
  const uint32_t started = millis();
  while (!Serial && (uint32_t)(millis() - started) < 8000) delay(50);
  delay(200);
  Serial.println("BOOTSTRAP 1 input-only; drive commands require CONFIRM");
}

void loop() {
  while (Serial.available() > 0) {
    const char incoming = (char)Serial.read();
    if (incoming == '\r') continue;
    if (incoming == '\n') {
      lineBuffer[lineLength] = '\0';
      dispatch(lineBuffer);
      lineLength = 0;
      continue;
    }
    if (lineLength + 1 >= sizeof(lineBuffer)) {
      lineLength = 0;
      error("command line too long");
      continue;
    }
    lineBuffer[lineLength++] = incoming;
  }
  delay(1);
}
