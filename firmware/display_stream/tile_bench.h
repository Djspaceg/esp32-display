// CFGBENCH: on-target tile-stream microbenchmarks (S3 only), feeding
// docs/tile-stream-plan.md's budget math.
#pragma once

#if defined(CONFIG_IDF_TARGET_ESP32S3)
void runTileBench();
#endif
