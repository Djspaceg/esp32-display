// C-compatible stand-in: capability-tagged allocation is plain calloc/free on
// the host, so AddressSanitizer sees every Doom sound allocation.
#pragma once

#include <stdlib.h>

#define MALLOC_CAP_INTERNAL (1u << 11)
#define MALLOC_CAP_8BIT (1u << 2)

static inline void *heap_caps_calloc(size_t n, size_t size, unsigned caps) {
    (void)caps;
    return calloc(n, size);
}

static inline void heap_caps_free(void *ptr) { free(ptr); }
