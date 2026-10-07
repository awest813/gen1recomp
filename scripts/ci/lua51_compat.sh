#!/usr/bin/env bash
# PUC Lua 5.1 compatibility gate for the browser build (docs/proposals/web-port.md).
#
# love.js runs PUC Lua 5.1 -- there is no LuaJIT in WebAssembly -- so code
# that only LuaJIT accepts either fails to load in the browser or, worse,
# loads and silently misbehaves.  This gate catches both classes:
#
#   1. every shipped Lua file must compile under luac5.1 (goto, 5.2+ syntax);
#      the Gen 3 importer files below still use goto and are allowlisted
#      until the Gen 3 web work removes it.
#   2. no \xHH or \u{...} string escapes outside comments: PUC 5.1 reads
#      "\xc3" as the literal text "xc3" with no error.  Use decimal escapes
#      ("\195"), which every Lua reads the same way.
#   3. the LuaCompat shim suite passes under lua5.1, where it actually patches
#      load().
#
#   scripts/ci/lua51_compat.sh        (needs luac5.1 + lua5.1 on PATH)

set -uo pipefail
cd "$(dirname "$0")/../.."

LUAC=${LUAC51:-luac5.1}
LUA=${LUA51:-lua5.1}
SHIPPED=(main.lua conf.lua src data mods tools/save-editor)

# Gen 3 importer files that still use goto (not loaded by the Gen 1 web build).
ALLOW_GOTO=(
  src/import/gba/battle_anim_extract.lua
  src/import/gba/door_anim_extract.lua
  src/import/gba/encounters_extract.lua
  src/import/gba/extract_map_events.lua
  src/import/gba/extract_scripts.lua
  src/import/gba/map_tree.lua
)

fail=0

for tool in "$LUAC" "$LUA"; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "missing $tool (apt-get install lua5.1)" >&2
    exit 2
  fi
done

echo "-- luac5.1 -p over shipped Lua"
total=0
bad=0
while IFS= read -r -d '' f; do
  total=$((total + 1))
  if ! out=$("$LUAC" -p "$f" 2>&1); then
    allowed=0
    for a in "${ALLOW_GOTO[@]}"; do [ "$f" = "$a" ] && allowed=1; done
    if [ "$allowed" = 0 ]; then
      echo "  $out"
      bad=$((bad + 1))
    fi
  fi
done < <(find "${SHIPPED[@]}" -name '*.lua' -print0 | sort -z)
echo "   $total files, $bad new failures (${#ALLOW_GOTO[@]} allowlisted)"
[ "$bad" = 0 ] || fail=1

echo "-- \\x / \\u{} string escapes"
# an odd run of backslashes before x/u{ is a real escape; skip comment lines
hits=$(grep -rnE --include='*.lua' '(^|[^\\])(\\\\)*\\(x[0-9a-fA-F]{2}|u\{)' "${SHIPPED[@]}" \
  | grep -vE '^[^:]+:[0-9]+:[[:space:]]*--' || true)
if [ -n "$hits" ]; then
  echo "$hits" | sed 's/^/  /'
  echo "   use decimal escapes instead (\"\\xc3\" -> \"\\195\")"
  fail=1
else
  echo "   none"
fi

echo "-- LuaCompat suite under lua5.1"
"$LUA" tests/engine/lua_compat_test.lua || fail=1

if [ "$fail" = 0 ]; then
  echo "lua 5.1 compat gate: PASS"
else
  echo "lua 5.1 compat gate: FAIL"
fi
exit "$fail"
