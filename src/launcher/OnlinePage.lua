-- The PK:GB launcher's Online page: connect to the relay, host or join a
-- room (public or with a PIN), pick a team from the party or the PC and
-- battle, trade one Pokemon, watch other trainers' battles, and invite
-- the players who are online.
--
-- Written for src/launcher/ on the online modules alone: Connect (name and
-- sign-in), Client (relay connection, rooms, invites, events), ArenaData
-- (the profile two games must share), TeamPick (a team from a save),
-- ArenaBoot (the battle launch spec) and Trade (the two-save exchange).
-- main.lua already pumps Connect.update and Client.update every frame.
--
-- This file holds the page's state and actions; the views live beside it:
-- src/launcher/online/LobbyView.lua (hosting, joining, the room / watch /
-- player lists, invites) and src/launcher/online/RoomView.lua (the room,
-- its members, the team and the trade).
--
-- It plays the game selected in the launcher with that game's chosen save,
-- the original game only (no custom cart).

local Kit = require("src.ui.kit.Kit")
local Theme = require("src.ui.kit.Theme")
local GameVersion = require("src.core.GameVersion")
local Layout = require("src.launcher.online.Layout")

local PAL = Theme.PAL

local OnlinePage = {}
OnlinePage.__index = OnlinePage

local function lazy(name)
  return function() return require(name) end
end
local Connect = lazy("src.online.Connect")
local Client = lazy("src.online.Client")

local EVENTS = { "match_start", "match_end", "invite_token", "error", "room",
  "invite_in", "invite_sent", "invite_closed", "tournament", "tour_match", "tour_spectate",
  "tour_bye", "tour_over" }

-- Seconds a host or join request may go unanswered before the page gives
-- up on it and lets the player try again.
OnlinePage.JOIN_TIMEOUT = 15
-- Spectator seats a hosted battle offers when watching is allowed.
OnlinePage.SPECTATORS = 8

-- Tournament shot clocks the relay accepts (Protocol2.SHOT_CLOCKS).
OnlinePage.SHOT_CLOCKS = { 3, 6, 9 }

-- The team each tournament was entered with, by tournament id: a page is
-- made afresh when the launcher comes back from a battle, and the next
-- round must play the same team.
local tourPicks = {}
OnlinePage.tourPicks = tourPicks

-- Gen 3 battle formats, by the activity that names their ruleset.
OnlinePage.FORMATS = {
  { value = "single", label = "Single", activity = "battle_single", seats = 2 },
  { value = "double", label = "Double", activity = "battle_double", seats = 2 },
  { value = "multi", label = "Multi (2 vs 2)", activity = "battle_multi", seats = 4 },
}
local FORMAT_BY_RULESET = { g3_single = "Single", g3_double = "Double", g3_multi = "Multi",
  g3_link = "Link" }

function OnlinePage.new(launcher)
  local self = setmetatable({
    launcher = launcher,
    joinText = "",
    team = {},          -- refKey -> pick (a party index, or a box ref)
    teamOrder = {},     -- picks in the order they were chosen
    notice = nil,       -- { text, kind }
    profiles = {},      -- cache key -> profile
    handlers = {},
    tab = "rooms",      -- lobby list: rooms | watch | players
    box = 1,            -- PC box shown in the team picker
    hostOpts = { format = "single", private = false, pin = "", spectators = true,
                 partySize = nil, minLevel = nil, maxLevel = nil, forceLevel = nil },
    inviteNames = {},   -- incoming invite id -> sender name
    tourOpts = { shotClock = 6, spectators = 8, public = true },
    tourCode = "",
  }, OnlinePage)
  for _, event in ipairs(EVENTS) do
    local fn = function(payload) self:onEvent(event, payload) end
    self.handlers[event] = fn
    pcall(Client().on, event, fn)
  end
  self.nameDraft = (pcall(Connect().name) and Connect().name()) or ""
  return self
end

-- Stop listening; the connection itself stays up for the next visit.
function OnlinePage:close()
  for event, fn in pairs(self.handlers) do pcall(Client().off, event, fn) end
  self.handlers = {}
  self:endTrade()
end

function OnlinePage:say(text, kind)
  self.notice = text and { text = tostring(text), kind = kind or "info" } or nil
end

local function call(name, ...)
  local fn = Client()[name]
  if type(fn) ~= "function" then return false, nil end
  local ok, a, b = pcall(fn, ...)
  if not ok then return false, nil end
  return true, a, b
end

-- --------------------------------------------------------------- the game

-- The game, save and profile this page plays with, or nil plus why not.
function OnlinePage:game()
  local l = self.launcher
  local v = l.selected
  if not (v and l.ready[v]) then return nil, "Import a game first, then pick it on the left." end
  if l:activeCart(v) then
    return nil, "Online plays the original game. Choose it on the game's Carts page."
  end
  local slots = l:slotsFor(v)       -- loads the list and the chosen save
  local slotId = l:selectedSaveId(v)
  if not slotId or #slots == 0 then
    return nil, "Start or import a save for " .. GameVersion.info(v).displayName .. " first."
  end
  local slotName
  for _, sl in ipairs(slots) do
    if sl.id == slotId then slotName = sl.label or sl.name end
  end
  local profile, why = self:profile(v, self:rulesetFor(v, "battle"))
  if not profile then return nil, why end
  return { version = v, slotId = slotId, slotName = slotName, profile = profile,
           generation = GameVersion.generation(v) }
end

