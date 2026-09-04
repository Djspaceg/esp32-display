#include "net_link.h"

#include <Arduino.h>
#include <AsyncUDP.h>
#include <Preferences.h>

#include "app_state.h"
#include "band_protocol.h"
#include "control_apply.h"
#include "device_protocol.h"
#include "display_power.h"
#include "frame_pipeline.h"

using namespace bandproto;


// Reply endpoint: source of the most recent packet from the Mac. Used for
// the 1Hz heartbeat so the sender can detect blackholing (wrong IP after a
// reboot, WiFi drop) and see delivery stats. u32+u16 writes are effectively
// atomic on this 32-bit core.
volatile uint32_t hbIp = 0;
volatile uint16_t hbPort = 0;

AsyncUDP udp;

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
  if (len >= 4 && memcmp(data, "ETL1", 4) == 0) {
#if defined(ESPDISP_LARGE_TILE_STREAM)
    if (largeTileStreamEnabled()) {
      handleLargeTilePacket(data, len);
      return;
    }
#endif
    statBadLen++;
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
#if defined(CONFIG_IDF_TARGET_ESP32S3)
    // On the tile board, bit 15 means TILE packet, full stop: this board
    // advertises CAP_TILE_STREAM and not CAP_COMPRESSED_BANDS, so no
    // correct sender ever sends it a packed band packet, and the two
    // layouts are byte-ambiguous past the flag - parsing by capability is
    // the only sound reading. See deviceCapabilities().
    if (tileStreamEnabled()) {
      handleTilePacket(data, len);
      return;
    }
#endif
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
#include <lwip/sockets.h>

static int rxSock = -1;

// Priority above loopTask (1) so a queued datagram preempts drawing
// bookkeeping, below the WiFi/lwIP tasks (18+) which feed it. Pinned to core
// 1: lwIP runs on core 0, so parsing and the PSRAM band copy no longer
// compete with the radio.
static const UBaseType_t RX_TASK_PRIORITY = 9;
static const uint32_t RX_TASK_STACK = 6144;
// The receive task's handle, kept so CFGTUNE rxprio can move its priority at
// runtime. Section 17.2 measured the draw pass's per-call cost inflating
// ~10x under network load, and the scheduling half of that mechanism is this
// task preempting loopTask's gather memcpys from priority 9 against 1 on the
// same core; section 17.6 item 3 names re-prioritising the two tasks as the
// untested lever. A runtime knob rather than a constant for the same
// measurement-discipline reason as tuneRxDrainYieldEvery: interleaved A/B
// arms need to swap without a ~2 minute reflash per swap.
TaskHandle_t rxTaskHandle = nullptr;
/// Datagrams this task may drain before yielding to the draw loop. See the
/// drain loop in udpReceiveTask for why an explicit yield is required.
///
/// A variable rather than a constant so `CFGTUNE` can change it at runtime.
/// That is a measurement requirement, not a feature: the run-to-run spread on
/// this hardware is ~4 fps peak-to-peak at the operating point
/// (docs/tile-stream-plan.md section 17.11), so resolving anything smaller
/// needs many samples with the arms INTERLEAVED - and a reflash per swap costs
/// ~2 minutes, which forces blocked sampling, which is exactly how this
/// project already accepted one false positive.
int tuneRxDrainYieldEvery = 24;

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
    // Drain whatever queued while that one was being processed, without
    // blocking. The point is lwIP's UDP receive mailbox: it is a fixed
    // SMALL number of slots (CONFIG_LWIP_UDP_RECVMBOX_SIZE, an sdkconfig
    // fact this build cannot change), so datagrams landing while a record
    // decodes have very little room to wait in - pulling them out the
    // moment processing ends, instead of taking the blocking path's
    // suspend/wake round trip per datagram, is the one queue-depth lever
    // available at runtime. Empty is the normal exit; a saturating flood
    // cannot starve anything this way that it would not also starve
    // through the blocking call, which returns immediately when data is
    // queued.
    // Bounded, and it yields when it hits the bound. This task runs at
    // priority 9 and loop() at 1, so a drain loop that keeps finding data
    // never lets the DRAW happen: measured with `espdisp.py tile-motion`, at
    // 30 full frames/s offered the panel accepted 1519 datagrams/s and drew
    // only 5.4 times a second - the tiles were arriving and sitting in bufA
    // unshown. Neither the blocking recvfrom nor MSG_DONTWAIT yields while
    // data is queued, so the yield has to be explicit; vTaskDelay(1) is the
    // shortest one that actually lets a lower-priority task be scheduled.
    // 24 datagrams between yields keeps the ceiling far above the radio's
    // (~24 per tick is ~24000/s) while bounding how long drawing waits.
    int drained = 0;
    while (true) {
      fromLen = sizeof(from);
      n = lwip_recvfrom(rxSock, rxBuf, sizeof(rxBuf), MSG_DONTWAIT,
                        (struct sockaddr *)&from, &fromLen);
      if (n <= 0) break;  // empty (EWOULDBLOCK) or error: back to blocking
      handleInbound(rxBuf, (size_t)n, from.sin_addr.s_addr,
                    ntohs(from.sin_port));
      if (++drained >= tuneRxDrainYieldEvery) {
        drained = 0;
        vTaskDelay(1);  // let loopTask draw what has arrived
      }
    }
  }
}

