// display_stream: UDP RGB565 frame receiver for the supported Waveshare
// ESP32 display boards (see board_config.h for the table).
//
// Pipeline (per docs/esp32-wireless-display-plan.md):
//   Mac sends raw RGB565 frames (big-endian / panel byte order) chunked
//   over UDP. Each packet: [frame_id u16 LE][band_index u16 LE]
//   [dirty_count u16 LE][payload]. Bands reassemble into the back buffer
//   of a double buffer; completed frames are pushed to the panel with
//   esp_lcd's interrupt-driven SPI/QSPI DMA.
//
// Why esp_lcd instead of Arduino_GFX for the push: Arduino_GFX's SPI paths
// busy-wait the CPU for the whole frame transfer. On the C6's single core
// that starves the WiFi/lwIP task and drops most UDP chunks (measured:
// throughput plateaued ~20fps with heavy loss). esp_lcd queues the transfer
// and returns; the CPU services WiFi while the SPI peripheral streams the
// frame, and an ISR callback tells us when the buffer is free.
//
// Frame geometry is a per-binary compile-time fact derived from the board
// table (bandproto::Geometry): bands are whole-row groups sized to the
// packet budget. On the 172x320 C6 panels that is 80 bands of 4 rows
// portrait / 86 of 2 landscape - byte-identical to the original hardcoded
// protocol; on the 466x466 S3 AMOLED it is 466 one-row bands.
//
// Buffer ownership (single writer per buffer at all times):
//   backBuf  - being filled by the UDP callback (lwIP task)
//   readyBuf - complete frame awaiting display (handoff slot)
//   dmaBuf   - currently being read by SPI DMA
// The UDP side only swaps into a buffer that DMA isn't reading; otherwise
// it keeps overwriting its current back buffer (recency over completeness).

#include <Adafruit_NeoPixel.h>
#include <ArduinoOTA.h>
#include <AsyncUDP.h>
#include <ESPmDNS.h>
#include <Preferences.h>
#include <WiFi.h>
#include <esp_mac.h>
#include <esp_task_wdt.h>
#include <mbedtls/base64.h>

// Board table, runtime detection, and the shared panel bring-up. These live in
// firmware/libraries/espdisp_board so display_test builds the panel exactly the
// way this firmware does. panel_init.h pulls in the esp_lcd and SPI headers.
#include <board_config.h>
#include <board_detect.h>
#include <board_power.h>
#include <board_touch.h>
#include <panel_init.h>
#include <touch_gesture.h>
#include <touch_map.h>

#include "wifi_config.h"  // compile-time fallback WIFI_SSID / WIFI_PASSWORD (gitignored)

// Hardware-free and unit tested on the host (firmware/test/run_tests.sh).
// Included here rather than further down because the helpers below use them.
#include "panel_state.h"

// Up here for the same reason, and for one more: the Arduino build generates a
// prototype for every function in this sketch and inserts them all near the top
// of the file. Any function whose signature names a type from one of these
// headers - toWireGesture takes a deviceproto::TouchGesture - gets a prototype
// emitted above the point where the header used to be included, and the sketch
// failed to compile with "'deviceproto' has not been declared".
//
// All of them are header-only, self-contained, and unit tested standalone on the
// host, so nothing in this file has to be declared before them.
#include "band_protocol.h"
#include "band_compress.h"
#include "device_protocol.h"
#include "control_queue.h"
#include "ota_policy.h"
#include "chip_identity.h"
using namespace bandproto;

// WiFi credentials live in NVS flash and are reconfigurable over the USB
// serial port without reflashing (see handleSerialConfig). The compiled-in
// wifi_config.h values are only the first-boot fallback.
static String cfgSsid;
static String cfgPass;

// Device name: mDNS hostname + service instance name, so multiple panels
// coexist and the Mac discovers them by browsing _espdisp._udp instead of
// resolving a hardcoded hostname. Default is unique per board
// (espdisplay-XXXX from the MAC); changeable via CFGNAME over USB.
static String cfgName;
static const char *FW_VERSION = "1.3.0";
static uint8_t deviceId[6] = {0};

// Reads the MAC straight from eFuse rather than via WiFi.macAddress(),
// because the name is needed before WiFi is initialized: the DHCP hostname
// is latched inside WiFi.mode() when entering STA mode.
static String defaultDeviceName() {
  char buf[24];
  snprintf(buf, sizeof(buf), "espdisplay-%02x%02x", deviceId[4], deviceId[5]);
  return String(buf);
}

// ---- Board identity ---------------------------------------------------
// On the C6, one binary serves both Waveshare 1.47" boards: the panel
// controller and pin map differ, the 172x320 resolution does not. Detected at
// boot, cached only when explicitly forced with CFGBOARD over USB. On the S3
// the variant is a compile-time fact (COMPILED_VARIANT) and none of the probe
// machinery runs.
static board::Variant boardVariant = board::COMPILED_VARIANT;
static const board::Config *bcfg = &board::configFor(board::COMPILED_VARIANT);

// ---- Display geometry --------------------------------------------------
// A per-binary compile-time fact, NOT a per-boot one: buffers, band layout,
// and the mDNS advertisement are all sized from it. Reading it from
// COMPILED_VARIANT is correct on every target because the C6 boards (the
// only case where detection can change the variant at runtime) share their
// resolution; setup() enforces that invariant against a stale CFGBOARD
// override. Pins, panel driver, pixel clock, gap and inversion stay runtime
// facts read from bcfg.
static const bandproto::Geometry PANEL_GEOMETRY = {
    board::configFor(board::COMPILED_VARIANT).panelW,
    board::configFor(board::COMPILED_VARIANT).panelH};
static const int16_t PANEL_W = (int16_t)PANEL_GEOMETRY.width;
static const int16_t PANEL_H = (int16_t)PANEL_GEOMETRY.height;

static esp_lcd_panel_handle_t panel = nullptr;

// ---- Onboard RGB LED(s): WiFi signal quality indicator ------------------
// WS2812-style addressable LED(s) glowing through the board's acrylic layer,
// on the non-touch board only. Driven as a short strip with every pixel the
// same color: data past the real LED count is ignored, so this works whether
// the board has one LED or several.
//
// Constructed lazily, after detection, and only when the board actually has an
// LED. Adafruit_NeoPixel drives its pin in begin(), and GPIO8's function on the
// Touch board is undocumented - it is measurably not the BOOT button, but that
// is all we know - so a static instance plus an unconditional begin() would
// drive a pin whose other end is a mystery.
static const int RGB_COUNT = 8;                // safe upper bound, extras ignored
static const uint8_t RGB_LED_BRIGHTNESS = 28;  // subtle glow, not a lamp
static uint32_t ledOverrideUntil = 0;          // CFGLED diagnostic hold
static Adafruit_NeoPixel *rgbLed = nullptr;

// ---- BOOT button (ESP32-C6 boot strap; plain input after boot) ----------
// Short press: toggle backlight high/low. Long press: turn the display 180
// (rotation += 2 - a physical button reachable from behind a mounted panel
// stays a two-position toggle even where quarter turns exist).
// GPIO9 on both boards - see bcfg, and the note there about Waveshare's pinout
// table claiming GPIO8 for the Touch variant.
// How often loop() checks whether the idle-text template needs saving to
// NVS. This is what actually bounds flash wear for a template built from
// live tokens ({uptime}, {rssi}) - see saveIdleTextPrefsIfChanged's comment
// for why a reactive, push-triggered check cannot. One minute is short
// enough that a genuinely new template (the case this whole mechanism
// exists for) is saved promptly, and long enough that a template ticking
// with every 2-second EINF still costs at most one write a minute rather
// than one every few seconds.
static const uint32_t IDLE_TEXT_SAVE_INTERVAL_MS = 60000;
static const uint32_t LONG_PRESS_MS = 600;
// A third tier, well past the long press, for the one action that should not
// be reachable by an accidental long-hold: turning the panel off from a
// button reachable from behind a mounted display. 3s is long enough that
// nobody clears LONG_PRESS_MS's 600ms by accident and keeps holding without
// meaning to - the long-press flip already fired and released the button in
// any ordinary press.
static const uint32_t EXTRA_LONG_PRESS_MS = 3000;
static const uint32_t DEBOUNCE_MS = 30;
static const uint8_t BL_HIGH = 128;  // 50%, Waveshare's recommended ceiling
static const uint8_t BL_LOW = 24;    // ~10%
// The backlight level to use when awake and being driven, 1..255. This is the
// single source of truth: the BOOT button steps it between BL_LOW and BL_HIGH,
// and the sender can set any level. Keeping one value instead of a high/low
// flag is what lets both live together without them disagreeing.
static uint8_t userBlLevel = BL_HIGH;

// True when the level is nearer high than low, which is what the high/low
// toggle and the reported flag mean now that any level is possible.
static inline bool blIsHigh() {
  return panelstate::brightnessIsHigh(userBlLevel, BL_LOW);
}

// ---- Status card & display sleep ----------------------------------------
// The status card means "nothing is driving this panel", NOT "the picture
// hasn't changed". Liveness comes from the sender's 2s keepalive, which
// arrives regardless of whether any pixels changed - with dirty-band
// diffing, a static photo legitimately sends no frame data for minutes, and
// keying off frame arrivals made the panel dim itself mid-use.
// Backlight off is driven by the Mac's own display/system sleep ("ESLP").
static const uint32_t SENDER_GONE_MS = 45000;
static const uint32_t IDLE_REPOSITION_MS = 30000;
static const uint8_t BL_IDLE = 10;
static bool idleActive = false;
static volatile uint32_t lastSenderPacketAt = 0;  // any packet, incl. keepalive
static uint32_t lastIdleDrawAt = 0;
static volatile bool sleepRequested = false;  // set by UDP task on ESLP
static volatile bool wakeRequested = false;   // set by UDP task on EWAK
static bool displaySleeping = false;

// ---- Protocol (v2: dirty bands) -----------------------------------------
// All wire-format constants and the reassembly/coalescing decision logic
// live in band_protocol.h, which is hardware-free and unit tested on the
// host (firmware/test/run_tests.sh). Included at the top of this file; see the
// note there about generated prototypes.

// Capabilities every board has, whatever panel or peripherals it carries.
static const uint32_t BASE_CAPABILITIES =
    deviceproto::CAP_BRIGHTNESS | deviceproto::CAP_BRIGHTNESS_LEVEL |
    deviceproto::CAP_FLIP |
    deviceproto::CAP_IDENTIFY | deviceproto::CAP_RESTART |
    deviceproto::CAP_SLEEP_SYNC | deviceproto::CAP_TELEMETRY |
    deviceproto::CAP_IDLE_TEXT |
    // The RLE decode is chip-independent and the C6 gains from packing too
    // (an 80-band keyframe becomes a handful of datagrams), so every board
    // advertises it.
    deviceproto::CAP_COMPRESSED_BANDS |
    // A manual on/off is not a hardware fact the way battery or rotate are -
    // every board here has a backlight or panel-command brightness sink
    // already, so every board can honour it.
    deviceproto::CAP_POWER;

// Whether the touch controller came up. Not simply "is this the Touch board":
// the chip has to actually answer, so a board with dead touch advertises no
// touch rather than promising gestures that never arrive.
static bool touchAvailable = false;

// Which board's touch calibration to run raw coordinates through. Picked
// once at boot from bcfg->touch (see setup()) rather than defaulted, because
// touchmap::map's Calibration parameter defaults to the C6's AXS5106L
// calibration - correct only for that one board - and every other board
// must pass its own explicitly or inherit a mirroring/rotation convention
// that was never measured on its hardware.
static touchmap::Calibration touchCalibration = touchmap::AXS5106L_ON_C6;

// Whether the power-management IC came up, on the same "the chip has to answer"
// rule as touchAvailable: only the 1.75C has a PMU, and a 1.75C whose PMU is
// silent must advertise no battery rather than promise readings that never come.
static bool batteryAvailable = false;

// ---- OTA (ArduinoOTA over WiFi, LAN only) -------------------------------
// Fails closed, deliberately: an unpassworded ArduinoOTA is an unauthenticated
// remote-code-execution path for anything that can reach this panel. There is no
// default password and none is generated - with nothing stored, OTA does not
// start and CAP_OTA is not advertised, which is the state every panel already
// ships in. Set one with CFGOTAPW over USB.
//
// The plaintext is deliberately NOT kept in a global. It is read from NVS into a
// local inside startOtaIfConfigured() and handed to ArduinoOTA, which stores only
// SHA256(password) (verified in the core's ArduinoOTA.cpp setPassword). The two
// flags below are all that stays resident.
static const uint16_t OTA_PORT = 3232;  // ArduinoOTA's own default port
static bool otaConfigured = false;      // a password is stored in NVS
static bool otaActive = false;          // begin() has run, handle() is live

// The two flags collapsed into the one thing anybody is told, so the capability
// bit and CFGSHOW's ota= cannot drift apart. The rules live in ota_policy.h
// where they are tested on the host.
static inline otapolicy::Status currentOtaStatus() {
  return otapolicy::status(otaActive, otaConfigured);
}
// Set for the duration of a write. The whole transfer happens inside one
// ArduinoOTA.handle() call, so the loop does not normally iterate while this is
// set; it exists so that if it ever does, nothing repaints over the progress
// screen and no DMA is queued underneath the flash writes.
static volatile bool otaInProgress = false;
static uint8_t otaShownPercent = 0;
// The dimmed states onStart clears so an update is visible, held so onError can
// put them back. A successful push reboots, so only the failure path needs them.
// See otapolicy::SavedPanelState for why this is a type rather than two bools:
// onError is reachable without onStart, and restoring in that case woke a
// sleeping panel for anything on the LAN that got the password wrong.
static otapolicy::SavedPanelState otaSavedPanel;

// Last successful PMU reading, so the 5s status line and CFGSHOW can report a
// battery without doing I2C traffic of their own. Only meaningful once
// batteryReadingValid is set; a failed sample leaves the previous one standing
// rather than reporting a zeroed battery as fact.
//
// It does not stand forever, though. lastBatteryAt ages it out after
// deviceproto::BATTERY_MAX_AGE_MS, so a PMU that answers at boot and then goes
// silent stops being quoted as if it were still talking. batteryReadingCurrent()
// is the one test both the serial line and CFGSHOW go through.
static boardpower::Reading lastBattery = {};
static bool batteryReadingValid = false;
static uint32_t lastBatteryAt = 0;

// Advertised capabilities. Runtime rather than a constant because CAP_TOUCH
// depends on the hardware, and the sender uses these bits to decide which
// controls to offer - a panel without touch should not show touch actions.
static uint32_t deviceCapabilities() {
  // Long press rides with touch rather than being its own condition: the same
  // classifier produces both, so a panel whose controller answered can report
  // holds. It is a separate bit so a sender can tell this firmware from an
  // older build whose holds classified as nothing.
  return BASE_CAPABILITIES
         | (touchAvailable ? (deviceproto::CAP_TOUCH
                              | deviceproto::CAP_TOUCH_LONGPRESS)
                           : 0u)
         | (batteryAvailable ? deviceproto::CAP_BATTERY : 0u)
         // Quarter turns only where the glass is square. On a rectangular
         // panel a 90-degree mounting turn is what the sender-driven
         // landscape mechanism already expresses, and honouring rotation 1/3
         // there would fight it - so the capability is withheld and the
         // Rotate handler NACKs those values as defense in depth behind it.
         | (bcfg->panelW == bcfg->panelH ? deviceproto::CAP_ROTATE : 0u)
         // Only when OTA actually came up, not merely because this build
         // contains the code and not merely because a password is stored: a
         // panel that is not listening advertises no OTA, so nothing offers an
         // update path that would time out. advertisesCapability owns that rule.
         | (otapolicy::advertisesCapability(currentOtaStatus())
                ? deviceproto::CAP_OTA
                : 0u);
}

// Lines the sender asked the panel to show on its status card, with when they
// arrived so the card can say how old they are. Written by the UDP task and
// read by the loop, so both go through controlMux.
static deviceproto::IdleTextMessage idleText;
static uint32_t idleTextAt = 0;
// The last idle-text content actually written to NVS, so loop()'s periodic
// check (see IDLE_TEXT_SAVE_INTERVAL_MS below) can tell "really changed"
// from "same as what is already saved" without re-touching flash. Zero-
// initialized to an empty message by static storage; setup() overwrites it
// with whatever was loaded, so a freshly booted panel does not immediately
// rewrite NVS with the value it just read back out of it.
static deviceproto::IdleTextMessage lastSavedIdleText;

static const uint16_t UDP_PORT = 5568;
static const size_t FRAME_BYTES = PANEL_GEOMETRY.frameBytes();

