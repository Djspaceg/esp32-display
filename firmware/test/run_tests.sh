#!/bin/zsh
# Compile and run the firmware's host-side protocol tests.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
OUT="$TMP/test_band_protocol"
AUDIO_OUT="$TMP/test_audio"
STAGING_OUT="$TMP/test_panel_transfer_staging"
STALL_OUT="$TMP/test_panel_transfer_stall_recovery"
RESCUE_OUT="$TMP/test_rescue_model"
CXXFLAGS=(
  -std=c++17 -Wall -Wextra -Werror
  -fsanitize=address,undefined -fno-sanitize-recover=all
)
# Address + UB sanitizers, non-recovering: the suite feeds hostile inputs to
# parsers that run on the panel's network path (the RLE decoder above all),
# and a bounds fault that happens not to change the return value would
# otherwise pass. On the host this costs milliseconds and turns every stray
# read or write in a test into a hard failure.
clang++ "${CXXFLAGS[@]}" \
  -o "$OUT" "$HERE/test_band_protocol.cpp"
"$OUT"

clang++ "${CXXFLAGS[@]}" \
  -DCONFIG_IDF_TARGET_ESP32S3 \
  -DESPDISP_HOST_AUDIO_TEST \
  -I"$HERE/fakes/audio" \
  -I"$HERE/../libraries/espdisp_board/src" \
  -o "$AUDIO_OUT" \
  "$HERE/test_audio.cpp" \
  "$HERE/fakes/audio/audio_host_fakes.cpp" \
  "$HERE/../display_stream/audio_transport.cpp" \
  "$HERE/../display_stream/audio_engine.cpp" \
  "$HERE/../display_stream/audio_backend.cpp" \
  "$HERE/../display_stream/audio_test.cpp" \
  "$HERE/../display_stream/net_link.cpp" \
  "$HERE/../display_stream/telemetry.cpp" \
  "$HERE/../display_stream/mdns_announce.cpp"
"$AUDIO_OUT"

clang++ "${CXXFLAGS[@]}" \
  -DCONFIG_IDF_TARGET_ESP32S3 \
  -DESPDISP_HOST_PANEL_TRANSFER_TEST \
  -I"$HERE/fakes/panel_transfer" \
  -I"$HERE/../libraries/espdisp_board/src" \
  -o "$STAGING_OUT" \
  "$HERE/test_panel_transfer_staging.cpp" \
  "$HERE/../display_stream/dma_gate.cpp" \
  "$HERE/../display_stream/panel_transfer.cpp"
"$STAGING_OUT"

# Recovery side of the same accounting: once a wait has timed out, can the
# system ever draw again, and can a shared completion callback release a slot
# hardware still owns?
clang++ "${CXXFLAGS[@]}" \
  -DCONFIG_IDF_TARGET_ESP32S3 \
  -DESPDISP_HOST_PANEL_TRANSFER_TEST \
  -I"$HERE/fakes/panel_transfer" \
  -I"$HERE/../libraries/espdisp_board/src" \
  -o "$STALL_OUT" \
  "$HERE/test_panel_transfer_stall_recovery.cpp" \
  "$HERE/../display_stream/dma_gate.cpp" \
  "$HERE/../display_stream/panel_transfer.cpp"
"$STALL_OUT"

# The rescue image's USB-pin guard and screen layout, for every board profile.
clang++ "${CXXFLAGS[@]}" \
  -I"$HERE/../libraries/espdisp_board/src" \
  -o "$RESCUE_OUT" "$HERE/test_rescue_model.cpp"
"$RESCUE_OUT"

bash "$HERE/../../mac/ESPDisplaySender/Tests/SenderAudioRTHostTests/run_tests.sh"
