-- The PK:GB launcher's mod pages: the installed list, one mod's details and
-- options, tools (safe mode, all on/off, load order, profiles), the asset
-- importers, and the "Get mods" catalog built from the mod indexes the
-- player added.
--
-- Written from scratch for this project over the shared GPL mod modules:
-- src/mods/ModLibrary.lua (install, enable, options), ModUpdate.lua (GitHub
-- releases), ModIndex.lua (index feeds), LoadOrder.lua, ModProfile.lua,
-- RequiredImports.lua and src/core/SaveData.lua.  Network work is pumped one
-- frame at a time from update(); nothing here blocks a frame.
--
-- The page object holds the launcher (`launcher`) and draws into the rect
-- the launcher gives it.  Clicks queue closures with launcher:queue, which
-- the launcher runs from its own update().

local Kit = require("src.ui.kit.Kit")
local Theme = require("src.ui.kit.Theme")
local GameVersion = require("src.core.GameVersion")

local PAL = Theme.PAL

local ModsPage = {}
ModsPage.__index = ModsPage

-- Every launcher page this module draws, and where Back / Escape leads.
ModsPage.PAGES = { mods = true, importers = true, mod = true, modoptions = true,
  modtools = true, loadorder = true, profiles = true, catalog = true,
  catalogitem = true, feeds = true, examples = true, example = true }
-- Pages with more than one way in go Back the way they were entered
-- (Launcher:back); PARENT is their answer when that is not known.
ModsPage.RETURNS = { examples = true, importers = true }
ModsPage.PARENT = { importers = "mods", mod = "mods", modoptions = "mod",
  modtools = "mods", loadorder = "modtools", profiles = "modtools",
  catalog = "mods", catalogitem = "catalog", feeds = "catalog", examples = "mods",
  example = "examples" }

local MOD_KIND = { label = "Mod package", exts = { "zip" } }
local PROFILE_NAME_MAX = 24

function ModsPage.new(launcher)
  return setmetatable({
    launcher = launcher,
    checks = {},      -- mod id -> { h, row } release checks in flight
    releases = {},    -- mod id -> { status, best, err }
    queue = {},       -- download + install jobs waiting
    current = nil,    -- the job running now
    query = "",
    allGames = false,
    feedDraft = "",
    profileDraft = "",
    scroll = {},
  }, ModsPage)
end

-- ------------------------------------------------------------------ helpers

local function saveData()
  local ok, SaveData = pcall(require, "src.core.SaveData")
  return ok and SaveData or nil
end

-- Can the launcher reach the network at all?  The browser fetches through
-- the page even though Platform reports no native transport there.
function ModsPage.canFetch()
  local ok, Platform = pcall(require, "src.core.Platform")
  if not ok then return false end
  local okF, can = pcall(Platform.canFetchRemote)
  if okF and can then return true end
  local okW, web = pcall(Platform.isWeb)
  return okW and web == true
end

-- At most `max` characters, never half of one: a byte cut through an
-- accented letter leaves text the kit measures as empty.
local function clip(text, max)
  text = tostring(text or "")
  local out, n = {}, 0
  for ch in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    n = n + 1
    if n > max then break end
    out[n] = ch
  end
  return table.concat(out)
end
ModsPage.clip = clip

local function trim(text)
  return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function hex(bytes)
  return (tostring(bytes):gsub(".", function(c) return ("%02x"):format(c:byte()) end))
end

local function sha256(bytes)
  if not (love and love.data and love.data.hash) then return nil end
  local ok, digest = pcall(love.data.hash, "sha256", bytes)
  if not ok or type(digest) ~= "string" then return nil end
  return #digest == 64 and digest:lower() or hex(digest)
end

local function btnH(s) return math.max(Kit.tapMin(), math.floor(34 * s)) end

-- A row of buttons that wraps onto more lines when the width runs out.
-- Items: { label, id, kind, enabled, run, keepArmed }.  Returns the y below.
function ModsPage:flow(cx, cy, cw, s, items)
  local l = self.launcher
  local h = btnH(s)
  local gap = Theme.space("s", s)
  local x = cx
  for _, it in ipairs(items) do
    local bw = math.min(cw, math.max(Kit.tapMin(),
      Kit.textWidth("small", it.label) + math.floor(28 * s)))
    if x > cx and x + bw > cx + cw then
      x = cx
      cy = cy + h + gap
    end
    if Kit.button(x, cy, bw, h, it.label, { id = it.id, font = "small", kind = it.kind,
        enabled = it.enabled }) then
      l:queue(it.run, it.keepArmed)
    end
    x = x + bw + gap
  end
  return cy + h + gap
end

-- The height flow() will use for the same items.
function ModsPage.flowHeight(cw, s, items)
  local h, gap = btnH(s), Theme.space("s", s)
  local x, lines = 0, 1
  for _, it in ipairs(items) do
    local bw = math.min(cw, math.max(Kit.tapMin(),
      Kit.textWidth("small", it.label) + math.floor(28 * s)))
    if x > 0 and x + bw > cw then
      x = 0
      lines = lines + 1
    end
    x = x + bw + gap
  end
  return lines * (h + gap)
end

-- A list row's title over one detail line.
local function twoLines(title, detail, x, y, h, w, titleInk, detailInk, s)
  local th, dh = Kit.textHeight("button"), Kit.textHeight("micro")
  local top = y + (h - th - dh - Theme.space("xxs", s)) / 2
  Kit.text("button", Kit.ellipsize("button", tostring(title), w), x, top, titleInk)
  Kit.text("micro", Kit.ellipsize("micro", tostring(detail or ""), w), x,
    top + th + Theme.space("xxs", s), detailInk)
end

-- Wrapped paragraph; returns the y below it.
local function para(font, text, x, y, w, ink, gap)
  text = tostring(text or "")
  if text == "" then return y end
  Kit.textWrapped(font, text, x, y, w, ink)
  return y + Kit.wrapHeight(font, text, w) + (gap or 0)
end

local function gameName(version)
  local info = version and GameVersion.info(version)
  return info and info.displayName or tostring(version or "this game")
end

