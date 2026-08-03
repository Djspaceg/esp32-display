#!/bin/zsh
# Build the native ESPDisplaySender app into ~/Applications.
#
# Set ESPDISPLAY_CODE_SIGN_IDENTITY to a stable signing identity to preserve
# the app's designated requirement across rebuilds. Without one, the script
# uses ad-hoc signing, which can require Screen Recording permission again.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$HERE/ESPDisplaySender/ESPDisplaySender.xcodeproj"
SCHEME="ESPDisplaySender App"
APP="$HOME/Applications/ESPDisplaySender.app"
STAGED_APP="$HOME/Applications/.ESPDisplaySender.app.staged"
SIGNING_IDENTITY="${ESPDISPLAY_CODE_SIGN_IDENTITY:--}"
DERIVED_DATA="$(mktemp -d "${TMPDIR:-/tmp}/espdisplaysender.XXXXXX")"

cleanup() {
  rm -rf "$DERIVED_DATA" "$STAGED_APP"
}
trap cleanup EXIT INT TERM

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination "platform=macOS" \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  build

BUILT_APP="$DERIVED_DATA/Build/Products/Release/ESPDisplaySender.app"
if [[ ! -d "$BUILT_APP" ]]; then
  echo "error: Xcode did not produce $BUILT_APP" >&2
  exit 1
fi

mkdir -p "$HOME/Applications"
rm -rf "$STAGED_APP"
ditto "$BUILT_APP" "$STAGED_APP"

if [[ "$SIGNING_IDENTITY" == "-" ]]; then
  codesign --force --sign - "$STAGED_APP"
  SIGNING_NOTE="ad-hoc signed; a rebuild may require Screen Recording permission again"
else
  codesign --force --options runtime --sign "$SIGNING_IDENTITY" "$STAGED_APP"
  codesign --verify --strict --verbose=1 "$STAGED_APP"
  SIGNING_NOTE="signed with $SIGNING_IDENTITY"
fi

rm -rf "$APP"
mv "$STAGED_APP" "$APP"

echo "built $APP"
echo "$SIGNING_NOTE"
echo "open manager:      open $APP"
echo "install at login:  $HERE/install-launch-agent.sh"
