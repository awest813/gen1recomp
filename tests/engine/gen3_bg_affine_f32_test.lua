-- bg_affine's float32 rounding without the FFI (PUC Lua, the browser build)
-- must match LuaJIT's ffi.new("float", x) bit for bit: BgAffineSet's
-- rotation/scale matrix is built from those roundings.
--   luajit tests/engine/gen3_bg_affine_f32_test.lua   (also runs on lua5.1)
package.path = "./?.lua;./?/init.lua;" .. package.path
local T = require("tests.harness")
local eq, check = T.eq, T.check

-- load the module with the FFI hidden so the pure-Lua path is under test
local realRequire = require
_G.require = function(name)
  if name == "ffi" then error("module 'ffi' not found") end
  return realRequire(name)
end
package.loaded["src.core.game3.bg_affine"] = nil
local Affine = realRequire("src.core.game3.bg_affine")
_G.require = realRequire
local f32 = Affine._f32

local cases = {
  { 0.33333333333333331, 0.3333333432674408 },
  { 0.10000000000000001, 0.10000000149011612 },
  { 3.1415926535897931, 3.1415927410125732 },
  { -2.7182818284590451, -2.7182817459106445 },
  { 16777217, 16777216 },                          -- tie rounds to even
  { 9.9999999999999993e-41, 9.9999461011147596e-41 }, -- subnormal
  { 3.5e+38, math.huge },                          -- overflow
  { 3.129320807286708, 3.1293208599090576 },
  { 1.4000000000000001e-45, 1.4012984643248171e-45 }, -- smallest subnormal
  { 7.0000000000000004e-46, 0 },                   -- under half of it
}
for _, c in ipairs(cases) do
  eq(f32(c[1]), c[2], ("f32(%.17g)"):format(c[1]))
end

local okFfi, ffi = pcall(realRequire, "ffi")
if okFfi and ffi then
  local bad = 0
  math.randomseed(7)
  for _ = 1, 20000 do
    local x = (math.random() - 0.5) * 2 ^ math.random(-150, 130)
    if f32(x) ~= tonumber(ffi.new("float", x)) then bad = bad + 1 end
  end
  eq(bad, 0, "20000 random values match the FFI")
else
  check(true, "no FFI on " .. _VERSION .. ": fixed cases only")
end

T.finish()