static bool startRawInboundTransport() {
  rxSock = lwip_socket(AF_INET, SOCK_DGRAM, IPPROTO_IP);
  if (rxSock < 0) return false;
  // Raise the socket's queued-byte cap (lwIP accounts SO_RCVBUF against
  // datagrams waiting in the receive mailbox). The default is a few KB -
  // two or three full datagrams - so a burst arriving while one record
  // decodes gets dropped at the socket even when memory is plentiful.
  // 64 KB holds a ~44-datagram burst. Best effort: if the option is
  // compiled out of lwIP, the setsockopt fails and the old behavior
  // stands - the drain loop in udpReceiveTask still helps on its own.
  int rcvBuf = 64 * 1024;
  lwip_setsockopt(rxSock, SOL_SOCKET, SO_RCVBUF, &rcvBuf, sizeof(rcvBuf));
  struct sockaddr_in addr = {};
  addr.sin_family = AF_INET;
  addr.sin_port = htons(UDP_PORT);
  addr.sin_addr.s_addr = htonl(INADDR_ANY);
  if (lwip_bind(rxSock, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
    lwip_close(rxSock);
    rxSock = -1;
    return false;
  }
  // Which core the receive task pins to. Boot default is core 1 (away from
  // lwIP/WiFi on core 0), which is the arrangement every measurement so far
  // was taken under. CFGRXCORE persists 0 to test the section 18.2/18.4
  // hypothesis - that core 1 is oversubscribed by decode + draw together and
  // only PARALLELISM (not priorities, not moving work between tasks) can
  // help - by putting decode with the radio on core 0 and leaving core 1 to
  // the draw loop. NVS-persisted, unlike the CFGTUNE knobs, because task
  // affinity is fixed at creation: applying it takes the restart, and an A/B
  // arm swap is then a 5-second reboot instead of a 2-minute reflash.
  Preferences corePrefs;
  corePrefs.begin("espdisp", true);
  uint8_t rxCore = corePrefs.getUChar("rxcore", 1);
  corePrefs.end();
  if (rxCore > 1) rxCore = 1;
  Serial.printf("udprx pinned to core %u%s\n", (unsigned)rxCore,
                rxCore == 0 ? " (CFGRXCORE experiment)" : "");
  return xTaskCreatePinnedToCore(udpReceiveTask, "udprx", RX_TASK_STACK,
                                 nullptr, RX_TASK_PRIORITY, &rxTaskHandle,
                                 rxCore) == pdPASS;
}

static void sendRawToSender(const uint8_t *data, size_t len) {
  if (rxSock < 0 || hbPort == 0) return;
  struct sockaddr_in to = {};
  to.sin_family = AF_INET;
  to.sin_port = htons(hbPort);
  to.sin_addr.s_addr = hbIp;  // stored exactly as recvfrom produced it
  lwip_sendto(rxSock, data, len, 0, (struct sockaddr *)&to, sizeof(to));
}

static void onPacket(AsyncUDPPacket packet) {
  handleInbound(packet.data(), packet.length(), (uint32_t)packet.remoteIP(),
                packet.remotePort());
}

static bool startAsyncInboundTransport() {
  if (!udp.listen(UDP_PORT)) return false;
  udp.onPacket(onPacket);
  return true;
}

static void sendAsyncToSender(const uint8_t *data, size_t len) {
  if (hbPort == 0) return;
  udp.writeTo(data, len, IPAddress(hbIp), hbPort);
}

bool startInboundTransport() {
  return board::COMPILED_PLATFORM.useRawLwipReceiveTask
             ? startRawInboundTransport()
             : startAsyncInboundTransport();
}

void sendToSender(const uint8_t *data, size_t len) {
  if (board::COMPILED_PLATFORM.useRawLwipReceiveTask) {
    sendRawToSender(data, len);
  } else {
    sendAsyncToSender(data, len);
  }
}
