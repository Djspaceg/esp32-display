// Host tests for the firmware update over the stream channel
// (display_stream/stream_update.h): the packets, the chunk/ack window, the
// PBKDF2 challenge, and the SHA-256 gate in front of Update.end().
//
// The receiver is driven exactly as stream_update_service.cpp drives it on
// the panel - onPacket() on the receive path, takeWork()/finish*() on the
// loop - against a fake flash and a reference SHA-256, through a simulated
// link that loses, duplicates and reorders datagrams.
#include <cstdio>
#include <cstring>
#include <deque>
#include <map>
#include <random>
#include <string>
#include <vector>

#include "../display_stream/device_protocol.h"
#include "../display_stream/stream_update.h"
#include "support/sha256_ref.h"

using namespace streamupdate;

static int failures = 0;

static void check(bool condition, const char *message) {
  if (!condition) {
    std::printf("FAIL: %s\n", message);
    failures++;
  }
}

static const char PASSWORD[] = "correct horse battery";
static const Endpoint MAC = {0x0A01A8C0u, 50123};
static const Endpoint OTHER = {0x0B01A8C0u, 50123};

class RefHasher : public Hasher {
 public:
  void reset() override { sha.reset(); }
  void update(const uint8_t *d, size_t n) override { sha.update(d, n); }
  void finish(uint8_t out[SHA256_BYTES]) override { sha.finish(out); }
  sharef::Sha256 sha;
};

// Update's part of the bargain: what was begun, written, ended, aborted.
struct FakeFlash {
  bool begun = false;
  uint32_t size = 0;
  std::vector<uint8_t> written;
  int writes = 0;
  int activations = 0;
  int aborts = 0;
  bool failWrites = false;
  bool refuseEnd = false;
};

struct Panel {
  Receiver rx;
  RefHasher hasher;
  FakeFlash flash;
  std::vector<uint8_t> slotMemory;
  uint16_t slotsWanted = 32;
  uint32_t now = 1000;
  std::vector<Receiver::Outgoing> sent;
  uint8_t random[32];

  explicit Panel(uint16_t slots = 32, bool arm = true) : slotsWanted(slots) {
    rx.configure(4u << 20, slots, &hasher);
    if (arm) rx.setPasswordHash(sharef::sha256Hex(PASSWORD).c_str());
    for (int i = 0; i < 32; i++) random[i] = (uint8_t)(0x40 + i);
  }

  void deliver(const std::vector<uint8_t> &packet, Endpoint from = MAC) {
    rx.onPacket(packet.data(), packet.size(), from, now, random);
    drain();
  }

  void drain() {
    Receiver::Outgoing out;
    while (rx.popOutgoing(out)) sent.push_back(out);
  }

  // One loop() pass worth of work, done the way the service does it.
  void pump(int maxItems = 1000) {
    for (int i = 0; i < maxItems; i++) {
      WorkItem w = rx.takeWork(now);
      drain();
      if (w.kind == Work::None) return;
      switch (w.kind) {
        case Work::VerifyAuth: {
          // As stream_update_service.cpp verifyResponse: the cnonce must
          // commit to the image, then ArduinoOTA's PBKDF2 response.
          char seed[160];
          cnonceSeed(seed, sizeof(seed), w.expectedHex, w.nonce);
          if (!sameDigestHex(sharef::sha256Hex(seed).c_str(), w.cnonce)) {
            rx.finishAuth(false, now);
            break;
          }
          const std::string salt = std::string(w.nonce) + ":" + w.cnonce;
          const std::string derived =
              sharef::pbkdf2Hex(rx.passwordHash(), salt, PBKDF2_ITERATIONS);
          const std::string expected = sharef::sha256Hex(
              derived + ":" + w.nonce + ":" + w.cnonce);
          rx.finishAuth(sameDigestHex(expected.c_str(), w.response), now);
          break;
        }
        case Work::Begin:
          flash.begun = true;
          flash.size = w.imageBytes;
          slotMemory.assign((size_t)w.slots * w.slotBytes, 0);
          rx.finishBegin(true, nullptr, slotMemory.data(), w.slots, now);
          break;
        case Work::Write:
          flash.writes++;
          now += 1;  // a flash write is never free
          if (flash.failWrites) {
            rx.finishWrite(w.seq, false, "Flash Write Failed", now);
          } else {
            flash.written.insert(flash.written.end(), w.data, w.data + w.len);
            rx.finishWrite(w.seq, true, nullptr, now);
          }
          break;
        case Work::Activate:
          if (flash.refuseEnd) {
            rx.finishActivate(false, "Could Not Activate The Firmware", now);
          } else {
            flash.activations++;
            rx.finishActivate(true, nullptr, now);
          }
          break;
        case Work::Abort:
          flash.aborts++;
          rx.finishAbort(now);
          break;
        case Work::None:
          break;
      }
      drain();
    }
  }

