-- The PK:GB launcher's Online page (src/launcher/OnlinePage.lua), headless,
-- against a scripted relay client.  No pokered cite: port-only online UI.
--
-- Pins the flow a player relies on: sign in with the chosen save's trainer,
-- host or join (room code or invite code), pick exactly the team size,
-- ready up, and the relay's match_start boots the battle with a spec the
-- real ArenaBoot accepts; the battle's result is reported; a trade room
-- starts the trade once both trainers are in and reloads saves when done.
--   luajit tests/engine/online_page_test.lua

package.path = "./?.lua;./?/init.lua;" .. package.path
love = love or require("tests.love_stub")
love.graphics.setLineJoin = love.graphics.setLineJoin or function() end
love.graphics.newShader = love.graphics.newShader or function() return {} end

local T = require("tests.harness")
local check, eq = T.check, T.eq

-- saves: Gold is imported with one save
package.loaded["src.core.SaveData"] = {
  listSlots = function(version)
    if version ~= "gold" then return {} end
    return { { id = "slot1", exists = true, name = "GOLD", meta = { timeText = "1:00",
      badges = 1, dexCount = 5 } } }
  end,
  activeSlot = function() return "slot1" end,
  setActiveSlot = function() return true end,
  loadOptions = function() return {} end,
  saveOptions = function() return true end,
}
package.loaded["src.import.CacheContract"] = setmetatable({
  isReady = function(version) return version == "gold" end,
  isImported = function(version) return version == "gold" end,
}, { __index = require("src.import.CacheContract") })

-- the online modules, scripted
local PROFILE = { engine = 2, version = "gold", kind = "vanilla", engineVersion = "1",
  rule = { partySize = 3 } }
package.loaded["src.online.ArenaData"] = {
  profile = function(version) return version == "gold" and PROFILE or nil, "no" end,
  equal = function(a, b) return a.version == b.version end,
}
local PARTY = {}
for i = 1, 4 do PARTY[i] = { species = 150 + i, level = 20 + i } end
package.loaded["src.online.TeamPick"] = {
  readSlot = function() return { party = PARTY, trainerName = "GOLD", generation = 2 } end,
  validate = function(_, team, rule)
    if #team ~= rule.partySize then return false, "pick " .. rule.partySize end
    return true
  end,
  pack = function(_, team)
    local out = {}
    -- Gen 1/2 packed mons name their species
    for i, index in ipairs(team) do out[i] = { species = "MON" .. PARTY[index].species, level = 5 } end
    return out
  end,
}
package.loaded["src.box.Catalog"] = {
  describe = function(_, mon) return { name = "MON" .. mon.species, level = mon.level } end,
}

