#!/bin/zsh
# Double-clickable: build ESPDisplaySender from this checkout, install the
# LaunchAgent, and start it.
#
# Finder launches a .command with the working directory set to the user's home,
# not to the script's folder, so everything here is resolved relative to $0
# instead of assuming a cwd.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LABEL="com.espdisplay.sender"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

echo "==> Stopping any running sender"
# make-app.sh deletes and replaces the app bundle, so move the running copy out
# of the way first. Not being loaded is the normal case, not a failure.
launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || echo "    (was not running)"

echo "==> Building (Release, via Xcode - this takes a minute)"
"$HERE/make-app.sh"

echo "==> Installing and starting the LaunchAgent"
"$HERE/install-launch-agent.sh"

echo
echo "==> Status"
sleep 4
if pgrep -f "ESPDisplaySender --background" > /dev/null 2>&1; then
  echo "    running as PID $(pgrep -f 'ESPDisplaySender --background' | tr '\n' ' ')"
else
  echo "    NOT running - check the log below"
fi
echo
echo "    log:     /tmp/espdisplaysender.log"
echo "    manager: open ~/Applications/ESPDisplaySender.app"

# Finder leaves the Terminal window open, but a prompt makes it obvious the
# script finished rather than stalled. Skipped when run non-interactively.
if [ -t 0 ]; then
  echo
  printf 'Press return to close. '
  read -r _
fi
