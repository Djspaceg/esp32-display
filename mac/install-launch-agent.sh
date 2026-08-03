#!/bin/zsh
# Install (or reinstall) the LaunchAgent that starts ESPDisplaySender at
# login and restarts it if it exits. Run make-app.sh first.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LABEL="com.espdisplay.sender"
BIN="$HOME/Applications/ESPDisplaySender.app/Contents/MacOS/ESPDisplaySender"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

if [[ ! -x "$BIN" ]]; then
  echo "error: $BIN not found - run make-app.sh first" >&2
  exit 1
fi

mkdir -p "$HOME/Library/LaunchAgents"
sed "s|__BIN__|$BIN|" "$HERE/launchagent.plist.template" > "$PLIST"

# Replace any existing registration, then load and start.
launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo "installed $PLIST"
echo "logs: /tmp/espdisplaysender.log"
echo
echo "First run: grant Screen Recording to ESPDisplaySender when macOS"
echo "prompts (System Settings > Privacy & Security > Screen Recording)."
echo "launchd will keep retrying every ~10s until the permission is granted."
echo
echo "uninstall: launchctl bootout gui/$(id -u) $PLIST && rm $PLIST"
