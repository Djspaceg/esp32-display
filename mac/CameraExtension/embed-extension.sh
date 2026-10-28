#!/bin/zsh
# Embed Xcode's signed CoreMediaIO system extension before the containing app
# is signed. The app supplies frames through the extension's CMIO sink stream;
# no socket is opened by the extension.
set -euo pipefail

APP="${CODESIGNING_FOLDER_PATH:?CODESIGNING_FOLDER_PATH is not set}"
DESTINATION="$APP/Contents/Library/SystemExtensions/ESPDisplayCamera.systemextension"
SOURCE_EXTENSION="${BUILT_PRODUCTS_DIR:?BUILT_PRODUCTS_DIR is not set}/ESPDisplayCamera.systemextension"

[[ -n "$APP" && "$APP" == /* && "$APP" != "/" ]] || {
  echo "error: unexpected app path $APP" >&2
  exit 1
}
[[ "$DESTINATION" == "$APP"/Contents/Library/SystemExtensions/ESPDisplayCamera.systemextension ]] || {
  echo "error: unexpected camera extension destination $DESTINATION" >&2
  exit 1
}
[[ -d "$SOURCE_EXTENSION" && "$SOURCE_EXTENSION" == "$BUILT_PRODUCTS_DIR"/ESPDisplayCamera.systemextension ]] || {
  echo "error: missing Xcode-built camera extension at $SOURCE_EXTENSION" >&2
  exit 1
}
rm -rf -- "$DESTINATION"
ditto "$SOURCE_EXTENSION" "$DESTINATION"
codesign --verify --strict "$DESTINATION"
echo "embedded Xcode-signed ESPDisplayCamera.systemextension"
