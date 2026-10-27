-- Gallery: one hook, every game.  exp.gain wraps the per-mon EXP award in
-- Red / Blue / Yellow (src/battle/Experience.lua), Gold / Silver / Crystal
-- (src/battle/gen2/Battle.lua) and FireRed / LeafGreen / Emerald
-- (src/core/game3/battle/experience.lua).  Each passes the same ctx keys
-- (defeatedDef, level, isTrainer, participants, traded, mon), and the
-- vanilla answer already carries the game's own trainer, traded, Lucky Egg
-- and EXP. SHARE factors, so scaling it scales the whole formula.
local MAX_GAIN = 0xFFFF -- the award is a 16-bit word in all three games

return function(mod)
  mod.options:define({
    { key = "rate", label = "EXP RATE", type = "choice", default = "2",
      choices = { { "1.5X", "1.5" }, { "2X", "2" }, { "3X", "3" } } },
    { key = "trainers", label = "TRAINERS ONLY", type = "toggle", default = false },
  })

  mod.hooks:wrap("exp.gain", function(next, ctx)
    local gained = next(ctx)
    if type(gained) ~= "number" or gained <= 0 then return gained end
    if mod.options:get("trainers") and not ctx.isTrainer then return gained end
    local rate = tonumber(mod.options:get("rate")) or 2
    return math.min(MAX_GAIN, math.floor(gained * rate))
  end)
end
