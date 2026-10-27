-- Gallery: a second roll on a failed catch.  catch.rate wraps the whole
-- ball throw in every generation and is called as (ball, mon, def, opts);
-- its answer is `caught, detail` (Gen 1 and Gen 3: the shake count, Gen 2:
-- the final rate).  Calling `next` again is simply another vanilla throw,
-- with that game's own formula, ball bonus and status bonus.
return function(mod)
  mod.options:define({
    { key = "tries", label = "ROLLS PER BALL", type = "choice", default = "2",
      choices = { { "2", "2" }, { "3", "3" } } },
  })

  mod.hooks:wrap("catch.rate", function(next, ball, mon, def, opts)
    local tries = tonumber(mod.options:get("tries")) or 2
    local caught, detail = next(ball, mon, def, opts)
    for _ = 2, tries do
      if caught then break end
      caught, detail = next(ball, mon, def, opts)
    end
    return caught, detail
  end)
end
