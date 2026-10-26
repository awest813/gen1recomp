-- Steady frames off the plain overworld build no Lua garbage either: the
-- rarer Renderer:endFrame paths (a DYNAMIC-layout docked box, the battle
-- dim and void veil around the letterbox, the paper surround behind an
-- opaque screen).  Same harness as overworld_frame_alloc_perf.lua: the
-- fixture overworld through Game:draw on tests/love_stub, the collector
-- stopped, KB per frame on the interpreter love.js runs.
--   luajit tests/engine/ui_frame_alloc_perf.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
if not _G.love then _G.love = require("tests.love_stub") end
if rawget(_G, "jit") then jit.off() end

-- model LOVE's images, quads and colour state (see
-- overworld_frame_alloc_perf.lua), so the count below is the engine's alone
do
  getmetatable(love.graphics.newImage("x")).setWrap = function() end
  local newQuad = love.graphics.newQuad
  local function setViewport(q, x, y, w, h) q.x, q.y, q.w, q.h = x, y, w, h end
  love.graphics.newQuad = function(...)
    local q = newQuad(...)
    q.setViewport = setViewport
    return q
  end
  local c = { 1, 1, 1, 1 }
  love.graphics.setColor = function(r, g, b, a)
    c[1], c[2], c[3], c[4] = r, g, b, a
  end
  love.graphics.getColor = function() return c[1], c[2], c[3], c[4] end
end

local T = require("tests.modkit")
local check, eq = T.check, T.eq
local Data = T.fixtures.fresh()
Data.tilesets.FIX_OUT.tilesPerRow = 16
Data.field.flyWarps = Data.field.flyWarps or {}
Data.field.playerSprites = { walk = "SPRITE_FIX_PLAYER" }
Data.field.waterTilesets = {}
Data.field.forcedMovement = { tiles = {} }
Data.audio = Data.audio or {}
Data.audio.songs = Data.audio.songs or {}
Data.audio.mapSongs = Data.audio.mapSongs or {}
-- the SGB palettes these screens ask for by name, as a real cache has them
local ROUTE = { { 255, 255, 255 }, { 170, 170, 170 }, { 85, 85, 85 }, { 0, 0, 0 } }
local GREENBAR = { { 255, 255, 255 }, { 0, 200, 0 }, { 0, 100, 0 }, { 0, 0, 0 } }
Data.palettes = {
  palettes = {
    ROUTE = ROUTE, MEWMON = ROUTE, GREENBAR = GREENBAR,
    YELLOWBAR = { GREENBAR[1], GREENBAR[2], { 200, 200, 0 }, GREENBAR[4] },
    REDBAR = { GREENBAR[1], GREENBAR[2], { 200, 0, 0 }, GREENBAR[4] },
  },
  pokemon = {},
}

local SaveData = require("src.core.SaveData")
local Game = require("src.core.Game")
local StateStack = require("src.core.StateStack")
local OverworldState = require("src.world.OverworldController")
local Renderer = require("src.render.Renderer")
local TextBox = require("src.render.TextBox")

Game.data = Data
Game.save = SaveData.newGame()
Game.save.player.map = "FIX_TOWN"
StateStack:init()
Game.stack = StateStack
Game.overworld = OverworldState
Game.input = {
  isDown = function() return false end,
  wasPressed = function() return false end,
  step = function() end, state = {}, pressQueue = {},
}
Game.renderer = Renderer
Renderer:init()

local save = SaveData.newGame()
save.player.map = "FIX_TOWN"
save.player.x, save.player.y = 4, 4
save.lastOutdoor = { id = "FIX_TOWN", x = 4, y = 4 }
Game:restoreSave(save, false, { freshBoot = true })
while #Game.stack.states > 1 do Game.stack:pop() end
eq(Game.stack.states[1], OverworldState, "the overworld is the draw base")
Game.save.options = Game.save.options or {}

local function frame()
  Game.stack:update(1 / 60)
  Game:draw()
end

