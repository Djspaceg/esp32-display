// Chip/platform capabilities shared by carrier targets.
//
// This header deliberately contains no panel controller, display timing,
// touch-controller, or carrier pin facts. A target composes one platform with
// one panel and one carrier in board_config.h.
#pragma once

#include <stdint.h>

namespace board {

enum class Platform : uint8_t { Esp32C6, Esp32S3, Esp32P4 };
enum class WifiTopology : uint8_t { Native, HostedCoprocessor };
enum class IdentitySource : uint8_t { WifiStationMac, EfuseBaseMac };
enum class SerialTransport : uint8_t { NativeUsbCdc, UartBridge };

struct PlatformConfig {
  Platform platform;
  const char *chipToken;
  const char *partitionToken;
  bool usePsramFrameBuffers;
  bool useRawLwipReceiveTask;
  WifiTopology wifi;
  IdentitySource identity;
  SerialTransport serial;
};

static constexpr PlatformConfig PLATFORM_ESP32_C6 = {
    Platform::Esp32C6, "esp32c6", "default-8m", false, false,
    WifiTopology::Native, IdentitySource::WifiStationMac,
    SerialTransport::NativeUsbCdc};
static constexpr PlatformConfig PLATFORM_ESP32_S3 = {
    Platform::Esp32S3, "esp32s3", "universal-8m-ota", true, true,
    WifiTopology::Native, IdentitySource::WifiStationMac,
    SerialTransport::NativeUsbCdc};
static constexpr PlatformConfig PLATFORM_ESP32_P4 = {
    Platform::Esp32P4, "esp32p4", "p4-32m-ota", true, true,
    WifiTopology::HostedCoprocessor, IdentitySource::EfuseBaseMac,
    SerialTransport::UartBridge};

#if defined(CONFIG_IDF_TARGET_ESP32P4)
static constexpr const PlatformConfig &COMPILED_PLATFORM = PLATFORM_ESP32_P4;
#elif defined(CONFIG_IDF_TARGET_ESP32S3)
static constexpr const PlatformConfig &COMPILED_PLATFORM = PLATFORM_ESP32_S3;
#else
static constexpr const PlatformConfig &COMPILED_PLATFORM = PLATFORM_ESP32_C6;
#endif

}  // namespace board
