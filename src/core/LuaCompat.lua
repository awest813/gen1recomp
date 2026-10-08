-- PUC Lua 5.1 shims: a 5.2-style load(), and a pcall that yields (below).
--
-- load():
--
-- LuaJIT (every native build) accepts load(string, name, mode, env).  PUC Lua
-- 5.1 -- what love.js runs in the browser, since there is no JIT in
-- WebAssembly -- only accepts a reader function there and raises
-- "bad argument #1 to 'load' (function expected, got string)".  The engine
-- calls the 5.2 form to sandbox generated cache modules (src/core/Data.lua and
-- the game3 chrome loaders), so on 5.1 every boot from the cache died.
--
-- install() is idempotent and a no-op where load already takes strings, so
-- conf.lua and main.lua can both call it without caring which ran first.  It
-- has zero requires so conf.lua can load it before anything else.

local LuaCompat = {}

local BINARY_SIGNATURE = "\27"

local function modeAllows(mode, chunk)
  if mode == nil then return true end
  local binary = chunk:sub(1, 1) == BINARY_SIGNATURE
  if binary and not mode:find("b", 1, true) then
    return false, ("attempt to load a binary chunk (mode is '%s')"):format(mode)
  end
  if not binary and not mode:find("t", 1, true) then
    return false, ("attempt to load a text chunk (mode is '%s')"):format(mode)
  end
  return true
end

-- Builds the 5.2-compatible load around the 5.1 primitives.  Exposed for the
-- tests, which run under LuaJIT and so never see install() take effect.
function LuaCompat.makeLoad(baseLoad, loadstring, setfenv)
  return function(chunk, chunkname, mode, env)
    local fn, err
    if type(chunk) == "string" then
      local ok, why = modeAllows(mode, chunk)
      if not ok then return nil, why end
      fn, err = loadstring(chunk, chunkname)
    else
      fn, err = baseLoad(chunk, chunkname)
    end
    if fn and env ~= nil then setfenv(fn, env) end
    return fn, err
  end
end

function LuaCompat.loadAcceptsStrings(G)
  G = G or _G
  return type(G.load) == "function" and (pcall(G.load, "return true"))
end

function LuaCompat.install(G)
  G = G or _G
  if LuaCompat.loadAcceptsStrings(G) then return false end
  if type(G.loadstring) ~= "function" or type(G.setfenv) ~= "function" then
    return false
  end
  G.load = LuaCompat.makeLoad(G.load, G.loadstring, G.setfenv)
  return true
end

-- Yield across pcall.  LuaJIT lets a coroutine yield from inside a pcall'd
-- function; PUC Lua 5.1 raises "attempt to yield across metamethod/C-call
-- boundary" instead.  yieldablePcall is pcall built from a coroutine (the
-- coxpcall pattern): the call runs in its own coroutine and every yield is
-- passed through to the caller's resumer and back, so code that reports
-- progress by yielding works under a pcall on both.  Costs a coroutine per
-- call, so callers swap it in only around such code (RomExtractorGen3:run).

local unpack = unpack or table.unpack
local function pack(...) return { n = select("#", ...), ... } end

local yieldsThroughPcall = nil

function LuaCompat.pcallYields()
  if yieldsThroughPcall == nil then
    local co = coroutine.create(function() return pcall(coroutine.yield, true) end)
    local ok, value = coroutine.resume(co)
    yieldsThroughPcall = ok and value == true
  end
  return yieldsThroughPcall
end

function LuaCompat.yieldablePcall(f, ...)
  -- coroutine.create needs a Lua function on 5.1
  local co = coroutine.create(function(...) return f(...) end)
  local res = pack(coroutine.resume(co, ...))
  while true do
    if not res[1] then return false, res[2] end
    if coroutine.status(co) == "dead" then return true, unpack(res, 2, res.n) end
    res = pack(coroutine.resume(co, coroutine.yield(unpack(res, 2, res.n))))
  end
end

return LuaCompat
