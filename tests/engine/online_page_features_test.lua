-- The PK:GB launcher's Online page (src/launcher/OnlinePage.lua and the
-- views in src/launcher/online/), headless, against a scripted relay
-- client: the features past host / join / ready / trade.  No pokered
-- cite: port-only online UI.
--
-- Pins: Gen 3 trades use the link ruleset and battles the chosen format
-- (Multi seats four); Not ready, the rematch prompt and the relay's clock;
-- the host's Kick and Close; private rooms and the PIN prompt; watching a
-- battle; the players list, sending and answering invites; battle rules;
-- PC box picks; the join timeout and the lost-connection notice; the web
-- build's message; an invite code the app was opened with; and that every
-- control fits a phone.
--   luajit tests/engine/online_page_features_test.lua

package.path = "./?.lua;./?/init.lua;" .. package.path
love = love or require("tests.love_stub")
love.graphics.setLineJoin = love.graphics.setLineJoin or function() end
love.graphics.newShader = love.graphics.newShader or function() return {} end

local T = require("tests.harness")
local check, eq = T.check, T.eq

-- saves: Gold and FireRed are imported with one save each
local GAMES = { gold = true, firered = true }
package.loaded["src.core.SaveData"] = {
  listSlots = function(version)
    if not GAMES[version] then return {} end
    return { { id = "slot1", exists = true, name = "TRAINER", meta = { timeText = "1:00",
      badges = 1, dexCount = 5 } } }
  end,
  activeSlot = function() return "slot1" end,
  setActiveSlot = function() return true end,
  loadOptions = function() return {} end,
  saveOptions = function() return true end,
}
package.loaded["src.import.CacheContract"] = setmetatable({
  isReady = function(version) return GAMES[version] == true end,
  isImported = function(version) return GAMES[version] == true end,
}, { __index = require("src.import.CacheContract") })

-- profiles: one per (game, ruleset, rule), as ArenaData would make them
local profileCalls = {}
local G3_ACTIVITY = { battle_single = "g3_single", battle_double = "g3_double",
  battle_multi = "g3_multi", trade = "g3_link" }
