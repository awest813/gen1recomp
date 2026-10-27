-- The room half of the PK:GB launcher's Online page
-- (src/launcher/OnlinePage.lua): who is in the room (with the host's kick
-- and close controls), the ready / move clock, the team picker over the
-- party and the PC boxes, the rematch prompt, watching, and the trade.
-- Installed as methods on the page.

local Kit = require("src.ui.kit.Kit")
local Theme = require("src.ui.kit.Theme")
local Layout = require("src.launcher.online.Layout")

local PAL = Theme.PAL

local RoomView = {}

local DEADLINE_TEXT = { ready = "Ready up within %s", shot = "Choose a move within %s",
  result = "Result due within %s" }
local DEADLINE_ORDER = { "ready", "shot", "result" }

local TRADE_STAGE = {
  handshake = "Connecting the two games...", seat = "Connecting the two games...",
  waitParty = "Swapping party lists...", picking = "Choose a Pokemon to offer.",
  waitPick = "Waiting for the other trainer to choose...",
  confirming = "Confirm the trade?", waitConfirm = "Waiting for the other trainer to confirm...",
  exchange = "Trading...", commit_wait = "Saving...", committed = "Done.",
}

function RoomView.install(P)
  -- The clock the relay is running for this room, as text, or nil.
  function P:deadlineText(room)
    local d = room and room.deadlines
    if type(d) ~= "table" then return nil end
    local now = self:serverNow()
    for _, kind in ipairs(DEADLINE_ORDER) do
      local left = Layout.countdown(d[kind], now)
      if left then return DEADLINE_TEXT[kind]:format(left) end
    end
    return nil
  end

  function P:drawRoom(room, game, cx, cy, cw, m)
    local l = self.launcher
    local s, gap = m.s, m.gap
    local trade = room.intent == "trade"
    local title = (trade and "Trade room" or "Battle room") .. "  -  code " .. tostring(room.room)
    Kit.textBold("button", Kit.ellipsize("button", title, cw), cx, cy, PAL.heading)
    cy = cy + Kit.textHeight("button") + math.floor(4 * s)
    local facts = {}
    local format = P.formatName(room.profile)
    if format and not trade then facts[#facts + 1] = format end
    if not trade then facts[#facts + 1] = P.ruleText(room.rule) end
    if room.locked then facts[#facts + 1] = "private" end
    if (room.maxSpectators or 0) > 0 then
      facts[#facts + 1] = ("%d/%d watching"):format(#(room.spectators or {}), room.maxSpectators)
    end
    if #facts > 0 then
      cy = Layout.line("micro", table.concat(facts, "  -  "), cx, cy, cw, PAL.muted) + math.floor(6 * s)
    end

    cy = self:drawMembers(room, cx, cy, cw, m)
    local clock = not trade and self:deadlineText(room)
    if clock then
      cy = Layout.line("small", clock, cx, cy, cw, PAL.yellow or PAL.text) + math.floor(4 * s)
    end
    cy = cy + gap

    local host = self:isHost(room)
    cy = Layout.buttons(l, cx, cy, cw, m.smallH, m, {
      { label = "Get invite code", id = "online-invite", run = function() self:invite() end },
      (not trade and (room.maxSpectators or 0) > 0) and {
        label = self.showWatchInvite and "Hide players" or "Invite to watch",
        id = "online-invite-watch", active = self.showWatchInvite,
        run = function() self.showWatchInvite = not self.showWatchInvite end } or false,
      { label = "Leave room", id = "online-leave", kind = "danger", run = function() self:leave() end },
      host and { label = "Close room", id = "online-close", kind = "danger",
        run = function() self:closeRoom() end } or false,
    }) + math.floor(6 * s)
    if self.inviteToken then
      Kit.text("micro", Kit.ellipsize("micro", "Invite code (copied): " .. self.inviteToken, cw),
        cx, cy, PAL.faint)
      cy = cy + Kit.textHeight("micro") + math.floor(4 * s)
    end
    if self.showWatchInvite and not trade then cy = self:drawWatchInvites(cx, cy, cw, m) end
    cy = cy + gap
    if not game then return cy end
    if self:mySeat(room) == nil then
      local text = room.stage == "battling"
        and "You are watching. The battle opens here as it starts."
        or "You are watching. The battle opens here when it starts."
      return Layout.para("small", text, cx, cy, cw, PAL.text) + gap
    end
    if trade then return self:drawTrade(game, cx, cy, cw, m) end
    return self:drawTeam(room, game, cx, cy, cw, m)
  end

  -- Members: "(you)", host, ready, away, the side in a Multi Battle, and
  -- for the host a Kick button on everyone else.
  function P:drawMembers(room, cx, cy, cw, m)
    local l = self.launcher
    local s = m.s
    local host = self:isHost(room)
    local four = (room.seats or 2) > 2
    local kickW = Layout.buttonW(s, "Kick")
    for _, pl in ipairs(room.players or {}) do
      local parts = { tostring(pl.name) }
      if self:isYou(pl.id) then parts[1] = parts[1] .. " (you)" end
      if four then parts[#parts + 1] = ((pl.seat or 0) % 2 == 0) and "Team A" or "Team B" end
      if room.host and pl.id == room.host then parts[#parts + 1] = "host" end
      if pl.ready then parts[#parts + 1] = "ready" end
      if pl.online == false then parts[#parts + 1] = "away" end
      local line = table.concat(parts, "  -  ")
      local canKick = host and not self:isYou(pl.id) and room.stage ~= "battling"
      local lineH = canKick and m.smallH or (Kit.textHeight("small") + math.floor(4 * s))
      local textW = canKick and (cw - kickW - m.gap) or cw
      Kit.text("small", Kit.ellipsize("small", line, textW), cx,
        cy + (lineH - Kit.textHeight("small")) / 2, PAL.text)
      if canKick and Kit.button(cx + cw - kickW, cy, kickW, m.smallH, "Kick",
          { id = "online-kick-" .. tostring(pl.id), font = "small", kind = "danger" }) then
        local who = pl
        l:queue(function() self:kick(who) end)
      end
      cy = cy + lineH + math.floor(2 * s)
    end
    local missing = (room.seats or 2) - #(room.players or {})
    if missing > 0 then
      local text = missing == 1 and "Waiting for another trainer..."
        or ("Waiting for %d more trainers..."):format(missing)
      cy = Layout.line("small", text, cx, cy, cw, PAL.muted)
    end
    return cy
  end

  -- Players online, to invite to watch this room's battle.
  function P:drawWatchInvites(cx, cy, cw, m)
    local l = self.launcher
    local players = self:players()
    if #players == 0 then
      return Layout.line("small", "Nobody else is online right now.", cx, cy, cw, PAL.muted) + m.gap
    end
    local btnW = Layout.buttonW(m.s, "Invite")
    for _, entry in ipairs(players) do
      Kit.text("small", Kit.ellipsize("small", tostring(entry.name) .. "  -  " .. P.statusText(entry),
        cw - btnW - m.gap), cx, cy + (m.smallH - Kit.textHeight("small")) / 2, PAL.text)
      if Kit.button(cx + cw - btnW, cy, btnW, m.smallH, "Invite",
          { id = "online-watch-invite-" .. tostring(entry.id), font = "small",
            enabled = self.outgoing == nil }) then
        l:queue(function() self:invitePlayer(entry, "watch") end)
      end
      cy = cy + m.smallH + math.floor(4 * m.s)
    end
    return cy + m.gap
  end

  -- One pickable Pokemon row.
  local function monRow(self, game, cx, cy, cw, m, ref, mon, id)
    local entryH = math.max(Kit.tapMin(), math.floor(40 * m.s))
    local chosen = self:picked(ref)
    local clicked, ink = Kit.row(cx, cy, cw, entryH, chosen, id)
    Kit.text("button", Kit.ellipsize("button", P.monName(game.version, mon), cw - math.floor(24 * m.s)),
      cx + math.floor(12 * m.s), cy + (entryH - Kit.textHeight("button")) / 2, ink or PAL.text)
    if clicked then self.launcher:queue(function() self:toggle(ref, game) end) end
    return cy + entryH + math.floor(4 * m.s)
  end

  function P:drawTeam(room, game, cx, cy, cw, m)
    local l = self.launcher
    local s, gap = m.s, m.gap
    local source, why = self:source(game)
    local size = self:partySize(game)
    local ended = self.lastResult ~= nil or room.stage == "ended"
    if ended and not self.readied then
      local text = (self.lastResult and (self.lastResult .. " ") or "The battle is over. ")
        .. "Ready up again for a rematch, or leave the room."
      cy = Layout.para("small", text, cx, cy, cw, PAL.heading) + gap
    end
    Kit.caption(cx, cy, ("YOUR TEAM  -  PICK %d"):format(size), PAL.caption)
    cy = cy + Kit.textHeight("caption") + math.floor(6 * s)
    if not source then
      Kit.textWrapped("small", "That save could not be read: " .. tostring(why), cx, cy, cw, PAL.red)
      return cy + Kit.wrapHeight("small", "x " .. tostring(why), cw) + gap
    end
    local rows = self:candidates(game)
    local boxes, boxNames, order = {}, {}, {}
    for _, row in ipairs(rows) do
      if row.box then
        if not boxes[row.box] then
          boxes[row.box] = {}
          order[#order + 1] = row.box
        end
        boxNames[row.box] = row.boxName
        local list = boxes[row.box]
        list[#list + 1] = row
      else
        cy = monRow(self, game, cx, cy, cw, m, row.ref, row.mon, "online-mon-" .. row.ref)
      end
    end
    if #order > 0 then
      table.sort(order)
      local at = math.max(1, math.min(self.box or 1, #order))
      local box = order[at]
      cy = cy + math.floor(6 * s)
      local label = ("%s  (%d/%d)"):format(tostring(boxNames[box] or ("Box " .. box)), at, #order)
      local d
      d, cy = Layout.stepper(cx, cy, cw, m, "PC BOX", label, "online-box", at > 1, at < #order)
      if d ~= 0 then l:queue(function() self.box = at + d end) end
      cy = cy + math.floor(6 * s)
      for _, row in ipairs(boxes[box]) do
        cy = monRow(self, game, cx, cy, cw, m, row.ref, row.mon,
          ("online-box-%d-%d"):format(row.ref.box, row.ref.index))
      end
    end
    cy = cy + gap
    local count = #self:teamList()
    local label
    if self.readied then
      label = "Waiting for the others"
    else
      label = (ended and "Rematch (%d/%d)" or "Ready (%d/%d)"):format(count, size)
    end
    local readyW = math.min(cw, math.max(Layout.buttonW(s, label), math.floor(220 * s)))
    if Kit.button(cx, cy, readyW, m.rowH, label,
        { id = "online-ready", kind = "primary", enabled = not self.readied and count == size }) then
      l:queue(function() self:ready() end)
    end
    if self.readied then
      local backW = Layout.buttonW(s, "Not ready")
      local bx, by = cx + readyW + gap, cy
      if bx + backW > cx + cw then bx, by = cx, cy + m.rowH + gap end
      if Kit.button(bx, by, backW, m.rowH, "Not ready", { id = "online-unready", font = "small" }) then
        l:queue(function() self:unready() end)
      end
      cy = by
    end
    return cy + m.rowH + gap
  end

  function P:drawTrade(game, cx, cy, cw, m)
    local l = self.launcher
    local s, gap = m.s, m.gap
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
        if Kit.button(cx, ry, colW, entryH, Kit.ellipsize("small", P.monName(game.version, mine[i]),
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
        Kit.text("small", Kit.ellipsize("small", P.monName(game.version, theirs[i]), colW - math.floor(24 * s)),
          cx + colW + gap + math.floor(12 * s), ry + (entryH - Kit.textHeight("small")) / 2,
          chosen and PAL.inverse or PAL.text)
      end
    end
    cy = cy + rows * (entryH + math.floor(4 * s)) + gap
    if stage == "confirming" then
      local half = math.floor((cw - gap) / 2)
      if Kit.button(cx, cy, half, m.rowH, "Trade", { id = "trade-yes", kind = "primary" }) then
        l:queue(function() pcall(t.confirm, t, true) end)
      end
      if Kit.button(cx + cw - half, cy, half, m.rowH, "Cancel", { id = "trade-no" }) then
        l:queue(function() pcall(t.confirm, t, false) end)
      end
      cy = cy + m.rowH + gap
    end
    return cy
  end
end

return RoomView
