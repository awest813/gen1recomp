-- Byte-exact pins for the cache writers the import speedups touched
-- (src/import/LuaWriter.lua, src/import/gba/native_pack.lua encoders) and
-- the stage weighting behind the Gen 1/2 progress bar
-- (src/import/StageWeights.lua).  An import's cache must come out
-- byte-identical after a speedup; these pin the text and binary layouts so
-- a "faster" encoder that reorders keys or bytes fails here, not in a
-- player's cache.  No pokered cite: port-only import plumbing.
--   luajit tests/engine/import_writer_output_pins_test.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
love = love or require("tests.love_stub")

local T = require("tests.harness")
local check, eq = T.check, T.eq

-- ------------------------------------------------------- LuaWriter

local LuaWriter = require("src.import.LuaWriter")
eq(LuaWriter.encode({}), "return {}\n", "an empty table")
eq(LuaWriter.encode({ 1, "two", true }), 'return {\n  1,\n  "two",\n  true,\n}\n', "an array")
eq(LuaWriter.encode({ b = 1, a = { x = 2 }, [3] = "c", ["end"] = 0, ["a b"] = 1 }),
  'return {\n'
  .. '  [3] = "c",\n'
  .. '  a = {\n    x = 2,\n  },\n'
  .. '  ["a b"] = 1,\n'
  .. '  b = 1,\n'
  .. '  ["end"] = 0,\n'
  .. '}\n',
  "numbers before strings, keywords and spaces bracketed, nested indent")
eq(LuaWriter.encode({ s = 'q"\\\n\r\t\0\1' }), 'return {\n  s = "q\\"\\\\\\n\\r\\t\\000\\001",\n}\n',
  "escapes")
eq(LuaWriter.encode({ { {} } }), "return {\n  {\n    {},\n  },\n}\n", "nested empties")
eq(LuaWriter.encode({ [1] = "a", [3] = "c" }), 'return {\n  [1] = "a",\n  [3] = "c",\n}\n',
  "a holey array is written as keys")
local cyclic = {}
cyclic.self = cyclic
check(not pcall(LuaWriter.encode, cyclic), "a cycle is refused")

-- ------------------------------------------------------- NativePack

local NativePack = require("src.import.gba.native_pack")
local idx = NativePack.encodeIdx({ formatVersion = 1, flags = 2, midCount = 1,
  atlasCols = 16, atlasRows = 1, midIds = { 0x1234 },
  pixels = setmetatable({ [1] = 1, [2] = 255, [3] = 256, [4] = 300 }, { __index = function() return nil end }) })
eq(#idx, 12 + 2 + 256, "idx: header, one mid id, 256 pixels")
eq(idx:sub(1, 14), "SVMI\1\2\1\0\16\0\1\0\52\18", "idx header and mid id")
eq(idx:sub(15, 18), "\1\255\0\44", "pixels wrap at 256")
eq(idx:sub(19), string.rep("\0", 252), "missing pixels are 0")
local decoded = NativePack.decodeIdx(idx)
eq(decoded and decoded.pixels[2], 255, "and it decodes")

local layout = NativePack.encodeMidLayout({ width = 2, height = 1, borderWidth = 1,
  borderHeight = 1, borderMids = { 7 },
  cells = { { mid = 0x0102, coll = 1, elev = 3 }, { mid = 70000, coll = 300, elev = 0 } } })
eq(layout, "SVML\1\0\2\0\1\0\2\0\1\0\1\1\7\0" .. "\2\1\1\3" .. "\112\17\44\0",
  "layout: header, border, cells (mid wraps at 65536, coll at 256)")

-- ------------------------------------------------------- StageWeights

local StageWeights = require("src.import.StageWeights")
local w = StageWeights.new({ A = 10, B = 30 }, 5)
local seen = {}
local function push(done, total) seen[#seen + 1] = done / total end
push(w:begin("A"))
push(w:at(0.5))
push(w:begin("B"))
push(w:at(1))
push(w:begin("C")) -- a stage the table does not know
push(w:at(1))
eq(seen[1], 0, "the first stage starts at 0")
eq(seen[2], 5 / 40, "half of a 10-weight stage of 40")
eq(seen[3], 10 / 40, "the next stage starts where the last one ended")
for i = 2, #seen do
  check(seen[i] >= seen[i - 1] - 0.15, "progress does not fall far back: " .. table.concat(seen, ", "))
end
eq(seen[#seen], 1, "and the bar still ends at 1 with an unknown stage")

T.finish("import writer output pins")
