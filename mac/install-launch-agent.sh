#!/bin/zsh
# Install (or reinstall) the login trigger that opens ESPDisplay through
# LaunchServices in the background at login. Run make-app.sh first, or use
# build-and-restart.command, which runs both.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP="/Applications/ESPDisplay.app"

if [[ ! -d "$APP" ]]; then
  echo "error: $APP not found - run make-app.sh first" >&2
  exit 1
fi

LABEL="$(plutil -extract CFBundleIdentifier raw -o - "$APP/Contents/Info.plist")"
[[ -n "$LABEL" ]] || {
  echo "error: $APP has no bundle identifier" >&2
  exit 1
}
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

mkdir -p "$HOME/Library/LaunchAgents"
sed \
  -e "s|__APP__|$APP|" \
  -e "s|__APP_BUNDLE_IDENTIFIER__|$LABEL|" \
  "$HERE/launchagent.plist.template" > "$PLIST"

# Replace any existing registration, then load the LaunchServices trigger.
launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo "installed $PLIST"
echo "logs: /tmp/espdisplaysender.log"
echo
echo "First run: grant Screen Recording to ESPDisplay when macOS"
echo "prompts (System Settings > Privacy & Security > Screen Recording)."
echo "The login trigger opens the app through LaunchServices without taking focus."
echo
echo "open manager: open /Applications/ESPDisplay.app"
echo "uninstall: launchctl bootout gui/$(id -u) $PLIST && rm $PLIST"
