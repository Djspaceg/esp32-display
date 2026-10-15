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
DOOM_SOUND_OUT="$TMP/test_doom_sound"
DOOM_PACE_OUT="$TMP/test_doom_audio_pace"
DOOM_BRIDGE_OUT="$TMP/test_doom_audio_bridge"
MEM_REPORT_OUT="$TMP/test_mem_report"
USB_INPUT_OUT="$TMP/test_usb_input"
USB_HOST_INIT_OUT="$TMP/test_usb_host_init"
QUAKE_PAK_OUT="$TMP/test_quake_pak"
GAME_STORE_OUT="$TMP/test_game_store"
DOOM_STORE_WAD_OUT="$TMP/test_doom_store_wad"
QUAKE_INPUT_OUT="$TMP/test_quake_input"
BOOT_SCREEN_OUT="$TMP/test_boot_screen"
DSI_BACKLIGHT_OUT="$TMP/test_dsi_backlight"
COPROCESSOR_OUT="$TMP/test_coprocessor_update"
STREAM_UPDATE_OUT="$TMP/test_stream_update"
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
  -I"$HERE/../quake/src" \
  -o "$DOOM_ENTRY_OUT" \
  "$HERE/test_doom_entry_gate.cpp" \
  "$HERE/../display_stream/input_button.cpp" \
  "$HERE/../display_stream/input_map.cpp" \
  "$HERE/../display_stream/input_touch.cpp" \
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
  # Doom WADs in the game store: listed, chosen and read unmapped. Each case is
  # its own process, as each is its own boot on the board.
  clang++ "${CXXFLAGS[@]}" \
    -DCONFIG_IDF_TARGET_ESP32$target \
    -I"$HERE/fakes/doom_wad" -I"$HERE/../doom/src" \
    -o "$DOOM_STORE_WAD_OUT-$target" \
    "$HERE/test_doom_store_wad.cpp" "$TMP/doom_wad_unit_$target.o"
  for case in preflight legacy chosen missing small-s3; do
    "$DOOM_STORE_WAD_OUT-$target" "$case"
  done
done

# Which game the Doom boot takes a stored WAD for: by its IWAD name, else by
# its lumps (d_iwad.c.inc, unmodified; upstream engine code, so its own
# warnings are not this suite's to fail on).
clang -std=c11 -w -I"$HERE/../doom/src" \
  -c -o "$TMP/doom_iwad_unit.o" "$HERE/doom_iwad_unit.c"
clang++ "${CXXFLAGS[@]}" -I"$HERE/../doom/src" \
  -o "$TMP/test_doom_iwad" "$HERE/test_doom_iwad.cpp" "$TMP/doom_iwad_unit.o"
"$TMP/test_doom_iwad"

# The game store's directory: the format the Mac app writes (the shared
# fixture), every refusal, and the legacy layout.
clang++ "${CXXFLAGS[@]}" \
  -DGAME_STORE_FIXTURE="\"$HERE/../../mac/ESPDisplaySender/Tests/SenderProtocolTests/Fixtures/game-store-v1.hex\"" \
  -I"$HERE/../doom/src" \
  -o "$GAME_STORE_OUT" "$HERE/test_game_store.cpp"
"$GAME_STORE_OUT"

# The saved-games store beside doom_wad: configs and saves survive a restart,
# and the power going mid-write leaves the old file or the new one, whole.
clang++ "${CXXFLAGS[@]}" \
  -o "$TMP/test_save_store" "$HERE/test_save_store.cpp"
"$TMP/test_save_store"

# Doom's sound effects: what the engine starts is what the codec is sent
# (the sound module and i_sound.c.inc, unmodified, against fakes/doom_sound).
# The upstream music-module table leaves its optional Poll hook implicit.
clang -std=c11 -Wall -Wextra -Werror -Wno-missing-field-initializers \
  -fsanitize=address,undefined -fno-sanitize-recover=all \
  -I"$HERE/fakes/doom_sound" -I"$HERE/../doom/src" \
  -c -o "$TMP/doom_sound_unit.o" "$HERE/doom_sound_unit.c"
clang++ "${CXXFLAGS[@]}" \
  -I"$HERE/fakes/doom_sound" -I"$HERE/../doom/src" \
  -o "$DOOM_SOUND_OUT" \
  "$HERE/test_doom_sound.cpp" "$TMP/doom_sound_unit.o"
"$DOOM_SOUND_OUT"

# Doom's sound-output pacing keeps the I2S queue short without running dry.
clang++ "${CXXFLAGS[@]}" \
  -o "$DOOM_PACE_OUT" "$HERE/test_doom_audio_pace.cpp"
"$DOOM_PACE_OUT"

# The board side of Doom's sound (doom_audio.cpp and the real codec backend,
# unmodified, against fakes/audio): nothing on boards without audio parts.
clang++ "${CXXFLAGS[@]}" \
  -DCONFIG_IDF_TARGET_ESP32S3 -DESPDISP_HOST_AUDIO_TEST -DESPDISP_DOOM_RUNTIME \
  -I"$HERE/fakes/audio" \
  -I"$HERE/../libraries/espdisp_board/src" \
  -I"$HERE/../doom/src" \
  -o "$DOOM_BRIDGE_OUT" \
  "$HERE/test_doom_audio_bridge.cpp" \
  "$HERE/fakes/audio/audio_host_fakes.cpp" \
  "$HERE/../display_stream/audio_backend.cpp" \
  "$HERE/../display_stream/doom_audio.cpp"
