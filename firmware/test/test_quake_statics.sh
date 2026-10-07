#!/usr/bin/env bash
# Keeps the Quake engine's relocation lists honest
# (firmware/quake/src/platform/quake_statics_lists.h):
#  - every relocated name has exactly one rename and one per-unit entry,
#  - every per-unit list is in QUAKE_STATICS_UNITS and names a vendored source,
#  - the generated engine_units/ wrappers match their generator.
# A rename without an allocator entry would leave a NULL pointer the engine
# dereferences on its first use; an entry without a rename would allocate
# storage nothing uses while the array stayed in internal RAM.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
QUAKE="$HERE/../quake"
python3 - "$QUAKE/src/platform/quake_statics_lists.h" "$QUAKE/src/engine" <<'PY'
import os, re, sys
header, engine = sys.argv[1], sys.argv[2]
text = open(header).read()
# Join macro continuation lines.
text = text.replace("\\\n", " ")
renames = re.findall(r"^#define (\w+) \(\*quake_(\w+)\)", text, re.M)
problems = []
for name, target in renames:
    if name != target:
        problems.append("rename %s points at quake_%s" % (name, target))
renamed = [n for n, _ in renames]
lists = {}
for unit, body in re.findall(r"^#define QUAKE_STATICS_(\w+)\(X\)(.*)$", text, re.M):
    if unit == "UNITS":
        continue
    lists[unit] = re.findall(r"X\((\w+), (PSRAM|INTERNAL)\)", body)
units = re.search(r"^#define QUAKE_STATICS_UNITS\(X\)(.*)$", text, re.M).group(1)
listed_units = re.findall(r"X\((\w+)\)", units)
entries = [n for unit in lists.values() for n, _ in unit]
for n in set(entries) | set(renamed):
    if entries.count(n) != 1:
        problems.append("%s has %d allocator entries" % (n, entries.count(n)))
    if renamed.count(n) != 1:
        problems.append("%s has %d renames" % (n, renamed.count(n)))
if sorted(lists) != sorted(listed_units):
    problems.append("QUAKE_STATICS_UNITS %s differs from the per-unit lists %s"
                    % (sorted(listed_units), sorted(lists)))
for unit, names in lists.items():
    src = os.path.join(engine, unit + ".c.inc")
    if not os.path.isfile(src):
        problems.append("unit %s has no engine source" % unit)
        continue
    body = open(src).read()
    for n, _ in names:
        # The definition must be in this unit, at file scope.
        # `type name[...];`, or the tail of an anonymous struct, `} name;`.
        if not re.search(r"^((static\s+)?[A-Za-z_][\w \t*]*\b|\}\s*)%s\s*[\[;]" % n,
                         body, re.M):
            problems.append("%s is not defined at file scope in %s.c" % (n, unit))
# No relocated name may also be declared inside a function or a struct (a
# local, parameter or member): the rename would turn it into an uninitialised
# pointer. Comments and strings are blanked first; brace depth decides scope.
# Code under #ifdef IDGODS counts as compiled, so enabling it stays safe.
relocated = set(entries)
decl = re.compile(
    r"(?:^|[;{(,])\s*(?:(?:static|const|unsigned|signed|struct|volatile|register)\s+)*"
    r"(?!(?:return|else|case|goto|sizeof|do)\b)[A-Za-z_]\w*[\s*]+((?:\**\s*\w+\s*(?:\[[^\]]*\])?\s*,\s*)*)\**\s*(\w+)\s*[\[;=,)]")
def strip(text):
    text = re.sub(r"/\*.*?\*/", lambda m: re.sub(r"[^\n]", " ", m.group(0)), text, flags=re.S)
    text = re.sub(r"//[^\n]*", "", text)
    text = re.sub(r'"(?:\\.|[^"\\\n])*"', '""', text)
    # Character literals too: '{' and '}' would throw the brace depth off.
    return re.sub(r"'(?:\\.|[^'\\\n])+'", "' '", text)
for name in sorted(os.listdir(engine)):
    if not name.endswith((".c.inc", ".h")):
        continue
    depth = 0
    for lineno, line in enumerate(strip(open(os.path.join(engine, name)).read()).split("\n"), 1):
        if line.lstrip().startswith("#"):
            continue
        if depth > 0 or "(" in line:
            for m in decl.finditer(line):
                names = re.findall(r"(\w+)\s*(?:\[[^\]]*\])?\s*,", m.group(1)) + [m.group(2)]
                for n in names:
                    if n in relocated and (depth > 0 or line.rstrip().endswith((")", ",")) and "(" in line):
                        problems.append("%s:%d declares relocated %s in a function or struct" % (name, lineno, n))
        depth = max(0, depth + line.count("{") - line.count("}"))
if problems:
    print("test_quake_statics: " + "\n  ".join(["FAILED"] + problems))
    sys.exit(1)
print("test_quake_statics: %d relocated arrays in %d units OK" % (len(entries), len(lists)))
PY
"$QUAKE/update_engine_units.sh" --check
echo "test_quake_statics: engine_units current"
