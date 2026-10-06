#!/bin/zsh
# Compile and run the firmware's host-side protocol tests.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
OUT="$TMP/test_band_protocol"
AUDIO_OUT="$TMP/test_audio"
SEAM_OUT="$TMP/test_audio_identity_seam"
STAGING_OUT="$TMP/test_panel_transfer_staging"
STALL_OUT="$TMP/test_panel_transfer_stall_recovery"
RESCUE_OUT="$TMP/test_rescue_model"
DOOM_ENTRY_OUT="$TMP/test_doom_entry_gate"
DOOM_WAD_OUT="$TMP/test_doom_wad"
DOOM_FAILURE_OUT="$TMP/test_doom_failure_screen"
MEM_REPORT_OUT="$TMP/test_mem_report"
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
  "$HERE/../display_stream/mdns_announce.cpp" \
  "$HERE/../display_stream/wifi_worker.cpp"
"$AUDIO_OUT"

# The start gate at runtime, through the backend API alone: an impostor that
# acknowledges at the codec addresses gets no clocks and no amplifier.
clang++ "${CXXFLAGS[@]}" \
  -DCONFIG_IDF_TARGET_ESP32S3 \
  -DESPDISP_HOST_AUDIO_TEST \
  -I"$HERE/fakes/audio" \
  -I"$HERE/../libraries/espdisp_board/src" \
  -o "$SEAM_OUT" \
  "$HERE/test_audio_identity_seam.cpp" \
  "$HERE/fakes/audio/audio_host_fakes.cpp" \
  "$HERE/../display_stream/audio_transport.cpp" \
  "$HERE/../display_stream/audio_engine.cpp" \
  "$HERE/../display_stream/audio_backend.cpp" \
  "$HERE/../display_stream/audio_test.cpp" \
  "$HERE/../display_stream/net_link.cpp" \
  "$HERE/../display_stream/telemetry.cpp" \
  "$HERE/../display_stream/mdns_announce.cpp" \
  "$HERE/../display_stream/wifi_worker.cpp"
"$SEAM_OUT"

# loopTask never waits on a hosted WiFi RPC (the P4 watchdog reboot).
zsh "$HERE/test_hosted_rpc_budget.sh"

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

# The BOOT triple press refuses Doom, without rebooting, on a board whose WAD
# the Doom boot would refuse, and otherwise reopens the boot-mode menu; the menu
# defaults to streaming and hands Doom its one-shot flag (input_button.cpp and
# boot_menu.cpp, unmodified, against fakes).
clang++ "${CXXFLAGS[@]}" \
  -DCONFIG_IDF_TARGET_ESP32P4 -DESPDISP_BOARD_P4_4B -DESPDISP_DOOM_RUNTIME \
  -I"$HERE/fakes/doom_entry" \
  -I"$HERE/../libraries/espdisp_board/src" \
  -I"$HERE/../doom/src" \
  -o "$DOOM_ENTRY_OUT" \
  "$HERE/test_doom_entry_gate.cpp" \
  "$HERE/../display_stream/input_button.cpp" \
  "$HERE/../display_stream/boot_menu.cpp"
"$DOOM_ENTRY_OUT"

# The WAD access layer on both storage layouts: every refusal reaches Serial,
# and the preflight refuses exactly what the Doom boot refuses.
for target in P4 S3; do
  clang -std=c11 -Wall -Wextra -Werror \
    -fsanitize=address,undefined -fno-sanitize-recover=all \
    -DCONFIG_IDF_TARGET_ESP32$target \
    -I"$HERE/fakes/doom_wad" -I"$HERE/../doom/src" \
    -c -o "$TMP/doom_wad_unit_$target.o" "$HERE/doom_wad_unit.c"
  clang++ "${CXXFLAGS[@]}" \
    -DCONFIG_IDF_TARGET_ESP32$target \
    -I"$HERE/fakes/doom_wad" -I"$HERE/../doom/src" \
    -o "$DOOM_WAD_OUT-$target" \
    "$HERE/test_doom_wad.cpp" "$TMP/doom_wad_unit_$target.o"
  "$DOOM_WAD_OUT-$target"
done

# The card a Doom boot that cannot start shows before restarting.
clang++ "${CXXFLAGS[@]}" \
  -o "$DOOM_FAILURE_OUT" "$HERE/test_doom_failure_screen.cpp"
"$DOOM_FAILURE_OUT"

# The 5 s status line is unchanged and the mem line after it parses.
clang++ "${CXXFLAGS[@]}" \
  -o "$MEM_REPORT_OUT" "$HERE/test_mem_report.cpp"
"$MEM_REPORT_OUT"

bash "$HERE/../../mac/ESPDisplaySender/Tests/SenderAudioRTHostTests/run_tests.sh"
