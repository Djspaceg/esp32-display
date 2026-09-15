#pragma once

inline bool esp_ptr_external_ram(const void *) { return false; }
inline bool esp_ptr_internal(const void *) { return true; }
