#!/bin/zsh
# Compile and run the firmware's host-side protocol tests.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mktemp -d)/test_band_protocol"
clang++ -std=c++17 -Wall -Wextra -Werror -o "$OUT" "$HERE/test_band_protocol.cpp"
"$OUT"
