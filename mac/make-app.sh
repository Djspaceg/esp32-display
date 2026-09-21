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

# Firmware is embedded directly from the committed canonical release store.
# Packaging never rebuilds or duplicates it. The build phase validates the
# catalog and copies every shipping revision it carries; ESPDISP_SKIP_FIRMWARE
# packages the documented no-resource fallback.
CATALOG="$HERE/../firmware-releases/manifest.json"
if [[ -z "${ESPDISP_SKIP_FIRMWARE:-}" ]]; then
  if [[ ! -f "$CATALOG" ]]; then
    echo "error: canonical firmware catalog is missing: $CATALOG" >&2
    exit 1
  fi
  python3 "$HERE/../tools/espdisp.py" release-info "$CATALOG" >/dev/null
fi

# The build number is derived here, not typed into the project, so it ALWAYS
# moves when the source moves. It had been pinned at 2 in the project file, which
# meant every build since reported "1.1 (2)" and no build could be told from any
# other in Finder or in the app - a rebuilt app looked identical to a two-week-old
# one, and only the file's timestamp gave it away.
#
# The count of commits on HEAD is used because it is strictly numeric, which
# CFBundleVersion requires, and monotonic, so a higher number is always the newer
# build. A tree with uncommitted changes gets the same count with a trailing .1,
# which is still numeric and still sorts above the clean commit it came from.
#
# The marketing version (MARKETING_VERSION, 1.1) is deliberately NOT touched: that
# one is the user's to decide.
BUILD_NUMBER="$(git -C "$HERE/.." rev-list --count HEAD)"
SOURCE_COMMIT="$(git -C "$HERE/.." rev-parse --short HEAD)"
if [[ -n "$(git -C "$HERE/.." status --porcelain --untracked-files=no)" ]]; then
  BUILD_NUMBER="${BUILD_NUMBER}.1"
  SOURCE_COMMIT="${SOURCE_COMMIT}-dirty"
fi
echo "build number $BUILD_NUMBER from source $SOURCE_COMMIT"

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination "platform=macOS" \
  -derivedDataPath "$DERIVED_DATA" \
  -allowProvisioningUpdates \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
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
