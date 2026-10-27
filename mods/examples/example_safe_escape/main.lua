-- Gallery: battle.run is the speed roll for RUN in every generation.  The
-- rules that forbid running sit in front of it in each engine (a trainer
-- battle, a no-escape event battle, Mean Look or a wrapping move), so
-- answering `true` here skips only the dice.  Two Gen 3 cases decide inside
-- the roll instead -- a double battle and the Battle Pyramid -- and those
-- keep their vanilla answer.  Gen 3 also asks this roll for the FOE's
-- side (ctx.battler), and a wild mon trying to leave keeps its own odds.
return function(mod)
  mod.hooks:wrap("battle.run", function(next, ctx)
    local battle = ctx and ctx.battle
    if type(battle) == "table" and (battle.double or battle.pyramid) then
      return next(ctx)
    end
    local battler = ctx and ctx.battler
    if type(battler) == "table" and battler.side ~= nil and battler.side ~= "player" then
      return next(ctx)
    end
    return true
  end)
end
