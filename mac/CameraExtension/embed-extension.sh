#!/bin/zsh
# Build the CoreMediaIO system extension inside the app before Xcode signs the
# containing bundle. The app supplies complete camera frames through the
# extension's CoreMediaIO sink stream; no socket is opened by the extension.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP="${CODESIGNING_FOLDER_PATH:?CODESIGNING_FOLDER_PATH is not set}"
DESTINATION="$APP/Contents/Library/SystemExtensions/ESPDisplayCamera.systemextension"
EXECUTABLE="$DESTINATION/Contents/MacOS/ESPDisplayCamera"
INFO="$DESTINATION/Contents/Info.plist"
ENTITLEMENTS="$HERE/CameraExtension.entitlements"
SOURCE="$HERE/main.swift"
IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"

[[ "$DESTINATION" == *.app/Contents/Library/SystemExtensions/ESPDisplayCamera.systemextension ]] || {
  echo "error: unexpected camera extension destination $DESTINATION" >&2
  exit 1
}
rm -rf -- "$DESTINATION"
mkdir -p "$DESTINATION/Contents/MacOS"
plutil -lint "$HERE/Info.plist" >/dev/null
plutil -lint "$ENTITLEMENTS" >/dev/null
ditto "$HERE/Info.plist" "$INFO"

for arch in arm64 x86_64; do
  swiftc -parse-as-library -O -target "$arch-apple-macos12.3" \
    -framework CoreMediaIO -framework CoreMedia -framework CoreVideo \
    -framework IOKit \
    -o "$EXECUTABLE.$arch" "$SOURCE"
done
lipo -create "$EXECUTABLE.arm64" "$EXECUTABLE.x86_64" -output "$EXECUTABLE"
rm -f -- "$EXECUTABLE.arm64" "$EXECUTABLE.x86_64"
codesign --force --sign "$IDENTITY" --timestamp=none \
  --entitlements "$ENTITLEMENTS" "$DESTINATION"
codesign --verify --strict "$DESTINATION"
echo "embedded ESPDisplayCamera.systemextension signed by ${EXPANDED_CODE_SIGN_IDENTITY_NAME:-$IDENTITY}"
