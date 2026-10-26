-- The PK:GB launcher's save-sync page: create a sync account or link this
-- device with another's two codes, sync now, settle conflicts, unlink.
-- Everything it does is src/sync/SyncEngine.lua's shared engine, which the
-- games and the pre-launch sync use too; this page only shows it and pumps
-- it while the launcher is up.

local Kit = require("src.ui.kit.Kit")
local Theme = require("src.ui.kit.Theme")
local GameVersion = require("src.core.GameVersion")

local PAL = Theme.PAL

local SyncPage = {}
SyncPage.__index = SyncPage

function SyncPage.new(launcher)
  return setmetatable({ launcher = launcher, code1 = "", code2 = "" }, SyncPage)
end

function SyncPage:engine()
  local ok, SyncEngine = pcall(require, "src.sync.SyncEngine")
  if not ok then return nil end
  local okS, eng = pcall(SyncEngine.shared)
  return okS and eng or nil
end

-- A name for this device on the account's device list.
local function deviceLabel()
  local os_ = love.system and love.system.getOS and love.system.getOS() or "device"
  return "PK:GB on " .. tostring(os_)
end

function SyncPage:create()
  local eng = self:engine()
  if not eng then return self.launcher:say("Sync is not available here.", "error") end
  local ok, why = eng:createAccount(deviceLabel())
  if ok == false then self.launcher:say(why, "error") end
end

function SyncPage:link(code1, code2)
  local eng = self:engine()
  if not eng then return self.launcher:say("Sync is not available here.", "error") end
  local ok, why = eng:linkDevice(code1, code2, deviceLabel())
  if ok == false then self.launcher:say(why, "error") end
end

function SyncPage:syncNow()
  local eng = self:engine()
  if eng then pcall(eng.syncNow, eng) end
end

function SyncPage:unlink()
  local l = self.launcher
  if l.armedDelete ~= "sync:unlink" then
    l.armedDelete = "sync:unlink"
    return l:say("Press Unlink again. Saves stay on this device.", "info")
  end
  l.armedDelete = nil
  local eng = self:engine()
  if eng then pcall(eng.unlink, eng) end
end

function SyncPage:resolve(key, choice)
  local eng = self:engine()
  if not eng then return end
  local ok, why = eng:resolveConflict(key, choice)
  if ok == false then self.launcher:say(why, "error") end
end

-- Pumped every frame by the launcher while an account exists or work runs.
-- A device linked in an earlier run gets its engine on the first pump.
local checkedLink = false

function SyncPage.pump(dt)
  local SyncEngine = package.loaded["src.sync.SyncEngine"]
  local eng = SyncEngine and SyncEngine._shared
  if eng == nil and not checkedLink then
    checkedLink = true
    local ok, linked = pcall(function()
      local SyncState = require("src.sync.SyncState")
      return SyncState.linked(SyncState.load())
    end)
    if ok and linked then
      SyncEngine = require("src.sync.SyncEngine")
      eng = SyncEngine.shared()
    end
  end
  if type(eng) == "table" and (eng:linked() or eng:busy()) then
    pcall(eng.update, eng, dt)
    return eng
  end
end