// ---- Buffers -----------------------------------------------------------
// bufA: persistent assembled frame, written by the UDP callback per band.
// bufB: DMA staging - dirty strips are memcpy'd here before queueing, so
//       SPI DMA never reads memory the network path is writing.
//
// Where they live is a per-chip fact. The C6's 110KB frames fit internal
// DMA-capable SRAM (and the C6 has no PSRAM anyway). A 466x466 frame is
// 434KB - two of them cannot fit the S3's 512KB SRAM, so they go to the
// stacked PSRAM, which the S3's GDMA can read. UNVERIFIED on hardware:
// sustained QSPI-from-PSRAM throughput and any alignment constraints need
// measuring on a real 1.75C before this is trusted.
#if defined(CONFIG_IDF_TARGET_ESP32S3)
static const uint32_t FRAME_BUF_CAPS = MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT;
#else
static const uint32_t FRAME_BUF_CAPS = MALLOC_CAP_DMA;
#endif
static uint8_t *bufA = nullptr;
static uint8_t *bufB = nullptr;

static Reassembler reassembler(PANEL_GEOMETRY);  // tested logic: band_protocol.h
static bool bufLandscape = false;                // orientation of bufA's content

// Bands applied to bufA but not yet drawn. Accumulates across frames so
// bands from an abandoned partial frame still reach the panel with the next
// completed frame. Guarded by drawMux (UDP callback runs in the lwIP task).
static uint8_t pendingDrawBitmap[BITMAP_BYTES];
static portMUX_TYPE drawMux = portMUX_INITIALIZER_UNLOCKED;
static volatile uint32_t framesCompleted = 0;    // completion signal: UDP -> loop
static volatile bool pendingLandscape = false;   // orientation for the pending draw

static bool panelLandscape = false;              // current panel MADCTL state
// The user's mounting rotation, clockwise quarter turns 0-3. Supersedes the
// old flip180 bool: rotation 2 IS the old flip, and the BOOT long press still
// steps by 2. Values 1 and 3 are only accepted on square glass (see the
// Rotate case in applyPendingControl and CFGROT); rectangular panels express
// a physical quarter turn through the sender's landscape mechanism instead.
static uint8_t panelRotation = 0;

// User-requested "display off", independent of the Mac's own ESLP/EWAK sleep
// sync and the idle timer. Both of those are transient states this firmware
// arrives at and clears on the next drawn frame; this one is a standing
// instruction like rotation or brightness level, persisted in NVS and held
// until an explicit Power command turns it back on - see panelstate::
// backlightLevel for why it outranks even a wake-touch, and the CAP_POWER
// comment in device_protocol.h for why it is not simply riding ESLP/EWAK.
static bool panelManuallyOff = false;
static bool madctlDirty = false;                 // panel config needs reapplying

// Stats.
static volatile uint32_t statFramesShown = 0;
static volatile uint32_t statFramesDropped = 0;  // incomplete, abandoned
static volatile uint32_t statFramesSkipped = 0;  // complete but no free buffer
static volatile uint32_t statPackets = 0;
static volatile uint32_t statBadLen = 0;
static volatile uint32_t statDrawErrors = 0;
static volatile int32_t dmaInFlight = 0;  // queued strip draws not yet completed
static uint32_t dmaQueuedAt = 0;          // for DMA-stall detection

// Reply endpoint: source of the most recent packet from the Mac. Used for
// the 1Hz heartbeat so the sender can detect blackholing (wrong IP after a
// reboot, WiFi drop) and see delivery stats. u32+u16 writes are effectively
// atomic on this 32-bit core.
static volatile uint32_t hbIp = 0;
static volatile uint16_t hbPort = 0;

// Management controls arrive on lwIP's callback task and are applied by the
// Arduino loop. NVS writes, panel changes, LED work, and restarts must never
// run inside the network callback.
static portMUX_TYPE controlMux = portMUX_INITIALIZER_UNLOCKED;
static controlq::ControlQueue controls;
static uint32_t restartAt = 0;

AsyncUDP udp;

// ISR context: one queued strip transfer finished.
static bool IRAM_ATTR onColorTransDone(esp_lcd_panel_io_handle_t,
                                       esp_lcd_panel_io_event_data_t *, void *) {
  if (dmaInFlight > 0) {
    dmaInFlight = dmaInFlight - 1;
  }
  return false;
}

// Apply one band's payload to bufA and run the reassembly bookkeeping. The
// shared body of both packet layouts: the classic one-raw-band packet and
// each record of a packed packet. `countPacket` keeps the classic path's
// stats semantics (duplicates count in packets=); the packed path counts its
// datagram once, in its caller.
//
// A compressed payload is decoded straight into bufA at the band offset -
// this is the network receive path, so there is no scratch copy. rle565::
// decode is bounds-checked against exactly this band's length: whatever a
// datagram claims, nothing is written outside the band (see band_compress.h;
// a fault there would be a remote-triggered overflow). The decode runs after
// the reassembler classifies the chunk, so a stale or duplicate band never
// touches bufA; the cost is that a payload that then fails to decode leaves
// its band marked seen over the previous frame's rows - a torn band on a
// forged packet, healed by the next keyframe, and never memory-unsafe.
static bool applyBandPayload(const bandproto::Header &h, bool compressed,
                             const uint8_t *payload, size_t payloadLen,
                             bool countPacket) {
  if (h.bandIndex >= PANEL_GEOMETRY.bandCount(h.landscape)) {
    return false;  // geometry mismatch - sender misconfigured
  }
  const size_t rawLen =
      PANEL_GEOMETRY.bandPayloadBytes(h.bandIndex, h.landscape);
  if (!compressed && payloadLen != rawLen) {
    statBadLen = statBadLen + 1;
    return false;
  }

  bool droppedFrame = false;
  ChunkAction action = reassembler.onChunk(h, droppedFrame);
  if (droppedFrame) {
    // Incomplete frame abandoned - but its bands are already applied to
    // bufA and marked in pendingDrawBitmap, so they still reach the panel
    // with the next completed frame (per-band recency).
    statFramesDropped = statFramesDropped + 1;
  }
  if (action == ChunkAction::Reject) {
    return false;  // geometry mismatch - sender misconfigured
  }
  if (countPacket) {
    statPackets = statPackets + 1;
  }
  if (action == ChunkAction::IgnoreStale || action == ChunkAction::Duplicate) {
    return true;
  }

  // A landscape/portrait change invalidates everything in bufA (band geometry
  // and pixel layout both change), so stale pending bands are dropped and the
  // keyframe the sender guarantees on an orientation change rebuilds it. Not to
  // be confused with the user's mounting rotation, which leaves bufA valid and
  // is repainted locally in loop() - see the madctlDirty block there.
  if (h.landscape != bufLandscape) {
    portENTER_CRITICAL(&drawMux);
    memset(pendingDrawBitmap, 0, sizeof(pendingDrawBitmap));
    portEXIT_CRITICAL(&drawMux);
    bufLandscape = h.landscape;
  }

  uint8_t *dst = bufA + PANEL_GEOMETRY.bandOffset(h.bandIndex, h.landscape);
  if (compressed) {
    if (!rle565::decode(payload, payloadLen, dst, rawLen)) {
      statBadLen = statBadLen + 1;
      return false;
    }
  } else {
    memcpy(dst, payload, rawLen);
  }
  portENTER_CRITICAL(&drawMux);
  pendingDrawBitmap[h.bandIndex >> 3] |= 1 << (h.bandIndex & 7);
  portEXIT_CRITICAL(&drawMux);

  if (action == ChunkAction::ApplyComplete) {
    pendingLandscape = h.landscape;
    framesCompleted = framesCompleted + 1;  // loop draws the pending bands
  }
  return true;
}

// One inbound datagram, whatever transport delivered it: AsyncUDP's lwIP
// callback on the C6, the dedicated receive task on the S3. `remoteIp` is in
// the byte order the transport's reply path expects (IPAddress dword and
// sockaddr s_addr share it on this little-endian core).
static void handleInbound(const uint8_t *data, size_t len, uint32_t remoteIp,
                          uint16_t remotePort) {
  // Any packet from the sender refreshes the heartbeat reply endpoint and
  // proves the sender is alive - keepalives arrive even when the screen is
  // perfectly static, which is why liveness keys off this and not frames.
  hbIp = remoteIp;
  hbPort = remotePort;
  lastSenderPacketAt = millis();

  if (len == 4 && memcmp(data, "EPNG", 4) == 0) {
    return;  // keepalive ping: endpoint refresh only
  }
  if (len == 4 && memcmp(data, "ESLP", 4) == 0) {
    sleepRequested = true;  // Mac's displays slept: loop turns backlight off
    return;
  }
  if (len == 4 && memcmp(data, "EWAK", 4) == 0) {
    // Explicit wake, because a frame may never come: if the Mac wakes onto
    // static content there is nothing to send, and waiting for a frame
    // would leave the panel dark.
    wakeRequested = true;
    return;
  }
  if (len >= 4 && memcmp(data, "ETXT", 4) == 0) {
    deviceproto::IdleTextMessage message;
    if (!deviceproto::parseIdleText(data, len, message)) {
      statBadLen = statBadLen + 1;
      return;
    }
    // Only the RAM copy is touched here. NVS is written from loop() on its
    // own slow timer (see IDLE_TEXT_SAVE_INTERVAL_MS) rather than reacting to
    // this arriving - a template built from live tokens like {uptime} or
    // {rssi} produces DIFFERENT TEXT ON EVERY PUSH by design, so comparing
    // content on every ETXT (which the sender's 2-second EINF keeps
    // triggering indefinitely) would still write to flash every couple of
    // seconds for exactly the templates a user is most likely to actually
    // use. A periodic check is the only thing that bounds the write rate
    // regardless of what the template contains.
    portENTER_CRITICAL(&controlMux);
    idleText = message;
    idleTextAt = millis();
    portEXIT_CRITICAL(&controlMux);
    return;
  }
  if (len >= 4 && memcmp(data, "ECTL", 4) == 0) {
    deviceproto::ControlCommand command;
    if (!deviceproto::parseControl(data, len, command)) {
      statBadLen = statBadLen + 1;
      return;
    }
    portENTER_CRITICAL(&controlMux);
    controls.offer(command);
    portEXIT_CRITICAL(&controlMux);
    return;
  }
  // Never parse a frame header before proving all six bytes are present.
  if (len < HEADER_BYTES) {
    statBadLen = statBadLen + 1;
    return;
  }
  bandproto::Header h = parseHeader(data);
  if (h.reservedBitsSet) {
    // band_index bits 14..10 are reserved-zero; a sender that sets one is
    // speaking a layout this firmware does not, so refuse the whole packet.
    statBadLen = statBadLen + 1;
    return;
  }
  if (h.packed) {
    // Packed packet: several band records in one datagram, each raw or
    // RLE-compressed (only sent to us because we advertise
    // CAP_COMPRESSED_BANDS). The walker validates each record's framing
    // before applyBandPayload sees it; the header's band_index must name the
    // first record's band, a cross-check that the two layouts agree.
    bool first = true;
    bool ok = bandproto::forEachPackedRecord(
        data + HEADER_BYTES, len - HEADER_BYTES,
        [&](uint16_t band, bool compressed, const uint8_t *payload,
            size_t payloadLen) {
          if (first) {
            if (band != h.bandIndex) return false;
            first = false;
          }
          bandproto::Header bandHeader = h;
          bandHeader.bandIndex = band;
          return applyBandPayload(bandHeader, compressed, payload, payloadLen,
                                  false);
        });
    if (!ok) {
      statBadLen = statBadLen + 1;
      return;
    }
    // One datagram, one count: packets= is what the ingest probe and the
    // link supervisor read, and both care about datagrams accepted, not
    // bands carried.
    statPackets = statPackets + 1;
    return;
  }
  applyBandPayload(h, false, data + HEADER_BYTES, len - HEADER_BYTES, true);
}

// ---- Inbound transport ---------------------------------------------------
// The S3 gets a dedicated FreeRTOS receive task draining a raw lwIP socket on
// the app core; the single-core C6 keeps AsyncUDP. Measured on the 466x466 S3
// (tools/ingest_probe.py): the AsyncUDP path accepted ~1826 datagrams/s flat
// from 8k to 12k offered - a software receive-path ceiling, not radio. Its
// per-datagram cost is paid in the lwIP callback (pbuf handling plus an
// AsyncUDPPacket allocation per datagram); recvfrom into one preallocated
// buffer on the second core takes that work off the WiFi task entirely. The
// before/after numbers live in the commit that introduced this.
//
// Replies (heartbeat, EINF, EACK, EBAT, ETCH) go out through sendToSender so
// each transport answers on its own socket.
#if defined(CONFIG_IDF_TARGET_ESP32S3)
#include <lwip/sockets.h>

static int rxSock = -1;

// Priority above loopTask (1) so a queued datagram preempts drawing
// bookkeeping, below the WiFi/lwIP tasks (18+) which feed it. Pinned to core
// 1: lwIP runs on core 0, so parsing and the PSRAM band copy no longer
// compete with the radio.
static const UBaseType_t RX_TASK_PRIORITY = 9;
static const uint32_t RX_TASK_STACK = 6144;

static void udpReceiveTask(void *) {
  // One reusable buffer, internal RAM. Sized over MAX_PACKED_PACKET_BYTES so
  // an oversized datagram is read whole (and then refused by the length
  // checks) rather than truncated into something that might parse.
  static uint8_t rxBuf[2048];
  while (true) {
    struct sockaddr_in from;
    socklen_t fromLen = sizeof(from);
    int n = lwip_recvfrom(rxSock, rxBuf, sizeof(rxBuf), 0,
                          (struct sockaddr *)&from, &fromLen);
    if (n <= 0) {
      vTaskDelay(1);  // transient socket error: don't spin the core
      continue;
    }
    handleInbound(rxBuf, (size_t)n, from.sin_addr.s_addr,
                  ntohs(from.sin_port));
  }
}

