#!/usr/bin/env bash
# Fetch the shareware game data into the ignored paths the tooling reads:
#
#   doom   firmware/doom/doom1.wad       Doom shareware v1.9 doom1.wad
#          (tools/espdisp.py puts it in every S3 and P4 bundle)
#   quake  firmware/quake/id1/pak0.pak   Quake shareware v1.06 id1/pak0.pak
#          (tools/espdisp.py write-data quake_pak writes it to a P4 board)
#
# Every file is checked against a pinned size and SHA-256 before it is moved
# into place, and is downloaded and unpacked in a work directory beside its
# target so the final move is atomic. A file that is already there is checked,
# never overwritten unless it fails the check and --force is given.
#
# Needs only curl, bsdtar (macOS's tar) and shasum or sha256sum. bsdtar reads
# the LHA archives inside id's original zips.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)

DOOM_TARGET="$REPO_ROOT/firmware/doom/doom1.wad"
DOOM_SIZE=4196020
DOOM_SHA256=1d7d43be501e67d927e415e0b8f3e29c3bf33075e859721816f652a526cac771

QUAKE_TARGET="$REPO_ROOT/firmware/quake/id1/pak0.pak"
QUAKE_SIZE=18689235
QUAKE_SHA256=35a9c55e5e5a284a159ad2a62e0e8def23d829561fe2f54eb402dbc0a9a946af

# "description|kind|url". kind says how the file comes out of the download:
#   raw       the download is the file
#   doom19s   doom19s.zip: DOOMS_19.1 + DOOMS_19.2 are one LHA holding DOOM1.WAD
#   quake106  quake106.zip: resource.1 is an LHA holding ID1/PAK0.PAK
#   sdltgz    quakesw-1.0.6.tar.gz holding id1/pak0.pak
DOOM_MIRRORS=(
  "ftp.gwdg.de, id Software's original doom19s.zip|doom19s|https://ftp.gwdg.de/pub/misc/ftp.idsoftware.com/idstuff/doom/doom19s.zip"
  "gamers.org idgames, id Software's original doom19s.zip|doom19s|https://www.gamers.org/pub/idgames/idstuff/doom/doom19s.zip"
  "GitHub nneonneo/universal-doom, doom1.wad alone|raw|https://raw.githubusercontent.com/nneonneo/universal-doom/main/DOOM1.WAD"
)
QUAKE_MIRRORS=(
  "ftp.gwdg.de, id Software's original quake106.zip|quake106|https://ftp.gwdg.de/pub/misc/ftp.idsoftware.com/idstuff/quake/quake106.zip"
  "gamers.org idgames, id Software's original quake106.zip|quake106|https://www.gamers.org/pub/idgames/idstuff/quake/quake106.zip"
  "libsdl.org, quakesw-1.0.6.tar.gz|sdltgz|https://www.libsdl.org/projects/quake/data/quakesw-1.0.6.tar.gz"
)

usage() {
  cat <<'EOF'
usage: tools/fetch_game_data.sh [--game doom|quake|both] [--doom-mirror N]
                                [--quake-mirror N] [--force] [--list]

Fetch the shareware Doom doom1.wad and/or Quake id1/pak0.pak into the repo's
ignored data paths, checking each against a pinned size and SHA-256.

  --game G          doom, quake or both (asked when omitted on a terminal)
  --doom-mirror N   which Doom mirror to use (see --list; asked when omitted
                    on a terminal, otherwise 1)
  --quake-mirror N  which Quake mirror to use, likewise
  --force           replace a file that is present but fails its check
  --list            print the mirrors and exit
EOF
}

die() { echo "fetch_game_data: $*" >&2; exit 1; }

list_mirrors() {
  local name=$1 i=1 entry
  shift
  echo "$name mirrors:"
  for entry in "$@"; do
    echo "  $i) ${entry%%|*}"
    echo "     ${entry##*|}"
    i=$((i + 1))
  done
}

# stderr, not stdout: the mirror prompt runs inside $(...).
interactive() { [ -t 0 ] && [ -t 2 ]; }

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | cut -d' ' -f1
  else
    sha256sum "$1" | cut -d' ' -f1
  fi
}

size_of() { wc -c < "$1" | tr -d ' '; }

# matches FILE SIZE SHA256: exit 0 only for the exact pinned bytes.
matches() {
  [ -f "$1" ] && [ "$(size_of "$1")" = "$2" ] && [ "$(sha256_of "$1")" = "$3" ]
}

bsdtar_cmd() {
  if command -v bsdtar >/dev/null 2>&1; then
    echo bsdtar
  elif tar --version 2>/dev/null | grep -q bsdtar; then
    echo tar
  else
    die "unpacking this mirror needs bsdtar (libarchive); pick the raw mirror or install it"
  fi
}

# extract KIND DOWNLOAD OUT WORK: write the wanted file from DOWNLOAD to OUT.
extract() {
  local kind=$1 download=$2 out=$3 work=$4 tar
  case $kind in
    raw) mv "$download" "$out"; return ;;
  esac
  tar=$(bsdtar_cmd) || return 1
  case $kind in
    doom19s)
      "$tar" -xOf "$download" DOOMS_19.1 > "$work/dooms.lha"
      "$tar" -xOf "$download" DOOMS_19.2 >> "$work/dooms.lha"
      "$tar" -xOf "$work/dooms.lha" DOOM1.WAD > "$out"
      ;;
    quake106)
      "$tar" -xOf "$download" resource.1 > "$work/resource.1"
      "$tar" -xOf "$work/resource.1" ID1/PAK0.PAK > "$out"
      ;;
    sdltgz)
      "$tar" -xOf "$download" id1/pak0.pak > "$out"
      ;;
    *) die "unknown mirror kind $kind" ;;
  esac
}