  bool lastStatus(StatusReply &out) const {
    for (auto it = sent.rbegin(); it != sent.rend(); ++it) {
      if (parseStatus(it->bytes, it->len, out)) return true;
    }
    return false;
  }
  bool lastAck(Ack &out) const {
    for (auto it = sent.rbegin(); it != sent.rend(); ++it) {
      if (parseAck(it->bytes, it->len, out)) return true;
    }
    return false;
  }
  bool challengeNonce(std::string &nonce) const {
    for (auto it = sent.rbegin(); it != sent.rend(); ++it) {
      if (it->len == CHALLENGE_BYTES && memcmp(it->bytes, "EUPC", 4) == 0) {
        nonce.assign((const char *)it->bytes + 12, HEX_DIGEST_CHARS);
        return true;
      }
    }
    return false;
  }
};

static std::vector<uint8_t> makeImage(size_t n, uint32_t seed) {
  std::vector<uint8_t> image(n);
  std::mt19937 rng(seed);
  for (auto &b : image) b = (uint8_t)rng();
  image[0] = 0xE9;  // the app image magic, for realism only
  return image;
}

static std::vector<uint8_t> beginPacket(uint16_t session,
                                        const std::vector<uint8_t> &image,
                                        uint16_t chunk,
                                        const std::vector<uint8_t> *digestOverride =
                                            nullptr) {
  Begin b;
  b.session = session;
  b.imageBytes = (uint32_t)image.size();
  b.chunkBytes = chunk;
  const auto d = digestOverride ? *digestOverride
                                : sharef::digest(image.data(), image.size());
  memcpy(b.sha256, d.data(), SHA256_BYTES);
  std::vector<uint8_t> out(BEGIN_BYTES);
  writeBegin(out.data(), b);
  return out;
}

// The cnonce the Mac sends: sha256hex(imageSha256Hex ":" nonce).
static std::string boundCnonce(const std::vector<uint8_t> &digest,
                               const std::string &nonce) {
  return sharef::sha256Hex(sharef::hex(digest.data(), digest.size()) + ":" + nonce);
}

static std::vector<uint8_t> authPacket(uint16_t session, const std::string &nonce,
                                       const char *password,
                                       const std::string &cnonce) {
  const std::string derived = sharef::pbkdf2Hex(
      sharef::sha256Hex(password), nonce + ":" + cnonce, PBKDF2_ITERATIONS);
  const std::string response =
      sharef::sha256Hex(derived + ":" + nonce + ":" + cnonce);
  std::vector<uint8_t> out(AUTH_BYTES);
  writeAuth(out.data(), session, cnonce.c_str(), response.c_str());
  return out;
}

static std::vector<uint8_t> dataPacket(uint16_t session, uint32_t seq,
                                       const std::vector<uint8_t> &image,
                                       uint16_t chunk) {
  const size_t start = (size_t)seq * chunk;
  const size_t len = std::min<size_t>(chunk, image.size() - start);
  std::vector<uint8_t> out(DATA_HEADER_BYTES + len);
  writeDataHeader(out.data(), session, seq, image.data() + start, len);
  memcpy(out.data() + DATA_HEADER_BYTES, image.data() + start, len);
  return out;
}

// BEGIN, challenge, AUTH, verify, begin: the panel ready for data.
static bool authenticate(Panel &p, uint16_t session,
                         const std::vector<uint8_t> &image, uint16_t chunk,
                         const char *password = PASSWORD,
                         const std::vector<uint8_t> *digestOverride = nullptr) {
  p.deliver(beginPacket(session, image, chunk, digestOverride));
  std::string nonce;
  if (!p.challengeNonce(nonce)) return false;
  const auto digest = digestOverride ? *digestOverride
                                     : sharef::digest(image.data(), image.size());
  p.deliver(authPacket(session, nonce, password, boundCnonce(digest, nonce)));
  p.pump();
  StatusReply st;
  return p.lastStatus(st) && st.code == Status::AuthAccepted;
}

// ---- packets and primitives ---------------------------------------------

