-- Gen 1 menus, from a menu audit: each case is a bug a player could hit.
--   luajit tests/engine/gen1_menu_audit_test.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local T = require("tests.harness")
local check, eq = T.check, T.eq
love = love or require("tests.love_stub")

local function newGame(party)
  local game = {
    data = { pokemon = { CHANSEY = { name = "CHANSEY" }, RATTATA = { name = "RATTATA" } },
             moves = {}, text = { _NotHealthyEnoughText = "Not healthy\nenough.{PROMPT}" } },
    save = { party = party, inventory = {}, options = {}, flags = {} },
    overworld = { map = { def = { tileset = "OVERWORLD" }, id = "PALLET_TOWN" },
                  partyKnows = function() return nil end },
  }
  game.stack = {
    states = {},
    push = function(self, s) table.insert(self.states, s) end,
    pop = function(self) return table.remove(self.states) end,
    top = function(self) return self.states[#self.states] end,
  }
  game.input = {
    queue = {},
    wasPressed = function(self, btn) return self.queue[btn] or false end,
    isDown = function() return false end,
  }
  return game
end

local function press(state, btn)
  state.game.input.queue = { [btn] = true }
  state:update(1 / 60)
  state.game.input.queue = {}
end

-- ------- PartyMenu: B while choosing where to SWITCH (or whom to SOFTBOIL)
do
  local a = { species = "CHANSEY", hp = 100, stats = { hp = 100 }, level = 30, moves = {} }
  local b = { species = "RATTATA", hp = 20, stats = { hp = 20 }, level = 5, moves = {} }
  local game = newGame({ a, b })
  local PartyMenu = require("src.ui.PartyMenu")
  local cancelled = false
  local pm = PartyMenu.new(game, { onCancel = function() cancelled = true end })
  game.stack:push(pm)
  pm.swapFrom = 1
  press(pm, "b")
  eq(pm.swapFrom, nil, "B drops the pending SWITCH")
  eq(game.stack:top(), pm, "and the party list stays open")
  eq(cancelled, false, "without leaving to the START menu")
  pm.softboiledFrom = 1
  press(pm, "b")
  eq(pm.softboiledFrom, nil, "B drops the SOFTBOILED target pick")
  eq(game.stack:top(), pm, "and stays on the party list")
  press(pm, "b")
  eq(#game.stack.states, 0, "a plain B still leaves")
  eq(cancelled, true, "through onCancel")
end

-- ------- OPTION: TEXT SPEED walks by direction and stops at the ends
do
  local game = newGame({})
  game.save.options.textSpeed = 3 -- MEDIUM
  local OptionsMenu = require("src.ui.OptionsMenu")
  local ok, menu = pcall(OptionsMenu.new, game, {})
  if check(ok, "OPTION opens on a bare game (" .. tostring(menu) .. ")") then
    local row
    local function find(rows)
      for _, r in ipairs(rows or {}) do
        if r.id == "textSpeed" then row = r end
        if r.members then find(r.members) end
      end
    end
    find(menu.rows)
    if check(row ~= nil, "the TEXT SPEED row exists") then
      row.step(game, -1)
      eq(game.save.options.textSpeed, 1, "Left from MEDIUM is FAST")
      eq(row.step(game, -1), false, "Left at FAST stays at FAST")
      eq(game.save.options.textSpeed, 1, "and does not wrap to SLOW")
      row.step(game, 1); row.step(game, 1)
      eq(game.save.options.textSpeed, 5, "Right twice reaches SLOW")
      row.step(game, 1, true)
      eq(game.save.options.textSpeed, 1, "A still cycles round")
    end
  end
end

-- ------- OPTION: A on an inert row (a mod's information line) stays put
do
  local game = newGame({})
  local OptionsMenu = require("src.ui.OptionsMenu")
  local ok, menu = pcall(OptionsMenu.new, game, {})
  if ok then
    local rows = menu.view or menu.rows
    table.insert(rows, 1, { id = "info", label = "INFO", value = function() return "" end })
    game.stack:push(menu)
    menu.index = 1
    press(menu, "a")
    eq(game.stack:top(), menu, "A on a row with nothing to do does not leave OPTION")
  end
end

-- ------- Menu: an empty item list (a mod hook) does not crash on A
do
  local game = newGame({})
  local Menu = require("src.ui.Menu")
  local ok, m = pcall(Menu.new, game, {}, { cancelable = true, noSound = true })
  if check(ok, "an empty menu can be built (" .. tostring(m) .. ")") then
    game.stack:push(m)
    local okA, err = pcall(press, m, "a")
    check(okA, "A on an empty menu does nothing (" .. tostring(err) .. ")")
  end
end

-- ------- ListMenu: removing a row near the end keeps no blank bottom row
do
  local game = newGame({})
  local ListMenu = require("src.ui.ListMenu")
  local items = {}
  for i = 1, 8 do items[i] = { label = "ROW" .. i } end
  local list = ListMenu.new(game, "LIST", items, {})
  local visible = list.cursorRows or list.rows
  list.index, list.scroll = #items, #items - visible
  list:removeCurrent()
  check(list.scroll <= math.max(0, #list.items - visible),
    "the list scrolls back so its last row is at the bottom")
  check(list.index >= list.scroll + 1 and list.index <= list.scroll + visible,
    "and the cursor stays on screen")
end

-- ------- Marquee: characters, not bytes
do
  local Marquee = require("src.ui.Marquee")
  eq(Marquee.clip("Pokémon", 5), "Pokém", "a clip keeps é whole")
  local a = Marquee.scroll("A LONG STATUS LINE HERE", 10, "one")
  local b = Marquee.scroll("ANOTHER LONG LINE HERE!", 10, "two")
  check(a ~= nil and b ~= nil, "two lines can scroll at once")
end

T.finish("gen1 menu audit")
