#pragma once

#include <stddef.h>
#include <stdlib.h>

static constexpr unsigned MALLOC_CAP_INTERNAL = 1u << 0;
static constexpr unsigned MALLOC_CAP_8BIT = 1u << 1;

inline void *heap_caps_malloc(size_t bytes, unsigned) {
  return malloc(bytes);
}

inline void heap_caps_free(void *allocation) {
  free(allocation);
}

inline size_t heap_caps_get_free_size(unsigned) { return 123456; }
