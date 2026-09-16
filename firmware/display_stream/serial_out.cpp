#include "serial_out.h"

#include <freertos/FreeRTOS.h>
#include <freertos/semphr.h>

namespace serialout {

// RECURSIVE on purpose. loop()'s five-second report takes a LineGuard around a
// group of lines, and the modules it calls emit through this same path; a plain
// mutex would deadlock the loop task the first time that happened, taking the
// panel down with it. Recursion makes the guard composable instead of a trap for
// whoever adds the next line inside the block.
static SemaphoreHandle_t lineMutex = nullptr;

// How long a writer waits for the mutex before emitting anyway.
//
// Emitting anyway is deliberate. The alternative is dropping a line because
// another writer is slow, and this machinery exists to make serial output
// trustworthy. Every writer on this firmware runs on the loop task bar one
// boot-time recovery line, so a contended lock should not happen at all; if it
// ever does, a possibly-interleaved line is more honest than silence.
static const TickType_t LOCK_WAIT_TICKS = pdMS_TO_TICKS(250);

void begin() {
  if (lineMutex == nullptr) {
    lineMutex = xSemaphoreCreateRecursiveMutex();
  }
}

namespace {

// The Lock half of serialline::writeLine's contract.
struct MutexLock {
  bool held = false;

  bool acquire() {
    if (lineMutex != nullptr) {
      held = xSemaphoreTakeRecursive(lineMutex, LOCK_WAIT_TICKS) == pdTRUE;
    }
    return true;  // see LOCK_WAIT_TICKS: never refuse to emit
  }
  void release() {
    if (held) {
      xSemaphoreGiveRecursive(lineMutex);
      held = false;
    }
  }
};

// The Sink half. room() is availableForWrite(), which both transports this
// firmware uses report honestly: HWCDC returns its TX ring's free space and
// HardwareSerial returns its UART TX buffer's. Asking before writing is the
// whole point - see serial_line.h for what the CDC path does to a write that
// does not fit.
struct StreamSink {
  Stream &port;

  size_t room() {
    const int available = port.availableForWrite();
    return available > 0 ? (size_t)available : 0;
  }
  size_t write(const uint8_t *data, size_t length) {
    return port.write(data, length);
  }
  void idle() { delay(1); }
};

// Formats into buffer and returns the length with any trailing newlines
// trimmed. Callers converted from printf() keep their "\n", and writeLine
// appends one of its own; trimming here avoids editing sixty-odd call sites.
size_t formatTrimmed(char *buffer, size_t capacity, const char *format,
                     va_list args) {
  const int length = vsnprintf(buffer, capacity, format, args);
  if (length <= 0) return 0;
  size_t bytes = (size_t)length < capacity ? (size_t)length : capacity - 1;
  while (bytes > 0 && (buffer[bytes - 1] == '\n' || buffer[bytes - 1] == '\r')) {
    bytes--;
  }
  return bytes;
}

}  // namespace

LineGuard::LineGuard() : held_(false) {
  if (lineMutex != nullptr) {
    held_ = xSemaphoreTakeRecursive(lineMutex, LOCK_WAIT_TICKS) == pdTRUE;
  }
}

LineGuard::~LineGuard() {
  if (held_) xSemaphoreGiveRecursive(lineMutex);
}

void line(Stream &port, const char *text) {
  if (text == nullptr) return;
  MutexLock lock;
  StreamSink sink = {port};
  serialline::writeLine(lock, sink, text, strlen(text));
}

void printfLine(Stream &port, const char *format, ...) {
  char buffer[LINE_BYTES];
  va_list args;
  va_start(args, format);
  const size_t bytes = formatTrimmed(buffer, sizeof(buffer), format, args);
  va_end(args);
  if (bytes == 0) return;
  MutexLock lock;
  StreamSink sink = {port};
  serialline::writeLine(lock, sink, buffer, bytes);
}

void LineSerial::printf(const char *format, ...) {
  char buffer[LINE_BYTES];
  va_list args;
  va_start(args, format);
  const size_t bytes = formatTrimmed(buffer, sizeof(buffer), format, args);
  va_end(args);
  if (bytes == 0) return;
  MutexLock lock;
  StreamSink sink = {port_};
  serialline::writeLine(lock, sink, buffer, bytes);
}

}  // namespace serialout
