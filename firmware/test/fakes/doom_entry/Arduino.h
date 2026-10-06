// Host fake of the Arduino surface input_button.cpp and boot_menu.cpp touch. Serial output is
// captured so a test can read the last line the firmware printed, and
// ESP.restart() only records the call.
#pragma once

#include <stddef.h>
#include <stdint.h>

#include <cstdarg>
#include <cstdio>
#include <string>

#define IRAM_ATTR
static constexpr int LOW = 0;
static constexpr int HIGH = 1;
static constexpr int INPUT_PULLUP = 0x05;
static constexpr int CHANGE = 0x03;

class String {
 public:
  String() = default;
  String(const char *value) : value_(value == nullptr ? "" : value) {}
  const char *c_str() const { return value_.c_str(); }

 private:
  std::string value_;
};

class FakeSerial {
 public:
  std::string captured;
  int printf(const char *format, ...) __attribute__((format(printf, 2, 3))) {
    char line[512];
    va_list args;
    va_start(args, format);
    const int written = std::vsnprintf(line, sizeof(line), format, args);
    va_end(args);
    captured += line;
    return written;
  }
  void println(const char *value) {
    captured += value;
    captured += "\n";
  }
  void flush() {}
};
extern FakeSerial Serial;

// A real restart never returns. A test that runs a loop which only a restart
// leaves sets throwOnRestart and catches FakeRestart.
struct FakeRestart {};

class FakeEsp {
 public:
  int restarts = 0;
  bool throwOnRestart = false;
  void restart() {
    restarts++;
    if (throwOnRestart) throw FakeRestart();
  }
};
extern FakeEsp ESP;

void delay(uint32_t ms);
uint32_t millis();
void pinMode(int pin, int mode);
int digitalRead(int pin);
int digitalPinToInterrupt(int pin);
void attachInterrupt(int interrupt, void (*isr)(), int mode);
