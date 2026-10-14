#!/bin/zsh
# Build ESPDisplayAudio.driver into mac/AudioDriver/build and sign it with the
# same Apple Development identity the app is signed with (the project's
# DEVELOPMENT_TEAM; see make-app.sh). Needs no admin rights: installing is a
# separate step, install-driver.sh, run with sudo. For developers: the app
# carries its own copy (embed-driver.sh) and installs it from its Audio
# section.
#
# ESPDISP_SIGN_IDENTITY names a different identity, by name or SHA-1, when the
# keychain holds more than one for the team.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PROJECT_FILE="$HERE/../ESPDisplaySender/ESPDisplaySender.xcodeproj/project.pbxproj"
OUT="$HERE/build"
BUNDLE="$OUT/ESPDisplayAudio.driver"

TEAM="$(sed -n 's/.*DEVELOPMENT_TEAM = \([A-Z0-9]*\);.*/\1/p' "$PROJECT_FILE" | sort -u)"
if [[ -z "$TEAM" || "$TEAM" == *$'\n'* ]]; then
  echo "error: expected one DEVELOPMENT_TEAM in $PROJECT_FILE, found: ${TEAM:-none}" >&2
  exit 1
fi

mkdir -p "$OUT"
# Compiled under its final name inside a scratch folder, then moved into
# place once signed, so build/ never holds a half-built driver.
SCRATCH_DIR="$OUT/.partial"
SCRATCH="$SCRATCH_DIR/ESPDisplayAudio.driver"
rm -rf -- "$SCRATCH_DIR"
mkdir -p "$SCRATCH_DIR"
"$HERE/compile-driver.sh" "$SCRATCH"

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
rmdir "$SCRATCH_DIR"
codesign -dv --verbose=2 "$BUNDLE" 2>&1 | grep -E '^(Identifier|Authority|TeamIdentifier)='
echo "built $BUNDLE"
echo "install (needs admin): sudo $HERE/install-driver.sh"
