#!/usr/bin/env python3
"""Applies gen1recomp's browser patches to a love.js LÖVE source tree
(Davidobot/love, `emscripten` branch, pinned in scripts/build_web.sh).

Idempotent and re-appliable, like mobile/ios/patch_love_src.py: the first run
stashes a pristine `.orig` copy of every file it rewrites and later runs start
over from that copy, so editing the patch content here takes effect on the
next build with no manual restore.

What it does:
  1. Copies ports/web/native/ (LuaBitOp's bit.c, lovejs_bridge.cpp) into
     src/libraries/g1rweb/.
  2. Adds a love_3p_g1rweb static library to CMakeLists.txt and links it into
     liblove, next to love_3p_lua53.
  3. Preloads `bit` (LuaBitOp; LuaJIT builds have it built in, PUC Lua does
     not) and `lovejs` (the picker/storage bridge) in modules/love/love.cpp.
  4. Lets Canvases be RGBA8 on WebGL (graphics/opengl/OpenGL.cpp).  LÖVE
     only trusts an RGBA8 render target on GLES2 when OES_rgb8_rgba8 is
     reported; WebGL 1 guarantees RGBA/UNSIGNED_BYTE is colour-renderable but
     never reports that name, so every Canvas -- the 160x144 game canvas
     included -- silently became RGBA4 (16 levels per channel).

  5. Stops love.js alerting on every love::Exception (common/Exception.cpp).
     Its constructor ran alert("An error occurred before the game window
     could be initialised...") and printed the message for *every*
     exception, including the ones luax_catchexcept turns straight into a
     caught Lua error -- so each probe for a file that may not exist (the
     launcher checks every version's rom-cache.complete at boot) popped a
     blocking dialog.  Real failures still reach Lua and the game's error
     screen.

Usage: patch_love.py <path/to/love>
"""

import shutil
import sys
from pathlib import Path

WEB_DIR = Path(__file__).resolve().parent
NATIVE_SRC = WEB_DIR / "native"
NATIVE_FILES = ("bit.c", "lovejs_bridge.cpp")
MARKER = "gen1recomp web bridge"

CMAKE_LIB = """
# %s: LuaBitOp (`bit`) + the `lovejs` picker/storage bridge
set(LOVE_SRC_3P_G1RWEB
	src/libraries/g1rweb/bit.c
	src/libraries/g1rweb/lovejs_bridge.cpp
)

add_library(love_3p_g1rweb ${LOVE_SRC_3P_G1RWEB})
target_link_libraries(love_3p_g1rweb ${LOVE_LUA_LIBRARY})
""" % MARKER

LOVE_CPP_DECL = """
// %s: preloaded below on emscripten builds.
#ifdef LOVE_EMSCRIPTEN
extern "C" int luaopen_bit(lua_State *L);
extern "C" int luaopen_lovejs(lua_State *L);
#endif
""" % MARKER

LOVE_CPP_PRELOAD = """
#ifdef LOVE_EMSCRIPTEN
	// %s
	love::luax_preload(L, luaopen_bit, "bit");
	love::luax_preload(L, luaopen_lovejs, "lovejs");
#endif
""" % MARKER


OPENGL_RGBA8_ANCHOR = (
    "\t\t\treturn GLAD_VERSION_1_0 || GLAD_ES_VERSION_3_0 || GLAD_OES_rgb8_rgba8"
    " || GLAD_ARM_rgba8;\n")
OPENGL_RGBA8 = """#ifdef LOVE_EMSCRIPTEN
\t\t\t// %s: WebGL 1 guarantees RGBA/UNSIGNED_BYTE textures are
\t\t\t// colour-renderable but reports no OES_rgb8_rgba8, so without this
\t\t\t// every Canvas fell back to RGBA4.
\t\t\treturn true;
#else
%s#endif
"""


EXCEPTION_ALERT = """	#if LOVE_EMSCRIPTEN
		// TODO: replace with a nice console.error call (ie figure out how to pass multi-line string to it properly)
		std::cout << message << std::endl;
		emscripten_run_script("alert('An error occurred before the game window could be initialised. Please check the console!')");
	#endif
"""
EXCEPTION_QUIET = """	// %s: no alert/print per exception -- most are caught and
	// become Lua errors (ports/web/patch_love.py, item 5)
"""


def pristine(path: Path):
    """Text of the untouched file, normalized to \n, plus its newline style
    (love's CMakeLists.txt is CRLF; keep it that way so the diff stays small)."""
    orig = path.with_name(path.name + ".orig")
    if not orig.exists():
        shutil.copy2(path, orig)
    raw = orig.read_bytes().decode("utf-8")
    newline = "\r\n" if "\r\n" in raw else "\n"
    return raw.replace("\r\n", "\n"), newline


def write(path: Path, text: str, newline: str) -> None:
    path.write_bytes(text.replace("\n", newline).encode("utf-8"))


def replace_once(text: str, anchor: str, replacement: str, what: str) -> str:
    count = text.count(anchor)
    if count != 1:
        sys.exit("patch_love.py: expected one %s anchor, found %d" % (what, count))
    return text.replace(anchor, replacement, 1)


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    love = Path(sys.argv[1]).resolve()
    cmake = love / "CMakeLists.txt"
    love_cpp = love / "src" / "modules" / "love" / "love.cpp"
    opengl_cpp = love / "src" / "modules" / "graphics" / "opengl" / "OpenGL.cpp"
    exception_cpp = love / "src" / "common" / "Exception.cpp"
    for path in (cmake, love_cpp, opengl_cpp, exception_cpp):
        if not path.exists():
            sys.exit("patch_love.py: not a LÖVE tree (missing %s)" % path)

    dst = love / "src" / "libraries" / "g1rweb"
    dst.mkdir(parents=True, exist_ok=True)
    for name in NATIVE_FILES:
        shutil.copy2(NATIVE_SRC / name, dst / name)

    text, newline = pristine(cmake)
    anchor = "target_link_libraries(love_3p_lua53 ${LOVE_LUA_LIBRARY})\n"
    text = replace_once(text, anchor, anchor + CMAKE_LIB, "love_3p_lua53 link")
    text = replace_once(text, "\tlove_3p_lua53\n", "\tlove_3p_lua53\n\tlove_3p_g1rweb\n",
                        "liblove link list")
    write(cmake, text, newline)

    text, newline = pristine(love_cpp)
    anchor = "// For love::graphics::setGammaCorrect.\n"
    text = replace_once(text, anchor, LOVE_CPP_DECL + "\n" + anchor, "love.cpp include")
    anchor = '\tlove::luax_preload(L, luaopen_luautf8, "utf8");\n#endif\n'
    text = replace_once(text, anchor, anchor + LOVE_CPP_PRELOAD, "utf8 preload")
    write(love_cpp, text, newline)

    text, newline = pristine(opengl_cpp)
    text = replace_once(text, OPENGL_RGBA8_ANCHOR,
                        OPENGL_RGBA8 % (MARKER, OPENGL_RGBA8_ANCHOR), "RGBA8 render target")
    write(opengl_cpp, text, newline)

    text, newline = pristine(exception_cpp)
    text = replace_once(text, EXCEPTION_ALERT, EXCEPTION_QUIET % MARKER, "Exception alert")
    write(exception_cpp, text, newline)

    print("patch_love.py: patched %s" % love)


if __name__ == "__main__":
    main()
