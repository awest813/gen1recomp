-- Driver: the every-game gallery mods (mods/examples/example_exp_boost,
-- example_lucky_ball, example_safe_escape, example_quiet_alarm) measured
-- against the real engine of whichever game is booted.  It starts a real
-- wild battle and calls the functions those hooks wrap -- the run roll, the
-- ball throw, the EXP award and the low-HP alarm switch -- and prints one
-- line per mechanic, so a run with the mods off and a run with them on can be
-- compared:
--
--   XG run    <escapes out of N, slow lead against a fast foe>
--   XG catch  <catches out of N, POKE BALL at a full-HP ONIX>
--   XG exp    <EXP one KO awards>
--   XG alarm  <low-HP loop starts with the alarm switched on>
--
--   POKEPORT_GAME=yellow|gold|firered tools/run_driver.sh <version> <id> \
--     tests/drivers/xgen_gallery_mods.lua
local U = require("tests.drivers.util")
local OUT = os.getenv("POKEPORT_SHOT_DIR") or "/tmp/xgen_gallery_mods"
local N = 400

local function report(name, value) print(("XG %-6s %s"):format(name, tostring(value))) end

-- ------- Red / Blue / Yellow

local function gen1(game)
  U.newGame(game)
  U.wait(60)
  local Pokemon = require("src.pokemon.Pokemon")
  local BattleState = require("src.battle.BattleState")
  local Experience = require("src.battle.Experience")
  local Sound = require("src.core.Sound")
  local lead = Pokemon.new(game.data, "PIDGEY", 10)
  game.save.party = { lead }
  U.teleport(game, "ROUTE_1", 5, 5, "down")
  local battle = BattleState.newWild(game, "ONIX", 20)
  battle.onFinish = function() end
  game.overworld:pushBattle(battle)
  U.wait(200)
  U.shot(game, OUT .. "/battle.png")

  local escapes = 0
  for _ = 1, N do
    battle.runAttempts = 1
    if battle:runRoll(10, 200) then escapes = escapes + 1 end
  end
  report("run", escapes)

  local caught = 0
  for _ = 1, N do
    if battle:catchAttempt("POKE_BALL") then caught = caught + 1 end
  end
  report("catch", caught)

  local before = lead.exp
  Experience.apply(game.data, lead, game.data.pokemon.ONIX, 20, false, 1, false)
  report("exp", lead.exp - before)

  local started = 0
  local realStart = Sound.startLoop
  Sound.startLoop = function(...) started = started + 1 end
  -- the red-bar test is the input, not what is measured: the switch is
  battle.lowHealthAlarmActive = function() return true end
  battle:updateFx()
  Sound.startLoop = realStart
  report("alarm", started)
end

-- ------- Gold / Silver / Crystal

local function gen2(game)
  U.wait(200)
  local Mon = require("src.battle.gen2.Mon")
  local Catching = require("src.battle.gen2.Catching")
  local Sound = require("src.core.Sound")
  local data = game.data
  local lead = Mon.new(data, "PIDGEY", 10)
  game.save.party = { lead }
  local world = game.world
  world:warpToMapId("ROUTE_29", 50, 8, "down")
  U.wait(60)
  world:startBattle({ wild = Mon.new(data, "ONIX", 20) })
  local screen
  for _ = 1, 1200 do
    screen = game.stack:top()
    if screen and screen.screenId == "Gen2BattleState" and screen.battle then break end
    U.wait(1)
  end
  if not (screen and screen.battle) then return report("error", "no battle screen") end
  U.wait(200)
  U.shot(game, OUT .. "/battle.png")
  local battle = screen.battle

  local escapes = 0
  for _ = 1, N do
    battle.runAttempts = 1
    if battle:runRoll(10, 200) then escapes = escapes + 1 end
  end
  report("run", escapes)

  local caught = 0
  for _ = 1, N do
    if Catching.attempt(screen:catchOptions("POKE_BALL")) then caught = caught + 1 end
  end
  report("catch", caught)

  local mon = battle.party[1]
  local before = mon.experience
  battle:giveExperiencePass(battle.enemy, data.pokemon.ONIX, { 1 }, 1, false, true)
  report("exp", mon.experience - before)

  local started = 0
  local realStart = Sound.startLoop
  Sound.startLoop = function(...) started = started + 1 end
  screen.lowHealthAlarmActive = function() return true end
  screen:updateAlarm()
  Sound.startLoop = realStart
  report("alarm", started)
