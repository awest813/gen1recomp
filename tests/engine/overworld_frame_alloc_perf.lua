-- A steady Gen 1 overworld frame (Game:draw -> GameViewport.begin, the
-- world pass, the UI pass, Renderer:endFrame) builds no Lua garbage, with or
-- without a dialogue box up.  The browser build runs PUC Lua 5.1 with no JIT,
-- where every per-frame table is collector work on the frame budget; this
-- path used to build ~2.9 KB a frame there (frameRects' ~30-field rect
-- table, endFrame's two closures and its return table, GameViewport's
-- context and rect, TextBox's line-row pair).
--   luajit tests/engine/overworld_frame_alloc_perf.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
if not _G.love then _G.love = require("tests.love_stub") end
-- the interpreter is what love.js runs, and it keeps LuaJIT's allocation
-- sinking from hiding a table the web build would still pay for
if rawget(_G, "jit") then jit.off() end

-- The stub's images, quads and colour state are not what LOVE's are: an
-- image without setWrap fails the border-fill bake (and the renderer retries
-- it every frame), a quad without setViewport cannot be reused, and the
-- stub's setColor allocates a table per call.  Model the real objects so
-- the count below is the engine's alone.
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
-- a named palette for the map, so the SGB zone lists (UI and world) are
-- built every frame just as they are on a real cache
local ROUTE = { { 255, 255, 255 }, { 170, 170, 170 }, { 85, 85, 85 }, { 0, 0, 0 } }
Data.palettes = { palettes = { ROUTE = ROUTE } }

local SaveData = require("src.core.SaveData")
local Game = require("src.core.Game")
local StateStack = require("src.core.StateStack")
local OverworldState = require("src.world.OverworldController")
local Renderer = require("src.render.Renderer")
local GameViewport = require("src.render.GameViewport")
local TextBox = require("src.render.TextBox")
local PaletteFX = require("src.render.PaletteFX")

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
-- already been outdoors: the interior palette fallback (wLastMap's zero-fill
-- before the first outdoor step) is a separate, pre-Pallet-only path
save.lastOutdoor = { id = "FIX_TOWN", x = 4, y = 4 }
Game:restoreSave(save, false, { freshBoot = true })
-- the fixture save raises a report over the map; the frame under test is
-- the bare overworld
while #Game.stack.states > 1 do Game.stack:pop() end
eq(Game.stack.states[1], OverworldState, "the overworld is the draw base")

local function frame()
  Game.stack:update(1 / 60)
  Game:draw()
end

local function kbPerFrame(n)
  for _ = 1, 60 do frame() end
  collectgarbage("collect")
  collectgarbage("stop")
  local before = collectgarbage("count")
  for _ = 1, n do frame() end
  local after = collectgarbage("count")
  collectgarbage("restart")
  return (after - before) / n
end

-- ------------------------------------------------ the bare overworld
do
  local drawn, zoned = 0, 0
  local draw, worldZones = OverworldState.drawWorld, OverworldState.sgbWorldZones
  OverworldState.drawWorld = function(...)
    drawn = drawn + 1
    return draw(...)
  end
  OverworldState.sgbWorldZones = function(...)
    local zones = worldZones(...)
    if zones and zones[1] and zones[1].colors == ROUTE then zoned = zoned + 1 end
    return zones
  end
  local kb = kbPerFrame(240)
  OverworldState.drawWorld = draw
  OverworldState.sgbWorldZones = worldZones
  check(drawn > 0, "the world pass ran")
  check(zoned > 0, "under the map's named palette")
  check(kb < 0.01, ("a steady overworld frame allocates nothing (%.3f KB/frame)")
    :format(kb))
end

-- ------------------------------------------------ dialogue box up
do
  Game.stack:push(TextBox.new(Game, "HELLO THERE\nWORLD", function() end))
  local kb = kbPerFrame(240)
  check(kb < 0.01, ("a frame under a dialogue box allocates nothing (%.3f KB/frame)")
    :format(kb))
  Game.stack:pop()
end

-- ------------------------------------------------ what callers still see
do
  local a = Renderer:frameRects()
  local b = Renderer:frameRects()
  check(a ~= b, "frameRects still hands each caller its own table")
  eq(a.uox, b.uox, "with the same geometry")
  local x, y, w, h = Renderer:playfieldRect()
  eq(x, a.vux, "playfieldRect x")
  eq(y, a.vuy, "playfieldRect y")
  eq(w, a.vuw, "playfieldRect w")
  eq(h, a.vuh, "playfieldRect h")

  Renderer:beginFrame(false)
  local v1 = Renderer:endFrame(nil, nil)
  Renderer:beginFrame(false)
  local v2 = Renderer:endFrame(nil, nil)
  check(v1 == v2, "an unchanged frame reuses endFrame's viewport")
  local ww, wh = love.graphics.getDimensions()
  eq(v2.width, ww, "viewport width")
  eq(v2.height, wh, "viewport height")
  eq(v2.viewWidth, a.vuw, "viewport view width")
  eq(v2.gameX, a.ox, "viewport game x")

  v2.gameX = -1
  Renderer:beginFrame(false)
  local v3 = Renderer:endFrame(nil, nil)
  check(v3 ~= v2, "a consumer that wrote to the viewport gets a fresh one")
  eq(v3.gameX, a.ox, "carrying this frame's value")

  local getDimensions = love.graphics.getDimensions
  love.graphics.getDimensions = function() return 800, 720 end
  Renderer:beginFrame(false)
  local v4 = Renderer:endFrame(nil, nil)
  love.graphics.getDimensions = getDimensions
  check(v4 ~= v3, "a resize gets a fresh viewport")
  eq(v4.width, 800, "with the new width")

  -- the overworld's zone lists: kept while untouched, rebuilt once touched
  local ui1, ui2 = OverworldState:sgbPalettes(), OverworldState:sgbPalettes()
  check(ui1 == ui2, "the UI zone list is reused while it holds")
  eq(#ui2, 1, "one whole-screen zone")
  eq(ui2[1].colors, ROUTE, "in the map's palette")
  eq(ui2[1].w, 160, "across the screen")
  ui2[2] = { colors = ROUTE, x = 0, y = 0, w = 8, h = 8 }
  local ui3 = OverworldState:sgbPalettes()
  check(ui3 ~= ui2 and #ui3 == 1, "a list someone added to is not handed out again")
  ui3[1].tag = true
  local ui4 = OverworldState:sgbPalettes()
  check(ui4 ~= ui3 and ui4[1].tag == nil, "nor one whose zone was written to")

  local vw, vh = Renderer:worldViewSize()
  local w1, w2 = OverworldState:sgbWorldZones(), OverworldState:sgbWorldZones()
  check(w1 == w2, "the world zone list is reused while it holds")
  eq(#w2, 1, "one zone over the world view")
  eq(w2[1].w, vw, "world zone width")
  eq(w2[1].h, vh, "world zone height")
  w2[1].colors = PaletteFX.GRAYS
  local w3 = OverworldState:sgbWorldZones()
  check(w3 ~= w2 and w3[1].colors == ROUTE, "a retinted world zone is rebuilt")

  -- vanilla GameViewport: one rect, refilled, and still the full window
  local r1 = GameViewport.begin(1)
  local r2 = GameViewport.begin(1)
  check(r1 == r2, "an unhooked GameViewport reuses its rect")
  eq(r2.width, ww, "rect width")
  eq(r2.height, wh, "rect height")
  check(not GameViewport.active(), "and stays a pass-through")
end

-- Before the first outdoor visit the palette falls back to the default heal
-- map every frame; SaveData.defaultHealMap answers it without building the
-- heal table defaultHeal returns, and must name the same map.
do
  local SaveData = require("src.core.SaveData")
  local boots = {
    {}, { startMap = "REDS_HOUSE_2F" }, { startMap = "ROUTE_1", startX = 2 },
    { lastHeal = { map = "VIRIDIAN_CITY", x = 1, y = 2 } },
    { lastHeal = { map = "CERULEAN_CITY" }, startMap = "ROUTE_9" },
  }
  for i, boot in ipairs(boots) do
    eq(SaveData.defaultHealMap(boot), SaveData.defaultHeal(boot).map,
      "defaultHealMap matches defaultHeal, case " .. i)
  end
  eq(SaveData.defaultHealMap(nil), SaveData.defaultHeal(nil).map,
    "defaultHealMap matches defaultHeal with no boot table")
  local boot = boots[2]
  collectgarbage("collect")
  collectgarbage("stop")
  local before = collectgarbage("count")
  for _ = 1, 1000 do SaveData.defaultHealMap(boot) end
  local grown = collectgarbage("count") - before
  collectgarbage("restart")
  check(grown < 0.5, ("defaultHealMap builds nothing (%.2f KB over 1000 calls)")
    :format(grown))
end

T.finish("overworld_frame_alloc_perf")