local C = { state = "offline", handlers = {}, sent = {}, rooms = {} }
local function record(kind, ...) C.sent[#C.sent + 1] = { kind = kind, ... } end
local function last(kind)
  for i = #C.sent, 1, -1 do if C.sent[i].kind == kind then return C.sent[i] end end
end
local session = { send = function() end, poll = function() end, close = function() end }
package.loaded["src.online.Client"] = {
  on = function(e, fn) C.handlers[e] = fn end,
  off = function(e) C.handlers[e] = nil end,
  state = function() return C.state end,
  you = function() return C.state == "online" and { id = "me", name = "GOLD#123" } or nil end,
  room = function() return C.room end,
  openRooms = function() return C.rooms end,
  roomSession = function() return session end,
  createRoom = function(opts) record("create", opts) C.pending = { id = 1 } return C.pending end,
  joinRoom = function(id, as, profile) record("join", id, as, profile) return { id = 2 } end,
  joinRoomByInvite = function(token, as, profile) record("invite", token, as, profile) return { id = 3 } end,
  ready = function(party, digest) record("ready", party, digest) end,
  report = function(result) record("report", result) end,
  leaveRoom = function() record("leave") C.room = nil end,
  inviteToken = function(room) record("token", room) end,
  sendRaw = function(msg) record("raw", msg) end,
}
local connectStarts = {}
package.loaded["src.online.Connect"] = {
  name = function() return C.state == "online" and "GOLD#123" or nil end,
  state = function() return C.state end,
  busy = function() return false end,
  error = function() return nil end,
  start = function(opts) connectStarts[#connectStarts + 1] = opts end,
  setName = function(text) if #text < 3 then return false, "too short" end return true end,
  disconnect = function() C.state = "offline" end,
}

local Launcher = require("src.launcher.Launcher")

local launches = {}
local function fresh(opts)
  local l = Launcher.new(function(version, cartId, o)
    launches[#launches + 1] = { version = version, cartId = cartId, opts = o }
  end, opts)
  l.selected = "gold"
  return l
end

local function window(w, h)
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

window(1280, 720)
local l = fresh({ noUpdateCheck = true })
check(drawText(l):find("Online", 1, true) ~= nil, "the header offers Online")
l:openOnline()
eq(l.page, "online", "Online opens as a page")
local t = drawText(l)
check(t:find("Offline", 1, true) and t:find("Connect", 1, true), "offline, it offers Connect")
check(t:find("relay", 1, true) ~= nil, "and names the relay it will use")
local page = l.online

-- --------------------------------------------------------------- sign in
page:connect()
eq(#connectStarts, 1, "Connect signs in")
eq(connectStarts[1].trainerName, "GOLD", "as the chosen save's trainer")
eq(connectStarts[1].profiles[1], PROFILE, "advertising this game's profile")
C.state = "online"
C.rooms = {
  { id = "u1", name = "RIVAL#456", intent = "battle", version = "gold", room = "r0123456789abcdef",
    profile = PROFILE },
  { id = "u2", name = "OTHER#789", intent = "battle", version = "red", room = "rfedcba9876543210",
    profile = { version = "red" } },
}
t = drawText(l)
check(t:find("Online as GOLD#123", 1, true) ~= nil, "online, it shows who you are")
check(t:find("Host a battle", 1, true) and t:find("Host a trade", 1, true), "and offers to host")
check(t:find("RIVAL#456", 1, true) ~= nil, "open rooms are listed")
check(t:find("not your game", 1, true) ~= nil, "a room for another game says so")
check(page:compatible(C.rooms[1], page:game()), "a room for the same game can be joined")
check(not page:compatible(C.rooms[2], page:game()), "another game's cannot")

page:rename("ab")
check(page.notice.kind == "error", "a bad name is refused with the reason")

-- ----------------------------------------------------------------- join
page:join("not a code")
check(page.notice.kind == "error", "a bad code is refused")
page:join(("A"):rep(32))
eq(last("invite")[1], ("a"):rep(32), "a 32-character code joins by invite")
page:join("r0123456789ABCDEF")
eq(last("join")[1], "r0123456789abcdef", "a room code joins that room")
eq(last("join")[2], "player", "as a player")

-- ----------------------------------------------------------------- host
page:host("battle")
eq(last("create")[1].intent, "battle", "Host a battle creates a battle room")
eq(last("create")[1].profile, PROFILE, "for this game")
C.pending.done = true
l:update(0)
eq(page.pending, nil, "the finished request is collected")
C.room = { room = "r1111111111111111", intent = "battle", seats = 2,
  players = { { id = "me", name = "GOLD#123" } }, rule = { partySize = 3 } }
t = drawText(l)
check(t:find("Battle room", 1, true) and t:find("r1111111111111111", 1, true), "the room shows its code")
check(t:find("Waiting for another trainer", 1, true) ~= nil, "and that it waits for a second player")
check(t:find("MON151", 1, true) ~= nil, "the save's party is listed to pick from")
for i = 1, 4 do page:toggle(i, page:game()) end
eq(#page:teamList(), 3, "no more than the team size can be picked")
page:ready()
local ready = last("ready")
check(ready and #ready[1] == 3, "Ready sends the packed team")
check(type(ready[2]) == "string" and #ready[2] == 16, "with a digest of it")
check(page.readied, "and waits for the other trainer")

page:invite()
eq(last("token")[1], "r1111111111111111", "Get invite code asks for this room's code")
C.handlers.invite_token({ token = ("b"):rep(32) })
check(drawText(l):find(("b"):rep(32), 1, true) ~= nil, "the invite code is shown")

-- ---------------------------------------------------------- match start
C.handlers.match_start({ role = "host", seed = 1234, peerName = "RIVAL#456",
  theirParty = { { species = "BULBASAUR", level = 5 }, { species = "CHARMANDER", level = 5 },
    { species = "SQUIRTLE", level = 5 } } })
eq(#launches, 0, "match_start only queues the boot")
l:update(0)
eq(#launches, 1, "the battle boots on the next update: " .. tostring(page.notice and page.notice.text))
local spec = launches[1].opts and launches[1].opts.arena
check(spec ~= nil, "with an arena spec")
eq(launches[1].version, "gold", "for this game")
eq(spec.role, "host", "in the relay's role")
eq(spec.slotId, "slot1", "with the chosen save")
eq(spec.seed, 1234, "and the shared seed")
eq(#spec.team, 3, "and the picked team")
spec.onDone("win")
eq(last("report")[1], "win", "the battle's result is reported")
local reports = 0
for _, m in ipairs(C.sent) do if m.kind == "report" then reports = reports + 1 end end
spec.onDone("crashed")
local after = 0
for _, m in ipairs(C.sent) do if m.kind == "report" then after = after + 1 end end
eq(after, reports, "anything but win, lose or draw is not reported")

-- ----------------------------------------------------------------- trade
local traded = { started = false, picks = {} }
local remote = { stageName = "picking", session = { theirParty = { { species = 25, level = 9 } } },
  handle = { party = PARTY } }
function remote:start() traded.started = true end
function remote:update() return self.stageName end
function remote:stage() return self.stageName end
function remote:canPick() return true end
function remote:pick(i) traded.picks[#traded.picks + 1] = i self.session.myPick = i return true end
function remote:confirm() end
function remote:close() traded.closed = true end
package.loaded["src.online.Trade"] = {
  openSlot = function(version, slotId) return { version = version, slotId = slotId, party = PARTY } end,
  remote = function() return remote end,
  pumpPending = function() end,
}
l = fresh({ noUpdateCheck = true })
l:openOnline()
page = l.online
C.room = { room = "r2222222222222222", intent = "trade", seats = 2,
  players = { { id = "me", name = "GOLD#123" } } }
session.paired = false
l:update(0)
check(not traded.started, "a trade waits for the second trainer")
session.paired = true
C.room.players[2] = { id = "u1", name = "RIVAL#456" }
l:update(0)
check(traded.started, "and starts once both are in")
t = drawText(l)
check(t:find("Choose a Pokemon", 1, true) and t:find("MON25", 1, true), "both parties are shown")
remote:pick(2)
remote.stageName = "confirming"
check(drawText(l):find("Confirm the trade", 1, true) ~= nil, "a picked pair asks to confirm")
local saveReloads = 0
l.savesChanged = function() saveReloads = saveReloads + 1 end
remote.stageName = "committed"
l:update(0)
eq(saveReloads, 1, "a finished trade reloads the saves")
check(traded.closed and page.trade == nil, "and closes the trade")
check(page.notice.text:find("Trade complete", 1, true) ~= nil, "and says so")

-- -------------------------------------------------- back from a battle
launches = {}
local back = fresh({ noUpdateCheck = true, initialGame = "online" })
eq(back.page, "online", "returning from a battle reopens Online")
local before = #connectStarts
back:update(0)
eq(#connectStarts, before + 1, "and signs back in")

-- small windows
for _, size in ipairs({ { 360, 640 }, { 640, 360 }, { 800, 600 } }) do
  window(size[1], size[2])
  drawText(l)
end
C.room = nil
window(390, 844)
drawText(l)

T.finish("online page")