end

-- ------- FireRed / LeafGreen / Emerald

local function gen3(game)
  for _ = 1, 900 do
    if game.phase == "boot" and game.boot then break end
    U.wait(1)
  end
  game:_handleBootAction({ action = "new_game", name = "RED" })
  U.wait(240)
  local Runtime = require("src.core.game3.runtime")
  local Party = require("src.core.game3.party")
  local BattleBridge = require("src.core.game3.battle_bridge")
  local Battle = require("src.core.game3.battle")
  local Engine = require("src.core.game3.battle.engine")
  local Catching = require("src.core.game3.battle.catching")
  local Experience = require("src.core.game3.battle.experience")
  local Encounters = require("src.core.game3.encounters")
  local Map = require("src.core.game3.map")
  local Audio = require("src.core.game3.audio")
  local Constants = require("src.core.game3.constants")
  local session = Runtime.getSession()
  local C = Constants.of(Constants.versionOf(session))
  Encounters.onStep = function() return nil end
  Map.load(nil, game, "FR_ROUTE_1", { x = 10, y = 20, facing = "down" })
  U.wait(40)
  session.party = {}
  -- not RATTATA: its RUN AWAY ability escapes before the roll is asked
  Party.giveMon(session, C.species.byName.SPECIES_PIDGEY, 10, "")
  local ok = BattleBridge.startWild(Runtime._mod, game,
    { species = C.species.byName.SPECIES_ONIX, level = 20 }, { done = function() end })
  for _ = 1, 3000 do
    if Battle.isActive() then break end
    U.wait(1)
  end
  if not (ok and Battle.isActive()) then return report("error", "no battle") end
  U.wait(200)
  U.shot(game, OUT .. "/battle.png")
  local st, ad = Battle.getState(), Battle._adapter

  local escapes = 0
  local mySpe, foeSpe = st.player.mon.speed, st.enemy.mon.speed
  st.player.mon.speed, st.enemy.mon.speed = 10, 200
  for _ = 1, N do
    st.fleeAttempts = 0
    if Engine.tryFlee(st, ad, st.player) then escapes = escapes + 1 end
  end
  st.player.mon.speed, st.enemy.mon.speed = mySpe, foeSpe
  report("run", escapes)

  local caught = 0
  for _ = 1, N do
    if Catching.tryCatch(4, st.enemy, st, session, nil) then caught = caught + 1 end
  end
  report("catch", caught)

  local gained = 0
  for _, award in ipairs(Experience.awardFoe(st, st.enemy, {})) do
    gained = gained + (award.amount or 0)
  end
  report("exp", gained)

  local started = 0
  local realPlay = Audio.playSe
  Audio.playSe = function(...) started = started + 1 end
  Battle._lowHpSong = false
  st.player.mon.hp = 1
  local Anim = require("src.core.game3.battle.anim")
  local realPresent = Anim.present
  Anim.present = function() return nil end
  Battle._updateLowHpMusic()
  Anim.present = realPresent
  Audio.playSe = realPlay
  report("alarm", started)
end

return function(game)
  io.stdout:setvbuf("line")
  local gen = require("src.core.GameVersion").generation()
  local L = game.mods
  for _, id in ipairs({ "example_exp_boost", "example_lucky_ball",
                        "example_safe_escape", "example_quiet_alarm" }) do
    local m = L and L.mods and L.mods[id]
    print(("XG mod %-20s %s"):format(id, m and tostring(m.state) or "absent"))
  end
  print("XG gen " .. tostring(gen))
  local run = ({ gen1, gen2, gen3 })[gen]
  local ok, err = pcall(run, game)
  if not ok then report("error", err) end
  love.event.quit(0)
end