static void testPrimitives() {
  check(deviceproto::CAP_STREAM_UPDATE == (1u << 22),
        "the capability bit is the one the Mac reads (1 << 22)");
  const uint8_t ping[] = {'E', 'P', 'N', 'G'};
  const uint8_t info[] = {'E', 'I', 'N', 'F'};
  check(!hasMagic(ping, 4) && !hasMagic(info, 4),
        "no existing packet type is mistaken for an update packet");
  const uint8_t digits[] = "123456789";
  check(crc32(digits, 9) == 0xCBF43926u, "CRC-32 matches the IEEE check value");
  check(sharef::sha256Hex("abc") ==
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        "the reference SHA-256 matches FIPS 180-2 for abc");

  // The challenge composition against Python hashlib's answer for the same
  // inputs. The Mac's EspotaProtocol.authResponse is pinned to these same
  // four values in StreamUpdateProtocolTests.
  const std::string hash = sharef::sha256Hex(PASSWORD);
  check(hash == "9028ea0d15decaa35b2da21c0290af3b1a5ba0a30a591906f89b5074e209ea72",
        "the stored password hash is sha256hex of the password");
  const char nonce[] =
      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa0123456789abcdef0123456789abcdef";
  const std::string cnonce(64, 'f');
  char salt[160];
  check(authSalt(salt, sizeof(salt), nonce, cnonce.c_str()) == 129,
        "the salt is nonce:cnonce");
  const std::string derived = sharef::pbkdf2Hex(hash, salt, PBKDF2_ITERATIONS);
  check(derived == "97b9f1a8e3bcc5fcbcd837fe21e5fa65f27319a89b384596e9eef2e540f7e614",
        "PBKDF2 over the hash hex matches hashlib");
  char challenge[220];
  check(authChallenge(challenge, sizeof(challenge), derived.c_str(), nonce,
                      cnonce.c_str()) == 194,
        "the challenge is derived:nonce:cnonce");
  check(sharef::sha256Hex(challenge) ==
            "12663dc3ba283763d902b9ba5c86360f4f8105f2b5b63684d282cceceb9da29c",
        "the expected response matches hashlib");
  char shortBuf[10];
  check(authSalt(shortBuf, sizeof(shortBuf), nonce, cnonce.c_str()) == 0,
        "a salt buffer too small is refused, not overrun");

  Ack a = {Phase::Receiving, 0x1234, 7, 39, 0x8000000000000005ull, 9999};
  uint8_t buf[ACK_BYTES];
  writeAck(buf, a);
  Ack b;
  check(parseAck(buf, sizeof(buf), b) && b.cumulative == 7 && b.windowEnd == 39 &&
            b.sack == 0x8000000000000005ull && b.bytesWritten == 9999 &&
            b.session == 0x1234,
        "an ack round-trips, all 64 SACK bits included");
  uint8_t st[STATUS_MAX_BYTES];
  const size_t n = writeStatus(st, sizeof(st), Status::ImageRefused, 9, 3,
                               "Could Not Activate The Firmware\n");
  StatusReply r;
  check(parseStatus(st, n, r) && r.code == Status::ImageRefused &&
            strcmp(r.detail, "Could Not Activate The Firmware?") == 0,
        "status detail is carried, with control characters replaced");
  check(!parseStatus(st, n - 1, r), "a truncated status is refused");

  std::vector<uint8_t> auth(AUTH_BYTES);
  const std::string upper(64, 'A');
  writeAuth(auth.data(), 5, upper.c_str(), upper.c_str());
  Auth parsed;
  check(!parseAuth(auth.data(), auth.size(), parsed),
        "an AUTH that is not lowercase hex is refused before any PBKDF2");
}

// ---- auth ---------------------------------------------------------------

static void testUnarmedRefuses() {
  Panel p(32, false);
  const auto image = makeImage(5000, 1);
  p.deliver(beginPacket(7, image, 1024));
  StatusReply st;
  check(p.lastStatus(st) && st.code == Status::NotConfigured,
        "with no password stored, BEGIN is refused as not configured");
  check(p.rx.phase() == Phase::Idle, "and no session exists");
}

static void testDataBeforeAuthIsRefused() {
  Panel p;
  const auto image = makeImage(10 * 1024, 2);
  p.deliver(beginPacket(7, image, 1024));
  check(p.rx.phase() == Phase::AwaitingAuth, "BEGIN opens a session awaiting auth");
  const size_t repliesBefore = p.sent.size();
  for (uint32_t seq = 0; seq < 10; seq++) p.deliver(dataPacket(7, seq, image, 1024));
  p.pump();
  check(p.rx.stats().refusedBeforeAuth == 10,
        "every data chunk before auth is refused");
  check(p.rx.stats().chunksFiled == 0 && p.rx.cumulative() == 0,
        "nothing is buffered before auth");
  check(!p.flash.begun && p.flash.writes == 0, "and nothing reaches flash");
  check(p.sent.size() == repliesBefore, "refused chunks are not acknowledged");
}

