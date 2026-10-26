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

page:disconnect()
step(2)
eq(A.state(), "offline", "Disconnect signs out")

T.finish("online page relay")