-- The Gen 3 ruleset an activity plays under (nil before Gen 3): trades
-- use the link ruleset, battles the chosen format's.
function OnlinePage:rulesetFor(version, intent, format)
  if GameVersion.generation(version) ~= 3 then return nil end
  local ArenaData = require("src.online.ArenaData")
  if intent == "trade" then return ArenaData.rulesetFor("trade") end
  return ArenaData.rulesetFor("battle_" .. tostring(format or "single"))
    or ArenaData.rulesetFor("battle_single")
end

local function ruleKey(rule)
  if type(rule) ~= "table" then return "-" end
  return ("%s/%s/%s/%s"):format(tostring(rule.partySize), tostring(rule.minLevel),
    tostring(rule.maxLevel), tostring(rule.forceLevel))
end

function OnlinePage:profile(version, rulesetId, rule)
  local key = ("%s|%s|%s"):format(version, tostring(rulesetId), ruleKey(rule))
  local cached = self.profiles[key]
  if cached then return cached end
  local ArenaData = require("src.online.ArenaData")
  local ok, profile, why = pcall(ArenaData.profile, version, "vanilla", nil, rule, rulesetId)
  if not ok then return nil, tostring(profile) end
  if not profile then return nil, tostring(why or "this game cannot play online") end
  self.profiles[key] = profile
  return profile
end

-- The rule a hosted battle plays by, from the room options.
function OnlinePage:hostRule(game)
  local o = self.hostOpts
  local base = (game and game.profile and game.profile.rule) or {}
  return {
    partySize = o.partySize or tonumber(base.partySize) or 3,
    minLevel = o.minLevel, maxLevel = o.maxLevel, forceLevel = o.forceLevel,
  }
end

-- The profile a room this page hosts (or an invite it sends) carries.
function OnlinePage:hostProfile(game, intent)
  local rulesetId = self:rulesetFor(game.version, intent, self.hostOpts.format)
  local rule = intent == "battle" and self:hostRule(game) or nil
  return self:profile(game.version, rulesetId, rule)
end

-- The profile to join a room with: a Gen 3 game takes the room's ruleset.
function OnlinePage:joinProfile(game, entry)
  if game.generation ~= 3 then return game.profile end
  local rulesetId = entry and entry.profile and entry.profile.rulesetId
  if not rulesetId and entry and entry.intent == "trade" then
    rulesetId = self:rulesetFor(game.version, "trade")
  end
  if not rulesetId or rulesetId == game.profile.rulesetId then return game.profile end
  return self:profile(game.version, rulesetId) or game.profile
end