static void testWrongPassword() {
  Panel p;
  const auto image = makeImage(10 * 1024, 3);
  check(!authenticate(p, 9, image, 1024, "wrong password!"),
        "a wrong password is not accepted");
  StatusReply st;
  check(p.lastStatus(st) && st.code == Status::AuthRefused &&
            strcmp(st.detail, "Authentication Failed") == 0,
        "the panel answers in ArduinoOTA's own words");
  check(p.rx.phase() == Phase::Idle && p.rx.authFailures() == 1,
        "the session is closed after a refusal");
  p.deliver(dataPacket(9, 0, image, 1024));
  p.pump();
  check(!p.flash.begun && p.rx.stats().chunksFiled == 0,
        "data after a refused password is still refused");
  check(p.lastStatus(st) && st.code == Status::UnknownSession,
        "and the sender is told the session does not exist");
}

static void testLostRefusalIsRepeated() {
  Panel p;
  const auto image = makeImage(4096, 17);
  const auto digest = sharef::digest(image.data(), image.size());
  p.deliver(beginPacket(12, image, 1024));
  std::string nonce;
  p.challengeNonce(nonce);
  const auto wrong = authPacket(12, nonce, "wrong password!", boundCnonce(digest, nonce));
  p.deliver(wrong);
  p.pump();
  p.sent.clear();  // the refusal was lost
  p.deliver(wrong);
  StatusReply st;
  check(p.lastStatus(st) && st.code == Status::AuthRefused,
        "a resent AUTH whose refusal was lost hears the refusal again");
  check(p.rx.authFailures() == 1, "without a second PBKDF2 attempt");
}

static void testCnonceMustCommitToTheImage() {
  // The right password, but a cnonce that does not commit to the image the
  // BEGIN named - an answer borrowed for a different image.
  Panel p;
  const auto image = makeImage(4096, 18);
  p.deliver(beginPacket(13, image, 1024));
  std::string nonce;
  p.challengeNonce(nonce);
  std::vector<uint8_t> otherDigest(32, 0x11);
  p.deliver(authPacket(13, nonce, PASSWORD, boundCnonce(otherDigest, nonce)));
  p.pump();
  StatusReply st;
  check(p.lastStatus(st) && st.code == Status::AuthRefused,
        "an answer bound to another image is refused");
  check(!p.flash.begun, "and nothing begins");
}

static void testAbortDuringBeginReleasesUpdate() {
  // Review finding: an abort that lands while Update.begin runs used to end
  // the session without ever calling Update.abort(), leaving Update open.
  Panel p;
  const auto image = makeImage(4096, 19);
  const auto digest = sharef::digest(image.data(), image.size());
  p.deliver(beginPacket(14, image, 1024));
  std::string nonce;
  p.challengeNonce(nonce);
  p.deliver(authPacket(14, nonce, PASSWORD, boundCnonce(digest, nonce)));
  WorkItem verify = p.rx.takeWork(p.now);
  check(verify.kind == Work::VerifyAuth, "auth is verified first");
  // finish auth the way the pump would
  p.rx.finishAuth(true, p.now);
  WorkItem begin = p.rx.takeWork(p.now);
  check(begin.kind == Work::Begin, "then begin is offered");
  std::vector<uint8_t> abort(ABORT_BYTES);
  writeAbort(abort.data(), 14);
  p.deliver(abort);  // arrives while Update.begin is running
  p.slotMemory.assign((size_t)begin.slots * begin.slotBytes, 0);
  p.rx.finishBegin(true, nullptr, p.slotMemory.data(), begin.slots, p.now);
  WorkItem next = p.rx.takeWork(p.now);
  check(next.kind == Work::Abort,
        "an Update.begin that succeeded after the abort is released");
  p.rx.finishAbort(p.now);
  check(!p.rx.ownsPanel() && !p.rx.usingSlots(), "and the panel is free again");
}

