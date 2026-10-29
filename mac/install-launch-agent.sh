#!/bin/zsh
# Install (or reinstall) the login trigger that opens ESPDisplaySender through
# LaunchServices in the background at login. Run make-app.sh first, or use
# build-and-restart.command, which runs both.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LABEL="com.resourcefork.espdisplay"
LEGACY_LABEL="com.espdisplay.sender"
APP="/Applications/ESPDisplaySender.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LEGACY_PLIST="$HOME/Library/LaunchAgents/$LEGACY_LABEL.plist"

if [[ ! -d "$APP" ]]; then
  echo "error: $APP not found - run make-app.sh first" >&2
  exit 1
fi

mkdir -p "$HOME/Library/LaunchAgents"
sed "s|__APP__|$APP|" "$HERE/launchagent.plist.template" > "$PLIST"

# The bundle identifier changed. Retire the old agent before installing the
# new label, otherwise login can start two copies of the same executable.
launchctl bootout "gui/$(id -u)/$LEGACY_LABEL" 2>/dev/null || true
if [[ -e "$LEGACY_PLIST" ]]; then
  [[ "$LEGACY_PLIST" == "$HOME/Library/LaunchAgents/"?* ]] || {
    echo "error: unexpected legacy LaunchAgent path $LEGACY_PLIST" >&2
    exit 1
  }
  mkdir -p "$HOME/.Trash"
  retired="$HOME/.Trash/$LEGACY_LABEL.plist"
  suffix=2
  while [[ -e "$retired" || -L "$retired" ]]; do
    retired="$HOME/.Trash/$LEGACY_LABEL.plist-$suffix"
    ((suffix += 1))
  done
  mv -- "$LEGACY_PLIST" "$retired"
  echo "retired $LEGACY_PLIST to $retired"
fi

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
