-- Gallery: battle.low_health_alarm is the on/off switch for the beeping
-- under a red HP bar, in every generation.  ctx.on is what the engine is
-- about to do; turning it off and letting vanilla act stops the loop with
-- that game's own sound call, so nothing here knows which game it is.
return function(mod)
  mod.hooks:wrap("battle.low_health_alarm", function(next, ctx)
    if type(ctx) == "table" then ctx.on = false end
    return next(ctx)
  end)
end