static void testFullWindowIsAckedAtOnce() {
  // Review finding: with loop() inside a block erase, the last chunks that
  // filled the window waited for the next batch to be acknowledged.
  Panel p(5);
  const auto image = makeImage(20 * 1024, 20);
  authenticate(p, 15, image, 1024);
  for (uint32_t seq = 0; seq < 4; seq++) p.deliver(dataPacket(15, seq, image, 1024));
  p.sent.clear();
  p.deliver(dataPacket(15, 4, image, 1024));  // the fifth fills the window
  Ack ack;
  check(p.lastAck(ack) && ack.cumulative == 5,
        "the chunk that fills the window is acknowledged without waiting on loop()");
}

static void testNewerReceiveTimestampIsNotSilence() {
  // Hardware finding (4C, 2026-10-10): both WiFi attempts ended "the sender
  // went silent" 4.9 s and 0.8 s in, mid-stream. loop() samples millis()
  // before taking the lock; the receive task, meanwhile, files a chunk
  // stamped a few ms LATER. now - lastHeard then wraps to ~4.29e9 and the
  // 10 s idle timeout fires on a sender that is flooding the panel.
  Panel p;
  const auto image = makeImage(20 * 1024, 21);
  check(authenticate(p, 16, image, 1024), "auth for the clock-race run");
  const uint32_t loopSampledAt = p.now;
  p.now += 3;  // the receive task runs between the sample and the lock
  p.deliver(dataPacket(16, 0, image, 1024));
  WorkItem w = p.rx.takeWork(loopSampledAt);
  StatusReply st;
  const bool aborted = p.lastStatus(st) && st.code == Status::Aborted;
  check(!aborted && p.rx.phase() == Phase::Receiving,
        "a chunk stamped after loop() sampled its clock is not a silent sender");
  check(w.kind == Work::Write, "and the chunk is offered for writing");
  // Real silence still times out, measured from the last chunk.
  if (w.kind == Work::Write) p.rx.finishWrite(w.seq, true, nullptr, p.now);
  p.now += SESSION_IDLE_TIMEOUT_MS + 1;
  p.pump();
  check(p.lastStatus(st) && st.code == Status::Aborted,
        "ten seconds of real silence still aborts");
}

static void testOldStampsStillReadAsOld() {
  // Review finding on the clock fix: an unbounded clamp read any stamp more
  // than 2^31 ms old as "0 ms ago", which silenced the rate-limited replies
  // on a panel up for more than 24.8 days. Only a short skew is clamped now.
  check(elapsedMs(1000, 1003) == 0, "a few ms of backward skew reads as 0");
  check(elapsedMs(1000, 400) == 600, "ordinary elapsed time is unchanged");
  check(elapsedMs(5, 0xFFFFFFF0u) == 21, "the 49-day rollover still counts forward");
  const uint32_t ancient = 1000u + 0x80000000u + 5u;
  check(elapsedMs(ancient, 1000) > 0x80000000u,
        "a stamp more than 24.8 days old reads as long ago, not as 0");
  Panel p;
  const auto image = makeImage(4096, 22);
  p.now = ancient;  // nothing repeated since boot, 24.8+ days ago
  p.deliver(dataPacket(77, 0, image, 1024));
  StatusReply st;
  check(p.lastStatus(st) && st.code == Status::UnknownSession,
        "an unknown session is still told so on a panel up for 25 days");
}

static void testRetransmittedBeginKeepsNonce() {
  Panel p;
  const auto image = makeImage(4096, 4);
  p.deliver(beginPacket(11, image, 1024));
  std::string first, second;
  p.challengeNonce(first);
  p.random[0] ^= 0xFF;  // a new BEGIN would get a different nonce
  p.deliver(beginPacket(11, image, 1024));
  p.challengeNonce(second);
  check(!first.empty() && first == second,
        "a repeated BEGIN gets the same challenge, so an AUTH in flight stays valid");
}

// ---- transfer -----------------------------------------------------------

static void testInOrderTransfer() {
  Panel p;
  const auto image = makeImage(100 * 1024 + 77, 5);
  const uint16_t chunk = MAX_CHUNK_BYTES;
  check(authenticate(p, 21, image, chunk), "the right password is accepted");
  check(p.flash.begun && p.flash.size == image.size(),
        "Update.begin gets the exact image size");
  const uint32_t chunks = (uint32_t)((image.size() + chunk - 1) / chunk);
  uint32_t next = 0;
  for (int round = 0; next < chunks && round < 1000; round++) {
    Ack ack;
    uint32_t limit = p.lastAck(ack) ? ack.windowEnd : p.slotsWanted;
    while (next < chunks && next < limit) p.deliver(dataPacket(21, next++, image, chunk));
    p.pump();
  }
  p.pump();
  check(p.flash.written == image, "flash holds the image byte for byte");
  check(p.flash.writes == (int)chunks, "each chunk is written once");
  check(p.rx.digestMatched() && p.flash.activations == 1 && p.flash.aborts == 0,
        "a matching SHA-256 activates exactly once");
  StatusReply st;
  check(p.lastStatus(st) && st.code == Status::Activated &&
            st.value == image.size(),
        "the sender is told the update activated");
  check(!p.rx.rebootDue(p.now), "the restart waits for the verdict to leave");
  p.now += REBOOT_DELAY_MS;
  check(p.rx.rebootDue(p.now), "then the panel restarts");
}

