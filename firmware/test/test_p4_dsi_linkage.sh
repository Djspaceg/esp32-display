#!/bin/bash
# Build the production P4 family and prove its DSI draw paths retain shared
# runtime state instead of being optimized into constant failure.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD_ROOT="${ESPDISP_P4_LINKAGE_BUILD_ROOT:-$REPO_ROOT/firmware/test/build/p4-dsi-linkage}"
STAGED_SKETCH="$BUILD_ROOT/display_stream"
OUTPUT_DIR="$BUILD_ROOT/output"
BUILD_PATH="$OUTPUT_DIR/build"

cleanup() {
  if [[ "${ESPDISP_KEEP_P4_LINKAGE_BUILD:-0}" != "1" ]]; then
    rm -rf "$BUILD_ROOT"
  fi
}
trap cleanup EXIT

rm -rf "$BUILD_ROOT"
mkdir -p "$STAGED_SKETCH" "$OUTPUT_DIR"
rsync -a \
  --exclude build \
  --exclude partitions.csv \
  --exclude wifi_config.h \
  "$REPO_ROOT/firmware/display_stream/" "$STAGED_SKETCH/"
cp "$REPO_ROOT/firmware/display_stream/wifi_config.h.example" \
  "$STAGED_SKETCH/wifi_config.h"
cp "$REPO_ROOT/firmware/partitions_p4_4b.csv" \
  "$STAGED_SKETCH/partitions.csv"

TMPDIR="$BUILD_ROOT/tmp"
mkdir -p "$TMPDIR"
export TMPDIR
python3 - "$REPO_ROOT" "$STAGED_SKETCH" "$OUTPUT_DIR" <<'PY'
import os
import sys

repo_root, sketch_dir, output_dir = sys.argv[1:]
sys.path.insert(0, os.path.join(repo_root, "tools"))
import espdisp

family = espdisp.FAMILIES["p4"]
espdisp.validate_family_build_contract(family)
command = [
    espdisp.arduino_cli(),
    "compile",
    "-b",
    family.fqbn,
    "--libraries",
    espdisp.LIBRARIES_DIR,
]
for relative in family.extra_library_dirs:
    command += ["--libraries", os.path.join(repo_root, relative)]
if family.extra_flags:
    flags = " ".join(family.extra_flags)
    command += [
        "--build-property",
        "compiler.c.extra_flags=%s" % flags,
        "--build-property",
        "compiler.cpp.extra_flags=%s" % flags,
    ]
command += [
    "--build-path",
    os.path.join(output_dir, "build"),
    "--output-dir",
    output_dir,
    ".",
]
lines = espdisp.run_streaming(command, cwd=sketch_dir)
espdisp.validate_family_app_contract(
    family, espdisp.read_binary(espdisp.app_image(output_dir)))
espdisp.report_sizes(lines)
PY

OBJDUMP="${RISCV32_ESP_ELF_OBJDUMP:-}"
if [[ -z "$OBJDUMP" ]]; then
  OBJDUMP="$(find "$HOME/Library/Arduino15/packages/esp32/tools/esp-rv32" \
    -type f -name riscv32-esp-elf-objdump -print 2>/dev/null | sort | tail -n 1)"
fi
if [[ -z "$OBJDUMP" || ! -x "$OBJDUMP" ]]; then
  echo "FAIL: installed riscv32-esp-elf-objdump not found" >&2
  exit 1
fi

PANEL_OBJECT="$BUILD_PATH/sketch/panel_transfer.cpp.o"
FRAME_OBJECT="$BUILD_PATH/sketch/frame_pipeline.cpp.o"
ORIENTATION_OBJECT="$BUILD_PATH/sketch/orientation.cpp.o"
POWER_OBJECT="$BUILD_PATH/sketch/display_power.cpp.o"
for object in \
  "$PANEL_OBJECT" \
  "$FRAME_OBJECT" \
  "$ORIENTATION_OBJECT" \
  "$POWER_OBJECT"; do
  if [[ ! -f "$object" ]]; then
    echo "FAIL: expected build artifact missing: $object" >&2
    exit 1
  fi
done