static bool startInboundTransport() {
  rxSock = lwip_socket(AF_INET, SOCK_DGRAM, IPPROTO_IP);
  if (rxSock < 0) return false;
  struct sockaddr_in addr = {};
  addr.sin_family = AF_INET;
  addr.sin_port = htons(UDP_PORT);
  addr.sin_addr.s_addr = htonl(INADDR_ANY);
  if (lwip_bind(rxSock, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
    lwip_close(rxSock);
    rxSock = -1;
    return false;
  }
  return xTaskCreatePinnedToCore(udpReceiveTask, "udprx", RX_TASK_STACK,
                                 nullptr, RX_TASK_PRIORITY, nullptr,
                                 1) == pdPASS;
}

static void sendToSender(const uint8_t *data, size_t len) {
  if (rxSock < 0 || hbPort == 0) return;
  struct sockaddr_in to = {};
  to.sin_family = AF_INET;
  to.sin_port = htons(hbPort);
  to.sin_addr.s_addr = hbIp;  // stored exactly as recvfrom produced it
  lwip_sendto(rxSock, data, len, 0, (struct sockaddr *)&to, sizeof(to));
}
#else
static void onPacket(AsyncUDPPacket packet) {
  handleInbound(packet.data(), packet.length(), (uint32_t)packet.remoteIP(),
                packet.remotePort());
}

static bool startInboundTransport() {
  if (!udp.listen(UDP_PORT)) return false;
  udp.onPacket(onPacket);
  return true;
}

static void sendToSender(const uint8_t *data, size_t len) {
  if (hbPort == 0) return;
  udp.writeTo(data, len, IPAddress(hbIp), hbPort);
}
#endif

// Bring up SPI and the panel for whichever board this is. The body lives in
// boardpanel::init so display_test exercises the identical path - a bring-up
// test that constructs the panel its own way can pass while this is broken.
static bool initDisplay() {
  return boardpanel::init(*bcfg, SPI2_HOST, bcfg->pclkHz, FRAME_BYTES,
                          onColorTransDone, nullptr, nullptr, &panel);
}

// Persist the physical-mounting settings. Only written on a button press or an
// explicit command, so NVS wear is a non-issue.
static void saveDisplayPrefs() {
  Preferences prefs;
  prefs.begin("espdisp", false);
  // "rot" supersedes the old "flip" bool (flip true == rot 2). setup() still
  // reads "flip" when no "rot" exists, so a panel upgraded in place keeps its
  // mounting; the old key is left alone rather than deleted, so a downgrade
  // to older firmware also keeps the 180 the two encodings agree on.
  prefs.putUChar("rot", panelRotation);
  prefs.putUChar("bllevel", userBlLevel);
  prefs.putBool("pwroff", panelManuallyOff);
  prefs.end();
}

// If the idle text held in RAM differs from what NVS last had, write it.
// Called from loop() on IDLE_TEXT_SAVE_INTERVAL_MS, never from the network
// path: see the comment in the ETXT branch of handleInbound for why a
// template built from live tokens ({uptime}, {rssi}) needs a time-bounded
// check rather than a reactive one to keep flash wear bounded at all - the
// EXPANDED TEXT legitimately changes on nearly every push for exactly the
// templates most likely to be in real use, so "did the content change"
// alone does not throttle anything for those.
//
// A device that reboots between checks loses at most one interval's worth of
// freshness in the saved copy - the same trade every polled-write scheme
// like this makes, and cheap next to what it buys: a screensaver template
// that used to vanish on every reboot now needs a genuinely unlucky timing
// window (a change landing in the last IDLE_TEXT_SAVE_INTERVAL_MS before a
// crash) to lose anything at all.
static void saveIdleTextPrefsIfChanged() {
  deviceproto::IdleTextMessage snapshot;
  portENTER_CRITICAL(&controlMux);
  snapshot = idleText;
  portEXIT_CRITICAL(&controlMux);

  if (deviceproto::idleTextEqual(snapshot, lastSavedIdleText)) return;

  char encoded[deviceproto::IDLE_TEXT_MAX_BYTES];
  size_t n = deviceproto::encodeIdleTextForStorage(
      snapshot, encoded, sizeof(encoded));
  // A message that could not be encoded (should not happen: the buffer is
  // sized for the protocol's own maximum) is left as whatever NVS already
  // held rather than saving something truncated. lastSavedIdleText is
  // deliberately NOT updated here, so the next check retries rather than
  // treating a failed encode as if it had succeeded.
  if (n == 0 && snapshot.lineCount > 0) return;

  Preferences prefs;
  prefs.begin("espdisp", false);
  prefs.putString("idletxt", encoded);
  prefs.end();
  lastSavedIdleText = snapshot;
  Serial.printf("idle text saved to NVS (%u lines, %u bytes)\n",
                (unsigned)snapshot.lineCount, (unsigned)n);
}

// Apply orientation + the user's mounting rotation, then record what the panel
// now holds. The MADCTL/gap arithmetic itself is in
// boardpanel::applyOrientation, shared with display_test; it is identical on
// both boards (verified against Waveshare's own example for the JD9853, not
// assumed from the ST7789).
static void applyPanelConfig(bool landscape) {
  boardpanel::applyOrientation(panel, *bcfg, landscape, panelRotation);
  panelLandscape = landscape;
  madctlDirty = false;
}

static uint8_t currentDeviceFlags() {
  return panelstate::deviceFlags(blIsHigh(), panelRotation, displaySleeping,
                                 idleActive, WiFi.status() == WL_CONNECTED,
                                 panelManuallyOff);
}

// ---- Touch (Touch board only) ------------------------------------------
// A finger on a dimmed panel lights it for a bounded window, and that touch is
// consumed rather than also firing whatever a tap is wired to - the same way a
// phone's first tap wakes the screen instead of pressing what is under it.
//
// Deliberately local and deliberately silent: the Mac's sleep state is
// authoritative, so waking never sends anything. It stops this panel from being
// dark while somebody is looking at it, and nothing more.
static const uint32_t TOUCH_WAKE_MS = 10000;
static uint32_t touchWakeUntil = 0;
static touchgesture::Tracker touchTracker;
static uint16_t touchSequence = 0;

// ---- Quick info bar (a lit panel only) ---------------------------------
// A plain tap - not a swipe, not a long press, and not the tap that woke a
// dimmed panel - shows a status line across the top of the panel for a few
// seconds without touching the backlight or interrupting streaming: this is
// the fast path to "what's the battery doing right now" that does not
// require waiting for the sender to go quiet and the idle card to appear.
//
// Local and additive, the same way the wake-touch is: sendTouchEvent still
// reports the tap to the sender for its own gesture-preset mapping, so a
// preset bound to Tap (e.g. togglePause) is unaffected by this also showing
// a bar - the two are independent reactions to the same gesture.
static const uint32_t INFO_BAR_MS = 2000;
static uint32_t infoBarUntil = 0;
// The row range currently covered by the bar, in the CURRENT frame
// orientation (see infoBarRows()). Recomputed on every show so a tap that
// lands mid-rotation still gets the right band, and reused by the streaming
// path each loop to know which run(s) to redraw the bar onto instead of
// letting a fresh frame silently erase it (see loop()'s per-run draw path).
static int infoBarY0 = 0;
static int infoBarY1 = 0;
static char infoBarText[40] = {0};
// The glyph scale the bar's text was last drawn at, so redrawInfoBarOverRun
// (which has to reproduce the exact same draw, not just some legible one)
// never disagrees with showInfoBar about how big the text is - both go
// through infoBarGlyphScale() below rather than each picking their own.
static int infoBarScale = 2;

static bool infoBarActive() {
  return infoBarUntil != 0 && (int32_t)(millis() - infoBarUntil) < 0;
}

// The largest legible glyph scale for this text on a panel frameWidth px
// wide: prefer 2x (14px glyphs - drawIdleScreen's own "prefer the larger
// text" default), drop to 1x only if the string would not fit at 2x. A bare
// scale=1 bar reads as an illegible smear of pixels at this panel's size,
// which is what the very first hardware pass of this feature showed - this
// mirrors drawIdleScreen's own scale-fallback exactly rather than inventing
// a second policy for "how big should on-device text be".
static int infoBarGlyphScale(const char *text, int frameWidth) {
  int scale = 2;
  if ((int)strlen(text) * 6 * scale > frameWidth - 2 * 4) {
    scale = 1;
  }
  return scale;
}

// True while the current press has already been spent waking the panel.
static bool touchConsumed = false;

static bool touchWakeActive() {
  return touchWakeUntil != 0 && (int32_t)(millis() - touchWakeUntil) < 0;
}

static uint8_t currentBrightness() {
  return panelstate::backlightLevel(panelManuallyOff, displaySleeping,
                                    idleActive, touchWakeActive(), userBlLevel,
                                    BL_IDLE);
}

// Push a raw level to whichever brightness sink this board has: PWM duty on
// the backlight pin, or the panel's own 0x51 command on the AMOLED (which
// has no backlight - each pixel emits, and level 0 means a black panel, not
// a powered-down one). Safe to call before the panel exists: the panel path
// does nothing until initDisplay() has run.
static void driveBrightness(uint8_t level) {
  if (bcfg->hasBacklightPin()) {
    analogWrite(bcfg->pinBl, level);
  } else if (panel != nullptr) {
    boardpanel::setPanelBrightness(panel, *bcfg, level);
  }
}

// Drive the brightness to whatever the current state calls for. Every place
// that used to repeat the sleep/idle/high/low ternary now goes through here,
// so the sink can no longer disagree with what is reported over the network.
static void applyBacklight() { driveBrightness(currentBrightness()); }

// ---- Identify ----------------------------------------------------------
// "Which panel is this?" must work on both boards, and only one of them has an
// addressable LED, so the primary signal is a backlight pulse: present on every
// board and visible across a room. Where an LED does exist it still turns blue
// as well, so nothing regresses on the boards that already had that.
static const uint32_t IDENTIFY_BLINK_MS = 250;
static uint32_t identifyUntil = 0;
static uint32_t identifyPhaseAt = 0;
static bool identifyPhaseHigh = false;

// Deliberately not folded into applyBacklight()/currentBrightness(): the
// brightness reported over EINF/EACK must stay the steady value the user chose.
// If the pulse went through the reported path, every telemetry packet during an
// identify would carry a different number and the manager's slider would twitch.
static void updateIdentify() {
  if (identifyUntil == 0) return;
  uint32_t now = millis();
  if ((int32_t)(now - identifyUntil) >= 0) {
    identifyUntil = 0;
    applyBacklight();  // hand the pin back to the sleep/idle/user state machine
    return;
  }
  if (now - identifyPhaseAt < IDENTIFY_BLINK_MS) return;
  identifyPhaseAt = now;
  identifyPhaseHigh = !identifyPhaseHigh;
  driveBrightness(identifyPhaseHigh ? 255 : BL_LOW);
}

static void sendDeviceInfo() {
  if (hbPort == 0) return;
  uint8_t packet[96];
  size_t len = deviceproto::writeInfo(
      packet, sizeof(packet), currentDeviceFlags(), deviceCapabilities(),
      millis() / 1000, WiFi.status() == WL_CONNECTED ? (int16_t)WiFi.RSSI() : -127,
      currentBrightness(), deviceId, cfgName.c_str(), FW_VERSION);
  if (len > 0) {
    sendToSender(packet, len);
  }
}

// Sample the PMU and report it. Its own packet rather than fields on EINF: an
// already-shipped sender length-checks EINF exactly and would reject every one
// of them, whereas an unknown packet type is simply dropped (see the EBAT
// comment in device_protocol.h).
static void sendBatteryStatus() {
  if (!batteryAvailable) return;
  boardpower::Reading reading;
  if (!boardpower::read(reading)) return;
  lastBattery = reading;
  batteryReadingValid = true;
  lastBatteryAt = millis();
  if (hbPort == 0) return;

  uint8_t flags = 0;
  if (reading.present) flags |= deviceproto::BATTERY_FLAG_PRESENT;
  if (reading.externalPower) flags |= deviceproto::BATTERY_FLAG_EXTERNAL_POWER;
  deviceproto::ChargeState state = deviceproto::ChargeState::Unknown;
  switch (reading.charge) {
    case boardpower::Charge::Charging:
      state = deviceproto::ChargeState::Charging;
      break;
    case boardpower::Charge::Discharging:
      state = deviceproto::ChargeState::Discharging;
      break;
    case boardpower::Charge::Standby:
      state = deviceproto::ChargeState::Standby;
      break;
    case boardpower::Charge::Unknown:
      break;
  }

  uint8_t packet[deviceproto::BATTERY_PACKET_BYTES];
  deviceproto::writeBattery(
      packet, flags,
      reading.percentKnown ? reading.percent : deviceproto::BATTERY_PERCENT_UNKNOWN,
      state, reading.millivolts);
  sendToSender(packet, sizeof(packet));
}

// board_power.h's Charge enum to panel_state.h's - two separate types for the
// reason board_power.h's own doc comment gives (that header stays independent
// of the wire/UI format), so every caller that wants a word or a formatted
// line converts through here rather than switching on boardpower::Charge
// itself in more than one place.
static panelstate::Charge toChargeWord(boardpower::Charge charge) {
  switch (charge) {
    case boardpower::Charge::Charging:
      return panelstate::Charge::Charging;
    case boardpower::Charge::Discharging:
      return panelstate::Charge::Discharging;
    case boardpower::Charge::Standby:
      return panelstate::Charge::Standby;
    default:
      return panelstate::Charge::Unknown;
  }
}

// Charge state as one word, for the serial status line. Forwards to
// panelstate::chargeWord so the serial line and the on-device idle card
// (drawIdleScreen(), via panelstate::formatBatteryLine) cannot disagree on
// what a charge state is called - one word list, one place, every caller.
static const char *batteryChargeWord(boardpower::Charge charge) {
  return panelstate::chargeWord(toChargeWord(charge));
}

// Whether the cached reading is recent enough to quote. False before the first
// sample and again once one stops arriving - a PMU that answered at boot and then
// died must not keep its percentage on the serial line and in CFGSHOW, which are
// the only ways to read a battery on a panel no sender has found.
static bool batteryReadingCurrent() {
  return batteryAvailable && batteryReadingValid &&
         deviceproto::batteryReadingCurrent(millis(), lastBatteryAt);
}

// Battery percentage for CFGSHOW, or -1 when there is no PMU, no cell, no
// settled gauge reading, or nothing recent enough to report. Negative rather
// than 0 so "we do not know" can never be read as "empty".
static int batteryPercentOrUnknown() {
  if (!batteryReadingCurrent()) return -1;
  if (!lastBattery.present || !lastBattery.percentKnown) return -1;
  return (int)lastBattery.percent;
}

static void sendControlAck(const deviceproto::ControlCommand &command,
                           uint8_t status = 0) {
  if (hbPort == 0) return;
  uint8_t packet[deviceproto::ACK_PACKET_BYTES];
  deviceproto::writeAck(packet, command.opcode, command.sequence, status,
                        currentDeviceFlags(), currentBrightness());
  sendToSender(packet, sizeof(packet));
}

static void applyPendingControl() {
  deviceproto::ControlCommand command;
  deviceproto::ControlCommand duplicateAck;
  bool hasCommand = false;
  bool hasDuplicateAck = false;
  portENTER_CRITICAL(&controlMux);
  hasCommand = controls.take(command);
  hasDuplicateAck = controls.takeDuplicateAck(duplicateAck);
  portEXIT_CRITICAL(&controlMux);

  if (hasCommand) {
    uint8_t ackStatus = 0;
    switch (command.opcode) {
      case deviceproto::ControlOpcode::Brightness:
        userBlLevel = command.value != 0 ? BL_HIGH : BL_LOW;
        saveDisplayPrefs();
        applyBacklight();
        Serial.printf("network: backlight %s (saved)\n", blIsHigh() ? "high" : "low");
        break;
      case deviceproto::ControlOpcode::BrightnessLevel:
        userBlLevel = (uint8_t)command.value;
        saveDisplayPrefs();
        applyBacklight();
        Serial.printf("network: backlight level %u (saved)\n", userBlLevel);
        break;
      case deviceproto::ControlOpcode::Flip:
        // Kept for old senders. Flip 1 is rotation 2; Flip 0 is upright.
        // Deliberately absolute rather than "toggle the 180 bit": a sender
        // that says Flip 0 means "upright", and leaving a quarter turn
        // standing would contradict it.
        panelRotation = command.value != 0 ? 2 : 0;
        madctlDirty = true;
        saveDisplayPrefs();
        Serial.printf("network: flip180=%d -> rotation=%u (saved)\n",
                      command.value != 0, panelRotation);
        break;
      case deviceproto::ControlOpcode::Rotate:
        if ((command.value & 1) != 0 && bcfg->panelW != bcfg->panelH) {
          // Defense in depth behind the capability gate: CAP_ROTATE is not
          // advertised on rectangular glass, so a well-behaved sender never
          // sends 1 or 3 here - but one that does gets a NACK it can tell
          // from packet loss, not silence.
          ackStatus = 1;
          Serial.printf("network: rotate %ld refused (panel not square)\n",
                        (long)command.value);
          break;
        }
        panelRotation = (uint8_t)(command.value & 3);
        madctlDirty = true;
        saveDisplayPrefs();
        Serial.printf("network: rotation=%u (saved)\n", panelRotation);
        break;
      case deviceproto::ControlOpcode::Power:
        panelManuallyOff = command.value == 0;
        saveDisplayPrefs();
        applyBacklight();
        Serial.printf("network: display %s (saved)\n",
                      panelManuallyOff ? "off" : "on");
        break;
      case deviceproto::ControlOpcode::Identify:
        // Backlight pulse on every board; LED too where there is one.
        identifyUntil = millis() + (uint32_t)command.value * 1000;
        identifyPhaseAt = 0;  // pulse on the next loop pass, not one blink later
        if (bcfg->hasRgbLed() && rgbLed != nullptr) {
          rgbLed->fill(rgbLed->Color(0, 96, 255));
          rgbLed->show();
          ledOverrideUntil = identifyUntil;
        }
        Serial.printf("network: identify for %lds\n", (long)command.value);
        break;
      case deviceproto::ControlOpcode::Restart:
        restartAt = millis() + 500;
        Serial.println("network: restart requested");
        break;
    }
    portENTER_CRITICAL(&controlMux);
    controls.markApplied(command.sequence);
    portEXIT_CRITICAL(&controlMux);
    sendControlAck(command, ackStatus);
    sendDeviceInfo();
  }
  if (hasDuplicateAck) {
    sendControlAck(duplicateAck);
  }
}

// Serial configuration protocol (USB CDC), so credentials can change
// without reflashing:
//   CFGWIFI <base64 ssid> <base64 password>\n  -> save to NVS, reply
//     CFGOK, reboot onto the new network (empty password = open network)
//   CFGOTAPW <base64 password> | CFGOTAPW clear\n  -> enable/disable OTA
//   CFGSHOW\n  -> CFGINFO ssid=... ip=... rssi=...
// Base64 avoids every quoting hazard SSIDs and passwords can contain.
static void processConfigLine(char *line) {
  if (strncmp(line, "CFGWIFI ", 8) == 0) {
    // CFGWIFI <b64 ssid> <b64 pass>  set both (empty pass = open network)
    // CFGWIFI <b64 ssid>             keep the password currently in use
    // The second form exists so changing the SSID (or just re-saving)
    // doesn't force the user to retype their password - and so a blank
    // field can never silently wipe a working password.
    char *b64Ssid = line + 8;
    char *sep = strchr(b64Ssid, ' ');
    bool keepPassword = (sep == nullptr);
    char *b64Pass = nullptr;
    if (!keepPassword) {
      *sep = 0;
      b64Pass = sep + 1;
    }

    unsigned char ssid[33], pass[65];
    size_t ssidLen = 0, passLen = 0;
    if (mbedtls_base64_decode(ssid, sizeof(ssid) - 1, &ssidLen,
                              (const unsigned char *)b64Ssid, strlen(b64Ssid)) != 0) {
      Serial.println("CFGERR bad base64 ssid (max 32 bytes)");
      return;
    }
    ssid[ssidLen] = 0;
    if (ssidLen == 0) {
      Serial.println("CFGERR empty ssid");
      return;
    }
    if (!keepPassword) {
      if (mbedtls_base64_decode(pass, sizeof(pass) - 1, &passLen,
                                (const unsigned char *)b64Pass, strlen(b64Pass)) != 0) {
        Serial.println("CFGERR bad base64 password (max 64 bytes)");
        return;
      }
      pass[passLen] = 0;
    }

    Preferences prefs;
    prefs.begin("espdisp", false);
    prefs.putString("ssid", (const char *)ssid);
    // When keeping, persist the *effective* password (which may have come
    // from the compiled fallback) so "keep" means exactly "what works now"
    // regardless of where it came from.
    prefs.putString("pass", keepPassword ? cfgPass : String((const char *)pass));
    prefs.end();

    Serial.printf("CFGOK saved \"%s\"%s, restarting\n", (const char *)ssid,
                  keepPassword ? " (password kept)" : "");
    Serial.flush();
    delay(200);
    ESP.restart();
  } else if (strncmp(line, "CFGNAME ", 8) == 0) {
    // Set the device name (mDNS hostname + service instance). Base64 like
    // CFGWIFI; sanitized to hostname-safe [a-z0-9-], max 32 chars.
    unsigned char raw[48];
    size_t rawLen = 0;
    if (mbedtls_base64_decode(raw, sizeof(raw) - 1, &rawLen,
                              (const unsigned char *)(line + 8),
                              strlen(line + 8)) != 0) {
      Serial.println("CFGERR bad base64");
      return;
    }
    raw[rawLen] = 0;
    char clean[33];
    size_t n = 0;
    for (size_t i = 0; i < rawLen && n < sizeof(clean) - 1; i++) {
      char c = (char)tolower(raw[i]);
      if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-') {
        clean[n++] = c;
      } else if (c == ' ' || c == '_') {
        clean[n++] = '-';
      }
    }
    clean[n] = 0;
    if (n == 0) {
      Serial.println("CFGERR name has no hostname-safe characters");
      return;
    }
    Preferences prefs;
    prefs.begin("espdisp", false);
    prefs.putString("name", clean);
    prefs.end();
    Serial.printf("CFGOK name \"%s\", restarting\n", clean);
    Serial.flush();
    delay(200);
    ESP.restart();
  } else if (strncmp(line, "CFGFLIP ", 8) == 0) {
    // Set the 180-degree flip without the button: CFGFLIP 0|1. Kept beside
    // CFGROT for old tooling and muscle memory; it maps onto the same stored
    // rotation (1 -> rot 2, 0 -> rot 0). Persisted, and applied on the next
    // drawn frame.
    int want = atoi(line + 8);
    panelRotation = want != 0 ? 2 : 0;
    madctlDirty = true;
    saveDisplayPrefs();
    Serial.printf("CFGOK flip180=%d rot=%u (saved; applies with next frame)\n",
                  want != 0, panelRotation);
  } else if (strncmp(line, "CFGROT ", 7) == 0) {
    // Set the mounting rotation in clockwise quarter turns: CFGROT 0|1|2|3.
    // Quarter turns (1 and 3) are refused on rectangular glass for the same
    // reason CAP_ROTATE is not advertised there: a physical 90-degree turn
    // of those panels is what the sender's landscape mechanism expresses,
    // and a MADCTL quarter turn would fight it. Persisted, and applied on
    // the next drawn frame.
    int want = atoi(line + 7);
    if (want < 0 || want > 3) {
      Serial.println("CFGERR expected: CFGROT 0|1|2|3");
      return;
    }
    if ((want & 1) != 0 && bcfg->panelW != bcfg->panelH) {
      Serial.printf("CFGERR rotation %d needs a square panel (%s is %ux%u); "
                    "only 0 and 2 apply here\n",
                    want, bcfg->name, bcfg->panelW, bcfg->panelH);
      return;
    }
    panelRotation = (uint8_t)want;
    madctlDirty = true;
    saveDisplayPrefs();
    Serial.printf("CFGOK rot=%u (saved; applies with next frame)\n",
                  panelRotation);
  } else if (strncmp(line, "CFGPOWER ", 9) == 0) {
    // Manual on/off without the network path: CFGPOWER 0|1. Mirrors the
    // Power control opcode exactly (same flag, same NVS key, same priority
    // over touch-wake) so a bench test over serial behaves identically to a
    // toggle from the app. Persisted, so it survives a reboot too.
    int want = atoi(line + 9);
    if (want != 0 && want != 1) {
      Serial.println("CFGERR expected: CFGPOWER 0|1");
      return;
    }
    panelManuallyOff = want == 0;
    saveDisplayPrefs();
    applyBacklight();
    Serial.printf("CFGOK pwr=%s (saved)\n", panelManuallyOff ? "off" : "on");
  } else if (strncmp(line, "CFGBOARD ", 9) == 0) {
    // Override board auto-detection: CFGBOARD st7789|jd9853|auto.
    // The escape hatch for a board whose I2C peripherals do not answer, and the
    // way to undo a wrong forcing ("auto"). Reboots, because the pin map and
    // panel driver are chosen during setup and cannot be swapped underneath a
    // running panel.
    const char *token = line + 9;
    board::Variant want = board::variantFromName(token);
    bool isAuto = strcmp(token, "auto") == 0;
    if (want == board::Variant::Unknown && !isAuto) {
      Serial.println("CFGERR expected: CFGBOARD st7789|jd9853|co5300|auto");
      return;
    }
    if (board::COMPILED_VARIANT != board::Variant::Unknown) {
      // Single-board chips have nothing to override: the variant is a
      // compile-time fact there, and persisting a wrong answer would only
      // manufacture a broken boot.
      Serial.printf("CFGERR board is fixed at compile time on this chip (%s)\n",
                    board::variantToken(board::COMPILED_VARIANT));
      return;
    }
    if (want != board::Variant::Unknown) {
      const board::Config &wantCfg = board::configFor(want);
      if (wantCfg.panelW != PANEL_GEOMETRY.width ||
          wantCfg.panelH != PANEL_GEOMETRY.height) {
        // Buffers, band layout, and the mDNS advertisement in this binary are
        // sized for the compiled resolution; forcing a board with different
        // glass cannot work, so refuse rather than persist a broken boot.
        Serial.printf("CFGERR %s is %ux%u; this binary is built for %ux%u\n",
                      board::variantToken(want), wantCfg.panelW, wantCfg.panelH,
                      PANEL_GEOMETRY.width, PANEL_GEOMETRY.height);
        return;
      }
    }
    Preferences prefs;
    prefs.begin("espdisp", false);
    prefs.putUChar("board", (uint8_t)want);
    prefs.end();
    Serial.printf("CFGOK board=%s, restarting\n", board::variantToken(want));
    Serial.flush();
    delay(200);
    ESP.restart();
  } else if (strncmp(line, "CFGLED ", 7) == 0) {
    // Diagnostic: show a literal color for 10s (CFGLED <r> <g> <b>, 0-255).
    // Lets channel-order problems be diagnosed over serial: send pure red,
    // ask what color appears.
    int r, g, b;
    if (sscanf(line + 7, "%d %d %d", &r, &g, &b) != 3) {
      Serial.println("CFGERR expected: CFGLED <r> <g> <b>");
      return;
    }
    if (rgbLed == nullptr) {
      // Say so rather than accepting silently: on this board the command has
      // nothing to drive, and a bare CFGOK would look like the LED is broken.
      Serial.printf("CFGERR no addressable LED on %s\n", bcfg->name);
      return;
    }
    rgbLed->fill(rgbLed->Color(r & 0xFF, g & 0xFF, b & 0xFF));
    rgbLed->show();
    ledOverrideUntil = millis() + 10000;
    Serial.printf("CFGOK led r=%d g=%d b=%d for 10s\n", r & 0xFF, g & 0xFF, b & 0xFF);
  } else if (strncmp(line, "CFGOTAPW ", 9) == 0) {
    // Set or clear the OTA password:
    //   CFGOTAPW <b64 password>  enable OTA with this password
    //   CFGOTAPW clear           forget it, which turns OTA off again
    // Base64 for exactly the reason CFGWIFI uses it - a password may contain
    // any character a shell or a space-delimited line would eat. One byte is
    // still refused, and it is refused rather than mangled: a 0x00 anywhere in
    // the decoded password is rejected below, because NVS, ArduinoOTA and espota
    // all handle it as a C string. "clear" cannot
    // collide with a real payload because it is recognised as a literal BEFORE
    // any decode is attempted, which is a property of the order below rather
    // than of the string (see otapolicy::classifyArgument, which owns and
    // documents that; an earlier comment here claimed five characters can never
    // be valid base64, which is a claim about decoders and not one to rely on).
    //
    // Both forms restart. OTA is brought up during setup and its bit is baked
    // into the mDNS caps TXT record there, so a reboot is the honest way to make
    // the panel's advertisement agree with its state.
    const char *arg = line + 9;
    Preferences prefs;
    if (otapolicy::classifyArgument(arg) == otapolicy::Argument::Clear) {
      prefs.begin("espdisp", false);
      prefs.remove("otapw");
      prefs.end();
      Serial.println("CFGOK ota password cleared (OTA off), restarting");
      Serial.flush();
      delay(200);
      ESP.restart();
      return;
    }
    // Sized so the decode cannot fail for want of room, which keeps "not
    // base64" and "too long" distinguishable: the config line is 256 bytes
    // including its terminator, so the argument is at most 246 characters and
    // decodes to at most 185 bytes. The length policy is then applied to the
    // result rather than being an accident of this buffer's size.
    unsigned char pw[193];
    size_t pwLen = 0;
    const bool decoded = mbedtls_base64_decode(pw, sizeof(pw) - 1, &pwLen,
                                               (const unsigned char *)arg,
                                               strlen(arg)) == 0;
    switch (otapolicy::verifyPassword(decoded, pw, pwLen)) {
      case otapolicy::Verdict::NotBase64:
        Serial.println("CFGERR bad base64 password");
        return;
      case otapolicy::Verdict::EmbeddedNul:
        // Refused rather than stored: putString below would cut the password at
        // that byte, ArduinoOTA's setPassword would hash the same short prefix,
        // and espota cannot pass a 0x00 in argv anyway - so this password can
        // never work end to end, and accepting it would leave the panel
        // listening with a secret shorter than the floor above promises.
        // otapolicy::verifyPassword documents the full chain.
        Serial.println("CFGERR ota password must not contain a 0x00 byte "
                       "(it would be stored truncated; try another)");
        return;
      case otapolicy::Verdict::TooShort:
        // Refused rather than accepted: this one password is the only thing
        // between the LAN and a firmware write, espota can be retried as fast
        // as the panel will answer, and a weak one is worse than no OTA at all.
        Serial.printf("CFGERR ota password must be at least %u bytes "
                      "(or: CFGOTAPW clear)\n",
                      (unsigned)otapolicy::PASSWORD_MIN_BYTES);
        return;
      case otapolicy::Verdict::TooLong:
        Serial.printf("CFGERR ota password must be at most %u bytes\n",
                      (unsigned)otapolicy::PASSWORD_MAX_BYTES);
        return;
      case otapolicy::Verdict::Accept:
        break;
    }
    pw[pwLen] = 0;
    prefs.begin("espdisp", false);
    prefs.putString("otapw", (const char *)pw);
    prefs.end();
    // The length, never the password - not even a prefix of it.
    Serial.printf("CFGOK ota password set (%u bytes), restarting\n",
                  (unsigned)pwLen);
    Serial.flush();
    delay(200);
    ESP.restart();
  } else if (strcmp(line, "CFGSHOW") == 0) {
    // ssid64 first: base64 keeps SSIDs with spaces parseable in a
    // space-delimited line. Plain ssid goes last, for humans on a monitor.
    unsigned char b64[48], name64[48];
    size_t b64Len = 0, name64Len = 0;
    mbedtls_base64_encode(b64, sizeof(b64) - 1, &b64Len,
                          (const unsigned char *)cfgSsid.c_str(), cfgSsid.length());
    b64[b64Len] = 0;
    mbedtls_base64_encode(name64, sizeof(name64) - 1, &name64Len,
                          (const unsigned char *)cfgName.c_str(), cfgName.length());
    name64[name64Len] = 0;
    // ota= is three-valued on purpose: "off" (no password stored), "pending" (a
    // password is stored but the radio was not ready when setup ran, so nothing
    // is listening yet), "on" (listening). Reporting only on/off would make a
    // panel that simply booted without WiFi look misconfigured. The mapping is
    // otapolicy::statusToken, tested on the host.
    // flip= stays (derived: rotation == 2) so anything parsing the old field
    // keeps reading the truth; rot= carries the full quarter-turn value.
    Serial.printf(
        "CFGINFO ssid64=%s name64=%s connected=%d ip=%s rssi=%d flip=%d "
        "rot=%u bl=%s pwr=%s board=%s bat=%d ota=%s ssid=%s\n",
        (const char *)b64, (const char *)name64, WiFi.status() == WL_CONNECTED,
        WiFi.localIP().toString().c_str(), (int)WiFi.RSSI(),
        panelRotation == 2, panelRotation,
        blIsHigh() ? "high" : "low", panelManuallyOff ? "off" : "on",
        board::variantToken(boardVariant),
        batteryPercentOrUnknown(),
        otapolicy::statusToken(currentOtaStatus()), cfgSsid.c_str());
  }
  // Anything else on serial is ignored (a monitor typing away is harmless).
}