// A sender that keeps a window full and retransmits from the acks, over a
// link that drops, duplicates and reorders. What a real network does to the
// Mac's StreamUpdateWindow, reduced to the receiver's view of it.
struct LossyRun {
  int delivered = 0;
  int dropped = 0;
  int duplicated = 0;
  int reordered = 0;
};

static LossyRun runLossy(Panel &p, uint16_t session,
                         const std::vector<uint8_t> &image, uint16_t chunk,
                         uint32_t seed, int dropPct, int dupPct, int reorderPct) {
  LossyRun run;
  // A receiver that never acknowledges must fail the run, not spin it.
  if (!p.rx.authAccepted()) return run;
  std::mt19937 rng(seed);
  const uint32_t chunks = (uint32_t)((image.size() + chunk - 1) / chunk);
  std::vector<bool> acked(chunks, false);
  std::deque<std::vector<uint8_t>> wire;
  uint32_t windowEnd = p.slotsWanted;
  for (int round = 0; round < 400; round++) {
    Ack ack;
    if (p.lastAck(ack) && ack.session == session) {
      windowEnd = ack.windowEnd;
      for (uint32_t s = 0; s < ack.cumulative && s < chunks; s++) acked[s] = true;
      for (uint32_t i = 0; i < SACK_BITS; i++) {
        if (ack.sack & (1ull << i)) {
          const uint32_t s = ack.cumulative + 1 + i;
          if (s < chunks) acked[s] = true;
        }
      }
    }
    bool all = true;
    for (uint32_t s = 0; s < chunks; s++) {
      if (acked[s]) continue;
      all = false;
      if (s >= windowEnd) break;
      auto packet = dataPacket(session, s, image, chunk);
      if ((int)(rng() % 100) < dropPct) {
        run.dropped++;
        continue;
      }
      wire.push_back(packet);
      if ((int)(rng() % 100) < dupPct) {
        wire.push_back(packet);
        run.duplicated++;
      }
    }
    if (all) break;
    // Reorder: swap random neighbours before delivery.
    for (size_t i = 1; i < wire.size(); i++) {
      if ((int)(rng() % 100) < reorderPct) {
        std::swap(wire[i - 1], wire[i]);
        run.reordered++;
      }
    }
    while (!wire.empty()) {
      p.deliver(wire.front());
      wire.pop_front();
      run.delivered++;
      p.now += 1;
    }
    p.pump(3);  // flash slower than the link: the window does the waiting
  }
  p.pump();
  return run;
}

static void testLossDuplicationReordering() {
  for (uint32_t seed = 1; seed <= 4; seed++) {
    Panel p(24);
    const auto image = makeImage(200 * 1024 + 3, 100 + seed);
    check(authenticate(p, (uint16_t)(30 + seed), image, MAX_CHUNK_BYTES),
          "auth before the lossy run");
    const LossyRun run =
        runLossy(p, (uint16_t)(30 + seed), image, MAX_CHUNK_BYTES, seed, 15, 10, 20);
    char msg[160];
    std::snprintf(msg, sizeof(msg),
                  "seed %u: 15%% loss, 10%% duplication, 20%% reordering "
                  "still writes the exact image (dropped %d dup %d reorder %d)",
                  seed, run.dropped, run.duplicated, run.reordered);
    check(p.flash.written == image, msg);
    check(p.flash.writes == (int)((image.size() + MAX_CHUNK_BYTES - 1) / MAX_CHUNK_BYTES),
          "every chunk reaches flash exactly once despite duplicates");
    check(p.rx.stats().duplicates > 0 && p.rx.stats().outOfOrder > 0,
          "the run really exercised duplicates and holes");
    check(p.flash.activations == 1, "and the image activates");
  }
}

