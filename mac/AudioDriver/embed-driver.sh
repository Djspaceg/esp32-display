#!/bin/zsh
# Xcode build phase: compile ESPDisplayAudio.driver into the app at
# Contents/Library/Audio and sign it with the identity the app is signed
# with, before the app itself is signed. The app's Install Audio Driver
# button copies it from there into /Library/Audio/Plug-Ins/HAL.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP="${CODESIGNING_FOLDER_PATH:?CODESIGNING_FOLDER_PATH is not set}"
DESTINATION="$APP/Contents/Library/Audio/ESPDisplayAudio.driver"
[[ "$DESTINATION" == *.app/Contents/Library/Audio/ESPDisplayAudio.driver ]] || {
  echo "error: unexpected driver destination $DESTINATION" >&2
  exit 1
}

mkdir -p "${DESTINATION:h}"
"$HERE/compile-driver.sh" "$DESTINATION"
# "-" (ad hoc) when the build is not signed by a team; the app then says the
# driver cannot be installed, since the installer accepts only the team's.
IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
codesign --force --sign "$IDENTITY" --timestamp=none "$DESTINATION"
codesign --verify --strict "$DESTINATION"
echo "embedded ESPDisplayAudio.driver signed by ${EXPANDED_CODE_SIGN_IDENTITY_NAME:-$IDENTITY}"
