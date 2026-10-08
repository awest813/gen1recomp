#!/usr/bin/env bash
# Browser build: game.love + a custom love.js (LÖVE 11.4 -> WebAssembly).
# See docs/proposals/web-port.md and ports/web/BUILD.md.
#
# Usage:
#   scripts/build_web.sh [--emsdk DIR] [--work DIR] [--out DIR]
#                        [--memory BYTES] [--split-mb N] [--skip-native]
#                        [--love FILE]
#
#   --emsdk DIR     emsdk checkout with 2.0.0 installed + activated
#                   (default: $EMSDK, else <work>/emsdk, installed on demand)
#   --work DIR      clones and build trees (default: .bazinga/work/web)
#   --out DIR       the deployable site (default: dist/web)
#   --memory BYTES  initial wasm heap (default 268435456; it grows on demand)
#   --split-mb N    split game.data into N MB parts for hosts with a per-file
#                   cap (scripts/split_web_build.py); 0 = off (default)
#   --skip-native   reuse the love.js/love.wasm already in <work>/native-out
#   --love FILE     package this game.love (e.g. the release workflow's
#                   version-stamped payload) instead of running pack_love.sh;
#                   the web trims below still apply to a copy of it
#
# Output: <out>/index.html, game.js, game.data, love.js, love.wasm.  Serve it
# over http(s) (python3 -m http.server -d dist/web) -- file:// will not load
# the wasm.  The compat (no-pthreads) build needs no COOP/COEP headers.
#
# Everything third-party is pinned below; the build verifies each checkout
# is at its pinned commit before using it.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/.bazinga/work/web"
OUT="$ROOT/dist/web"
MEMORY=268435456
SPLIT_MB=0
SKIP_NATIVE=0
LOVE_INPUT=""
EMSDK_DIR="${EMSDK:-}"

# --- pins -------------------------------------------------------------------
EMSDK_VERSION="2.0.0"   # love.js needs 2.0.x (newer drop getMemory)
# the emsdk installer itself (not the SDK it installs): pinned so a future
# emsdk that drops old SDK downloads can't break a cold build
EMSDK_REPO="https://github.com/emscripten-core/emsdk"
EMSDK_COMMIT="b44154299bdefe75ba287874bb63fc9806243771"
LOVEJS_REPO="https://github.com/Davidobot/love.js"
LOVEJS_COMMIT="c4f04e185033a7c9fbefa9be3bec88c41a90421b"
MEGASOURCE_REPO="https://github.com/Davidobot/megasource"
MEGASOURCE_COMMIT="3bc0b46670a2912c02c54c6977b9510e64e89023"
LOVE_REPO="https://github.com/Davidobot/love"
LOVE_COMMIT="32e0716b43a51686f5fa9ac04ca08b6410b698a5"
# emscripten 2.0.0's SDL2 port, fetched with git instead of the port's GitHub
# archive zip and handed to emcc through EMCC_LOCAL_PORTS.
SDL2_REPO="https://github.com/emscripten-ports/SDL2"
SDL2_TAG="version_22"
SDL2_COMMIT="7e3e23093496fb81759cf8c249a5249075d38395"

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --emsdk) EMSDK_DIR="$2"; shift 2 ;;
    --work) WORK="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --memory) MEMORY="$2"; shift 2 ;;
    --split-mb) SPLIT_MB="$2"; shift 2 ;;
    --skip-native) SKIP_NATIVE=1; shift ;;
    --love) LOVE_INPUT="$2"; shift 2 ;;
    -h|--help) sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

case "$MEMORY" in ''|*[!0-9]*) fail "--memory must be a byte count, got '$MEMORY'" ;; esac
case "$SPLIT_MB" in ''|*[!0-9]*) fail "--split-mb must be a whole number, got '$SPLIT_MB'" ;; esac

mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd)"
NATIVE_OUT="$WORK/native-out"

