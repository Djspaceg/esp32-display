#pragma once

#include <stddef.h>
#include <stdint.h>

#include <algorithm>
#include <cstdarg>
#include <cstdio>
#include <string>

using TickType_t = uint32_t;
using UBaseType_t = unsigned int;
using BaseType_t = int;
using TaskHandle_t = void *;
using QueueHandle_t = void *;
using TaskFunction_t = void (*)(void *);

static constexpr BaseType_t pdTRUE = 1;
static constexpr BaseType_t pdFALSE = 0;
static constexpr BaseType_t pdPASS = 1;
static constexpr int OUTPUT = 1;
static constexpr int LOW = 0;
static constexpr int HIGH = 1;

#define pdMS_TO_TICKS(ms) ((TickType_t)(ms))

struct portMUX_TYPE {};

#define portENTER_CRITICAL(mux) ((void)(mux))
#define portEXIT_CRITICAL(mux) ((void)(mux))

class String {
 public:
  String() = default;
  String(const char *value) : value_(value == nullptr ? "" : value) {}

  String &operator=(const char *value) {
    value_ = value == nullptr ? "" : value;
    return *this;
  }

  const char *c_str() const { return value_.c_str(); }

 private:
  std::string value_;
};

class IPAddress {
 public:
  explicit IPAddress(uint32_t value = 0) : value_(value) {}
  operator uint32_t() const { return value_; }
  String toString() const { return String("127.0.0.1"); }

 private:
  uint32_t value_;
};

class FakeSerial {
 public:
  int printf(const char *format, ...) {
    va_list args;
    va_start(args, format);
    const int result = std::vprintf(format, args);
    va_end(args);
    return result;
  }
  void println(const char *value) {
    if (value != nullptr) std::puts(value);
  }
};

extern FakeSerial Serial;

template <typename T>
constexpr T min(const T &left, const T &right) {
  return std::min(left, right);
}

template <typename T>
constexpr T max(const T &left, const T &right) {
  return std::max(left, right);
}

uint32_t millis();
uint32_t micros();
void delay(uint32_t milliseconds);
void pinMode(int pin, int mode);
void digitalWrite(int pin, int value);

QueueHandle_t xQueueCreate(UBaseType_t depth, UBaseType_t itemSize);
BaseType_t xQueueSend(QueueHandle_t queue, const void *item,
                      TickType_t waitTicks);
BaseType_t xQueueReceive(QueueHandle_t queue, void *item,
                         TickType_t waitTicks);
void vQueueDelete(QueueHandle_t queue);
BaseType_t xTaskCreatePinnedToCore(TaskFunction_t task, const char *name,
                                  uint32_t stack, void *argument,
                                  UBaseType_t priority,
                                  TaskHandle_t *handle, BaseType_t core);
void vTaskDelete(TaskHandle_t task);
void vTaskDelay(TickType_t ticks);
void taskYIELD();
