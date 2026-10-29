#!/bin/zsh
# Build the native ESPDisplaySender app into /Applications.
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
WORKSPACE="$(cd "$HERE/.." && pwd)"
PROJECT="$HERE/ESPDisplaySender/ESPDisplaySender.xcodeproj"
SCHEME="ESPDisplaySender App"
APP_PARENT="/Applications"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
APP_NAME="ESPDisplaySender"
APP="$APP_PARENT/$APP_NAME.app"
STAGED_APP="$APP_PARENT/.ESPDisplaySender.app.staged"
SCRATCH_PARENT="$WORKSPACE"
DERIVED_DATA="$(mktemp -d "$SCRATCH_PARENT/.espdisplaysender.XXXXXX")"

mkdir -p "$APP_PARENT"

cleanup() {
  discard_scratch "$DERIVED_DATA" "$SCRATCH_PARENT" "build directory"
  discard_scratch "$STAGED_APP" "$APP_PARENT" "staged app"
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
# When rebuilding the same source while that number is already installed, advance
# the numeric suffix so Finder and the app can distinguish the replacement.
#
# The marketing version (MARKETING_VERSION, 1.1) is deliberately NOT touched: that
# one is the user's to decide.
BASE_BUILD_NUMBER="$(git -C "$HERE/.." rev-list --count HEAD)"
BUILD_REVISION=0
SOURCE_COMMIT="$(git -C "$HERE/.." rev-parse --short HEAD)"
if [[ -n "$(git -C "$HERE/.." status --porcelain --untracked-files=no)" ]]; then
  BUILD_REVISION=1
  SOURCE_COMMIT="${SOURCE_COMMIT}-dirty"
fi
if [[ -f "$APP/Contents/Info.plist" ]]; then
  INSTALLED_BUILD_NUMBER="$(plutil -extract CFBundleVersion raw -o - \
    "$APP/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$INSTALLED_BUILD_NUMBER" == "$BASE_BUILD_NUMBER" ]]; then
    INSTALLED_REVISION=0
  elif [[ "$INSTALLED_BUILD_NUMBER" == "$BASE_BUILD_NUMBER".* ]]; then
    INSTALLED_REVISION="${INSTALLED_BUILD_NUMBER#"$BASE_BUILD_NUMBER".}"
  else
    INSTALLED_REVISION=""
  fi
  if [[ "$INSTALLED_REVISION" == <-> && "$INSTALLED_REVISION" -ge "$BUILD_REVISION" ]]; then
    BUILD_REVISION=$((INSTALLED_REVISION + 1))
  fi
fi
BUILD_NUMBER="$BASE_BUILD_NUMBER"
if (( BUILD_REVISION > 0 )); then
  BUILD_NUMBER="${BASE_BUILD_NUMBER}.${BUILD_REVISION}"
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

BUILT_APP="$DERIVED_DATA/Build/Products/Release/$APP_NAME.app"
if [[ ! -d "$BUILT_APP" ]]; then
  echo "error: Xcode did not produce $BUILT_APP" >&2
  exit 1
fi

discard_scratch "$STAGED_APP" "$APP_PARENT" "staged app"
ditto "$BUILT_APP" "$STAGED_APP"
codesign --verify --deep --strict --verbose=1 "$STAGED_APP"

# Xcode build products can be registered by LaunchServices even though they
# are immediately discarded. Those dead registrations can later be chosen as
# the display label for a privacy entry. Keep only the installed app
# registered. The staging path is deliberately hidden and was never
# registered, so asking LaunchServices to unregister it fails its scan.
[[ -x "$LSREGISTER" ]] || {
  echo "error: LaunchServices register tool is missing: $LSREGISTER" >&2
  exit 1
}
"$LSREGISTER" -u "$BUILT_APP"
echo "unregistered the transient Xcode build product from LaunchServices"

# Keep only the known installed path registered. Deleting an app bundle while
# its old process runs is safe: the existing process continues from its mapped
# files, while the next launch sees the replacement at the same path.
remove_previous_install() {
  local target="$1"
  [[ -e "$target" ]] || return 0
  require_under "$target" "$APP_PARENT" "previous install"
  [[ "$target" == "$APP_PARENT/ESPDisplaySender.app" ]] || {
    echo "error: unexpected installed app path $target" >&2
    exit 1
  }
  "$LSREGISTER" -u "$target" || true
  discard_scratch "$target" "$APP_PARENT" "previous install"
  echo "unregistered and deleted the previous install"
}

remove_previous_install "$APP"
mv -- "$STAGED_APP" "$APP"
"$LSREGISTER" -f -R -trusted "$APP"

codesign --display --verbose=2 "$APP"
if ! codesign -d --entitlements :- "$APP" 2>&1 \
  | grep -Fq "<string>4D22XL743H.com.resourcefork.espdisplay</string>"; then
  echo "error: installed app lacks its Data Protection Keychain access group" >&2
  exit 1
fi
echo "verified Data Protection Keychain access group"

registered_paths="$("$LSREGISTER" -dump | awk '
  /^path:[[:space:]]+/ {
    if (path != "" && name == "ESPDisplaySender") print path
    path = $0
    sub(/^[^/]*\//, "/", path)
    name = ""
    next
  }
  /^name:[[:space:]]+/ { name = $2 }
  END {
    if (path != "" && name == "ESPDisplaySender") print path
  }
')"
if [[ "$registered_paths" != "$APP" ]]; then
  echo "error: expected exactly one registered ESPDisplaySender path: $APP" >&2
  printf '%s\n' "$registered_paths" >&2
  exit 1
fi
echo "verified exactly one registered ESPDisplaySender path"

echo "built and Apple Development signed $APP"
echo "open manager:      open $APP"
echo "install at login:  $HERE/install-launch-agent.sh"