# clone_at DIR REPO COMMIT [BRANCH]: shallow-clone (or reuse) DIR at COMMIT.
clone_at() {
  local dir="$1" repo="$2" commit="$3" branch="${4:-}"
  if [ ! -d "$dir/.git" ]; then
    if [ -n "$branch" ]; then
      git clone -q --depth 50 -b "$branch" "$repo" "$dir"
    else
      git clone -q --depth 50 "$repo" "$dir"
    fi
  fi
  if [ "$(git -C "$dir" rev-parse HEAD)" != "$commit" ]; then
    git -C "$dir" fetch -q --depth 50 origin "$commit" 2>/dev/null || true
    # -f and clean: a restored CI cache (restore-keys) or an earlier run left
    # the tree patched by patch_love.py, with its .orig copies and added
    # files; a pin bump must start from the pristine new commit.  Single -f
    # clean leaves nested repos (megasource/libs/love) alone.
    git -C "$dir" checkout -qf "$commit" \
      || fail "$dir: cannot check out pinned commit $commit"
    git -C "$dir" clean -qfdx
  fi
  [ "$(git -C "$dir" rev-parse HEAD)" = "$commit" ] \
    || fail "$dir is not at pinned commit $commit"
}

# --- native: love.js with LuaBitOp + the lovejs bridge ------------------------
build_native() {
  command -v cmake >/dev/null || fail "cmake is required"
  command -v python3 >/dev/null || fail "python3 is required"

  if [ -z "$EMSDK_DIR" ]; then
    EMSDK_DIR="$WORK/emsdk"
    if [ ! -x "$EMSDK_DIR/emsdk" ]; then
      say "installing emsdk $EMSDK_VERSION into $EMSDK_DIR"
      git clone -q --depth 50 "$EMSDK_REPO" "$EMSDK_DIR"
    fi
    clone_at "$EMSDK_DIR" "$EMSDK_REPO" "$EMSDK_COMMIT"
    "$EMSDK_DIR/emsdk" install "$EMSDK_VERSION" >/dev/null
    "$EMSDK_DIR/emsdk" activate "$EMSDK_VERSION" >/dev/null
  fi
  [ -f "$EMSDK_DIR/emsdk_env.sh" ] || fail "no emsdk at $EMSDK_DIR"
  # emsdk_env.sh puts emsdk's own (old) node and python first on PATH; keep
  # that to the native build so packaging below uses the system node/npm
  local saved_path="$PATH"
  # shellcheck disable=SC1091
  source "$EMSDK_DIR/emsdk_env.sh" >/dev/null 2>&1
  command -v emcc >/dev/null || fail "emcc not on PATH after sourcing emsdk_env.sh"
  emcc --version | head -1 | grep -q " $EMSDK_VERSION " \
    || fail "emsdk at $EMSDK_DIR is not $EMSDK_VERSION: $(emcc --version | head -1)"

  say "fetching pinned sources"
  clone_at "$WORK/megasource" "$MEGASOURCE_REPO" "$MEGASOURCE_COMMIT" emscripten
  clone_at "$WORK/megasource/libs/love" "$LOVE_REPO" "$LOVE_COMMIT" emscripten
  clone_at "$WORK/SDL2" "$SDL2_REPO" "$SDL2_COMMIT" "$SDL2_TAG"

  say "patching LÖVE (ports/web/patch_love.py)"
  python3 "$ROOT/ports/web/patch_love.py" "$WORK/megasource/libs/love"

  say "building love.js (compat, no pthreads)"
  local build="$WORK/build/compat"
  mkdir -p "$build"
  export EMCC_LOCAL_PORTS="sdl2=$WORK/SDL2"
  (
    cd "$build"
    # DISABLE_EXCEPTION_CATCHING=0 at *compile* time, not just link time:
    # LÖVE reports failures (a missing file, a bad image) as C++ exceptions
    # that luax_catchexcept turns into Lua errors.  Upstream love.js only
    # passes the flag to the linker, so those exceptions are never caught and
    # unwind straight through Lua's pcall -- the engine's guarded
    # love.filesystem.read("build-info.json") at conf time aborted conf.lua.
    emcmake cmake "$WORK/megasource" -DLOVE_JIT=0 -DCMAKE_BUILD_TYPE=Release \
      -DLOVEJS_COMPAT=1 -DSEXPORT_ALL=1 -DSMAIN_MODULE=1 \
      -DSERROR_ON_UNDEFINED_SYMBOLS=0 \
      "-DCMAKE_C_FLAGS=-s DISABLE_EXCEPTION_CATCHING=0" \
      "-DCMAKE_CXX_FLAGS=-s DISABLE_EXCEPTION_CATCHING=0" >/dev/null
    # megasource builds zlib's shared and static targets into the same
    # libz.a, which races under -j; a serial pass finishes what is left
    emmake make -j"$(nproc 2>/dev/null || echo 4)" \
      || { echo "parallel make failed; retrying serially" >&2; emmake make -j1; }
  )
  mkdir -p "$NATIVE_OUT"
  cp "$build/love/love.js" "$build/love/love.wasm" "$NATIVE_OUT/"
  export PATH="$saved_path"
  unset EMSDK EMSDK_NODE EMSDK_PYTHON EM_CONFIG EM_CACHE EMCC_LOCAL_PORTS
}

