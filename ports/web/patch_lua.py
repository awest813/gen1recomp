#!/usr/bin/env python3
"""Builds megasource's PUC Lua 5.1 as C++ for the browser (love.js).

Why: Lua compiled as C raises errors with longjmp.  The love.js build turns
on C++ exception catching (-s DISABLE_EXCEPTION_CATCHING=0, see
scripts/build_web.sh), and emscripten 2.0.0 mishandles a longjmp that
unwinds through C++ frames compiled that way.  Every LÖVE error raised with
luaL_error from luax_catchexcept -- a missing file, an undecodable image, a
shader that fails to compile -- then escapes or skips the caller's pcall: in
practice love.filesystem.newFileData returned nothing,
love.image.newImageData jumped out of its pcall, and love.graphics.newImage
trapped ("null function or function signature mismatch") and killed the
runtime.  Gold's intro hit the last one probing for Crystal's kris.png.

Lua 5.1 already supports C++ error handling: compiled as C++, LUAI_THROW is
`throw` and LUAI_TRY is try/catch (luaconf.h), which emscripten unwinds
correctly through LÖVE's frames.  The public API keeps C linkage
(LUA_API extern "C") so LÖVE, LuaBitOp and the other C modules link
unchanged.

Idempotent, same .orig scheme as patch_love.py.

Usage: patch_lua.py <path/to/megasource/libs/lua-5.1.5>
"""

import sys
from pathlib import Path

from patch_love import MARKER, pristine, replace_once, write

CMAKE_ANCHOR = "\tsrc/print.c\n)\n"
CMAKE_CXX = """
# %s: compile Lua as C++ so lua_error is a C++ throw (ports/web/patch_lua.py)
set_source_files_properties(${LUA_SRC} PROPERTIES LANGUAGE CXX)
""" % MARKER

LUACONF_ANCHOR = "#else\n\n#define LUA_API\t\textern\n\n#endif\n"
LUACONF_API = """#else

/* %s: Lua is built as C++ for the browser (ports/web/patch_lua.py);
** keep the API on C linkage so C modules and LÖVE link unchanged */
#if defined(__cplusplus)
#define LUA_API\t\textern "C"
#else
#define LUA_API\t\textern
#endif

#endif
""" % MARKER


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    lua = Path(sys.argv[1]).resolve()
    cmake = lua / "CMakeLists.txt"
    luaconf = lua / "src" / "luaconf.h"
    for path in (cmake, luaconf):
        if not path.exists():
            sys.exit("patch_lua.py: not a Lua 5.1 tree (missing %s)" % path)

    text, newline = pristine(cmake)
    text = replace_once(text, CMAKE_ANCHOR, CMAKE_ANCHOR + CMAKE_CXX, "LUA_SRC list end")
    write(cmake, text, newline)

    text, newline = pristine(luaconf)
    text = replace_once(text, LUACONF_ANCHOR, LUACONF_API, "LUA_API extern")
    write(luaconf, text, newline)

    print("patch_lua.py: patched %s" % lua)


if __name__ == "__main__":
    main()
