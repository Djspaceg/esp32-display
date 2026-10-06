// The 5 s "mem" diagnostic line: internal and DMA heap, allocation failures,
// the age of the last answered WiFi RPC, and audio uplink errors. Printed as
// its own line right after the status line, which stays byte-for-byte as it
// was so the app's and the tools' parsers are untouched.
//
// Hardware-free and unit tested on the host (firmware/test/
// test_mem_report.cpp); mem_diag.cpp fills the sample on the device.
#pragma once

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

namespace memreport {

struct Sample {
  uint32_t internalFree = 0;      // ifree: heap_caps_get_free_size(INTERNAL)
  uint32_t internalMinFree = 0;   // imin: lowest internal free since boot
  uint32_t dmaFree = 0;           // dma: free DMA-capable internal heap
  uint32_t dmaMinFree = 0;        // dmamin: its lowest since boot
  uint32_t dmaLargestBlock = 0;   // dmablk: largest free DMA block
  // afail/afsz/afcaps count failures from memdiag::begin() on, not earlier
  // static constructors. A plain malloc() reports MALLOC_CAP_DEFAULT
  // (0x1000), not the pool it tried. On dual-core chips two simultaneous
  // failures can lose a count or tear size from caps.
  uint32_t allocFailures = 0;     // afail: failed allocations since begin()
  uint32_t lastFailedSize = 0;    // afsz: size of the last one
  uint32_t lastFailedCaps = 0;    // afcaps: its heap caps (hex)
  int32_t rpcAgeMs = -1;          // rpcage: -1 without a hosted link
  uint32_t uplinkErrors = 0;      // aupErr: audio uplink send failures
};

// Writes the line without a newline; returns what snprintf returns.
inline int formatLine(char *out, size_t len, const Sample &s) {
  return snprintf(out, len,
                  "mem ifree=%lu imin=%lu dma=%lu dmamin=%lu dmablk=%lu "
                  "afail=%lu afsz=%lu afcaps=0x%lx rpcage=%ld aupErr=%lu",
                  (unsigned long)s.internalFree,
                  (unsigned long)s.internalMinFree, (unsigned long)s.dmaFree,
                  (unsigned long)s.dmaMinFree,
                  (unsigned long)s.dmaLargestBlock,
                  (unsigned long)s.allocFailures,
                  (unsigned long)s.lastFailedSize,
                  (unsigned long)s.lastFailedCaps, (long)s.rpcAgeMs,
                  (unsigned long)s.uplinkErrors);
}

}  // namespace memreport
