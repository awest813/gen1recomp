-- LuaCompat.rewriteGoto: the `goto continue` idiom that LuaJIT-era mods use,
-- rewritten for PUC Lua 5.1 (the browser build).  Under LuaJIT each snippet
-- also runs unmodified, so the rewrite is checked against native goto; under
-- lua5.1 the rewritten code is checked against the expected values.
--   luajit tests/engine/lua_goto_rewrite_test.lua   (also runs on lua5.1)
package.path = "./?.lua;./?/init.lua;" .. package.path
local T = require("tests.harness")
local eq, check = T.eq, T.check
local LuaCompat = require("src.core.LuaCompat")
local loadstr = loadstring or load
local nativeGoto = loadstr("goto x ::x::") ~= nil

local function lines(s) return select(2, s:gsub("\n", "")) end

local function same(name, src, expected)
  local out, why = LuaCompat.rewriteGoto(src)
  check(out ~= nil, name .. ": rewritten (" .. tostring(why) .. ")")
  if not out then return end
  eq(lines(out), lines(src), name .. ": line count kept")
  local fn, err = loadstr(out, "=" .. name)
  check(fn ~= nil, name .. ": compiles on " .. _VERSION .. " " .. tostring(err))
  if not fn then return end
  local got = fn()
  eq(got, expected, name .. ": result")
  if nativeGoto then
    eq(assert(loadstr(src))(), got, name .. ": matches native goto")
  end
end

same("for continue", [[
local s = 0
for i = 1, 10 do
  if i % 2 == 0 then goto continue end
  s = s + i
  ::continue::
end
return s]], 25)

same("while continue and a real break", [[
local i, s = 0, 0
while true do
  i = i + 1
  if i > 8 then break end
  if i % 3 == 0 then goto continue end
  s = s + i
  ::continue::
end
return s .. "/" .. i]], "27/9")

same("label ends an if branch, code after the if still runs", [[
local log = {}
for i = 1, 4 do
  if i ~= 2 then
    if i == 3 then
      goto continue
    end
    log[#log + 1] = "a" .. i
    ::continue::
  end
  log[#log + 1] = "b" .. i
end
return table.concat(log, ",")]], "a1,b1,b2,b3,a4,b4")

same("nested loops, each with its own continue", [[
local s = 0
for i = 1, 3 do
  if i == 2 then goto continue end
  for j = 1, 3 do
    if j == 2 then goto continue end
    s = s + i * 10 + j
    ::continue::
  end
  ::continue::
end
return s]], 11 + 13 + 31 + 33)

same("else branch", [[
local out = {}
for i = 1, 3 do
  if i == 1 then
    out[#out + 1] = "one"
  else
    if i == 2 then goto skip end
    out[#out + 1] = "x" .. i
    ::skip::
  end
end
return table.concat(out, ",")]], "one,x3")

same("unused label is dropped", [[
local s = 0
for i = 1, 3 do
  s = s + i
  ::unused::
end
return s]], 6)

same("break inside an inner loop is left alone", [[
local s = 0
for i = 1, 3 do
  if i == 2 then goto continue end
  for j = 1, 5 do
    if j > 2 then break end
    s = s + j
  end
  ::continue::
end
return s]], 6)

-- shapes it must refuse (the caller keeps the original compile error)
local function refuses(name, src)
  eq(LuaCompat.rewriteGoto(src), nil, name .. ": left alone")
end
refuses("goto out of an inner loop", [[
for i = 1, 3 do
  for j = 1, 3 do
    if j == 2 then goto continue end
  end
  ::continue::
end]])
refuses("label not the last statement", [[
for i = 1, 3 do
  if i == 2 then goto continue end
  ::continue::
  print(i)
end]])
refuses("goto from a nested function", [[
for i = 1, 3 do
  local f = function() goto continue end
  ::continue::
end]])
refuses("break crossing two wrappers", [[
for i = 1, 3 do
  if i then
    if i == 1 then goto inner end
    if i == 3 then break end
    ::inner::
  end
  if i == 2 then goto continue end
  ::continue::
end]])
refuses("no goto at all", "local t = {} t.goto = 1 return t")

-- the mod sandbox compiles through it on PUC 5.1 (a mod's own load() of a
-- lib file is Sandbox.compile too)
do
  love = love or require("tests.love_stub")
  local okS, Sandbox = pcall(require, "src.mods.Sandbox")
  check(okS, "Sandbox loads: " .. tostring(Sandbox))
  if okS then
    local env = setmetatable({}, { __index = _G })
    local fn, err = Sandbox.compile([[
      local s = 0
      for i = 1, 4 do
        if i == 3 then goto continue end
        s = s + i
        ::continue::
      end
      return s]], "=goto_mod", env)
    check(fn ~= nil, "a mod chunk with goto continue compiles on " .. _VERSION .. " " .. tostring(err))
    eq(fn and fn(), 7, "and runs")
  end
end

T.finish()
