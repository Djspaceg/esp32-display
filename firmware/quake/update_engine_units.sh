#!/usr/bin/env bash
# Regenerate src/engine_units/: one wrapper unit per vendored engine source.
#
# Each upstream quakegeneric .c lives in src/engine/ as <name>.c.inc so Arduino
# does not compile it bare (it would compile it into every family's image, and
# without the prelude's relocations and renames). Its wrapper compiles it only
# into images that carry the Quake runtime, after platform/quake_prelude.h,
# and appends the allocator for the arrays it defines when
# platform/quake_statics_lists.h lists any. Run after adding or removing an engine
# source or changing the per-unit lists; --check reports drift without writing.
set -euo pipefail
cd "$(dirname "$0")/src"
check=0
[ "${1:-}" = "--check" ] && check=1
stale=0
expected=$(mktemp -d "${TMPDIR:-/tmp}/quake-units.XXXXXX")
trap 'rm -rf "$expected"' EXIT
for source in engine/*.c.inc; do
  name=$(basename "$source" .c.inc)
  alloc=""
  if grep -q "QUAKE_STATICS_${name}(X)" platform/quake_statics_lists.h; then
    alloc="QUAKE_DEFINE_STATICS_ALLOCATOR(${name})
"
  fi
  cat > "$expected/qe_${name}.c" <<EOF
// Compiles the vendored engine source ${name}.c (engine/${name}.c.inc) as its own
// unit. Written by firmware/quake/update_engine_units.sh; do not edit.
#include "../quake_build.h"
#if defined(ESPDISP_QUAKE_RUNTIME)
#include "../platform/quake_prelude.h"
#include "../engine/${name}.c.inc"
${alloc}#endif
EOF
done
mkdir -p engine_units
for unit in "$expected"/*.c engine_units/*.c; do
  [ -e "$unit" ] || continue
  base=$(basename "$unit")
  if ! cmp -s "$expected/$base" "engine_units/$base" 2>/dev/null; then
    stale=1
    echo "stale: engine_units/$base"
    if [ "$check" = 0 ]; then
      if [ -e "$expected/$base" ]; then cp "$expected/$base" "engine_units/$base"
      else rm -f "engine_units/$base"; fi
    fi
  fi
done
[ "$check" = 1 ] && [ "$stale" = 1 ] && exit 1
exit 0
