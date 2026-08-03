#!/bin/zsh
# Build the native ESPDisplaySender app into ~/Applications.
#
# Xcode signs with the Apple Development team configured in the project,
# preserving the app's designated requirement across rebuilds so macOS privacy
# permissions remain attached to the same application identity.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$HERE/ESPDisplaySender/ESPDisplaySender.xcodeproj"
SCHEME="ESPDisplaySender App"
APP="$HOME/Applications/ESPDisplaySender.app"
STAGED_APP="$HOME/Applications/.ESPDisplaySender.app.staged"
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
  -allowProvisioningUpdates \
  build

BUILT_APP="$DERIVED_DATA/Build/Products/Release/ESPDisplaySender.app"
if [[ ! -d "$BUILT_APP" ]]; then
  echo "error: Xcode did not produce $BUILT_APP" >&2
  exit 1
fi

mkdir -p "$HOME/Applications"
rm -rf "$STAGED_APP"
ditto "$BUILT_APP" "$STAGED_APP"
codesign --verify --deep --strict --verbose=1 "$STAGED_APP"

rm -rf "$APP"
mv "$STAGED_APP" "$APP"

codesign --display --verbose=2 "$APP"
echo "built and Apple Development signed $APP"
echo "open manager:      open $APP"
echo "install at login:  $HERE/install-launch-agent.sh"
