#!/bin/zsh
# Install or remove ESPDisplayAudio.driver, then restart coreaudiod so it is
# loaded or unloaded. Must be run as root:
#
#   sudo mac/AudioDriver/install-driver.sh              install build/ESPDisplayAudio.driver
#   sudo mac/AudioDriver/install-driver.sh --uninstall  remove it
#
# Restarting coreaudiod stops all sound on the Mac for a second or two.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SOURCE="$HERE/build/ESPDisplayAudio.driver"
HAL="/Library/Audio/Plug-Ins/HAL"
TARGET="$HAL/ESPDisplayAudio.driver"
# Root-only (mode 700) before anything is copied in, so nothing running as
# the user can touch the copy between its check and the move.
STAGING="$HAL/.ESPDisplayAudio.installing"
STAGED="$STAGING/ESPDisplayAudio.driver"
BUNDLE_ID="com.resourcefork.espdisplay.audio-driver"
PROJECT_FILE="$HERE/../ESPDisplaySender/ESPDisplaySender.xcodeproj/project.pbxproj"

if [[ "$(id -u)" != 0 ]]; then
  echo "error: installing a CoreAudio driver needs admin rights; run:" >&2
  echo "  sudo $0 ${1:-}" >&2
  exit 1
fi

# The same lock the app's Install and Remove buttons hold, so this script and
# the app never install or remove at the same time.
# The lock file is root-only so no other user can hold it to stall an
# install, and the wait for it is bounded.
if [[ -z "${ESPDISP_INSTALL_LOCKED:-}" ]]; then
  LOCK="$HAL/.ESPDisplayAudio.lock"
  mkdir -p "$HAL"
  (umask 077 && touch "$LOCK")
  chown root:wheel "$LOCK"
  chmod 600 "$LOCK"
  status=0
  /usr/bin/lockf -s -k -t 30 "$LOCK" \
    /usr/bin/env ESPDISP_INSTALL_LOCKED=1 /bin/zsh "$0" "$@" || status=$?
  if [[ $status == 75 ]]; then
    echo "error: another install or removal of the audio driver is still running;" \
      "try again in a minute" >&2
  fi
  exit $status
fi

restart_coreaudiod() {
  # launchd starts it again straight away.
  killall coreaudiod 2>/dev/null || true
}

case "${1:-}" in
  --uninstall)
    if [[ -e "$TARGET" ]]; then
      rm -rf -- "$TARGET"
      restart_coreaudiod
      echo "removed $TARGET and restarted coreaudiod"
    else
      echo "$TARGET is not installed"
    fi
    exit 0
    ;;
  "")
    ;;
  *)
    echo "usage: sudo $0 [--uninstall]" >&2
    exit 2
    ;;
esac

if [[ ! -d "$SOURCE" || -L "$SOURCE" ]]; then
  echo "error: $SOURCE is missing; build it first with $HERE/build-driver.sh" >&2
  exit 1
fi
TEAM="$(sed -n 's/.*DEVELOPMENT_TEAM = \([A-Z0-9]*\);.*/\1/p' "$PROJECT_FILE" | sort -u)"
if [[ -z "$TEAM" || "$TEAM" == *$'\n'* ]]; then
  echo "error: expected one DEVELOPMENT_TEAM in $PROJECT_FILE, found: ${TEAM:-none}" >&2
  exit 1
fi

# Everything is checked on the root-owned staged copy, not on build/, which
# any process running as the user could swap between a check and the copy.
mkdir -p "$HAL"
rm -rf -- "$STAGING"
# Whatever happens next, the staging folder goes with the script.
trap 'rm -rf -- "$STAGING"' EXIT
mkdir -m 700 "$STAGING"
chown root:wheel "$STAGING"
ditto "$SOURCE" "$STAGED"
chown -R root:wheel "$STAGED"
chmod -R go-w "$STAGED"
identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$STAGED/Contents/Info.plist")"
if [[ "$identifier" != "$BUNDLE_ID" ]]; then
  echo "error: $SOURCE is $identifier, not $BUNDLE_ID" >&2
  exit 1
fi
# Signed by an Apple-issued certificate of the app's own team, not merely
# signed: an ad-hoc signature would pass a plain --verify.
requirement="=anchor apple generic and identifier \"$BUNDLE_ID\" and certificate leaf[subject.OU] = \"$TEAM\""
if ! codesign --verify --strict -R "$requirement" "$STAGED"; then
  echo "error: $SOURCE is not signed by team $TEAM; rebuild it with $HERE/build-driver.sh" >&2
  exit 1
fi
rm -rf -- "$TARGET"
mv -- "$STAGED" "$TARGET"
restart_coreaudiod
echo "installed $TARGET and restarted coreaudiod"
