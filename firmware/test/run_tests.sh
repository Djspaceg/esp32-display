#!/bin/zsh
# Compile and run the firmware's host-side protocol tests.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mktemp -d)/test_band_protocol"
# Address + UB sanitizers, non-recovering: the suite feeds hostile inputs to
# parsers that run on the panel's network path (the RLE decoder above all),
# and a bounds fault that happens not to change the return value would
# otherwise pass. On the host this costs milliseconds and turns every stray
# read or write in a test into a hard failure.
clang++ -std=c++17 -Wall -Wextra -Werror \
  -fsanitize=address,undefined -fno-sanitize-recover=all \
  -o "$OUT" "$HERE/test_band_protocol.cpp"
"$OUT"
