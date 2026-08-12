#!/bin/zsh
# Build the native ESPDisplaySender app into ~/Applications.
#
# Xcode signs with the Apple Development team configured in the project,
# preserving the app's designated requirement across rebuilds so macOS privacy
# permissions remain attached to the same application identity.
set -euo pipefail

# This script relocates and deletes files, so the environment the paths are
# built from is checked first. `set -u` catches an *unset* variable but not an
# empty one, and an empty HOME would quietly retarget "$HOME/Applications/..."
# at a system-wide location.
[[ -n "${HOME:-}" && -d "$HOME" ]] || {
  echo "error: HOME is not set to an existing directory" >&2
  exit 1
}

# Refuse to touch anything that is not an absolute path inside the directory it
# belongs to. Called before every delete and before the install swap, so no
# recursive operation here runs on a path that has not been checked.
#
# The local is NOT called `path`. In zsh `path` is tied to `PATH`, so `local
# path=...` inside a function replaces the search path for the duration of the
# call and every external command in it stops resolving - which is what used to
# happen here: `discard_scratch` could not find `rm`, so neither scratch delete
# ran and every build left a 400MB derived-data directory in TMPDIR.
require_under() {
  local target="$1" parent="$2" label="$3"
  [[ -n "$target" ]] || { echo "error: empty $label path" >&2; exit 1; }
  [[ "$target" == /* ]] || {
    echo "error: $label path is not absolute: $target" >&2; exit 1; }
  [[ "$target" != *..* ]] || {
    echo "error: $label path contains '..': $target" >&2; exit 1; }
  [[ "$target" == "$parent"/?* ]] || {
    echo "error: $label path escapes $parent: $target" >&2; exit 1; }
}

# Delete scratch this script created during this run, after checking it. Build
# intermediates are hundreds of megabytes of disposable output, so they are
# removed rather than moved to the Trash.
#
# Same reason as above for not calling the local `path`: this is the function that
# runs `rm`, and with PATH clobbered it silently deleted nothing.
discard_scratch() {
  local target="$1" parent="$2" label="$3"
  [[ -e "$target" ]] || return 0
  require_under "$target" "$parent" "$label"
  rm -rf -- "$target"
}

HERE="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$HERE/ESPDisplaySender/ESPDisplaySender.xcodeproj"
SCHEME="ESPDisplaySender App"
APP="$HOME/Applications/ESPDisplaySender.app"
STAGED_APP="$HOME/Applications/.ESPDisplaySender.app.staged"
# Trailing slash stripped so the require_under prefix test below is exact;
# macOS sets TMPDIR with one.
SCRATCH_PARENT="${TMPDIR:-/tmp}"
SCRATCH_PARENT="${SCRATCH_PARENT%/}"
DERIVED_DATA="$(mktemp -d "$SCRATCH_PARENT/espdisplaysender.XXXXXX")"

cleanup() {
  discard_scratch "$DERIVED_DATA" "$SCRATCH_PARENT" "build directory"
  discard_scratch "$STAGED_APP" "$HOME/Applications" "staged app"
}
trap cleanup EXIT INT TERM

# The firmware the app ships with, built before Xcode runs so the build phase in
# the project has something to embed and the signature covers it.
#
# WHY THE APP CARRIES FIRMWARE: a .espdispfw can only come from `espdisp.py
# bundle`, so an Add Display sheet that asks the user for one asks them to open a
# terminal - and adding a brand-new board is meant to work without that. Building
# it here uses the CLI on the machine of whoever packages the app, which is a
# different thing from requiring it of whoever uses the app.
#
# Reused when it is already there, because compiling both boards takes minutes and
# most rebuilds are not firmware changes. ESPDISP_REBUILD_FIRMWARE=1 forces a fresh
# one; ESPDISP_SKIP_FIRMWARE=1 packages without any, and the app then asks for a
# file. A failure here is a warning rather than the end of the build: an app with no
# embedded firmware still works, and still updates panels over the air.
FIRMWARE_DIR="$HERE/ESPDisplaySender/Resources"
FIRMWARE="$FIRMWARE_DIR/espdisp-default.espdispfw"
if [[ -n "${ESPDISP_SKIP_FIRMWARE:-}" ]]; then
  echo "skipping the default firmware bundle (ESPDISP_SKIP_FIRMWARE is set)"
elif [[ -f "$FIRMWARE" && -z "${ESPDISP_REBUILD_FIRMWARE:-}" ]]; then
  echo "reusing $FIRMWARE ($(stat -f %z "$FIRMWARE") bytes)"
  echo "  rebuild it with ESPDISP_REBUILD_FIRMWARE=1 $0"
else
  echo "building the default firmware bundle (compiles both boards, minutes)"
  mkdir -p "$FIRMWARE_DIR"
  if ! python3 "$HERE/../tools/espdisp.py" bundle --output "$FIRMWARE"; then
    echo "warning: could not build a firmware bundle; the app will ask for one" >&2
    rm -f -- "$FIRMWARE"
  fi
fi

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination "platform=macOS" \
  -derivedDataPath "$DERIVED_DATA" \
  -allowProvisioningUpdates \
  build

BUILT_APP="$DERIVED_DATA/Build/Products/Release/ESPDisplaySender.app"
if [[ ! -d "$BUILT_APP" ]]; then
  echo "error: Xcode did not produce $BUILT_APP" >&2
  exit 1
fi

mkdir -p "$HOME/Applications"
discard_scratch "$STAGED_APP" "$HOME/Applications" "staged app"
ditto "$BUILT_APP" "$STAGED_APP"
codesign --verify --deep --strict --verbose=1 "$STAGED_APP"

# The outgoing install is moved to the Trash rather than deleted, so a bad
# build is recoverable and nothing recursive ever runs against ~/Applications.
# The cost is that repeated rebuilds accumulate bundles in the Trash.
if [[ -e "$APP" ]]; then
  require_under "$APP" "$HOME/Applications" "installed app"
  RETIRED="$HOME/.Trash/ESPDisplaySender.app.$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$HOME/.Trash"
  mv -- "$APP" "$RETIRED"
  echo "previous install moved to $RETIRED"
fi
mv -- "$STAGED_APP" "$APP"

codesign --display --verbose=2 "$APP"
echo "built and Apple Development signed $APP"
echo "open manager:      open $APP"
echo "install at login:  $HERE/install-launch-agent.sh"
