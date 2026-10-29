#!/bin/zsh
# Embed Xcode's signed CoreMediaIO system extension before the containing app
# is signed. The app supplies frames through the extension's CMIO sink stream;
# no socket is opened by the extension.
set -euo pipefail

if [[ "${ESPDISP_SKIP_CAMERA_EXTENSION:-}" == "1" ]]; then
  echo "camera extension excluded for the Local Network test build"
  exit 0
fi

APP="${CODESIGNING_FOLDER_PATH:?CODESIGNING_FOLDER_PATH is not set}"
IDENTIFIER="${CAMERA_EXTENSION_BUNDLE_ID:?CAMERA_EXTENSION_BUNDLE_ID is not set}"
EXTENSION_NAME="$IDENTIFIER.systemextension"
DESTINATION="$APP/Contents/Library/SystemExtensions/$EXTENSION_NAME"
SOURCE_EXTENSION="${BUILT_PRODUCTS_DIR:?BUILT_PRODUCTS_DIR is not set}/$EXTENSION_NAME"

[[ -n "$APP" && "$APP" == /* && "$APP" != "/" ]] || {
  echo "error: unexpected app path $APP" >&2
  exit 1
}
[[ "$DESTINATION" == "$APP"/Contents/Library/SystemExtensions/"$EXTENSION_NAME" ]] || {
  echo "error: unexpected camera extension destination $DESTINATION" >&2
  exit 1
}
[[ -d "$SOURCE_EXTENSION" && "$SOURCE_EXTENSION" == "$BUILT_PRODUCTS_DIR"/"$EXTENSION_NAME" ]] || {
  echo "error: missing Xcode-built camera extension at $SOURCE_EXTENSION" >&2
  exit 1
}
[[ "$(plutil -extract CFBundleIdentifier raw -o - \
  "$SOURCE_EXTENSION/Contents/Info.plist")" == "$IDENTIFIER" ]] || {
  echo "error: camera extension bundle name and identifier do not match" >&2
  exit 1
}
rm -rf -- "$DESTINATION"
ditto "$SOURCE_EXTENSION" "$DESTINATION"
codesign --verify --strict "$DESTINATION"
echo "embedded Xcode-signed $EXTENSION_NAME"
