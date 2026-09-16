// Whole-line serial emission: chunk to what the transport can actually take,
// wait for room rather than overrunning it, and keep one line contiguous.
//
// WHY THIS EXISTS - measured, not inferred.
//
// The CFGSHOW identity reply was arriving truncated. A timestamped raw capture
// showed the reply stopping at exactly byte 256 with the tail never arriving at
// all, while a shorter 339-byte reply on the same board got through intact when
// the ring happened to be empty. The cut is a size boundary, not a collision
// with another writer:
//
//   t=+0.002s +95B  (cum 95)
//   t=+0.002s +64B  (cum 159)
//   t=+0.002s +97B  (cum 256)   <- reply ends here, mid-token
//   t=+1.514s +90B  (cum 346)   <- next line, so the port is alive
//
// 256 is HWCDC's default TX ring size. HWCDC::begin() installs a 256-byte ring
// when none was requested, and display_stream.ino never asked for more. A
// write larger than the free ring space is chunked internally, and if the ring
// does not drain the remainder is ABANDONED after a bounded number of timeouts;
// write() then returns a short count. Print::printf() discards that count, so
// the firmware believed it had emitted a whole line. Worse, the abandoned tail
// takes the trailing newline with it, which is what made the next telemetry
// line look spliced onto the reply and sent the first diagnosis chasing a race.
//
// Two independent things were therefore wrong, and both are fixed:
//
//   1. The ring was too small for the line. display_stream.ino now sizes it
//      deliberately instead of inheriting a default that happens to sit just
//      under the identity reply's length.
//   2. Nothing checked whether the bytes fit. That is this file's job: never
//      hand the transport more than it currently has room for, and wait for
//      room instead of letting the driver drop the remainder silently.
//
// Fix 2 alone would be enough to stop the truncation, but it makes emission a
// multi-write operation, which genuinely opens the interleaving window the
// original report described. Hence the lock: it is held across the entire
// line including its newline, so no other writer can land bytes between a
// line's first and last character.
//
// Deliberately Arduino-free so the policy is host-testable.
#pragma once

#include <stddef.h>
#include <stdint.h>

namespace serialline {

// Largest single write handed to the transport. Small enough that a chunk fits
// comfortably in any sane ring, so progress does not depend on the ring being
// mostly empty.
static const size_t MAX_CHUNK_BYTES = 64;

// How many idle turns to spend waiting for room before abandoning the line.
// A bounded wait matters more than a complete line: the loop task emits these,
// and a host that opens the CDC port and stops draining it must never be able
// to wedge the pipeline. At roughly a millisecond per turn this is a few
// hundred milliseconds of patience, then the line is dropped and the firmware
// keeps running.
static const unsigned MAX_IDLE_WAITS = 400;

// Emits text plus exactly one trailing newline as one uninterrupted line.
// Returns the number of body bytes accepted, excluding the newline, so a caller
// can tell a complete line from an abandoned one.
template <typename Lock, typename Sink>
inline size_t writeLine(Lock &lock, Sink &sink, const char *text,
                        size_t length) {
  if (text == nullptr) return 0;
  if (!lock.acquire()) return 0;

  size_t sent = 0;
  bool abandoned = false;
  const char newline = '\n';

  // Phase 0 is the body, phase 1 the newline. The newline goes inside the lock
  // and inside the same room-checked path as the body: a line whose terminator
  // was dropped is what made this bug look like a splice in the first place.
  for (int phase = 0; phase < 2 && !abandoned; phase++) {
    const char *cursor = phase == 0 ? text : &newline;
    size_t remaining = phase == 0 ? length : 1;
    while (remaining > 0) {
      size_t want = remaining < MAX_CHUNK_BYTES ? remaining : MAX_CHUNK_BYTES;
      unsigned waits = 0;
      size_t room = sink.room();
      while (room < want) {
        if (room > 0) {
          want = room;  // partial room is progress; take it
          break;
        }
        if (waits >= MAX_IDLE_WAITS) {
          abandoned = true;
          break;
        }
        sink.idle();
        waits++;
        room = sink.room();
      }
      if (abandoned) break;
      const size_t wrote = sink.write((const uint8_t *)cursor, want);
      if (wrote == 0) {
        abandoned = true;  // transport refused despite reporting room
        break;
      }
      cursor += wrote;
      remaining -= wrote;
      if (phase == 0) sent += wrote;
    }
  }

  lock.release();
  return sent;
}

}  // namespace serialline