static void handleSerialConfig() {
  static char line[256];
  static size_t lineLen = 0;
  while (Serial.available() > 0) {
    char c = (char)Serial.read();
    if (c == '\n' || c == '\r') {
      if (lineLen > 0) {
        line[lineLen] = 0;
        lineLen = 0;
        processConfigLine(line);
      }
    } else if (lineLen < sizeof(line) - 1) {
      line[lineLen++] = c;
    } else {
      lineLen = 0;  // oversized garbage: reset
    }
  }
}

#include "font5x7.h"  // classic 5x7 ASCII font (Adafruit GFX, BSD license)

// Draw scaled 5x7 text into an RGB565 big-endian buffer of bufW x bufH.
static void drawText(uint8_t *buf, int bufW, int bufH, int x, int y,
                     const char *s, uint16_t color, int scale) {
  for (; *s; s++) {
    for (int col = 0; col < 5; col++) {
      uint8_t bits = font[(size_t)(unsigned char)*s * 5 + col];
      for (int row = 0; row < 7; row++) {
        if (!(bits & (1 << row))) {
          continue;
        }
        for (int sy = 0; sy < scale; sy++) {
          for (int sx = 0; sx < scale; sx++) {
            int px = x + col * scale + sx;
            int py = y + row * scale + sy;
            if (px < 0 || py < 0 || px >= bufW || py >= bufH) {
              continue;
            }
            size_t off = ((size_t)py * bufW + px) * 2;
            buf[off] = color >> 8;
            buf[off + 1] = color & 0xFF;
          }
        }
      }
    }
    x += 6 * scale;
  }
}

// White text with a 1px black outline so it reads over any frame content.
static void drawOutlinedText(uint8_t *buf, int bufW, int bufH, int x, int y,
                             const char *s, int scale) {
  for (int dy = -1; dy <= 1; dy++) {
    for (int dx = -1; dx <= 1; dx++) {
      if (dx || dy) {
        drawText(buf, bufW, bufH, x + dx, y + dy, s, 0x0000, scale);
      }
    }
  }
  drawText(buf, bufW, bufH, x, y, s, 0xFFFF, scale);
}

