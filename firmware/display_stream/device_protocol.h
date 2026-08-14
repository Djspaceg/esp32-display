// Versioned device telemetry and management protocol. This file is portable
// and hardware-free so Swift and firmware can share exact byte-vector tests.
#pragma once

#include <stddef.h>
#include <stdint.h>
#include <string.h>

namespace deviceproto {

static const uint8_t INFO_VERSION = 1;
static const uint8_t FRAME_PROTOCOL_VERSION = 2;
static const uint8_t CONTROL_PROTOCOL_VERSION = 1;
static const size_t INFO_PREFIX_BYTES = 27;
static const size_t CONTROL_PACKET_BYTES = 12;
static const size_t ACK_PACKET_BYTES = 12;

enum Capability : uint32_t {
  CAP_BRIGHTNESS = 1u << 0,
  CAP_FLIP = 1u << 1,
  CAP_IDENTIFY = 1u << 2,
  CAP_RESTART = 1u << 3,
  // Accepts a firmware push over WiFi (ArduinoOTA on the LAN, password
  // required). Runtime rather than per-board: a panel with no OTA password does
  // not listen and does not set this, so the bit means "an update can be pushed
  // to this panel now", not "this build was compiled with OTA in it".
  CAP_OTA = 1u << 4,
  CAP_SLEEP_SYNC = 1u << 5,
  CAP_TELEMETRY = 1u << 6,
  // Accepts BrightnessLevel, i.e. any level rather than only high/low.
  // Advertised separately from CAP_BRIGHTNESS so a sender can offer a slider
  // to firmware that supports it and the old toggle to firmware that does
  // not, without either side needing a protocol version bump.
  CAP_BRIGHTNESS_LEVEL = 1u << 7,
  // Accepts ETXT, so the panel can show something chosen by the user while no
  // sender is driving it.
  CAP_IDLE_TEXT = 1u << 8,
  // Emits ETCH, i.e. this panel has a touch screen and reports gestures. A
  // sender should offer touch actions only when this is set, so a panel without
  // touch does not show controls that can never fire.
  CAP_TOUCH = 1u << 9,
  // Classifies a held press as LongPress rather than as nothing. Advertised
  // apart from CAP_TOUCH, like CAP_BRIGHTNESS_LEVEL is from CAP_BRIGHTNESS, so a
  // sender can tell a panel that reports holds from one that only reports taps
  // and swipes - a gesture bound to a hold would otherwise appear to be ignored.
  CAP_TOUCH_LONGPRESS = 1u << 10,
  // Emits EBAT from this board's available battery telemetry source: the
  // 1.75C's AXP2101 PMU or the C6 touch board's battery-voltage ADC. Advertised
  // because it is a per-board fact, not a firmware one, so a sender must not
  // show a battery row for a panel that will never send a reading.
  CAP_BATTERY = 1u << 11,
  // Accepts packed band packets (band_index bit 15): several RLE-compressed
  // or raw band records per datagram, up to MAX_PACKED_PACKET_BYTES. The
  // receive-path ceiling is packets per second, not bytes (measured on the
  // 466x466 S3: ~1826 datagrams/s accepted however fast they are offered),
  // so fewer, denser packets is what raises the frame rate. A capability bit
  // rather than a version bump, per the reasoning at EBAT below: a sender
  // only packs for a panel that advertised it, so every other pairing stays
  // byte-identical on the wire.
  CAP_COMPRESSED_BANDS = 1u << 12,
  // Accepts Rotate, i.e. any quarter turn rather than only the 180 Flip.
  // Advertised only by panels whose glass is square (panelW == panelH): on a
  // rectangular panel a 90-degree mounting turn is what the sender-driven
  // landscape mechanism already expresses, and accepting rotation 1/3 there
  // would fight it. A NEW opcode plus this bit rather than widened Flip
  // values, because old firmware's validControlValue rejects Flip > 1
  // SILENTLY - parseControl returns false, no ack is sent, and a sender
  // could not tell rejection from packet loss. An unknown opcode is refused
  // the same way, but this bit is what stops a sender from ever sending one
  // to firmware that predates it.
  CAP_ROTATE = 1u << 13,
  // Accepts Power, i.e. a user-requested display on/off that is independent
  // of the Mac's own ESLP/EWAK sleep sync and persists across a reboot.
  // ESLP/EWAK exist to follow the Mac's displays; this is the opposite kind
  // of thing - a standing instruction the panel keeps until told otherwise,
  // the way rotation and brightness level already are. Advertised on every
  // board: unlike battery or rotate, a manual "off" is not a hardware fact,
  // it is a capability any panel with a backlight or an AMOLED panel command
  // can honour.
  CAP_POWER = 1u << 14,
  // Accepts tile-stream packets (tile_protocol.h): a 16x16 dirty-tile grid
  // with per-run codec choice (raw / RLE565 / BC1), replacing full-width
  // bands on this panel. Advertised only by board::Variant::AmoledCo5300 -
  // gated on the variant rather than panelW == panelH deliberately, so a
  // hypothetical future square panel on other silicon does not inherit a
  // draw path that was tuned for this board's QSPI and PSRAM (see
  // docs/tile-stream-plan.md section 5). A capability bit rather than a
  // version bump, per the reasoning at EBAT below: a sender only sends
  // tile packets to a panel that advertised it, so every other pairing -
  // including every C6 board - stays byte-identical on the wire.
  //
  // MUTUALLY EXCLUSIVE with CAP_COMPRESSED_BANDS: both formats claim bit 15
  // of the header's second field and are byte-ambiguous past it, so a board
  // advertises exactly one of the two and parses bit-15 packets as that one.
  // Classic unpacked band packets (bit 15 clear) stay accepted everywhere,
  // which is what keeps a tile panel drivable by a sender that predates
  // tiles - slower, never wrong.
  CAP_TILE_STREAM = 1u << 15,
  // This panel's glass is ROUND: pixels outside the frame's inscribed circle
  // are physically not visible and never will be. A per-board hardware fact
  // like CAP_BATTERY, not an "accepts X" - advertised so a sender can stop
  // spending bandwidth and panel paint time on a fifth of the framebuffer
  // nobody can see (181 of the 466x466 panel's 900 tiles, measured on the
  // glass with `espdisp.py tile-test --round-mask`).
  //
  // Nothing in the firmware acts on this: the receive path accepts whatever
  // subset of tiles the sender declares in dirty_count, so the saving is
  // entirely the sender's to take, and a sender that ignores this bit is
  // still correct - just slower. The bit exists because the SENDER cannot
  // know the glass shape any other way; the board reads it from its own
  // table (board::Config::roundDisplay).
  CAP_ROUND_DISPLAY = 1u << 16,
  // Accepts tile records in the half-resolution BC1 codec
  // (tileproto::TileCodec::HalfBc1, wire value 3): the payload is BC1 of a
  // half-size raster which this panel pixel-doubles on arrival, ~16:1
  // overall. The sender engages it only when a frame's motion would not fit
  // the datagram ceiling at plain BC1 rates - it trades resolution for the
  // frame arriving at all (docs/tile-stream-plan.md section 16).
  //
  // A separate bit and not implied by CAP_TILE_STREAM, on the same reasoning
  // as that bit itself: firmware predating this REJECTS codec 3, and because
  // a rejected record aborts its whole datagram, a sender that guessed wrong
  // would silently lose entire frames rather than degrade. So the sender
  // sends codec 3 only where it was advertised, and an older panel keeps
  // getting byte-identical full-resolution records.
  CAP_TILE_HALFRES = 1u << 17,
};

enum class ControlOpcode : uint8_t {
  Brightness = 1,
  Flip = 2,
  Identify = 3,
  Restart = 4,
  BrightnessLevel = 5,
  // Value 0-3: clockwise quarter turns. Supersedes Flip internally (Rotate 2
  // == Flip 1); Flip stays valid in both directions so old senders keep
  // working. Whether values 1 and 3 are honoured is a panel-shape fact the
  // sketch owns (square glass only, NACKed there with a nonzero ack status);
  // this file only knows the representable range.
  Rotate = 6,
  // Value 0 or 1: whether the display should be on. A standing instruction,
  // persisted, and independent of ESLP/EWAK and the idle timer - see the
  // CAP_POWER comment above for why this is a separate axis rather than
  // riding the existing sleep sync.
  Power = 7,
};

struct ControlCommand {
  ControlOpcode opcode;
  uint16_t sequence;
  int32_t value;
};

inline uint16_t readU16LE(const uint8_t *p) {
  return (uint16_t)p[0] | ((uint16_t)p[1] << 8);
}

inline uint32_t readU32LE(const uint8_t *p) {
  return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
         ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

inline void writeU16LE(uint8_t *p, uint16_t value) {
  p[0] = value & 0xFF;
  p[1] = value >> 8;
}

inline void writeU32LE(uint8_t *p, uint32_t value) {
  p[0] = value & 0xFF;
  p[1] = (value >> 8) & 0xFF;
  p[2] = (value >> 16) & 0xFF;
  p[3] = (value >> 24) & 0xFF;
}

// Lowest and highest backlight level a BrightnessLevel command may request.
// Zero is excluded deliberately: a black backlight is indistinguishable from a
// broken panel, and turning the display off already has its own command.
static const int32_t BRIGHTNESS_LEVEL_MIN = 1;
static const int32_t BRIGHTNESS_LEVEL_MAX = 255;

// How long an Identify may light the LED for.
static const int32_t IDENTIFY_SECONDS_MIN = 1;
static const int32_t IDENTIFY_SECONDS_MAX = 30;

inline bool validControlValue(ControlOpcode opcode, int32_t value) {
  switch (opcode) {
    case ControlOpcode::Brightness:
    case ControlOpcode::Flip:
      return value == 0 || value == 1;
    case ControlOpcode::Identify:
      return value >= IDENTIFY_SECONDS_MIN && value <= IDENTIFY_SECONDS_MAX;
    case ControlOpcode::Restart:
      return value == 1;
    case ControlOpcode::BrightnessLevel:
      return value >= BRIGHTNESS_LEVEL_MIN && value <= BRIGHTNESS_LEVEL_MAX;
    case ControlOpcode::Rotate:
      // The full quarter-turn range. The panel-shape restriction (1 and 3
      // only on square glass) deliberately does NOT live here: this header
      // is board-blind, and the sketch is what knows the panel's shape. It
      // NACKs rather than drops, so a sender can tell "refused" from "lost".
      return value >= 0 && value <= 3;
    case ControlOpcode::Power:
      return value == 0 || value == 1;
  }
  return false;
}

inline bool parseControl(const uint8_t *data, size_t len, ControlCommand &out) {
  if (len != CONTROL_PACKET_BYTES || memcmp(data, "ECTL", 4) != 0 ||
      data[4] != CONTROL_PROTOCOL_VERSION) {
    return false;
  }
  if (data[5] < (uint8_t)ControlOpcode::Brightness ||
      data[5] > (uint8_t)ControlOpcode::Power) {
    return false;
  }
  out.opcode = (ControlOpcode)data[5];
  out.sequence = readU16LE(data + 6);
  out.value = (int32_t)readU32LE(data + 8);
  return validControlValue(out.opcode, out.value);
}

// EINF fixed prefix followed by UTF-8 name and firmware version bytes.
inline size_t writeInfo(uint8_t *out, size_t capacity, uint8_t flags,
                        uint32_t capabilities, uint32_t uptimeSeconds,
                        int16_t rssi, uint8_t brightness,
                        const uint8_t deviceId[6], const char *name,
                        const char *firmwareVersion) {
  size_t nameLen = strnlen(name, 33);
  size_t firmwareLen = strnlen(firmwareVersion, 25);
  if (nameLen > 32 || firmwareLen > 24 ||
      capacity < INFO_PREFIX_BYTES + nameLen + firmwareLen) {
    return 0;
  }
  memcpy(out, "EINF", 4);
  out[4] = INFO_VERSION;
  out[5] = FRAME_PROTOCOL_VERSION;
  out[6] = CONTROL_PROTOCOL_VERSION;
  out[7] = flags;
  writeU32LE(out + 8, capabilities);
  writeU32LE(out + 12, uptimeSeconds);
  writeU16LE(out + 16, (uint16_t)rssi);
  out[18] = brightness;
  out[19] = (uint8_t)nameLen;
  out[20] = (uint8_t)firmwareLen;
  memcpy(out + 21, deviceId, 6);
  memcpy(out + INFO_PREFIX_BYTES, name, nameLen);
  memcpy(out + INFO_PREFIX_BYTES + nameLen, firmwareVersion, firmwareLen);
  return INFO_PREFIX_BYTES + nameLen + firmwareLen;
}

inline size_t writeAck(uint8_t out[ACK_PACKET_BYTES], ControlOpcode opcode,
                       uint16_t sequence, uint8_t status, uint8_t flags,
                       uint8_t brightness) {
  memcpy(out, "EACK", 4);
  out[4] = CONTROL_PROTOCOL_VERSION;
  out[5] = (uint8_t)opcode;
  writeU16LE(out + 6, sequence);
  out[8] = status;
  out[9] = flags;
  out[10] = brightness;
  out[11] = 0;
  return ACK_PACKET_BYTES;
}

// ---- Touch events ("ETCH") ----------------------------------------------
// Gestures the panel observed, reported to the sender so it can act on them.
//
// Semantic gestures, not raw coordinates streamed as pointer input. That is a
// deliberate limit on what a panel can ask the Mac to do: these datagrams are
// unauthenticated, so anything on the LAN can forge them, and the blast radius
// has to stay inside a set of actions the user opted into. A "swipe left" a
// sender maps to "cycle source" is recoverable; synthesised clicks at arbitrary
// coordinates would be remote control of the Mac. Raw pointer injection should
// wait for pairing.
//
// One datagram per completed gesture, never per report, so a drag cannot flood
// the link that frame data shares.
static const uint8_t TOUCH_VERSION = 1;
static const size_t TOUCH_PACKET_BYTES = 14;

enum class TouchGesture : uint8_t {
  Tap = 1,
  SwipeLeft = 2,
  SwipeRight = 3,
  SwipeUp = 4,
  SwipeDown = 5,
  // Reported while the finger is still down, unlike every other gesture here.
  // Only sent by firmware advertising CAP_TOUCH_LONGPRESS; a sender that predates
  // it refuses the unknown value and drops the datagram, so no version bump is
  // needed in either direction.
  LongPress = 6,
};

// Bit 0 of the flags byte: the panel was in landscape when the gesture happened.
// Coordinates are in the frame that was on screen, so a receiver needs to know
// which frame that was to interpret them.
static const uint8_t TOUCH_FLAG_LANDSCAPE = 0x01;

struct TouchEvent {
  TouchGesture gesture;
  uint16_t sequence;
  uint16_t x;
  uint16_t y;
  uint8_t flags;
};

inline bool validTouchGesture(uint8_t raw) {
  return raw >= (uint8_t)TouchGesture::Tap &&
         raw <= (uint8_t)TouchGesture::LongPress;
}

// ["ETCH"][version][gesture][sequence u16][x u16][y u16][flags][reserved]
//
// The sequence number is what lets a receiver ignore a duplicate. UDP can
// deliver the same datagram twice, and a tap the sender maps to pause/resume
// would otherwise toggle twice and land back where it started - a bug that
// would look like the tap was ignored.
inline size_t writeTouch(uint8_t out[TOUCH_PACKET_BYTES], TouchGesture gesture,
                         uint16_t sequence, uint16_t x, uint16_t y,
                         uint8_t flags) {
  memcpy(out, "ETCH", 4);
  out[4] = TOUCH_VERSION;
  out[5] = (uint8_t)gesture;
  writeU16LE(out + 6, sequence);
  writeU16LE(out + 8, x);
  writeU16LE(out + 10, y);
  out[12] = flags;
  out[13] = 0;
  return TOUCH_PACKET_BYTES;
}

inline bool parseTouch(const uint8_t *data, size_t len, TouchEvent &out) {
  if (len != TOUCH_PACKET_BYTES || memcmp(data, "ETCH", 4) != 0 ||
      data[4] != TOUCH_VERSION || !validTouchGesture(data[5])) {
    return false;
  }
  out.gesture = (TouchGesture)data[5];
  out.sequence = readU16LE(data + 6);
  out.x = readU16LE(data + 8);
  out.y = readU16LE(data + 10);
  out.flags = data[12];
  return true;
}

// ---- Battery ("EBAT") ---------------------------------------------------
// What the board's battery telemetry source says, sent unprompted on a slow
// timer by firmware advertising CAP_BATTERY. Charge state may be Unknown when
// the board exposes voltage but not its charger's status signal.
//
// WHY NOT EXTRA FIELDS ON EINF: EINF already carries uptime, RSSI and
// brightness, so battery looks like it belongs there. It cannot go there.
// A sender's EINF parser gates on the version byte and then requires the
// packet length to equal the fixed prefix plus the two string lengths
// EXACTLY, so appending fields after the strings - or bumping INFO_VERSION -
// makes an already-shipped sender reject every EINF outright. Telemetry that
// exists today would vanish rather than degrade. A sender's inbound path, by
// contrast, is a chain of parse attempts that silently drops anything it
// cannot name, so a NEW packet type is invisible and harmless to a sender
// that predates it. That is the same reasoning that produced ETCH and ETXT,
// and it is why a new capability bit is preferred here over a version bump.
//
// Fixed 12 bytes, matching the ECTL/EACK convention, because everything worth
// reporting fits: presence, external power, percent, charge state, millivolts.
static const uint8_t BATTERY_VERSION = 1;
static const size_t BATTERY_PACKET_BYTES = 12;

// Bit 0: a battery is physically attached. Bit 1: external (VBUS) power is
// present, so the panel keeps running whatever the cell does.
static const uint8_t BATTERY_FLAG_PRESENT = 0x01;
static const uint8_t BATTERY_FLAG_EXTERNAL_POWER = 0x02;

// Percent when the telemetry source has no opinion - no battery attached, or
// a fuel gauge that has not settled. Distinct from 0, which is a
// real and alarming reading, and the reason percent is not simply clamped.
static const uint8_t BATTERY_PERCENT_UNKNOWN = 0xFF;

// How long a reading may be reported as current, on either side.
//
// A reading needs an expiry because a failed sample deliberately leaves the
// previous one standing - reporting zeros would be worse - but "the last thing
// the telemetry source said" and "what the battery is doing" stop being the same claim
// eventually. Without a ceiling, a source that answers once at boot and then
// dies keeps its percentage on the serial line, in CFGSHOW and in the sender's UI
// forever, and those are the three places whose whole purpose is to tell the
// truth about the cell.
//
// 45s is four missed samples at the firmware's 10s poll, chosen so a single
// transient sample failure or one dropped datagram never flips a display to
// unknown, while a source that has actually stopped answering is reported as
// unknown inside a minute. Both sides use this number: the firmware ages out its
// cached reading, and the sender ages out the last EBAT it received (mirrored as
// DeviceProtocol.batteryMaxAge, asserted equal in both test suites).
static const uint32_t BATTERY_MAX_AGE_MS = 45000;

// Whether a reading sampled at `sampledAtMs` is still current at `nowMs`.
//
// Unsigned subtraction, so a millis() rollover after ~49 days produces a correct
// small difference rather than a huge one - the wrong answer there would be to
// declare a fresh reading stale forever.
inline bool batteryReadingCurrent(uint32_t nowMs, uint32_t sampledAtMs) {
  return (uint32_t)(nowMs - sampledAtMs) <= BATTERY_MAX_AGE_MS;
}

// One enum rather than separate charging/discharging flag bits, so the packet
// cannot express a contradictory state: "charging and discharging at once" is
// not representable here, whereas two independent bits would make it a case
// every receiver had to decide what to do about.
enum class ChargeState : uint8_t {
  Unknown = 0,
  Charging = 1,
  Discharging = 2,
  Standby = 3,
};

struct BatteryStatus {
  bool present;
  bool externalPower;
  uint8_t percent;      ///< 0-100, or BATTERY_PERCENT_UNKNOWN
  ChargeState state;
  uint16_t millivolts;  ///< 0 means the voltage reading is unknown
};

inline bool validBatteryPercent(uint8_t raw) {
  return raw <= 100 || raw == BATTERY_PERCENT_UNKNOWN;
}

inline bool validChargeState(uint8_t raw) {
  return raw <= (uint8_t)ChargeState::Standby;
}

// ["EBAT"][version][flags][percent][state][millivolts u16][reserved x2]
inline size_t writeBattery(uint8_t out[BATTERY_PACKET_BYTES], uint8_t flags,
                           uint8_t percent, ChargeState state,
                           uint16_t millivolts) {
  memcpy(out, "EBAT", 4);
  out[4] = BATTERY_VERSION;
  out[5] = flags;
  out[6] = percent;
  out[7] = (uint8_t)state;
  writeU16LE(out + 8, millivolts);
  out[10] = 0;
  out[11] = 0;
  return BATTERY_PACKET_BYTES;
}

inline bool parseBattery(const uint8_t *data, size_t len, BatteryStatus &out) {
  // The exact-length test is what refuses a trailing byte here. parseIdleText
  // has to check for trailing bytes separately because its packet is
  // variable-length; this one is fixed, so "13 bytes arrived" and "the sender
  // and this parser disagree about the layout" are the same condition, and
  // both are worth refusing rather than half-accepting.
  if (len != BATTERY_PACKET_BYTES || memcmp(data, "EBAT", 4) != 0 ||
      data[4] != BATTERY_VERSION || !validBatteryPercent(data[6]) ||
      !validChargeState(data[7])) {
    return false;
  }
  out.present = (data[5] & BATTERY_FLAG_PRESENT) != 0;
  out.externalPower = (data[5] & BATTERY_FLAG_EXTERNAL_POWER) != 0;
  out.percent = data[6];
  out.state = (ChargeState)data[7];
  out.millivolts = readU16LE(data + 8);
  // The two reserved bytes are deliberately not required to be zero. They
  // exist so a later firmware can carry one more small field - a temperature,
  // a charge current - without a new packet type, and refusing a non-zero
  // reserved byte would make that impossible without the version bump this
  // whole design exists to avoid.
  //
  // THE CONSTRAINT THAT BUYS: any field put in bytes 10-11 later must define 0
  // as "absent". Every firmware built before that field writes zeros there, and
  // because nothing checks them a receiver cannot tell those zeros from a real
  // reading - so a field where 0 is a meaningful value (a temperature in Celsius,
  // say) would be silently misread on every older panel. Something that cannot
  // treat 0 as absent needs a version bump, which is the cost of leaving these
  // bytes open rather than a reason not to.
  return true;
}

// ---- Idle text ("ETXT") -------------------------------------------------
// Lines the panel shows on its status card while no sender is driving it, so
// an idle panel can carry something the user picked instead of only its own
// IP and signal strength.
//
// Deliberately narrow: the panel's font is a 5x7 ASCII bitmap, so anything
// outside printable ASCII is rejected rather than substituted - a sender that
// sends unrenderable bytes should find out, not watch the panel draw blanks.
static const uint8_t IDLE_TEXT_VERSION = 1;
static const size_t IDLE_TEXT_MAX_LINES = 4;
// 28 characters is what fits the 172px-wide portrait panel at the smaller of
// the two text scales.
static const size_t IDLE_TEXT_MAX_LINE_BYTES = 28;
static const size_t IDLE_TEXT_HEADER_BYTES = 8;
static const size_t IDLE_TEXT_MAX_BYTES =
    IDLE_TEXT_HEADER_BYTES +
    IDLE_TEXT_MAX_LINES * (1 + IDLE_TEXT_MAX_LINE_BYTES);

struct IdleTextMessage {
  uint8_t lineCount;
  char lines[IDLE_TEXT_MAX_LINES][IDLE_TEXT_MAX_LINE_BYTES + 1];
};

inline bool printableAscii(uint8_t byte) { return byte >= 0x20 && byte <= 0x7E; }

// Whether two idle-text messages hold the same lines.
//
// What the NVS-persistence path checks before writing: `idleText` is
// overwritten by every ETXT the sender pushes (its own 2-second EINF timer
// keeps that arriving indefinitely, whether or not the content changed), and
// a flash write on every one of those would wear the same NVS cells down
// over weeks of uptime for no reason - only a genuine change is worth saving.
inline bool idleTextEqual(const IdleTextMessage &a, const IdleTextMessage &b) {
  if (a.lineCount != b.lineCount) return false;
  for (uint8_t i = 0; i < a.lineCount; i++) {
    if (strncmp(a.lines[i], b.lines[i], IDLE_TEXT_MAX_LINE_BYTES + 1) != 0) {
      return false;
    }
  }
  return true;
}

// Flatten an idle-text message into one NVS-friendly string, lines joined by
// '\n'. Safe because the font this text is refused for anything but printable
// ASCII (0x20-0x7E, see printableAscii/writeIdleText), so '\n' (0x0A) can
// never appear inside a line and ambiguously double as a separator.
//
// Returns the number of bytes written (excluding the terminator), or 0 if
// `capacity` was not enough - the caller then skips the write rather than
// truncating a template silently.
inline size_t encodeIdleTextForStorage(
    const IdleTextMessage &msg, char *out, size_t capacity) {
  size_t offset = 0;
  for (uint8_t i = 0; i < msg.lineCount; i++) {
    if (i > 0) {
      if (offset + 1 >= capacity) return 0;
      out[offset++] = '\n';
    }
    size_t n = strnlen(msg.lines[i], IDLE_TEXT_MAX_LINE_BYTES + 1);
    if (offset + n >= capacity) return 0;
    memcpy(out + offset, msg.lines[i], n);
    offset += n;
  }
  out[offset] = '\0';
  return offset;
}

// Rebuild an idle-text message from what `encodeIdleTextForStorage` wrote. An
// empty string decodes to zero lines - the same "nothing pushed" state a
// panel boots into today, so a never-configured device NVS key and an
// explicitly cleared template read identically.
inline IdleTextMessage decodeIdleTextFromStorage(const char *stored) {
  IdleTextMessage out;
  memset(&out, 0, sizeof(out));
  if (stored == nullptr || stored[0] == '\0') return out;

  uint8_t lineCount = 0;
  size_t lineStart = 0;
  size_t i = 0;
  for (;; i++) {
    const bool atSeparator = stored[i] == '\n';
    const bool atEnd = stored[i] == '\0';
    if (!atSeparator && !atEnd) continue;
    if (lineCount < IDLE_TEXT_MAX_LINES) {
      size_t n = i - lineStart;
      if (n > IDLE_TEXT_MAX_LINE_BYTES) n = IDLE_TEXT_MAX_LINE_BYTES;
      memcpy(out.lines[lineCount], stored + lineStart, n);
      out.lines[lineCount][n] = '\0';
      lineCount++;
    }
    lineStart = i + 1;
    if (atEnd) break;
  }
  out.lineCount = lineCount;
  return out;
}

// ["ETXT"][version][lineCount][reserved x2] then per line [length][bytes].
inline size_t writeIdleText(uint8_t *out, size_t capacity,
                            const char *const *lines, size_t lineCount) {
  if (lineCount > IDLE_TEXT_MAX_LINES) return 0;
  size_t needed = IDLE_TEXT_HEADER_BYTES;
  for (size_t i = 0; i < lineCount; i++) {
    size_t n = strnlen(lines[i], IDLE_TEXT_MAX_LINE_BYTES + 1);
    if (n > IDLE_TEXT_MAX_LINE_BYTES) return 0;
    for (size_t j = 0; j < n; j++) {
      if (!printableAscii((uint8_t)lines[i][j])) return 0;
    }
    needed += 1 + n;
  }
  if (capacity < needed) return 0;

  memcpy(out, "ETXT", 4);
  out[4] = IDLE_TEXT_VERSION;
  out[5] = (uint8_t)lineCount;
  out[6] = 0;
  out[7] = 0;
  size_t offset = IDLE_TEXT_HEADER_BYTES;
  for (size_t i = 0; i < lineCount; i++) {
    size_t n = strnlen(lines[i], IDLE_TEXT_MAX_LINE_BYTES + 1);
    out[offset++] = (uint8_t)n;
    memcpy(out + offset, lines[i], n);
    offset += n;
  }
  return offset;
}

inline bool parseIdleText(const uint8_t *data, size_t len, IdleTextMessage &out) {
  if (len < IDLE_TEXT_HEADER_BYTES || len > IDLE_TEXT_MAX_BYTES ||
      memcmp(data, "ETXT", 4) != 0 || data[4] != IDLE_TEXT_VERSION) {
    return false;
  }
  const uint8_t lineCount = data[5];
  if (lineCount > IDLE_TEXT_MAX_LINES) return false;

  IdleTextMessage parsed;
  parsed.lineCount = lineCount;
  memset(parsed.lines, 0, sizeof(parsed.lines));

  size_t offset = IDLE_TEXT_HEADER_BYTES;
  for (uint8_t i = 0; i < lineCount; i++) {
    if (offset >= len) return false;
    const size_t n = data[offset++];
    if (n > IDLE_TEXT_MAX_LINE_BYTES || offset + n > len) return false;
    for (size_t j = 0; j < n; j++) {
      if (!printableAscii(data[offset + j])) return false;
    }
    memcpy(parsed.lines[i], data + offset, n);
    parsed.lines[i][n] = '\0';
    offset += n;
  }
  // Trailing bytes mean the sender and this parser disagree about the
  // layout, which is worth refusing rather than half-accepting.
  if (offset != len) return false;

  out = parsed;
  return true;
}

}  // namespace deviceproto