if [ "$SKIP_NATIVE" -eq 0 ]; then
  build_native
fi
[ -f "$NATIVE_OUT/love.js" ] && [ -f "$NATIVE_OUT/love.wasm" ] \
  || fail "no love.js/love.wasm in $NATIVE_OUT (run without --skip-native)"

# --- payload ---------------------------------------------------------------
LOVE_FILE="$WORK/game.love"
if [ -n "$LOVE_INPUT" ]; then
  [ -f "$LOVE_INPUT" ] || fail "--love: no such file $LOVE_INPUT"
  say "using $LOVE_INPUT"
  cp "$LOVE_INPUT" "$LOVE_FILE"
else
  say "packing game.love"
  "$ROOT/scripts/pack_love.sh" --output "$LOVE_FILE" --listing "$WORK/love-listing.txt" >/dev/null
fi
# Trim what the browser never loads -- every byte here is downloaded and held
# in memory before the game starts:
#   * the launcher videos (no Theora worker thread in the compat build;
#     LauncherSplash/LauncherThemeVideo skip them on Web)
#   * the cart-label Photoshop sources (~14 MB; only the .png exports load)
#   * the store/app-icon cover art (packaging scripts read it; the game never)
zip -q -d "$LOVE_FILE" 'assets/launcher/*.ogv' >/dev/null 2>&1 || true
zip -q -d "$LOVE_FILE" 'assets/labels/*.psd' >/dev/null 2>&1 || true
zip -q -d "$LOVE_FILE" 'assets/logo/gen1recomp_cover.png' >/dev/null 2>&1 || true
say "game.love: $(du -h "$LOVE_FILE" | cut -f1)"

# --- page -----------------------------------------------------------------
say "packaging the site with love.js's packager"
clone_at "$WORK/lovejs" "$LOVEJS_REPO" "$LOVEJS_COMMIT"
if [ ! -d "$WORK/lovejs/node_modules" ]; then
  (cd "$WORK/lovejs" && npm ci --silent --no-audit --no-fund)
fi
cp "$NATIVE_OUT/love.js" "$NATIVE_OUT/love.wasm" "$WORK/lovejs/src/compat/"
rm -rf "$OUT"
mkdir -p "$OUT"
node "$WORK/lovejs/index.js" -c -t "G1R Deluxe" -m "$MEMORY" "$LOVE_FILE" "$OUT" >/dev/null
rm -rf "$OUT/theme"
sed "s/__G1R_MEMORY__/$MEMORY/" "$ROOT/ports/web/shell/index.html" > "$OUT/index.html"
cp "$ROOT/ports/web/shell/manifest.webmanifest" "$ROOT/ports/web/shell/"*.png "$OUT/"

if [ "$SPLIT_MB" -gt 0 ]; then
  python3 "$ROOT/scripts/split_web_build.py" "$OUT" --chunk-size-mb "$SPLIT_MB"
fi

# --- verify ---------------------------------------------------------------
for f in index.html game.js love.js love.wasm manifest.webmanifest icon-192.png; do
  [ -f "$OUT/$f" ] || fail "site is missing $f"
done
grep -q "__G1R_MEMORY__" "$OUT/index.html" && fail "index.html memory placeholder not rendered"
# grep a materialized listing: `unzip | grep -q` under pipefail SIGPIPEs unzip
# on the first match and turns a hit into a pass
unzip -Z1 "$LOVE_FILE" > "$WORK/web-listing.txt"
if grep -Eq '^(data|assets)/generated/.' "$WORK/web-listing.txt"; then
  fail "game.love contains generated ROM data"
fi

say "site: $OUT ($(du -sh "$OUT" | cut -f1))"
say "serve it with: python3 -m http.server -d \"$OUT\" 8000"
