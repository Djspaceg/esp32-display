// Chip/platform capabilities shared by carrier targets.
//
// This header deliberately contains no panel controller, display timing,
// touch-controller, or carrier pin facts. A target composes one platform with
// one panel and one carrier in board_config.h.
#pragma once

#include <stdint.h>

namespace board {

/// A release family's platform. Esp32S3_4M is the S3 4 MiB family (s3-4m):
/// the same chip as Esp32S3 with its own image, partition table and boards.
enum class Platform : uint8_t { Esp32C3, Esp32C6, Esp32S3, Esp32P4, Esp32S3_4M };

/// Whether a family runs on an ESP32-S3, for chip facts (pads, ADC units)
/// that both S3 families share.
constexpr bool isS3Chip(Platform platform) {
  return platform == Platform::Esp32S3 || platform == Platform::Esp32S3_4M;
}
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

#include "generated_platform_config.h"

#if defined(CONFIG_IDF_TARGET_ESP32P4)
static constexpr const PlatformConfig &COMPILED_PLATFORM = PLATFORM_ESP32_P4;
#elif defined(CONFIG_IDF_TARGET_ESP32S3) && defined(ESPDISP_FAMILY_S3_4M)
// The 4 MiB S3 family's build target passes ESPDISP_FAMILY_S3_4M.
static constexpr const PlatformConfig &COMPILED_PLATFORM = PLATFORM_ESP32_S3_4M;
#elif defined(CONFIG_IDF_TARGET_ESP32S3)
static constexpr const PlatformConfig &COMPILED_PLATFORM = PLATFORM_ESP32_S3;
#elif defined(CONFIG_IDF_TARGET_ESP32C3)
static constexpr const PlatformConfig &COMPILED_PLATFORM = PLATFORM_ESP32_C3;
#else
static constexpr const PlatformConfig &COMPILED_PLATFORM = PLATFORM_ESP32_C6;
#endif

}  // namespace board
