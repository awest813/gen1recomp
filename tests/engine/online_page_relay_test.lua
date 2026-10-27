-- The PK:GB launcher's Online page against the real Connect / Client code
-- and the in-repo fake relay (tests/support/fake_relay.lua): what the
-- scripted test cannot show is that the page drives the real client
-- correctly.  No pokered cite: port-only online UI.
--   luajit tests/engine/online_page_relay_test.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
love = love or require("tests.love_stub")
love.graphics.setLineJoin = love.graphics.setLineJoin or function() end

local T = require("tests.harness")
local check, eq = T.check, T.eq

local okR, FakeRelay = pcall(require, "tests.support.fake_relay")
if not okR then
  print("skip: fake relay unavailable: " .. tostring(FakeRelay))
  return T.finish("online page relay")
end
local Version = require("src.core.Version")

local options = {}
package.loaded["src.core.SaveData"] = setmetatable({
  listSlots = function(version)
    if version ~= "gold" then return {} end
    return { { id = "slot1", exists = true, name = "GOLD" } }
  end,
  activeSlot = function() return "slot1" end,
  setActiveSlot = function() return true end,
  loadOptions = function() return options end,
  saveOptions = function(o) options = o return true end,
}, { __index = require("src.core.SaveData") })
package.loaded["src.import.CacheContract"] = setmetatable({
  isReady = function(version) return version == "gold" end,
  isImported = function(version) return version == "gold" end,
}, { __index = require("src.import.CacheContract") })
local PROFILE = { engine = 2, version = "gold", engineVersion = Version.engine,
  apiVersion = Version.modApi, fingerprint = "f00d", kind = "vanilla", rule = { partySize = 3 } }
package.loaded["src.online.ArenaData"] = setmetatable({
  profile = function() return PROFILE end,
}, { __index = require("src.online.ArenaData") })
package.loaded["src.online.TeamPick"] = setmetatable({
  readSlot = function() return { party = {}, trainerName = "GOLD", generation = 2 } end,
}, { __index = require("src.online.TeamPick") })
local tradeStarts = 0
package.loaded["src.online.Trade"] = {
  openSlot = function() return { party = {} } end,
  remote = function() return { start = function() tradeStarts = tradeStarts + 1 end,
    update = function() return "waitParty" end, stage = function() return "waitParty" end,
    close = function() end, session = {} } end,
  pumpPending = function() end,
}

local relay = FakeRelay.new()
local seatA = relay:seat("a0000001", "GOLD")
local seatB = relay:seat("b0000002", "RIVAL")
local function newClient(seat)
  package.loaded["src.online.Client"] = nil
  local Client = require("src.online.Client")
  Client.reset()
  Client.configure({ relayAddress = "fake:1", connect = function() return seat.transport end })
  return Client
end
local B = newClient(seatB)
local A = newClient(seatA)           -- the page's client: the one require() returns
package.loaded["src.online.Connect"] = nil
local Connect = require("src.online.Connect")
Connect.reset()

