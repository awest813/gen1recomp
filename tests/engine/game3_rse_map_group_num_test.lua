-- Rse.mapGroupNum reads a map's group and number from the map catalog first.
-- `local g, n = cond and slot:match(...)` kept only the first capture, so n
-- was always nil and every lookup fell through to the name scan.
package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.harness")
love = love or require("tests.love_stub")

local catalog = {
  ["EM_LITTLEROOT_TOWN"] = { 0, 9 },
}
package.loaded["src.import.gba.map_catalog"] = {
  groupNumFor = function(mapId)
    local row = catalog[mapId]
    if row then return row[1], row[2] end
    return nil, nil
  end,
}
package.loaded["src.core.game3.constants"] = {
  versionOf = function() return "emerald" end,
  of = function()
    return { map_groups = { byName = {
      MAP_ROUTE101 = { group = 0, num = 16, name = "Route101" },
    } } }
  end,
}
package.loaded["src.core.game3.profile"] = {
  forSession = function() return { family = "rse", map = { enginePrefix = "EM_" } } end,
}

local Rse = require("src.core.game3.rse.init")

local g, n = Rse.mapGroupNum("EM_LITTLEROOT_TOWN", {})
T.eq(g, 0, "catalog group")
T.eq(n, 9, "catalog number (was dropped by `and`)")

g, n = Rse.mapGroupNum("EM_ROUTE101", {})
T.eq(g, 0, "name fallback group")
T.eq(n, 16, "name fallback number")

T.eq(Rse.mapGroupNum("EM_NOWHERE", {}), nil, "unknown map")
T.eq(Rse.mapGroupNum(nil, {}), nil, "non-string map")

T.finish("game3 rse mapGroupNum")
