#include "camera_service.h"

#include <Arduino.h>
#include <esp_camera.h>

#include <board_config.h>

#include "app_state.h"
#include "camera_protocol.h"
#include "display_power.h"
#include "net_link.h"

namespace {

const board::GeneratedCamera *camera = nullptr;
bool available = false;
bool requested = false;
cameraproto::Resolution resolution = cameraproto::Resolution::Qvga;
uint16_t nextFrameId = 0;
uint32_t lastFrameAt = 0;

framesize_t frameSize(cameraproto::Resolution value) {
  return value == cameraproto::Resolution::Vga ? FRAMESIZE_VGA : FRAMESIZE_QVGA;
}

bool applyResolution() {
  sensor_t *sensor = esp_camera_sensor_get();
  if (!sensor) return false;
  return sensor->set_framesize(sensor, frameSize(resolution)) == 0;
}

}  // namespace

bool startCameraService() {
  camera = bcfg ? board::generatedCamera(bcfg->variant) : nullptr;
  if (!camera || !camera->present) return false;

  camera_config_t config = {};
  config.ledc_channel = LEDC_CHANNEL_0;
  config.ledc_timer = LEDC_TIMER_0;
  config.pin_d0 = camera->d0;
  config.pin_d1 = camera->d1;
  config.pin_d2 = camera->d2;
  config.pin_d3 = camera->d3;
  config.pin_d4 = camera->d4;
  config.pin_d5 = camera->d5;
  config.pin_d6 = camera->d6;
  config.pin_d7 = camera->d7;
  config.pin_xclk = camera->xclk;
  config.pin_pclk = camera->pclk;
  config.pin_vsync = camera->vsync;
  config.pin_href = camera->href;
  config.pin_sccb_sda = camera->sccbSda;
  config.pin_sccb_scl = camera->sccbScl;
  config.pin_pwdn = camera->pwdn;
  config.pin_reset = camera->reset;
  config.xclk_freq_hz = 20000000;
  config.pixel_format = PIXFORMAT_JPEG;
  config.frame_size = frameSize(resolution);
  config.jpeg_quality = 12;
  config.fb_count = psramFound() ? 2 : 1;
  config.fb_location = psramFound() ? CAMERA_FB_IN_PSRAM : CAMERA_FB_IN_DRAM;
  config.grab_mode = CAMERA_GRAB_LATEST;

  if (esp_camera_init(&config) != ESP_OK) {
    Serial.println("camera: init failed");
    return false;
  }
  available = applyResolution();
  Serial.println(available ? "camera: ready" : "camera: sensor setup failed");
  return available;
}

bool cameraAvailable() {
  return available;
}

bool handleCameraCommand(const uint8_t *data, size_t len) {
  if (!available) return false;
  cameraproto::Command command;
  if (!cameraproto::parseCommand(data, len, command)) return false;
  resolution = command.resolution;
  if (!applyResolution()) return false;
  requested = command.kind == cameraproto::COMMAND_START;
  if (!requested) Serial.println("camera: stopped by sender");
  return true;
}

void serviceCamera() {
  // Camera frames are opt-in. The sender's normal two-second keepalive is the
  // lease: when the app exits or loses the device, stop WiFi JPEG work without
  // waiting for a fresh command packet.
  if (requested && (lastSenderPacketAt == 0 ||
                    (uint32_t)(millis() - lastSenderPacketAt) > 5000)) {
    requested = false;
    Serial.println("camera: sender lease expired");
  }
  if (!available || !requested || hbPort == 0) return;
  const uint32_t now = millis();
  if (now - lastFrameAt < 66) return;  // cap WiFi JPEG work at 15 fps.
  lastFrameAt = now;

  camera_fb_t *frame = esp_camera_fb_get();
  if (!frame || !frame->buf || frame->len == 0) {
    if (frame) esp_camera_fb_return(frame);
    return;
  }
  const size_t fragments =
      (frame->len + cameraproto::MAX_FRAGMENT_PAYLOAD - 1) /
      cameraproto::MAX_FRAGMENT_PAYLOAD;
  if (fragments == 0 || fragments > cameraproto::MAX_FRAGMENTS) {
    esp_camera_fb_return(frame);
    return;
  }
  const uint16_t frameId = nextFrameId++;
  uint8_t packet[cameraproto::FRAME_HEADER_BYTES +
                 cameraproto::MAX_FRAGMENT_PAYLOAD];
  for (size_t index = 0, offset = 0; index < fragments; ++index) {
    const size_t payload = min(cameraproto::MAX_FRAGMENT_PAYLOAD,
                               frame->len - offset);
    const size_t header = cameraproto::writeFrameHeader(
        packet, sizeof(packet), resolution, frameId, (uint16_t)index,
        (uint16_t)fragments);
    if (header == 0) break;
    memcpy(packet + header, frame->buf + offset, payload);
    sendToSender(packet, header + payload);
    offset += payload;
  }
  esp_camera_fb_return(frame);
}
