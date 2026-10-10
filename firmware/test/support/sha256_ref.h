// Reference SHA-256, HMAC-SHA256 and PBKDF2-HMAC-SHA256 for host tests only.
// The panel uses mbedtls and the core's Hash library; these exist so a test
// can compute the same digests the panel and the Mac do and check the
// receiver's decisions against real ones. Checked against hashlib vectors in
// test_stream_update.cpp.
#pragma once

#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include <string>
#include <vector>

namespace sharef {

class Sha256 {
 public:
  Sha256() { reset(); }
  void reset() {
    static const uint32_t init[8] = {0x6a09e667, 0xbb67ae85, 0x3c6ef372,
                                     0xa54ff53a, 0x510e527f, 0x9b05688c,
                                     0x1f83d9ab, 0x5be0cd19};
    memcpy(h_, init, sizeof(h_));
    len_ = 0;
    used_ = 0;
  }
  void update(const uint8_t *data, size_t len) {
    for (size_t i = 0; i < len; i++) {
      buf_[used_++] = data[i];
      if (used_ == 64) {
        block(buf_);
        used_ = 0;
      }
    }
    len_ += len;
  }
  void finish(uint8_t out[32]) {
    const uint64_t bits = len_ * 8;
    const uint8_t pad = 0x80;
    update(&pad, 1);
    const uint8_t zero = 0;
    while (used_ != 56) update(&zero, 1);
    uint8_t lenBytes[8];
    for (int i = 0; i < 8; i++) lenBytes[i] = (uint8_t)(bits >> (56 - 8 * i));
    update(lenBytes, 8);
    for (int i = 0; i < 8; i++) {
      out[4 * i] = (uint8_t)(h_[i] >> 24);
      out[4 * i + 1] = (uint8_t)(h_[i] >> 16);
      out[4 * i + 2] = (uint8_t)(h_[i] >> 8);
      out[4 * i + 3] = (uint8_t)h_[i];
    }
  }

 private:
  static uint32_t rotr(uint32_t x, int n) { return (x >> n) | (x << (32 - n)); }
  void block(const uint8_t *p) {
    static const uint32_t k[64] = {
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
        0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
        0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
        0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
        0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
        0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
        0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
        0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
        0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2};
    uint32_t w[64];
    for (int i = 0; i < 16; i++) {
      w[i] = ((uint32_t)p[4 * i] << 24) | ((uint32_t)p[4 * i + 1] << 16) |
             ((uint32_t)p[4 * i + 2] << 8) | (uint32_t)p[4 * i + 3];
    }
    for (int i = 16; i < 64; i++) {
      const uint32_t s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
      const uint32_t s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
      w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }
    uint32_t a = h_[0], b = h_[1], c = h_[2], d = h_[3], e = h_[4], f = h_[5],
             g = h_[6], h = h_[7];
    for (int i = 0; i < 64; i++) {
      const uint32_t s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
      const uint32_t ch = (e & f) ^ (~e & g);
      const uint32_t t1 = h + s1 + ch + k[i] + w[i];
      const uint32_t s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
      const uint32_t maj = (a & b) ^ (a & c) ^ (b & c);
      const uint32_t t2 = s0 + maj;
      h = g;
      g = f;
      f = e;
      e = d + t1;
      d = c;
      c = b;
      b = a;
      a = t1 + t2;
    }
    h_[0] += a; h_[1] += b; h_[2] += c; h_[3] += d;
    h_[4] += e; h_[5] += f; h_[6] += g; h_[7] += h;
  }

  uint32_t h_[8];
  uint64_t len_;
  uint8_t buf_[64];
  size_t used_;
};

inline std::string hex(const uint8_t *bytes, size_t len) {
  static const char digits[] = "0123456789abcdef";
  std::string out;
  for (size_t i = 0; i < len; i++) {
    out += digits[bytes[i] >> 4];
    out += digits[bytes[i] & 15];
  }
  return out;
}

inline std::vector<uint8_t> digest(const uint8_t *data, size_t len) {
  Sha256 s;
  s.update(data, len);
  std::vector<uint8_t> out(32);
  s.finish(out.data());
  return out;
}

inline std::string sha256Hex(const std::string &text) {
  const auto d = digest((const uint8_t *)text.data(), text.size());
  return hex(d.data(), d.size());
}

inline void hmac(const uint8_t *key, size_t keyLen, const uint8_t *data,
                 size_t dataLen, uint8_t out[32]) {
  uint8_t k[64] = {};
  if (keyLen > 64) {
    const auto d = digest(key, keyLen);
    memcpy(k, d.data(), 32);
  } else {
    memcpy(k, key, keyLen);
  }
  uint8_t ipad[64], opad[64];
  for (int i = 0; i < 64; i++) {
    ipad[i] = k[i] ^ 0x36;
    opad[i] = k[i] ^ 0x5c;
  }
  Sha256 inner;
  inner.update(ipad, 64);
  inner.update(data, dataLen);
  uint8_t innerOut[32];
  inner.finish(innerOut);
  Sha256 outer;
  outer.update(opad, 64);
  outer.update(innerOut, 32);
  outer.finish(out);
}

/// One 32-byte block of PBKDF2-HMAC-SHA256, which is all a 32-byte key needs.
inline std::string pbkdf2Hex(const std::string &password,
                             const std::string &salt, uint32_t iterations) {
  std::vector<uint8_t> s(salt.begin(), salt.end());
  s.push_back(0);
  s.push_back(0);
  s.push_back(0);
  s.push_back(1);
  uint8_t u[32], t[32];
  hmac((const uint8_t *)password.data(), password.size(), s.data(), s.size(), u);
  memcpy(t, u, 32);
  for (uint32_t i = 1; i < iterations; i++) {
    hmac((const uint8_t *)password.data(), password.size(), u, 32, u);
    for (int j = 0; j < 32; j++) t[j] ^= u[j];
  }
  return hex(t, 32);
}

}  // namespace sharef
