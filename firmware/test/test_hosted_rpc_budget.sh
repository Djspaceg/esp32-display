#!/bin/zsh
# The P4 hosted-RPC watchdog reboot: loopTask never waits on a WiFi RPC.
# Run by run_tests.sh.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
OUT="$TMP/test_hosted_rpc_budget"
clang++ -std=c++17 -Wall -Wextra -Werror \
  -fsanitize=address,undefined -fno-sanitize-recover=all \
  -DCONFIG_IDF_TARGET_ESP32S3 \
  -DESPDISP_HOST_AUDIO_TEST \
  -I"$HERE/fakes/audio" \
  -I"$HERE/../libraries/espdisp_board/src" \
  -o "$OUT" \
  "$HERE/test_hosted_rpc_budget.cpp" \
  "$HERE/fakes/audio/audio_host_fakes.cpp" \
  "$HERE/../display_stream/audio_transport.cpp" \
  "$HERE/../display_stream/audio_engine.cpp" \
  "$HERE/../display_stream/audio_backend.cpp" \
  "$HERE/../display_stream/audio_test.cpp" \
  "$HERE/../display_stream/net_link.cpp" \
  "$HERE/../display_stream/telemetry.cpp" \
  "$HERE/../display_stream/mdns_announce.cpp" \
  "$HERE/../display_stream/wifi_worker.cpp"
"$OUT"
