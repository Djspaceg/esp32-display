// The WiFi coprocessor's own ESP-Hosted firmware, on carriers whose WiFi is a
// C6 behind ESP-Hosted (the P4 family).
//
// The C6 runs whatever ESP-Hosted build its carrier shipped with; the host
// side comes from the Espressif core this firmware is built on. On a 4B whose
// C6 was too old to answer Req_GetCoprocessorFwVersion, against host 2.12.13,
// outgoing WiFi data stopped about 18 minutes into a stream while everything
// else stayed up: frames still arrived, RPCs were answered within 0.5 s, the
// host's TX throttle was clear and every sendto() succeeded, yet nothing the
// board sent reached the LAN (no heartbeat, ARP reply or mDNS answer, and no
// router ping). The same board on Espressif's matching 2.12.13 coprocessor
// image streamed for an hour without it (2026-10-07). So the firmware reports
// the pairing at boot and in CFGSHOW, and CFGC6UPDATE installs the image that
// matches the host.
//
// Everything here is pure, so the decisions are tested on the host
// (test/test_coprocessor_update.cpp); coprocessor_service.cpp and
// coprocessor_ota.cpp do the I/O.
#pragma once

#include <stddef.h>
#include <stdint.h>
#include <string.h>

namespace coprocessor {

/// ESP-Hosted's own packing (ESP_HOSTED_VERSION_VAL).
constexpr uint32_t version(uint32_t major, uint32_t minor, uint32_t patch) {
  return (major << 16) | (minor << 8) | patch;
}

enum class Status : uint8_t {
  Unknown,     // not probed: no hosted coprocessor, or before the probe ran
  Current,     // the coprocessor runs exactly the host's version
  Unreported,  // it did not answer the version request: older than any host
               // this firmware has shipped with
  Older,       // it reported a version below the host's
  Newer,       // it reported a version above the host's
};

/// `answered` is whether Req_GetCoprocessorFwVersion came back at all; a
/// coprocessor that does not implement it predates every host version here.
/// Patch levels count: the 2.12.11 -> 2.12.13 step alone carried an SDIO
/// receive fix, so only an exact match is Current.
inline Status classify(uint32_t hostVersion, bool answered,
                       uint32_t coprocessorVersion) {
  if (!answered) return Status::Unreported;
  if (coprocessorVersion == hostVersion) return Status::Current;
  return coprocessorVersion < hostVersion ? Status::Older : Status::Newer;
}

/// Only an older coprocessor is updated. A newer one is left alone: a
/// downgrade is never what a mismatch warning asks for.
inline bool needsUpdate(Status status) {
  return status == Status::Unreported || status == Status::Older;
}

/// CFGSHOW's c6= token.
inline const char *statusToken(Status status) {
  switch (status) {
    case Status::Current:
      return "current";
    case Status::Unreported:
      return "unreported";
    case Status::Older:
      return "older";
    case Status::Newer:
      return "newer";
    case Status::Unknown:
      break;
  }
  return "unknown";
}

/// One official Espressif coprocessor image: the ESP-Hosted network_adapter
/// build the Espressif core itself points at for this host version
/// (esp32-hal-hosted.c hostedGetUpdateURL). Its length and SHA-256 are pinned
/// here, so a download that differs by one byte is never finalized.
struct Image {
  uint32_t hostVersion;
  const char *url;
  uint32_t length;
  const char *sha256;  // lowercase hex
};

/// Measured 2026-10-07: app descriptor "2.12.13", project network_adapter,
/// built Sep 16 2026 with ESP-IDF v5.5.5, chip id 13 (ESP32-C6).
static constexpr Image IMAGES[] = {
    {version(2, 12, 13),
     "https://espressif.github.io/arduino-esp32/hosted/esp32c6-v2.12.13.bin",
     1226976,
     "f8509949826c197a4fa3c7958943b4e8985cffdfdf4204c2847d8953905121c9"},
};

/// The pinned image for this host, or nullptr. A core upgrade that moves the
/// host version leaves this nullptr until a new image is measured and pinned,
/// so an update can never install a coprocessor build the host was not
/// paired with.
inline const Image *imageForHost(uint32_t hostVersion) {
  for (const Image &image : IMAGES) {
    if (image.hostVersion == hostVersion) return &image;
  }
  return nullptr;
}

/// Whether a finished transfer may be finalized (ota_end, which is what
/// makes the coprocessor boot it): every byte arrived and the digest is the
/// pinned one. Anything else leaves the coprocessor on its current image.
inline bool mayFinalize(const Image &image, uint32_t bytesWritten,
                        const char *sha256Hex) {
  return sha256Hex != nullptr && bytesWritten == image.length &&
         strcmp(sha256Hex, image.sha256) == 0;
}

enum class TransferOutcome : uint8_t {
  Installed,       // finalized and activated: the next C6 reset boots it
  BeginRefused,    // the coprocessor would not start an update
  Stalled,         // the download stopped short
  WriteFailed,     // the coprocessor refused a chunk
  Rejected,        // wrong length or digest: never finalized
  EndRefused,      // the coprocessor's own image check failed
  ActivateFailed,  // finalized but not made the boot image (ESP-Hosted
                   // 2.6+ sets the boot partition in activate, not end)
};

/// Streams the image from `port`'s source into the coprocessor and finalizes
/// it only through mayFinalize. Port is the device's HTTPS stream and
/// ESP-Hosted OTA calls, or a host test's fake:
///   bool begin();                         start the coprocessor's update
///   int read(uint8_t *buf, size_t want);  >0 bytes, 0 none yet, <0 ended
///   bool stalled();                       no byte for too long
///   void digest(const uint8_t *, size_t); SHA-256 of what was read
///   void digestHex(char out[65]);         lowercase hex of that digest
///   bool write(const uint8_t *, size_t);  one chunk to the coprocessor
///   void progress(uint32_t written, uint32_t total);
///   bool end();                           the coprocessor validates it
///   bool activate();                      and makes it the boot image
/// Nothing after a failure reaches end() or activate(), so the coprocessor
/// keeps booting the image it has.
template <typename Port, size_t CHUNK_BYTES = 1400>
TransferOutcome runTransfer(const Image &image, Port &port) {
  if (!port.begin()) return TransferOutcome::BeginRefused;
  uint8_t chunk[CHUNK_BYTES];
  uint32_t written = 0;
  while (written < image.length) {
    // Never more than is left, so an oversized body is not read into the
    // coprocessor; and whole chunks where possible, since newer coprocessors
    // refuse a first write shorter than the image header.
    const uint32_t left = image.length - written;
    const size_t want = left < CHUNK_BYTES ? (size_t)left : CHUNK_BYTES;
    const int got = port.read(chunk, want);
    if (got < 0) return TransferOutcome::Stalled;
    if (got == 0) {
      if (port.stalled()) return TransferOutcome::Stalled;
      continue;
    }
    port.digest(chunk, (size_t)got);
    if (!port.write(chunk, (size_t)got)) return TransferOutcome::WriteFailed;
    written += (uint32_t)got;
    port.progress(written, image.length);
  }
  char hex[65] = {0};
  port.digestHex(hex);
  if (!mayFinalize(image, written, hex)) return TransferOutcome::Rejected;
  if (!port.end()) return TransferOutcome::EndRefused;
  if (!port.activate()) return TransferOutcome::ActivateFailed;
  return TransferOutcome::Installed;
}

inline const char *outcomeText(TransferOutcome outcome) {
  switch (outcome) {
    case TransferOutcome::Installed:
      return "installed";
    case TransferOutcome::BeginRefused:
      return "coprocessor refused to begin; unchanged";
    case TransferOutcome::Stalled:
      return "download stopped short; not finalized, unchanged";
    case TransferOutcome::WriteFailed:
      return "coprocessor refused a chunk; not finalized, unchanged";
    case TransferOutcome::Rejected:
      return "wrong length or digest; not finalized, unchanged";
    case TransferOutcome::EndRefused:
      return "coprocessor rejected the image; unchanged";
    case TransferOutcome::ActivateFailed:
      return "coprocessor did not activate it; still on its old image";
  }
  return "unknown";
}

}  // namespace coprocessor
