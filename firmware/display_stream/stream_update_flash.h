// How a stream-channel update puts its image into flash. On a DSI panel the
// whole image area is erased first; elsewhere each 64 KiB block is erased as
// the writes reach it. Writes go in sector-sized batches, and the image's
// first bytes go last. Pure, so test/test_stream_update.cpp drives the exact
// code the panel runs.
//
// WHY ERASE FIRST ON DSI. A flash erase or write turns the cache off, and on
// the P4 that also stops the DSI refresh, whose restart runs from a cached
// interrupt: the panel shows a blank cyan field for as long as it lasts.
// Arduino's Update erased a 64 KiB block every 64 KiB written, about 130 ms
// each, 33 times in a 2 MB image, so the progress screen flickered
// throughout. Erasing the whole area before the progress screen is up (in
// steps, so loop() still feeds the watchdog and the sender's heartbeat
// between them) leaves only page writes during the transfer, and those
// finish inside one refresh. SPI panels keep their own frame memory and never
// showed this, so they keep erasing as they go and lose no time up front.
//
// WHY THE FIRST BYTES LAST. Update withheld the image's first 16 bytes until
// end(), so a transfer that stopped anywhere short of activation was never a
// valid image. This keeps that: they are left erased, not written, until
// finish(), after the digest matched. Sixteen rather than one so the write
// stays aligned if flash encryption is ever turned on.
#pragma once

#include <stddef.h>
#include <stdint.h>
#include <string.h>

namespace streamupdate {

class FlashSink {
 public:
  virtual ~FlashSink() {}
  virtual bool erase(uint32_t offset, uint32_t length) = 0;
  virtual bool write(uint32_t offset, const uint8_t *data, size_t length) = 0;
};

class FlashImageWriter {
 public:
  static const uint32_t SECTOR_BYTES = 4096;
  // One erase step: a 64 KiB block erase is one flash command, ~130 ms.
  static const uint32_t ERASE_STEP_BYTES = 65536;
  static const size_t BATCH_BYTES = SECTOR_BYTES;
  static const size_t WITHHELD_BYTES = 16;

  /// eraseFirst: erase everything through eraseStep() before any write.
  /// Otherwise eraseDone() at once, and write() erases blocks as it goes.
  void start(FlashSink *sink, uint32_t imageBytes, bool eraseFirst) {
    sink_ = sink;
    imageBytes_ = imageBytes;
    eraseEnd_ = (imageBytes + SECTOR_BYTES - 1) / SECTOR_BYTES * SECTOR_BYTES;
    eraseFirst_ = eraseFirst;
    erased_ = 0;
    written_ = 0;
    batchLen_ = 0;
    withheldLen_ = 0;
    failed_ = sink == nullptr || imageBytes == 0;
  }

  /// No image: every later call fails.
  void close() { start(nullptr, 0, false); }

  bool eraseDone() const {
    return !failed_ && (!eraseFirst_ || erased_ >= eraseEnd_);
  }
  uint32_t erasedBytes() const { return erased_; }
  bool failed() const { return failed_; }

  /// Erases the next step of an erase-first image. False on failure; true
  /// once done, and then a no-op.
  bool eraseStep() {
    if (failed_) return false;
    if (!eraseFirst_ || erased_ >= eraseEnd_) return true;
    return eraseNext();
  }

  /// Appends the next bytes of the image, in order. False once anything has
  /// failed, including a write before the erase finished or past the image.
  bool write(const uint8_t *data, size_t length) {
    if (failed_ || !eraseDone()) return fail();
    if (length > imageBytes_ - written_) return fail();
    while (length > 0) {
      size_t take = BATCH_BYTES - batchLen_;
      if (take > length) take = length;
      memcpy(batch_ + batchLen_, data, take);
      batchLen_ += take;
      written_ += (uint32_t)take;
      data += take;
      length -= take;
      if (batchLen_ == BATCH_BYTES && !flush()) return false;
    }
    return true;
  }

  /// Writes what is buffered, then the withheld first bytes. Only for a
  /// whole image whose digest has been checked.
  bool finish() {
    if (failed_ || written_ != imageBytes_) return fail();
    if (!flush()) return false;
    if (withheldLen_ == 0) return fail();
    if (!sink_->write(0, withheld_, withheldLen_)) return fail();
    return true;
  }

 private:
  bool eraseNext() {
    uint32_t len = eraseEnd_ - erased_;
    if (len > ERASE_STEP_BYTES) len = ERASE_STEP_BYTES;
    if (!sink_->erase(erased_, len)) return fail();
    erased_ += len;
    return true;
  }

  bool flush() {
    if (batchLen_ == 0) return true;
    uint32_t offset = written_ - (uint32_t)batchLen_;
    const uint8_t *from = batch_;
    size_t len = batchLen_;
    // Erase-as-you-go: every block this batch reaches, before writing it.
    while (!eraseFirst_ && erased_ < offset + len) {
      if (!eraseNext()) return false;
    }
    if (offset == 0) {
      withheldLen_ = len < WITHHELD_BYTES ? len : WITHHELD_BYTES;
      memcpy(withheld_, batch_, withheldLen_);
      offset += (uint32_t)withheldLen_;
      from += withheldLen_;
      len -= withheldLen_;
    }
    if (len > 0 && !sink_->write(offset, from, len)) return fail();
    batchLen_ = 0;
    return true;
  }
  bool fail() {
    failed_ = true;
    return false;
  }

  FlashSink *sink_ = nullptr;
  uint32_t imageBytes_ = 0;
  uint32_t eraseEnd_ = 0;
  bool eraseFirst_ = false;
  uint32_t erased_ = 0;
  uint32_t written_ = 0;
  size_t batchLen_ = 0;
  size_t withheldLen_ = 0;
  uint8_t batch_[BATCH_BYTES];
  uint8_t withheld_[WITHHELD_BYTES];
  bool failed_ = true;
};

}  // namespace streamupdate