-- Advertise a profile to the relay too, so rooms and invites made with it
-- match this game.
function OnlinePage:advertise(profile)
  if type(profile) ~= "table" then return end
  local ok, list = call("profiles")
  if not ok or type(list) ~= "table" then return end
  local ArenaData = require("src.online.ArenaData")
  for _, p in ipairs(list) do
    local okE, same = pcall(ArenaData.equal, p, profile)
    if okE and same then return end
  end
  local out = {}
  for i, p in ipairs(list) do out[i] = p end
  out[#out + 1] = profile
  call("setProfiles", out)
end

-- The save's party and PC, read once per save.
function OnlinePage:source(game)
  local key = game.version .. ":" .. game.slotId
  if self.sourceKey ~= key then
    local TeamPick = require("src.online.TeamPick")
    local ok, slot, why = pcall(TeamPick.readSlot, game.version, game.slotId)
    -- picks belong to a save: another save (or a reloaded one) starts over
    if self.sourceKey ~= nil then
      self.team, self.teamOrder = {}, {}
      self.box = 1
    end
    self.sourceKey = key
    self.sourceSlot = ok and slot or nil
    self.sourceWhy = ok and why or slot
  end
  return self.sourceSlot, self.sourceWhy
end

-- Everything in the save a team can be picked from: the party first, then
-- each PC box ({ ref, mon, box, boxName }).
function OnlinePage:candidates(game)
  local source = self:source(game)
  if not source then return {} end
  local TeamPick = require("src.online.TeamPick")
  local list = {}
  if type(TeamPick.candidates) == "function" then
    local ok, rows = pcall(TeamPick.candidates, source)
    if ok and type(rows) == "table" then list = rows end
  else
    for i, mon in ipairs(source.party or {}) do
      list[i] = { where = "party", index = i, mon = mon }
    end
  end
  local out = {}
  for _, row in ipairs(list) do
    if row.where == "box" then
      out[#out + 1] = { ref = { where = "box", box = row.box, index = row.index }, mon = row.mon,
                        box = row.box, boxName = row.source }
    else
      out[#out + 1] = { ref = row.index, mon = row.mon }
    end
  end
  return out
end

local function monName(version, mon)
  local ok, d = pcall(function() return require("src.box.Catalog").describe(version, mon) end)
  if ok and type(d) == "table" then
    return ("%s  Lv%d"):format(tostring(d.name or d.species or "?"), tonumber(d.level) or 0)
  end
  return ("#%s  Lv%s"):format(tostring(mon and mon.species or "?"), tostring(mon and mon.level or "?"))
end
OnlinePage.monName = monName

-- ------------------------------------------------------------ connection

-- A web build has no sockets: Online needs the desktop or mobile app.
function OnlinePage:networkMissing()
  local okN, available = pcall(function() return require("src.link.Net").available() end)
  if okN and available then return false end
  local okO, os_ = pcall(function() return love.system.getOS() end)
  return okO and os_ == "Web"
end

OnlinePage.WEB_TEXT = "Online play needs the desktop or mobile app: the web version can't "
  .. "connect to the relay."

function OnlinePage:connect()
  if self:networkMissing() then return self:say(OnlinePage.WEB_TEXT, "error") end
  local game, why = self:game()
  if not game then return self:say(why, "error") end
  local source = self:source(game)
  local trainer = source and source.trainerName or game.slotName
  local profiles = { game.profile }
  if game.generation == 3 then
    -- every Gen 3 ruleset, so trades and every battle format can match
    for _, f in ipairs(OnlinePage.FORMATS) do
      local p = self:profile(game.version, self:rulesetFor(game.version, "battle", f.value))
      if p and p ~= game.profile then profiles[#profiles + 1] = p end
    end
    local trade = self:profile(game.version, self:rulesetFor(game.version, "trade"))
    if trade then profiles[#profiles + 1] = trade end
  end
  local ok, err = pcall(Connect().start, {
    version = game.version,
    trainerName = trainer,
    profiles = profiles,
    presence = { where = "launcher", status = "idle", version = game.version,
                 engine = game.generation },
  })
  if not ok then return self:say(err, "error") end
  self.nameDraft = Connect().name() or self.nameDraft
  self:say(nil)
end

function OnlinePage:rename(text)
  local ok, why = Connect().setName(text)
  if not ok then return self:say(why or "That name won't work.", "error") end
  self.nameDraft = Connect().name() or text
  self:say("You are " .. tostring(self.nameDraft) .. " online.", "info")
end

function OnlinePage:disconnect()
  self:endTrade()
  self.wasOnline, self.autoJoin = nil, nil
  pcall(Connect().disconnect)
  self.pending, self.inviteToken, self.pinPrompt, self.outgoing = nil, nil, nil, nil
end

function OnlinePage:online()
  return Client().state() == "online"
end

function OnlinePage:you()
  local ok, you = call("you")
  return ok and you or nil
end

function OnlinePage:isYou(id)
  local you = self:you()
  return you ~= nil and id ~= nil and you.id == id
end

-- ------------------------------------------------------------------ rooms

-- Remember a request the relay has yet to answer.
function OnlinePage:request(pending, info)
  self.pending, self.pendingAge, self.pendingInfo = pending, 0, info or {}
  self.readied, self.inviteToken, self.lastResult = nil, nil, nil
  if not (info and info.keepTeam) then self.team, self.teamOrder = {}, {} end
end

function OnlinePage:host(intent)
  local game, why = self:game()
  if not game then return self:say(why, "error") end
  local o = self.hostOpts
  if o.private and not tostring(o.pin or ""):match("^%d%d%d%d$") then
    return self:say("A private room needs a 4-digit PIN.", "error")
  end
  local profile, err = self:hostProfile(game, intent)
  if not profile then return self:say(err, "error") end
  local seats = 2
  if intent == "battle" and game.generation == 3 then
    for _, f in ipairs(OnlinePage.FORMATS) do
      if f.value == o.format then seats = f.seats end
    end
  end
  self:advertise(profile)
  self:request(Client().createRoom({
    intent = intent, profile = profile, playing = true, seats = seats,
    private = o.private or nil, pin = o.private and o.pin or nil,
    maxSpectators = (intent == "battle" and o.spectators) and OnlinePage.SPECTATORS or 0,
  }), { host = intent })
  self:say(nil)
end

-- The lobby's entry for a room id, if the relay listed it.
function OnlinePage:lobbyEntry(roomId)
  local ok, lobby = call("lobby")
  for _, entry in ipairs(ok and lobby or {}) do
    if entry.room == roomId then return entry end
  end
  return nil
end

-- A room id (r + 16 hex) or an invite code (32 hex).  opts: as ("player"
-- or "spectator"), pin (4 digits), entry (the lobby row).
function OnlinePage:join(text, roomId, opts)
  opts = opts or {}
  local game, why = self:game()
  if not game then return self:say(why, "error") end
  local as = opts.as or "player"
  text = tostring(roomId or text or ""):gsub("%s", "")
  if text:match("^%x+$") and #text == 32 then
    self:request(Client().joinRoomByInvite(text:lower(), as, game.profile), { as = as })
  elseif text:match("^[rR]%x+$") and #text == 17 then
    local id = text:lower()
    local entry = opts.entry or self:lobbyEntry(id)
    if entry and entry.locked and not opts.pin then
      -- ask for the PIN before knocking
      self.pinPrompt = { room = id, as = as, entry = entry, text = "" }
      return self:say("That room is private. Enter its 4-digit PIN.", "info")
    end
    local profile = self:joinProfile(game, entry)
    self:advertise(profile)
    self:request(Client().joinRoom(id, as, profile, opts.pin),
      { room = id, as = as, entry = entry })
  else
    return self:say("Enter a room code (r and 16 letters/digits) or an invite code.", "error")
  end
  self:say(nil)
end

-- Join the room the PIN prompt is open for.
function OnlinePage:submitPin(text)
  local prompt = self.pinPrompt
  if not prompt then return end
  text = tostring(text or prompt.text or ""):gsub("%s", "")
  if not text:match("^%d%d%d%d$") then
    return self:say("The PIN is 4 digits.", "error")
  end
  self:join(nil, prompt.room, { as = prompt.as, entry = prompt.entry, pin = text })
end

function OnlinePage:watch(entry)
  if not (entry and entry.room) then return end
  self:join(nil, entry.room, { as = "spectator", entry = entry })
end

function OnlinePage:refreshLobby()
  local Protocol2 = require("src.online.Protocol2")
  pcall(Client().sendRaw, Protocol2.lobbyQuery())
end

function OnlinePage:invite()
  local room = Client().room()
  if room then pcall(Client().inviteToken, room.room) end
end

function OnlinePage:leave()
  self:endTrade()
  pcall(Client().leaveRoom)
  self.team, self.teamOrder = {}, {}
  self.readied, self.inviteToken, self.lastResult = nil, nil, nil
end

-- Host only: remove a trainer from the room, or close it for everyone.
function OnlinePage:kick(player)
  if not (player and player.id) then return end
  call("kick", player.id)
  self:say("Removed " .. tostring(player.name or "that trainer") .. " from the room.", "info")
end

function OnlinePage:closeRoom()
  self.closing = true
  call("closeRoom")
end

function OnlinePage:isHost(room)
  return room ~= nil and room.host ~= nil and self:isYou(room.host)
end

-- This trainer's seat in the room, or nil when watching.
function OnlinePage:mySeat(room)
  for _, pl in ipairs((room or {}).players or {}) do
    if self:isYou(pl.id) then return pl.seat or 0, pl end
  end
  return nil
end

-- Two games can share a room when their profiles match.
function OnlinePage:compatible(entry, game)
  if not (entry and game) then return false end
  if entry.profile then
    local mine = self:joinProfile(game, entry)
    local ok, same = pcall(require("src.online.ArenaData").equal, entry.profile, mine)
    return ok and same == true
  end
  return entry.version == game.version
end

-- -------------------------------------------------------------- players

-- The other trainers online, by name.
function OnlinePage:players()
  local ok, lobby = call("lobby")
  local you = self:you()
  local seen, out = {}, {}
  for _, entry in ipairs(ok and lobby or {}) do
    if entry.id and not seen[entry.id] and not (you and entry.id == you.id)
        and entry.online ~= false then
      seen[entry.id] = true
      out[#out + 1] = entry
    end
  end
  table.sort(out, function(a, b)
    local na, nb = tostring(a.name or ""):lower(), tostring(b.name or ""):lower()
    if na ~= nb then return na < nb end
    return tostring(a.id) < tostring(b.id)
  end)
  return out
end

local STATUS_TEXT = { idle = "Available", busy = "Busy", trading = "Trading",
  battling = "Battling", chatting = "Chatting", recruiting = "Looking for players" }

function OnlinePage.statusText(entry)
  if entry.room and entry.stage == "battling" then return "Battling" end
  if entry.room then return "In a room" end
  if entry.where == "game" then return "Playing" end
  return STATUS_TEXT[entry.status or "idle"] or tostring(entry.status)
end

local ACTIVITY_TEXT = { battle_single = "a battle", battle_double = "a Double Battle",
  battle_multi = "a Multi Battle", trade = "a trade", watch = "watch their battle",
  tournament = "a tournament" }

function OnlinePage.activityText(activity)
  return ACTIVITY_TEXT[activity or ""] or tostring(activity or "play")
end

-- Ask another trainer to battle, trade or watch this room's battle.
function OnlinePage:invitePlayer(entry, kind)
  local game, why = self:game()
  if not game then return self:say(why, "error") end
  if not (entry and entry.id) then return end
  local activity, detail, profile
  if kind == "watch" then
    local room = Client().room()
    if not room then return self:say("Host or join a battle first, then invite someone to watch.", "error") end
    activity, detail, profile = "watch", { room = room.room }, room.profile or game.profile
  elseif kind == "trade" then
    profile = self:hostProfile(game, "trade")
    activity, detail = "trade", { ruleset = profile and profile.rulesetId or nil }
  else
    profile = self:hostProfile(game, "battle")
    activity = "battle_single"
    if game.generation == 3 then
      for _, f in ipairs(OnlinePage.FORMATS) do
        if f.value == self.hostOpts.format then activity = f.activity end
      end
    end
    detail = { ruleset = profile and profile.rulesetId or nil }
  end
  if not profile then return self:say("This game can't play online.", "error") end
  self:advertise(profile)
  local ok, handle = call("invite", entry.id, activity, detail, profile)
  if not ok then return self:say("The invite could not be sent.", "error") end
  self.outgoing = { handle = handle, name = entry.name, activity = activity, to = entry.id }
  self:say(("Inviting %s to %s..."):format(tostring(entry.name or "?"),
    OnlinePage.activityText(activity)), "info")
end

function OnlinePage:invites()
  local ok, list = call("invites")
  return ok and type(list) == "table" and list or {}
end

function OnlinePage:answerInvite(invite, accept)
  if not (invite and invite.id) then return end
  if accept then
    local game, why = self:game()
    if not game then return self:say(why, "error") end
    if Client().room() then self:leave() end
    if invite.activity ~= "watch" then
      local kind = invite.activity == "trade" and "trade" or "battle"
      local rulesetId = type(invite.detail) == "table" and invite.detail.ruleset or nil
      if game.generation == 3 and rulesetId then
        self:advertise(self:profile(game.version, rulesetId))
      else
        self:advertise(self:hostProfile(game, kind))
      end
    end
    self.team, self.teamOrder, self.readied, self.lastResult = {}, {}, nil, nil
  end
  call("replyInvite", invite.id, accept == true)
  local from = invite.from and invite.from.name or "the other trainer"
  if accept then
    self:say(("Joining %s..."):format(tostring(from)), "info")
  else
    self:say(("You declined %s's invite."):format(tostring(from)), "info")
  end
end

-- ----------------------------------------------------------------- battle

function OnlinePage:partySize(game)
  local room = Client().room()
  local rule = room and room.rule or game.profile.rule or {}
  return tonumber(rule.partySize) or 3
end

local function refKey(ref)
  if type(ref) == "number" then return "party|" .. ref end
  return ("box|%s|%s"):format(tostring(ref.box), tostring(ref.index))
end
OnlinePage.refKey = refKey

function OnlinePage:teamList()
  local list = {}
  for _, ref in ipairs(self.teamOrder) do
    if self.team[refKey(ref)] then list[#list + 1] = ref end
  end
  return list
end

function OnlinePage:picked(ref)
  return self.team[refKey(ref)] ~= nil
end

-- Add or drop one pick: a party index, or { where = "box", box, index }.
-- limit overrides the room's team size (a tournament entry picks up to 6).
function OnlinePage:toggle(ref, game, limit)
  if self.readied then return end
  local key = refKey(ref)
  if self.team[key] then
    self.team[key] = nil
    for i = #self.teamOrder, 1, -1 do
      if refKey(self.teamOrder[i]) == key then table.remove(self.teamOrder, i) end
    end
  elseif #self:teamList() < (limit or self:partySize(game)) then
    self.team[key] = ref
    self.teamOrder[#self.teamOrder + 1] = ref
  end
end

local function digest(packed)
  local Protocol = require("src.link.Protocol")
  local Fingerprint = require("src.link.Fingerprint")
  local text = Protocol.canonical(packed)
  return ("%08x%08x"):format(Fingerprint.fnv1a32(text, 0x811C9DC5),
                             Fingerprint.fnv1a32(text, 0x050C5D1F))
end

function OnlinePage:pack(game, team, rule)
  local TeamPick = require("src.online.TeamPick")
  local source = self:source(game)
  if not source then return nil, "That save could not be read." end
  local room = Client().room()
  rule = rule or (room and room.rule) or game.profile.rule
  local ok, why = TeamPick.validate(source, team, rule)
  if not ok then return nil, why end
  return TeamPick.pack(source, team, game.generation)
end

function OnlinePage:ready()
  local game, why = self:game()
  if not game then return self:say(why, "error") end
  local team = self:teamList()
  local packed, err = self:pack(game, team)
  if not packed then return self:say(err, "error") end
  self.myPacked, self.myTeam = packed, team
  Client().ready(packed, digest(packed))
  self.readied = true
  self.lastResult = nil
  self:say("Ready. The battle starts when everyone is ready.", "info")
end

-- Take back Ready to change the team.
function OnlinePage:unready()
  if not self.readied then return end
  pcall(Client().ready, {}, nil)
  self.readied, self.myTeam = nil, nil
  self:say("Not ready. Change your team, then ready up again.", "info")
end

-- The relay started a match: build the launch spec and hand the game the
-- window.  A player's battle reports its result through onDone; a
-- spectator's only watches.
function OnlinePage:startMatch(p)
  local game, why = self:game()
  if not game then return self:say(why, "error") end
  if type(p) ~= "table" then return end
  self.lastResult = nil
  local fields
  if p.role == "spectator" then
    fields = {
      profile = p.profile or game.profile, role = "spectator", slotId = game.slotId,
      seed = p.seed, session = Client().roomSession(),
      hostParty = p.hostParty, guestParty = p.guestParty,
      hostName = p.hostName, guestName = p.guestName,
      seats = p.seats, match = p.match, room = p.room, players = p.players,
    }
  else
    local team = self.myTeam
    local tour = select(2, call("tournament"))
    local entered = tour and tourPicks[tour.tour]
    if not team and entered then
      team, self.myPacked = entered.team, entered.packed
    end
    if not team then
      -- a room that starts on its own (Gen 3) takes the first party members
      team = {}
      for i = 1, self:partySize(game) do team[i] = i end
      self.myPacked = self:pack(game, team)
    end
    local specTeam = team
    if game.generation ~= 3 then
      -- before Gen 3 the spec names party slots only; a PC pick travels
      -- in the packed team
      for _, ref in ipairs(team) do
        if type(ref) ~= "number" then specTeam = nil break end
      end
    end
    fields = {
      profile = p.profile or game.profile, role = p.role, slotId = game.slotId,
      team = specTeam, seed = p.seed, session = Client().roomSession(),
      theirParty = p.theirParty, myParty = self.myPacked,
      peerName = p.peerName, hostName = p.hostName, guestName = p.guestName,
      seat = p.seat, seats = p.seats, match = p.match, room = p.room, players = p.players,
      onDone = function(result)
        if result == "win" or result == "lose" or result == "draw" then
          pcall(Client().report, result)
        end
      end,
    }
  end
  local spec, err = require("src.online.ArenaBoot").spec(fields)
  if not spec then return self:say("The battle could not start: " .. tostring(err), "error") end
  self.launcher:launchArena(game.version, spec)
end

function OnlinePage:onEvent(event, payload)
  if event == "match_start" then
    self.launcher:queue(function() self:startMatch(payload) end)
  elseif event == "match_end" then
    self.readied, self.myTeam = nil, nil
    if type(payload) == "table" and payload.youWon ~= nil then
      self.lastResult = payload.youWon and "You won!" or "You lost."
      self:say(self.lastResult, "info")
    else
      self.lastResult = "The battle is over."
    end
  elseif event == "invite_token" and type(payload) == "table" then
    self.inviteToken = payload.token
    if love.system and love.system.setClipboardText and payload.token then
      pcall(love.system.setClipboardText, payload.token)
    end
  elseif event == "error" and type(payload) == "table" then
    if self.closing and payload.reason == "closed" then
      self.closing = nil
      return self:say("You closed the room.", "info")
    end
    self:say(payload.text or payload.reason or "Something went wrong online.", "error")
  elseif event == "room" then
    if payload == nil then
      self:endTrade()
      self.readied, self.myTeam, self.inviteToken, self.lastResult = nil, nil, nil, nil
    else
      self.pinPrompt = nil
      if self.outgoing and self.outgoing.accepted then self.outgoing = nil end
    end
  elseif event == "invite_in" and type(payload) == "table" then
    local from = payload.from and payload.from.name or "A trainer"
    if payload.id then self.inviteNames[payload.id] = from end
    self:say(("%s invites you to %s."):format(tostring(from),
      OnlinePage.activityText(payload.activity)), "info")
  elseif event == "invite_sent" and type(payload) == "table" then
    if self.outgoing then
      self:say(("Invite sent to %s. Waiting for an answer..."):format(tostring(self.outgoing.name)), "info")
    end
  elseif event == "invite_closed" and type(payload) == "table" then
    self:inviteClosed(payload)
  elseif event == "tournament" then
    self:onTournament(payload)
  elseif event == "tour_match" and type(payload) == "table" then
    self:say(("You play next: round %d. Your battle opens when it starts."):format(
      tonumber(payload.round) or 1), "info")
  elseif event == "tour_spectate" then
    self:say("A tournament battle is starting. It opens here to watch.", "info")
  elseif event == "tour_bye" and type(payload) == "table" then
    self:say(("You have a bye in round %d and go straight through."):format(
      tonumber(payload.round) or 1), "info")
  elseif event == "tour_over" and type(payload) == "table" then
    if payload.championId and self:isYou(payload.championId) then
      self:say("You won the tournament! You are the champion.", "info")
    else
      self:say(("The tournament is over. %s is the champion."):format(
        tostring(payload.champion or "Nobody")), "info")
    end
  end
end

function OnlinePage:inviteClosed(msg)
  local incoming = msg.id and self.inviteNames[msg.id]
  if incoming then
    self.inviteNames[msg.id] = nil
    if msg.why ~= "accepted" and msg.why ~= "crossed" and msg.why ~= "declined" then
      self:say(("%s's invite is no longer open."):format(tostring(incoming)), "info")
    end
    return
  end
  local out = self.outgoing
  if not out then return end
  if msg.why == "accepted" or msg.why == "crossed" then
    out.accepted = true
    self:say(("%s accepted. Opening the room..."):format(tostring(out.name)), "info")
    return
  end
  self.outgoing = nil
  local Protocol2 = require("src.online.Protocol2")
  local ok, text = pcall(Protocol2.inviteClosedText, msg)
  self:say(ok and text or ("The invite closed: " .. tostring(msg.why)),
    (msg.why == "declined" or msg.why == "timeout") and "info" or "error")
end

-- ------------------------------------------------------------ tournaments

-- The team picked for a tournament, packed, or nil plus why not.  rule is
-- the tournament's rule when it is known.
function OnlinePage:tourEntry(game, rule)
  local team = self:teamList()
  if #team == 0 then return nil, "Pick your team first." end
  local need = rule and tonumber(rule.partySize)
  if need and #team ~= need then
    return nil, ("This tournament plays %d Pokemon; you picked %d."):format(need, #team)
  end
  rule = rule or {}
  local packed, why = self:pack(game, team, { partySize = #team, minLevel = rule.minLevel,
    maxLevel = rule.maxLevel, forceLevel = rule.forceLevel })
  if not packed then return nil, why end
  return { team = team, packed = packed }
end

function OnlinePage:hostTournament()
  local game, why = self:game()
  if not game then return self:say(why, "error") end
  local rule = self:hostRule(game)
  local entry, err = self:tourEntry(game, rule)
  if not entry then return self:say(err, "error") end
  local profile, perr = self:hostProfile(game, "battle")
  if not profile then return self:say(perr, "error") end
  local o = self.tourOpts
  self:advertise(profile)
  self.tourEntering = entry
  self:request(Client().createTournament({
    profile = profile, rule = rule, playing = true, shotClock = o.shotClock,
    maxSpectators = o.spectators, party = entry.packed, partyDigest = digest(entry.packed),
    public = o.public,
  }), { tour = true, keepTeam = true })
  self:say(nil)
end

-- Join a tournament by its code (6 letters/digits) or id, as a player
-- (with the picked team) or a spectator.  entry is its lobby row.
function OnlinePage:joinTournament(ref, as, entry)
  local game, why = self:game()
  if not game then return self:say(why, "error") end
  as = as or "player"
  ref = tostring(ref or ""):gsub("%s", "")
  local opts = { as = as }
  if ref:match("^t%x+$") and #ref == 17 then
    opts.tour = ref:lower()
  elseif #ref == 6 and ref:match("^%w+$") then
    opts.code = ref:upper()
  else
    return self:say("Enter a tournament code (6 letters and digits).", "error")
  end
  local profile = entry and self:joinProfile(game, entry) or game.profile
  opts.profile = profile
  if as == "player" then
    local rule = entry and entry.profile and entry.profile.rule
    local tourEntry, err = self:tourEntry(game, rule)
    if not tourEntry then return self:say(err, "error") end
    opts.party, opts.partyDigest = tourEntry.packed, digest(tourEntry.packed)
    self.tourEntering = tourEntry
  else
    self.tourEntering = nil
  end
  self:advertise(profile)
  local ok, pending = call("joinTournament", opts)
  if not ok then return self:say("Couldn't join that tournament.", "error") end
  self:request(pending, { tour = true, as = as, keepTeam = true })
  self:say(nil)
end

function OnlinePage:onTournament(tour)
  if type(tour) ~= "table" then
    self.tourEntering = nil
    return
  end
  if self.tourEntering and tour.tour then
    tourPicks[tour.tour] = self.tourEntering
    self.tourEntering = nil
  end
end

function OnlinePage:tourCall(name, ...)
  call(name, ...)
end

-- The creator of a tournament can start it, remove players and close it.
function OnlinePage:isCreator(tour)
  return tour ~= nil and tour.creator ~= nil and self:isYou(tour.creator)
end

-- The name of a tournament player, by id.
function OnlinePage.tourName(tour, id)
  if id == nil then return "?" end
  for _, p in ipairs(tour and tour.players or {}) do
    if p.id == id then return tostring(p.name or id) end
  end
  return tostring(id)
end

-- This trainer's next unplayed match in the current round, or nil.
function OnlinePage:nextMatch(tour)
  if not (tour and tour.stage == "running") then return nil end
  local you = self:you()
  if not you then return nil end
  for _, round in ipairs(tour.bracket or {}) do
    for _, match in ipairs(round.matches or {}) do
      if (match.a == you.id or match.b == you.id)
          and (match.state == "pending" or match.state == "live") then
        return match, round.round
      end
    end
  end
  return nil
end

-- ------------------------------------------------------------------ trade

function OnlinePage:beginTrade(game)
  local Trade = require("src.online.Trade")
  local handle, why = Trade.openSlot(game.version, game.slotId)
  if not handle then return self:say("The trade could not start: " .. tostring(why), "error") end
  local peer
  for _, pl in ipairs((Client().room() or {}).players or {}) do
    if not self:isYou(pl.id) then peer = pl.name end
  end
  local remote, err = Trade.remote(handle, Client().roomSession(), { peerName = peer })
  if not remote then return self:say("The trade could not start: " .. tostring(err), "error") end
  remote:start()
  self.trade = remote
end

function OnlinePage:endTrade()
  if self.trade then pcall(self.trade.close, self.trade) end
  self.trade = nil
end

-- ----------------------------------------------------------------- update

-- An invite code the app was opened with (launcher.pendingInvite): fill
-- the join field, sign in if needed and join once online.
function OnlinePage:takeLaunchInvite()
  local l = self.launcher
  local code = l.pendingInvite
  if code then
    l.pendingInvite = nil
    self.joinText = tostring(code)
    self.autoJoin = self.joinText
    local state = Client().state()
    if state ~= "online" and state ~= "connecting" and state ~= "ticket"
        and state ~= "reconnecting" then
      self:connect()
    end
  end
  if self.autoJoin and self:online() and not self.pending and not Client().room() then
    local text = self.autoJoin
    self.autoJoin = nil
    self:join(text)
  end
end

-- Say so when the relay connection drops, and when it comes back.
function OnlinePage:watchConnection()
  local state = Client().state()
  if state == "online" then
    if self.lost then
      self.lost = nil
      self:say("Reconnected.", "info")
    end
    self.wasOnline = true
  elseif self.wasOnline and state ~= "offline" then
    self.wasOnline = nil
    self.lost = true
    self.pending, self.pinPrompt = nil, nil
    if state == "reconnecting" then
      self:say("Connection lost. Reconnecting...", "error")
    else
      local err = Connect().error() or (select(2, call("error")))
      self:say("Connection lost" .. (err and (": " .. tostring(err)) or ".")
        .. " Press Connect to try again.", "error")
    end
  elseif state == "offline" then
    self.wasOnline, self.lost = nil, nil
  end
end

-- A request answered: report what went wrong, or open the PIN prompt.
function OnlinePage:finished(pending)
  local info = self.pendingInfo or {}
  self.pendingInfo = nil
  if not pending.error then
    if info.as == "spectator" then
      self:say("Watching. The battle opens here when it starts.", "info")
    end
    return
  end
  local reason = pending.reason
  if (reason == "pin_required" or reason == "bad_pin") and info.room then
    self.pinPrompt = { room = info.room, as = info.as, entry = info.entry, text = "" }
    if reason == "pin_required" then
      return self:say("That room is private. Enter its 4-digit PIN.", "info")
    end
    return self:say(pending.error, "error")
  end
  if reason == "pin_locked" then self.pinPrompt = nil end
  self:say(pending.error, "error")
end

function OnlinePage:update(dt)
  pcall(function() require("src.online.Trade").pumpPending(dt) end)
  self:watchConnection()
  local pending = self.pending
  if pending then
    if pending.done then
      self.pending = nil
      self:finished(pending)
    else
      self.pendingAge = (self.pendingAge or 0) + (dt or 0)
      if self.pendingAge > OnlinePage.JOIN_TIMEOUT then
        self.pending, self.pendingInfo = nil, nil
        self:say("The relay didn't answer. Try again.", "error")
      end
    end
  end
  self:takeLaunchInvite()
  local room = Client().room()
  if room and room.intent == "trade" and not self.trade then
    local session = Client().roomSession()
    -- one attempt per paired session: a save that can't be read would
    -- otherwise retry (and toast) every frame
    if session and session.paired and self.tradeTried ~= session then
      self.tradeTried = session
      local game = self:game()
      if game then self:beginTrade(game) end
    end
  end
  if self.trade then
    local ok, stage = pcall(self.trade.update, self.trade)
    if not ok then
      self:say(stage, "error")
      self:endTrade()
    elseif stage == "committed" then
      self:say("Trade complete. The save was updated.", "info")
      self.launcher:savesChanged()
      self.sourceKey = nil
      self.team, self.teamOrder = {}, {}
      self:endTrade()
    elseif stage == "cancelled" then
      local why = self.trade.session and self.trade.session.error
      self:say("The trade was cancelled" .. (why and (": " .. tostring(why)) or "."), "error")
      self:endTrade()
    end
  end
end

-- ------------------------------------------------------------------- text

function OnlinePage.formatName(profile)
  return FORMAT_BY_RULESET[profile and profile.rulesetId or ""]
end

-- "3 Pokemon, all Lv50" and the like.
function OnlinePage.ruleText(rule)
  if type(rule) ~= "table" then return nil end
  local parts = { ("%d Pokemon"):format(tonumber(rule.partySize) or 3) }
  if rule.forceLevel then
    parts[#parts + 1] = ("all Lv%d"):format(rule.forceLevel)
  else
    if rule.minLevel then parts[#parts + 1] = ("Lv%d or higher"):format(rule.minLevel) end
    if rule.maxLevel then parts[#parts + 1] = ("up to Lv%d"):format(rule.maxLevel) end
  end
  return table.concat(parts, ", ")
end

function OnlinePage:serverNow()
  local ok, t = call("serverTime")
  return ok and t or nil
end

-- ------------------------------------------------------------------- draw

local STATE_TEXT = { offline = "Offline", connecting = "Connecting...",
  ticket = "Signing in...", reconnecting = "Reconnecting...", error = "Not connected" }

-- Draws the page in a card at x, y, w, h and returns the height it used.
function OnlinePage:draw(x, y, w, h, s)
  local l = self.launcher
  local pad = math.floor(18 * s)
  Kit.card(x, y, w, h)
  local cx, cw = x + pad, w - 2 * pad
  local cy = y + pad
  local m = Layout.metrics(s)
  local rowH, gap = m.rowH, m.gap
  local function btnW(label) return Layout.buttonW(s, label) end

  cy = l:pageHeader(cx, cy, cw, s, { title = "Online",
    subtitle = "Battle, trade and watch with other players" }) - math.floor(8 * s)

  if self:networkMissing() then
    cy = Layout.para("small", OnlinePage.WEB_TEXT, cx, cy, cw, PAL.red)
    return cy + gap - y + pad
  end

  local state = Connect().state()
  local online = state == "online"
  local you = Client().you()
  local Net = require("src.link.Net")
  local status = online and ("Online as " .. tostring(you and you.name or Connect().name() or "?"))
    or STATE_TEXT[state] or "Offline"
  if online then
    local okC, counts = call("counts")
    if okC and type(counts) == "table" and counts.players then
      status = status .. ("  -  %d online"):format(counts.players)
    end
  end
  Kit.text("small", Kit.ellipsize("small", status .. "  -  relay " .. tostring(Net.defaultRelayAddress()), cw),
    cx, cy, online and PAL.green or PAL.muted)
  cy = cy + Kit.textHeight("small") + math.floor(12 * s)

  local game, gameWhy = self:game()
  -- name and connect
  local connW = btnW(online and "Disconnect" or "Connect")
  local renW = btnW("Rename")
  local fieldW = cw - connW - renW - 2 * gap
  -- too narrow for all three: the name and Rename share a line, Connect gets its own
  local stacked = fieldW < 200 * s
  if stacked then fieldW = cw - renW - gap end
  local nameEnd
  self.nameDraft, nameEnd = Kit.textfield("online-name", cx, cy, fieldW, rowH, self.nameDraft, "Your online name")
  if Kit.button(cx + fieldW + gap, cy, renW, rowH, "Rename", { id = "online-rename", font = "small" })
      or nameEnd == "submit" then
    local text = self.nameDraft
    l:queue(function() self:rename(text) end)
  end
  if stacked then cy, connW = cy + rowH + gap, cw end
  if Kit.button(cx + cw - connW, cy, connW, rowH, online and "Disconnect" or "Connect",
      { id = "online-connect", font = "small", kind = online and nil or "primary",
        enabled = online or (game ~= nil and not Connect().busy()) }) then
    l:queue(function() if online then self:disconnect() else self:connect() end end)
  end
  cy = cy + rowH + gap

  local err = Connect().error()
  local message = self.notice
    or (err and { text = tostring(err):gsub("^%l", string.upper), kind = "error", hint = not online })
    or (not game and { text = gameWhy, kind = "error" })
  if message then
    Kit.textWrapped("small", message.text, cx, cy, cw, message.kind == "error" and PAL.red or PAL.text)
    cy = cy + Kit.wrapHeight("small", message.text, cw) + math.floor(4 * s)
    if message.hint then
      local hint = "Check your internet connection, or set another relay in Settings."
      Kit.textWrapped("micro", hint, cx, cy, cw, PAL.muted)
      cy = cy + Kit.wrapHeight("micro", hint, cw)
    end
    cy = cy + gap
  end
  if game then
    local line = ("Playing %s with %s"):format(GameVersion.info(game.version).displayName,
      tostring(game.slotName or game.slotId))
    Kit.text("micro", Kit.ellipsize("micro", line, cw), cx, cy, PAL.faint)
    cy = cy + Kit.textHeight("micro") + gap
  end
  if not online then
    -- what signing in opens up, so the empty page says why to
    local what = "Connect to see open rooms, who else is online, live battles to watch "
      .. "and tournaments. Battles and trades use the save you play here."
    cy = cy + Theme.space("s", s)
    Kit.textWrapped("small", what, cx, cy, cw, PAL.muted)
    cy = cy + Kit.wrapHeight("small", what, cw)
    return cy - y + pad
  end

  cy = self:drawInvites(game, cx, cy, cw, m)
  local okT, tour = call("tournament")
  local room = Client().room()
  if okT and type(tour) == "table" then
    cy = self:drawTournament(tour, room, game, cx, cy, cw, m)
  elseif room then
    cy = self:drawRoom(room, game, cx, cy, cw, m)
  else
    cy = self:drawLobby(game, cx, cy, cw, m)
  end
  return cy - y + pad
end

require("src.launcher.online.LobbyView").install(OnlinePage)
require("src.launcher.online.RoomView").install(OnlinePage)
require("src.launcher.online.TourView").install(OnlinePage)

return OnlinePage
