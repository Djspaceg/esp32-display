#!/bin/zsh
# Build ESPDisplayAudio.driver into mac/AudioDriver/build and sign it with the
# same Apple Development identity the app is signed with (the project's
# DEVELOPMENT_TEAM; see make-app.sh). Needs no admin rights: installing is a
# separate step, install-driver.sh, run with sudo.
#
# ESPDISP_SIGN_IDENTITY names a different identity, by name or SHA-1, when the
# keychain holds more than one for the team.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PROJECT_FILE="$HERE/../ESPDisplaySender/ESPDisplaySender.xcodeproj/project.pbxproj"
OUT="$HERE/build"
BUNDLE="$OUT/ESPDisplayAudio.driver"
SCRATCH="$OUT/.ESPDisplayAudio.driver.partial"

TEAM="$(sed -n 's/.*DEVELOPMENT_TEAM = \([A-Z0-9]*\);.*/\1/p' "$PROJECT_FILE" | sort -u)"
if [[ -z "$TEAM" || "$TEAM" == *$'\n'* ]]; then
  echo "error: expected one DEVELOPMENT_TEAM in $PROJECT_FILE, found: ${TEAM:-none}" >&2
  exit 1
fi

mkdir -p "$OUT"
rm -rf -- "$SCRATCH"
mkdir -p "$SCRATCH/Contents/MacOS"
cp "$HERE/Info.plist" "$SCRATCH/Contents/Info.plist"
plutil -lint "$SCRATCH/Contents/Info.plist" >/dev/null

clang -std=c11 -O2 -Wall -Wextra -Werror \
  -arch arm64 -arch x86_64 -mmacosx-version-min=13.0 \
  -bundle -fvisibility=hidden \
  -framework CoreAudio -framework CoreFoundation \
  -o "$SCRATCH/Contents/MacOS/ESPDisplayAudio" \
  "$HERE/ESPDisplayAudio.c"

# Sign with each Apple Development identity until one carries the app's team.
team_of() {
  codesign -dv "$1" 2>&1 | sed -n 's/^TeamIdentifier=//p'
}
signed=""
if [[ -n "${ESPDISP_SIGN_IDENTITY:-}" ]]; then
  candidates=("$ESPDISP_SIGN_IDENTITY")
else
  candidates=("${(@f)$(security find-identity -v -p codesigning \
    | sed -n 's/^ *[0-9]*) \([0-9A-F]\{40\}\) "Apple Development: .*"$/\1/p')}")
fi
for identity in "${candidates[@]}"; do
  [[ -n "$identity" ]] || continue
  codesign --force --sign "$identity" --timestamp=none "$SCRATCH" >/dev/null 2>&1 || continue
  if [[ "$(team_of "$SCRATCH")" == "$TEAM" ]]; then
    signed="$identity"
    break
  fi
done
if [[ -z "$signed" ]]; then
  echo "error: no Apple Development identity for team $TEAM signed the driver" >&2
  exit 1
fi
codesign --verify --strict --verbose=1 "$SCRATCH"

rm -rf -- "$BUNDLE"
mv -- "$SCRATCH" "$BUNDLE"
codesign -dv --verbose=2 "$BUNDLE" 2>&1 | grep -E '^(Identifier|Authority|TeamIdentifier)='
echo "built $BUNDLE"
echo "install (needs admin): sudo $HERE/install-driver.sh"