PANEL_DISASSEMBLY="$BUILD_ROOT/panel_transfer.dis"
FRAME_DISASSEMBLY="$BUILD_ROOT/frame_pipeline.dis"
"$OBJDUMP" -drC "$PANEL_OBJECT" > "$PANEL_DISASSEMBLY"
"$OBJDUMP" -drC "$FRAME_OBJECT" > "$FRAME_DISASSEMBLY"

PANEL_BODY="$(awk '
  /^[[:xdigit:]]+ <.*>:/ {
    if (!printing) {
      printing = index($0, "<boardpaneldsi::drawBitmap(") != 0
    } else if ($0 ~ /^[[:xdigit:]]+ <[^.]/) {
      exit
    }
  }
  printing { print }
' "$PANEL_DISASSEMBLY")"

echo
echo "=== panel_transfer.cpp.o boardpaneldsi::drawBitmap ==="
if [[ -n "$PANEL_BODY" ]]; then
  printf '%s\n' "$PANEL_BODY"
else
  echo "missing"
fi

if [[ -z "$PANEL_BODY" ]]; then
  echo "FAIL: panel_transfer.cpp.o has no complete boardpaneldsi::drawBitmap body" >&2
  exit 1
fi
if grep -Eq '[[:space:]]li[[:space:]]+a0,258([[:space:]]|$)' <<<"$PANEL_BODY" &&
   ! grep -q 'esp_lcd_panel_draw_bitmap' <<<"$PANEL_BODY"; then
  echo "FAIL: panel_transfer.cpp.o DSI draw is the constant ESP_ERR_INVALID_ARG return" >&2
  exit 1
fi
if ! grep -q 'esp_lcd_panel_draw_bitmap' <<<"$PANEL_BODY"; then
  echo "FAIL: panel_transfer.cpp.o DSI draw has no nontrivial panel draw call" >&2
  exit 1
fi

echo
echo "=== frame_pipeline.cpp.o DSI linkage references ==="
grep -nE \
  'boardpaneldsi::panel(Width|Height)|esp_lcd_panel_draw_bitmap|statDrawErrors' \
  "$FRAME_DISASSEMBLY" || true

for symbol in \
  'boardpaneldsi::panelWidth' \
  'boardpaneldsi::panelHeight' \
  'esp_lcd_panel_draw_bitmap'; do
  if ! grep -q "$symbol" "$FRAME_DISASSEMBLY"; then
    echo "FAIL: frame_pipeline.cpp.o cfg.isDsi() path has no reference to $symbol" >&2
    exit 1
  fi
done

ORIENTATION_DISASSEMBLY="$BUILD_ROOT/orientation.dis"
POWER_DISASSEMBLY="$BUILD_ROOT/display_power.dis"
"$OBJDUMP" -drC "$ORIENTATION_OBJECT" > "$ORIENTATION_DISASSEMBLY"
"$OBJDUMP" -drC "$POWER_OBJECT" > "$POWER_DISASSEMBLY"

echo
echo "=== orientation.cpp.o shared DSI state ==="
grep -n 'boardpaneldsi::orientationQuadrant' "$ORIENTATION_DISASSEMBLY" || true
if ! grep -q 'boardpaneldsi::orientationQuadrant' "$ORIENTATION_DISASSEMBLY"; then
  echo "FAIL: orientation.cpp.o DSI branch does not update shared orientation" >&2
  exit 1
fi

echo
echo "=== display_power.cpp.o shared DSI state ==="
grep -nE \
  'boardpaneldsi::backlight(Pin|EnablePin)|ledc_(set|update)_duty' \
  "$POWER_DISASSEMBLY" || true
for symbol in \
  'boardpaneldsi::backlightPin' \
  'boardpaneldsi::backlightEnablePin' \
  'ledc_set_duty' \
  'ledc_update_duty'; do
  if ! grep -q "$symbol" "$POWER_DISASSEMBLY"; then
    echo "FAIL: display_power.cpp.o DSI branch has no reference to $symbol" >&2
    exit 1
  fi
done

echo "PASS: production P4 objects retain nontrivial shared-state DSI draw paths"
