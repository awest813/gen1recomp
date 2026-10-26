package.path = "./?.lua;./?/init.lua;" .. package.path
love = love or require("tests.love_stub")
local T = require("tests.harness")
local Convert = require("src.online.Convert")
local Mon = require("src.battle.gen2.Mon")

local gen1Data = {
  pokemon = {
    TESTMON = { id = "TESTMON", name = "TESTMON", index = 1, dex = 1, types = { "GRASS", "POISON" },
      baseStats = { hp = 45, attack = 49, defense = 49, speed = 45, special = 65 },
      catchRate = 45, growthRate = "MEDIUM_SLOW" },
  },
  moves = {
    TACKLE = { id = "TACKLE", name = "TACKLE", index = 33, pp = 35 },
    VINE_WHIP = { id = "VINE_WHIP", name = "VINE WHIP", index = 22, pp = 10 },
    BODY_SLAM = { id = "BODY_SLAM", name = "BODY SLAM", index = 34, pp = 15 },
  },
}

local gen2Data = {
  pokemon = {
    TESTMON = { id = "TESTMON", name = "TESTMON", types = { "GRASS", "POISON" },
      baseStats = { hp = 45, attack = 49, defense = 49, speed = 45, specialAttack = 65, specialDefense = 65 },
      growthRate = "GROWTH_MEDIUM_SLOW", genderRatio = 0x1f },
    growthRates = {
      GROWTH_MEDIUM_SLOW = { numerator = 6, denominator = 5, squared = -15, linear = 100, constant = 140 },
    },
  },
  moves = {
    TACKLE = { id = "TACKLE", name = "TACKLE", pp = 35 },
    VINE_WHIP = { id = "VINE_WHIP", name = "VINE WHIP", pp = 10 },
    BODY_SLAM = { id = "BODY_SLAM", name = "BODY SLAM", pp = 15 },
    GIGA_DRAIN = { id = "GIGA_DRAIN", name = "GIGA DRAIN", pp = 5 },
    SWEET_SCENT = { id = "SWEET_SCENT", name = "SWEET SCENT", pp = 20 },
  },
  items = {},
}

local DVS = { attack = 15, defense = 14, speed = 13, special = 12 }

local function gen2Mon(moves)
  local dvs = {}
  for k, v in pairs(DVS) do dvs[k] = v end
  dvs.hp = Mon.hpDV(dvs)
  local statExp = { hp = 0, attack = 0, defense = 0, speed = 0, special = 0 }
  local stats = Mon.stats(gen2Data.pokemon.TESTMON.baseStats, dvs, 30, statExp)
  return { species = "TESTMON", level = 30,
    experience = Mon.experienceForLevel(Mon.growthFor(gen2Data, "GROWTH_MEDIUM_SLOW"), 30),
    dvs = dvs, statExp = statExp, stats = stats, hp = stats.hp, maxHp = stats.hp,
    happiness = 128, pokerus = 0, caughtLevel = 5, moves = moves,
    nickname = "SPROUT", ot = "GOLD", otName = "GOLD", otId = 4321, traded = false, isEgg = false }
end

local illegal = gen2Mon({ { id = "TACKLE", pp = 35, maxPp = 35 }, { id = "GIGA_DRAIN", pp = 5, maxPp = 5 } })

do
  local out, reason = Convert.toGen1(illegal, gen2Data, gen1Data)
  T.check(out == nil and reason == "move_too_new", "a Gen 2 move refuses the Time Capsule trade")
  local fixed, report = Convert.toGen1(illegal, gen2Data, gen1Data,
    { moves = { "BODY_SLAM", "SWEET_SCENT", "VINE_WHIP", "BODY_SLAM" } })
  T.check(fixed ~= nil, "the recommended moveset lets it through")
  local ids = {}
  for _, mv in ipairs(fixed and fixed.moves or {}) do ids[#ids + 1] = mv.id end
  T.eq(table.concat(ids, ","), "BODY_SLAM,VINE_WHIP", "moves Gen 1 lacks and duplicates are dropped")
  T.eq(fixed and fixed.moves[1].pp, 15, "replacement moves start at full PP")
  T.eq(fixed and fixed.moves[1].ppUps, 0, "and no PP Ups")
  local said = false
  for _, row in ipairs(report and report.changed or {}) do
    if row.kind == "moves" then said = true end
  end
  T.check(said, "the conversion report lists the replaced moveset")
  T.eq(#illegal.moves, 2, "the source record is not modified")
  local lines, legal = Convert.preview(illegal, 2, 1, gen2Data, gen1Data, { moves = { "BODY_SLAM" } })
  T.check(legal and table.concat(lines, "|"):find("RECOMMENDED", 1, true) ~= nil, "the preview uses the replacement")
  local still, why = Convert.toGen1(illegal, gen2Data, gen1Data, { moves = { "GIGA_DRAIN" } })
  T.check(still == nil and why == "move_too_new", "a set with no Gen 1 move keeps the refusal")
end

T.finish("time_capsule_recommend")
