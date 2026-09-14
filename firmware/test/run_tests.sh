#!/bin/zsh
# Compile and run the firmware's host-side protocol tests.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
OUT="$TMP/test_band_protocol"
STAGING_OUT="$TMP/test_panel_transfer_staging"
# Address + UB sanitizers, non-recovering: the suite feeds hostile inputs to
# parsers that run on the panel's network path (the RLE decoder above all),
# and a bounds fault that happens not to change the return value would
# otherwise pass. On the host this costs milliseconds and turns every stray
# read or write in a test into a hard failure.
clang++ -std=c++17 -Wall -Wextra -Werror \
  -fsanitize=address,undefined -fno-sanitize-recover=all \
  -o "$OUT" "$HERE/test_band_protocol.cpp"
"$OUT"

clang++ -std=c++17 -Wall -Wextra -Werror \
  -fsanitize=address,undefined -fno-sanitize-recover=all \
  -DCONFIG_IDF_TARGET_ESP32S3 \
  -DESPDISP_HOST_PANEL_TRANSFER_TEST \
  -I"$HERE/fakes/panel_transfer" \
  -I"$HERE/../libraries/espdisp_board/src" \
  -o "$STAGING_OUT" \
  "$HERE/test_panel_transfer_staging.cpp" \
  "$HERE/../display_stream/dma_gate.cpp" \
  "$HERE/../display_stream/panel_transfer.cpp"
"$STAGING_OUT"
