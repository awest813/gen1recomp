-- Tournaments on the PK:GB launcher's Online page
-- (src/launcher/OnlinePage.lua): the lobby's Tournaments tab (host one,
-- browse the public ones, join or watch by code, with the team to enter)
-- and the tournament itself (players, the creator's Start / Kick / Close,
-- the bracket, the clock, "you play next" and the champion).  Installed as
-- methods on the page.

local Kit = require("src.ui.kit.Kit")
local Theme = require("src.ui.kit.Theme")
local GameVersion = require("src.core.GameVersion")
local Layout = require("src.launcher.online.Layout")

local PAL = Theme.PAL

local TourView = {}

local SPECTATOR_CAPS = {
  { value = 0, label = "No spectators" },
  { value = 8, label = "8 watching" },
  { value = 32, label = "32 watching" },
}
local VISIBILITY = {
  { value = true, label = "Listed publicly" },
  { value = false, label = "Code only" },
}
local STATE_TEXT = { pending = "to play", live = "playing now", done = "done", bye = "bye" }

local function gameName(version)
  local ok, info = pcall(GameVersion.info, version)
  return ok and info and info.displayName or tostring(version or "?")
end

function TourView.install(P)
  -- Public tournaments, from the relay's watchable list.
  function P:openTournaments()
    local fn = require("src.online.Client").watchable
    local ok, list = pcall(fn or function() return {} end)
    local out = {}
    for _, e in ipairs(ok and type(list) == "table" and list or {}) do
      if e.tour then out[#out + 1] = e end
    end
    return out
  end

  function P:drawTourLobby(game, cx, cy, cw, m)
    local l = self.launcher
    local s, gap = m.s, m.gap
    local small = math.floor(6 * s)
    local busy = self.pending ~= nil

    -- the team to enter with
    local count = #self:teamList()
    Kit.caption(cx, cy, ("YOUR TEAM  -  %d PICKED"):format(count), PAL.caption)
    cy = cy + Kit.textHeight("caption") + small
    if game then cy = self:drawPicker(game, cx, cy, cw, m, 6) + gap end

    -- join by code
    local joinW, watchW = Layout.buttonW(s, "Join"), Layout.buttonW(s, "Watch")
    local fieldW = cw - joinW - watchW - 2 * gap
    local stacked = fieldW < Kit.tapMin() * 3
    if stacked then fieldW = cw end
    local ended
    self.tourCode, ended = Kit.textfield("online-tour-code", cx, cy, fieldW, m.rowH, self.tourCode,
      "Tournament code")
    local bx, by = cx + fieldW + gap, cy
    if stacked then bx, by = cx, cy + m.rowH + gap end
    if Kit.button(bx, by, joinW, m.rowH, "Join", { id = "online-tour-join", font = "small",
        enabled = game ~= nil and not busy }) or (ended == "submit" and game ~= nil and not busy) then
      local code = self.tourCode
      l:queue(function() self:joinTournament(code, "player") end)
    end
    if Kit.button(bx + joinW + gap, by, watchW, m.rowH, "Watch", { id = "online-tour-watch",
        font = "small", enabled = game ~= nil and not busy }) then
      local code = self.tourCode
      l:queue(function() self:joinTournament(code, "spectator") end)
    end
    cy = by + m.rowH + gap

    -- host one
    Kit.caption(cx, cy, "HOST A TOURNAMENT", PAL.caption)
    cy = cy + Kit.textHeight("caption") + small
    cy = Layout.line("micro", "Rules: " .. self:optionsSummary(game) .. " (Room options above)",
      cx, cy, cw, PAL.muted) + small
    local o = self.tourOpts
    local clocks = {}
    for _, v in ipairs(P.SHOT_CLOCKS) do
      clocks[#clocks + 1] = { value = v, label = ("Shot clock %d"):format(v) }
    end
    local picked, below = Layout.choices(cx, cy, cw, m, clocks, o.shotClock, "online-tour-clock-")
    if picked then l:queue(function() o.shotClock = picked end) end
    cy = below + small
    picked, below = Layout.choices(cx, cy, cw, m, SPECTATOR_CAPS, o.spectators, "online-tour-spec-")
    if picked then l:queue(function() o.spectators = picked end) end
    cy = below + small
    local vis
    vis, below = Layout.choices(cx, cy, cw, m, VISIBILITY, o.public, "online-tour-public-")
    if vis ~= nil then l:queue(function() o.public = vis end) end
    cy = below + gap
    local size = self:hostRule(game).partySize
    local label = ("Host a tournament (%d/%d)"):format(count, size)
    if Kit.button(cx, cy, math.min(cw, math.max(Layout.buttonW(s, label), math.floor(240 * s))), m.rowH,
        label, { id = "online-tour-host", kind = "primary",
        enabled = game ~= nil and not busy and count == size }) then
      l:queue(function() self:hostTournament() end)
    end
    cy = cy + m.rowH + gap * 2

    -- the public ones
    Kit.caption(cx, cy, "OPEN TOURNAMENTS", PAL.caption)
    cy = cy + Kit.textHeight("caption") + small
    local list = self:openTournaments()
    if #list == 0 then
      Kit.emptyBox(cx, cy, cw, m.rowH * 2, "No public tournaments. Host one, or join with a code.")
      return cy + m.rowH * 2 + gap
    end
    for _, entry in ipairs(list) do
      local fits = self:compatible(entry, game)
      local parts = { gameName(entry.version) }
      if entry.players then parts[#parts + 1] = ("%d players"):format(entry.players) end
      parts[#parts + 1] = entry.stage == "running" and "under way" or "taking players"
      if not fits then parts[#parts + 1] = "not your game" end
      local open = entry.stage ~= "running" and entry.stage ~= "finished"
      local id = entry.tour
      cy = self:listRow(cx, cy, cw, m, "online-tour-" .. tostring(entry.id),
        tostring(entry.name or "?") .. "'s tournament", table.concat(parts, "  -  "), {
          { key = "join", label = "Join", enabled = fits and open and not busy,
            run = function() self:joinTournament(id, "player", entry) end },
          { key = "watch", label = "Watch", enabled = fits and not busy,
            run = function() self:joinTournament(id, "spectator", entry) end },
        })
    end
    return cy + gap
  end

  -- The tournament this trainer is in.
  function P:drawTournament(tour, room, game, cx, cy, cw, m)
    local l = self.launcher
    local s, gap = m.s, m.gap
    local small = math.floor(4 * s)
    local title = "Tournament" .. (tour.code and ("  -  code " .. tour.code) or "")
    Kit.textBold("button", Kit.ellipsize("button", title, cw), cx, cy, PAL.heading)
    cy = cy + Kit.textHeight("button") + small
    local facts = {}
    local format = P.formatName(tour.profile)
    if format then facts[#facts + 1] = format end
    facts[#facts + 1] = P.ruleText(tour.rule)
    if tour.shotClock then facts[#facts + 1] = ("shot clock %d"):format(tour.shotClock) end
    if (tour.maxSpectators or 0) > 0 then
      facts[#facts + 1] = ("%d/%d watching"):format(#(tour.spectators or {}), tour.maxSpectators)
    end
    cy = Layout.line("micro", table.concat(facts, "  -  "), cx, cy, cw, PAL.muted) + small

    local stage
    if tour.stage == "finished" then
      stage = ("Finished. Champion: %s"):format(tostring(tour.championName
        or P.tourName(tour, tour.champion)))
    elseif tour.stage == "running" then
      stage = ("Round %d under way"):format(tonumber(tour.round) or 1)
    else
      stage = ("Taking players (%d so far)"):format(#(tour.players or {}))
    end
    cy = Layout.line("small", stage, cx, cy, cw, PAL.text) + small
    local match, round = self:nextMatch(tour)
    if match then
      local you = self:you()
      local foe = P.tourName(tour, match.a == (you and you.id) and match.b or match.a)
      local text = match.state == "live" and ("Your round %d battle against %s is on.")
        or ("You play next: round %d against %s.")
      cy = Layout.line("small", text:format(tonumber(round) or 1, foe), cx, cy, cw, PAL.green) + small
    end
    local clock = self:deadlineText(tour) or (room and self:deadlineText(room))
    if clock then cy = Layout.line("small", clock, cx, cy, cw, PAL.yellow or PAL.text) + small end
    if room and self:mySeat(room) == nil and tour.stage == "running" then
      cy = Layout.line("small", "A battle is starting; it opens here to watch.", cx, cy, cw, PAL.muted) + small
    end
    cy = cy + gap

    local creator = self:isCreator(tour)
    local registering = tour.stage == "registering"
    cy = Layout.buttons(l, cx, cy, cw, m.smallH, m, {
      (creator and registering) and { label = "Start", id = "online-tour-start", kind = "primary",
        enabled = #(tour.players or {}) >= 2,
        run = function() self:tourCall("startTournament") end } or false,
      { label = "Leave", id = "online-tour-leave", kind = "danger",
        run = function() self:tourCall("leaveTournament") end },
      creator and { label = "Close tournament", id = "online-tour-close", kind = "danger",
        run = function() self:tourCall("closeTournament") end } or false,
    }) + gap

    -- players
    Kit.caption(cx, cy, "PLAYERS", PAL.caption)
    cy = cy + Kit.textHeight("caption") + small
    local kickW = Layout.buttonW(s, "Kick")
    for _, p in ipairs(tour.players or {}) do
      local parts = { tostring(p.name or "?") .. (self:isYou(p.id) and " (you)" or "") }
      if p.id == tour.creator then parts[#parts + 1] = "host" end
      if p.eliminated then parts[#parts + 1] = "out" end
      if p.online == false then parts[#parts + 1] = "away" end
      local canKick = creator and registering and not self:isYou(p.id)
      local lineH = canKick and m.smallH or (Kit.textHeight("small") + small)
      Kit.text("small", Kit.ellipsize("small", table.concat(parts, "  -  "),
        canKick and (cw - kickW - gap) or cw), cx, cy + (lineH - Kit.textHeight("small")) / 2,
        p.eliminated and PAL.muted or PAL.text)
      if canKick and Kit.button(cx + cw - kickW, cy, kickW, m.smallH, "Kick",
          { id = "online-tour-kick-" .. tostring(p.id), font = "small", kind = "danger" }) then
        local id = p.id
        l:queue(function() self:tourCall("kickFromTournament", id) end)
      end
      cy = cy + lineH + small
    end
    cy = cy + gap

    -- the bracket
    if #(tour.bracket or {}) > 0 then
      Kit.caption(cx, cy, "BRACKET", PAL.caption)
      cy = cy + Kit.textHeight("caption") + small
      for _, r in ipairs(tour.bracket) do
        cy = Layout.line("small", ("Round %d"):format(tonumber(r.round) or 0), cx, cy, cw, PAL.heading) + small
        for _, match in ipairs(r.matches or {}) do
          local a, b = P.tourName(tour, match.a), match.b and P.tourName(tour, match.b) or "(bye)"
          local line = a .. "  vs  " .. b
          if match.winner then
            line = line .. "  -  " .. P.tourName(tour, match.winner) .. " won"
          elseif STATE_TEXT[match.state or ""] then
            line = line .. "  -  " .. STATE_TEXT[match.state]
          end
          local mine = self:isYou(match.a) or self:isYou(match.b)
          cy = Layout.line("small", line, cx + m.inset, cy, cw - m.inset, mine and PAL.heading or PAL.text) + small
        end
      end
    end
    return cy + gap
  end
end

return TourView
