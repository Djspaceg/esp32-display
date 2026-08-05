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
require_under() {
  local path="$1" parent="$2" label="$3"
  [[ -n "$path" ]] || { echo "error: empty $label path" >&2; exit 1; }
  [[ "$path" == /* ]] || {
    echo "error: $label path is not absolute: $path" >&2; exit 1; }
  [[ "$path" != *..* ]] || {
    echo "error: $label path contains '..': $path" >&2; exit 1; }
  [[ "$path" == "$parent"/?* ]] || {
    echo "error: $label path escapes $parent: $path" >&2; exit 1; }
}

# Delete scratch this script created during this run, after checking it. Build
# intermediates are hundreds of megabytes of disposable output, so they are
# removed rather than moved to the Trash.
discard_scratch() {
  local path="$1" parent="$2" label="$3"
  [[ -e "$path" ]] || return 0
  require_under "$path" "$parent" "$label"
  rm -rf -- "$path"
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
