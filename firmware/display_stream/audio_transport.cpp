#include "audio_transport.h"

#include <string.h>

#include "audio_backend_model.h"

#if defined(CONFIG_IDF_TARGET_ESP32S3)
#include <lwip/sockets.h>
#endif

namespace audiotransport {

int tuneReceiveBufferBytes = 96 * 1024;
TaskHandle_t receiveTaskHandle = nullptr;

#if defined(CONFIG_IDF_TARGET_ESP32S3)
namespace {

constexpr UBaseType_t RECEIVE_TASK_PRIORITY = 13;
constexpr uint32_t RECEIVE_TASK_STACK = 5120;
constexpr int DRAIN_BEFORE_YIELD = 8;

int audioSocket = -1;
QueueHandle_t packetQueue = nullptr;
Stats transportStats;
volatile uint32_t peerIp = 0;
volatile uint16_t peerPort = 0;
uint16_t uplinkSequence = 0;
uint16_t statusSequence = 0;

void cleanupStartFailure() {
  if (audioSocket >= 0) {
    lwip_close(audioSocket);
    audioSocket = -1;
  }
  if (packetQueue != nullptr) {
    vQueueDelete(packetQueue);
    packetQueue = nullptr;
  }
  receiveTaskHandle = nullptr;
}

bool sendDatagram(const uint8_t *data, size_t length) {
  if (audioSocket < 0 || peerPort == 0) return false;
  struct sockaddr_in target = {};
  target.sin_family = AF_INET;
  target.sin_port = htons(peerPort);
  target.sin_addr.s_addr = peerIp;
  return lwip_sendto(audioSocket, data, length, 0,
                     reinterpret_cast<struct sockaddr *>(&target),
                     sizeof(target)) == (int)length;
}

void acceptDatagram(const uint8_t *data, size_t length,
                    const struct sockaddr_in &from) {
  audioproto::PcmDatagram parsed = {};
  const audioproto::ParseResult result =
      audioproto::parsePcmDownlink(data, length, parsed);
  if (result != audioproto::ParseResult::Ok) {
    if (result == audioproto::ParseResult::VersionMismatch) {
      transportStats.versionMismatches++;
    } else {
      transportStats.badDatagrams++;
    }
    return;
  }
  Packet packet = {};
  packet.header = parsed.header;
  packet.payloadBytes = (uint16_t)parsed.payloadBytes;
  memcpy(packet.samples, parsed.payload, parsed.payloadBytes);
  peerIp = from.sin_addr.s_addr;
  peerPort = ntohs(from.sin_port);
  if (xQueueSend(packetQueue, &packet, 0) != pdTRUE) {
    transportStats.queueDrops++;
  }
}

void receiveTask(void *) {
  static uint8_t receiveBuffer[audioproto::MAX_DATAGRAM_BYTES];
  while (true) {
    struct sockaddr_in from = {};
    socklen_t fromLength = sizeof(from);
    int received = lwip_recvfrom(
        audioSocket, receiveBuffer, sizeof(receiveBuffer), 0,
        reinterpret_cast<struct sockaddr *>(&from), &fromLength);
    if (received <= 0) {
      vTaskDelay(1);
      continue;
    }
    acceptDatagram(receiveBuffer, (size_t)received, from);
    for (int drained = 0; drained < DRAIN_BEFORE_YIELD; ++drained) {
      fromLength = sizeof(from);
      received = lwip_recvfrom(
          audioSocket, receiveBuffer, sizeof(receiveBuffer), MSG_DONTWAIT,
          reinterpret_cast<struct sockaddr *>(&from), &fromLength);
      if (received <= 0) break;
      acceptDatagram(receiveBuffer, (size_t)received, from);
    }
    // The receive task outranks the engine so it can empty lwIP promptly, but
    // it yields after a bounded burst so the depth-12 handoff queue drains.
    taskYIELD();
  }
}

}  // namespace

bool start(const board::Config &config) {
  const board::AudioConfig *audio =
      board::generatedAudioConfig(config.variant);
  if (audio == nullptr ||
      audiobackend::classify(*audio) !=
          audiobackend::DescriptorStatus::Ready) {
    return false;
  }
  packetQueue = xQueueCreate(QUEUE_DEPTH, sizeof(Packet));
  if (packetQueue == nullptr) return false;
  audioSocket = lwip_socket(AF_INET, SOCK_DGRAM, IPPROTO_IP);
  if (audioSocket < 0) {
    cleanupStartFailure();
    return false;
  }
  if (!setReceiveBufferBytes(tuneReceiveBufferBytes)) {
    cleanupStartFailure();
    return false;
  }
  struct sockaddr_in address = {};
  address.sin_family = AF_INET;
  address.sin_port = htons(audioproto::UDP_PORT);
  address.sin_addr.s_addr = htonl(INADDR_ANY);
  if (lwip_bind(audioSocket,
                reinterpret_cast<struct sockaddr *>(&address),
                sizeof(address)) < 0) {
    cleanupStartFailure();
    return false;
  }
  if (xTaskCreatePinnedToCore(
          receiveTask, "audiorx", RECEIVE_TASK_STACK, nullptr,
          RECEIVE_TASK_PRIORITY, &receiveTaskHandle, 1) != pdPASS) {
    cleanupStartFailure();
    return false;
  }
  return true;
}

void stop() {
  if (receiveTaskHandle != nullptr) {
    vTaskDelete(receiveTaskHandle);
    receiveTaskHandle = nullptr;
  }
  cleanupStartFailure();
  peerIp = 0;
  peerPort = 0;
}

bool available() {
  return audioSocket >= 0 && packetQueue != nullptr &&
         receiveTaskHandle != nullptr;
}

bool receive(Packet &packet, TickType_t waitTicks) {
  return packetQueue != nullptr &&
         xQueueReceive(packetQueue, &packet, waitTicks) == pdTRUE;
}

bool sendCapture(const int16_t *samples, uint16_t frameCount,
                 uint8_t channels, uint32_t sampleRateHz,
                 uint16_t streamGeneration, uint32_t sampleCounter) {
  uint8_t datagram[audioproto::MAX_DATAGRAM_BYTES];
  const size_t payloadBytes =
      (size_t)frameCount * channels * sizeof(int16_t);
  const audioproto::PcmHeader header = {
      audioproto::DatagramKind::PcmUplink,
      uplinkSequence++,
      streamGeneration,
      sampleRateHz,
      sampleCounter,
      micros(),
      frameCount,
      channels,
  };
  const size_t length = audioproto::writePcm(
      datagram, sizeof(datagram), header,
      reinterpret_cast<const uint8_t *>(samples), payloadBytes);
  if (length == 0 || !sendDatagram(datagram, length)) {
    transportStats.uplinkErrors++;
    return false;
  }
  return true;
}

bool sendStatus(uint16_t streamGeneration, uint32_t sampleRateHz,
                const audioproto::Status &status) {
  uint8_t datagram[audioproto::HEADER_BYTES +
                   audioproto::STATUS_PAYLOAD_BYTES];
  const size_t length = audioproto::writeStatus(
      datagram, sizeof(datagram), statusSequence++, streamGeneration,
      sampleRateHz, micros(), status);
  return length > 0 && sendDatagram(datagram, length);
}

bool setReceiveBufferBytes(int bytes) {
  if (bytes < 16 * 1024 || bytes > 256 * 1024) return false;
  if (audioSocket >= 0 &&
      lwip_setsockopt(audioSocket, SOL_SOCKET, SO_RCVBUF, &bytes,
                      sizeof(bytes)) != 0) {
    return false;
  }
  tuneReceiveBufferBytes = bytes;
  return true;
}

const Stats &stats() { return transportStats; }

#else

bool start(const board::Config &) { return false; }
void stop() {}
bool available() { return false; }
bool receive(Packet &, TickType_t) { return false; }
bool sendCapture(const int16_t *, uint16_t, uint8_t, uint32_t, uint16_t,
                 uint32_t) {
  return false;
}
bool sendStatus(uint16_t, uint32_t, const audioproto::Status &) {
  return false;
}
bool setReceiveBufferBytes(int bytes) {
  if (bytes < 16 * 1024 || bytes > 256 * 1024) return false;
  tuneReceiveBufferBytes = bytes;
  return true;
}
const Stats &stats() {
  static Stats empty;
  return empty;
}

#endif

}  // namespace audiotransport
