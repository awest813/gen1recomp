-- CONTROLS rebinding, the controls audit: on a Switch the A row starts on
-- SDL "b" (GamepadMap.NX_GAMEPAD_BINDINGS), so binding B to physical A swaps
-- instead of leaving two Bs; SELECT on one half of a swap undoes the swap
-- rather than leaving two rows on one input; an Input:reset (focus loss)
-- under an armed capture does not strand it; and a key the player bound
-- plays its button instead of a hotkey in Red/Blue/Yellow and Gold.
--   luajit tests/engine/rebind_controls_audit_test.lua
package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.harness")
local check, eq = T.check, T.eq
love = love or require("tests.love_stub")

local Input = require("src.core.Input")
local GamepadMap = require("src.core.GamepadMap")
local BindingsMenu = require("src.ui.BindingsMenu")

local function newGame()
  local game = { save = { options = {} }, data = {} }
  game.stack = {
    states = {},
    push = function(self, s) table.insert(self.states, s) end,
    pop = function(self) return table.remove(self.states) end,
    top = function(self) return self.states[#self.states] end,
  }
  game.input = { queue = {}, wasPressed = function(self, b) return self.queue[b] or false end,
                 isDown = function() return false end }
  function game:writeOptions() end
  return game
end

local function press(state, btn)
  state.game.input.queue = { [btn] = true }
  state:update(1 / 60)
  state.game.input.queue = {}
end

local function capturePad(bm, row, button)
  bm.index = row
  press(bm, "a")
  bm:onGamepadPressed(button)
  bm:onGamepadReleased(button)
end

local ROW_A, ROW_B = 5, 6

-- ---- a Switch: B bound to physical A (SDL "b") swaps with the A row
do
  GamepadMap._forceNXForTests = true
  Input:init()
  local game = newGame()
  local bm = BindingsMenu.new(game)
  game.stack:push(bm)
  eq(bm.items[ROW_A].right, "Z/B", "on a Switch the A row reads the button that is A there")
  capturePad(bm, ROW_B, "b")
  bm:commitBindings()
  local pads = Input.padBindings
  eq(pads.b, "b", "physical A is now B")
  eq(pads.a, "a", "and physical B took over A: the pad still has an A")
  GamepadMap._forceNXForTests = nil
end

-- ---- SELECT on one half of a swap gives the other row its input back
do
  Input:init()
  local game = newGame()
  local bm = BindingsMenu.new(game)
  game.stack:push(bm)
  capturePad(bm, ROW_A, "b")
  eq(bm.items[ROW_B].right, "X/A", "binding A to the B button hands B the A button")
  bm.index = ROW_A
  bm:clearBinding(bm.items[ROW_A])
  eq(bm.items[ROW_A].right, "Z/A", "clearing A puts it back on the A button")
  eq(bm.items[ROW_B].right, "X/B", "and B back on the B button")
  bm:commitBindings()
  eq(Input.padBindings.a, "a", "live: A is A")
  eq(Input.padBindings.b, "b", "live: B is B")
  eq(game.save.options.bindings.b, nil, "B's swapped entry is gone, not left at its default")

  -- the same for keys
  bm.index = ROW_A
  press(bm, "a")
  bm:onKeyPressed("x")
  bm:onKeyReleased("x")
  eq(bm.items[ROW_B].right, "Z/B", "binding A to X hands B the Z key")
  bm:clearBinding(bm.items[ROW_A])
  eq(bm.items[ROW_B].right, "X/B", "clearing A gives B its X back")
  bm:commitBindings()
  eq(Input.keyBindings.z, "a", "live: Z is A")
  eq(Input.keyBindings.x, "b", "live: X is B")
end

-- ---- an Input:reset under an armed capture: the capture re-arms
do
  Input:init()
  local game = newGame()
  local bm = BindingsMenu.new(game)
  game.stack:push(bm)
  bm.index = ROW_A
  press(bm, "a")
  check(bm.capture ~= nil and Input.captureArmed, "the row is armed")
  Input:reset() -- alt-tab away and back
  bm:update(1 / 60)
  check(Input.captureArmed, "the next frame re-arms Input's capture queue")
  Input:keypressed("escape")
  bm:update(1 / 60)
  eq(bm.capture, nil, "so Escape still cancels it (Gold reaches the capture only this way)")
end

-- ---- a bound key plays its button in Gold instead of a hotkey
do
  Input:init()
  Input:applyBindings({ a = { key = "2" } })
  local Game2 = require("src.core.Game2")
  local hotkeyCalls = 0
  local fake = setmetatable({ hotkey = function() hotkeyCalls = hotkeyCalls + 1 return true end },
    { __index = Game2 })
  Game2.keypressed(fake, "2")
  eq(hotkeyCalls, 0, "Gold: a key bound to A never reaches the COLOR hotkey")
  check(Input:isDown("a"), "it presses A")
  Input:keyreleased("2")
  Input:applyBindings(nil)
  Game2.keypressed(fake, "2")
  eq(hotkeyCalls, 1, "unbound, 2 is still the hotkey")
end


-- ---- Red's rebind of A to Q swaps with FireRed's L, which Red does not show
do
  Input:init()
  local game = newGame()
  local bm = BindingsMenu.new(game)
  game.stack:push(bm)
  bm.index = ROW_A
  press(bm, "a")
  bm:onKeyPressed("q")
  bm:onKeyReleased("q")
  local b = game.save.options.bindings
  eq(b.a and b.a.key, "q", "A is on Q")
  eq(b.l and b.l.key, "z", "and FireRed's L took A's Z, not left reading Q")
end

-- ---- Gold reads and writes the same bindings as Red and FireRed
do
  local SaveData = require("src.core.SaveData")
  local GoldSave = require("src.core.gen2.Save")
  local opts = SaveData.loadOptions()
  opts.bindings = { a = { key = "k" } }
  SaveData.saveOptions(opts)
  local gold = GoldSave.loadOptions()
  eq(gold.bindings and gold.bindings.a and gold.bindings.a.key, "k", "Gold loads Red's rebind")
  gold.bindings = { b = { key = "j" } }
  GoldSave.saveOptions(gold)
  local red = SaveData.loadOptions()
  eq(red.bindings and red.bindings.b and red.bindings.b.key, "j", "and Red loads Gold's")
  eq(red.gold and red.gold.bindings, nil, "with no second copy inside Gold's block")
  gold.bindings = nil -- RESET ALL
  GoldSave.saveOptions(gold)
  eq(SaveData.loadOptions().bindings, nil, "a reset in Gold clears them everywhere")
end

T.finish("rebind controls audit")
