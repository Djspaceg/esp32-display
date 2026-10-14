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
STAGED="$HAL/.ESPDisplayAudio.driver.installing"
BUNDLE_ID="com.espdisplay.audio-driver"

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
identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SOURCE/Contents/Info.plist")"
if [[ "$identifier" != "$BUNDLE_ID" ]]; then
  echo "error: $SOURCE is $identifier, not $BUNDLE_ID" >&2
  exit 1
fi
codesign --verify --strict "$SOURCE"

mkdir -p "$HAL"
rm -rf -- "$STAGED"
ditto "$SOURCE" "$STAGED"
chown -R root:wheel "$STAGED"
chmod -R go-w "$STAGED"
rm -rf -- "$TARGET"
mv -- "$STAGED" "$TARGET"
restart_coreaudiod
echo "installed $TARGET and restarted coreaudiod"
