-- Gen 2 / Gen 3 menus, from a menu audit: each case is a bug a player could hit.
--   luajit tests/engine/gen23_menu_audit_test.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
love = love or require("tests.love_stub")
local T = require("tests.harness")
local check, eq = T.check, T.eq

-- ------- Gen 3: TOUCH PAD / VIBRATION / KEY BAR live in this game's block
do
  local env = os.getenv
  os.getenv = function(k) if k == "POKEPORT_TOUCH" then return "1" end return env(k) end
  local Rows = require("src.ui.game3.option_rows")
  local Options = require("src.core.game3.options")
  local ctx = { options = { touchControls = { enabled = true, layout = "red" } } }
  local rows = Rows.build(ctx, { textSpeed = true, battleScene = true, battleStyle = true,
    sound = true, buttonMode = true, frameType = true })
  os.getenv = env
  local touch
  for _, r in ipairs(rows) do if r.id == "touchControls" then touch = r end end
  if check(touch ~= nil, "the TOUCH PAD row is listed when touch is on") then
    local TouchControls = require("src.core.TouchControls")
    local applied
    local realApply = TouchControls.applyOptions
    TouchControls.applyOptions = function(_, o) applied = o end
    eq(touch.value(ctx), "ON", "it starts ON")
    touch.step(ctx, 1)
    TouchControls.applyOptions = realApply
    local g3 = ctx.options.game3 or {}
    eq(g3.touchControls and g3.touchControls.enabled, false,
      "turning it off writes options.game3, which Game3:applyOptions reads first")
    eq(Options.block(ctx.options).touchControls, nil, "not the per-game save block nothing reads")
    -- the read Game3:applyOptions makes (src/core/Game3.lua)
    local o = ctx.options
    local seen = (type(o.game3) == "table" and o.game3.touchControls) or o.touchControls
    eq(seen and seen.enabled, false, "so the game sees the pad off on its next apply")
    eq(ctx.options.touchControls.enabled, true, "and leaves Red's shared pad alone")
    eq(applied and applied.touchControls and applied.touchControls.enabled, false,
      "the pad is applied with the new value")
    eq(touch.value(ctx), "OFF", "and reads OFF")
  end
  local audio
  for _, r in ipairs(rows) do if r.id == "group.audio" then audio = r end end
  local inAudio = false
  for _, g in ipairs(Rows.GROUPS) do
    if g.id == "group.audio" then
      for _, id in ipairs(g.members) do if id == "audioMode" then inAudio = true end end
    end
  end
  check(inAudio, "AUDIO MODE sits in the AUDIO group, as on Gen 1 and Gen 2")
end

-- ------- Gen 2: OPTION saves as it changes, not only on the way out
do
  local OptionsMenu = require("src.ui.gen2.OptionsMenu")
  local DeferredWrite = require("src.core.DeferredWrite")
  local saved = 0
  local options = {}
  local game = { options = options, persistOptions = function() saved = saved + 1 end }
  DeferredWrite.cancel("options")
  OptionsMenu.changed({ game = game, options = options })
  eq(DeferredWrite.isPending("options"), true, "a change schedules a save")
  DeferredWrite.flush("options")
  eq(saved, 1, "which writes the options when flushed (focus loss)")
  OptionsMenu.changed({ game = game, options = {} })
  eq(DeferredWrite.isPending("options"), false, "a copy of the options is never written over them")
end

T.finish("gen2/3 menu audit")