package.loaded["src.online.ArenaData"] = {
  profile = function(version, kind, _, rule, rulesetId)
    profileCalls[#profileCalls + 1] = { version = version, rule = rule, rulesetId = rulesetId }
    local gen3 = version == "firered"
    return { engine = gen3 and 3 or 2, version = version, kind = kind or "vanilla",
      engineVersion = "1", fingerprint = "f00d",
      rulesetId = rulesetId or (gen3 and "g3_single" or "gen2"),
      rule = { partySize = rule and rule.partySize or 3, minLevel = rule and rule.minLevel,
               maxLevel = rule and rule.maxLevel, forceLevel = rule and rule.forceLevel } }
  end,
  equal = function(a, b)
    return a.version == b.version and a.rulesetId == b.rulesetId
  end,
  rulesetFor = function(activity) return G3_ACTIVITY[activity] end,
}

-- the save: four in the party, two in PC box 3
local PARTY, BOX = {}, {}
for i = 1, 4 do PARTY[i] = { species = 150 + i, level = 20 + i } end
BOX[1] = { species = 200, level = 50 }
BOX[2] = { species = 201, level = 51 }
local function monAt(ref)
  if type(ref) == "number" then return PARTY[ref] end
  return ref.box == 3 and BOX[ref.index] or nil
end
package.loaded["src.online.TeamPick"] = {
  readSlot = function(version)
    return { party = PARTY, trainerName = "TRAINER", generation = version == "firered" and 3 or 2 }
  end,
  candidates = function(source)
    local out = {}
    for i, mon in ipairs(source.party) do out[#out + 1] = { where = "party", index = i, mon = mon } end
    for i, mon in ipairs(BOX) do
      out[#out + 1] = { where = "box", box = 3, index = i, mon = mon, source = "BOX 3" }
    end
    return out
  end,
  validate = function(_, team, rule)
    if #team ~= rule.partySize then return false, "pick " .. rule.partySize end
    for _, ref in ipairs(team) do if not monAt(ref) then return false, "missing" end end
    return true
  end,
  pack = function(_, team, generation)
    local out = {}
    for i, ref in ipairs(team) do
      local mon = monAt(ref)
      -- Gen 1/2 packed mons name their species, Gen 3 ones number it
      out[i] = { species = generation == 3 and mon.species or ("MON" .. mon.species), level = mon.level }
    end
    return out
  end,
}
package.loaded["src.box.Catalog"] = {
  describe = function(_, mon) return { name = "MON" .. mon.species, level = mon.level } end,
}

-- the relay client, scripted
local C = { state = "offline", handlers = {}, sent = {}, lobby = {}, rooms = {}, watch = {},
  invites = {}, now = 1000000, profiles = {} }
local function record(kind, ...) C.sent[#C.sent + 1] = { kind = kind, ... } end
local function last(kind)
  for i = #C.sent, 1, -1 do if C.sent[i].kind == kind then return C.sent[i] end end
end
local function count(kind)
  local n = 0
  for _, m in ipairs(C.sent) do if m.kind == kind then n = n + 1 end end
  return n
end
local session = { send = function() end, poll = function() end, close = function() end }
package.loaded["src.online.Client"] = {
  on = function(e, fn) C.handlers[e] = fn end,
  off = function(e) C.handlers[e] = nil end,
  state = function() return C.state end,
  error = function() return C.err end,
  you = function() return C.state == "online" and { id = "me", name = "TRAINER#123" } or nil end,
  room = function() return C.room end,
  lobby = function() return C.lobby end,
  openRooms = function() return C.rooms end,
  watchable = function() return C.watch end,
  counts = function() return { players = #C.lobby + 1, openRooms = #C.rooms } end,
  invites = function() return C.invites end,
  serverTime = function() return C.now end,
  profiles = function() return C.profiles end,
  setProfiles = function(list) C.profiles = list record("profiles", list) end,
  roomSession = function() return session end,
  createRoom = function(opts) record("create", opts) C.pending = { id = 1 } return C.pending end,
  joinRoom = function(id, as, profile, pin)
    record("join", id, as, profile, pin) C.pending = { id = 2 } return C.pending
  end,
  joinRoomByInvite = function(token, as, profile)
    record("invite", token, as, profile) C.pending = { id = 3 } return C.pending
  end,
  ready = function(party, digest) record("ready", party, digest) end,
  report = function(result) record("report", result) end,
  leaveRoom = function() record("leave") C.room = nil end,
  inviteToken = function(room) record("token", room) end,
  kick = function(id) record("kick", id) end,
  closeRoom = function() record("close") end,
  invite = function(to, activity, detail, profile)
    record("sendInvite", to, activity, detail, profile)
    return { to = to, activity = activity, state = "sending" }
  end,
  replyInvite = function(id, accept) record("reply", id, accept) return true end,
  sendRaw = function(msg) record("raw", msg) end,
}
local connectStarts = {}
package.loaded["src.online.Connect"] = {
  name = function() return C.state == "online" and "TRAINER#123" or nil end,
  state = function() return C.state end,
  busy = function() return false end,
  error = function() return C.err end,
  start = function(opts) connectStarts[#connectStarts + 1] = opts end,
  setName = function() return true end,
  disconnect = function() C.state = "offline" end,
}

local Kit = require("src.ui.kit.Kit")
local Launcher = require("src.launcher.Launcher")

local launches = {}
local function fresh(version)
  local l = Launcher.new(function(v, cartId, o)
    launches[#launches + 1] = { version = v, cartId = cartId, opts = o }
  end, { noUpdateCheck = true })
  l.selected = version or "gold"
  l:openOnline()
  return l, l.online
end

local W, H = 1280, 720
local function window(w, h)
  W, H = w, h
  love.graphics.getDimensions = function() return w, h end
  love.graphics.getPixelDimensions = function() return w, h end
end
local realPrint = love.graphics.print
local function drawText(l)
  local seen = {}
  love.graphics.print = function(str, ...) seen[#seen + 1] = tostring(str) return realPrint(str, ...) end
  local ok, err = pcall(l.draw, l)
  love.graphics.print = realPrint
  check(ok, "the launcher draws: " .. tostring(err))
  return table.concat(seen, "\n")
end
local function has(text, needle) return text:find(needle, 1, true) ~= nil end

-- Every control the page draws fits the window and is tall enough to tap.
local function fits(l, what)
  drawText(l)
  Kit.audit = {}
  drawText(l)
  local list = Kit.audit
  Kit.audit = nil
  local bad
  for _, c in ipairs(list) do
    if c.class == "control" and (c.x < -1 or c.x + c.w > W + 1 or c.h < Kit.tapMin() - 0.5) then
      bad = bad or ("%s at %d+%d (h %d)"):format(c.label, c.x, c.w, c.h)
    end
  end
  check(bad == nil, what .. ": every control fits at " .. W .. "x" .. H .. (bad and (": " .. bad) or ""))
  -- no two visible controls overlap (scrolled content under the launcher's
  -- tab bar is clipped away, so only controls inside their clip count)
  local function visible(c)
    local k = c.clip
    return c.class == "control"
      and (not k or (c.y >= k.y - 1 and c.y + c.h <= k.y + k.h + 1))
  end
  local clash
  for i = 1, #list do
    local a = list[i]
    for j = i + 1, #list do
      local b = list[j]
      if not clash and visible(a) and visible(b) and a.x < b.x + b.w - 1 and b.x < a.x + a.w - 1
          and a.y < b.y + b.h - 1 and b.y < a.y + a.h - 1 then
        clash = a.label .. " / " .. b.label
      end
    end
  end
  check(clash == nil, what .. ": no controls overlap at " .. W .. "x" .. H .. (clash and (": " .. clash) or ""))
end

window(1280, 720)
local l, page
C.state = "online"

-- ------------------------------------------------- 1: Gen 3 trade ruleset
local fl, fpage = fresh("firered")
fl:update(0)
fpage:host("trade")
local created = last("create")[1]
eq(created.intent, "trade", "FireRed hosts a trade room")
eq(created.profile.rulesetId, "g3_link", "a Gen 3 trade uses the link ruleset, not g3_single")
eq(created.maxSpectators, 0, "a trade room takes no spectators")
fpage.hostOpts.format = "double"
fpage:host("battle")
eq(last("create")[1].profile.rulesetId, "g3_double", "a Double Battle uses g3_double")
eq(last("create")[1].seats, 2, "for two trainers")
fpage.hostOpts.format = "multi"
fpage:host("battle")
eq(last("create")[1].profile.rulesetId, "g3_multi", "a Multi Battle uses g3_multi")
eq(last("create")[1].seats, 4, "for four trainers")
check(fpage:compatible({ profile = { version = "firered", rulesetId = "g3_link" }, intent = "trade" },
  fpage:game()), "a FireRed trade room is joinable from FireRed")
fpage:join(nil, "r00000000000000aa", { entry = { room = "r00000000000000aa", intent = "trade",
  profile = { version = "firered", rulesetId = "g3_link" } } })
eq(last("join")[3].rulesetId, "g3_link", "joining a trade room joins with the link ruleset")
-- the format choice shows on the page
fpage.showOptions = true
local text = drawText(fl)
check(has(text, "Double") and has(text, "Multi"), "the room options offer the Gen 3 formats")
C.state = "offline"
fpage:connect()
local adv = connectStarts[#connectStarts].profiles
local rulesets = {}
for _, p in ipairs(adv) do rulesets[p.rulesetId] = true end
check(rulesets.g3_single and rulesets.g3_double and rulesets.g3_multi and rulesets.g3_link,
  "a Gen 3 game advertises every ruleset when it signs in")
C.state = "online"

-- Multi room: four seats, Team A / Team B
C.room = { room = "r4444444444444444", intent = "battle", seats = 4, host = "me",
  profile = { rulesetId = "g3_multi" }, rule = { partySize = 3 },
  players = { { id = "me", name = "TRAINER#123", seat = 0 }, { id = "u1", name = "RIVAL", seat = 1 } } }
text = drawText(fl)
check(has(text, "Team A") and has(text, "Team B"), "a Multi room shows each trainer's side")
check(has(text, "Waiting for 2 more trainers"), "and how many seats are still open")
C.room = nil
-- back to Gold (the newest page holds the client's event handlers)
l, page = fresh("gold")
l:update(0)

-- ----------------------------------------- 8: battle rules when hosting
page.hostOpts.partySize = 5
page:stepLevel("minLevel", 1)
page:stepLevel("minLevel", 1)
eq(page.hostOpts.minLevel, 10, "the lowest level steps by 5 from Any")
page:stepLevel("maxLevel", -1)
eq(page.hostOpts.maxLevel, 95, "the highest level steps down from Any")
page:stepLevel("maxLevel", 1)
eq(page.hostOpts.maxLevel, nil, "and back up to Any")
page.hostOpts.forceLevel = 50
page:host("battle")
local rule = last("create")[1].profile.rule
eq(rule.partySize, 5, "the hosted room carries the team size")
eq(rule.minLevel, 10, "the lowest level")
eq(rule.forceLevel, 50, "and the level cap")
eq(last("create")[1].maxSpectators, 8, "a battle room is watchable by default")
page.hostOpts.spectators = false
page:host("battle")
eq(last("create")[1].maxSpectators, 0, "unless watching is turned off")
page.hostOpts = { format = "single", private = false, pin = "", spectators = true }

-- ----------------------------------------------- 4: private rooms, PIN
page.hostOpts.private, page.hostOpts.pin = true, "12"
local before = count("create")
page:host("battle")
eq(count("create"), before, "a private room needs a full PIN")
check(page.notice.kind == "error" and has(page.notice.text, "4-digit"), "and says so")
page.hostOpts.pin = "1234"
page:host("battle")
eq(last("create")[1].private, true, "a private room is created private")
eq(last("create")[1].pin, "1234", "with its PIN")
page.hostOpts.private, page.hostOpts.pin = false, ""
page:host("battle")
eq(last("create")[1].pin, nil, "a public room sends no PIN")

local locked = { id = "u7", name = "LOCKED", room = "r7777777777777777", locked = true, open = true,
  intent = "battle", version = "gold", profile = { version = "gold", rulesetId = "gen2" } }
C.rooms = { locked }
C.lobby = { locked }
before = count("join")
page:join(nil, locked.room, { entry = locked })
eq(count("join"), before, "a private room asks for the PIN before knocking")
check(page.pinPrompt and page.pinPrompt.room == locked.room, "with a PIN prompt")
check(has(drawText(l), "Enter its PIN"), "that the page shows")
page:submitPin("12a")
eq(count("join"), before, "a PIN that isn't 4 digits is refused")
page:submitPin("4321")
eq(last("join")[4], "4321", "the PIN goes with the join")
C.pending.done, C.pending.error, C.pending.reason = true, "The PIN didn't match. Tries left: 4.", "bad_pin"
l:update(0)
check(page.pinPrompt ~= nil, "a wrong PIN keeps the prompt open")
check(has(page.notice.text, "Tries left"), "and says how many tries are left")
page:submitPin("1111")
C.pending.done, C.pending.error, C.pending.reason = true, "Too many tries.", "pin_locked"
l:update(0)
eq(page.pinPrompt, nil, "a locked-out PIN closes the prompt")
check(page.notice.kind == "error" and has(page.notice.text, "Too many"), "with the relay's message")
-- a code join to a private room the lobby didn't list
page:join("r8888888888888888")
C.pending.done, C.pending.error, C.pending.reason = true, "That room needs a PIN.", "pin_required"
l:update(0)
check(page.pinPrompt and page.pinPrompt.room == "r8888888888888888", "pin_required opens the prompt")
check(has(page.notice.text, "private"), "and explains it")
page.pinPrompt = nil
C.rooms, C.lobby = {}, {}

-- ------------------------------------------ 10: join timeout, lost link
page:join("r9999999999999999")
check(page.pending ~= nil, "a join waits for the relay")
l:update(5)
check(page.pending ~= nil, "for a while")
l:update(page.JOIN_TIMEOUT)
eq(page.pending, nil, "a join the relay never answers is dropped")
check(page.notice.kind == "error" and has(page.notice.text, "didn't answer"), "with a message")
check(has(drawText(l), "Host a battle"), "and the buttons are back")

C.state = "reconnecting"
l:update(0)
check(page.notice.kind == "error" and has(page.notice.text, "Connection lost"), "a dropped link says so")
C.state = "online"
l:update(0)
check(has(page.notice.text, "Reconnected"), "and says when it is back")
C.state, C.err = "error", "timed out"
l:update(0)
check(has(page.notice.text, "Connection lost: timed out"), "a link that gives up names why")
C.state, C.err = "online", nil
l:update(0)

-- -------------------------- 2 + 3 + 9: room, host controls, team, clock
C.room = { room = "r1111111111111111", intent = "battle", seats = 2, host = "me", stage = "waiting",
  rule = { partySize = 3 }, maxSpectators = 8, spectators = {},
  deadlines = { ready = C.now + 42000 },
  players = { { id = "me", name = "TRAINER#123", seat = 0 }, { id = "u1", name = "RIVAL#456", seat = 1 } } }
text = drawText(l)
check(has(text, "TRAINER#123 (you)"), "the member list marks you")
check(has(text, "Kick"), "the host can kick the other trainer")
check(has(text, "Close room"), "and close the room")
check(has(text, "Ready up within 0:42"), "the relay's ready clock counts down")
check(has(text, "PC BOX") and has(text, "MON200"), "the PC boxes can be picked from")
page:kick(C.room.players[2])
eq(last("kick")[1], "u1", "Kick removes that trainer")
page:closeRoom()
eq(count("close"), 1, "Close room closes it")
C.handlers.error({ scope = "room", reason = "closed", text = "The host closed the room." })
check(page.notice.kind == "info" and has(page.notice.text, "You closed"), "the host is told calmly")

C.room.host = "u1"
check(not has(drawText(l), "Kick"), "a guest gets no Kick button")

-- team from the party and a PC box
local game = page:game()
page:toggle(1, game)
page:toggle({ where = "box", box = 3, index = 2 }, game)
page:toggle(2, game)
page:toggle(3, game)
eq(#page:teamList(), 3, "the team holds the team size")
eq(page:teamList()[2].box, 3, "a PC pick is part of the team")
page:ready()
local ready = last("ready")
eq(ready[1][2].species, "MON201", "Ready packs the PC pick")
check(page.readied, "and waits")
check(has(drawText(l), "Not ready"), "Not ready is offered")
page:unready()
local unready = last("ready")
eq(#unready[1], 0, "Not ready sends an empty team")
eq(unready[2], nil, "without a digest")
check(not page.readied, "and the team can change again")
page:toggle(2, game)
eq(#page:teamList(), 2, "a pick can be dropped after Not ready")
page:toggle(4, game)
page:ready()

-- the battle starts: a Gen 2 PC pick travels in the packed team
C.handlers.match_start({ role = "host", seat = 0, seed = 7, peerName = "RIVAL#456",
  theirParty = { { species = "BULBASAUR", level = 5 }, { species = "CHARMANDER", level = 5 },
    { species = "SQUIRTLE", level = 5 } } })
l:update(0)
local spec = launches[#launches] and launches[#launches].opts.arena
check(spec ~= nil, "the battle boots: " .. tostring(page.notice and page.notice.text))
eq(spec and spec.team, nil, "a Gen 2 spec with a PC pick names no party slots")
eq(spec and spec.myParty and spec.myParty[2].species, "MON201", "and packs the PC pick")

-- back in the room after the battle: the rematch prompt
l, page = fresh("gold")
l:update(0)
C.room.stage = "ended"
C.room.deadlines = {}
text = drawText(l)
check(has(text, "rematch") and has(text, "Rematch (0/3)"), "an ended battle offers a rematch")
C.handlers.match_end({ youWon = true })
eq(page.lastResult, "You won!", "the result is kept")
check(has(drawText(l), "You won! Ready up again"), "and shown with the rematch prompt")
C.room.stage = "waiting"

-- Gen 3: a PC pick stays in the spec's team
C.room = { room = "r5555555555555555", intent = "battle", seats = 2, host = "me", stage = "waiting",
  profile = { engine = 3, version = "firered", rulesetId = "g3_single", kind = "vanilla",
    rule = { partySize = 2 } }, rule = { partySize = 2 },
  players = { { id = "me", name = "TRAINER#123", seat = 0 }, { id = "u1", name = "RIVAL", seat = 1 } } }
fl, fpage = fresh("firered")
fl:update(0)
local g3 = fpage:game()
fpage:toggle({ where = "box", box = 3, index = 1 }, g3)
fpage:toggle(1, g3)
fpage:ready()
C.handlers.match_start({ role = "host", seat = 0, seats = 2, seed = 9, match = "m1",
  room = C.room.room, profile = C.room.profile,
  players = { { id = "me", name = "TRAINER#123", seat = 0 }, { id = "u1", name = "RIVAL", seat = 1 } } })
fl:update(0)
spec = launches[#launches].opts.arena
eq(spec.team and spec.team[1].box, 3, "a Gen 3 spec keeps the PC pick: "
  .. tostring(fpage.notice and fpage.notice.text))
eq(spec.myParty and spec.myParty[1].species, 200, "and packs it")
C.room = nil

-- ------------------------------------------------------- 5: spectating
l, page = fresh("gold")
l:update(0)
local live = { id = "u2", name = "CHAMP", room = "r6666666666666666", stage = "battling", intent = "battle",
  version = "gold", spectators = 1, maxSpectators = 8, profile = { version = "gold", rulesetId = "gen2" } }
C.watch = { live, { id = "u3", tour = "t0000000000000001" } }
page.tab = "watch"
text = drawText(l)
check(has(text, "CHAMP's battle") and has(text, "1 watching"), "live battles are listed to watch")
check(has(text, "Watch (1)"), "tournaments are left out of the watch list")
page:watch(live)
eq(last("join")[1], live.room, "Watch joins that room")
eq(last("join")[2], "spectator", "as a spectator")
C.pending.done = true
l:update(0)
check(has(page.notice.text, "Watching"), "and says it is watching")
C.room = { room = live.room, intent = "battle", seats = 2, stage = "battling", host = "u2",
  players = { { id = "u2", name = "CHAMP", seat = 0 }, { id = "u4", name = "CHALLENGER", seat = 1 } },
  spectators = { { id = "me", name = "TRAINER#123" } }, maxSpectators = 8 }
text = drawText(l)
check(has(text, "You are watching"), "a spectator sees no team picker")
check(not has(text, "YOUR TEAM"), "and cannot ready up")
local n = #launches
C.handlers.match_start({ role = "spectator", seed = 11, match = "m2", room = live.room,
  hostName = "CHAMP", guestName = "CHALLENGER",
  hostParty = { { species = "PIKACHU", level = 50 } }, guestParty = { { species = "EEVEE", level = 50 } } })
l:update(0)
eq(#launches, n + 1, "a watched battle boots: " .. tostring(page.notice and page.notice.text))
spec = launches[#launches].opts.arena
eq(spec.role, "spectator", "as a spectator")
eq(spec.hostParty[1].species, "PIKACHU", "with both sides' teams")
C.room, C.watch = nil, {}

-- ----------------------------------------- 6: players online, invites
l, page = fresh("gold")
l:update(0)
C.lobby = {
  { id = "me", name = "TRAINER#123" },
  { id = "u2", name = "BLUE", status = "idle", version = "gold" },
  { id = "u3", name = "AMBER", room = "r6666666666666666", stage = "battling", version = "gold" },
  { id = "u2", name = "BLUE", room = "r1234567890abcdef", open = true },
  { id = "u5", name = "GONE", online = false },
}
local players = page:players()
eq(#players, 2, "the players list skips you, duplicates and the offline")
eq(players[1].name, "AMBER", "sorted by name")
page.tab = "players"
text = drawText(l)
check(has(text, "Battling") and has(text, "Available"), "with what each trainer is doing")
page:invitePlayer(players[2], "battle")
local sent = last("sendInvite")
eq(sent[1], "u2", "Battle invites that trainer")
eq(sent[2], "battle_single", "to a battle")
check(type(sent[4]) == "table", "with this game's profile")
C.handlers.invite_sent({ id = "i1", to = "u2" })
check(has(page.notice.text, "Invite sent to BLUE"), "a sent invite says so")
C.handlers.invite_closed({ id = "i1", why = "declined" })
check(has(page.notice.text, "declined"), "a declined invite says so")
eq(page.outgoing, nil, "and frees the Invite buttons")
page:invitePlayer(players[2], "trade")
eq(last("sendInvite")[2], "trade", "Trade invites to a trade")
C.handlers.invite_closed({ id = "i2", why = "accepted", room = "r2222222222222222" })
check(has(page.notice.text, "accepted"), "an accepted invite says so")
page.outgoing = nil
before = count("sendInvite")
page:invitePlayer(players[2], "watch")
eq(count("sendInvite"), before, "outside a room there is nothing to watch")

-- an incoming invite
local inv = { id = "i9", from = { id = "u3", name = "AMBER" }, activity = "battle_single",
  detail = {}, expiresAt = C.now + 15000 }
C.invites = { inv }
C.handlers.invite_in(inv)
check(has(page.notice.text, "AMBER invites you to a battle"), "an invite arrives with a notice")
text = drawText(l)
check(has(text, "Accept") and has(text, "Decline") and has(text, "0:15 left"), "with Accept, Decline and its clock")
page:answerInvite(inv, true)
eq(last("reply")[1], "i9", "Accept answers that invite")
eq(last("reply")[2], true, "with yes")
check(has(page.notice.text, "Joining AMBER"), "and says it is joining")
page:answerInvite(inv, false)
eq(last("reply")[2], false, "Decline answers no")
C.invites = {}
C.handlers.invite_in({ id = "i10", from = { id = "u3", name = "AMBER" }, activity = "trade" })
C.handlers.invite_closed({ id = "i10", why = "timeout" })
check(has(page.notice.text, "no longer open"), "an invite that runs out says so")

-- inviting someone to watch from a battle room
C.room = { room = "r3333333333333333", intent = "battle", seats = 2, host = "me", stage = "waiting",
  rule = { partySize = 3 }, maxSpectators = 8, spectators = {},
  players = { { id = "me", name = "TRAINER#123", seat = 0 } } }
page.showWatchInvite = true
check(has(drawText(l), "Invite"), "a battle room can invite players to watch")
page:invitePlayer(players[1], "watch")
eq(last("sendInvite")[2], "watch", "a watch invite")
eq(last("sendInvite")[3].room, "r3333333333333333", "names this room")
page.outgoing = nil
C.room = nil

-- ---------------------------------- deep link: the app opened with a code
C.state = "offline"
l, page = fresh("gold")
local starts = #connectStarts
l.pendingInvite = ("c"):rep(32)
l:update(0)
eq(l.pendingInvite, nil, "the launch invite is taken")
eq(page.joinText, ("c"):rep(32), "into the join field")
eq(#connectStarts, starts + 1, "and the page signs in")
C.state = "online"
l:update(0)
eq(last("invite")[1], ("c"):rep(32), "then joins with it once online")
C.pending.done = true
l:update(0)
l:update(0)
eq(page.autoJoin, nil, "only once")

-- ------------------------------------------------------- 11: web build
local realOS = love.system.getOS
love.system.getOS = function() return "Web" end
l, page = fresh("gold")
starts = #connectStarts
page:connect()
eq(#connectStarts, starts, "the web build does not try to connect")
check(has(page.notice.text, "desktop or mobile app"), "and says Online needs the app")
check(has(drawText(l), "desktop or mobile app"), "on the page too")
love.system.getOS = realOS

-- ------------------------------------------------- layouts, phone first
C.state = "online"
l, page = fresh("gold")
l:update(0)
page.showOptions = true
page.hostOpts.private = true
page.pinPrompt = { room = "r7777777777777777", text = "" }
C.invites = { inv }
C.lobby = { { id = "u2", name = "BLUE", status = "idle", version = "gold" } }
C.rooms = { locked }
C.watch = { live }
for _, size in ipairs({ { 390, 844 }, { 1280, 720 }, { 360, 640 } }) do
  window(size[1], size[2])
  for _, tab in ipairs({ "rooms", "watch", "players" }) do
    page.tab = tab
    fits(l, "the lobby (" .. tab .. ")")
  end
end
C.room = { room = "r1111111111111111", intent = "battle", seats = 4, host = "me", stage = "ended",
  rule = { partySize = 3 }, maxSpectators = 8, spectators = {}, locked = true,
  deadlines = { ready = C.now + 5000 },
  players = { { id = "me", name = "TRAINER#123", seat = 0 }, { id = "u1", name = "RIVAL#456", seat = 1 },
    { id = "u2", name = "BLUE", seat = 2 } } }
page.showWatchInvite = true
page.readied = true
for _, size in ipairs({ { 390, 844 }, { 1280, 720 } }) do
  window(size[1], size[2])
  fits(l, "a battle room")
end

T.finish("online page features")
