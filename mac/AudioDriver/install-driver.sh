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
BUNDLE_ID="com.espdisplay.audio-driver"
PROJECT_FILE="$HERE/../ESPDisplaySender/ESPDisplaySender.xcodeproj/project.pbxproj"

if [[ "$(id -u)" != 0 ]]; then
  echo "error: installing a CoreAudio driver needs admin rights; run:" >&2
  echo "  sudo $0 ${1:-}" >&2
  exit 1
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
mkdir -m 700 "$STAGING"
chown root:wheel "$STAGING"
ditto "$SOURCE" "$STAGED"
chown -R root:wheel "$STAGED"
chmod -R go-w "$STAGED"
identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$STAGED/Contents/Info.plist")"
if [[ "$identifier" != "$BUNDLE_ID" ]]; then
  rm -rf -- "$STAGING"
  echo "error: $SOURCE is $identifier, not $BUNDLE_ID" >&2
  exit 1
fi
# Signed by an Apple-issued certificate of the app's own team, not merely
# signed: an ad-hoc signature would pass a plain --verify.
requirement="=anchor apple generic and identifier \"$BUNDLE_ID\" and certificate leaf[subject.OU] = \"$TEAM\""
if ! codesign --verify --strict -R "$requirement" "$STAGED"; then
  rm -rf -- "$STAGING"
  echo "error: $SOURCE is not signed by team $TEAM; rebuild it with $HERE/build-driver.sh" >&2
  exit 1
fi
rm -rf -- "$TARGET"
mv -- "$STAGED" "$TARGET"
rmdir "$STAGING"
restart_coreaudiod
echo "installed $TARGET and restarted coreaudiod"