local function kbPerFrame(n)
  for _ = 1, 60 do frame() end
  collectgarbage("collect")
  collectgarbage("stop")
  -- PUC Lua's full collect shrinks the interpreter stack, and the next
  -- frame grows it back: a one-off, not the frame's own garbage
  frame()
  local before = collectgarbage("count")
  for _ = 1, n do frame() end
  local after = collectgarbage("count")
  collectgarbage("restart")
  return (after - before) / n
end

local function steady(what, n)
  local kb = kbPerFrame(n or 240)
  check(kb < 0.01, ("%s allocates nothing (%.3f KB/frame)"):format(what, kb))
end

-- a window the 160x144 screen does not fill, so there are voids around the
-- letterbox for the dim and the veil to cover
local g = love.graphics
local realDims, realPixelDims = g.getDimensions, g.getPixelDimensions
local function bigWindow(on)
  if on then
    g.getDimensions = function() return 700, 600 end
    g.getPixelDimensions = function() return 700, 600 end
  else
    g.getDimensions, g.getPixelDimensions = realDims, realPixelDims
  end
end

-- ------------------------------------------------ DYNAMIC: a docked box
do
  Game.save.options.uiLayout = "dynamic"
  Game.stack:push(TextBox.new(Game, "HELLO THERE\nWORLD", function() end))
  steady("a dialogue box docked to the window edge")
  local list = Renderer.uiAnchors
  eq(list and #list, 1, "the box declares one anchor")
  local a = list and list[1]
  eq(a and a.anchor, "bottom", "against the bottom edge")
  eq(a and a.w, 160, "the box's width")
  eq(a and a.extract, true, "cut out of the letterbox blit")
  frame()
  check(Renderer.uiAnchors[1] == a, "an unchanged anchor keeps its record")
  a.tag = true
  frame()
  check(Renderer.uiAnchors[1] ~= a and Renderer.uiAnchors[1].tag == nil,
    "a record someone wrote to is not used again")
  Game.stack:pop()
  Game.save.options.uiLayout = nil
end

-- ------------------------------------------------ void veil, battle dim
-- Both fill the window outside the letterbox: the pieces must cover exactly
-- the voids, never the screen itself.
local function voidFills(setup)
  local fills = {}
  local rect = g.rectangle
  g.rectangle = function(mode, x, y, w, h)
    local _, _, _, a = g.getColor()
    if mode == "fill" and a == 0.5 then fills[#fills + 1] = { x, y, w, h } end
    return rect(mode, x, y, w, h)
  end
  setup()
  frame()
  g.rectangle = rect
  local R = Renderer:frameRects()
  local area = 0
  for _, f in ipairs(fills) do
    area = area + f[3] * f[4]
    local overlap = f[1] < R.uox + R.uvpw and R.uox < f[1] + f[3]
      and f[2] < R.uoy + R.uvph and R.uoy < f[2] + f[4]
    check(not overlap, "a void fill stays off the screen")
  end
  return #fills, area, R.vuw * R.vuh - R.uvpw * R.uvph
end

do
  bigWindow(true)
  local veil = { 0, 0, 0, 0.5 }
  local draw = OverworldState.draw
  OverworldState.draw = function(...)
    Renderer.voidVeil = veil
    return draw(...)
  end
  steady("a void veil around the letterbox")
  local n, area, want = voidFills(function() end)
  OverworldState.draw = draw
  check(n > 0, "the veil drew")
  eq(area, want, "the veil covers every void pixel once")
  bigWindow(false)
end

do
  bigWindow(true)
  -- a world-backed battle stand-in: see-through, so the map draws under it
  local battle = { isOpaque = false, BG_WORLD_DIM = 0.5,
    bgMode = function() return "world" end, draw = function() end }
  Game.stack:push(battle)
  steady("the battle dim over the world")
  local n, area, want = voidFills(function() end)
  check(n > 0, "the dim drew")
  eq(area, want, "the dim covers every void pixel once")
  Game.stack:pop()

  -- an opaque screen asking for the paper surround (letterboxWhite): the
  -- clear reads the shade through a function every frame
  local paper = { isOpaque = true, letterboxWhite = true, draw = function() end }
  Game.stack:push(paper)
  steady("the paper surround behind an opaque screen")
  Game.stack:pop()
  bigWindow(false)
end

T.finish("ui_frame_alloc_perf")
