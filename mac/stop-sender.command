#!/bin/zsh
# Double-clickable: stop the background sender, freeing the single-instance
# lock so a build launched from Xcode actually runs.
#
# Worth knowing why this is needed: the app takes an exclusive lock on
# /tmp/espdisplaysender.lock. A second copy that cannot get the lock asks the
# running one to show its window and then exits 0. So pressing Run in Xcode
# while the agent is up looks like a successful launch - a manager window
# appears - but it belongs to the installed app, and the freshly built binary
# exited immediately. Stop the agent first, then Run.
set -euo pipefail

LABEL="com.espdisplay.sender"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

echo "==> Stopping the sender LaunchAgent"
launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || echo "    (was not loaded)"

sleep 2
if pgrep -fl "ESPDisplaySender --background" > /dev/null 2>&1; then
  echo "    still running:"
  pgrep -fl "ESPDisplaySender --background"
else
  echo "    stopped. The lock is free, so Xcode can run its own build now."
fi
echo
echo "    start it again: mac/build-and-restart.command"

if [ -t 0 ]; then
  echo
  printf 'Press return to close. '
  read -r _
fi
