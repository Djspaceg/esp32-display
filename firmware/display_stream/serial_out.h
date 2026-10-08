// Arduino binding for serialline::writeLine. See serial_line.h for the measured
// root cause this exists to fix.
#pragma once

#include <Arduino.h>
#include <stdarg.h>
#include <stddef.h>
#include <string.h>

#include "serial_line.h"

namespace serialout {

// Creates the interleaving mutex. Safe to call before any line is emitted;
// lines emitted before it are handled single-threaded during early boot.
void begin();

// Holds the line lock across a group of related lines, so a multi-line report
// block cannot be split by another writer. Recursive, so anything called inside
// the block may itself emit lines.
class LineGuard {
 public:
  LineGuard();
  ~LineGuard();

 private:
  bool held_;
  LineGuard(const LineGuard &);
  LineGuard &operator=(const LineGuard &);
};

// Emits text plus exactly one newline as one uninterrupted line.
void line(Stream &port, const char *text);

// Formatting buffer size. The CFGINFO identity reply is the longest line this
// firmware emits: with a 32-byte SSID (twice, once base64), a 32-byte name, the
// longest profile, target and partition tokens and the src= build identity it
// reaches about 550 bytes, and a hosted board's c6fw= and c6= after src= add
// about 30. A trimmed line loses its LAST fields first, so this is sized with
// headroom rather than to the byte. The buffer is on the caller's stack.
static const size_t LINE_BYTES = 768;

void printfLine(Stream &port, const char *format, ...)
    __attribute__((format(printf, 2, 3)));

// Drop-in stand-in for a Stream at call sites that only print whole lines.
// Returned by value so the ~70 existing configSerial().println/printf call
// sites compile unchanged.
class LineSerial {
 public:
  explicit LineSerial(Stream &port) : port_(port) {}
  void println(const char *text) { line(port_, text); }
  void println(const String &text) { line(port_, text.c_str()); }
  // print() also terminates the line. Every caller here prints a complete
  // message; a partial print would defeat the whole-line guarantee.
  void print(const char *text) { line(port_, text); }
  void printf(const char *format, ...) __attribute__((format(printf, 2, 3)));
  void flush() { port_.flush(); }

 private:
  Stream &port_;
};

}  // namespace serialout