-- "Red, Blue, Yellow, Gold and Silver": the games a manifest claims, in the
-- engine's own order, without the series name on each
function ModsPage.runsOn(manifest)
  local okT, ModTargets = pcall(require, "src.mods.ModTargets")
  if not okT then return nil end
  local okV, versions = pcall(ModTargets.versions, manifest)
  if not okV or type(versions) ~= "table" or #versions == 0 then return nil end
  local names = {}
  for _, v in ipairs(versions) do
    names[#names + 1] = (gameName(v):gsub("^Pok%S*mon ", ""))
  end
  if #names == 1 then return names[1] end
  return table.concat(names, ", ", 1, #names - 1) .. " and " .. names[#names]
end

-- -------------------------------------------------------------------- model

-- Installed mods as ModLibrary lists them for one game, cached until
-- something changes them (the launcher clears modRows).
function ModsPage:modsFor(version)
  local l = self.launcher
  l.modRows = l.modRows or {}
  local rows = l.modRows[version]
  if rows then return rows end
  local ok, ModLibrary = pcall(require, "src.mods.ModLibrary")
  local okL, got = false, nil
  if ok then okL, got = pcall(ModLibrary.list, version) end
  rows = (okL and type(got) == "table") and got or {}
  -- what can run on this game first, each half still by name: on Gold the
  -- Gen 1-only mods would otherwise sit between the ones a player can use
  local order = {}
  for i, row in ipairs(rows) do order[row] = i end
  table.sort(rows, function(a, b)
    local ua = not a.broken and a.supported ~= false
    local ub = not b.broken and b.supported ~= false
    if ua ~= ub then return ua end
    return order[a] < order[b]
  end)
  l.modRows[version] = rows
  return rows
end

function ModsPage:changed()
  local l = self.launcher
  l.modRows, l.cartPlans = nil, nil
  self.importerStates, self.schemas, self.seenSchemas = nil, nil, nil
  self.exampleRows = nil
end

-- An asset importer's state (missing / partial / ready) reads its packs'
-- manifests from disk: kept until something changes them, not per frame.
function ModsPage:importerState(id)
  self.importerStates = self.importerStates or {}
  local st = self.importerStates[id]
  if st == nil then
    local okS, state = pcall(require("src.import.Importers").state, id)
    st = okS and state or "missing"
    self.importerStates[id] = st
  end
  return st
end

function ModsPage:rowByFolder(version, folder)
  for _, row in ipairs(self:modsFor(version)) do
    if row.folder == folder then return row end
  end
  return nil
end

function ModsPage:toggleMod(version, row)
  local l = self.launcher
  if not (row and row.id) or row.broken then return end
  local ModLibrary = require("src.mods.ModLibrary")
  local ok, err = pcall(ModLibrary.setEnabled, row.id, not row.enabled, version)
  if not ok then return l:say("Could not change that mod: " .. tostring(err), "error") end
  self:changed()
  l:say(("%s is %s for %s. It applies the next time the game starts."):format(
    row.name, row.enabled and "off" or "on", gameName(version)), "info")
end

function ModsPage:removeMod(row)
  local l = self.launcher
  local key = "mod:" .. tostring(row and row.folder)
  if l.armedDelete ~= key then
    l.armedDelete = key
    return l:say("Press Remove again to uninstall " .. tostring(row.name) .. ".", "info")
  end
  l.armedDelete = nil
  local ModLibrary = require("src.mods.ModLibrary")
  local ok, done, err = pcall(ModLibrary.uninstall, row.folder)
  self:changed()
  if not (ok and done) then
    return l:say("Could not remove " .. tostring(row.name) .. ": "
      .. tostring(ok and err or done), "error")
  end
  self.releases[row.id or ""] = nil
  if l.page == "mod" or l.page == "modoptions" then l.page = "mods" end
  l:say(tostring(row.name) .. " was removed.", "info")
end

function ModsPage:installMod(data, name)
  local l = self.launcher
  local ModLibrary = require("src.mods.ModLibrary")
  local ok, manifest, err, info = pcall(ModLibrary.installZip, data, name, { upgrade = true })
  if not ok then manifest, err, info = nil, manifest, nil end
  self:changed()
  if not manifest then
    -- the same or an older version: not a failure, and the fix is a choice
    if type(info) == "table" and info.exists and info.manifest then
      return l:say(("%s %s is already installed with the same or a newer version. "
        .. "Remove it first to install this copy instead."):format(
          tostring(info.manifest.name or info.manifest.id),
          tostring(info.manifest.version or "")), "info")
    end
    return l:say("Could not install " .. tostring(name or "that mod") .. ": "
      .. tostring(err), "error")
  end
  local missing = ModLibrary.missingDependencies(manifest, ModLibrary.list())
  local text = ("Installed %s."):format(manifest.name or manifest.id)
  if manifest.experimental then
    -- experimental mods start off everywhere (ModLibrary.list, Loader)
    text = text .. " It is experimental, so it starts off: turn it on for each game you want it in."
  end
  if #missing > 0 then
    text = text .. " It also needs: " .. table.concat(missing, ", ") .. "."
  end
  l:say(text, #missing > 0 and "error" or "info")
  return true
end

function ModsPage:pickMod()
  local l = self.launcher
  if l:requestHostPick("mod") then return end
  l:pickPath("Choose a mod .zip", MOD_KIND, "mod", function(path)
    local FilePicker = require("src.core.FilePicker")
    local data, err = FilePicker.read(path)
    if not data then return l:say("Could not read that file: " .. tostring(err), "error") end
    self:installMod(data, FilePicker.basename(path))
  end, "Drop a mod .zip onto this window to install it.")
end

-- What a mod still needs before it can load: a file the player supplies
-- (RequiredImports) or an asset pack an importer builds (Importers).
-- Returns { file, pack, text } or nil; worked out once per mod list.
function ModsPage:modNeeds(row)
  if type(row) ~= "table" then return nil end
  if row.needChecked then return row.need end
  row.needChecked = true
  row.need = self:findModNeeds(row)
  return row.need
end

function ModsPage:findModNeeds(row)
  local manifest = row.manifest
  if type(manifest) ~= "table" then return nil end
  local need = {}
  local okR, RequiredImports = pcall(require, "src.mods.RequiredImports")
  if okR and #(RequiredImports.specs(manifest)) > 0 then
    local okI, rows = pcall(RequiredImports.inspect, manifest)
    for _, r in ipairs(okI and rows or {}) do
      if not r.present and r.required and not need.file then
        need.file, need.text = r.spec, "Needs " .. tostring(r.name)
          .. (r.error and (" (" .. tostring(r.error) .. ")") or "")
      end
    end
  end
  if not need.file and #(manifest.required_assets or {}) > 0 then
    local Importers = require("src.import.Importers")
    for _, spec in ipairs(manifest.required_assets) do
      if not Importers.resolve(spec) then
        local desc = Importers.get(spec.importer)
        need.pack = spec
        need.text = "Needs the " .. tostring(desc and desc.name or spec.importer)
          .. " asset import"
        break
      end
    end
  end
  return need.text and need or nil
end

-- Pick the file a mod asked for and keep it for that mod.
function ModsPage:addModFile(row, spec)
  local l = self.launcher
  l.pendingModFile = { manifest = row.manifest, spec = spec, name = row.name }
  if l:requestHostPick("required_import", "modfile") then return end
  local started = l:pickPath("Choose " .. tostring(spec.name), { label = spec.name, exts = {} }, "all",
    function(path) self:storeModFile(require("src.core.FilePicker").read(path)) end)
  if not started then
    l.pendingModFile = nil
    l:say("This platform has no file picker for mod files.", "error")
  end
end

function ModsPage:storeModFile(data, err)
  local l = self.launcher
  local want = l.pendingModFile
  l.pendingModFile = nil
  if not want then return end
  if not data then return l:say("Could not read that file: " .. tostring(err), "error") end
  local RequiredImports = require("src.mods.RequiredImports")
  local ok, why = RequiredImports.importData(want.manifest, want.spec.id, data)
  l.modRows = nil
  if not ok then
    return l:say(tostring(want.spec.name) .. " was not accepted: " .. tostring(why), "error")
  end
  l:say(("%s now has %s."):format(tostring(want.name), tostring(want.spec.name)), "info")
end

-- Forget the file a mod was given (it asks for it again next time).
function ModsPage:removeModFile(row, fileRow)
  local l = self.launcher
  local key = "modfile:" .. tostring(row.folder) .. ":" .. tostring(fileRow.id)
  if l.armedDelete ~= key then
    l.armedDelete = key
    return l:say("Press Remove file again to delete the stored "
      .. tostring(fileRow.name) .. ".", "info")
  end
  l.armedDelete = nil
  local RequiredImports = require("src.mods.RequiredImports")
  local ok, done, err = pcall(RequiredImports.remove, row.manifest, fileRow.id)
  l.modRows = nil
  if not (ok and done) then
    return l:say("Could not remove " .. tostring(fileRow.name) .. ": "
      .. tostring(ok and err or done), "error")
  end
  l:say(tostring(fileRow.name) .. " was removed from " .. tostring(row.name) .. ".", "info")
end

-- A file from the imports folder: offer it to every installed mod still
-- missing one; RequiredImports checks it against each.
function ModsPage:storeInboxModFile(data)
  local l = self.launcher
  if not data then return false end
  local RequiredImports = require("src.mods.RequiredImports")
  for _, row in ipairs(require("src.mods.ModLibrary").list()) do
    local manifest = row.manifest
    if manifest and #(RequiredImports.specs(manifest)) > 0 then
      local okI, rows = pcall(RequiredImports.inspect, manifest)
      for _, r in ipairs(okI and rows or {}) do
        if not r.present and RequiredImports.importData(manifest, r.id, data) then
          l.modRows = nil
          l:say(("%s now has %s."):format(tostring(row.name), tostring(r.name)), "info")
          return true
        end
      end
    end
  end
  l:say("No installed mod is waiting for that file.", "error")
  return false
end

-- ------------------------------------------------------- asset importers

function ModsPage:runImporter(id)
  local l = self.launcher
  if l.assetJob then return l:say("An import is already running.", "error") end
  l.pendingImporter = id
  if l:requestHostPick("required_import", "importer") then return end
  local desc = require("src.import.Importers").get(id)
  local started = l:pickPath("Choose " .. tostring(desc and desc.source and desc.source.name or id),
    { label = desc and desc.name or id, exts = desc and desc.source and desc.source.formats or {} }, "all",
    function(path) self:startImporter(require("src.core.FilePicker").read(path)) end)
  if not started then
    l.pendingImporter = nil
    l:say("This platform has no file picker for importer sources.", "error")
  end
end

function ModsPage:startImporter(data, err)
  local l = self.launcher
  local id = l.pendingImporter
  l.pendingImporter = nil
  if not id then return end
  if not data then return l:say("Could not read that file: " .. tostring(err), "error") end
  local desc = require("src.import.Importers").get(id)
  local okM, module = pcall(require, desc and desc.module or "")
  if not okM or type(module) ~= "table" or type(module.job) ~= "function" then
    return l:say("That importer is not available in this build.", "error")
  end
  local okJ, co = pcall(module.job, data)
  if not okJ or type(co) ~= "thread" then return l:say(tostring(co), "error") end
  l.assetJob = { id = id, name = desc.name, co = co, done = 0, total = 1,
    status = "Starting" }
end

function ModsPage:stepImporter(budget)
  local l = self.launcher
  local job = l.assetJob
  if not job then return end
  local clock = love.timer and love.timer.getTime
  local deadline = clock and (clock() + (budget or 0.008))
  repeat
    local ok, info = coroutine.resume(job.co)
    if not ok then
      l.assetJob, self.importerStates = nil, nil
      return l:say(tostring(job.name) .. " import failed: " .. tostring(info), "error")
    end
    if coroutine.status(job.co) == "dead" then
      l.assetJob, l.modRows, self.importerStates = nil, nil, nil
      return l:say(tostring(job.name) .. " assets imported.", "info")
    end
    if type(info) == "table" then
      job.done, job.total = tonumber(info.done) or job.done, tonumber(info.total) or job.total
      job.status = info.status or job.status
    end
  until not deadline or clock() >= deadline
end

-- ------------------------------------------------------- safe mode, all on

function ModsPage:safeMode()
  local opts = self.launcher:peekOptions()
  local SaveData = saveData()
  if SaveData and SaveData.isSafeMode then return SaveData.isSafeMode(opts) end
  return type(opts) == "table" and opts.safeMode == true
end

function ModsPage:setSafeMode(on)
  local l = self.launcher
  local SaveData = saveData()
  local opts = l:options()
  if SaveData and SaveData.setSafeMode then SaveData.setSafeMode(opts, on)
  else opts.safeMode = on == true end
  if SaveData then pcall(SaveData.saveOptions, opts) end
  self:changed()
  l:say(on and "Safe mode is on: the game starts with every mod off."
    or "Safe mode is off: your mods load again.", "info")
end

-- Turn every mod that can run on this game on, or off, in one write.
function ModsPage:setAll(version, on)
  local l = self.launcher
  local SaveData = require("src.core.SaveData")
  local opts = SaveData.loadOptions()
  local scope = SaveData.modScope(version)
  local n = 0
  for _, row in ipairs(self:modsFor(version)) do
    if row.id and not row.broken and row.supported then
      SaveData.setModEnabled(opts, row.id, on, scope)
      n = n + 1
    end
  end
  SaveData.saveOptions(opts)
  self:changed()
  if n == 0 then return l:say("No installed mod runs on " .. gameName(version) .. ".", "info") end
  l:say(("Turned %d %s %s for %s."):format(n, n == 1 and "mod" or "mods",
    on and "on" or "off", gameName(version)), "info")
end

-- ------------------------------------------------------------- load order

function ModsPage:orderList(version)
  local entries, byId = {}, {}
  for _, row in ipairs(self:modsFor(version)) do
    if row.id and not row.broken then
      entries[#entries + 1] = { id = row.id, manifest = row.manifest }
      byId[row.id] = row
    end
  end
  local opts = self.launcher:options()
  return require("src.mods.LoadOrder").materialize(opts.modOrder, entries), byId
end

function ModsPage:moveOrder(version, id, delta)
  local list = self:orderList(version)
  local moved, changed = require("src.mods.LoadOrder").move(list, id, delta)
  if not changed then return false end
  local SaveData = require("src.core.SaveData")
  local opts = self.launcher:options()
  SaveData.setModOrder(opts, moved)
  SaveData.saveOptions(opts)
  self:changed()
  return true
end

function ModsPage:resetOrder()
  local SaveData = require("src.core.SaveData")
  local opts = self.launcher:options()
  SaveData.setModOrder(opts, {})
  SaveData.saveOptions(opts)
  self:changed()
  self.launcher:say("Load order is back to each mod's own priority.", "info")
end

-- --------------------------------------------------------------- profiles

function ModsPage:profiles()
  local opts = self.launcher:options()
  return type(opts.modProfiles) == "table" and opts.modProfiles or {}
end

local function findProfile(list, name)
  for i, p in ipairs(list) do
    if type(p) == "table" and p.name == name then return p, i end
  end
  return nil
end

function ModsPage:saveProfile(version, name)
  local l = self.launcher
  name = trim(name)
  if name == "" then return l:say("Give the profile a name first.", "error") end
  name = clip(name, PROFILE_NAME_MAX)
  local SaveData = require("src.core.SaveData")
  local ModProfile = require("src.mods.ModProfile")
  local opts = l:options()
  local available = {}
  for _, row in ipairs(self:modsFor(version)) do
    if row.id and not row.broken then
      available[#available + 1] = { id = row.id, enabled = row.enabled and true or false }
    end
  end
  local snap = ModProfile.capture(available, opts.modOptions, opts.modsByVersion, opts.modOrder)
  snap.name = name
  opts.modProfiles = type(opts.modProfiles) == "table" and opts.modProfiles or {}
  local _, at = findProfile(opts.modProfiles, name)
  if at then opts.modProfiles[at] = snap
  else opts.modProfiles[#opts.modProfiles + 1] = snap end
  opts.activeProfile = name
  SaveData.saveOptions(opts)
  self.profileDraft = ""
  l:say(("Saved this setup as %s."):format(name), "info")
  return true
end

function ModsPage:applyProfile(version, name)
  local l = self.launcher
  if self:safeMode() then
    return l:say("Turn safe mode off before applying a profile.", "error")
  end
  local SaveData = require("src.core.SaveData")
  local ModProfile = require("src.mods.ModProfile")
  local opts = l:options()
  local p = findProfile(type(opts.modProfiles) == "table" and opts.modProfiles or {}, name)
  if not p then return l:say("That profile is gone.", "error") end
  local scope = SaveData.modScope(version)
  local byId = {}
  for _, row in ipairs(self:modsFor(version)) do
    if row.id and not row.broken then
      byId[row.id] = true
      local want = type(p.enabled) ~= "table" or p.enabled[row.id] ~= false
      SaveData.setModEnabled(opts, row.id, want, scope)
    end
  end
  ModProfile.restoreVersions(p, opts)
  opts.modOptions = type(opts.modOptions) == "table" and opts.modOptions or {}
  for modId, bucket in pairs(type(p.options) == "table" and p.options or {}) do
    if byId[modId] and type(bucket) == "table" then
      local copy = {}
      for k, v in pairs(bucket) do copy[k] = v end
      opts.modOptions[modId] = copy
    end
  end
  ModProfile.restoreOrder(p, opts)
  opts.activeProfile = p.name
  SaveData.saveOptions(opts)
  for _, move in ipairs(ModProfile.slotMoves(p)) do
    pcall(SaveData.setActiveSlot, move[1], move[2])
  end
  l.slots = {}
  self:changed()
  local missing = ModProfile.missingIds(p, byId)
  if #missing > 0 then
    return l:say(("Applied %s. Not installed here: %s."):format(p.name,
      table.concat(missing, ", ")), "error")
  end
  l:say(("Applied %s. It takes effect the next time the game starts."):format(p.name), "info")
end

function ModsPage:renameProfile(old, new)
  local l = self.launcher
  new = trim(new)
  self.renamingProfile = nil
  if new == "" or new == old then return end
  new = clip(new, PROFILE_NAME_MAX)
  local opts = l:options()
  local list = type(opts.modProfiles) == "table" and opts.modProfiles or {}
  if findProfile(list, new) then return l:say("A profile named " .. new .. " already exists.", "error") end
  local p = findProfile(list, old)
  if not p then return end
  p.name = new
  if opts.activeProfile == old then opts.activeProfile = new end
  require("src.core.SaveData").saveOptions(opts)
  l:say(("Renamed %s to %s."):format(old, new), "info")
end

function ModsPage:deleteProfile(name)
  local l = self.launcher
  local key = "profile:" .. tostring(name)
  if l.armedDelete ~= key then
    l.armedDelete = key
    return l:say("Press Delete again to remove the profile " .. tostring(name) .. ".", "info")
  end
  l.armedDelete = nil
  local opts = l:options()
  local list = type(opts.modProfiles) == "table" and opts.modProfiles or {}
  local _, at = findProfile(list, name)
  if not at then return end
  table.remove(list, at)
  if opts.activeProfile == name then opts.activeProfile = nil end
  require("src.core.SaveData").saveOptions(opts)
  l:say("Deleted the profile " .. tostring(name) .. ".", "info")
end

-- ------------------------------------------------------------ mod options

-- A mod's options_schema file, run in the mod sandbox like the loader does.
-- Cached per folder; false means the mod has none the launcher can read.
function ModsPage:schemaFor(row)
  self.schemas = self.schemas or {}
  local key = tostring(row and row.folder)
  if self.schemas[key] ~= nil then return self.schemas[key] or nil end
  local schema = false
  local m = row and row.manifest
  if type(m) == "table" and type(m.options_schema) == "string" and love and love.filesystem then
    local ok, rows = pcall(function()
      local SafePath = require("src.mods.SafePath")
      local Sandbox = require("src.mods.Sandbox")
      local path = SafePath.join(row.folder, m.options_schema, "options_schema")
      local chunk, err = Sandbox.loadFile(love.filesystem, path, Sandbox.envFor({ modId = row.id }))
      if not chunk then error(err, 0) end
      return chunk()
    end)
    if ok and type(rows) == "table" then schema = rows end
  end
  -- a mod that declares its options in code (mod.options:define) has no
  -- file to read: what the game reported after a boot is the answer
  if not schema and row and row.id then
    if self.seenSchemas == nil then
      local okC, got = pcall(require("src.mods.OptionSchemaCache").load)
      self.seenSchemas = okC and type(got) == "table" and got or {}
    end
    schema = self.seenSchemas[row.id] or false
  end
  self.schemas[key] = schema
  return schema or nil
end

local OPTION_TYPES = { toggle = true, choice = true, number = true, text = true }

function ModsPage:optionValues(id)
  local ok, all = pcall(require("src.mods.ModLibrary").modOptions)
  local bucket = ok and type(all) == "table" and all[id] or nil
  return type(bucket) == "table" and bucket or {}
end

function ModsPage:optionValue(id, row)
  -- what the mod will read (src/mods/OptionValue.lua), not raw storage
  return require("src.mods.OptionValue").coerce(row, self:optionValues(id)[row.key])
end

function ModsPage:setOption(id, key, value)
  local values = {}
  for k, v in pairs(self:optionValues(id)) do values[k] = v end
  values[key] = value
  local ok, err = pcall(require("src.mods.ModLibrary").setModOptions, id, values)
  if not ok then self.launcher:say("Could not save that option: " .. tostring(err), "error") end
end

function ModsPage:resetOptions(row)
  local schema = self:schemaFor(row) or {}
  local values = {}
  for _, opt in ipairs(schema) do
    if type(opt) == "table" and type(opt.key) == "string" and opt.default ~= nil then
      values[opt.key] = opt.default
    end
  end
  local ok, saved, err = pcall(require("src.mods.ModLibrary").setModOptions, row.id, values)
  if not ok or not saved then
    return self.launcher:say("Could not reset " .. tostring(row.name) .. "'s options: "
      .. tostring(ok and err or saved), "error")
  end
  self.launcher:say(tostring(row.name) .. "'s options are back to their defaults.", "info")
end

function ModsPage:optionVisible(id, opt, byKey)
  local cond = opt.visible_if
  if cond == nil then return true end
  if type(cond) ~= "table" or type(cond.key) ~= "string" then return false end
  local value = self:optionValue(id, byKey[cond.key] or { key = cond.key })
  if cond.equals ~= nil then return value == cond.equals end
  if cond.not_equals ~= nil then return value ~= cond.not_equals end
  return false
end

-- ------------------------------------------------------------ mod updates

-- A mod the updater can look after: installed by the player (not shipped in
-- the game folder), intact, and naming the GitHub repo it is released from.
local function updatable(row)
  return type(row) == "table" and not row.broken and not row.bundled
    and type(row.manifest) == "table" and type(row.manifest.github) == "string"
    and row.manifest.github ~= ""
end
ModsPage.updatable = updatable

-- Read from the launcher's cached list: every installed mod is listed for
-- any game, so the selected game's rows cover them all.
function ModsPage:updatableRows()
  local out = {}
  for _, row in ipairs(self:modsFor(self.launcher.selected or false)) do
    if updatable(row) then out[#out + 1] = row end
  end
  return out
end

function ModsPage:checkRow(row, force)
  if not updatable(row) or self.checks[row.id] then return false end
  local ModUpdate = require("src.mods.ModUpdate")
  self.checks[row.id] = { row = row,
    h = ModUpdate.beginFetchReleases(row.manifest.github, row.id, { force = force }) }
  return true
end

function ModsPage:checkUpdates(force)
  local l = self.launcher
  if not ModsPage.canFetch() then
    return l:say("This device cannot check for mod updates from the launcher.", "error")
  end
  local n = 0
  for _, row in ipairs(self:updatableRows()) do
    if self:checkRow(row, force) then n = n + 1 end
  end
  if n == 0 and next(self.checks) == nil then
    return l:say("None of your mods name a GitHub repo to update from.", "info")
  end
  self.reportChecks = true
end

function ModsPage:checking() return next(self.checks) ~= nil end

function ModsPage:pumpChecks()
  local ModUpdate = require("src.mods.ModUpdate")
  for id, c in pairs(self.checks) do
    local ok, done, releases, err = pcall(ModUpdate.pumpFetchReleases, c.h)
    if not ok then done, releases, err = true, nil, tostring(done) end
    if done then
      self.checks[id] = nil
      if releases then
        local status, best = ModUpdate.statusFor(c.row.version, releases)
        self.releases[id] = { status = status, best = best }
      else
        self.releases[id] = { status = "error", err = err }
      end
    end
  end
  if self.reportChecks and not self:checking() then
    self.reportChecks = nil
    local n = self:availableCount()
    self.launcher:say(n > 0 and (("%d %s an update."):format(n, n == 1 and "mod has" or "mods have"))
      or "Your mods are up to date.", "info")
  end
end

function ModsPage:availableCount()
  local n = 0
  for _, row in ipairs(self:updatableRows()) do
    local r = self.releases[row.id]
    if r and r.status == "available" then n = n + 1 end
  end
  return n
end

-- One line about a mod's update state, or nil when there is nothing to say.
function ModsPage:updateLine(row)
  if not updatable(row) then return nil end
  if self.checks[row.id] then return "Checking for updates", PAL.muted end
  local r = self.releases[row.id]
  if not r then return nil end
  if r.status == "available" and r.best then
    return "Update available: v" .. tostring(r.best.version), PAL.yellow
  end
  if r.status == "error" then return "Update check failed: " .. tostring(r.err), PAL.red end
  if r.status == "current" then return "Up to date", PAL.muted end
  return nil
end

local function jobFor(row, release, verb)
  return { kind = "mod", id = row.id, name = row.name or row.id,
    url = release.zip and release.zip.url, size = release.zip and release.zip.size,
    version = release.version, verb = verb or "Updated", upgrade = true }
end

function ModsPage:enqueue(job)
  self.queue[#self.queue + 1] = job
end

function ModsPage:busy()
  return self.current ~= nil or #self.queue > 0
    or (self.batch ~= nil and self.batch.phase == "checking")
end

function ModsPage:updateMod(row)
  local l = self.launcher
  local r = self.releases[row.id]
  if not (r and r.status == "available" and r.best and r.best.zip) then
    return l:say("No update is known for " .. tostring(row.name) .. ". Check for updates first.", "info")
  end
  if self:queued(row.id) then return end
  self:enqueue(jobFor(row, r.best))
end

function ModsPage:queued(id)
  if self.current and self.current.id == id then return true end
  for _, job in ipairs(self.queue) do if job.id == id then return true end end
  return false
end

-- Update every mod with a newer release: check them all (the release cache
-- answers recent ones without a request), then download and install.
-- spec: { auto, done(result), force }.  Returns true when work started.
function ModsPage:updateAll(spec)
  spec = spec or {}
  local l = self.launcher
  local function finish(result, text, kind)
    if text then l:say(text, kind or "info") end
    if spec.done then spec.done(result) end
    return false
  end
  if self.batch then return false end
  if self:safeMode() then
    return finish({ ok = false, skipped = true, updated = 0, total = 0, failures = {} },
      "Safe mode is on, so mods were not updated.")
  end
  if not ModsPage.canFetch() then
    return finish({ ok = false, skipped = true, updated = 0, total = 0, failures = {} },
      not spec.auto and "This device cannot download mod updates from the launcher." or nil, "error")
  end
  local rows = self:updatableRows()
  if #rows == 0 then
    return finish({ ok = true, skipped = true, updated = 0, total = 0, failures = {} },
      not spec.auto and "None of your mods name a GitHub repo to update from." or nil)
  end
  self.batch = { auto = spec.auto, done = spec.done, phase = "checking", rows = rows,
    updated = 0, total = 0, failures = {} }
  for _, row in ipairs(rows) do self:checkRow(row, spec.force) end
  return true
end

function ModsPage:stop()
  local b = self.batch
  self.queue = {}
  if b then b.cancelled = true end
  -- one download on its own (a catalog Install, one Update): dropped now.
  -- Its transfer cannot be interrupted, so it finishes in the background and
  -- its file is thrown away (pumpAbandoned); nothing is installed from it.
  local job = self.current
  if job and not b and job.stage ~= "install" then
    self.current = nil
    if job.h and job.stage == "download" then
      self.abandoned = self.abandoned or {}
      self.abandoned[#self.abandoned + 1] = job
    end
    self.launcher:say("Stopped getting " .. tostring(job.name) .. ".", "info")
  end
  if b and b.phase == "checking" then
    self.checks = {}
    self:finishBatch()
  end
end

function ModsPage:finishBatch()
  local b = self.batch
  if not b then return end
  self.batch = nil
  local l = self.launcher
  local result = { ok = not b.cancelled and #b.failures == 0,
    cancelled = b.cancelled == true, updated = b.updated, total = b.total,
    failures = b.failures }
  local text, kind
  if b.cancelled then
    text = ("Stopped after updating %d of %d."):format(b.updated, b.total)
  elseif b.total == 0 then
    text = "Your mods are up to date."
  elseif #b.failures == 0 then
    text = ("Updated %d %s."):format(b.updated, b.updated == 1 and "mod" or "mods")
  else
    text = ("Updated %d of %d. %s"):format(b.updated, b.total, table.concat(b.failures, " "))
    kind = "error"
  end
  l:say(text, kind or "info")
  if type(b.done) == "function" then
    local ok, err = pcall(b.done, result)
    if not ok then l:say(tostring(err), "error") end
  end
end

function ModsPage:pumpBatch()
  local b = self.batch
  if not b then return end
  if b.phase == "checking" then
    for _, row in ipairs(b.rows) do
      if self.checks[row.id] then return end
    end
    b.phase = "installing"
    for _, row in ipairs(b.rows) do
      local r = self.releases[row.id]
      if r and r.status == "available" and r.best and r.best.zip and not self:queued(row.id) then
        local job = jobFor(row, r.best)
        job.batch = b
        self:enqueue(job)
        b.total = b.total + 1
      end
    end
  end
  if b.phase == "installing" and not self.current and #self.queue == 0 then
    self:finishBatch()
  end
end

-- ------------------------------------------------- downloads and installs

function ModsPage:pumpAbandoned()
  local list = self.abandoned
  if not list then return end
  local ModUpdate = require("src.mods.ModUpdate")
  for i = #list, 1, -1 do
    local job = list[i]
    local ok, done, path = pcall(ModUpdate.pumpDownloadZip, job.h)
    if not ok or done then
      if ok and path then pcall(love.filesystem.remove, path) end
      table.remove(list, i)
    end
  end
  if #list == 0 then self.abandoned = nil end
end

-- Start the next job, or advance the one running: an optional release
-- lookup (a cart pin names a repo and a version), the download, then the
-- install.  Returns nothing; results land through finishJob.
function ModsPage:pumpInstalls()
  local ModUpdate = require("src.mods.ModUpdate")
  local job = self.current
  if not job then
    job = table.remove(self.queue, 1)
    if not job then return end
    self.current = job
    if not job.url and job.repo then
      job.stage = "releases"
      job.h = ModUpdate.beginFetchReleases(job.repo, job.id, {})
    else
      job.stage = "start"
    end
  end
  if job.stage == "releases" then
    local done, releases, err = ModUpdate.pumpFetchReleases(job.h)
    if not done then return end
    local found
    for _, rel in ipairs(releases or {}) do
      if rel.version == job.version and rel.zip then found = rel break end
    end
    if not found then
      return self:finishJob(job, false, err or ("no release " .. tostring(job.version)
        .. " with a .zip in " .. tostring(job.repo)))
    end
    job.url, job.size = found.zip.url, found.zip.size
    job.stage = "start"
  end
  if job.stage == "start" then
    job.file = ("launcher_download_%s.part"):format(tostring(job.id):gsub("[^%w%-_]", "_"))
    job.h = ModUpdate.beginDownloadZip(job.url, job.file, job.size)
    job.stage = "download"
  end
  local done, path, err, progress = ModUpdate.pumpDownloadZip(job.h)
  if not done then
    job.progress = tonumber(progress) or job.progress
    return
  end
  if not path then
    return self:finishJob(job, false, err or "download failed", job.h and job.h.browserDownload)
  end
  local okR, bytes = pcall(love.filesystem.read, path)
  pcall(love.filesystem.remove, path)
  if not okR or type(bytes) ~= "string" or bytes == "" then
    return self:finishJob(job, false, "the download could not be read back")
  end
  return self:finishJob(job, self:installBytes(job, bytes))
end

-- Returns ok, err.
function ModsPage:installBytes(job, bytes)
  if job.sha256 then
    local got = sha256(bytes)
    if got ~= job.sha256:lower() then
      return false, "the download does not match the cart's pinned hash"
    end
  end
  if job.kind == "cart" then
    local CartStore = require("src.carts.CartStore")
    local ok, cart, err = pcall(CartStore.install, bytes)
    if not ok then cart, err = nil, cart end
    local l = self.launcher
    l.cartRows, l.cartPlans = nil, nil
    if not cart then return false, tostring(err) end
    job.version = cart.version
    return true
  end
  local ModLibrary = require("src.mods.ModLibrary")
  local ok, manifest, err = pcall(ModLibrary.installZip, bytes, tostring(job.id) .. ".zip",
    { upgrade = job.upgrade, replace = job.replace })
  if not ok then manifest, err = nil, manifest end
  if not manifest then
    if tostring(err):find("already installed", 1, true) then return true end
    return false, tostring(err)
  end
  if job.id and manifest.id ~= job.id then
    return false, ("the package installed %s, not %s"):format(tostring(manifest.id), tostring(job.id))
  end
  job.version = manifest.version or job.version
  return true
end

function ModsPage:finishJob(job, ok, err, neutral)
  local l = self.launcher
  self.current = nil
  self:changed()
  local b = job.batch
  if ok then
    if job.kind == "mod" and job.id then self.releases[job.id] = { status = "current" } end
    if b then b.updated = b.updated + 1 end
  elseif b then
    b.failures[#b.failures + 1] = tostring(job.name) .. ": " .. tostring(err) .. "."
  end
  if job.onDone then pcall(job.onDone, ok, err) end
  if b then return end
  if ok then
    local text = ("%s %s%s."):format(job.verb or "Installed", tostring(job.name),
      job.version and (" v" .. tostring(job.version)) or "")
    if job.kind == "cart" then text = text .. " Pick it on its game's Carts page." end
    l:say(text, "info")
  else
    l:say((neutral and "" or ("Could not get " .. tostring(job.name) .. ": "))
      .. tostring(err), neutral and "info" or "error")
  end
end

-- One line for the job strip: what runs, how far.
function ModsPage:jobLine()
  local job = self.current
  local b = self.batch
  if job then
    local text = (job.verb == "Updated" and "Updating " or "Downloading ") .. tostring(job.name)
    if b and b.total > 0 then
      text = text .. (" (%d of %d)"):format(math.min(b.total, b.updated + #b.failures + 1), b.total)
    elseif #self.queue > 0 then
      text = text .. (" (%d more waiting)"):format(#self.queue)
    end
    return text, job.progress
  end
  if b and b.phase == "checking" then return "Checking your mods for updates", nil end
  if self:checking() then return "Checking for updates", nil end
  return nil
end

-- main.lua asks for this before a shortcut boots: update every mod that has
-- a newer release, then call done({ ok, skipped, cancelled, updated, total,
-- failures }).  Without a network, in safe mode, or with nothing to update
-- it answers straight away.
function ModsPage:autoUpdateAll(done, opts)
  local l = self.launcher
  if opts and opts.tab == "mods" and l.selected and l.ready[l.selected] then
    l.page = "mods"
  end
  return self:updateAll({ auto = true, done = done })
end

-- --------------------------------------------------------------- catalog

function ModsPage:openCatalog()
  local l = self.launcher
  l.page = "catalog"
  self.scroll.catalog = 0
  if not self.feeds then self:refreshCatalog(false) end
end

function ModsPage:refreshCatalog(force)
  local ModIndex = require("src.mods.ModIndex")
  local ok, sources = pcall(ModIndex.sources)
  local online = ModsPage.canFetch()
  self.feeds = {}
  for _, source in ipairs(ok and sources or {}) do
    local feed = { source = source, label = source.label or ModIndex.labelFor(source.feed) }
    if online then
      feed.h = ModIndex.beginFetch(source, { force = force })
    else
      local okC, entry = pcall(ModIndex.readCache, source.feed)
      if okC and type(entry) == "table" then
        feed.index = { mods = entry.mods or {}, carts = entry.carts or {} }
        feed.stale = true
      else
        feed.err = "offline, and nothing saved from this index yet"
      end
    end
    self.feeds[#self.feeds + 1] = feed
  end
  self.catalogAll, self.catalogShown = nil, nil
end

function ModsPage:pumpCatalog()
  if not self.feeds then return end
  local ModIndex = require("src.mods.ModIndex")
  for _, feed in ipairs(self.feeds) do
    if feed.h then
      local ok, done, index, err, meta = pcall(ModIndex.pumpFetch, feed.h)
      if not ok then done, index, err = true, nil, tostring(done) end
      if done then
        feed.h = nil
        feed.index, feed.err = index, err
        feed.stale = type(meta) == "table" and meta.stale or nil
        self.catalogAll, self.catalogShown = nil, nil
      end
    end
  end
end

function ModsPage:catalogLoading()
  for _, feed in ipairs(self.feeds or {}) do
    if feed.h then return true end
  end
  return false
end

-- Every listing from every feed, mods then carts, first feed winning an id.
function ModsPage:catalogEntries()
  if self.catalogAll then return self.catalogAll end
  local all, seen = {}, {}
  self.entryFeed = setmetatable({}, { __mode = "k" })
  for _, feed in ipairs(self.feeds or {}) do
    local index = feed.index
    if type(index) == "table" then
      for _, list in ipairs({ index.mods or {}, index.carts or {} }) do
        for _, entry in ipairs(list) do
          local key = (entry.kind == "cart" and "cart:" or "mod:") .. tostring(entry.id)
          if not seen[key] then
            seen[key] = true
            all[#all + 1] = entry
            self.entryFeed[entry] = feed.label
          end
        end
      end
    end
  end
  self.catalogAll = all
  return all
end

function ModsPage:catalogFiltered(version)
  local key = tostring(self.query) .. "|" .. tostring(self.allGames) .. "|" .. tostring(version)
  if self.catalogShown and self.catalogKey == key then return self.catalogShown end
  local ModIndex = require("src.mods.ModIndex")
  local ok, list = pcall(ModIndex.filter, self:catalogEntries(), { query = self.query,
    game = (not self.allGames) and version or nil })
  self.catalogShown, self.catalogKey = ok and list or {}, key
  return self.catalogShown
end

-- installed: nil | "installed" | "update"
function ModsPage:entryState(entry)
  local ModIndex = require("src.mods.ModIndex")
  if ModIndex.isCart(entry) then
    for _, c in ipairs(self.launcher:cartsFor(entry.base)) do
      if c.id == entry.id then
        local okS, Semver = pcall(require, "src.mods.Semver")
        local order = okS and Semver.compare(tostring(entry.version), tostring(c.version))
        return (order and order > 0) and "update" or "installed"
      end
    end
    return nil
  end
  for _, row in ipairs(self:modsFor(self.launcher.selected)) do
    if row.id == entry.id then
      local ModUpdate = require("src.mods.ModUpdate")
      return ModUpdate.isNewer(row.version, ModIndex.displayVersion(entry)) and "update" or "installed"
    end
  end
  return nil
end

function ModsPage:compatFor(entry)
  local ModIndex = require("src.mods.ModIndex")
  local Version = require("src.core.Version")
  local installed, enabled = {}, {}
  for _, row in ipairs(self:modsFor(self.launcher.selected)) do
    if row.id and not row.broken then
      installed[row.id] = row.version or "0.0.0"
      if row.enabled then enabled[row.id] = true end
    end
  end
  local ok, issues = pcall(ModIndex.compatIssues, entry, { modApi = Version.modApi,
    engineVersion = Version.engine, installed = installed, enabled = enabled })
  return ok and issues or {}
end

function ModsPage:installEntry(entry)
  local l = self.launcher
  local ModIndex = require("src.mods.ModIndex")
  if not ModsPage.canFetch() then
    return l:say("This device cannot download from the launcher. Get the file in a "
      .. "browser and drop it here instead.", "error")
  end
  local release, why = ModIndex.releaseFor(entry)
  if type(release) ~= "table" or not (release.zip and release.zip.url) then
    return l:say(tostring(entry.title or entry.id) .. ": " .. tostring(why or "nothing to download"), "error")
  end
  if self:queued(entry.id) then return end
  local isCart = ModIndex.isCart(entry)
  self:enqueue({ kind = isCart and "cart" or "mod", id = entry.id,
    name = entry.title or entry.id, url = release.zip.url, size = release.zip.size,
    version = release.version, verb = self:entryState(entry) == "update" and "Updated" or "Installed",
    upgrade = true })
end

function ModsPage:addFeed(text)
  local l = self.launcher
  text = trim(text)
  if text == "" then return l:say("Paste an index address first.", "error") end
  local ok, row, err = pcall(require("src.mods.ModIndex").addSource, text)
  if not ok then row, err = nil, row end
  if not row then return l:say("Could not add that index: " .. tostring(err), "error") end
  self.feedDraft = ""
  self:refreshCatalog(false)
  l:say("Added " .. tostring(row.label or row.feed) .. ".", "info")
end

function ModsPage:removeFeed(source)
  local l = self.launcher
  local key = "feed:" .. tostring(source.feed)
  if l.armedDelete ~= key then
    l.armedDelete = key
    return l:say("Press Remove again to drop this index and its saved listing.", "info")
  end
  l.armedDelete = nil
  local ok, done, err = pcall(require("src.mods.ModIndex").removeSource, source.feed)
  if not (ok and done) then
    return l:say("Could not remove that index: " .. tostring(ok and err or done), "error")
  end
  self:refreshCatalog(false)
  l:say("Removed " .. tostring(source.label or source.feed) .. ".", "info")
end

-- ------------------------------------------------------------------ pump

function ModsPage:update()
  self:pumpChecks()
  self:pumpCatalog()
  -- a job that throws ends with the reason rather than repeating every frame
  local ok, err = pcall(self.pumpInstalls, self)
  if not ok and self.current then self:finishJob(self.current, false, err) end
  self:pumpAbandoned()
  self:pumpBatch()
end

-- ------------------------------------------------------------------ draw

function ModsPage:draw(x, y, w, h, s)
  local l = self.launcher
  local page = l.page
  if page == "importers" then
    return l:drawFitted("importers", x, y, w, h, s, function(_, ...) return self:drawImporters(...) end)
  end
  if page == "feeds" then
    return l:drawFitted("feeds", x, y, w, h, s, function(_, ...) return self:drawFeeds(...) end)
  end
  if not (l.selected and l.ready[l.selected]) then return l:drawGame(x, y, w, h, s) end
  -- the list pages keep a list between a header and buttons; too short for
  -- that (a phone on its side), the whole page scrolls instead of overlapping
  local lists = { catalog = self.drawCatalog, examples = self.drawExamples,
    loadorder = self.drawLoadOrder, mods = self.drawMods }
  local list = lists[page] or (not ModsPage.PAGES[page] and self.drawMods) or nil
  local fitted = { mod = self.drawDetail, modoptions = self.drawOptions,
    modtools = self.drawTools, profiles = self.drawProfiles, catalogitem = self.drawEntry,
    example = self.drawExample }
  local fn = fitted[page] or list or self.drawMods
  return l:drawFitted(tostring(page) .. ":" .. tostring(l.selected), x, y, w, h, s,
    function(_, ...) return fn(self, ...) end)
end

-- The strip shown while downloads or update checks run, with Stop.
function ModsPage:drawJobStrip(cx, cy, cw, s)
  local text, progress = self:jobLine()
  if not text then return cy end
  local l = self.launcher
  local bh = btnH(s)
  local stopW = math.max(Kit.tapMin(), Kit.textWidth("small", "Stop") + math.floor(28 * s))
  local tw = cw - stopW - Theme.space("s", s)
  Kit.text("small", Kit.ellipsize("small", text, tw), cx, cy, PAL.text)
  local my = cy + Kit.textHeight("small") + Theme.space("xxs", s)
  if progress then
    Theme.meter(cx, my, tw, math.max(4, math.floor(8 * s)), progress * 100, PAL.green)
  else
    Kit.text("micro", "Working...", cx, my, PAL.muted)
  end
  if Kit.button(cx + cw - stopW, cy, stopW, bh, "Stop", { id = "mods-stop", font = "small",
      enabled = self.batch ~= nil or #self.queue > 0 or self.current ~= nil }) then
    l:queue(function() self:stop() end)
  end
  return cy + math.max(bh, Kit.textHeight("small") + math.floor(14 * s)) + Theme.space("s", s)
end

function ModsPage:drawSafeBanner(cx, cy, cw, s)
  if not self:safeMode() then return cy end
  local l = self.launcher
  local bh = btnH(s)
  local offW = math.max(Kit.tapMin(), Kit.textWidth("small", "Turn off") + math.floor(28 * s))
  local text = "Safe mode is on: every mod stays off until you turn it off."
  local tw = cw - offW - Theme.space("m", s) - Theme.space("s", s)
  local th = math.max(bh, Kit.wrapHeight("small", text, tw)) + Theme.space("s", s)
  Theme.fillRounded(cx, cy, cw, th, PAL.red, 0.18, Theme.radius())
  Theme.fillRounded(cx, cy, math.max(3, math.floor(4 * s)), th, PAL.red, 1, 2)
  Kit.textWrapped("small", text, cx + Theme.space("m", s), cy + (th - Kit.wrapHeight("small", text, tw)) / 2,
    tw, PAL.text)
  if Kit.button(cx + cw - offW - Theme.space("xxs", s), cy + (th - bh) / 2, offW, bh, "Turn off",
      { id = "safe-off", font = "small", kind = "warn" }) then
    l:queue(function() self:setSafeMode(false) end)
  end
  return cy + th + Theme.space("s", s)
end

function ModsPage:drawMods(x, y, w, h, s)
  local l = self.launcher
  local v = l.selected
  local pad = math.floor(18 * s)
  Kit.card(x, y, w, h)
  local cx, cw = x + pad, w - 2 * pad
  local cy = y + pad
  local bh = math.max(Kit.tapMin(), math.floor(40 * s))
  cy = l:pageHeader(cx, cy, cw, s, { title = "Mods",
    subtitle = "For " .. gameName(v), accent = Theme.gameColor(v),
    back = function() l.page = nil end, backId = "mods-back" })
  cy = self:drawSafeBanner(cx, cy, cw, s)
  cy = self:drawJobStrip(cx, cy, cw, s)
  local avail = self:availableCount()
  local busy = self:busy()
  cy = self:flow(cx, cy, cw, s, {
    { label = "Get mods", id = "mods-catalog", kind = "accent", run = function() self:openCatalog() end },
    { label = "Examples", id = "mods-examples", run = function() l.page = "examples" end },
    avail > 0 and { label = ("Update all (%d)"):format(avail), id = "mods-update-all", kind = "primary",
        enabled = not busy, run = function() self:updateAll({}) end }
      or { label = "Check for updates", id = "mods-check", enabled = not self:checking() and not busy,
        run = function() self:checkUpdates(true) end },
    { label = "Tools", id = "mods-tools", run = function() l.page = "modtools" end },
  })

  local rows = self:modsFor(v)
  local rowH = math.max(Kit.tapMin() + math.floor(8 * s), math.floor(56 * s))
  local gap = math.floor(4 * s)
  local hint = "Or drop a mod .zip onto this window. Changes apply the next "
    .. "time the game starts."
  local hintH = Kit.wrapHeight("micro", hint, cw)
  local footH = bh + math.floor(12 * s) + hintH
  local viewH = math.max(rowH, y + h - pad - footH - math.floor(10 * s) - cy)
  local need = math.max(h, (cy - y) + 2 * (rowH + gap) + footH + pad + math.floor(10 * s))
  if #rows == 0 then
    Kit.emptyBox(cx, cy, cw, math.min(viewH, rowH * 2), "No mods installed")
  else
    local maxAt = Kit.scrollExtent(#rows * (rowH + gap), viewH)
    l.modScroll = Kit.scrollInput(l.modScroll or 0, maxAt, cx, cy, cw, viewH)
    local py = Kit.scrollBegin(cx, cy, cw, viewH, l.modScroll, maxAt)
    local rw = cw - Kit.scrollGutter(s)
    -- wide enough for the longest label with the button's own inset
    local longest = math.max(Kit.textWidth("small", "Add file"), Kit.textWidth("small", "Get pack"))
    local bw = math.max(Kit.tapMin(), longest + Theme.BUTTON.labelInset * s + math.floor(12 * s))
    -- the toggle only ever says On or Off: sized for that, the name gets the room
    local tw = math.max(Kit.tapMin(), math.max(Kit.textWidth("small", "On"),
      Kit.textWidth("small", "Off")) + Theme.BUTTON.labelInset * s + math.floor(24 * s))
    local sbh = math.max(Kit.tapMin(), math.floor(32 * s))
    local bgap = math.floor(8 * s)
    for i, row in ipairs(rows) do
      local ry = py + (i - 1) * (rowH + gap)
      local clicked = Kit.row(cx, ry, rw, rowH, false, "mod-" .. tostring(row.folder))
      local tx = cx + math.floor(12 * s)
      local need = not row.broken and row.supported and self:modNeeds(row) or nil
      -- a narrow row keeps its name readable: what the mod needs is on its
      -- details page (a tap on the row), not a second button here
      local needBtn = need and rw - bw - tw - 2 * bgap - math.floor(20 * s) >= 150 * s
      local textW = rw - tw - bgap - (needBtn and (bw + bgap) or 0) - math.floor(20 * s)
      local detail
      local ink = PAL.muted
      local upd, updInk = self:updateLine(row)
      if need then
        detail, ink = need.text, PAL.yellow
      elseif row.broken then
        detail, ink = "Broken: " .. row.broken, PAL.red
      elseif not row.supported then
        detail = "Not made for this game"
      elseif upd and updInk ~= PAL.muted then
        detail, ink = upd, updInk
      else
        -- what it does says more than its version, which the details page keeps
        local parts = {}
        if row.experimental then parts[#parts + 1] = "Experimental" end
        if row.description and row.description ~= "" then
          parts[#parts + 1] = row.description
        else
          if row.version then parts[#parts + 1] = "v" .. tostring(row.version) end
          if row.author then parts[#parts + 1] = "by " .. tostring(row.author) end
        end
        detail = table.concat(parts, "  -  ")
        if detail == "" then detail = row.id end
      end
      twoLines(row.name, detail, tx, ry, rowH, textW, PAL.text, ink, s)
      local by = ry + (rowH - sbh) / 2
      local onX = cx + rw - tw - math.floor(8 * s)
      local needX = onX - bw - bgap
      if needBtn then
        if Kit.button(needX, by, bw, sbh, need.file and "Add file" or "Get pack",
            { id = "mod-need-" .. tostring(row.folder), font = "small", kind = "accent" }) then
          l:queue(function()
            if need.file then self:addModFile(row, need.file)
            else l.page = "importers" end
          end)
        end
      end
      local usable = not row.broken and row.supported
      if Kit.button(onX, by, tw, sbh, row.enabled and usable and "On" or "Off",
          { id = "mod-toggle-" .. tostring(row.folder), font = "small",
            kind = row.enabled and usable and "primary" or nil, enabled = usable }) then
        l:queue(function() self:toggleMod(v, row) end)
      end
      -- a press on a button is not also a press on its row
      if clicked and not Kit.clickIn(onX, by, tw, sbh)
          and not (needBtn and Kit.clickIn(needX, by, bw, sbh)) then
        local folder = row.folder
        l:queue(function() self.detailFolder, l.page = folder, "mod" end)
      end
    end
    Kit.scrollEnd(cx, cy, cw, viewH, l.modScroll, maxAt, PAL.surface)
  end

  local fy = y + h - pad - bh - hintH - math.floor(8 * s)
  local iw = math.min(math.floor((cw - math.floor(10 * s)) / 2), math.floor(260 * s))
  if Kit.button(cx, fy, iw, bh, "Install mod .zip", { id = "mod-install", kind = "accent" }) then
    l:queue(function() self:pickMod() end)
  end
  if Kit.button(cx + iw + math.floor(10 * s), fy, iw, bh, "Asset importers",
      { id = "mod-importers" }) then
    l:queue(function() l.page = "importers" end)
  end
  Kit.textWrapped("micro", hint, cx, fy + bh + math.floor(8 * s), cw, PAL.faint)
  return need
end

-- ------------------------------------------------------------ examples

function ModsPage:examplesFor(version)
  self.exampleRows = self.exampleRows or {}
  local rows = self.exampleRows[version or ""]
  if rows then return rows end
  local okL, got = pcall(require("src.mods.ModLibrary").examples, version)
  rows = okL and type(got) == "table" and got or {}
  self.exampleRows[version or ""] = rows
  return rows
end

function ModsPage:installExample(row)
  local l = self.launcher
  local ok, manifest, err = pcall(require("src.mods.ModLibrary").installExample, row.name)
  if not ok then manifest, err = nil, manifest end
  if not manifest then
    return l:say("Could not install " .. tostring(row.title) .. ": " .. tostring(err), "error")
  end
  self:changed()
  self.exampleRows = nil
  local v = l.selected
  if row.supported == false then
    l:say(("%s is installed. It does not run on %s, so it stays off here."):format(
      tostring(row.title), gameName(v)), "info")
  else
    l:say(("%s is installed and on for %s. It applies the next time the game starts."):format(
      tostring(row.title), gameName(v)), "info")
  end
end

-- The gallery that ships with the game, one press to install each.
function ModsPage:drawExamples(x, y, w, h, s)
  local l = self.launcher
  local v = l.selected
  local pad = math.floor(18 * s)
  Kit.card(x, y, w, h)
  local cx, cw = x + pad, w - 2 * pad
  local cy = y + pad
  cy = l:pageHeader(cx, cy, cw, s, { title = "Example mods",
    subtitle = "Made with the game, to try or to learn from",
    back = function() l:back() end, backId = "examples-back" })
  local rows = self:examplesFor(v)
  local rowH = math.max(Kit.tapMin() + math.floor(8 * s), math.floor(56 * s))
  local viewH = math.max(rowH, y + h - pad - cy)
  local need = math.max(h, (cy - y) + 2 * rowH + pad)
  if #rows == 0 then
    Kit.emptyBox(cx, cy, cw, math.min(viewH, rowH * 2), "This build has no example mods")
    return need
  end
  local gapR = math.floor(4 * s)
  local maxAt = Kit.scrollExtent(#rows * (rowH + gapR), viewH)
  self.scroll.examples = Kit.scrollInput(self.scroll.examples or 0, maxAt, cx, cy, cw, viewH)
  local py = Kit.scrollBegin(cx, cy, cw, viewH, self.scroll.examples, maxAt)
  local rw = cw - Kit.scrollGutter(s)
  local bw = math.max(Kit.tapMin(), Kit.textWidth("small", "Installed") + math.floor(24 * s))
  local bh = math.max(Kit.tapMin(), math.floor(32 * s))
  for i, row in ipairs(rows) do
    local ry = py + (i - 1) * (rowH + gapR)
    local clicked = Kit.row(cx, ry, rw, rowH, false, "example-" .. tostring(row.name))
    local detail, ink = row.description or row.id, PAL.muted
    if row.supported == false then
      detail = "Not for " .. gameName(v) .. ": runs on " .. tostring(ModsPage.runsOn(row.manifest) or "other games")
      ink = PAL.faint
    end
    twoLines(row.title, detail, cx + math.floor(12 * s), ry, rowH,
      rw - bw - math.floor(36 * s), PAL.text, ink, s)
    local bx, by = cx + rw - bw - math.floor(8 * s), ry + (rowH - bh) / 2
    if Kit.button(bx, by, bw, bh, row.installed and "Installed" or "Install",
        { id = "example-install-" .. tostring(row.name), font = "small",
          kind = not row.installed and row.supported ~= false and "primary" or nil,
          enabled = not row.installed }) then
      l:queue(function() self:installExample(row) end)
    elseif clicked and not Kit.clickIn(bx, by, bw, bh) then
      local name = row.name
      l:queue(function() self.exampleName, l.page = name, "example" end)
    end
  end
  Kit.scrollEnd(cx, cy, cw, viewH, self.scroll.examples, maxAt, PAL.surface)
  return need
end

-- One example in full: a phone's row has room for a few words of it.
function ModsPage:drawExample(x, y, w, h, s)
  local l = self.launcher
  local v = l.selected
  local pad = math.floor(18 * s)
  Kit.card(x, y, w, h)
  local cx, cw = x + pad, w - 2 * pad
  local cy = y + pad
  local row
  for _, r in ipairs(self:examplesFor(v)) do
    if r.name == self.exampleName then row = r end
  end
  local back = function() l.page = "examples" end
  if not row then
    cy = l:pageHeader(cx, cy, cw, s, { title = "Example", back = back, backId = "example-back" })
    Kit.text("small", "That example is not in this build.", cx, cy, PAL.muted)
    return cy + Kit.textHeight("small") + pad - y
  end
  local m = row.manifest or {}
  local sub = {}
  if m.version then sub[#sub + 1] = "v" .. tostring(m.version) end
  if type(m.category) == "string" and m.category ~= "" then
    sub[#sub + 1] = (m.category:sub(1, 1) .. m.category:sub(2):lower():gsub("_", " "))
  end
  cy = l:pageHeader(cx, cy, cw, s, { title = tostring(row.title),
    subtitle = #sub > 0 and table.concat(sub, "  -  ") or nil, back = back, backId = "example-back" })
  local gap = Theme.space("s", s)
  if row.description then cy = para("small", row.description, cx, cy, cw, PAL.text, gap) end
  local games = ModsPage.runsOn(m)
  if games then cy = para("micro", "Runs on " .. games, cx, cy, cw, PAL.muted, gap) end
  if row.supported == false then
    cy = para("small", "It does not run on " .. gameName(v) .. ".", cx, cy, cw, PAL.yellow, gap)
  end
  if m.experimental then
    cy = para("small", "Its author marks it experimental: it starts off.", cx, cy, cw, PAL.yellow, gap)
  end
  local items = {}
  if row.installed then
    items[1] = { label = "Installed", id = "example-detail-installed", enabled = false }
    items[2] = { label = "Open in Mods", id = "example-detail-open", run = function()
      local folder
      for _, r in ipairs(self:modsFor(v)) do if r.id == row.id then folder = r.folder end end
      if folder then self.detailFolder, l.page = folder, "mod" else l.page = "mods" end
    end }
  else
    items[1] = { label = "Install", id = "example-detail-install",
      kind = row.supported ~= false and "primary" or nil,
      run = function() self:installExample(row) end }
  end
  cy = self:flow(cx, cy + gap, cw, s, items)
  return cy + pad - y
end

-- One mod: what it is, its update state, its files, and every action.
function ModsPage:drawDetail(x, y, w, h, s)
  local l = self.launcher
  local v = l.selected
  local pad = math.floor(18 * s)
  Kit.card(x, y, w, h)
  local cx, cw = x + pad, w - 2 * pad
  local cy = y + pad
  local row = self:rowByFolder(v, self.detailFolder)
  if not row then
    cy = l:pageHeader(cx, cy, cw, s, { title = "Mod", back = function() l.page = "mods" end,
      backId = "mod-back" })
    Kit.text("small", "That mod is no longer installed.", cx, cy, PAL.muted)
    return cy + Kit.textHeight("small") + pad - y
  end
  local sub = {}
  if row.version then sub[#sub + 1] = "v" .. tostring(row.version) end
  if row.author then sub[#sub + 1] = "by " .. tostring(row.author) end
  local category = row.manifest and row.manifest.category
  if type(category) == "string" and category ~= "" then
    sub[#sub + 1] = (category:sub(1, 1) .. category:sub(2):lower():gsub("_", " "))
  end
  cy = l:pageHeader(cx, cy, cw, s, { title = tostring(row.name),
    subtitle = #sub > 0 and table.concat(sub, "  -  ") or tostring(row.id),
    back = function() l.page = "mods" end, backId = "mod-back" })
  local gap = Theme.space("s", s)
  cy = self:drawJobStrip(cx, cy, cw, s)
  if row.broken then cy = para("small", "This mod is broken: " .. tostring(row.broken), cx, cy, cw, PAL.red, gap) end
  if not row.broken and not row.supported then
    cy = para("small", "It was not made for " .. gameName(v) .. ", so it stays off here.", cx, cy, cw, PAL.yellow, gap)
  end
  if row.experimental then
    cy = para("small", "Its author marks it experimental.", cx, cy, cw, PAL.yellow, gap)
  end
  if row.description then cy = para("small", row.description, cx, cy, cw, PAL.text, gap) end
  local games = row.manifest and ModsPage.runsOn(row.manifest)
  if games then cy = para("micro", "Runs on " .. games, cx, cy, cw, PAL.muted, gap) end
  local upd, updInk = self:updateLine(row)
  if upd then cy = para("small", upd, cx, cy, cw, updInk, gap) end
  if row.bundled then
    cy = para("micro", "Built into this copy of the game: it cannot be removed or updated here.",
      cx, cy, cw, PAL.faint, gap)
  end
  local usable = not row.broken and row.supported
  local r = self.releases[row.id]
  local armed = l.armedDelete == "mod:" .. tostring(row.folder)
  -- what it still needs before it can load, and the way to supply it
  local need = usable and self:modNeeds(row) or nil
  if need then cy = para("small", need.text, cx, cy, cw, PAL.yellow, gap) end
  local items = {
    { label = row.enabled and usable and "Turn off" or "Turn on", id = "mod-detail-toggle",
      kind = (not row.enabled and usable) and "primary" or nil, enabled = usable,
      run = function() self:toggleMod(v, row) end },
  }
  if need then
    items[#items + 1] = { label = need.file and "Add file" or "Get pack", id = "mod-detail-need",
      kind = "primary", run = function()
        if need.file then self:addModFile(row, need.file) else l.page = "importers" end
      end }
  end
  if updatable(row) then
    if r and r.status == "available" and r.best then
      items[#items + 1] = { label = "Update to v" .. tostring(r.best.version), id = "mod-detail-update",
        kind = "primary", enabled = not self:queued(row.id),
        run = function() self:updateMod(row) end }
    else
      items[#items + 1] = { label = "Check for update", id = "mod-detail-check",
        enabled = not self.checks[row.id],
        run = function()
          if not ModsPage.canFetch() then
            return l:say("This device cannot check for mod updates from the launcher.", "error")
          end
          self:checkRow(row, true)
        end }
    end
  end
  if self:schemaFor(row) then
    items[#items + 1] = { label = "Options", id = "mod-detail-options",
      run = function() l.page = "modoptions" end }
  end
  if not row.bundled then
    items[#items + 1] = { label = armed and "Confirm remove" or "Remove", id = "mod-detail-remove",
      kind = "danger", keepArmed = true, run = function() self:removeMod(row) end }
  end
  cy = self:flow(cx, cy + gap, cw, s, items)

  -- files the mod asked the player for
  local okR, RequiredImports = pcall(require, "src.mods.RequiredImports")
  local files = {}
  if okR and row.manifest and #(RequiredImports.specs(row.manifest)) > 0 then
    local okI, got = pcall(RequiredImports.inspect, row.manifest)
    files = okI and got or {}
  end
  if #files > 0 then
    cy = cy + gap
    Kit.caption(cx, cy, "FILES THIS MOD USES", PAL.caption)
    cy = cy + Kit.textHeight("caption") + gap
    for _, f in ipairs(files) do
      local state = f.present and "Stored" or (f.error and ("Rejected: " .. tostring(f.error)))
        or (f.required and "Missing" or "Optional, not added")
      Kit.text("button", Kit.ellipsize("button", tostring(f.name), cw), cx, cy, PAL.text)
      cy = cy + Kit.textHeight("button")
      Kit.text("micro", Kit.ellipsize("micro", state, cw), cx, cy,
        f.present and PAL.green or (f.required and PAL.yellow or PAL.muted))
      cy = cy + Kit.textHeight("micro") + Theme.space("xs", s)
      local fileArmed = l.armedDelete == "modfile:" .. tostring(row.folder) .. ":" .. tostring(f.id)
      local fitems = { { label = f.present and "Replace file" or "Add file",
        id = "mod-file-add-" .. tostring(f.id), kind = f.present and nil or "accent",
        run = function() self:addModFile(row, f.spec) end } }
      if f.present then
        fitems[2] = { label = fileArmed and "Confirm remove" or "Remove file",
          id = "mod-file-remove-" .. tostring(f.id), kind = "danger", keepArmed = true,
          run = function() self:removeModFile(row, f) end }
      end
      cy = self:flow(cx, cy, cw, s, fitems)
    end
  end
  return cy + pad - y
end

-- Options from the mod's options_schema, with reset to defaults.
function ModsPage:drawOptions(x, y, w, h, s)
  local l = self.launcher
  local pad = math.floor(18 * s)
  Kit.card(x, y, w, h)
  local cx, cw = x + pad, w - 2 * pad
  local cy = y + pad
  local row = self:rowByFolder(l.selected, self.detailFolder)
  cy = l:pageHeader(cx, cy, cw, s, { title = "Options",
    subtitle = row and tostring(row.name) or nil,
    back = function() l.page = "mod" end, backId = "modoptions-back" })
  local schema = row and self:schemaFor(row)
  if not schema then
    cy = para("small", "The launcher cannot show this mod's options. Change them in the "
      .. "game's MODS menu instead.", cx, cy, cw, PAL.muted, pad)
    return cy - y
  end
  local id = row.id
  local byKey = {}
  for _, opt in ipairs(schema) do
    if type(opt) == "table" and type(opt.key) == "string" then byKey[opt.key] = opt end
  end
  local rh = btnH(s)
  local ctrlW = math.min(math.floor(cw * 0.5), math.floor(240 * s))
  local labelW = cw - ctrlW - Theme.space("m", s)
  local gap = Theme.space("s", s)
  local shown = 0
  for i, opt in ipairs(schema) do
    if type(opt) == "table" and type(opt.key) == "string" and opt.key ~= ""
        and OPTION_TYPES[opt.type] and self:optionVisible(id, opt, byKey) then
      shown = shown + 1
      local label = tostring(opt.label or opt.key)
      local lh = math.max(rh, Kit.wrapHeight("small", label, labelW))
      Kit.textWrapped("small", label, cx, cy + (lh - Kit.wrapHeight("small", label, labelW)) / 2,
        labelW, PAL.text)
      local kx, ky = cx + cw - ctrlW, cy + (lh - rh) / 2
      local value = self:optionValue(id, opt)
      local key = opt.key
      local oid = "modopt-" .. i
      if opt.type == "toggle" then
        local tw = math.min(ctrlW, math.floor(96 * s))
        local now, hit = Kit.toggle(kx + ctrlW - tw, ky, tw, rh, value and true or false, oid)
        if hit then l:queue(function() self:setOption(id, key, now) end) end
      elseif opt.type == "choice" then
        local choices = type(opt.choices) == "table" and opt.choices or {}
        local at = 1
        for ci, c in ipairs(choices) do
          if type(c) == "table" and c[2] == value then at = ci end
        end
        local cur = choices[at]
        local text = type(cur) == "table" and tostring(cur[1]) or "-"
        if Kit.button(kx, ky, ctrlW, rh, Kit.ellipsize("small", text, ctrlW - math.floor(16 * s)),
            { id = oid, font = "small", enabled = #choices > 1 }) then
          local nextChoice = choices[at % #choices + 1]
          l:queue(function() self:setOption(id, key, nextChoice[2]) end)
        end
      elseif opt.type == "number" then
        local sw = Kit.tapMin()
        local n = tonumber(value) or 0
        local step = tonumber(opt.step) or 1
        local function clamp(vv)
          if tonumber(opt.min) then vv = math.max(tonumber(opt.min), vv) end
          if tonumber(opt.max) then vv = math.min(tonumber(opt.max), vv) end
          return vv
        end
        if Kit.button(kx, ky, sw, rh, "-", { id = oid .. "-down", font = "small",
            enabled = clamp(n - step) ~= n }) then
          l:queue(function() self:setOption(id, key, clamp(n - step)) end)
        end
        Kit.textCenter("small", tostring(n), kx + sw, ky + (rh - Kit.textHeight("small")) / 2,
          ctrlW - 2 * sw, PAL.text)
        if Kit.button(kx + ctrlW - sw, ky, sw, rh, "+", { id = oid .. "-up", font = "small",
            enabled = clamp(n + step) ~= n }) then
          l:queue(function() self:setOption(id, key, clamp(n + step)) end)
        end
      else
        self.textDrafts = self.textDrafts or {}
        local dk = id .. ":" .. key
        local draft = self.textDrafts[dk]
        if draft == nil then draft = tostring(value or "") end
        local ended
        draft, ended = Kit.textfield(oid, kx, ky, ctrlW, rh, draft, label)
        self.textDrafts[dk] = draft
        if ended == "submit" then
          local text = draft
          if tonumber(opt.maxLen) then text = clip(text, tonumber(opt.maxLen)) end
          l:queue(function() self:setOption(id, key, text); self.textDrafts[dk] = nil end)
        elseif ended == "cancel" then
          self.textDrafts[dk] = nil
        end
      end
      cy = cy + lh + gap
    end
  end
  if shown == 0 then
    cy = para("small", "This mod has no options to show right now.", cx, cy, cw, PAL.muted, gap)
  end
  cy = self:flow(cx, cy + gap, cw, s, {
    { label = "Reset to defaults", id = "modoptions-reset", kind = "danger",
      run = function() self:resetOptions(row); self.textDrafts = nil end } })
  cy = para("micro", "Changes apply the next time the game starts.", cx, cy, cw, PAL.faint, 0)
  return cy + pad - y
end

-- Safe mode, all on / off, and the way to load order and profiles.
function ModsPage:drawTools(x, y, w, h, s)
  local l = self.launcher
  local v = l.selected
  local pad = math.floor(18 * s)
  Kit.card(x, y, w, h)
  local cx, cw = x + pad, w - 2 * pad
  local cy = y + pad
  cy = l:pageHeader(cx, cy, cw, s, { title = "Mod tools", subtitle = "For " .. gameName(v),
    accent = Theme.gameColor(v), back = function() l.page = "mods" end, backId = "modtools-back" })
  local gap = Theme.space("s", s)
  local rh = btnH(s)
  local tw = math.floor(96 * s)
  local on = self:safeMode()
  local text = "Safe mode starts every game with all mods off, to find out whether a mod "
    .. "is behind a problem. Your choices are kept for when you turn it off."
  local textW = cw - tw - Theme.space("m", s)
  Kit.textBold("button", "Safe mode", cx, cy, on and PAL.red or PAL.heading)
  local now, hit = Kit.toggle(cx + cw - tw, cy, tw, rh, on, "safe-mode")
  if hit then l:queue(function() self:setSafeMode(now) end) end
  cy = cy + math.max(rh, Kit.textHeight("button")) + Theme.space("xxs", s)
  cy = para("small", text, cx, cy, textW, PAL.muted, gap * 2)

  Kit.caption(cx, cy, "EVERY MOD FOR " .. gameName(v):upper(), PAL.caption)
  cy = cy + Kit.textHeight("caption") + gap
  cy = self:flow(cx, cy, cw, s, {
    { label = "Turn all on", id = "mods-all-on", run = function() self:setAll(v, true) end },
    { label = "Turn all off", id = "mods-all-off", run = function() self:setAll(v, false) end },
  })
  cy = cy + gap
  Kit.caption(cx, cy, "MORE", PAL.caption)
  cy = cy + Kit.textHeight("caption") + gap
  cy = self:flow(cx, cy, cw, s, {
    { label = "Load order", id = "mods-load-order",
      run = function() l.page, self.scroll.order = "loadorder", 0 end },
    { label = "Profiles", id = "mods-profiles", run = function() l.page = "profiles" end },
    { label = "Asset importers", id = "mods-tools-importers", run = function() l.page = "importers" end },
  })
  return cy + pad - y
end

function ModsPage:drawLoadOrder(x, y, w, h, s)
  local l = self.launcher
  local v = l.selected
  local pad = math.floor(18 * s)
  Kit.card(x, y, w, h)
  local cx, cw = x + pad, w - 2 * pad
  local cy = y + pad
  cy = l:pageHeader(cx, cy, cw, s, { title = "Load order",
    subtitle = "Mods lower in the list load later, and win when two change the same thing.",
    back = function() l.page = "modtools" end, backId = "loadorder-back" })
  cy = self:flow(cx, cy, cw, s, {
    { label = "Reset order", id = "loadorder-reset", kind = "danger",
      run = function() self:resetOrder() end } })
  local list, byId = self:orderList(v)
  local rowH = math.max(Kit.tapMin() + math.floor(8 * s), math.floor(48 * s))
  local gap = math.floor(4 * s)
  local viewH = math.max(rowH, y + h - pad - cy)
  local need = math.max(h, (cy - y) + 2 * rowH + pad)
  if #list == 0 then
    Kit.emptyBox(cx, cy, cw, math.min(viewH, rowH * 2), "No mods installed")
    return need
  end
  local maxAt = Kit.scrollExtent(#list * (rowH + gap), viewH)
  self.scroll.order = Kit.scrollInput(self.scroll.order or 0, maxAt, cx, cy, cw, viewH)
  local py = Kit.scrollBegin(cx, cy, cw, viewH, self.scroll.order, maxAt)
  local rw = cw - Kit.scrollGutter(s)
  local bw = math.max(Kit.tapMin(), Kit.textWidth("small", "Down") + math.floor(20 * s))
  local bh = math.max(Kit.tapMin(), math.floor(32 * s))
  for i, id in ipairs(list) do
    local ry = py + (i - 1) * (rowH + gap)
    Kit.row(cx, ry, rw, rowH, false, nil)
    local row = byId[id]
    local name = ("%d.  %s"):format(i, tostring(row and row.name or id))
    local textW = rw - 2 * (bw + math.floor(8 * s)) - math.floor(20 * s)
    Kit.text("button", Kit.ellipsize("button", name, textW), cx + math.floor(12 * s),
      ry + (rowH - Kit.textHeight("button")) / 2,
      (row and row.enabled and row.supported) and PAL.text or PAL.muted)
    local by = ry + (rowH - bh) / 2
    local dx = cx + rw - bw - math.floor(8 * s)
    if Kit.button(dx - bw - math.floor(8 * s), by, bw, bh, "Up",
        { id = "order-up-" .. id, font = "small", enabled = i > 1 }) then
      l:queue(function() self:moveOrder(v, id, -1) end)
    end
    if Kit.button(dx, by, bw, bh, "Down",
        { id = "order-down-" .. id, font = "small", enabled = i < #list }) then
      l:queue(function() self:moveOrder(v, id, 1) end)
    end
  end
  Kit.scrollEnd(cx, cy, cw, viewH, self.scroll.order, maxAt, PAL.surface)
  return need
end

function ModsPage:drawProfiles(x, y, w, h, s)
  local l = self.launcher
  local v = l.selected
  local pad = math.floor(18 * s)
  Kit.card(x, y, w, h)
  local cx, cw = x + pad, w - 2 * pad
  local cy = y + pad
  cy = l:pageHeader(cx, cy, cw, s, { title = "Profiles",
    subtitle = "Save which mods are on, their options and load order, and switch back any time.",
    back = function() l.page = "modtools" end, backId = "profiles-back" })
  local rh = btnH(s)
  local gap = Theme.space("s", s)
  local saveW = math.max(Kit.tapMin(), Kit.textWidth("small", "Save current") + math.floor(28 * s))
  local ended
  self.profileDraft, ended = Kit.textfield("profile-name", cx, cy, cw - saveW - gap, rh,
    self.profileDraft, "New profile name")
  if Kit.button(cx + cw - saveW, cy, saveW, rh, "Save current", { id = "profile-save",
      font = "small", kind = "primary" }) or ended == "submit" then
    local name = self.profileDraft
    l:queue(function() self:saveProfile(v, name) end)
  end
  cy = cy + rh + gap * 2
  local opts = l:options()
  local list = self:profiles()
  if #list == 0 then
    cy = para("small", "No profiles yet.", cx, cy, cw, PAL.muted, gap)
    return cy + pad - y
  end
  for i, p in ipairs(list) do
    local name = tostring(p.name or ("Profile " .. i))
    local active = opts.activeProfile == p.name
    if self.renamingProfile == p.name then
      local okW = math.max(Kit.tapMin(), Kit.textWidth("small", "Rename") + math.floor(28 * s))
      local e
      self.renameDraft, e = Kit.textfield("profile-rename", cx, cy, cw - okW - gap, rh,
        self.renameDraft, name)
      if Kit.button(cx + cw - okW, cy, okW, rh, "Rename", { id = "profile-rename-ok", font = "small",
          kind = "primary" }) or e == "submit" then
        local new = self.renameDraft
        l:queue(function() self:renameProfile(name, new) end)
      elseif e == "cancel" then
        self.renamingProfile = nil
      end
      cy = cy + rh + gap
    else
      Kit.textBold("button", Kit.ellipsize("button", name .. (active and "  (in use)" or ""), cw), cx, cy,
        active and PAL.green or PAL.heading)
      cy = cy + Kit.textHeight("button") + Theme.space("xs", s)
    end
    local armed = l.armedDelete == "profile:" .. name
    cy = self:flow(cx, cy, cw, s, {
      { label = "Apply", id = "profile-apply-" .. i, kind = "primary",
        run = function() self:applyProfile(v, p.name) end },
      { label = "Rename", id = "profile-rename-" .. i,
        run = function() self.renamingProfile, self.renameDraft = p.name, p.name end },
      { label = armed and "Confirm delete" or "Delete", id = "profile-delete-" .. i, kind = "danger",
        keepArmed = true, run = function() self:deleteProfile(p.name) end },
    }) + gap
  end
  return cy + pad - y
end

local IMPORTER_STATE = { ready = "Imported", partial = "Partly imported",
  missing = "Not imported", planned = "Coming later" }

function ModsPage:drawImporters(x, y, w, h, s)
  local l = self.launcher
  local pad = math.floor(18 * s)
  Kit.card(x, y, w, h)
  local cx, cw = x + pad, w - 2 * pad
  local cy = y + pad
  local smallH = math.max(Kit.tapMin(), math.floor(32 * s))
  cy = l:pageHeader(cx, cy, cw, s, { title = "Asset importers",
    subtitle = "Some mods use art or sound from another game you own. Import it once "
      .. "here and every mod that asks for it can use it.",
    back = function() l:back() end, backId = "importers-back" })

  local job = l.assetJob
  if job then
    Kit.text("small", Kit.ellipsize("small", tostring(job.name) .. ": " .. tostring(job.status), cw),
      cx, cy, PAL.text)
    cy = cy + Kit.textHeight("small") + math.floor(6 * s)
    Theme.meter(cx, cy, cw, math.floor(10 * s),
      100 * (job.done or 0) / math.max(1, job.total or 1), PAL.green)
    cy = cy + math.floor(22 * s)
  end
  local Importers = require("src.import.Importers")
  local entryH = math.max(Kit.tapMin() + math.floor(8 * s), math.floor(64 * s))
  local bw = math.max(Kit.tapMin(), Kit.textWidth("small", "Import") + math.floor(28 * s))
  for _, desc in ipairs(Importers.all()) do
    local state = self:importerState(desc.id)
    Kit.row(cx, cy, cw, entryH, false, "importer-" .. desc.id)
    local textW = cw - bw - math.floor(36 * s)
    local line = (IMPORTER_STATE[state] or state) .. "  -  " .. tostring(desc.summary or "")
    twoLines(desc.name, line, cx + math.floor(12 * s), cy, entryH, textW, PAL.text,
      state == "ready" and PAL.green or PAL.muted, s)
    if Kit.button(cx + cw - bw - math.floor(8 * s), cy + (entryH - smallH) / 2, bw, smallH,
        state == "ready" and "Redo" or "Import",
        { id = "importer-run-" .. desc.id, font = "small",
          enabled = state ~= "planned" and not job }) then
      local id = desc.id
      l:queue(function() self:runImporter(id) end)
    end
    cy = cy + entryH + math.floor(4 * s)
  end
  return cy - y + pad
end

-- "Get mods": search the listings of every index the player added.
function ModsPage:drawCatalog(x, y, w, h, s)
  local l = self.launcher
  local v = l.selected
  local pad = math.floor(18 * s)
  Kit.card(x, y, w, h)
  local cx, cw = x + pad, w - 2 * pad
  local cy = y + pad
  cy = l:pageHeader(cx, cy, cw, s, { title = "Get mods",
    subtitle = "From the mod indexes you added", back = function() l.page = "mods" end,
    backId = "catalog-back" })
  cy = self:drawJobStrip(cx, cy, cw, s)
  local rh = btnH(s)
  local gap = Theme.space("s", s)
  self.query = Kit.textfield("catalog-search", cx, cy, cw, rh, self.query, "Search mods and carts")
  cy = cy + rh + gap
  cy = self:flow(cx, cy, cw, s, {
    { label = self.allGames and "All games" or ("Only " .. gameName(v)), id = "catalog-scope",
      run = function() self.allGames = not self.allGames end },
    { label = "Refresh", id = "catalog-refresh", enabled = not self:catalogLoading(),
      run = function() self:refreshCatalog(true) end },
    { label = "Indexes", id = "catalog-feeds", run = function() l.page = "feeds" end },
  })
  local feeds = self.feeds or {}
  local status
  if #feeds == 0 then
    status = nil
  elseif self:catalogLoading() then
    status = "Loading the mod indexes..."
  else
    local bad, stale = 0, 0
    for _, f in ipairs(feeds) do
      if f.err then bad = bad + 1 end
      if f.stale then stale = stale + 1 end
    end
    if bad > 0 then status = ("%d of %d indexes could not be read."):format(bad, #feeds)
    elseif stale > 0 then status = "Offline: showing the listing saved last time." end
  end
  if status then
    Kit.text("micro", Kit.ellipsize("micro", status, cw), cx, cy, PAL.muted)
    cy = cy + Kit.textHeight("micro") + gap
  end
  local rowH = math.max(Kit.tapMin() + math.floor(8 * s), math.floor(56 * s))
  local viewH = math.max(rowH, y + h - pad - cy)
  local need = math.max(h, (cy - y) + 2 * rowH + pad)
  if #feeds == 0 then
    Kit.emptyBox(cx, cy, cw, math.min(viewH, rowH * 2), "No mod indexes added yet")
    local ty = para("micro", "Press Indexes and paste the address of an index you trust, "
      .. "or try the example mods that come with the game.", cx,
      cy + math.min(viewH, rowH * 2) + gap, cw, PAL.faint, gap)
    self:flow(cx, ty, cw, s, { { label = "Example mods", id = "catalog-examples", kind = "accent",
      run = function() l.page = "examples" end } })
    return need
  end
  local list = self:catalogFiltered(v)
  if #list == 0 then
    Kit.emptyBox(cx, cy, cw, math.min(viewH, rowH * 2),
      self:catalogLoading() and "Loading..." or "Nothing matches")
    return need
  end
  local ModIndex = require("src.mods.ModIndex")
  local gapR = math.floor(4 * s)
  local maxAt = Kit.scrollExtent(#list * (rowH + gapR), viewH)
  self.scroll.catalog = Kit.scrollInput(self.scroll.catalog or 0, maxAt, cx, cy, cw, viewH)
  local py = Kit.scrollBegin(cx, cy, cw, viewH, self.scroll.catalog, maxAt)
  local rw = cw - Kit.scrollGutter(s)
  local bw = math.max(Kit.tapMin(), Kit.textWidth("small", "Installed") + math.floor(24 * s))
  local bh = math.max(Kit.tapMin(), math.floor(32 * s))
  local first = math.max(1, math.floor((self.scroll.catalog or 0) / (rowH + gapR)))
  local last = math.min(#list, first + math.ceil(viewH / (rowH + gapR)) + 1)
  for i = first, last do
    local entry = list[i]
    local ry = py + (i - 1) * (rowH + gapR)
    local clicked = Kit.row(cx, ry, rw, rowH, false, "catalog-" .. i)
    local isCart = ModIndex.isCart(entry)
    local parts = {}
    if isCart then parts[#parts + 1] = "Cart for " .. gameName(entry.base) end
    if entry.author then parts[#parts + 1] = "by " .. tostring(entry.author) end
    parts[#parts + 1] = "v" .. tostring(ModIndex.displayVersion(entry))
    local state = self:entryState(entry)
    twoLines(entry.title or entry.id, table.concat(parts, "  -  "), cx + math.floor(12 * s), ry, rowH,
      rw - bw - math.floor(36 * s), PAL.text, PAL.muted, s)
    local bx, by = cx + rw - bw - math.floor(8 * s), ry + (rowH - bh) / 2
    local can = ModIndex.canInstall(entry) and state ~= "installed" and not self:queued(entry.id)
    local label = state == "installed" and "Installed" or (state == "update" and "Update" or "Install")
    if Kit.button(bx, by, bw, bh, label, { id = "catalog-install-" .. i, font = "small",
        kind = can and "primary" or nil, enabled = can }) then
      l:queue(function() self:installEntry(entry) end)
    end
    if clicked and not Kit.clickIn(bx, by, bw, bh) then
      l:queue(function() self.entry, l.page = entry, "catalogitem" end)
    end
  end
  Kit.scrollEnd(cx, cy, cw, viewH, self.scroll.catalog, maxAt, PAL.surface)
  return need
end

-- One listing: what it is, what to watch out for, and Install.
function ModsPage:drawEntry(x, y, w, h, s)
  local l = self.launcher
  local pad = math.floor(18 * s)
  Kit.card(x, y, w, h)
  local cx, cw = x + pad, w - 2 * pad
  local cy = y + pad
  local entry = self.entry
  local ModIndex = require("src.mods.ModIndex")
  if type(entry) ~= "table" then
    cy = l:pageHeader(cx, cy, cw, s, { title = "Get mods", back = function() l.page = "catalog" end,
      backId = "catalogitem-back" })
    return cy + pad - y
  end
  local isCart = ModIndex.isCart(entry)
  local sub = { (isCart and "Cart" or "Mod") .. " v" .. tostring(ModIndex.displayVersion(entry)) }
  if entry.author then sub[#sub + 1] = "by " .. tostring(entry.author) end
  cy = l:pageHeader(cx, cy, cw, s, { title = tostring(entry.title or entry.id),
    subtitle = table.concat(sub, "  -  "), back = function() l.page = "catalog" end,
    backId = "catalogitem-back" })
  local gap = Theme.space("s", s)
  cy = self:drawJobStrip(cx, cy, cw, s)
  if entry.summary and entry.summary ~= "" then cy = para("small", entry.summary, cx, cy, cw, PAL.text, gap) end
  local facts = {}
  if isCart then
    facts[#facts + 1] = "Plays as " .. gameName(entry.base)
    facts[#facts + 1] = ("Pins %d %s"):format(#(entry.mods or {}), #(entry.mods or {}) == 1 and "mod" or "mods")
    if entry.seal and entry.seal ~= "open" then facts[#facts + 1] = "Sealed: its saves keep its mod setup" end
  else
    local okT, target = pcall(ModIndex.targetLabel, entry)
    if okT and target then facts[#facts + 1] = "For " .. tostring(target) end
  end
  if entry.license then facts[#facts + 1] = "License: " .. tostring(entry.license) end
  local feed = self.entryFeed and self.entryFeed[entry]
  if feed then facts[#facts + 1] = "Listed by " .. tostring(feed) end
  for _, f in ipairs(facts) do cy = para("micro", f, cx, cy, cw, PAL.muted, Theme.space("xxs", s)) end
  cy = cy + gap
  if not isCart then
    for _, issue in ipairs(self:compatFor(entry)) do
      cy = para("small", "! " .. tostring(issue.text), cx, cy, cw, PAL.yellow, Theme.space("xxs", s))
    end
  end
  local state = self:entryState(entry)
  local url, why = ModIndex.installUrl(entry)
  if not url then cy = para("small", "Cannot install: " .. tostring(why), cx, cy, cw, PAL.red, gap) end
  local can = url ~= nil and state ~= "installed" and not self:queued(entry.id)
  cy = self:flow(cx, cy + gap, cw, s, {
    { label = state == "installed" and "Installed" or (state == "update" and "Update" or "Install"),
      id = "catalogitem-install", kind = "primary", enabled = can,
      run = function() self:installEntry(entry) end } })
  return cy + pad - y
end

function ModsPage:drawFeeds(x, y, w, h, s)
  local l = self.launcher
  local pad = math.floor(18 * s)
  Kit.card(x, y, w, h)
  local cx, cw = x + pad, w - 2 * pad
  local cy = y + pad
  cy = l:pageHeader(cx, cy, cw, s, { title = "Mod indexes",
    subtitle = "An index lists mods that live in their authors' own repos. Add only "
      .. "indexes you trust: mods run code in your game.",
    back = function() l.page = "catalog" end, backId = "feeds-back" })
  local rh = btnH(s)
  local gap = Theme.space("s", s)
  local addW = math.max(Kit.tapMin(), Kit.textWidth("small", "Add") + math.floor(32 * s))
  local ended
  self.feedDraft, ended = Kit.textfield("feed-url", cx, cy, cw - addW - gap, rh, self.feedDraft,
    "Index address or owner/repo")
  if Kit.button(cx + cw - addW, cy, addW, rh, "Add", { id = "feed-add", font = "small",
      kind = "primary" }) or ended == "submit" then
    local text = self.feedDraft
    l:queue(function() self:addFeed(text) end)
  end
  cy = cy + rh + gap * 2
  local okS, sources = pcall(require("src.mods.ModIndex").sources)
  sources = okS and sources or {}
  if #sources == 0 then
    cy = para("small", "No indexes yet.", cx, cy, cw, PAL.muted, gap)
    return cy + pad - y
  end
  local bw = math.max(Kit.tapMin(), Kit.textWidth("small", "Confirm") + math.floor(24 * s))
  for i, src in ipairs(sources) do
    local textW = cw - bw - gap
    Kit.text("button", Kit.ellipsize("button", tostring(src.label or src.feed), textW), cx, cy, PAL.text)
    Kit.text("micro", Kit.ellipsize("micro", tostring(src.url or src.feed), textW), cx,
      cy + Kit.textHeight("button"), PAL.muted)
    local armed = l.armedDelete == "feed:" .. tostring(src.feed)
    local builtIn = require("src.mods.ModIndex").isBuiltIn(src.feed)
    if not builtIn and Kit.button(cx + cw - bw, cy, bw, rh, armed and "Confirm" or "Remove",
        { id = "feed-remove-" .. i, font = "small", kind = "danger" }) then
      l:queue(function() self:removeFeed(src) end, true)
    end
    cy = cy + math.max(rh, Kit.textHeight("button") + Kit.textHeight("micro")) + gap
  end
  return cy + pad - y
end

return ModsPage
