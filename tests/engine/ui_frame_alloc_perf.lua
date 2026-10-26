-- Steady frames off the plain overworld build no Lua garbage either: the
-- rarer Renderer:endFrame paths (a DYNAMIC-layout docked box, the battle
-- dim and void veil around the letterbox, the paper surround behind an
-- opaque screen), the Gen 1 battle screen at its command menu and under a
-- message, and the common menus (START, party, list, summary, options,
-- trainer card) with their SGB zone lists.  Same harness as overworld_frame_alloc_perf.lua: the
-- fixture overworld through Game:draw on tests/love_stub, the collector
-- stopped, KB per frame on the interpreter love.js runs.
--   luajit tests/engine/ui_frame_alloc_perf.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
if not _G.love then _G.love = require("tests.love_stub") end
if rawget(_G, "jit") then jit.off() end

-- model LOVE's images, quads and colour state (see
-- overworld_frame_alloc_perf.lua), so the count below is the engine's alone.
-- A shader object too: the battle colours itself through the SGB zone pass
-- only when one compiles, and that is the path every real build takes.
do
  local shader = { send = function() end, hasUniform = function() return true end }
  love.graphics.newShader = function() return shader end
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

-- ------------------------------------------------ Gen 1 battle
local BattleState = require("src.battle.BattleState")
local Pokemon = require("src.pokemon.Pokemon")
local Font = require("src.render.Font")
local Strings = require("src.core.Strings")
Game.save.party = { Pokemon.new(Data, "FIXMON_A", 10, function(_, b) return b end) }

local pressA = false
Game.input.wasPressed = function(_, key) return pressA and key == "a" end
local battle = BattleState.newWild(Game, "FIXMON_C", 10)
Game.stack:push(battle)
check(battle:colorMode(), "the battle takes the SGB zone pass")

-- the intro's first text page, typed out and waiting for A
local n = 0
while not battle.msgPrompt and n < 2000 do frame(); n = n + 1 end
check(battle.msgPrompt, "the intro text waits on its prompt")
steady("a battle frame under a waiting message")

-- A through the intro to the FIGHT / PKMN / ITEM / RUN menu
n = 0
while battle.phase ~= "menu" and n < 5000 do
  pressA = n % 4 == 0
  frame()
  n = n + 1
end
pressA = false
eq(battle.phase, "menu", "the battle reaches its command menu")
steady("a battle frame at the command menu")
battle.player.shownStatus = "PSN"
battle.enemy.shownStatus = "PAR"
steady("the command menu with both statuses up")
battle.player.shownStatus, battle.enemy.shownStatus = nil, nil

-- what the zone pass and the OAM colours still see
do
  local p1, p2 = battle:sgbBattlePals(), battle:sgbBattlePals()
  check(p1 == p2, "the battle palette set is reused while it holds")
  eq(p2[0], Data.palettes.palettes.GREENBAR, "a full player bar is GREENBAR")
  eq(p2[2], Data.palettes.palettes.MEWMON, "the player slot's species palette")
  p2.extra = true
  local p3 = battle:sgbBattlePals()
  check(p3 ~= p2 and p3.extra == nil, "a set someone wrote to is rebuilt")
  local px = battle.player.shownPx
  battle.player.shownPx = 2
  local p4 = battle:sgbBattlePals()
  check(p4 ~= p3, "a bar colour change builds a fresh set")
  eq(p4[0], Data.palettes.palettes.REDBAR, "the low bar turns REDBAR")
  eq(p3[0], Data.palettes.palettes.GREENBAR, "and the old set is left alone")
  battle.player.shownPx = px
end

