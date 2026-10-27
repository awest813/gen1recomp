-- The lobby half of the PK:GB launcher's Online page
-- (src/launcher/OnlinePage.lua): hosting with its room options, joining by
-- code (and the PIN prompt), the open-room / watchable-battle / player
-- lists, and incoming invites.  Installed as methods on the page.

local Kit = require("src.ui.kit.Kit")
local Theme = require("src.ui.kit.Theme")
local GameVersion = require("src.core.GameVersion")
local Layout = require("src.launcher.online.Layout")

local PAL = Theme.PAL

local LobbyView = {}

local LEVEL_CAPS = {
  { value = 0, label = "Levels as they are" },
  { value = 50, label = "All Lv50" },
  { value = 100, label = "All Lv100" },
}

local function client() return require("src.online.Client") end

local function list(name)
  local fn = client()[name]
  if type(fn) ~= "function" then return {} end
  local ok, out = pcall(fn)
  return ok and type(out) == "table" and out or {}
end

local function gameName(version)
  local ok, info = pcall(GameVersion.info, version)
  return ok and info and info.displayName or tostring(version or "?")
end

function LobbyView.install(P)
  -- Incoming invites, each with Accept and Decline.
  function P:drawInvites(game, cx, cy, cw, m)
    local invites = self:invites()
    if #invites == 0 then return cy end
    local l = self.launcher
    local s = m.s
    Kit.caption(cx, cy, "INVITES", PAL.caption)
    cy = cy + Kit.textHeight("caption") + math.floor(6 * s)
    local now = self:serverNow()
    for _, inv in ipairs(invites) do
      local from = inv.from and inv.from.name or "A trainer"
      local text = ("%s invites you to %s."):format(tostring(from), P.activityText(inv.activity))
      local left = Layout.countdown(inv.expiresAt, now)
      local boxH = m.inset + Kit.wrapHeight("small", text, cw - 2 * m.inset)
        + (left and Kit.textHeight("micro") or 0) + m.gap + m.smallH + m.inset
      Kit.card(cx, cy, cw, boxH, "empty")
      local ty = Layout.para("small", text, cx + m.inset, cy + m.inset, cw - 2 * m.inset, PAL.heading)
      if left then ty = Layout.line("micro", left .. " left to answer", cx + m.inset, ty, cw, PAL.muted) end
      local id = tostring(inv.id)
      Layout.buttons(l, cx + m.inset, ty + m.gap, cw - 2 * m.inset, m.smallH, m, {
        { label = "Accept", id = "online-invite-accept-" .. id, kind = "primary",
          enabled = game ~= nil, run = function() self:answerInvite(inv, true) end },
        { label = "Decline", id = "online-invite-decline-" .. id,
          run = function() self:answerInvite(inv, false) end },
      })
      cy = cy + boxH + m.gap
    end
    return cy
  end

  function P:drawLobby(game, cx, cy, cw, m)
    local l = self.launcher
    local s, rowH, gap = m.s, m.rowH, m.gap
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
    cy = cy + rowH + math.floor(6 * s)
    local summary = self:optionsSummary(game)
    local optLabel = self.showOptions and "Hide room options" or "Room options"
    local optW = Layout.buttonW(s, optLabel)
    if Kit.button(cx, cy, math.min(cw, optW), m.smallH, optLabel,
        { id = "online-options", font = "small", kind = "ghost", active = self.showOptions }) then
      l:queue(function() self.showOptions = not self.showOptions end)
    end
    if optW + gap < cw then
      Kit.text("micro", Kit.ellipsize("micro", summary, cw - optW - gap), cx + optW + gap,
        cy + (m.smallH - Kit.textHeight("micro")) / 2, PAL.muted)
      cy = cy + m.smallH + gap
    else
      cy = Layout.line("micro", summary, cx, cy + m.smallH + 4, cw, PAL.muted) + gap
    end
    if self.showOptions then cy = self:drawHostOptions(game, cx, cy, cw, m) end

    local joinW = Layout.buttonW(s, "Join")
    local joinEnd
    self.joinText, joinEnd = Kit.textfield("online-join", cx, cy, cw - joinW - gap, rowH, self.joinText,
      "Room or invite code")
    if Kit.button(cx + cw - joinW, cy, joinW, rowH, "Join",
        { id = "online-join-go", font = "small", enabled = game ~= nil and not busy })
        or (joinEnd == "submit" and game ~= nil and not busy) then
      local text = self.joinText
      l:queue(function() self:join(text) end)
    end
    cy = cy + rowH + gap
    if self.pinPrompt then cy = self:drawPinPrompt(game, cx, cy, cw, m) end
    cy = cy + gap

    -- the lists
    local rooms = list("openRooms")
    local watch = {}
    for _, e in ipairs(list("watchable")) do
      if e.room then watch[#watch + 1] = e end
    end
    local players = self:players()
    local tabs = {
      { value = "rooms", label = ("Rooms (%d)"):format(#rooms) },
      { value = "watch", label = ("Watch (%d)"):format(#watch) },
      { value = "players", label = ("Players (%d)"):format(#players) },
    }
    local refreshW = Layout.buttonW(s, "Refresh")
    local tabW = cw - refreshW - gap
    local picked, below = Layout.choices(cx, cy, tabW, m, tabs, self.tab, "online-tab-")
    if picked then l:queue(function() self.tab = picked end) end
    if Kit.button(cx + cw - refreshW, cy, refreshW, m.smallH, "Refresh",
        { id = "online-refresh", font = "small" }) then
      l:queue(function() self:refreshLobby() end)
    end
    cy = below + gap
    if self.tab == "watch" then
      return self:drawWatchList(watch, game, cx, cy, cw, m)
    elseif self.tab == "players" then
      return self:drawPlayers(players, game, cx, cy, cw, m)
    end
    return self:drawRoomList(rooms, game, cx, cy, cw, m)
  end

  function P:optionsSummary(game)
    local o = self.hostOpts
    local parts = {}
    if game and game.generation == 3 then
      for _, f in ipairs(P.FORMATS) do
        if f.value == o.format then parts[#parts + 1] = f.label end
      end
    end
    parts[#parts + 1] = P.ruleText(self:hostRule(game))
    parts[#parts + 1] = o.private and "private" or "public"
    if not o.spectators then parts[#parts + 1] = "no spectators" end
    return table.concat(parts, "  -  ")
  end

  -- Format (Gen 3), battle rules, privacy and spectators for hosting.
  function P:drawHostOptions(game, cx, cy, cw, m)
    local l = self.launcher
    local s, gap = m.s, m.gap
    local o = self.hostOpts
    local small = math.floor(6 * s)
    if game and game.generation == 3 then
      Kit.caption(cx, cy, "BATTLE FORMAT", PAL.caption)
      cy = cy + Kit.textHeight("caption") + small
      local f, below = Layout.choices(cx, cy, cw, m, P.FORMATS, o.format, "online-format-")
      if f then l:queue(function() o.format = f end) end
      cy = below + gap
    end
    Kit.caption(cx, cy, "BATTLE RULES", PAL.caption)
    cy = cy + Kit.textHeight("caption") + small
    local rule = self:hostRule(game)
    local d
    d, cy = Layout.stepper(cx, cy, cw, m, "Team size", tostring(rule.partySize), "online-size",
      rule.partySize > 1, rule.partySize < 6)
    if d ~= 0 then l:queue(function() o.partySize = math.max(1, math.min(6, rule.partySize + d)) end) end
    cy = cy + small
    local capped = o.forceLevel ~= nil
    d, cy = Layout.stepper(cx, cy, cw, m, "Lowest level",
      o.minLevel and ("Lv" .. o.minLevel) or "Any", "online-min", not capped and o.minLevel ~= nil,
      not capped and (o.minLevel or 0) < (o.maxLevel or 100))
    if d ~= 0 then l:queue(function() self:stepLevel("minLevel", d) end) end
    cy = cy + small
    d, cy = Layout.stepper(cx, cy, cw, m, "Highest level",
      o.maxLevel and ("Lv" .. o.maxLevel) or "Any", "online-max",
      not capped and (o.maxLevel or 100) > (o.minLevel or 1), not capped and o.maxLevel ~= nil)
    if d ~= 0 then l:queue(function() self:stepLevel("maxLevel", d) end) end
    cy = cy + small
    local cap, below = Layout.choices(cx, cy, cw, m, LEVEL_CAPS, o.forceLevel or 0, "online-cap-")
    if cap then l:queue(function() o.forceLevel = cap > 0 and cap or nil end) end
    cy = below + gap
    local changed
    o.private, changed = Kit.checkbox(cx, cy, cw, m.smallH, o.private, "Private room (4-digit PIN)",
      "online-private")
    if changed then self:say(nil) end
    cy = cy + m.smallH + small
    if o.private then
      local fieldW = math.min(cw, math.max(Kit.tapMin() * 3, math.floor(140 * s)))
      local value = Kit.textfield("online-pin", cx, cy, fieldW, m.smallH, o.pin, "PIN")
      o.pin = tostring(value or ""):gsub("%D", ""):sub(1, 4)
      if fieldW + gap < cw then
        Kit.text("micro", Kit.ellipsize("micro", "Share it with the trainers you want in.",
          cw - fieldW - gap), cx + fieldW + gap, cy + (m.smallH - Kit.textHeight("micro")) / 2,
          PAL.muted)
      end
      cy = cy + m.smallH + small
    end
    o.spectators = Kit.checkbox(cx, cy, cw, m.smallH, o.spectators,
      "Let others watch my battles", "online-spectators")
    return cy + m.smallH + gap
  end

  -- Levels move in steps of 5; "Any" sits below the lowest and above the
  -- highest step.
  function P:stepLevel(field, d)
    local o = self.hostOpts
    local v = o[field]
    if field == "minLevel" then
      if v == nil then v = d > 0 and 5 or nil
      else v = v + 5 * d if v < 5 then v = nil end end
      if v and o.maxLevel and v > o.maxLevel then v = o.maxLevel end
    else
      if v == nil then v = d < 0 and 95 or nil
      else v = v + 5 * d if v > 95 then v = nil end end
      if v and v < 5 then v = 5 end
      if v and o.minLevel and v < o.minLevel then v = o.minLevel end
    end
    o[field] = v
  end

  function P:drawPinPrompt(game, cx, cy, cw, m)
    local l = self.launcher
    local prompt = self.pinPrompt
    local s, gap = m.s, m.gap
    local text = ("Room %s is private. Enter its PIN:"):format(tostring(prompt.room))
    cy = Layout.para("small", text, cx, cy, cw, PAL.text) + math.floor(6 * s)
    local goW, noW = Layout.buttonW(s, "Join"), Layout.buttonW(s, "Cancel")
    local fieldW = cw - goW - noW - 2 * gap
    local stacked = fieldW < Kit.tapMin() * 3
    if stacked then fieldW = cw end
    local value, ended = Kit.textfield("online-join-pin", cx, cy, fieldW, m.rowH, prompt.text, "4-digit PIN")
    prompt.text = tostring(value or ""):gsub("%D", ""):sub(1, 4)
    local by = stacked and (cy + m.rowH + gap) or cy
    local bx = stacked and cx or (cx + fieldW + gap)
    if Kit.button(bx, by, goW, m.rowH, "Join", { id = "online-pin-go", font = "small", kind = "primary",
        enabled = game ~= nil and self.pending == nil and #prompt.text == 4 })
        or (ended == "submit" and #prompt.text == 4 and self.pending == nil) then
      local pin = prompt.text
      l:queue(function() self:submitPin(pin) end)
    end
    if Kit.button(bx + goW + gap, by, noW, m.rowH, "Cancel", { id = "online-pin-cancel", font = "small" })
        or ended == "cancel" then
      l:queue(function() self.pinPrompt = nil self:say(nil) end)
    end
    return by + m.rowH + gap
  end

  -- A list row with a title, a detail line and buttons at the right.
  local function listRow(self, cx, cy, cw, m, id, title, detail, buttons)
    local s = m.s
    local entryH = math.max(Kit.tapMin() + math.floor(8 * s), math.floor(52 * s))
    local bw = 0
    for _, b in ipairs(buttons) do bw = bw + Layout.buttonW(s, b.label) + m.gap end
    -- on a narrow window the buttons go under the text
    local under = cw - bw < math.floor(120 * s)
    local rowH = under and (entryH + m.smallH + math.floor(6 * s)) or entryH
    Kit.row(cx, cy, cw, rowH, false, nil)
    local textW = under and (cw - 2 * m.inset) or (cw - bw - m.inset - math.floor(8 * s))
    Kit.text("button", Kit.ellipsize("button", title, textW), cx + m.inset, cy + math.floor(6 * s), PAL.text)
    Kit.text("micro", Kit.ellipsize("micro", detail, textW), cx + m.inset,
      cy + entryH - Kit.textHeight("micro") - math.floor(8 * s), PAL.muted)
    local bx = under and (cx + m.inset) or (cx + cw - bw + m.gap - math.floor(8 * s))
    local by = under and (cy + entryH) or (cy + (entryH - m.smallH) / 2)
    for _, b in ipairs(buttons) do
      local w = Layout.buttonW(s, b.label)
      if Kit.button(bx, by, w, m.smallH, b.label, { id = id .. "-" .. b.key, font = "small",
          kind = b.kind, enabled = b.enabled }) then
        self.launcher:queue(b.run)
      end
      bx = bx + w + m.gap
    end
    return cy + rowH + math.floor(4 * s)
  end

  function P:drawRoomList(rooms, game, cx, cy, cw, m)
    if #rooms == 0 then
      Kit.emptyBox(cx, cy, cw, m.rowH * 2, "No open rooms. Host one, or join with a code.")
      return cy + m.rowH * 2 + m.gap
    end
    for _, entry in ipairs(rooms) do
      local fits = self:compatible(entry, game)
      local parts = { tostring(entry.intent or "room"), gameName(entry.version) }
      local format = P.formatName(entry.profile)
      if format and entry.intent ~= "trade" then parts[#parts + 1] = format end
      if entry.players and entry.seats then
        parts[#parts + 1] = ("%d/%d"):format(entry.players, entry.seats)
      end
      if entry.locked then parts[#parts + 1] = "PIN" end
      if not fits then parts[#parts + 1] = "not your game" end
      local room = entry.room
      cy = listRow(self, cx, cy, cw, m, "online-room-" .. tostring(entry.id),
        tostring(entry.name or "?"), table.concat(parts, "  -  "), {
          { key = "join", label = "Join", enabled = fits and self.pending == nil,
            run = function() self:join(nil, room, { entry = entry }) end },
        })
    end
    return cy + m.gap
  end

  function P:drawWatchList(watch, game, cx, cy, cw, m)
    if #watch == 0 then
      Kit.emptyBox(cx, cy, cw, m.rowH * 2, "No battles to watch right now.")
      return cy + m.rowH * 2 + m.gap
    end
    for _, entry in ipairs(watch) do
      local fits = self:compatible(entry, game)
      local parts = { gameName(entry.version) }
      local format = P.formatName(entry.profile)
      if format then parts[#parts + 1] = format end
      parts[#parts + 1] = ("%d watching"):format(entry.spectators or 0)
      if not fits then parts[#parts + 1] = "not your game" end
      cy = listRow(self, cx, cy, cw, m, "online-watch-" .. tostring(entry.id),
        tostring(entry.name or "?") .. "'s battle", table.concat(parts, "  -  "), {
          { key = "go", label = "Watch", enabled = fits and self.pending == nil,
            run = function() self:watch(entry) end },
        })
    end
    return cy + m.gap
  end

  function P:drawPlayers(players, game, cx, cy, cw, m)
    if #players == 0 then
      Kit.emptyBox(cx, cy, cw, m.rowH * 2, "Nobody else is online right now.")
      return cy + m.rowH * 2 + m.gap
    end
    local out = self.outgoing
    for _, entry in ipairs(players) do
      local detail = P.statusText(entry)
      if entry.version then detail = detail .. "  -  " .. gameName(entry.version) end
      local can = game ~= nil and out == nil
      cy = listRow(self, cx, cy, cw, m, "online-player-" .. tostring(entry.id),
        tostring(entry.name or "?"), detail, {
          { key = "battle", label = "Battle", enabled = can,
            run = function() self:invitePlayer(entry, "battle") end },
          { key = "trade", label = "Trade", enabled = can,
            run = function() self:invitePlayer(entry, "trade") end },
        })
    end
    if out and not out.accepted then
      local l = self.launcher
      local text = ("Waiting for %s..."):format(tostring(out.name or "?"))
      local cancelW = Layout.buttonW(m.s, "Stop waiting")
      Kit.text("small", Kit.ellipsize("small", text, cw - cancelW - m.gap), cx,
        cy + (m.smallH - Kit.textHeight("small")) / 2, PAL.muted)
      if Kit.button(cx + cw - cancelW, cy, cancelW, m.smallH, "Stop waiting",
          { id = "online-invite-forget", font = "small" }) then
        l:queue(function() self.outgoing = nil self:say(nil) end)
      end
      cy = cy + m.smallH + m.gap
    end
    return cy + m.gap
  end
end

return LobbyView
