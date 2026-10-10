// Firmware update over the stream channel, on the panel: the lock, the flash,
// the digests and the screen around streamupdate::Receiver
// (stream_update.h, where every decision lives and is host-tested).
#pragma once

#include <stddef.h>
#include <stdint.h>

namespace streamupdatesvc {

/// Arm with the stored OTA password, or disarm with nullptr. Only the
/// password's SHA-256 hex is kept, as ArduinoOTA keeps it; NVS is untouched.
void arm(const char *password);
bool armed();

/// The receive path. True when the datagram was an update packet (and has
/// been handled); false for anything else.
bool handleInbound(const uint8_t *data, size_t len, uint32_t remoteIp,
                   uint16_t remotePort);

/// While true, frame packets are refused: an authenticated update owns the
/// panel's screen and its flash.
bool ownsPanel();

/// The loop side. Returns true while an update owns the loop, so loop()
/// skips drawing, serial config and everything else that could touch the
/// panel or the flash.
bool service();

}  // namespace streamupdatesvc