static void testSelectiveAck() {
  Panel p(16);
  const auto image = makeImage(20 * 1024, 6);
  authenticate(p, 40, image, 1024);
  p.deliver(dataPacket(40, 0, image, 1024));
  p.deliver(dataPacket(40, 2, image, 1024));
  p.deliver(dataPacket(40, 5, image, 1024));
  Ack ack;
  check(p.lastAck(ack), "a hole is acknowledged at once");
  check(ack.cumulative == 1, "the cumulative ack stops at the first hole");
  check(ack.sack == ((1ull << 0) | (1ull << 3)),
        "the selective bits name 2 and 5 relative to the hole at 1");
  p.deliver(dataPacket(40, 1, image, 1024));
  check(p.lastAck(ack) && ack.cumulative == 3 && ack.sack == (1ull << 1),
        "filling the hole moves the cumulative ack past what was buffered");
  p.deliver(dataPacket(40, 2, image, 1024));
  check(p.rx.stats().duplicates == 1, "a duplicate is counted, not filed again");
  p.deliver(dataPacket(40, 16, image, 1024));
  check(p.rx.stats().outsideWindow == 1,
        "a chunk past the advertised window is refused");
  check(p.lastAck(ack) && ack.windowEnd == 16,
        "and the ack restates the window: writeBase + slots");
  p.pump();
  p.now += ACK_WINDOW_BATCH_MS;
  p.pump();
  check(p.lastAck(ack) && ack.windowEnd == 16 + 3,
        "writing slots to flash opens the window by as many, batched");
}

static void testCorruptAndShortChunks() {
  Panel p;
  const auto image = makeImage(8 * 1024, 7);
  authenticate(p, 50, image, 1024);
  auto bad = dataPacket(50, 0, image, 1024);
  bad[DATA_HEADER_BYTES + 100] ^= 0x01;
  p.deliver(bad);
  check(p.rx.stats().badChunks == 1 && p.rx.cumulative() == 0,
        "a chunk whose CRC does not match is dropped, not filed");
  auto shortChunk = dataPacket(50, 0, image, 1024);
  shortChunk.resize(shortChunk.size() - 1);
  p.deliver(shortChunk);
  check(p.rx.stats().badChunks == 2 && p.rx.cumulative() == 0,
        "a chunk of the wrong length is dropped too");
  p.deliver(dataPacket(50, 0, image, 1024), OTHER);
  check(p.rx.stats().foreign == 1 && p.rx.cumulative() == 0,
        "the right session from another endpoint is refused");
  p.deliver(dataPacket(50, 0, image, 1024));
  check(p.rx.cumulative() == 1, "the good resend is accepted");
}

static void testBadHashNeverActivates() {
  Panel p;
  const auto image = makeImage(30 * 1024, 8);
  std::vector<uint8_t> wrong = sharef::digest(image.data(), image.size());
  wrong[31] ^= 0x80;
  check(authenticate(p, 60, image, 1024, PASSWORD, &wrong), "auth for the bad-hash run");
  runLossy(p, 60, image, 1024, 9, 0, 0, 0);
  check(p.flash.written == image, "every byte was written");
  check(!p.rx.digestMatched(), "the digest is judged a mismatch");
  check(p.flash.activations == 0, "Update.end is never called on a mismatch");
  check(p.flash.aborts == 1, "the update is aborted instead");
  StatusReply st;
  check(p.lastStatus(st) && st.code == Status::HashMismatch,
        "and the sender is told why");
  check(!p.rx.rebootDue(p.now + 60000) && !p.rx.ownsPanel(),
        "no restart; the panel goes back to streaming");
}

static void testCorruptionInsideCrcStillCaught() {
  // A chunk that is wrong but carries a CRC computed over the wrong bytes -
  // corruption before the sender framed it - passes the per-chunk check.
  // The whole-image SHA-256 is what stops it.
  Panel p;
  const auto image = makeImage(12 * 1024, 10);
  authenticate(p, 61, image, 1024);
  for (uint32_t seq = 0; seq < 12; seq++) {
    auto packet = dataPacket(61, seq, image, 1024);
    if (seq == 5) {
      packet[DATA_HEADER_BYTES + 3] ^= 0x10;
      writeU32(packet.data() + 12,
               crc32(packet.data() + DATA_HEADER_BYTES, 1024));
    }
    p.deliver(packet);
    p.pump();
  }
  p.pump();
  check(p.flash.activations == 0 && p.flash.aborts == 1,
        "a self-consistent bad chunk is caught by the image hash");
}

