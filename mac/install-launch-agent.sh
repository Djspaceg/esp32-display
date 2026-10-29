#!/bin/zsh
# Install (or reinstall) the login trigger that opens ESPDisplaySender through
# LaunchServices in the background at login. Run make-app.sh first, or use
# build-and-restart.command, which runs both.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LABEL="com.resourcefork.espdisplay"
APP="/Applications/ESPDisplaySender.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

if [[ ! -d "$APP" ]]; then
  echo "error: $APP not found - run make-app.sh first" >&2
  exit 1
fi

mkdir -p "$HOME/Library/LaunchAgents"
sed "s|__APP__|$APP|" "$HERE/launchagent.plist.template" > "$PLIST"

# Replace any existing registration, then load the LaunchServices trigger.
launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo "installed $PLIST"
echo "logs: /tmp/espdisplaysender.log"
echo
echo "First run: grant Screen Recording to ESPDisplaySender when macOS"
echo "prompts (System Settings > Privacy & Security > Screen Recording)."
echo "The login trigger opens the app through LaunchServices without taking focus."
echo
echo "open manager: open /Applications/ESPDisplaySender.app"
echo "uninstall: launchctl bootout gui/$(id -u) $PLIST && rm $PLIST"
