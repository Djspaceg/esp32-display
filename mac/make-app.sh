#!/bin/zsh
# Build ESPDisplaySender.app into ~/Applications.
#
# The bundle gives the sender a stable identity for the Screen Recording
# permission (TCC keys off the bundle, not the launching terminal) and
# makes it double-clickable. Ad-hoc signed: fine for a locally built app.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Applications/ESPDisplaySender.app"

cd "$HERE/ESPDisplaySender"
swift build -c release

mkdir -p "$APP/Contents/MacOS"
cp "$HERE/Info.plist" "$APP/Contents/Info.plist"
cp ".build/release/ESPDisplaySender" "$APP/Contents/MacOS/ESPDisplaySender"
codesign --force -s - "$APP"

echo "built $APP"
echo "run it:            open $APP"
echo "install at login:  $HERE/install-launch-agent.sh"
echo
echo "NOTE: the ad-hoc signature changes with every rebuild, which resets"
echo "the Screen Recording permission - re-grant it in System Settings >"
echo "Privacy & Security after rebuilding (launchd retries until you do)."