// Compose the idle card over the (pristine) last frame in bufA and push it.
// Text position moves on every draw to avoid burn-in.
static void drawIdleScreen() {
  int w = bufLandscape ? PANEL_H : PANEL_W;
  int hgt = bufLandscape ? PANEL_W : PANEL_H;

  // Copy the pushed lines out from under the UDP task before formatting.
  deviceproto::IdleTextMessage pushed;
  uint32_t pushedAt;
  portENTER_CRITICAL(&controlMux);
  pushed = idleText;
  pushedAt = idleTextAt;
  portEXIT_CRITICAL(&controlMux);

  char lineIp[24], lineWifi[24], lineAge[32], lineBattery[24];
  const char *lineName = cfgName.c_str();
  snprintf(lineIp, sizeof(lineIp), "%s", WiFi.localIP().toString().c_str());
  panelstate::formatWifiLine(lineWifi, sizeof(lineWifi),
                             WiFi.status() == WL_CONNECTED, (int)WiFi.RSSI());
  // Only for a board with a PMU and a reading that has not aged out - a C6
  // never has one, and a stale reading is worse than none (see
  // panelstate::shouldShowBatteryLine).
  const bool showBattery =
      panelstate::shouldShowBatteryLine(bcfg->hasBattery(), batteryReadingCurrent());
  if (showBattery) {
    // The full charging/discharging/standby distinction, not just a terse
    // "chg" flag - see panelstate::formatBatteryLine's doc comment for why
    // this line used to say less than the protocol and the Mac app already
    // know about this reading.
    panelstate::formatBatteryLine(
        lineBattery, sizeof(lineBattery), lastBattery.externalPower,
        lastBattery.present, lastBattery.percentKnown, lastBattery.percent,
        toChargeWord(lastBattery.charge));
  }

  // Room for the pushed lines, an age line, and the four status lines.
  const char *lines[deviceproto::IDLE_TEXT_MAX_LINES + 5];
  int lineCount = 0;
  if (pushed.lineCount > 0) {
    for (uint8_t i = 0; i < pushed.lineCount; i++) {
      lines[lineCount++] = pushed.lines[i];
    }
    // Say how stale it is. The panel has no clock, so pushed content silently
    // ageing would be worse than not showing it at all.
    const uint32_t ageSeconds = (millis() - pushedAt) / 1000;
    if (ageSeconds < 60) {
      snprintf(lineAge, sizeof(lineAge), "as of %lus ago",
               (unsigned long)ageSeconds);
    } else if (ageSeconds < 3600) {
      snprintf(lineAge, sizeof(lineAge), "as of %lum ago",
               (unsigned long)(ageSeconds / 60));
    } else {
      snprintf(lineAge, sizeof(lineAge), "as of %luh ago",
               (unsigned long)(ageSeconds / 3600));
    }
    lines[lineCount++] = lineAge;
  } else {
    // Nothing pushed, so draw the card the panel can build by itself. The
    // sender expresses exactly these three lines as its default screensaver
    // template, so a user who edits that template replaces them rather than
    // adding to them - appending them unconditionally used to print the name,
    // address, and signal twice for anyone whose template already had them.
    // Battery is appended rather than folded into the template, because only
    // one board in the fleet has one to report.
    lines[lineCount++] = lineName;
    lines[lineCount++] = lineIp;
    lines[lineCount++] = lineWifi;
    if (showBattery) lines[lineCount++] = lineBattery;
  }

  size_t maxLen = 0;
  for (int i = 0; i < lineCount; i++) {
    size_t n = strlen(lines[i]);
    if (n > maxLen) maxLen = n;
  }
  // On round glass the corners of the framebuffer are not on the panel, so
  // the card keeps to the inscribed square: an extra inset of
  // r*(1 - 1/sqrt(2)) per edge, ~14.6% of the diameter. Rectangular panels
  // keep the original 4px margin exactly.
  int margin = 4;
  if (bcfg->roundDisplay) {
    int d = w < hgt ? w : hgt;
    margin += (int)(0.1465f * (float)d);
  }
  // Prefer the larger text, but drop a size rather than run off the panel:
  // pushed lines can be far longer than the three status lines ever are.
  int scale = 2;
  if ((int)maxLen * 6 * scale > w - 2 * margin ||
      lineCount * 9 * scale > hgt - 2 * margin) {
    scale = 1;
  }
  const int lineH = 9 * scale;  // 7px glyph + spacing
  int blockW = (int)maxLen * 6 * scale;
  int blockH = lineCount * lineH;

  // Pseudo-random position within margins; esp_random is hardware RNG.
  int maxX = w - blockW - margin;
  int maxY = hgt - blockH - margin;
  int x = margin +
          (maxX > margin ? (int)(esp_random() % (uint32_t)(maxX - margin + 1)) : 0);
  int y = margin +
          (maxY > margin ? (int)(esp_random() % (uint32_t)(maxY - margin + 1)) : 0);

  memcpy(bufB, bufA, FRAME_BYTES);  // bufA stays pristine for the overlay
  for (int i = 0; i < lineCount; i++) {
    drawOutlinedText(bufB, w, hgt, x, y + i * lineH, lines[i], scale);
  }

  dmaInFlight = dmaInFlight + 1;
  dmaQueuedAt = millis();
  if (esp_lcd_panel_draw_bitmap(panel, 0, 0, w, hgt, bufB) != ESP_OK) {
    statDrawErrors = statDrawErrors + 1;
    dmaInFlight = dmaInFlight - 1;
  }
  lastIdleDrawAt = millis();
}

// What the quick info bar says by default: battery on a board that has one
// and a current reading, "usb power" is folded into that by
// formatBatteryLine already, and the WiFi line on a board with no battery to
// report (both C6 boards - see board_config.h's PowerController comment) so
// a tap there still shows something rather than an empty bar.
//
// A single word ("default") rather than the whole line, because this is the
// one point meant to grow into a user-customisable choice later - the To-do
// item that asked for this bar called it out explicitly - and everything
// downstream of this function already treats the bar's text as an opaque
// string, so swapping in a different default (or a small rotation of them)
// is a change to this function alone.
static const char *defaultInfoBarText() {
  static char text[24];
  if (panelstate::shouldShowBatteryLine(bcfg->hasBattery(),
                                       batteryReadingCurrent())) {
    panelstate::formatBatteryLine(text, sizeof(text), lastBattery.externalPower,
                                  lastBattery.present, lastBattery.percentKnown,
                                  lastBattery.percent,
                                  toChargeWord(lastBattery.charge));
  } else if (WiFi.status() == WL_CONNECTED) {
    panelstate::formatWifiLine(text, sizeof(text), true, (int)WiFi.RSSI());
  } else {
    panelstate::formatWifiLine(text, sizeof(text), false, 0);
  }
  return text;
}

// Show (or refresh) the quick info bar: a centred status line across the top
// of the panel for INFO_BAR_MS, triggered by a plain tap on a lit panel.
//
// Composed the same way drawIdleScreen composes the idle card - onto bufB
// from bufA, so bufA (the network path's always-current framebuffer, see
// the comment on bufA/bufB near their declaration) stays the ground truth
// this bar sits on top of rather than replaces - but only the bar's OWN row
// range is touched, not the whole frame: streaming keeps drawing everywhere
// else uninterrupted, which is the entire point of this being a bar and not
// a card.
static void showInfoBar(const char *text) {
  if (bufB == nullptr || panel == nullptr) return;

  const int w = bufLandscape ? PANEL_H : PANEL_W;
  const int hgt = bufLandscape ? PANEL_W : PANEL_H;

  strncpy(infoBarText, text, sizeof(infoBarText) - 1);
  infoBarText[sizeof(infoBarText) - 1] = 0;
  infoBarScale = infoBarGlyphScale(infoBarText, w);
  const int lineH = 9 * infoBarScale;
  panelstate::infoBarRowRange(w, hgt, bcfg->roundDisplay, lineH, infoBarY0,
                              infoBarY1);
  infoBarUntil = millis() + INFO_BAR_MS;

  waitForDmaIdle(200);  // bufB may still be feeding a previous transfer
  size_t rowBytes = (size_t)w * 2;
  size_t off = (size_t)infoBarY0 * rowBytes;
  size_t bytes = (size_t)(infoBarY1 - infoBarY0) * rowBytes;
  memcpy(bufB + off, bufA + off, bytes);  // bufA stays pristine for the overlay
  int textX = panelstate::centeredX(
      w, (int)strlen(infoBarText) * 6 * infoBarScale);
  drawOutlinedText(bufB, w, hgt, textX, infoBarY0, infoBarText, infoBarScale);

  dmaInFlight = dmaInFlight + 1;
  dmaQueuedAt = millis();
  if (esp_lcd_panel_draw_bitmap(panel, 0, infoBarY0, w, infoBarY1,
                                bufB + off) != ESP_OK) {
    statDrawErrors = statDrawErrors + 1;
    dmaInFlight = dmaInFlight - 1;
  }
}

// Redraw the info bar's row range from bufA (plain, no text) once its
// window has elapsed, so its last-shown text does not linger as a stale
// overlay once the bar itself has expired. bufA is guaranteed current for
// every row (see the comment on bufA's declaration), including the bar's,
// because the network task keeps writing every arriving band into it
// regardless of whether the bar is covering that row on the panel right now
// - which is exactly what makes "just redraw bufA's rows" a correct revert
// rather than a stale snapshot.
static void clearInfoBarIfExpired() {
  if (infoBarUntil == 0 || infoBarActive()) return;
  infoBarUntil = 0;
  if (bufB == nullptr || panel == nullptr) return;
  const int w = bufLandscape ? PANEL_H : PANEL_W;
  waitForDmaIdle(200);
  size_t rowBytes = (size_t)w * 2;
  size_t off = (size_t)infoBarY0 * rowBytes;
  size_t bytes = (size_t)(infoBarY1 - infoBarY0) * rowBytes;
  memcpy(bufB + off, bufA + off, bytes);
  dmaInFlight = dmaInFlight + 1;
  dmaQueuedAt = millis();
  if (esp_lcd_panel_draw_bitmap(panel, 0, infoBarY0, w, infoBarY1,
                                bufB + off) != ESP_OK) {
    statDrawErrors = statDrawErrors + 1;
    dmaInFlight = dmaInFlight - 1;
  }
}

// Redraw the bar over its own row range after a streaming run that just
// overwrote part or all of it with fresh frame content. Called from
// loop()'s per-run draw path (see forEachRun's lambda) whenever a run's
// rows overlap the bar's, so a live stream cannot silently erase the bar
// mid-window the way a plain per-band draw_bitmap would.
//
// Self-contained rather than reusing whatever the triggering run left in
// bufB: that run's own row range and the bar's may only partially overlap,
// so bufB is not guaranteed valid across the bar's whole range going in.
// This re-copies bufA -> bufB for exactly the bar's rows first, the same way
// showInfoBar() does, then draws text on top - bufA is always current (see
// its declaration comment), so this is a correct base regardless of which
// run triggered the call.
static void redrawInfoBarOverRun() {
  if (bufB == nullptr || panel == nullptr) return;
  const int w = bufLandscape ? PANEL_H : PANEL_W;
  const int hgt = bufLandscape ? PANEL_W : PANEL_H;
  size_t rowBytes = (size_t)w * 2;
  size_t off = (size_t)infoBarY0 * rowBytes;
  size_t bytes = (size_t)(infoBarY1 - infoBarY0) * rowBytes;
  memcpy(bufB + off, bufA + off, bytes);
  int textX = panelstate::centeredX(
      w, (int)strlen(infoBarText) * 6 * infoBarScale);
  drawOutlinedText(bufB, w, hgt, textX, infoBarY0, infoBarText, infoBarScale);
  dmaInFlight = dmaInFlight + 1;
  dmaQueuedAt = millis();
  if (esp_lcd_panel_draw_bitmap(panel, 0, infoBarY0, w, infoBarY1,
                                bufB + off) != ESP_OK) {
    statDrawErrors = statDrawErrors + 1;
    dmaInFlight = dmaInFlight - 1;
  }
}

// Wait for queued strip DMA to finish, bounded.
//
// Two callers, and the second is the reason this exists. Reusing bufB needs the
// previous transfer done (fillPanel achieves that with a flat delay(30)); an OTA
// write needs it for a sharper reason: on the S3 the frame buffers live in PSRAM,
// which shares its SPI controller with the flash the update is writing, and the
// cache goes down for the duration of an erase. A transfer still in flight when
// that happens is a hazard, so the progress screen drains before handing control
// back to the updater. UNVERIFIED on hardware (no board attached while this was
// written): written to be safe rather than measured.
static void waitForDmaIdle(uint32_t maxMs) {
  uint32_t start = millis();
  while (dmaInFlight != 0 && millis() - start < maxMs) {
    delay(2);
  }
  if (dmaInFlight != 0) {
    // The same reclaim the loop's DMA-stall failsafe does: a lost completion
    // callback must not wedge the panel forever.
    statDrawErrors = statDrawErrors + 1;
    dmaInFlight = 0;
  }
}

// Show OTA progress on the glass.
//
// An update takes tens of seconds during which nothing else is drawn, and a panel
// that simply freezes mid-picture looks broken rather than busy - so it says what
// is happening on the device, not only in the terminal doing the pushing.
//
// Composed in staging (bufB) like fillPanel does: bufA holds the last streamed
// frame and belongs to the network path, which keeps writing into it throughout.
// percent < 0 draws no bar, for the states where there is no meaningful figure.
static void drawOtaScreen(const char *headline, int percent) {
  if (bufB == nullptr || panel == nullptr) {
    return;
  }
  waitForDmaIdle(200);  // bufB may still be feeding the previous transfer

  const int w = PANEL_GEOMETRY.frameWidth(panelLandscape);
  const int hgt = PANEL_GEOMETRY.frameHeight(panelLandscape);
  // Round glass hides the framebuffer corners, so keep to the inscribed square
  // exactly as drawIdleScreen does.
  int margin = 4;
  if (bcfg->roundDisplay) {
    int d = w < hgt ? w : hgt;
    margin += (int)(0.1465f * (float)d);
  }

  // Deep blue: unmistakable next to the boot fills (gray waiting for WiFi, teal
  // ready, dark red no WiFi), so the state is readable across a room.
  const uint16_t bg = 0x0008;
  const uint8_t bgHi = bg >> 8, bgLo = bg & 0xFF;
  for (size_t i = 0; i < FRAME_BYTES; i += 2) {
    bufB[i] = bgHi;
    bufB[i + 1] = bgLo;
  }

  char pctText[8];
  pctText[0] = 0;
  if (percent >= 0) {
    snprintf(pctText, sizeof(pctText), "%d%%", percent);
  }

  size_t widest = strlen(headline);
  if (strlen(pctText) > widest) widest = strlen(pctText);
  int scale = 2;
  if ((int)widest * 6 * scale > w - 2 * margin) {
    scale = 1;
  }
  const int lineH = 9 * scale;
  const int barH = 6 * scale;
  const int blockH = lineH * 2 + barH + 3 * scale;
  int y = (hgt - blockH) / 2;
  if (y < margin) y = margin;

  drawOutlinedText(bufB, w, hgt, (w - (int)strlen(headline) * 6 * scale) / 2, y,
                   headline, scale);
  if (pctText[0] != 0) {
    drawOutlinedText(bufB, w, hgt,
                     (w - (int)strlen(pctText) * 6 * scale) / 2, y + lineH,
                     pctText, scale);

    // Progress bar: outlined box, filled left to right. Drawn by hand because
    // the font toolkit has no rectangle primitive and one bar does not justify
    // adding one.
    const int barW = w - 2 * margin;
    const int barX = margin;
    const int barY = y + lineH * 2 + 3 * scale;
    const int filledTo = (barW * percent) / 100;
    for (int px = 0; px < barW; px++) {
      for (int py = 0; py < barH; py++) {
        int sx = barX + px, sy = barY + py;
        if (sx < 0 || sy < 0 || sx >= w || sy >= hgt) continue;
        bool edge = (px == 0 || px == barW - 1 || py == 0 || py == barH - 1);
        uint16_t color = (edge || px < filledTo) ? 0xFFFF : bg;
        size_t off = ((size_t)sy * (size_t)w + (size_t)sx) * 2;
        bufB[off] = color >> 8;
        bufB[off + 1] = color & 0xFF;
      }
    }
  }

  dmaInFlight = dmaInFlight + 1;
  if (esp_lcd_panel_draw_bitmap(panel, 0, 0, w, hgt, bufB) != ESP_OK) {
    statDrawErrors = statDrawErrors + 1;
    dmaInFlight = dmaInFlight - 1;
  }
  // Drain before returning: the caller is about to resume writing flash.
  waitForDmaIdle(500);
}

// WiFi signal quality on the RGB LED(s): green is strong, fading through
// yellow and orange to red as RSSI drops; red also means disconnected.
//   >= -55 dBm  green      solid, excellent
//   -55..-90    gradient   green -> yellow -> orange -> red
//   down / < -90  red
static void updateSignalLed() {
  if (rgbLed == nullptr) {
    return;  // Touch board: no addressable LED to report signal on
  }
  if (millis() < ledOverrideUntil) {
    return;  // a CFGLED test color is being shown
  }
  uint8_t r, g;
  if (WiFi.status() != WL_CONNECTED) {
    r = 255;
    g = 0;
  } else {
    // Smooth with an EMA: instantaneous RSSI jitters a few dB between
    // reads, which made the color visibly flicker at the band edges.
    static float rssiAvg = 0;
    int rssi = WiFi.RSSI();
    rssiAvg = (rssiAvg == 0) ? rssi : rssiAvg * 0.7f + rssi * 0.3f;
    float clamped = rssiAvg;
    if (clamped > -55) clamped = -55;
    if (clamped < -90) clamped = -90;
    // 0.0 at -90 (red) .. 1.0 at -55 (green)
    float t = (clamped + 90) / 35.0f;
    r = (uint8_t)(255 * (1.0f - t));
    g = (uint8_t)(255 * t);
  }
  rgbLed->fill(rgbLed->Color(r, g, 0));
  rgbLed->show();
}