# choose_mirror NAME PRESET ENTRIES...: print the chosen entry.
choose_mirror() {
  local name=$1 preset=$2 count choice
  shift 2
  count=$#
  choice=$preset
  if [ -z "$choice" ]; then
    if interactive; then
      list_mirrors "$name" "$@" >&2
      read -r -p "Download $name from which mirror? [1-$count, default 1] " choice
    fi
    choice=${choice:-1}
  fi
  case $choice in
    ''|*[!0-9]*) die "$name mirror must be a number from 1 to $count" ;;
  esac
  [ "$choice" -ge 1 ] && [ "$choice" -le "$count" ] ||
    die "$name mirror must be a number from 1 to $count"
  shift $((choice - 1))
  echo "$1"
}

# fetch NAME TARGET SIZE SHA256 PRESET MIRRORS...
fetch() {
  local name=$1 target=$2 size=$3 sha=$4 preset=$5 entry desc kind url dir work
  shift 5
  local rel=${target#"$REPO_ROOT"/}
  if [ -e "$target" ]; then
    if matches "$target" "$size" "$sha"; then
      echo "$name: $rel is already present and verified ($size bytes, sha256 $sha)"
      return
    fi
    if [ "$FORCE" != 1 ]; then
      die "$name: $rel is present but is not the pinned file (want $size bytes, sha256 $sha); rerun with --force to replace it"
    fi
    echo "$name: $rel fails its check; --force given, replacing it"
  fi

  entry=$(choose_mirror "$name" "$preset" "$@")
  desc=${entry%%|*}
  kind=${entry#*|}; kind=${kind%%|*}
  url=${entry##*|}
  dir=$(dirname "$target")
  mkdir -p "$dir"
  work=$(mktemp -d "$dir/.fetch-XXXXXX")
  WORK_DIRS+=("$work")

  echo "$name: downloading from $desc"
  echo "  $url"
  curl --fail --location --proto '=https' --proto-redir '=https' \
    --retry 2 --connect-timeout 20 --progress-bar \
    -o "$work/download" "$url" || die "$name: download failed from $url"
  extract "$kind" "$work/download" "$work/file" "$work" ||
    die "$name: could not unpack the download from $url"

  local got_size got_sha
  got_size=$(size_of "$work/file")
  got_sha=$(sha256_of "$work/file")
  if [ "$got_size" != "$size" ] || [ "$got_sha" != "$sha" ]; then
    die "$name: the file from $url is $got_size bytes, sha256 $got_sha; want $size bytes, sha256 $sha. Nothing was written; try another mirror."
  fi
  mv -f "$work/file" "$target"
  echo "$name: wrote $rel ($size bytes, sha256 $sha)"
}

GAME=""
DOOM_PRESET=""
QUAKE_PRESET=""
FORCE=0
while [ $# -gt 0 ]; do
  case $1 in
    --game) [ $# -ge 2 ] || die "--game needs doom, quake or both"; GAME=$2; shift 2 ;;
    --game=*) GAME=${1#*=}; shift ;;
    --doom-mirror) [ $# -ge 2 ] || die "--doom-mirror needs a number"; DOOM_PRESET=$2; shift 2 ;;
    --doom-mirror=*) DOOM_PRESET=${1#*=}; shift ;;
    --quake-mirror) [ $# -ge 2 ] || die "--quake-mirror needs a number"; QUAKE_PRESET=$2; shift 2 ;;
    --quake-mirror=*) QUAKE_PRESET=${1#*=}; shift ;;
    --force) FORCE=1; shift ;;
    --list)
      list_mirrors Doom "${DOOM_MIRRORS[@]}"
      list_mirrors Quake "${QUAKE_MIRRORS[@]}"
      exit 0 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done

if [ -z "$GAME" ]; then
  interactive || die "pass --game doom, quake or both"
  echo "Which game data?"
  echo "  1) doom   shareware doom1.wad, 4.0 MB"
  echo "  2) quake  shareware id1/pak0.pak, 17.8 MB"
  echo "  3) both"
  read -r -p "Choose [1-3, default 3] " answer
  case ${answer:-3} in
    1|doom) GAME=doom ;;
    2|quake) GAME=quake ;;
    3|both) GAME=both ;;
    *) die "choose 1, 2 or 3" ;;
  esac
fi
case $GAME in
  doom|quake|both) ;;
  *) die "--game must be doom, quake or both, not $GAME" ;;
esac

WORK_DIRS=()
cleanup() {
  local dir
  for dir in ${WORK_DIRS[@]+"${WORK_DIRS[@]}"}; do rm -rf "$dir"; done
}
trap cleanup EXIT

if [ "$GAME" = doom ] || [ "$GAME" = both ]; then
  fetch Doom "$DOOM_TARGET" "$DOOM_SIZE" "$DOOM_SHA256" "$DOOM_PRESET" \
    "${DOOM_MIRRORS[@]}"
fi
if [ "$GAME" = quake ] || [ "$GAME" = both ]; then
  fetch Quake "$QUAKE_TARGET" "$QUAKE_SIZE" "$QUAKE_SHA256" "$QUAKE_PRESET" \
    "${QUAKE_MIRRORS[@]}"
fi