local Launcher = require("src.launcher.Launcher")
local launched = {}
local l = Launcher.new(function(v, c, o) launched[#launched + 1] = o end, { noUpdateCheck = true })
l.selected = "gold"
l:openOnline()
local page = l.online

local function step(n)
  for _ = 1, n or 1 do
    relay:pump()
    Connect.update(0)
    A.update(0)
    B.update(0)
    l:update(0)
  end
end

page:connect()
B.connect({ name = "RIVAL", profiles = { PROFILE } })
step(4)
eq(A.state(), "online", "Connect brings the page's client online: " .. tostring(Connect.error()))
check(page:online(), "and the page sees it")

-- host a trade room, hand out an invite, the rival joins with it
page:host("trade")
step(3)
local room = A.room()
check(room ~= nil and room.intent == "trade", "Host a trade opens a trade room: "
  .. tostring(page.notice and page.notice.text))
eq(page.pending, nil, "the request finished")
page:invite()
step(3)
check(type(page.inviteToken) == "string" and #page.inviteToken == 32, "an invite code arrives")
local joined = B.joinRoomByInvite(page.inviteToken, "player", PROFILE)
step(4)
check(joined.done and not joined.error, "the rival joins with that code: " .. tostring(joined.error))
eq(#(A.room().players or {}), 2, "both trainers are in the room")
eq(tradeStarts, 1, "the page starts the trade once both are in")

page:leave()
step(3)
eq(A.room(), nil, "Leave room leaves")

-- join a room by its code
local hosted = B.createRoom({ intent = "battle", profile = PROFILE, playing = true, seats = 2 })
step(3)
check(hosted.done and B.room(), "the rival hosts a battle")
page:join(B.room().room)
step(4)
check(A.room() and A.room().room == B.room().room, "joining by room code enters it: "
  .. tostring(page.notice and page.notice.text))
eq(A.room().intent, "battle", "a battle room")
local function noticeText() return tostring(page.notice and page.notice.text) end

-- a private room: the PIN prompt, a wrong PIN, the right one
page:leave()
B.leaveRoom()
step(3)
local private = B.createRoom({ intent = "battle", profile = PROFILE, playing = true, seats = 2,
  private = true, pin = "2468" })
step(3)
check(private.done and B.room() and B.room().locked, "the rival hosts a private room")
local code = B.room().room
page:join(code)
step(4)
check(page.pinPrompt ~= nil and page.pinPrompt.room == code, "joining it asks for the PIN: " .. noticeText())
page:submitPin("1111")
step(4)
check(page.pinPrompt ~= nil, "a wrong PIN keeps asking")
check(noticeText():find("Tries left", 1, true) ~= nil, "and counts the tries left: " .. noticeText())
page:submitPin("2468")
step(4)
check(A.room() and A.room().room == code, "the right PIN gets in: " .. noticeText())
eq(page.pinPrompt, nil, "and the prompt closes")
check(not page:isHost(A.room()), "the guest is not the host")
check(page:mySeat(A.room()) == 1, "and has the second seat")

-- the host closes the room
page:leave()
B.leaveRoom()
step(3)
page:host("battle")
step(3)
check(A.room() and page:isHost(A.room()), "the page hosts a room and knows it")
B.joinRoom(A.room().room, "player", PROFILE)
step(4)
eq(#A.room().players, 2, "the rival joins")
page:closeRoom()
step(3)
eq(A.room(), nil, "Close room closes it")
eq(B.room(), nil, "for everyone")
check(noticeText():find("You closed", 1, true) ~= nil, "and the host is told: " .. noticeText())

-- watching a room
B.createRoom({ intent = "battle", profile = PROFILE, playing = true, seats = 2, maxSpectators = 8 })
step(3)
page:watch({ room = B.room().room })
step(4)
check(A.room() and A.room().room == B.room().room, "Watch enters the room: " .. noticeText())
eq(page:mySeat(A.room()), nil, "without a seat")
eq(#A.room().spectators, 1, "as a spectator")
page:leave()
B.leaveRoom()
step(3)

-- an invite from the rival, accepted on the page
local okI = B.invite(A.you().id, "battle_single", {}, PROFILE)
step(3)
check(okI ~= nil and #A.invites() == 1, "the rival's invite arrives")
check(noticeText():find("invites you", 1, true) ~= nil, "with a notice: " .. noticeText())
page:answerInvite(A.invites()[1], true)
step(4)
check(A.room() ~= nil and #A.room().players == 2, "accepting it opens a room with both trainers")
check(B.room() and B.room().room == A.room().room, "the same room")
page:leave()
B.leaveRoom()
step(3)

-- an invite from the page, declined by the rival
page:invitePlayer({ id = B.you().id, name = "RIVAL" }, "trade")
step(3)
check(#B.invites() == 1, "the page's invite reaches the rival")
B.replyInvite(B.invites()[1].id, false)
step(3)
check(noticeText():find("declined", 1, true) ~= nil, "a declined invite says so: " .. noticeText())

page:disconnect()
step(2)
eq(A.state(), "offline", "Disconnect signs out")

T.finish("online page relay")