// Poll the BOOT button: short press toggles backlight, long press (fires
// while still held) flips the display 180 degrees, and an extra-long press
// (also fires while held, past the long-press point) toggles the manual
// display off/on - the same standing instruction CFGPOWER and the network
// Power opcode set, reachable without a Mac or a phone on the same WiFi.
//
// COMPOUNDS RATHER THAN REPLACES the long-press flip: holding past
// EXTRA_LONG_PRESS_MS also toggles power, on top of whatever the long press
// already did at LONG_PRESS_MS, because the long press fires immediately
// while held rather than waiting to see how long the button is down for -
// changing that would need release-time semantics for the rotation action,
// a bigger change than adding a third tier justifies. A user who only wants
// the power toggle and not the flip can press long enough for power and then
// long-press once more to flip back; this is the same tradeoff the two-step
// 180 toggle already makes.
static void handleButton() {
  static bool wasDown = false;
  static bool longFired = false;
  static bool extraLongFired = false;
  static uint32_t downAt = 0;

  bool down = digitalRead(bcfg->pinBootButton) == LOW;
  uint32_t now = millis();

  if (down && !wasDown) {
    wasDown = true;
    longFired = false;
    extraLongFired = false;
    downAt = now;
  } else if (down && wasDown && !longFired && now - downAt >= LONG_PRESS_MS) {
    longFired = true;
    // Still a 180 toggle, now expressed as rotation += 2 so it composes with
    // a quarter turn instead of erasing one: a panel mounted at 90 and
    // long-pressed lands at 270, not at 0. The physical button's semantics
    // are unchanged - press it twice and you are back where you started.
    panelRotation = (uint8_t)((panelRotation + 2) & 3);
    madctlDirty = true;
    saveDisplayPrefs();
    Serial.printf("button: long press -> rotation=%u (saved)\n", panelRotation);
  } else if (down && wasDown && longFired && !extraLongFired &&
            now - downAt >= EXTRA_LONG_PRESS_MS) {
    extraLongFired = true;
    // Mirrors the CFGPOWER serial command and ControlOpcode::Power exactly:
    // same flag, same NVS key, same immediate backlight effect.
    panelManuallyOff = !panelManuallyOff;
    saveDisplayPrefs();
    applyBacklight();
    Serial.printf("button: extra-long press -> pwr=%s (saved)\n",
                  panelManuallyOff ? "off" : "on");
  } else if (!down && wasDown) {
    wasDown = false;
    if (!longFired && now - downAt >= DEBOUNCE_MS) {
      // The button stays a two-position switch even though any level is now
      // reachable over the network: stepping through a range by pressing a
      // single button would be worse than useless.
      userBlLevel = blIsHigh() ? BL_LOW : BL_HIGH;
      applyBacklight();
      saveDisplayPrefs();
      Serial.printf("button: short press -> backlight %s (saved)\n",
                    blIsHigh() ? "high" : "low");
    }
  }
}

// Report a completed gesture to whoever is driving this panel.
//
// The internal gesture enum and the wire one are separate types: touch_gesture.h
// lives in the shared library and device_protocol.h lives here, so the library
// cannot see the wire format - and should not, because what the classifier can
// recognise and what the protocol has agreed to carry are allowed to differ. The
// translation is this switch, deliberately explicit so adding a gesture forces a
// decision about whether it goes on the wire rather than silently renumbering it.
//
// The mapping is inline rather than a helper because the Arduino preprocessor
// hoists function prototypes above the "device_protocol.h" include below, so a
// function taking a deviceproto type as a parameter does not compile here.
static void sendTouchEvent(touchgesture::Gesture gesture, int16_t x, int16_t y) {
  deviceproto::TouchGesture wire;
  switch (gesture) {
    case touchgesture::Gesture::Tap:
      wire = deviceproto::TouchGesture::Tap;
      break;
    case touchgesture::Gesture::SwipeLeft:
      wire = deviceproto::TouchGesture::SwipeLeft;
      break;
    case touchgesture::Gesture::SwipeRight:
      wire = deviceproto::TouchGesture::SwipeRight;
      break;
    case touchgesture::Gesture::SwipeUp:
      wire = deviceproto::TouchGesture::SwipeUp;
      break;
    case touchgesture::Gesture::SwipeDown:
      wire = deviceproto::TouchGesture::SwipeDown;
      break;
    case touchgesture::Gesture::LongPress:
      wire = deviceproto::TouchGesture::LongPress;
      break;
    default:
      return;  // not a gesture this protocol carries
  }
  if (hbPort == 0) {
    // No sender has ever spoken to this panel, so there is nowhere to report a
    // gesture to. Log it: a user tapping a panel that no Mac is driving should
    // be able to see that the touch registered and simply had no audience.
    Serial.printf("touch: %s ignored, no sender\n",
                  touchgesture::gestureName(gesture));
    return;
  }
  uint8_t packet[deviceproto::TOUCH_PACKET_BYTES];
  deviceproto::writeTouch(
      packet, wire, ++touchSequence, (uint16_t)x, (uint16_t)y,
      panelLandscape ? deviceproto::TOUCH_FLAG_LANDSCAPE : (uint8_t)0);
  sendToSender(packet, sizeof(packet));
  Serial.printf("touch: %s at (%d,%d) seq=%u -> sender\n",
                touchgesture::gestureName(gesture), x, y, touchSequence);
}

// Poll the touch controller and act on whatever the finger turned out to mean.
//
// Two behaviours share one finger, and the order between them matters. While the
// panel is dimmed - showing the idle card, or dark because the Mac's displays
// slept - a touch lights it and is *consumed*, so waking a panel never also
// toggles whatever the sender maps a tap to. Once the panel is lit, completed
// gestures go to the sender and it decides what they mean.
static void serviceTouch() {
  if (!touchAvailable) {
    return;
  }

  // Let an expired wake window hand the backlight back to the state machine.
  if (touchWakeUntil != 0 && !touchWakeActive()) {
    touchWakeUntil = 0;
    applyBacklight();
  }

  // Ticked before the poll, and regardless of whether one arrives: a long press
  // completes while the finger is still down, and a finger holding still produces
  // no controller interrupts to carry it. Polling first would mean the hold could
  // only be noticed when the user moved or lifted, which is exactly what a hold
  // is not.
  touchgesture::Event held = touchTracker.tick(millis());
  if (held.gesture != touchgesture::Gesture::None && !touchConsumed) {
    sendTouchEvent(held.gesture, held.startX, held.startY);
  }

  boardtouch::Sample sample;
  if (!boardtouch::poll(sample)) {
    return;
  }

  // Through the same orientation transform the pixels went through, so a swipe
  // means the direction the user actually swiped. Calibration is per board:
  // the C6 Touch's AXS5106L and the 1.75C's CST9217 disagree on which raw
  // axis is mirrored (see touch_map.h), so touchCalibration is picked once at
  // boot from bcfg->touch rather than the AXS5106L default every call site
  // used to take implicitly.
  touchmap::Point p = touchmap::map((int16_t)sample.rawX, (int16_t)sample.rawY,
                                    panelLandscape, panelRotation,
                                    touchCalibration);
  touchgesture::Event event =
      touchTracker.onReport(sample.pressed, p.x, p.y, millis());

  if (event.pressStarted && (idleActive || displaySleeping)) {
    touchConsumed = true;
    touchWakeUntil = millis() + TOUCH_WAKE_MS;
    applyBacklight();
    Serial.printf("touch: wake for %lus\n", (unsigned long)(TOUCH_WAKE_MS / 1000));
    return;
  }

  // The press that woke the panel is swallowed whole, so lighting a dark panel
  // never also fires whatever the gesture is bound to.
  //
  // Cleared when that press *ends*, whatever it classified as. Clearing it only
  // on a recognised gesture was a latent bug: a deliberate hold classifies as
  // nothing, so a waking press held for a moment left the flag set and ate the
  // next real gesture. Long press makes that path far more likely, since holding
  // is now something users are told to do.
  const bool consumed = touchConsumed;
  if (consumed && !touchTracker.pressActive()) {
    touchConsumed = false;
  }
  if (event.gesture == touchgesture::Gesture::None || consumed) {
    return;
  }
  // A plain tap on a lit panel shows the quick info bar, independent of and
  // in addition to reporting the gesture below - the two are separate
  // reactions to the same event, not alternatives. Swipes and long presses
  // do not: they already have a job (whatever the sender's gesture preset
  // binds them to), and a bar popping up on every swipe would fight that
  // rather than complement it.
  if (event.gesture == touchgesture::Gesture::Tap) {
    showInfoBar(defaultInfoBarText());
  }
  sendTouchEvent(event.gesture, event.startX, event.startY);
}

// Fill the whole panel with one RGB565 color (used for status feedback).
// Draws from staging (bufB) - bufA belongs to the network path.
static void fillPanel(uint16_t rgb565) {
  uint8_t hi = rgb565 >> 8, lo = rgb565 & 0xFF;
  for (size_t i = 0; i < FRAME_BYTES; i += 2) {
    bufB[i] = hi;
    bufB[i + 1] = lo;
  }
  dmaInFlight = dmaInFlight + 1;  // its completion fires onColorTransDone
  if (esp_lcd_panel_draw_bitmap(panel, 0, 0, PANEL_W, PANEL_H, bufB) != ESP_OK) {
    dmaInFlight = dmaInFlight - 1;
  }
  delay(30);  // let DMA finish before bufB is reused
}

// Advertise the service and every TXT record. Both the initial announce and
// the post-heal re-announce call this, and every value is derived from the
// constant it describes - the previous copies hardcoded "caps" and "res" in
// two places, so adding a capability would have silently left the advertised
// value stale.
static void addMdnsService() {
  char capsBuf[9], resBuf[16], protoBuf[4];
  snprintf(capsBuf, sizeof(capsBuf), "%08lx", (unsigned long)deviceCapabilities());
  snprintf(resBuf, sizeof(resBuf), "%ux%u", (unsigned)PANEL_W, (unsigned)PANEL_H);
  snprintf(protoBuf, sizeof(protoBuf), "%u",
           (unsigned)deviceproto::FRAME_PROTOCOL_VERSION);
  // Bind as const char *: ESPmDNS overloads addServiceTxt on char *,
  // const char *, and String, and a mutable buffer makes all three viable
  // under the -fpermissive the Arduino build uses, which is ambiguous.
  //
  // chip is already a const char * from chip_identity.h, and is bound here with
  // the others so the whole record set reads as one list. It says which of a
  // firmware bundle's images belongs to this panel; see chip_identity.h for why
  // that is advertised instead of inferred from res. UNVERIFIED that a browser
  // sees it - no board is attached, so this rests on it being the same call the
  // records beside it go through, not on an observation.
  const char *caps = capsBuf, *res = resBuf, *proto = protoBuf;
  const char *chip = chipidentity::chipToken();
  MDNS.setInstanceName(cfgName);
  MDNS.addService("espdisp", "udp", UDP_PORT);
  MDNS.addServiceTxt("espdisp", "udp", "name", cfgName);
  MDNS.addServiceTxt("espdisp", "udp", "res", res);
  MDNS.addServiceTxt("espdisp", "udp", "fw", FW_VERSION);
  MDNS.addServiceTxt("espdisp", "udp", "proto", proto);
  MDNS.addServiceTxt("espdisp", "udp", "caps", caps);
  MDNS.addServiceTxt("espdisp", "udp", "chip", chip);
  if (otaActive) {
    // _arduino._tcp is what espota/arduino-cli browse for. It is registered from
    // here rather than by ArduinoOTA itself (which is why setupOta calls
    // setMdnsEnabled(false)) for two reasons, both read out of the core's
    // ArduinoOTA.cpp: its begin() would call MDNS.begin() a second time, and its
    // end() calls MDNS.end(), i.e. mdns_free(), which would take _espdisp._udp
    // down with it. Registering here also means the WiFi-heal path gets OTA back
    // for free - that path tears mDNS down and calls this function again, so
    // without this line OTA would silently stop being discoverable after the
    // first heal.
    MDNS.enableArduino(OTA_PORT, true /* auth required */);
  }
}

// Bring OTA up, if it is configured and the radio is ready.
//
// Returns true only on the transition to active, so the caller knows the mDNS
// caps TXT record needs re-announcing.
//
// Fails closed at every step: no stored password means no listener and no
// CAP_OTA. The password is read into a local and handed straight to ArduinoOTA,
// which keeps only SHA256(password) - so the plaintext exists in RAM for the
// length of this call and not for the uptime of the panel.
static bool startOtaIfConfigured() {
  if (otaActive || !otaConfigured) {
    return false;
  }
  if (WiFi.status() != WL_CONNECTED) {
    return false;  // nothing to bind a socket to yet; retried from the loop
  }

  String otaPassword;
  {
    Preferences prefs;
    prefs.begin("espdisp", true /* read-only */);
    otaPassword = prefs.getString("otapw", "");
    prefs.end();
  }
  if (otaPassword.isEmpty()) {
    otaConfigured = false;  // cleared behind our back; stop retrying
    return false;
  }

  ArduinoOTA.setHostname(cfgName.c_str());  // <name>.local, not esp32-<mac>
  ArduinoOTA.setPassword(otaPassword.c_str());
  ArduinoOTA.setPort(OTA_PORT);
  ArduinoOTA.setMdnsEnabled(false);  // addMdnsService() owns every registration

  ArduinoOTA.onStart([]() {
    // Fed here so the drawing below gets its own watchdog interval instead of
    // sharing the one that started at the top of loop(). The draw is bounded at
    // ~700ms by construction - waitForDmaIdle(200) on the way into drawOtaScreen
    // and waitForDmaIdle(500) on the way out, plus a full-frame push - which is a
    // sum of two limits this file sets, not a measurement. Against a 10s timeout
    // it plainly fits; this costs one line and removes the need to care.
    //
    // An earlier version of this comment said Update.begin() erases the whole
    // 0x140000 app slot before any data arrives, and that this reset covers that
    // erase. Both halves are wrong, read out of the core rather than assumed:
    // UpdateClass::begin() (Updater.cpp:184) resets state, picks the partition
    // with esp_ota_get_next_update_partition, and allocates a sector buffer - it
    // erases nothing. The erase is per-64KB block inside _writeBuffer()
    // (Updater.cpp:665) as data arrives, so it falls between two progress
    // callbacks, each of which already feeds the watchdog. And _runUpdate calls
    // _updater->begin() at ArduinoOTA.cpp:343, before _start_callback() at 357,
    // so a reset here could not have covered it even if it did erase - a panic
    // would have happened inside begin(), upstream of this callback.
    esp_task_wdt_reset();
    otaInProgress = true;
    otaShownPercent = 0;
    // Make the update visible whatever state the panel was in: a push that
    // arrives while the Mac's displays are asleep would otherwise happen behind
    // a dark screen. Saved so a FAILED push can put it back - on success the
    // board reboots and the sender re-establishes both, but a failure leaves this
    // firmware running and the panel should go back to the state the Mac put it
    // in rather than sitting lit until the 45s idle timer notices.
    otaSavedPanel.save(displaySleeping, idleActive);
    displaySleeping = false;
    idleActive = false;
    applyBacklight();
    Serial.println("ota: update starting");
    drawOtaScreen("updating", 0);
    // Belt and braces. _runUpdate calls _progress_callback(0, _size) immediately
    // after _start_callback() returns (ArduinoOTA.cpp:359), and onProgress resets
    // the watchdog as its first statement, ahead of its own early return - so
    // this interval is already ended microseconds from now and this line changes
    // nothing today. It is here so the draw above stays covered if a future core
    // stops making that opening progress call.
    esp_task_wdt_reset();
  });

  ArduinoOTA.onProgress([](unsigned int done, unsigned int total) {
    // The whole transfer runs inside ArduinoOTA.handle(), which does not return
    // to the top of loop() until it is finished - so the 10s task watchdog is
    // fed from here or a legitimate update panics the board partway through.
    esp_task_wdt_reset();
    if (total == 0) {
      return;
    }
    uint8_t percent = (uint8_t)((uint64_t)done * 100u / total);
    // Repaint in 5% steps. This callback fires once per 1460-byte chunk (~770
    // times for a 1.1MB image) and a full-frame push costs tens of milliseconds,
    // so redrawing on every call would slow the update down for no extra
    // information.
    if (percent < otaShownPercent + 5 && percent != 100) {
      return;
    }
    otaShownPercent = percent;
    Serial.printf("ota: %u%%\n", (unsigned)percent);
    drawOtaScreen("updating", (int)percent);
  });

  ArduinoOTA.onEnd([]() {
    // ArduinoOTA reboots ~100ms after this returns (setRebootOnSuccess is left
    // at its default), so this is the last thing the old firmware draws.
    Serial.println("ota: complete, rebooting");
    drawOtaScreen("rebooting", 100);
    otaInProgress = false;
    // Success owes the panel nothing back - the reboot re-establishes both flags
    // from the sender - but drop the saved state here rather than letting the
    // reboot be what clears it. Otherwise "nothing saved crosses a push" rests on
    // _rebootOnSuccess still being true, which is a core default this sketch never
    // sets and which only the comment above records. One call makes the invariant
    // hold from this side instead of depending on that.
    otaSavedPanel.discard();
  });

  ArduinoOTA.onError([](ota_error_t error) {
    otaInProgress = false;
    const char *what = "failed";
    switch (error) {
      case OTA_AUTH_ERROR: what = "bad password"; break;
      case OTA_BEGIN_ERROR: what = "no free slot"; break;
      case OTA_CONNECT_ERROR: what = "connect lost"; break;
      case OTA_RECEIVE_ERROR: what = "transfer lost"; break;
      case OTA_END_ERROR: what = "bad image"; break;
    }
    Serial.printf("ota: %s (error %d)\n", what, (int)error);
    // Leave the reason on the glass rather than snapping back to the stream: a
    // failed push is exactly when someone is standing in front of the panel. The
    // next completed frame overwrites it, and a rejected image never touched the
    // running slot - the panel is still on the firmware it booted.
    drawOtaScreen(what, -1);
    // Then put back what onStart cleared, if onStart ran on this push at all -
    // take() answers false when it did not, and this callback is reachable
    // without it (a wrong password never gets that far; see SavedPanelState).
    // Restoring unconditionally lit a panel the Mac had put to sleep, for
    // anything on the LAN willing to guess the password wrong.
    //
    // Deliberately after the draw, not before it. If the panel really was asleep
    // the reason then goes dark almost immediately, which is the right way round
    // - obeying the sender beats leaving a message nobody is there to read, and
    // the reason is on the serial line either way.
    if (otaSavedPanel.take(displaySleeping, idleActive)) {
      applyBacklight();
    }
  });

  // begin() returns void in core 3.3.11 (verified in ArduinoOTA.cpp: on a failed
  // UDP bind it logs "udp bind failed" and returns with itself uninitialised),
  // and there is no accessor for that state. So the preconditions above - a
  // stored password and an associated radio - are the whole of what can be
  // checked before advertising CAP_OTA. UNVERIFIED without hardware: that the
  // bind succeeds in practice. If it ever does not, handle() is a no-op and a
  // push simply times out; nothing else misbehaves.
  ArduinoOTA.begin();
  otaActive = true;
  Serial.printf("ota: listening on %s.local:%u (password required)\n",
                cfgName.c_str(), (unsigned)OTA_PORT);
  return true;
}