local function metaLine(meta)
  if type(meta) ~= "table" then return "?" end
  local sum = type(meta.summary) == "table" and meta.summary or meta
  local parts = {}
  if sum.name then parts[#parts + 1] = tostring(sum.name) end
  if sum.timeText then parts[#parts + 1] = tostring(sum.timeText) end
  if sum.badges then parts[#parts + 1] = tostring(sum.badges) .. " badges" end
  if tonumber(meta.savedAt) then parts[#parts + 1] = os.date("%Y-%m-%d %H:%M", tonumber(meta.savedAt)) end
  return #parts > 0 and table.concat(parts, "  -  ") or "?"
end

function SyncPage:draw(x, y, w, h, s)
  local l = self.launcher
  local pad = math.floor(18 * s)
  Kit.card(x, y, w, h)
  local cx, cw = x + pad, w - 2 * pad
  local cy = y + pad
  local rowH = math.max(Kit.tapMin(), math.floor(40 * s))
  local gap = math.floor(10 * s)
  cy = l:pageHeader(cx, cy, cw, s, { title = "Save sync",
    subtitle = "Keep saves in step across your devices.",
    back = function() l.page = "settings" end, backId = "sync-back" })

  local eng = self:engine()
  if not eng then
    Kit.text("small", "Sync is not available on this build.", cx, cy, PAL.red)
    return cy + Kit.textHeight("small") + pad - y
  end
  local status = tostring(eng.status or "")
  Kit.textWrapped("small", status, cx, cy, cw, PAL.text)
  cy = cy + Kit.wrapHeight("small", status, cw) + math.floor(4 * s)
  if eng.error then
    Kit.textWrapped("small", tostring(eng.error), cx, cy, cw, PAL.red)
    cy = cy + Kit.wrapHeight("small", tostring(eng.error), cw) + math.floor(4 * s)
  end
  cy = cy + gap
  local busy = eng:busy()
  local half = math.floor((cw - gap) / 2)

  if eng:linked() then
    local codes = eng.codes
    if codes then
      local line = "Codes to link another device: " .. tostring(codes.code1) .. "  " .. tostring(codes.code2)
      Kit.textWrapped("small", line, cx, cy, cw, PAL.heading)
      cy = cy + Kit.wrapHeight("small", line, cw) + gap
    end
    if Kit.button(cx, cy, half, rowH, busy and "Syncing..." or "Sync now",
        { id = "sync-now", kind = "primary", enabled = not busy }) then
      l:queue(function() self:syncNow() end)
    end
    if Kit.button(cx + cw - half, cy, half, rowH,
        l.armedDelete == "sync:unlink" and "Confirm unlink" or "Unlink",
        { id = "sync-unlink", kind = "danger" }) then
      l:queue(function() self:unlink() end, true)
    end
    cy = cy + rowH + gap * 2
    for i, c in ipairs(eng.conflicts or {}) do
      local title = c.box and "Box collection"
        or ((c.version and GameVersion.info(c.version) and GameVersion.info(c.version).displayName
          or tostring(c.version or "Save")) .. (c.slot and ("  -  " .. tostring(c.slot)) or ""))
      Kit.textBold("button", Kit.ellipsize("button", title, cw), cx, cy, PAL.heading)
      cy = cy + Kit.textHeight("button") + math.floor(4 * s)
      if not c.box then
        Kit.text("micro", Kit.ellipsize("micro", "This device: " .. metaLine(c.localMeta), cw), cx, cy, PAL.text)
        cy = cy + Kit.textHeight("micro") + math.floor(2 * s)
        Kit.text("micro", Kit.ellipsize("micro", "Other device: " .. metaLine(c.remoteMeta), cw), cx, cy, PAL.text)
        cy = cy + Kit.textHeight("micro") + math.floor(6 * s)
      end
      local third = math.floor((cw - 2 * gap) / 3)
      local key = c.key
      if Kit.button(cx, cy, third, rowH, "Keep this one", { id = "sync-local-" .. i, font = "small" }) then
        l:queue(function() self:resolve(key, "local") end)
      end
      if Kit.button(cx + third + gap, cy, third, rowH, "Take the other", { id = "sync-remote-" .. i, font = "small" }) then
        l:queue(function() self:resolve(key, "remote") end)
      end
      if not c.box and Kit.button(cx + 2 * (third + gap), cy, third, rowH, "Keep both",
          { id = "sync-both-" .. i, font = "small" }) then
        l:queue(function() self:resolve(key, "both") end)
      end
      cy = cy + rowH + gap * 2
    end
    return cy - y + pad
  end

  if Kit.button(cx, cy, math.min(cw, math.floor(300 * s)), rowH, "Create a sync account",
      { id = "sync-create", kind = "primary", enabled = not busy }) then
    l:queue(function() self:create() end)
  end
  cy = cy + rowH + gap * 2
  Kit.caption(cx, cy, "OR LINK WITH ANOTHER DEVICE'S CODES", PAL.caption)
  cy = cy + Kit.textHeight("caption") + math.floor(6 * s)
  local linkW = math.max(Kit.tapMin(), Kit.textWidth("small", "Link") + math.floor(32 * s))
  local fieldW = math.floor((cw - linkW - 2 * gap) / 2)
  self.code1 = Kit.textfield("sync-code1", cx, cy, fieldW, rowH, self.code1, "First code")
  self.code2 = Kit.textfield("sync-code2", cx + fieldW + gap, cy, fieldW, rowH, self.code2, "Second code")
  if Kit.button(cx + cw - linkW, cy, linkW, rowH, "Link", { id = "sync-link", font = "small",
      enabled = not busy }) then
    local a, b = self.code1, self.code2
    l:queue(function() self:link(a, b) end)
  end
  cy = cy + rowH + gap
  return cy - y + pad
end

return SyncPage