"$DOOM_BRIDGE_OUT"

# The card a Doom boot that cannot start shows before restarting.
clang++ "${CXXFLAGS[@]}" \
  -o "$DOOM_FAILURE_OUT" "$HERE/test_doom_failure_screen.cpp"
"$DOOM_FAILURE_OUT"

# Which carriers can host a USB keyboard at all, and what a HID boot report
# means to Doom: key and mouse-button edges, the movement letters inside a menu,
# and nothing left held when the cable is pulled.
clang++ "${CXXFLAGS[@]}" \
  -I"$HERE/../libraries/espdisp_board/src" \
  -I"$HERE/../doom/src" \
  -o "$USB_INPUT_OUT" "$HERE/test_usb_input.cpp"
"$USB_INPUT_OUT"

# The USB host stack starts through tuh_rhport_init(), not the tusb_init()
# dispatcher, whose device-stack init reference keeps about 48 KB of device
# class buffers in the P4's DMA-capable internal RAM, which the C6 WiFi link
# needs while streaming.
clang++ "${CXXFLAGS[@]}" \
  -DESPDISP_BOARD_P4_4B -DESPDISP_DOOM_RUNTIME \
  -I"$HERE/fakes/usb_host" \
  -I"$HERE/../libraries/espdisp_board/src" \
  -I"$HERE/../doom/src" \
  -o "$USB_HOST_INIT_OUT" \
  "$HERE/test_usb_host_init.cpp" \
  "$HERE/../doom/src/platform/doom_usb_input.cpp"
"$USB_HOST_INIT_OUT"

# Quake's read-only data file: which partition contents are a usable pack and
# how the one file it serves reads and seeks. Checks the real shareware pak0
# too where tools/fetch_game_data.sh has put it.
clang++ "${CXXFLAGS[@]}" \
  -DQUAKE_TEST_PAK_PATH="\"$HERE/../quake/id1/pak0.pak\"" \
  -I"$HERE/../doom/src" \
  -o "$QUAKE_PAK_OUT" "$HERE/test_quake_pak.cpp"
"$QUAKE_PAK_OUT"

# Quake's touch, BOOT and USB key meanings and its frame placement.
clang++ "${CXXFLAGS[@]}" \
  -I"$HERE/../doom/src" \
  -o "$QUAKE_INPUT_OUT" "$HERE/test_quake_input.cpp"
"$QUAKE_INPUT_OUT"

# Quake's PSRAM relocation lists agree with themselves and the engine sources.
bash "$HERE/test_quake_statics.sh"

# The boot screen on every board profile, and its image asset matching the PNG
# it is generated from.
clang++ "${CXXFLAGS[@]}" \
  -I"$HERE/../libraries/espdisp_board/src" \
  -o "$BOOT_SCREEN_OUT" "$HERE/test_boot_screen.cpp"
"$BOOT_SCREEN_OUT"
python3 "$HERE/../../tools/generate_boot_image.py" --check

# The P4 boards' backlight through the real DSI backend: every lit level,
# the dimmed status card included, reaches a duty the glass shows.
clang++ "${CXXFLAGS[@]}" \
  -DCONFIG_IDF_TARGET_ESP32P4 -DESPDISP_BOARD_P4_4B \
  -I"$HERE/fakes/dsi_backlight" \
  -I"$HERE/../libraries/espdisp_board/src" \
  -I"$HERE/../libraries/esp_lcd_jd9365/src" \
  -I"$HERE/../libraries/esp_lcd_st7703/src" \
  -o "$DSI_BACKLIGHT_OUT" "$HERE/test_dsi_backlight.cpp"
"$DSI_BACKLIGHT_OUT"

# The C6 coprocessor's ESP-Hosted pairing: a silent coprocessor is outdated,
# only the image pinned for the host is offered, and only a whole transfer
# with the pinned digest is finalized.
clang++ "${CXXFLAGS[@]}" \
  -o "$COPROCESSOR_OUT" "$HERE/test_coprocessor_update.cpp"
"$COPROCESSOR_OUT"

# Firmware update over the stream channel: nothing is buffered before the
# PBKDF2 challenge is answered, loss/duplication/reordering still write the
# exact image once, only a matching SHA-256 ever reaches activation, and the
# image area is erased before any write on a DSI panel.
clang++ "${CXXFLAGS[@]}" \
  -o "$STREAM_UPDATE_OUT" "$HERE/test_stream_update.cpp"
"$STREAM_UPDATE_OUT"

# The 5 s status line is unchanged and the mem line after it parses.
clang++ "${CXXFLAGS[@]}" \
  -o "$MEM_REPORT_OUT" "$HERE/test_mem_report.cpp"
"$MEM_REPORT_OUT"

bash "$HERE/../../mac/ESPDisplaySender/Tests/SenderAudioRTHostTests/run_tests.sh"