void setup() {
  Serial.begin(115200);
  // A host that opens the CDC port but stops draining it would otherwise
  // block every Serial write and hang the whole loop task (observed as
  // total silence + frozen pipeline). Never wait on USB.
  Serial.setTxTimeoutMs(0);
  unsigned long start = millis();
  while (!Serial && millis() - start < 5000) {
    delay(50);
  }
  Serial.println("=== display_stream (esp_lcd DMA) ===");
  Serial.printf("firmware %s, frame protocol %u, control protocol %u\n",
                FW_VERSION, deviceproto::FRAME_PROTOCOL_VERSION,
                deviceproto::CONTROL_PROTOCOL_VERSION);
  esp_read_mac(deviceId, ESP_MAC_WIFI_STA);

  bufA = (uint8_t *)heap_caps_malloc(FRAME_BYTES, FRAME_BUF_CAPS);
  bufB = (uint8_t *)heap_caps_malloc(FRAME_BYTES, FRAME_BUF_CAPS);
  if (!bufA || !bufB) {
    Serial.println("FATAL: frame buffer alloc failed");
    while (true) delay(1000);
  }
  // Undelivered bands must show black, not heap garbage.
  memset(bufA, 0, FRAME_BYTES);
  Serial.printf("buffers ok, free heap: %lu\n", (unsigned long)ESP.getFreeHeap());

  // Load persisted settings before anything is drawn or the radio starts:
  // orientation and brightness must be known for the very first fill, and
  // the device name before WiFi latches its DHCP hostname.
  bool ssidFromNvs = false;
  uint8_t boardOverride = 0;
  {
    Preferences prefs;
    prefs.begin("espdisp", true /* read-only */);
    ssidFromNvs = prefs.isKey("ssid");
    // Operator override from CFGBOARD, 0 = auto-detect. Only an explicit
    // override is persisted; the auto-detected value deliberately is not. A
    // cached auto-detection would be sticky, and the one misdetection with
    // electrical consequences (a Touch board mistaken for a non-touch one)
    // would then survive every subsequent boot instead of being re-tested.
    boardOverride = prefs.getUChar("board", 0);
    cfgSsid = prefs.getString("ssid", WIFI_SSID);
    cfgPass = prefs.getString("pass", WIFI_PASSWORD);
    cfgName = prefs.getString("name", "");
    // Physical orientation and brightness are properties of how the board is
    // mounted, so they belong in flash - re-flipping after every reflash is
    // needless. NVS survives sketch uploads (only the app partition is
    // rewritten); a full flash erase does reset them.
    //
    // "rot" (quarter turns 0-3) supersedes the old "flip" bool. A panel
    // flashed before rotation existed has only "flip", so that key is the
    // fallback (flip true -> rot 2) - an upgraded panel keeps its mounting
    // without anyone touching it. saveDisplayPrefs writes "rot" from then on.
    if (prefs.isKey("rot")) {
      panelRotation = (uint8_t)(prefs.getUChar("rot", 0) & 3);
    } else {
      panelRotation = prefs.getBool("flip", false) ? 2 : 0;
    }
    // A panel a user turned off must stay off across a reboot - the whole
    // point of a standing instruction is that it survives the events that
    // would otherwise clear a transient one.
    panelManuallyOff = prefs.getBool("pwroff", false);
    // Migrate the old high/low flag: devices flashed before continuous
    // brightness have "blhigh" and no "bllevel".
    userBlLevel = prefs.getUChar(
        "bllevel", prefs.getBool("blhigh", true) ? BL_HIGH : BL_LOW);
    if (userBlLevel == 0) userBlLevel = BL_HIGH;
    // The screensaver template a sender pushed, restored so a reboot shows
    // the user's own card rather than falling back to the panel's built-in
    // one until the sender happens to reconnect and push again - the whole
    // point of a template being something the user set is that it survives
    // the events that would otherwise clear a transient one (same reasoning
    // as "pwroff" above).
    //
    // idleTextAt is deliberately LEFT AT ITS DEFAULT OF 0, not set to
    // millis(): the panel has no RTC, so a restored template's true age is
    // unknown and could be weeks old, and stamping "now" would claim the
    // sender just pushed it, which is worse than the truth. Left at 0, the
    // "as of" line drawIdleScreen() prints reads as time-since-boot instead -
    // an honest lower bound rather than a fabricated "just now".
    String storedIdleText = prefs.getString("idletxt", "");
    idleText = deviceproto::decodeIdleTextFromStorage(storedIdleText.c_str());
    // What was just read back out IS what NVS already holds, by definition -
    // recording it here is what stops the first periodic check from treating
    // a freshly booted panel's own restored content as a change worth
    // rewriting.
    lastSavedIdleText = idleText;
    // Only whether a password exists, never the password: it is read again, into
    // a local, at the point ArduinoOTA needs it. An empty stored value counts as
    // absent so a blank string can never enable an unpassworded OTA.
    otaConfigured = !prefs.getString("otapw", "").isEmpty();
    prefs.end();
  }
  // Report the actual source, not a value comparison: stored credentials
  // often equal the compiled ones, and claiming "compiled default" then
  // sends you hunting for a config that is in fact saved.
  Serial.printf("WiFi credentials: \"%s\" (%s)\n", cfgSsid.c_str(),
                ssidFromNvs ? "from NVS" : "compiled default");
  Serial.printf("display prefs: rotation=%u backlight=%u (%s)\n", panelRotation,
                userBlLevel, blIsHigh() ? "high" : "low");
  Serial.printf("idle text restored from NVS: %u lines\n",
                (unsigned)idleText.lineCount);

  if (cfgName.isEmpty()) {
    cfgName = defaultDeviceName();
  }

  // Which board is this? Everything below depends on the answer, and this MUST
  // come before any pin is configured: two of the C6 Touch board's panel pins
  // are chip outputs on the other C6 board's map (see board_config.h
  // resolve()), so guessing wrong means driving against live drivers. The probe
  // only touches the shared I2C pins and touch reset, which are safe on both.
  // Chips with exactly one supported board never probe at all.
  if (board::COMPILED_VARIANT != board::Variant::Unknown) {
    boardVariant = board::COMPILED_VARIANT;
    Serial.printf("board: fixed at compile time: %s\n",
                  board::variantToken(boardVariant));
  } else {
    board::Variant forced = board::variantFromStored(boardOverride);
    if (forced != board::Variant::Unknown) {
      boardVariant = forced;
      Serial.printf("board: forced to %s by CFGBOARD\n",
                    board::variantToken(forced));
    } else {
      boardVariant = boarddetect::probe();
    }
  }
  bcfg = &board::configFor(boardVariant);
  // A stored override written by an older firmware can name a board whose
  // glass this binary was not sized for. The geometry is compiled in
  // (buffers, band layout, mDNS), so refuse the override and re-probe rather
  // than boot a 172x320 pipeline against a 466x466 table.
  if (bcfg->panelW != PANEL_GEOMETRY.width ||
      bcfg->panelH != PANEL_GEOMETRY.height) {
    Serial.printf("board: ERROR %s is %ux%u but this binary is %ux%u - "
                  "ignoring override, re-probing\n",
                  board::variantToken(boardVariant), bcfg->panelW, bcfg->panelH,
                  PANEL_GEOMETRY.width, PANEL_GEOMETRY.height);
    boardVariant = boarddetect::probe();
    bcfg = &board::configFor(boardVariant);
  }
  Serial.printf("board: %s\n", bcfg->name);
  Serial.printf("  driver=%s bus=%s %ux%u pclk=%luMHz\n",
                bcfg->driver == board::PanelDriver::Co5300   ? "CO5300"
                : bcfg->driver == board::PanelDriver::Jd9853 ? "JD9853"
                                                             : "ST7789",
                bcfg->isQspi() ? "qspi" : "spi", bcfg->panelW, bcfg->panelH,
                (unsigned long)(bcfg->pclkHz / 1000000));
  Serial.printf("  sclk=%d d0/mosi=%d d1=%d d2=%d d3=%d cs=%d dc=%d rst=%d bl=%d boot=%d led=%d\n",
                bcfg->pinSclk, bcfg->pinMosi, bcfg->pinData1, bcfg->pinData2,
                bcfg->pinData3, bcfg->pinCs, bcfg->pinDc, bcfg->pinRst,
                bcfg->pinBl, bcfg->pinBootButton, bcfg->pinRgbLed);

  // Only construct the LED driver on a board that has one - begin() drives the
  // pin, and GPIO8 has no known function on the Touch board.
  if (bcfg->hasRgbLed()) {
    // NEO_RGB, not the usual NEO_GRB: this board's LED takes red first.
    // (Diagnosed with CFGLED - pure red displayed as green under GRB.)
    rgbLed = new Adafruit_NeoPixel(RGB_COUNT, bcfg->pinRgbLed,
                                   NEO_RGB + NEO_KHZ800);
    rgbLed->begin();
    rgbLed->setBrightness(RGB_LED_BRIGHTNESS);
    updateSignalLed();  // red until WiFi is up
  }

  pinMode(bcfg->pinBootButton, INPUT_PULLUP);
  if (bcfg->hasBacklightPin()) {
    // A PWM backlight exists independently of the panel, so light it early -
    // the boot status fills are pointless over a dark backlight.
    pinMode(bcfg->pinBl, OUTPUT);
    applyBacklight();
  }
  if (!initDisplay()) {
    Serial.println("FATAL: display init failed");
    while (true) delay(1000);
  }
  // Apply the saved flip up front so even the boot status fills land the
  // right way up, not just streamed frames.
  applyPanelConfig(false);
  // Panel-command brightness (the AMOLED) needs the panel up before it can
  // apply; its init table ends at full brightness, so this restores the
  // user's saved level. A harmless repeat on PWM boards.
  applyBacklight();
  fillPanel(0x2104);  // dark gray: display alive, waiting for WiFi

  // Touch, before WiFi: the capability bits mDNS advertises depend on whether
  // the controller answered, so this has to be settled before we announce.
  touchCalibration = bcfg->touch == board::TouchController::Cst9217
      ? touchmap::CST9217_ON_CO5300 : touchmap::AXS5106L_ON_C6;
  touchAvailable = boardtouch::init(*bcfg);
  // The PMU, for the same reason and so before the announce: CAP_BATTERY
  // depends on the chip having answered, and addMdnsService() bakes
  // deviceCapabilities() into its TXT record. Returns false on the C6 boards,
  // which have no PMU, and never touches the bus there.
  batteryAvailable = boardpower::init(*bcfg);
  // The device name doubles as the DHCP hostname (option 12), so the router
  // lists this board by name instead of "esp32c6-XXXXXX". This MUST precede
  // WiFi.mode(): the core latches the hostname onto the STA netif inside
  // mode() when entering STA, so setting it after has no effect on DHCP.
  WiFi.setHostname(cfgName.c_str());

  WiFi.mode(WIFI_STA);
  WiFi.setAutoReconnect(true);  // rejoin on AP drop (default, but explicit)
  WiFi.setSleep(false);         // latency: don't doze between beacons
  WiFi.begin(cfgSsid.c_str(), cfgPass.c_str());
  // Bounded wait that keeps servicing serial config: with wrong credentials
  // (mistyped, or the board moved to a new network) an unbounded wait would
  // make the device unconfigurable - CFGWIFI over USB must always work.
  uint32_t wifiWaitStart = millis();
  while (WiFi.status() != WL_CONNECTED) {
    handleSerialConfig();
    delay(100);
    if (millis() - wifiWaitStart > 30000) {
      Serial.printf("WiFi connect timeout for \"%s\" - continuing; fix via "
                    "CFGWIFI over USB or wait for auto-reconnect\n",
                    cfgSsid.c_str());
      break;
    }
  }
  if (WiFi.status() == WL_CONNECTED) {
    Serial.printf("WiFi up: %s (dhcp hostname \"%s\")\n",
                  WiFi.localIP().toString().c_str(), WiFi.getHostname());
  }

  // OTA before the announce, not after, even though ArduinoOTA is the later
  // arrival here: addMdnsService() bakes deviceCapabilities() into the caps TXT
  // record and registers _arduino._tcp, so both would be wrong if OTA came up
  // afterwards. Nothing in ArduinoOTA forces the opposite order - with
  // setMdnsEnabled(false) its begin() only binds a UDP socket, which needs the
  // radio (checked inside) and not mDNS.
  if (otaConfigured) {
    startOtaIfConfigured();
  } else {
    Serial.println("ota: disabled (no password set; enable with CFGOTAPW)");
  }

  if (MDNS.begin(cfgName.c_str())) {
    addMdnsService();
    Serial.printf("mDNS: %s.local, service _espdisp._udp%s\n", cfgName.c_str(),
                  otaActive ? " + _arduino._tcp" : "");
  } else {
    Serial.println("WARN: mDNS failed to start");
  }

  // Ready fill, honest about the radio. The WiFi wait above is bounded and
  // falls through on timeout, so painting "connected" unconditionally told
  // you the network was fine on a board that never associated.
  if (WiFi.status() == WL_CONNECTED) {
    fillPanel(0x0210);  // dark teal: WiFi up, waiting for stream
  } else {
    fillPanel(0x9000);  // dark red: no WiFi - fix with CFGWIFI over USB
  }

  if (startInboundTransport()) {
    Serial.printf("UDP listening on %u\n", UDP_PORT);
  } else {
    Serial.println("FATAL: UDP listen failed");
  }

  // Arm the status card: if no sender ever appears, the device announces
  // its name/IP/signal over the ready fill instead of sitting mute.
  lastSenderPacketAt = millis();

  // Task watchdog on the loop task: any unforeseen hang panics and reboots;
  // the Mac's heartbeat supervision then reconnects automatically. The
  // Arduino core usually pre-initializes the TWDT, so try init then
  // reconfigure to our timeout either way.
  esp_task_wdt_config_t wdtConfig = {};
  wdtConfig.timeout_ms = 10000;
  wdtConfig.idle_core_mask = 0;
  wdtConfig.trigger_panic = true;
  if (esp_task_wdt_init(&wdtConfig) != ESP_OK) {
    esp_task_wdt_reconfigure(&wdtConfig);
  }
  esp_task_wdt_add(NULL);
}

