-- Lua 5.2-style load() on PUC Lua 5.1.
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

return LuaCompat
