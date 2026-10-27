#!/bin/zsh
# Embed every shipping revision carried by the release catalog, and the rescue
# image of every family (Repair), before signing.
set -euo pipefail
setopt NULL_GLOB

DESTINATION_DIR="${CODESIGNING_FOLDER_PATH:?CODESIGNING_FOLDER_PATH is not set}/Contents/Resources"
SOURCE_ROOT="${SRCROOT:?SRCROOT is not set}/../../firmware-releases"
CATALOG="$SOURCE_ROOT/manifest.json"
RESCUE_ROOT="$SRCROOT/../../firmware-rescue"
RESCUE_DESTINATION="$DESTINATION_DIR/rescue"
TOOL="$SRCROOT/../../tools/espdisp.py"

mkdir -p "$DESTINATION_DIR"
rm -f -- "$DESTINATION_DIR/manifest.json" "$DESTINATION_DIR"/*.espdispfw
# Only ever the directory this script writes, inside the bundle being built.
[[ "$RESCUE_DESTINATION" == */Contents/Resources/rescue ]] || {
  echo "error: unexpected rescue destination $RESCUE_DESTINATION" >&2
  exit 1
}
rm -rf -- "$RESCUE_DESTINATION"

if [[ -n "${ESPDISP_SKIP_FIRMWARE:-}" ]]; then
  echo "note: canonical firmware resources skipped (ESPDISP_SKIP_FIRMWARE is set)"
  exit 0
fi
if [[ ! -f "$CATALOG" ]]; then
  echo "error: canonical firmware catalog not found at $CATALOG" >&2
  exit 1
fi

ARTIFACTS=("${(@f)$(python3 "$TOOL" release-info "$CATALOG")}")
if [[ ${#ARTIFACTS[@]} -eq 0 ]]; then
  echo "error: release catalog did not resolve any firmware artifacts" >&2
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
echo "embedded canonical firmware catalog and ${#ARTIFACTS[@]} shipping artifacts"

# The rescue images are copied as committed, index and all; the app checks every
# file against its rescue.json before it will write one.
RESCUE_FAMILIES=(c3 c6 s3 s3-4m p4)
for family in "${RESCUE_FAMILIES[@]}"; do
  source="$RESCUE_ROOT/$family"
  if [[ ! -f "$source/rescue.json" ]]; then
    echo "error: rescue image index not found at $source/rescue.json" >&2
    exit 1
  fi
  mkdir -p "$RESCUE_DESTINATION/$family"
  for file in "$source"/rescue.json "$source"/*.bin; do
    ditto "$file" "$RESCUE_DESTINATION/$family/${file:t}"
    chmod 644 "$RESCUE_DESTINATION/$family/${file:t}"
  done
  echo "embedded rescue image for $family"
done