void loop() {
  esp_task_wdt_reset();

  if (otaActive) {
    // An entire update happens inside this one call: handle() runs the transfer
    // to completion, feeding the watchdog from the progress callback, and either
    // reboots (success) or clears otaInProgress (failure) before returning. The
    // guard below is therefore belt and braces - if a future core version ever
    // returns between chunks, nothing beneath it may run: no frame may be drawn
    // over the progress screen, and no DMA may be queued while flash is being
    // written.
    ArduinoOTA.handle();
    if (otaInProgress) {
      return;
    }
  }

  handleButton();
  handleSerialConfig();
  applyPendingControl();
  updateIdentify();
  serviceTouch();
  if (dmaInFlight == 0) clearInfoBarIfExpired();
  static uint32_t lastIdleTextCheck = 0;
  if ((uint32_t)(millis() - lastIdleTextCheck) >= IDLE_TEXT_SAVE_INTERVAL_MS) {
    lastIdleTextCheck = millis();
    saveIdleTextPrefsIfChanged();
  }
  if (restartAt != 0 && (int32_t)(millis() - restartAt) >= 0) {
    Serial.flush();
    delay(50);
    ESP.restart();
  }

  // Reapply a pending rotation now, and repaint the whole screen from what is
  // already cached instead of waiting for a frame to arrive.
  //
  // A rotation changes MADCTL, which makes the panel re-address the pixels
  // already in its memory in the new direction. Every pixel on screen is
  // therefore wrong the moment it takes effect - including the parts no
  // incoming band will touch. Reapplying only on the next completed frame and
  // then redrawing just that frame's dirty bands left the image healing a band
  // at a time, and left a static screen upside-down until the sender's 5s full
  // refresh.
  //
  // This is fixable locally because a user rotation leaves bufA valid: a 180
  // changes only the scan direction, and a quarter turn is only reachable on
  // square glass, where the band geometry is orientation-symmetric - either
  // way the bands in bufA still tile the frame and the new MADCTL re-addresses
  // them. A landscape change is not, so one still mid-flight here
  // (bufLandscape not yet agreeing with the completed frame) only reapplies
  // the config and leaves the repaint to the keyframe the sender guarantees.
  //
  // The Mac-commanded rotation never had this problem because
  // DeviceSession.setFlip/setRotation force a keyframe. A BOOT-button turn is
  // invisible to the sender, so nothing asked for one.
  if (madctlDirty && dmaInFlight == 0) {
    bool orientationSettled = (bufLandscape == pendingLandscape);
    applyPanelConfig(bufLandscape);
    const char *repainted;
    if (idleActive) {
      drawIdleScreen();  // composes the card over bufA and pushes all of it
      repainted = "status card";
    } else if (orientationSettled && statFramesShown != 0) {
      // Mark every band and hand it to the existing draw path rather than
      // duplicating the staging and DMA logic. Bits past bandCount are ignored:
      // forEachRun bounds its walk by the count it is given.
      portENTER_CRITICAL(&drawMux);
      memset(pendingDrawBitmap, 0xFF, sizeof(pendingDrawBitmap));
      portEXIT_CRITICAL(&drawMux);
      framesCompleted = framesCompleted + 1;  // drawn below, same iteration
      repainted = "cached frame";
    } else {
      // Either a landscape change is mid-flight (the sender's keyframe repaints
      // it), or nothing but a boot fill has ever been on screen - and a uniform
      // fill looks the same either way up, so there is nothing to correct.
      repainted = "nothing to repaint";
    }
    Serial.printf("rotation=%u applied (%s)\n", panelRotation, repainted);
  }

  static uint32_t lastCompleted = 0;
  if (framesCompleted != lastCompleted && dmaInFlight == 0) {
    lastCompleted = framesCompleted;

    // Snapshot-and-clear the pending set; the UDP task keeps marking bands
    // for the next frame while we draw this one.
    uint8_t bands[BITMAP_BYTES];
    portENTER_CRITICAL(&drawMux);
    memcpy(bands, pendingDrawBitmap, sizeof(bands));
    memset(pendingDrawBitmap, 0, sizeof(pendingDrawBitmap));
    bool landscape = pendingLandscape;
    portEXIT_CRITICAL(&drawMux);

    if (landscape != panelLandscape || madctlDirty) {
      applyPanelConfig(landscape);
    }

    int drawWidth = PANEL_GEOMETRY.frameWidth(landscape);
    const int frameRows = PANEL_GEOMETRY.frameHeight(landscape);
    const int bandRows = PANEL_GEOMETRY.rowsPerBand(landscape);
    const uint16_t totalBands = PANEL_GEOMETRY.bandCount(landscape);

    // Coalesce runs of contiguous dirty bands into single DMA transfers.
    // Contiguous bands are contiguous in memory, so a run needs just one
    // memcpy to staging and one draw_bitmap. Staging (bufB) keeps DMA reads
    // off the buffer the network task writes. The last band may be short
    // (bandOffset of the end marker would overshoot the frame), so a run
    // that reaches the end sizes itself against the frame instead.
    bool drewAny = false;
    forEachRun(bands, totalBands, [&](int runStart, int runEnd) {
      size_t off = PANEL_GEOMETRY.bandOffset((uint16_t)runStart, landscape);
      size_t bytes =
          (runEnd >= (int)totalBands)
              ? FRAME_BYTES - off
              : PANEL_GEOMETRY.bandOffset((uint16_t)runEnd, landscape) - off;
      int yEnd = runEnd * bandRows;
      if (yEnd > frameRows) yEnd = frameRows;
      memcpy(bufB + off, bufA + off, bytes);
      dmaInFlight = dmaInFlight + 1;
      dmaQueuedAt = millis();
      // Queues async; blocks briefly only if the 2-deep transaction queue
      // is full. A failed queue never fires the completion callback, so
      // roll the counter back to avoid a permanent wedge.
      esp_err_t err = esp_lcd_panel_draw_bitmap(
          panel, 0, runStart * bandRows, drawWidth, yEnd, bufB + off);
      if (err != ESP_OK) {
        statDrawErrors = statDrawErrors + 1;
        dmaInFlight = dmaInFlight - 1;
      } else {
        drewAny = true;
        // This run just overwrote the panel's pixels for its own row range
        // with bufA's fresh content - if the info bar is up and any of its
        // rows fell inside that range, the bar is now gone from the glass
        // and has to be redrawn on top before this run's DMA transfer
        // completes, or the panel briefly (or, if no later run touches
        // those rows again, permanently until the bar's window elapses)
        // shows the stream instead of the bar a moment after showing it.
        if (infoBarActive() &&
            panelstate::rowRangeOverlaps(runStart * bandRows, yEnd, infoBarY0,
                                        infoBarY1)) {
          waitForDmaIdle(200);
          redrawInfoBarOverRun();
        }
      }
    });
    if (drewAny) {
      statFramesShown = statFramesShown + 1;
      // A drawn frame implies the sender is present and the Mac's displays
      // are awake, so leave both dimmed states.
      if (idleActive || displaySleeping) {
        idleActive = false;
        displaySleeping = false;
        applyBacklight();
      }
    }
  } else {
    delay(1);
  }

  // Display sleep: the Mac's screens slept, so stale pixels are pointless -
  // kill the backlight (heat + burn-in). Any drawn frame wakes it above.
  if (sleepRequested) {
    sleepRequested = false;
    if (!displaySleeping) {
      displaySleeping = true;
      idleActive = false;
      applyBacklight();
      Serial.println("display sleeping (ESLP from sender)");
    }
  }
  if (wakeRequested) {
    wakeRequested = false;
    if (displaySleeping || idleActive) {
      displaySleeping = false;
      idleActive = false;
      applyBacklight();
      Serial.println("display awake (EWAK from sender)");
    }
  }

  // Status card: the sender has stopped talking to us entirely (crashed,
  // quit, WiFi down, Mac asleep without telling us). Show where to find
  // this device, dimmed, repositioning against burn-in. Static content is
  // explicitly NOT this state - keepalives keep arriving for a still photo.
  // millisSince, not a plain subtraction: lastSenderPacketAt is written by a
  // higher-priority receive task/callback concurrently with this read, and a
  // packet landing between millis() and reading lastSenderPacketAt below can
  // leave lastSenderPacketAt newer than the millis() already captured. A
  // plain "now - last" then underflows to roughly UINT32_MAX ms - this is
  // exactly what put "sender silent 4294967s" in the serial log while the
  // sender was actively streaming, flashing idleActive on for one loop
  // iteration and off the next. See millisSince's doc comment.
  uint32_t senderSilence = panelstate::millisSince(millis(), lastSenderPacketAt);
  if (!displaySleeping && dmaInFlight == 0 && lastSenderPacketAt != 0 &&
      senderSilence > SENDER_GONE_MS) {
    if (!idleActive) {
      idleActive = true;
      applyBacklight();
      drawIdleScreen();
      Serial.printf("sender silent %lus - status card on\n",
                    (unsigned long)(senderSilence / 1000));
    } else if (millis() - lastIdleDrawAt > IDLE_REPOSITION_MS) {
      drawIdleScreen();  // new random position, fresh RSSI/IP
    }
  } else if (idleActive && senderSilence < SENDER_GONE_MS) {
    // Sender came back but has no new pixels to send (static content):
    // restore brightness without waiting for a frame.
    idleActive = false;
    applyBacklight();
    Serial.println("sender back - status card off");
  }

  // DMA-stall failsafe: strips take ~14ms worst case at 80MHz. If completion
  // callbacks haven't drained the counter after 500ms, they're lost -
  // reclaim rather than wedge forever.
  if (dmaInFlight != 0 && millis() - dmaQueuedAt > 500) {
    statDrawErrors = statDrawErrors + 1;
    dmaInFlight = 0;
  }

  // WiFi association fully lost for over a minute: autoReconnect isn't
  // getting us back, reboot for a clean radio state.
  static uint32_t wifiDownSince = 0;
  if (WiFi.status() == WL_CONNECTED) {
    wifiDownSince = 0;
    // Deferred OTA start. setup()'s WiFi wait is bounded and falls through on
    // timeout, so a panel that associated a moment later would otherwise have no
    // OTA until its next reboot. Cheap to leave here: the call is a flag test
    // once OTA is up, or once it is known to be unconfigured.
    if (startOtaIfConfigured()) {
      addMdnsService();  // caps TXT and _arduino._tcp were announced without OTA
    }
  } else if (wifiDownSince == 0) {
    wifiDownSince = millis();
  } else if (millis() - wifiDownSince > 60000) {
    Serial.println("WiFi down >60s, restarting");
    Serial.flush();
    delay(100);
    ESP.restart();
  }

  // Silent-but-associated failsafe: the heal below needs packets flowing to
  // detect trouble, but a link can rot so badly that nothing arrives at all
  // (measured: still associated at RSSI -92, multicast/mDNS dead, so the Mac
  // could not even resolve us). Association alone is not health. If nothing
  // has arrived for 2 minutes and the signal is poor, re-associate - it is
  // cheap, and the panel is useless in this state anyway.
  static uint32_t lastPacketSeenAt = 0;
  static uint32_t lastPacketsForIdle = 0;
  static uint32_t lastIdleReassoc = 0;
  if (statPackets != lastPacketsForIdle) {
    lastPacketsForIdle = statPackets;
    lastPacketSeenAt = millis();
  } else if (lastPacketSeenAt == 0) {
    lastPacketSeenAt = millis();
  }
  if (millis() - lastPacketSeenAt > 120000 && WiFi.RSSI() < -85 &&
      millis() - lastIdleReassoc > 120000) {
    lastIdleReassoc = millis();
    Serial.printf("idle+weak link (rssi=%d), re-associating\n", (int)WiFi.RSSI());
    WiFi.disconnect();
    WiFi.reconnect();
  }

  // Link supervisor: if the sender is actively pushing chunks (packets
  // climbing) but no frame has completed in 20s, the WiFi association has
  // rotted (observed: RSSI decayed to -81 and stayed; a fresh association
  // on the same radio read -56 with perfect delivery). Heal in stages:
  // reconnect WiFi first, hard-reboot if that doesn't take - the Mac's
  // heartbeat supervision reconnects automatically either way.
  static uint32_t lastLinkCheck = 0;
  static uint32_t lastShownVal = 0;
  static uint32_t lastShownChangeAt = 0;
  static uint32_t lastPacketsVal = 0;
  static uint8_t healStage = 0;
  static uint32_t healStartedAt = 0;
  if (millis() - lastLinkCheck >= 5000) {
    lastLinkCheck = millis();
    if (statFramesShown != lastShownVal) {
      lastShownVal = statFramesShown;
      lastShownChangeAt = millis();
      if (healStage != 0) {
        Serial.println("link heal: recovered");
        healStage = 0;
      }
    }
    uint32_t packetsDelta = statPackets - lastPacketsVal;
    lastPacketsVal = statPackets;
    // With dirty bands, low steady packet flow is normal for static
    // content; require sustained volume before judging the link rotten.
    // The threshold is two keyframes' worth of bands for this panel's
    // geometry, whatever that geometry is.
    bool starving = packetsDelta > 2u * PANEL_GEOMETRY.maxBandCount() &&
                    millis() - lastShownChangeAt > 20000;
    if (starving && healStage == 0) {
      Serial.printf("link heal: reconnecting WiFi (rssi=%d)\n", (int)WiFi.RSSI());
      WiFi.disconnect();
      WiFi.reconnect();
      healStage = 1;
      healStartedAt = millis();
    } else if (starving && healStage == 1 &&
               millis() - healStartedAt > 30000) {
      Serial.println("link heal: reconnect insufficient, restarting");
      Serial.flush();
      delay(100);
      ESP.restart();
    }
  }

  // After a heal reconnect completes, re-announce mDNS so the Mac's
  // re-resolution finds us. MDNS.end() below is mdns_free(): it drops every
  // registration, OTA's _arduino._tcp included, which is why addMdnsService()
  // owns that registration rather than ArduinoOTA - re-announcing here restores
  // OTA discovery with it. ArduinoOTA's own UDP socket is untouched by any of
  // this, so the listener never stops; only its advertisement would have.
  static bool mdnsRestartPending = false;
  static uint8_t lastHealStage = 0;
  if (healStage == 1 && lastHealStage == 0) {
    mdnsRestartPending = true;
  }
  lastHealStage = healStage;
  if (mdnsRestartPending && WiFi.status() == WL_CONNECTED) {
    mdnsRestartPending = false;
    MDNS.end();
    if (MDNS.begin(cfgName.c_str())) {
      addMdnsService();
      Serial.printf("mDNS re-announced, IP %s\n", WiFi.localIP().toString().c_str());
    }
  }

  // 1Hz heartbeat back to the sender: "EHB1" + 5 x u32 LE stats. Lets the
  // Mac detect blackholing and auto-tune its send pacing from real drops.
  static uint32_t lastHeartbeat = 0;
  if (hbPort != 0 && millis() - lastHeartbeat >= 1000) {
    lastHeartbeat = millis();
    uint8_t pkt[24];
    memcpy(pkt, "EHB1", 4);
    uint32_t vals[5] = {statFramesShown, statFramesDropped, statFramesSkipped,
                        statPackets, (uint32_t)ESP.getFreeHeap()};
    for (int i = 0; i < 5; i++) {
      pkt[4 + i * 4] = vals[i] & 0xFF;
      pkt[5 + i * 4] = (vals[i] >> 8) & 0xFF;
      pkt[6 + i * 4] = (vals[i] >> 16) & 0xFF;
      pkt[7 + i * 4] = (vals[i] >> 24) & 0xFF;
    }
    sendToSender(pkt, sizeof(pkt));
  }

  // Versioned capabilities and live state for the manager window. EHB1
  // remains unchanged for compatibility with older senders.
  static uint32_t lastInfo = 0;
  if (hbPort != 0 && millis() - lastInfo >= 2000) {
    lastInfo = millis();
    sendDeviceInfo();
  }

  // Battery, well slower than EINF's 2s. A cell does not move perceptibly in
  // ten seconds, and each sample is five I2C reads on the loop that also
  // services DMA and WiFi - so the cheapest cadence that still feels live wins.
  // Unlike the two timers above this is not gated on hbPort: the sample also
  // feeds the serial status line and CFGSHOW, which are the only way to read a
  // battery on a panel no sender has found yet. sendBatteryStatus() does the
  // hbPort check itself before it puts anything on the wire, and returns
  // immediately on a board with no PMU.
  static uint32_t lastBatteryPoll = 0;
  if (millis() - lastBatteryPoll >= 10000) {
    lastBatteryPoll = millis();
    sendBatteryStatus();
  }

  static uint32_t lastLedUpdate = 0;
  if (millis() - lastLedUpdate >= 2000) {
    lastLedUpdate = millis();
    updateSignalLed();
  }

  static uint32_t lastReport = 0;
  if (millis() - lastReport >= 5000) {
    lastReport = millis();
    Serial.printf("frames=%lu dropped=%lu skipped=%lu packets=%lu badlen=%lu drawerr=%lu heap=%lu rssi=%d\n",
                  (unsigned long)statFramesShown, (unsigned long)statFramesDropped,
                  (unsigned long)statFramesSkipped, (unsigned long)statPackets,
                  (unsigned long)statBadLen, (unsigned long)statDrawErrors,
                  (unsigned long)ESP.getFreeHeap(), (int)WiFi.RSSI());
    // Its own line, and only on a board with a PMU: the C6 boards would
    // otherwise print a battery field that can never say anything.
    if (batteryReadingCurrent()) {
      Serial.printf("battery: %d%% %s %umV present=%d vbus=%d\n",
                    batteryPercentOrUnknown(),
                    batteryChargeWord(lastBattery.charge),
                    (unsigned)lastBattery.millivolts, lastBattery.present,
                    lastBattery.externalPower);
    } else if (batteryAvailable && batteryReadingValid) {
      // The PMU answered once and has stopped. Said out loud rather than
      // silently repeating the last percentage, because this line is where a
      // dead PMU is diagnosed.
      Serial.printf("battery: no reading for %us (PMU stopped answering?)\n",
                    (unsigned)((millis() - lastBatteryAt) / 1000));
    }
  }
}
