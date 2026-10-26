-- Void-fill bake failure is remembered (src/render/TileRenderer.lua).
-- No pokered cite: the void fill is port-only (the original has no world
-- past the map's own border blocks on screen).
--
-- ensureBorderFill runs every overworld frame.  When the 32x32 border bake
-- failed it left nothing behind to say so, so the next frame baked again --
-- a fresh canvas created and dropped per frame for as long as the map was
-- up.  A failed bake now stands until the void-fill mode changes.
--   luajit tests/engine/void_fill_bake_retry_test.lua

package.path = "./?.lua;./?/init.lua;" .. package.path
love = love or require("tests.love_stub")

local T = require("tests.harness")
local check, eq = T.check, T.eq

local Logger = require("src.core.Logger")
local realWarn = Logger.warn
local warned = 0
Logger.warn = function() warned = warned + 1 end

local TileRenderer = require("src.render.TileRenderer")
local PixelCanvas = require("src.render.PixelCanvas")

local made, failing = 0, true
local realNew, realStatic = PixelCanvas.new, PixelCanvas.toStatic
PixelCanvas.new = function(w, h)
  made = made + 1
  return realNew(w, h)
end
PixelCanvas.toStatic = function(canvas)
  if failing then error("no texture readback on this device") end
  return { setWrap = function() end, setFilter = function() end,
           release = function() end }
end

local function renderer(tileset)
  return setmetatable({
    map = { def = { tileset = tileset, borderBlock = 0 },
            -- every block index answers the same 16-tile block
            tileset = { blocks = setmetatable({}, { __index = function()
              return { 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 }
            end }) } },
    quads = {},
    image = {},
  }, { __index = TileRenderer })
end

TileRenderer.setVoidFill("trees")
local r = renderer("HOUSE")
for _ = 1, 30 do r:ensureBorderFill() end
eq(made, 1, "a failed bake is attempted once, not once per frame")
eq(r.borderFill, nil, "and leaves no border image")
eq(warned, 1, "and is reported once")

-- The next mode retries: a VOID FILL change is the player asking again.
failing = false
local o = renderer("OVERWORLD")
for _ = 1, 5 do o:ensureBorderFill() end
check(o.borderFill ~= nil, "a working bake still lands")
eq(made, 2, "and bakes once")
TileRenderer.setVoidFill("black")
o:ensureBorderFill()
eq(o.borderFill, nil, "BLACK needs no bake")
TileRenderer.setVoidFill("trees")
for _ = 1, 5 do o:ensureBorderFill() end
check(o.borderFill ~= nil, "switching back bakes again")
eq(made, 3, "exactly once more")

PixelCanvas.new, PixelCanvas.toStatic = realNew, realStatic
Logger.warn = realWarn
TileRenderer.setVoidFill("trees")
T.finish("void fill bake retry")
