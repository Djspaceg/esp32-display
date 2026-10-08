// Host tests for the C6 coprocessor's ESP-Hosted pairing and update gate
// (display_stream/coprocessor_update.h).
//
// The defect: a 4B whose C6 could not answer Req_GetCoprocessorFwVersion ran
// against host ESP-Hosted 2.12.13 and, about 18 minutes into a stream, stopped
// putting anything on the air while the link otherwise looked healthy. The
// firmware never said the two sides were mismatched. These checks pin that a
// silent coprocessor counts as outdated, that only the image pinned for the
// exact host version is ever offered, and that a transfer is finalized only
// with every byte and the pinned digest.
#include <cstdio>
#include <cstring>
#include <vector>

#include "../display_stream/coprocessor_update.h"

static int failures = 0;

static void check(bool condition, const char *message) {
  if (!condition) {
    std::printf("FAIL: %s\n", message);
    failures++;
  }
}

static const uint32_t HOST = coprocessor::version(2, 12, 13);

static void testClassify() {
  using coprocessor::Status;
  // The 4B and 4C as found: Req_GetCoprocessorFwVersion unanswered.
  check(coprocessor::classify(HOST, false, 0) == Status::Unreported,
        "a coprocessor that does not report its version is Unreported");
  check(coprocessor::needsUpdate(coprocessor::classify(HOST, false, 0)),
        "an Unreported coprocessor needs the update");
  check(coprocessor::classify(HOST, true, HOST) == Status::Current,
        "an exact match is Current");
  check(!coprocessor::needsUpdate(Status::Current),
        "a Current coprocessor is left alone");
  // 2.12.11 -> 2.12.13 carried an SDIO fix, so the patch level counts.
  check(coprocessor::classify(HOST, true, coprocessor::version(2, 12, 11)) ==
            Status::Older,
        "an older patch level is Older");
  check(coprocessor::needsUpdate(Status::Older), "Older needs the update");
  check(coprocessor::classify(HOST, true, coprocessor::version(2, 13, 0)) ==
            Status::Newer,
        "a newer coprocessor is Newer");
  check(!coprocessor::needsUpdate(Status::Newer), "Newer is never downgraded");
  check(!coprocessor::needsUpdate(Status::Unknown),
        "an unprobed coprocessor is not updated");
}

static void testTokens() {
  using coprocessor::Status;
  check(std::strcmp(coprocessor::statusToken(Status::Current), "current") == 0,
        "current token");
  check(std::strcmp(coprocessor::statusToken(Status::Unreported),
                    "unreported") == 0,
        "unreported token");
  check(std::strcmp(coprocessor::statusToken(Status::Older), "older") == 0,
        "older token");
  check(std::strcmp(coprocessor::statusToken(Status::Newer), "newer") == 0,
        "newer token");
  check(std::strcmp(coprocessor::statusToken(Status::Unknown), "unknown") == 0,
        "unknown token");
}

static void testPinnedImage() {
  const coprocessor::Image *image = coprocessor::imageForHost(HOST);
  check(image != nullptr, "host 2.12.13 has a pinned coprocessor image");
  if (image == nullptr) return;
  // The URL the core itself builds (esp32-hal-hosted.c hostedGetUpdateURL),
  // for the C6 at exactly the host's version.
  check(std::strcmp(image->url,
                    "https://espressif.github.io/arduino-esp32/hosted/"
                    "esp32c6-v2.12.13.bin") == 0,
        "the pinned URL is Espressif's C6 image for 2.12.13");
  check(image->length == 1226976, "the pinned length is the measured one");
  check(std::strlen(image->sha256) == 64, "the pinned digest is SHA-256 hex");
  for (const char *c = image->sha256; *c; ++c) {
    check((*c >= '0' && *c <= '9') || (*c >= 'a' && *c <= 'f'),
          "the pinned digest is lowercase hex");
  }
  check(coprocessor::imageForHost(coprocessor::version(2, 12, 12)) == nullptr,
        "a host version with no measured image gets none");
  check(coprocessor::imageForHost(coprocessor::version(2, 13, 0)) == nullptr,
        "a core upgrade gets no image until one is pinned");
}

static void testFinalizeGate() {
  const coprocessor::Image *image = coprocessor::imageForHost(HOST);
  if (image == nullptr) return;
  check(coprocessor::mayFinalize(*image, image->length, image->sha256),
        "every byte and the pinned digest finalizes");
  check(!coprocessor::mayFinalize(*image, image->length - 1, image->sha256),
        "a short transfer is never finalized");
  check(!coprocessor::mayFinalize(*image, image->length + 1, image->sha256),
        "a long transfer is never finalized");
  char wrong[65];
  std::strcpy(wrong, image->sha256);
  wrong[63] = wrong[63] == '0' ? '1' : '0';
  check(!coprocessor::mayFinalize(*image, image->length, wrong),
        "a one-nibble digest difference is never finalized");
  check(!coprocessor::mayFinalize(*image, image->length, nullptr),
        "no digest is never finalized");
}

