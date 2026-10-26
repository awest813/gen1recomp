-- The PK:GB launcher's Online page: connect to the relay, host or join a
-- room, pick a team and battle, or trade one Pokemon.
--
-- Written for src/launcher/ on the online modules alone: Connect (name and
-- sign-in), Client (relay connection, rooms, events), ArenaData (the
-- profile two games must share), TeamPick (a team from a save), ArenaBoot
-- (the battle launch spec) and Trade (the two-save exchange).  main.lua
-- already pumps Connect.update and Client.update every frame.
--
-- It plays the game selected in the launcher with that game's chosen save,
-- the original game only (no custom cart).

local Kit = require("src.ui.kit.Kit")
local Theme = require("src.ui.kit.Theme")
local GameVersion = require("src.core.GameVersion")

local PAL = Theme.PAL

local OnlinePage = {}
OnlinePage.__index = OnlinePage

local function lazy(name)
  return function() return require(name) end
end
local Connect = lazy("src.online.Connect")
local Client = lazy("src.online.Client")

local EVENTS = { "match_start", "match_end", "invite_token", "error", "room" }

function OnlinePage.new(launcher)
  local self = setmetatable({
    launcher = launcher,
    joinText = "",
    team = {},          -- party index -> true
    notice = nil,       -- { text, kind }
    profiles = {},      -- version -> profile
    handlers = {},
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
  local profile, why = self:profile(v)
  if not profile then return nil, why end
  return { version = v, slotId = slotId, slotName = slotName, profile = profile,
           generation = GameVersion.generation(v) }
end

function OnlinePage:profile(version)
  local cached = self.profiles[version]
  if cached then return cached end
  local ArenaData = require("src.online.ArenaData")
  local rulesetId = GameVersion.generation(version) == 3 and "g3_single" or nil
  local ok, profile, why = pcall(ArenaData.profile, version, "vanilla", nil, nil, rulesetId)
  if not ok then return nil, tostring(profile) end
  if not profile then return nil, tostring(why or "this game cannot play online") end
  self.profiles[version] = profile
  return profile
end

-- The save's party, read once per save.
function OnlinePage:source(game)
  local key = game.version .. ":" .. game.slotId
  if self.sourceKey ~= key then
    local TeamPick = require("src.online.TeamPick")
    local ok, slot, why = pcall(TeamPick.readSlot, game.version, game.slotId)
    self.sourceKey = key
    self.sourceSlot = ok and slot or nil
    self.sourceWhy = ok and why or slot
    self.team = {}
  end
  return self.sourceSlot, self.sourceWhy
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

function OnlinePage:connect()
  local game, why = self:game()
  if not game then return self:say(why, "error") end
  local source = self:source(game)
  local trainer = source and source.trainerName or game.slotName
  local ok, err = pcall(Connect().start, {
    version = game.version,
    trainerName = trainer,
    profiles = { game.profile },
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
  pcall(Connect().disconnect)
  self.pending, self.inviteToken = nil, nil
end

function OnlinePage:online()
  return Client().state() == "online"
end

-- ------------------------------------------------------------------ rooms

function OnlinePage:host(intent)
  local game, why = self:game()
  if not game then return self:say(why, "error") end
  self.pending = Client().createRoom({ intent = intent, profile = game.profile,
    playing = true, seats = 2 })
  self.team, self.readied, self.inviteToken = {}, nil, nil
end

-- A room id (r + 16 hex) or an invite code (32 hex).
function OnlinePage:join(text, roomId)
  local game, why = self:game()
  if not game then return self:say(why, "error") end
  text = tostring(roomId or text or ""):gsub("%s", "")
  if text:match("^%x+$") and #text == 32 then
    self.pending = Client().joinRoomByInvite(text:lower(), "player", game.profile)
  elseif text:match("^r%x+$") and #text == 17 then
    self.pending = Client().joinRoom(text:lower(), "player", game.profile)
  else
    return self:say("Enter a room code (r and 16 letters/digits) or an invite code.", "error")
  end
  self.team, self.readied, self.inviteToken = {}, nil, nil
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
  self.team, self.readied, self.inviteToken = {}, nil, nil
end

-- Two games can share a room when their profiles match.
function OnlinePage:compatible(entry, game)
  if not (entry and game) then return false end
  if entry.profile then
    local ok, same = pcall(require("src.online.ArenaData").equal, entry.profile, game.profile)
    return ok and same == true
  end
  return entry.version == game.version
end

-- ----------------------------------------------------------------- battle

function OnlinePage:partySize(game)
  local room = Client().room()
  local rule = room and room.rule or game.profile.rule or {}
  return tonumber(rule.partySize) or 3
end

function OnlinePage:teamList()
  local list = {}
  for index in pairs(self.team) do list[#list + 1] = index end
  table.sort(list)
  return list
end

function OnlinePage:toggle(index, game)
  if self.readied then return end
  if self.team[index] then
    self.team[index] = nil
  elseif #self:teamList() < self:partySize(game) then
    self.team[index] = true
  end
end

local function digest(packed)
  local Protocol = require("src.link.Protocol")
  local Fingerprint = require("src.link.Fingerprint")
  local text = Protocol.canonical(packed)
  return ("%08x%08x"):format(Fingerprint.fnv1a32(text, 0x811C9DC5),
                             Fingerprint.fnv1a32(text, 0x050C5D1F))
end

function OnlinePage:pack(game, team)
  local TeamPick = require("src.online.TeamPick")
  local source = self:source(game)
  if not source then return nil, "That save could not be read." end
  local room = Client().room()
  local rule = (room and room.rule) or game.profile.rule
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
  self:say("Ready. The battle starts when the other trainer is ready too.", "info")
end

-- The relay started the match: build the launch spec and hand the game
-- the window.  The battle reports its result through onDone.
function OnlinePage:startMatch(p)
  local game, why = self:game()
  if not game then return self:say(why, "error") end
  if type(p) ~= "table" or p.role == "spectator" then return end
  local team = self.myTeam
  if not team then
    -- a room that starts on its own (Gen 3) takes the first party members
    team = {}
    for i = 1, self:partySize(game) do team[i] = i end
    self.myPacked = self:pack(game, team)
  end
  local fields = {
    profile = p.profile or game.profile, role = p.role, slotId = game.slotId,
    team = team, seed = p.seed, session = Client().roomSession(),
    theirParty = p.theirParty, myParty = self.myPacked,
    peerName = p.peerName, hostName = p.hostName, guestName = p.guestName,
    seat = p.seat, seats = p.seats, match = p.match, room = p.room, players = p.players,
    onDone = function(result)
      if result == "win" or result == "lose" or result == "draw" then
        pcall(Client().report, result)
      end
    end,
  }
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
      self:say(payload.youWon and "You won!" or "You lost.", "info")
    end
  elseif event == "invite_token" and type(payload) == "table" then
    self.inviteToken = payload.token
    if love.system and love.system.setClipboardText and payload.token then
      pcall(love.system.setClipboardText, payload.token)
    end
  elseif event == "error" and type(payload) == "table" then
    self:say(payload.text or payload.reason or "Something went wrong online.", "error")
  elseif event == "room" and payload == nil then
    self:endTrade()
    self.readied, self.myTeam, self.inviteToken = nil, nil, nil
  end
end

-- ------------------------------------------------------------------ trade

function OnlinePage:beginTrade(game)
  local Trade = require("src.online.Trade")
  local handle, why = Trade.openSlot(game.version, game.slotId)
  if not handle then return self:say("The trade could not start: " .. tostring(why), "error") end
  local peer
  for _, pl in ipairs((Client().room() or {}).players or {}) do
    local you = Client().you()
    if not (you and pl.id == you.id) then peer = pl.name end
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

function OnlinePage:update(dt)
  pcall(function() require("src.online.Trade").pumpPending(dt) end)
  local pending = self.pending
  if pending and pending.done then
    self.pending = nil
    if pending.error then self:say(pending.error, "error") end
  end
  local room = Client().room()
  if room and room.intent == "trade" and not self.trade then
    local session = Client().roomSession()
    if session and session.paired then
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
      self:endTrade()
    elseif stage == "cancelled" then
      local why = self.trade.session and self.trade.session.error
      self:say("The trade was cancelled" .. (why and (": " .. tostring(why)) or "."), "error")
      self:endTrade()
    end
  end
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
  local rowH = math.max(Kit.tapMin(), math.floor(40 * s))
  local smallH = math.max(Kit.tapMin(), math.floor(32 * s))
  local gap = math.floor(10 * s)
  local function btnW(label) return math.max(Kit.tapMin(), Kit.textWidth("small", label) + math.floor(28 * s)) end

  cy = l:pageHeader(cx, cy, cw, s, { title = "Online",
    subtitle = "Battle and trade with other players" }) - math.floor(8 * s)

  local state = Connect().state()
  local online = state == "online"
  local you = Client().you()
  local Net = require("src.link.Net")
  local status = online and ("Online as " .. tostring(you and you.name or Connect().name() or "?"))
    or STATE_TEXT[state] or "Offline"
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
  if not online then return cy - y + pad end

  local room = Client().room()
  if room then
    cy = self:drawRoom(room, game, cx, cy, cw, s, rowH, smallH, gap)
  else
    cy = self:drawLobby(game, cx, cy, cw, s, rowH, smallH, gap)
  end
  return cy - y + pad
end

function OnlinePage:drawLobby(game, cx, cy, cw, s, rowH, smallH, gap)
  local l = self.launcher
  local busy = self.pending ~= nil
  local half = math.floor((cw - gap) / 2)
  if Kit.button(cx, cy, half, rowH, "Host a battle",
      { id = "online-host-battle", kind = "primary", enabled = game ~= nil and not busy }) then
    l:queue(function() self:host("battle") end)
  end
  if Kit.button(cx + cw - half, cy, half, rowH, "Host a trade",
      { id = "online-host-trade", enabled = game ~= nil and not busy }) then
    l:queue(function() self:host("trade") end)
  end
  cy = cy + rowH + gap
  local joinW = math.max(Kit.tapMin(), Kit.textWidth("small", "Join") + math.floor(28 * s))
  local joinEnd
  self.joinText, joinEnd = Kit.textfield("online-join", cx, cy, cw - joinW - gap, rowH, self.joinText,
    "Room or invite code")
  if Kit.button(cx + cw - joinW, cy, joinW, rowH, "Join",
      { id = "online-join-go", font = "small", enabled = game ~= nil and not busy })
      or (joinEnd == "submit" and game ~= nil and not busy) then
    local text = self.joinText
    l:queue(function() self:join(text) end)
  end
  cy = cy + rowH + gap * 2

  local refreshW = math.max(Kit.tapMin(), Kit.textWidth("small", "Refresh") + math.floor(28 * s))
  Kit.caption(cx, cy + (smallH - Kit.textHeight("caption")) / 2, "OPEN ROOMS", PAL.caption)
  if Kit.button(cx + cw - refreshW, cy, refreshW, smallH, "Refresh", { id = "online-refresh", font = "small" }) then
    l:queue(function() self:refreshLobby() end)
  end
  cy = cy + smallH + math.floor(6 * s)
  local okR, rooms = pcall(Client().openRooms)
  rooms = okR and rooms or {}
  if #rooms == 0 then
    Kit.emptyBox(cx, cy, cw, rowH * 2, "No open rooms. Host one, or join with a code.")
    return cy + rowH * 2 + gap
  end
  local entryH = math.max(Kit.tapMin() + math.floor(8 * s), math.floor(52 * s))
  for i, entry in ipairs(rooms) do
    local ry = cy + (i - 1) * (entryH + math.floor(4 * s))
    Kit.row(cx, ry, cw, entryH, false, "online-room-" .. tostring(entry.id))
    local fits = self:compatible(entry, game)
    local info = entry.version and GameVersion.info(entry.version)
    local detail = ("%s  -  %s"):format(tostring(entry.intent or "room"),
      info and info.displayName or tostring(entry.version or "?"))
    local jw = math.max(Kit.tapMin(), Kit.textWidth("small", "Join") + math.floor(28 * s))
    local textW = cw - jw - math.floor(36 * s)
    Kit.text("button", Kit.ellipsize("button", tostring(entry.name or "?"), textW),
      cx + math.floor(12 * s), ry + math.floor(6 * s), PAL.text)
    Kit.text("micro", Kit.ellipsize("micro", fits and detail or (detail .. "  -  not your game"), textW),
      cx + math.floor(12 * s), ry + entryH - Kit.textHeight("micro") - math.floor(8 * s), PAL.muted)
    if Kit.button(cx + cw - jw - math.floor(8 * s), ry + (entryH - smallH) / 2, jw, smallH, "Join",
        { id = "online-room-join-" .. tostring(entry.id), font = "small",
          enabled = fits and self.pending == nil }) then
      local id = entry.room
      l:queue(function() self:join(nil, id) end)
    end
  end
  return cy + #rooms * (entryH + math.floor(4 * s)) + gap
end

function OnlinePage:drawRoom(room, game, cx, cy, cw, s, rowH, smallH, gap)
  local l = self.launcher
  local title = (room.intent == "trade" and "Trade room" or "Battle room")
    .. "  -  code " .. tostring(room.room)
  Kit.textBold("button", Kit.ellipsize("button", title, cw), cx, cy, PAL.heading)
  cy = cy + Kit.textHeight("button") + math.floor(6 * s)
  for _, pl in ipairs(room.players or {}) do
    local line = tostring(pl.name) .. (pl.ready and "  -  ready" or "")
      .. (pl.online == false and "  -  away" or "")
    Kit.text("small", Kit.ellipsize("small", line, cw), cx, cy, PAL.text)
    cy = cy + Kit.textHeight("small") + math.floor(2 * s)
  end
  if #(room.players or {}) < (room.seats or 2) then
    Kit.text("small", "Waiting for another trainer...", cx, cy, PAL.muted)
    cy = cy + Kit.textHeight("small")
  end
  cy = cy + gap
  local half = math.floor((cw - gap) / 2)
  if Kit.button(cx, cy, half, smallH, "Get invite code", { id = "online-invite", font = "small" }) then
    l:queue(function() self:invite() end)
  end
  if Kit.button(cx + cw - half, cy, half, smallH, "Leave room",
      { id = "online-leave", font = "small", kind = "danger" }) then
    l:queue(function() self:leave() end)
  end
  cy = cy + smallH + math.floor(6 * s)
  if self.inviteToken then
    Kit.text("micro", Kit.ellipsize("micro", "Invite code (copied): " .. self.inviteToken, cw),
      cx, cy, PAL.faint)
    cy = cy + Kit.textHeight("micro") + math.floor(4 * s)
  end
  cy = cy + gap
  if not game then return cy end
  if room.intent == "trade" then
    return self:drawTrade(game, cx, cy, cw, s, rowH, smallH, gap)
  end
  return self:drawTeam(game, cx, cy, cw, s, rowH, smallH, gap)
end

function OnlinePage:drawTeam(game, cx, cy, cw, s, rowH, smallH, gap)
  local l = self.launcher
  local source, why = self:source(game)
  local size = self:partySize(game)
  Kit.caption(cx, cy, ("YOUR TEAM  -  PICK %d"):format(size), PAL.caption)
  cy = cy + Kit.textHeight("caption") + math.floor(6 * s)
  if not source then
    Kit.textWrapped("small", "That save could not be read: " .. tostring(why), cx, cy, cw, PAL.red)
    return cy + Kit.wrapHeight("small", "x " .. tostring(why), cw) + gap
  end
  local entryH = math.max(Kit.tapMin(), math.floor(40 * s))
  for i, mon in ipairs(source.party or {}) do
    local chosen = self.team[i] == true
    local clicked, ink = Kit.row(cx, cy, cw, entryH, chosen, "online-mon-" .. i)
    Kit.text("button", Kit.ellipsize("button", monName(game.version, mon), cw - math.floor(24 * s)),
      cx + math.floor(12 * s), cy + (entryH - Kit.textHeight("button")) / 2, ink or PAL.text)
    if clicked then l:queue(function() self:toggle(i, game) end) end
    cy = cy + entryH + math.floor(4 * s)
  end
  cy = cy + gap
  local count = #self:teamList()
  if Kit.button(cx, cy, math.min(cw, math.floor(260 * s)), rowH,
      self.readied and "Waiting for the other trainer" or ("Ready (%d/%d)"):format(count, size),
      { id = "online-ready", kind = "primary", enabled = not self.readied and count == size }) then
    l:queue(function() self:ready() end)
  end
  return cy + rowH + gap
end

local TRADE_STAGE = {
  handshake = "Connecting the two games...", seat = "Connecting the two games...",
  waitParty = "Swapping party lists...", picking = "Choose a Pokemon to offer.",
  waitPick = "Waiting for the other trainer to choose...",
  confirming = "Confirm the trade?", waitConfirm = "Waiting for the other trainer to confirm...",
  exchange = "Trading...", commit_wait = "Saving...", committed = "Done.",
}

function OnlinePage:drawTrade(game, cx, cy, cw, s, rowH, smallH, gap)
  local l = self.launcher
  local t = self.trade
  if not t then
    Kit.text("small", "The trade starts when another trainer joins.", cx, cy, PAL.muted)
    return cy + Kit.textHeight("small") + gap
  end
  local okS, stage = pcall(t.stage, t)
  stage = okS and stage or "?"
  Kit.text("small", TRADE_STAGE[stage] or tostring(stage), cx, cy, PAL.text)
  cy = cy + Kit.textHeight("small") + gap
  local session = t.session or {}
  local colW = math.floor((cw - gap) / 2)
  local entryH = math.max(Kit.tapMin(), math.floor(40 * s))
  Kit.caption(cx, cy, "YOUR PARTY", PAL.caption)
  Kit.caption(cx + colW + gap, cy, "THEIR PARTY", PAL.caption)
  cy = cy + Kit.textHeight("caption") + math.floor(6 * s)
  local mine = (t.handle and t.handle.party) or {}
  local theirs = session.theirParty or {}
  local rows = math.max(#mine, #theirs)
  for i = 1, rows do
    local ry = cy + (i - 1) * (entryH + math.floor(4 * s))
    if mine[i] then
      local okP, can = pcall(t.canPick, t, i)
      local chosen = session.myPick == i
      if Kit.button(cx, ry, colW, entryH, Kit.ellipsize("small", monName(game.version, mine[i]),
          colW - math.floor(20 * s)), { id = "trade-mine-" .. i, font = "small",
          active = chosen, enabled = stage == "picking" and okP and can ~= false }) then
        l:queue(function()
          local okK, picked, why = pcall(t.pick, t, i)
          if not okK or not picked then self:say(why or picked or "That Pokemon can't be traded.", "error") end
        end)
      end
    end
    if theirs[i] then
      local chosen = session.theirPick == i
      Kit.row(cx + colW + gap, ry, colW, entryH, chosen, "trade-theirs-" .. i)
      Kit.text("small", Kit.ellipsize("small", monName(game.version, theirs[i]), colW - math.floor(24 * s)),
        cx + colW + gap + math.floor(12 * s), ry + (entryH - Kit.textHeight("small")) / 2,
        chosen and PAL.inverse or PAL.text)
    end
  end
  cy = cy + rows * (entryH + math.floor(4 * s)) + gap
  if stage == "confirming" then
    local half = math.floor((cw - gap) / 2)
    if Kit.button(cx, cy, half, rowH, "Trade", { id = "trade-yes", kind = "primary" }) then
      l:queue(function() pcall(t.confirm, t, true) end)
    end
    if Kit.button(cx + cw - half, cy, half, rowH, "Cancel", { id = "trade-no" }) then
      l:queue(function() pcall(t.confirm, t, false) end)
    end
    cy = cy + rowH + gap
  end
  return cy
end

return OnlinePage
