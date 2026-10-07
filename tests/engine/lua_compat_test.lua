-- src/core/LuaCompat: the 5.2-style load() shim for PUC Lua 5.1 (love.js).
-- Runs under both interpreters: LuaJIT (CI's headless tier) exercises the
-- shim through makeLoad/install on a fake global table, and
-- scripts/ci/lua51_compat.sh runs it again under lua5.1, where install()
-- patches the real _G.
--   luajit tests/engine/lua_compat_test.lua
--   lua5.1 tests/engine/lua_compat_test.lua
package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.harness")
local check, eq = T.check, T.eq

local LuaCompat = require("src.core.LuaCompat")

-- a 5.1-style load: functions only, like PUC Lua 5.1's
local function load51(chunk, name)
  if type(chunk) ~= "function" then
    error("bad argument #1 to 'load' (function expected, got " .. type(chunk) .. ")", 2)
  end
  return load(chunk, name)
end

local fake = { load = load51, loadstring = loadstring, setfenv = setfenv }
check(not LuaCompat.loadAcceptsStrings(fake), "the fake 5.1 load rejects strings")
check(LuaCompat.install(fake), "install patches a 5.1 load")
check(LuaCompat.loadAcceptsStrings(fake), "patched load accepts strings")
check(not LuaCompat.install(fake), "install is idempotent")

local shimLoad = fake.load

do
  local env = { x = 41 }
  local fn = shimLoad("y = x + 1; return y", "@test", "t", env)
  check(type(fn) == "function", "string chunk compiles")
  eq(fn(), 42, "chunk runs inside the supplied env")
  eq(env.y, 42, "globals land in the env table")
  eq(rawget(_G, "y"), nil, "the real globals stay untouched")
end

do
  local fn = shimLoad("return os", "@sandbox", "t", {})
  eq(fn(), nil, "an empty env hides the standard library")
end

do
  local fn, err = shimLoad("return (", "@broken", "t", {})
  eq(fn, nil, "syntax error returns nil")
  check(type(err) == "string" and err:find("broken", 1, true) ~= nil,
    "syntax error message names the chunk")
end

do
  local binary = string.dump(function() return 7 end)
  local fn, err = shimLoad(binary, "@bin", "t", {})
  eq(fn, nil, "mode 't' refuses a binary chunk")
  check(type(err) == "string" and err:find("binary", 1, true) ~= nil,
    "binary refusal says why")
  local fn2, err2 = shimLoad("return 1", "@txt", "b")
  eq(fn2, nil, "mode 'b' refuses a text chunk")
  check(type(err2) == "string" and err2:find("text", 1, true) ~= nil,
    "text refusal says why")
  local fn3 = shimLoad(binary, "@bin", "bt")
  eq(fn3 and fn3(), 7, "mode 'bt' accepts a binary chunk")
end

do
  local parts = { "return ", "a", " * 2" }
  local i = 0
  local fn = shimLoad(function() i = i + 1; return parts[i] end, "@reader", nil, { a = 21 })
  eq(fn and fn(), 42, "reader functions still work and honour env")
end

do
  local fn = shimLoad("return 5")
  eq(fn and fn(), 5, "no env keeps the caller's globals (5.1 default)")
end

-- On the interpreter running this file: after install(), the real load
-- must take strings (true on LuaJIT already, and on lua5.1 via the shim).
LuaCompat.install()
check(LuaCompat.loadAcceptsStrings(), "real load accepts strings after install (" .. _VERSION .. ")")
do
  local fn = load("return z", "@real", "t", { z = "ok" })
  eq(fn and fn(), "ok", "real load sandboxes with env after install")
end

T.finish()
