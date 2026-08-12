#!/bin/zsh
# Copy the default firmware bundle into the app being built, if there is one.
#
# Run as a build phase, before Xcode signs the app, so the signature covers the
# file. Copying it into an already-signed bundle afterwards would break the
# signature and re-signing would have to reproduce the Apple Development identity
# make-app.sh deliberately preserves.
#
# WHY THE APP CARRIES FIRMWARE AT ALL: a .espdispfw can only come from
# `tools/espdisp.py bundle`, so a first-run flow that asks the user for one asks
# them to open a terminal. Adding a brand-new board is supposed to work without
# that. `mac/make-app.sh` builds the bundle and puts it where this finds it;
# `BundledFirmware` in the app reads it back out of Resources.
#
# ABSENCE IS NOT AN ERROR, and that is the point of doing this in a script phase
# rather than as a file reference in the project: bundles are gitignored build
# output (a couple of megabytes that any checkout can rebuild), so a fresh clone
# has none. A referenced-but-missing file fails the Xcode build with "Build input
# file cannot be found"; this leaves a note in the log and exits 0, and the app's
# Add Display sheet asks for a file instead.
set -euo pipefail

# The name the app looks for. One string in one place: BundledFirmware.resourceName
# in Sources/SenderCore/BundledFirmware.swift is asserted against this spelling by
# testTheResourceNameIsWhatTheScriptInstalls.
BUNDLE_NAME="espdisp-default.espdispfw"

# SRCROOT is the directory holding the xcodeproj (mac/ESPDisplaySender), so the
# source and destination are both derived from Xcode's own environment rather than
# from where this script happens to be.
SOURCE="${SRCROOT:?SRCROOT is not set - this runs as an Xcode build phase}/Resources/$BUNDLE_NAME"
DESTINATION_DIR="${CODESIGNING_FOLDER_PATH:?CODESIGNING_FOLDER_PATH is not set}/Contents/Resources"

if [[ ! -f "$SOURCE" ]]; then
  echo "note: no default firmware bundle at $SOURCE - the app will ask for one."
  # Any stale copy from an earlier build goes too, so "no bundle here" cannot be
  # answered by a bundle from three builds ago.
  rm -f -- "$DESTINATION_DIR/$BUNDLE_NAME"
  exit 0
fi

mkdir -p "$DESTINATION_DIR"
# ditto rather than cp: it is what the rest of this repo's packaging uses and it
# replaces the destination wholesale rather than merging into it.
ditto "$SOURCE" "$DESTINATION_DIR/$BUNDLE_NAME"
# espdisp.py writes its output 0600, and ditto preserves the mode, which would ship
# an app whose firmware only the person who packaged it can read. Resources are
# world-readable like every other file in the bundle.
chmod 644 "$DESTINATION_DIR/$BUNDLE_NAME"
echo "embedded $(basename "$SOURCE") ($(stat -f %z "$SOURCE") bytes)"