-- the cached codes the menu labels draw from are what encode returns
do
  local codes = Font.codes("FIGHT")
  local fresh = Font.encode("FIGHT")
  eq(#codes, #fresh, "Font.codes has every glyph")
  for i = 1, #fresh do eq(codes[i], fresh[i], "Font.codes glyph " .. i) end
  check(Font.codes("FIGHT") == codes, "and hands back the cached array")
  check(fresh ~= Font.encode("FIGHT"), "while encode still copies")
  eq(Font.glyphCount("POK\195\169MON"), #Font.split("POK\195\169MON"),
    "glyphCount counts what split does")
  local encode = Font.encode
  local seen
  Font.encode = function(text) seen = text return encode(text) end
  Font.codes("RUN")
  Font.encode = encode
  eq(seen, "RUN", "a replaced encode is still asked")
  eq(Strings("FIGHT", "battle"), "FIGHT", "a context lookup still resolves")
  eq(Strings("%d LEFT", 3), "3 LEFT", "and a format still formats")
end
Game.stack:pop()

-- ------------------------------------------------ menus
local PaletteFX = require("src.render.PaletteFX")
local StartMenu = require("src.ui.StartMenu")
local PartyMenu = require("src.ui.PartyMenu")
local ListMenu = require("src.ui.ListMenu")
local SummaryMenu = require("src.ui.SummaryMenu")
local OptionsMenu = require("src.ui.OptionsMenu")
local TrainerCard = require("src.ui.TrainerCard")
local Runtime = require("src.mods.Runtime")
local Hooks = require("src.mods.Hooks")
local pals = Data.palettes.palettes
local party = Game.save.party
party[2] = Pokemon.new(Data, "FIXMON_A", 10, function(_, b) return b end)
party[3] = Pokemon.new(Data, "FIXMON_A", 10, function(_, b) return b end)
party[3].hp = 1

local menus = {
  { "the START menu", function() return StartMenu.new(Game) end },
  { "the party menu", function() return PartyMenu.new(Game, {}) end },
  { "a list menu", function()
    return ListMenu.new(Game, "ITEMS", { { label = "POTION" }, { label = "CANCEL" } }, {})
  end },
  { "the summary screen", function() return SummaryMenu.new(Game, party[3]) end },
  { "the options menu", function() return OptionsMenu.new(Game, {}) end },
  { "the trainer card", function() return TrainerCard.new(Game, {}) end },
}
for _, m in ipairs(menus) do
  local menu = m[2]()
  Game.stack:push(menu)
  steady(m[1] .. " over the overworld")
  check(Game.stack:top() == menu, m[1] .. " is still up")
  Game.stack:pop()
end

local function zoneIs(z, colors, x, y, w, h, what)
  check(z ~= nil and z.colors == colors and z.x == x and z.y == y
    and z.w == w and z.h == h, what)
end

-- the party menu's zones (BlkPacket_PartyMenu): kept while they hold
do
  local menu = PartyMenu.new(Game, {})
  local z1 = menu:sgbPalettes(Game)
  local z2 = menu:sgbPalettes(Game)
  check(z1 == z2, "the party zone list is reused while it holds")
  eq(#z2, 5, "base, icon column and three bars")
  zoneIs(z2[1], pals.GREENBAR, 0, 0, 160, 144, "the GREENBAR base")
  zoneIs(z2[2], pals.MEWMON, 8, 0, 16, 96, "the MEWMON icon column")
  zoneIs(z2[3], pals.GREENBAR, 40, 8, 56, 8, "a full bar")
  zoneIs(z2[5], pals.REDBAR, 40, 40, 56, 8, "the 1 HP bar")

  party[3].hp = party[3].stats.hp
  local z3 = menu:sgbPalettes(Game)
  check(z3 ~= z2, "a healed bar builds a fresh list")
  zoneIs(z3[5], pals.GREENBAR, 40, 40, 56, 8, "showing the new colour")
  zoneIs(z2[5], pals.REDBAR, 40, 40, 56, 8, "while the old list is untouched")
  check(z3[1] == z2[1] and z3[4] == z2[4], "zones that held are carried over")
  party[3].hp = 1
  local z4 = menu:sgbPalettes(Game)
  eq(#z4, 5, "and back again")

  z4.extra = true
  local z5 = menu:sgbPalettes(Game)
  check(z5 ~= z4 and z5.extra == nil, "a list someone wrote to is rebuilt")
  z5[1].tag = true
  local z6 = menu:sgbPalettes(Game)
  check(z6 ~= z5 and z6[1].tag == nil, "as is one with a zone written to")
  party[3], party[2] = nil, nil
  local z7 = menu:sgbPalettes(Game)
  eq(#z7, 3, "a shorter party drops its bars")
  check(z7[1] == z6[1], "and keeps the base zone")

  -- a render.zones subscriber may keep what it is handed: always fresh
  local saved = Runtime.hooks
  local hooks = Hooks.new()
  Runtime.hooks = hooks
  hooks:wrap("render.zones", function(vanilla, ...) return vanilla(...) end, 0, "test")
  local h1, h2 = menu:sgbPalettes(Game), menu:sgbPalettes(Game)
  check(h1 ~= h2 and h1[1] ~= h2[1], "hooked frames get fresh lists and zones")
  zoneIs(h2[1], pals.GREENBAR, 0, 0, 160, 144, "with the same base")
  local w1, w2 = PaletteFX.wholeNamed(Data, "MEWMON"), PaletteFX.wholeNamed(Data, "MEWMON")
  check(w1 ~= w2, "wholeNamed too")
  -- render.compose is handed the zone lists as well
  hooks = Hooks.new()
  Runtime.hooks = hooks
  hooks:wrap("render.compose", function(vanilla, ...) return vanilla(...) end, 0, "test")
  check(menu:sgbPalettes(Game) ~= menu:sgbPalettes(Game),
    "a render.compose subscriber gets fresh lists too")
  Runtime.hooks = saved

  local n1, n2 = PaletteFX.wholeNamed(Data, "MEWMON"), PaletteFX.wholeNamed(Data, "MEWMON")
  check(n1 == n2, "wholeNamed keeps its list while it holds")
  eq(#n2, 1, "one zone")
  zoneIs(n2[1], pals.MEWMON, 0, 0, 160, 144, "across the screen")
  eq(PaletteFX.wholeNamed(Data, "NO_SUCH_PALETTE"), nil, "an unknown name is nil")

  -- the bottom message: one row per line, empty ones included
  local rows = {}
  local draw = Font.draw
  Font.draw = function(text, x, y)
    if x == 8 and y >= 112 then rows[#rows + 1] = text .. "@" .. y end
    return draw(text, x, y)
  end
  menu.message = "LINE ONE\nLINE TWO\n"
  menu:draw()
  Font.draw = draw
  eq(table.concat(rows, "|"), "LINE ONE@112|LINE TWO@128|@144",
    "the party message prints line by line")
end

T.finish("ui_frame_alloc_perf")
