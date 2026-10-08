#!/usr/bin/env bash
# PUC Lua 5.1 compatibility gate for the browser build (docs/proposals/web-port.md).
#
# love.js runs PUC Lua 5.1 -- there is no LuaJIT in WebAssembly -- so code
# that only LuaJIT accepts either fails to load in the browser or, worse,
# loads and silently misbehaves.  This gate catches both classes:
#
#   1. every shipped Lua file must compile under luac5.1 (no goto, no 5.2+
#      syntax).  A file that fails here is reported by require() in the
#      browser as "module not found", which hides the real cause.
#   2. no \xHH or \u{...} escapes in quoted strings: PUC 5.1 reads
#      "\xc3" as the literal text "xc3" with no error.  Use decimal escapes
#      ("\195"), which every Lua reads the same way.
#   3. the LuaCompat shim suite passes under lua5.1, where it actually patches
#      load(), and the Web platform-profile suite (which loads main.lua and
#      drives love.run) passes under the interpreter the browser runs.
#
#   scripts/ci/lua51_compat.sh        (needs luac5.1 + lua5.1 on PATH)

set -uo pipefail
cd "$(dirname "$0")/../.."

LUAC=${LUAC51:-luac5.1}
LUA=${LUA51:-lua5.1}
SHIPPED=(main.lua conf.lua src data mods tools/save-editor)

# Files allowed to fail luac5.1 (none: the Gen 3 importer's goto loops were
# rewritten as repeat/until because the launcher loads them at boot).
ALLOW_GOTO=()

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
    for a in "${ALLOW_GOTO[@]+"${ALLOW_GOTO[@]}"}"; do [ "$f" = "$a" ] && allowed=1; done
    if [ "$allowed" = 0 ]; then
      echo "  $out"
      bad=$((bad + 1))
    fi
  fi
done < <(find "${SHIPPED[@]}" -name '*.lua' -print0 | sort -z)
echo "   $total files, $bad new failures (${#ALLOW_GOTO[@]} allowlisted)"
[ "$bad" = 0 ] || fail=1

echo "-- \\x / \\u{} string escapes"
# a small lexer: only quoted strings count (comments and [[long strings]]
# take backslashes literally)
if find "${SHIPPED[@]}" -name '*.lua' -print0 | sort -z \
    | xargs -0 "$LUA" scripts/ci/lua_escape_scan.lua; then
  echo "   none"
else
  echo "   use decimal escapes instead (\"\\xc3\" -> \"\\195\")"
  fail=1
fi

echo "-- suites under lua5.1"
"$LUA" tests/engine/lua_compat_test.lua || fail=1
"$LUA" tests/engine/web_profile_test.lua || fail=1
"$LUA" tests/engine/chip_audio_web_test.lua || fail=1
"$LUA" tests/engine/touch_web_activation_test.lua || fail=1
"$LUA" tests/engine/gen3_sequential_version_pin_test.lua || fail=1
"$LUA" tests/engine/gen3_bg_affine_f32_test.lua || fail=1
"$LUA" tests/engine/fixed_step_sustained_catchup_test.lua || fail=1
"$LUA" tests/engine/fetch_web_transport_test.lua || fail=1

if [ "$fail" = 0 ]; then
  echo "lua 5.1 compat gate: PASS"
else
  echo "lua 5.1 compat gate: FAIL"
fi
exit "$fail"
