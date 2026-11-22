-- Gen 1 import notes a save that looks like it is for the other game
-- (Red/Blue vs Yellow number their event flags differently, #838), using
-- the marker Compat checks on export.
package.path = "./?.lua;./?/init.lua;" .. package.path
love = love or require("tests.love_stub")
local T = require("tests.harness")
local GenSave = require("src.save_convert.GenSave")
local G1 = require("tests.fixtures.save.gen1_build")
local B = require("tests.fixtures.save.bytes")

local function with(starter, pika)
  local b = B.fromString(G1.build({}))
  b[0x29C3] = starter
  b[0x271C] = pika
  return B.pack(b)
end
T.eq(GenSave.looksLikeYellow(with(0x54, 0)), true, "a Pikachu starter reads as Yellow")
T.eq(GenSave.looksLikeYellow(with(0, 0x80)), true, "no starter but Pikachu's friendship reads as Yellow")
T.eq(GenSave.looksLikeYellow(with(0x99, 0)), false, "a Bulbasaur starter reads as Red/Blue")
T.eq(GenSave.looksLikeYellow("short"), nil, "a short file cannot tell")
T.finish("gen1 yellow marker")