// runTransfer over a fake source and coprocessor. The digest is whatever
// the test says it is, so the gate is tested apart from SHA-256 itself.
struct FakePort {
  uint32_t available = 0;      // bytes the source will hand out
  int stallAfterBytes = -1;    // >=0: return 0 forever after this many
  bool beginOk = true, endOk = true, activateOk = true;
  int failWriteAt = -1;        // write number that the coprocessor refuses
  const char *hex = nullptr;   // digest to report
  uint32_t served = 0, written = 0, writes = 0, firstWrite = 0;
  bool began = false, ended = false, activated = false;
  bool stalledFlag = false;

  bool begin() {
    began = true;
    return beginOk;
  }
  int read(uint8_t *buf, size_t want) {
    if (stallAfterBytes >= 0 && served >= (uint32_t)stallAfterBytes) {
      stalledFlag = true;
      return 0;
    }
    if (served >= available) return -1;
    size_t n = want;
    if (n > available - served) n = available - served;
    std::memset(buf, 0xA5, n);
    served += (uint32_t)n;
    return (int)n;
  }
  bool stalled() { return stalledFlag; }
  void digest(const uint8_t *, size_t) {}
  void digestHex(char out[65]) {
    std::snprintf(out, 65, "%s", hex != nullptr ? hex : "");
  }
  bool write(const uint8_t *, size_t len) {
    if (writes == 0) firstWrite = (uint32_t)len;
    if ((int)writes++ == failWriteAt) return false;
    written += (uint32_t)len;
    return true;
  }
  void progress(uint32_t, uint32_t) {}
  bool end() {
    ended = true;
    return endOk;
  }
  bool activate() {
    activated = true;
    return activateOk;
  }
};

static void testTransfer() {
  using coprocessor::TransferOutcome;
  const coprocessor::Image *image = coprocessor::imageForHost(HOST);
  if (image == nullptr) return;
  {
    FakePort port;
    port.available = image->length;
    port.hex = image->sha256;
    check(coprocessor::runTransfer(*image, port) == TransferOutcome::Installed,
          "a whole image with the pinned digest is installed");
    check(port.written == image->length && port.ended && port.activated,
          "installing writes every byte, then ends, then activates");
    check(port.firstWrite == 1400, "the first write is a whole chunk");
  }
  {
    FakePort port;
    port.available = image->length + 4096;  // an oversized body
    port.hex = image->sha256;
    check(coprocessor::runTransfer(*image, port) == TransferOutcome::Installed,
          "an oversized body is read only to the pinned length");
    check(port.written == image->length,
          "nothing past the pinned length reaches the coprocessor");
  }
  {
    FakePort port;
    port.available = image->length;
    port.hex = image->sha256;
    port.beginOk = false;
    check(coprocessor::runTransfer(*image, port) ==
              TransferOutcome::BeginRefused,
          "a refused begin is reported");
    check(port.writes == 0 && !port.ended, "a refused begin writes nothing");
  }
  {
    FakePort port;
    port.available = image->length - 100;  // the connection drops early
    port.hex = image->sha256;
    check(coprocessor::runTransfer(*image, port) == TransferOutcome::Stalled,
          "a body that ends short is a stall");
    check(!port.ended && !port.activated, "a short body is never finalized");
  }
  {
    FakePort port;
    port.available = image->length;
    port.stallAfterBytes = 700000;
    port.hex = image->sha256;
    check(coprocessor::runTransfer(*image, port) == TransferOutcome::Stalled,
          "a download that stops is a stall");
    check(!port.ended, "a stalled download is never finalized");
  }
  {
    FakePort port;
    port.available = image->length;
    port.failWriteAt = 3;
    port.hex = image->sha256;
    check(coprocessor::runTransfer(*image, port) ==
              TransferOutcome::WriteFailed,
          "a refused chunk is reported");
    check(!port.ended && !port.activated, "a refused chunk is never finalized");
  }
  {
    FakePort port;
    port.available = image->length;
    port.hex = "0000000000000000000000000000000000000000000000000000000000000000";
    check(coprocessor::runTransfer(*image, port) == TransferOutcome::Rejected,
          "a wrong digest is rejected");
    check(!port.ended && !port.activated, "a wrong digest is never finalized");
  }
  {
    FakePort port;
    port.available = image->length;
    port.hex = image->sha256;
    port.endOk = false;
    check(coprocessor::runTransfer(*image, port) == TransferOutcome::EndRefused,
          "the coprocessor's own rejection is reported");
    check(!port.activated, "a rejected image is never activated");
  }
  {
    FakePort port;
    port.available = image->length;
    port.hex = image->sha256;
    port.activateOk = false;
    check(coprocessor::runTransfer(*image, port) ==
              TransferOutcome::ActivateFailed,
          "a failed activation is not reported as installed");
  }
}

int main() {
  testClassify();
  testTokens();
  testPinnedImage();
  testFinalizeGate();
  testTransfer();
  if (failures != 0) {
    std::printf("test_coprocessor_update: %d failure(s)\n", failures);
    return 1;
  }
  std::printf("test_coprocessor_update: all checks passed\n");
  return 0;
}