static void testWriteFailure() {
  Panel p;
  const auto image = makeImage(6 * 1024, 11);
  authenticate(p, 62, image, 1024);
  p.flash.failWrites = true;
  p.deliver(dataPacket(62, 0, image, 1024));
  p.pump();
  StatusReply st;
  check(p.lastStatus(st) && st.code == Status::WriteFailed &&
            strcmp(st.detail, "Flash Write Failed") == 0,
        "a failed flash write is reported with Update's words");
  check(p.flash.aborts == 1 && p.flash.activations == 0,
        "and aborts without activating");
}

static void testImageRefused() {
  Panel p;
  const auto image = makeImage(3 * 1024, 12);
  authenticate(p, 63, image, 1024);
  p.flash.refuseEnd = true;
  for (uint32_t seq = 0; seq < 3; seq++) p.deliver(dataPacket(63, seq, image, 1024));
  p.pump();
  StatusReply st;
  check(p.lastStatus(st) && st.code == Status::ImageRefused &&
            strcmp(st.detail, "Could Not Activate The Firmware") == 0,
        "Update.end refusing the image is reported verbatim");
  check(!p.rx.rebootDue(p.now + 60000), "and the panel does not restart");
}

static void testAbortAndTimeout() {
  {
    Panel p;
    const auto image = makeImage(20 * 1024, 13);
    authenticate(p, 70, image, 1024);
    for (uint32_t seq = 0; seq < 5; seq++) p.deliver(dataPacket(70, seq, image, 1024));
    std::vector<uint8_t> abort(ABORT_BYTES);
    writeAbort(abort.data(), 70);
    p.deliver(abort, OTHER);
    check(p.rx.phase() == Phase::Receiving, "an abort from another endpoint is ignored");
    p.deliver(abort);
    p.pump();
    StatusReply st;
    check(p.lastStatus(st) && st.code == Status::Aborted, "the sender can abort");
    check(p.flash.aborts == 1 && p.flash.activations == 0,
          "an abort releases Update and never activates");
  }
  {
    Panel p;
    const auto image = makeImage(20 * 1024, 14);
    authenticate(p, 71, image, 1024);
    p.deliver(dataPacket(71, 0, image, 1024));
    p.pump();
    p.now += SESSION_IDLE_TIMEOUT_MS + 1;
    p.pump();
    StatusReply st;
    check(p.lastStatus(st) && st.code == Status::Aborted &&
              p.flash.aborts == 1 && p.flash.activations == 0,
          "a sender that goes silent is timed out and the update aborted");
    check(!p.rx.ownsPanel(), "and the panel is released");
  }
}

static void testBusy() {
  Panel p;
  const auto image = makeImage(10 * 1024, 15);
  authenticate(p, 80, image, 1024);
  p.deliver(beginPacket(81, image, 1024), OTHER);
  StatusReply st;
  check(p.lastStatus(st) && st.code == Status::Busy && st.session == 81,
        "a second sender is told another update is in progress");
  check(p.rx.session() == 80 && p.rx.phase() == Phase::Receiving,
        "and the running update is untouched");
}

static void testLostVerdictIsRepeated() {
  Panel p;
  const auto image = makeImage(2 * 1024, 16);
  authenticate(p, 90, image, 1024);
  p.deliver(dataPacket(90, 0, image, 1024));
  p.deliver(dataPacket(90, 1, image, 1024));
  p.pump();
  p.sent.clear();
  p.now += REPEAT_STATUS_MS;
  p.deliver(dataPacket(90, 1, image, 1024));
  StatusReply st;
  check(p.lastStatus(st) && st.code == Status::Activated,
        "a duplicate after the end gets the verdict again");
}

int main() {
  testPrimitives();
  testUnarmedRefuses();
  testDataBeforeAuthIsRefused();
  testWrongPassword();
  testRetransmittedBeginKeepsNonce();
  testNewerReceiveTimestampIsNotSilence();
  testOldStampsStillReadAsOld();
  testLostRefusalIsRepeated();
  testCnonceMustCommitToTheImage();
  testAbortDuringBeginReleasesUpdate();
  testFullWindowIsAckedAtOnce();
  testInOrderTransfer();
  testLossDuplicationReordering();
  testSelectiveAck();
  testCorruptAndShortChunks();
  testBadHashNeverActivates();
  testCorruptionInsideCrcStillCaught();
  testWriteFailure();
  testImageRefused();
  testAbortAndTimeout();
  testBusy();
  testLostVerdictIsRepeated();
  if (failures != 0) {
    std::printf("test_stream_update: %d failure(s)\n", failures);
    return 1;
  }
  std::printf("test_stream_update: all checks passed\n");
  return 0;
}
