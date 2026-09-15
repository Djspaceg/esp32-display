#pragma once

#include <stddef.h>
#include <stdint.h>

#define IRAM_ATTR

extern uint32_t fakeMicros;
extern uint32_t fakeMicrosStep;

inline uint32_t micros() {
  const uint32_t now = fakeMicros;
  fakeMicros += fakeMicrosStep;
  return now;
}

inline uint32_t millis() { return micros() / 1000; }
inline void delay(uint32_t) {}

struct portMUX_TYPE {};
#define portMUX_INITIALIZER_UNLOCKED {}

inline void portENTER_CRITICAL(portMUX_TYPE *) {}
inline void portEXIT_CRITICAL(portMUX_TYPE *) {}
inline void portENTER_CRITICAL_ISR(portMUX_TYPE *) {}
inline void portEXIT_CRITICAL_ISR(portMUX_TYPE *) {}

struct FakeSerial {
  template <typename... Args>
  void printf(const char *, Args...) {}
};

extern FakeSerial Serial;
