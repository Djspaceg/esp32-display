#!/bin/zsh
# Embed the canonical c6, s3, and p4 release resources before code signing.
set -euo pipefail

DESTINATION_DIR="${CODESIGNING_FOLDER_PATH:?CODESIGNING_FOLDER_PATH is not set}/Contents/Resources"
SOURCE_ROOT="${SRCROOT:?SRCROOT is not set}/../../firmware-releases"
CATALOG="$SOURCE_ROOT/manifest.json"
TOOL="$SRCROOT/../../tools/espdisp.py"

mkdir -p "$DESTINATION_DIR"
rm -f -- "$DESTINATION_DIR/manifest.json" "$DESTINATION_DIR"/*.espdispfw

if [[ -n "${ESPDISP_SKIP_FIRMWARE:-}" ]]; then
  echo "note: canonical firmware resources skipped (ESPDISP_SKIP_FIRMWARE is set)"
  exit 0
fi
if [[ ! -f "$CATALOG" ]]; then
  echo "error: canonical firmware catalog not found at $CATALOG" >&2
  exit 1
fi

ARTIFACTS=("${(@f)$(python3 "$TOOL" release-info "$CATALOG")}")
if [[ ${#ARTIFACTS[@]} -ne 3 ]]; then
  echo "error: release catalog did not resolve exactly three family artifacts" >&2
  exit 1
fi

ditto "$CATALOG" "$DESTINATION_DIR/manifest.json"
chmod 644 "$DESTINATION_DIR/manifest.json"
for relative in "${ARTIFACTS[@]}"; do
  source="$SOURCE_ROOT/$relative"
  destination="$DESTINATION_DIR/${relative:t}"
  ditto "$source" "$destination"
  chmod 644 "$destination"
  echo "embedded ${relative:t} ($(stat -f %z "$source") bytes)"
done
echo "embedded canonical firmware catalog and c6/s3/p4 artifacts"
