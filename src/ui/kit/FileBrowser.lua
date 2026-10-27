-- Immediate-mode in-launcher File Browser for handhelds and gamepads.
-- Allows navigating directories to pick ROM files (.gb/.gbc), import save files (.sav),
-- and select mod/skin archives (.zip) without requiring host desktop GUI pickers (zenity/kdialog).

local Theme = require("src.ui.kit.Theme")
local HostShell = require("src.core.HostShell")

-- POSIX shell quoting for the ls/test commands below.  HostShell.quote is the
-- shared helper, but the launcher may run where HostShell is a minimal shim
-- (the NX gate), so fall back to the same escaping locally.
local function shQuote(path)
  if HostShell and type(HostShell.quote) == "function" then
    return HostShell.quote(path)
  end
  return "'" .. tostring(path):gsub("'", "'\\''") .. "'"
end
local PAL = Theme.PAL
local Kit = nil
local function getKit()
  if not Kit then Kit = require("src.ui.kit.Kit") end
  return Kit
end

local FileBrowser = {
  active = false,
  title = "Select File",
  mode = "rom", -- "rom", "save", "mod", "cart", "all"
  currentDir = "/",
  entries = {},
  selectedIdx = 1,
  page = 1,
  perPage = 8,
  onSelect = nil,
  onCancel = nil,
  shortcutIdx = 1,
}

local SHORTCUTS = {
  { label = "SD Card", path = "/mnt/SDCARD" },
  { label = "GB ROMs", path = "/roms/gb" },
  { label = "GBC ROMs", path = "/roms/gbc" },
  { label = "Ports", path = "/roms/ports" },
  { label = "Game Dir", path = "." },
  { label = "Storage", path = "/storage" },
  { label = "Userdata", path = "/userdata/roms" },
  { label = "Root /", path = "/" },
}

local function findSdCardRoot()
  local candidates = {
    "/mnt/SDCARD",
    "/mnt/sdcard",
    "/mnt/mmc",
    "/sdcard",
    "/roms",
    "/storage/roms",
    "/userdata/roms",
    "/storage",
    "/userdata",
  }
  for _, path in ipairs(candidates) do
    local ok, h = pcall(io.popen, string.format("test -d %s && echo \"yes\"", shQuote(path)))
    if ok and h then
      local res = h:read("*a")
      h:close()
      if res and res:match("yes") then
        return path
      end
    end
  end
  return "/"
end

local function normalizePath(p)
  if not p or p == "" then return "/" end
  p = p:gsub("\\", "/")
  if p:sub(1, 1) ~= "/" and p:sub(1, 2) ~= "./" and p:sub(1, 3) ~= "../" then
    p = "/" .. p
  end
  p = p:gsub("/+", "/")
  return p
end

local function parentDir(p)
  p = normalizePath(p)
  if p == "/" or p == "." then return "/" end
  local parent = p:match("^(.*)/[^/]+/?$")
  if not parent or parent == "" then return "/" end
  return parent
end

local function isMatchingFilter(name, isDir, mode)
  -- hidden files and folders (.cache, .config ...) are never what is wanted
  if name:sub(1, 1) == "." and mode ~= "all" then return false end
  if isDir then return true end
  local ext = name:match("%.([^.]+)$")
  if not ext then return (mode == "all") end
  ext = ext:lower()
  if mode == "rom" then
    if ext == "gb" or ext == "gbc" or ext == "gba" then return true end
    if ext == "zip" or ext == "7z" then
      local ok, RomArchive = pcall(require, "src.import.RomArchive")
      if not ok or type(RomArchive.capabilities) ~= "function" then return false end
      local okCaps, caps = pcall(RomArchive.capabilities)
      if not okCaps or type(caps) ~= "table" then return false end
      return (ext == "zip" and caps.zip) or (ext == "7z" and caps.z7) or false
    end
    return false
  elseif mode == "save" then
    -- the same set the launcher's import takes (Launcher SAVE_KIND)
    return (ext == "sav" or ext == "srm" or ext == "sa1" or ext == "dsv" or ext == "sgm"
      or ext == "lua")
  elseif mode == "box" then
    return (ext == "gci" or ext == "sav")
  elseif mode == "mod" then
    return (ext == "zip")
  elseif mode == "cart" then
    return (ext == "g1rcart")
  end
  return true
end

local function scanDirectory(dir, mode)
  dir = normalizePath(dir)
  local entries = {}

  local ok, handle = pcall(io.popen, string.format("ls -1ap %s 2>/dev/null", shQuote(dir)))
  if ok and handle then
    local output = handle:read("*a")
    handle:close()
    if output and #output > 0 then
      for line in output:gmatch("[^\r\n]+") do
        if line ~= "./" and line ~= "../" and line ~= "." and line ~= ".." then
          local isDir = (line:sub(-1) == "/")
          local cleanName = isDir and line:sub(1, -2) or line
          if isMatchingFilter(cleanName, isDir, mode) then
            table.insert(entries, {
              name = cleanName,
              isDir = isDir,
              path = (dir == "/" and "/" .. cleanName) or (dir .. "/" .. cleanName),
            })
          end
        end
      end
    end
  end

  if #entries == 0 and love and love.filesystem and love.filesystem.getDirectoryItems then
    local okFs, items = pcall(love.filesystem.getDirectoryItems, dir)
    if okFs and items then
      for _, name in ipairs(items) do
        local full = (dir == "/" and "/" .. name) or (dir .. "/" .. name)
        local info = love.filesystem.getInfo and love.filesystem.getInfo(full)
        local isDir = info and info.type == "directory"
        if isMatchingFilter(name, isDir, mode) then
          table.insert(entries, {
            name = name,
            isDir = isDir,
            path = full,
          })
        end
      end
    end
  end

  table.sort(entries, function(a, b)
    if a.isDir ~= b.isDir then
      return a.isDir
    end
    return a.name:lower() < b.name:lower()
  end)

  return entries
end

function FileBrowser.open(opts)
  opts = opts or {}
  FileBrowser.active = true
  FileBrowser.title = opts.title or "Select File"
  FileBrowser.mode = opts.mode or "rom"
  FileBrowser.onSelect = opts.onSelect
  FileBrowser.onCancel = opts.onCancel
  FileBrowser.selectedIdx = 1
  FileBrowser.page = 1

  FileBrowser.places = nil
  local initPath = opts.initialPath or FileBrowser._startDir()
  FileBrowser.currentDir = initPath
  FileBrowser.entries = scanDirectory(FileBrowser.currentDir, FileBrowser.mode)
  if #FileBrowser.entries == 0 and initPath ~= "/" then
    FileBrowser.currentDir = "/"
    FileBrowser.entries = scanDirectory(FileBrowser.currentDir, FileBrowser.mode)
  end
end

function FileBrowser.close(path)
  if not FileBrowser.active then return end
  local onSelect = FileBrowser.onSelect
  local onCancel = FileBrowser.onCancel
  FileBrowser.active = false
  FileBrowser.onSelect = nil
  FileBrowser.onCancel = nil
  if path and onSelect then
    onSelect(path)
  elseif not path and onCancel then
    onCancel()
  end
end

function FileBrowser.setDirectory(dir)
  FileBrowser.scroll, FileBrowser.followSel = 0, false
  FileBrowser.currentDir = normalizePath(dir)
  FileBrowser.entries = scanDirectory(FileBrowser.currentDir, FileBrowser.mode)
  FileBrowser.selectedIdx = 1
  FileBrowser.page = 1
end

function FileBrowser.cycleShortcut()
  FileBrowser.shortcutIdx = (FileBrowser.shortcutIdx % #SHORTCUTS) + 1
  local target = SHORTCUTS[FileBrowser.shortcutIdx]
  FileBrowser.setDirectory(target.path)
end

function FileBrowser.gamepadpressed(button)
  if not FileBrowser.active then return false end
  FileBrowser.followSel = true

  local total = #FileBrowser.entries
  local perPage = FileBrowser.perPage
  local maxPage = math.max(1, math.ceil(total / perPage))

  if button == "dpup" then
    if FileBrowser.selectedIdx > 1 then
      FileBrowser.selectedIdx = FileBrowser.selectedIdx - 1
      FileBrowser.page = math.floor((FileBrowser.selectedIdx - 1) / perPage) + 1
    end
    return true
  elseif button == "dpdown" then
    if FileBrowser.selectedIdx < total then
      FileBrowser.selectedIdx = FileBrowser.selectedIdx + 1
      FileBrowser.page = math.floor((FileBrowser.selectedIdx - 1) / perPage) + 1
    end
    return true
  elseif button == "dpleft" or button == "leftshoulder" or button == "triggerleft" or button == "lefttrigger" or button == "l2" then
    if FileBrowser.page > 1 then
      FileBrowser.page = FileBrowser.page - 1
      FileBrowser.selectedIdx = (FileBrowser.page - 1) * perPage + 1
    end
    return true
  elseif button == "dpright" or button == "rightshoulder" or button == "triggerright" or button == "righttrigger" or button == "r2" then
    if FileBrowser.page < maxPage then
      FileBrowser.page = FileBrowser.page + 1
      FileBrowser.selectedIdx = math.min(total, (FileBrowser.page - 1) * perPage + 1)
    end
    return true
  elseif button == "a" or button == "start" then
    local entry = FileBrowser.entries[FileBrowser.selectedIdx]
    if entry then
      if entry.isDir then
        FileBrowser.setDirectory(entry.path)
      else
        FileBrowser.close(entry.path)
      end
    end
    return true
  elseif button == "b" then
    if FileBrowser.currentDir ~= "/" and FileBrowser.currentDir ~= "." then
      FileBrowser.setDirectory(parentDir(FileBrowser.currentDir))
    else
      FileBrowser.close(nil)
    end
    return true
  elseif button == "x" then
    FileBrowser.cycleShortcut()
    return true
  elseif button == "back" or button == "select" then
    FileBrowser.close(nil)
    return true
  end

  return true
end

function FileBrowser.keypressed(key)
  if not FileBrowser.active then return false end
  if key == "escape" then
    FileBrowser.close(nil)
    return true
  elseif key == "up" then
    return FileBrowser.gamepadpressed("dpup")
  elseif key == "down" then
    return FileBrowser.gamepadpressed("dpdown")
  elseif key == "left" then
    return FileBrowser.gamepadpressed("dpleft")
  elseif key == "right" then
    return FileBrowser.gamepadpressed("dpright")
  elseif key == "return" then
    return FileBrowser.gamepadpressed("a")
  elseif key == "backspace" then
    return FileBrowser.gamepadpressed("b")
  end
  return false
end

-- Where a browse starts: the SD card on a handheld, the home folder on a
-- desktop (the root of the disk is never where a ROM is).
local function startDir()
  if os.getenv("HANDHELD") == "1" or os.getenv("PORTMASTER") == "1" then
    return findSdCardRoot()
  end
  local home = os.getenv("HOME") or os.getenv("USERPROFILE")
  return home and normalizePath(home) or findSdCardRoot()
end
FileBrowser._startDir = startDir

-- Quick jumps that exist on this machine, worked out once per open.
local function places()
  local out, seen = {}, {}
  local function add(label, path)
    if not path or seen[path] then return end
    local ok, h = pcall(io.popen, string.format("test -d %s && echo yes", shQuote(path)))
    local found = false
    if ok and h then found = (h:read("*a") or ""):match("yes") ~= nil; h:close() end
    if found then seen[path] = true; out[#out + 1] = { label = label, path = path } end
  end
  local home = os.getenv("HOME")
  if home then
    add("Home", home)
    add("Downloads", home .. "/Downloads")
    add("Desktop", home .. "/Desktop")
  end
  for _, sc in ipairs(SHORTCUTS) do
    if sc.path ~= "/" and sc.path ~= "." then add(sc.label, sc.path) end
  end
  return out
end

local MODE_LABEL = { rom = "ROM", save = "Save", box = "Box save", mod = "Mod", cart = "Cart", all = "File" }

function FileBrowser.draw(m)
  if not FileBrowser.active then return end

  local Kit = getKit()
  local Icons = require("src.ui.kit.Icons")
  local s = m and m.s or Kit.scale or 1
  local W = (m and m.W) or (love.graphics and love.graphics.getWidth()) or 640
  local H = (m and m.H) or (love.graphics and love.graphics.getHeight()) or 480
  FileBrowser.places = FileBrowser.places or places()

  -- the host blocks clicks for everything under the modal; the modal itself
  -- takes them
  Kit.blockClicks = false
  Theme.fill(0, 0, W, H, PAL.bg, 0.86)

  local pad = math.floor(16 * s)
  local gap = math.floor(8 * s)
  local modalW = math.floor(math.min(640 * s, W - 2 * math.floor(10 * s)))
  local modalH = math.floor(math.min(520 * s, H - 2 * math.floor(10 * s)))
  local px = math.floor((W - modalW) / 2)
  local py = math.floor((H - modalH) / 2)
  Kit.card(px, py, modalW, modalH, true)
  local cx, cw = px + pad, modalW - 2 * pad
  local cy = py + pad
  local btn = math.max(Kit.tapMin(), math.floor(32 * s))

  -- title and close
  Kit.textBold("button", Kit.ellipsize("button", FileBrowser.title, cw - btn - gap), cx,
    cy + (btn - Kit.textHeight("button")) / 2, PAL.heading)
  if Kit.button(cx + cw - btn, cy, btn, btn, "", { id = "fb-close", icon = "x", face = "bare" }) then
    FileBrowser.close(nil)
    return
  end
  cy = cy + btn + gap

  -- path with Up
  local upW = math.max(btn, Kit.textWidth("small", "Up") + math.floor(44 * s))
  if Kit.button(cx, cy, upW, btn, "Up", { id = "fb-up", icon = "arrow-up", fullLabel = true, font = "small",
      enabled = FileBrowser.currentDir ~= "/" }) then
    FileBrowser.setDirectory(parentDir(FileBrowser.currentDir))
  end
  local barX, barW = cx + upW + gap, cw - upW - gap
  Theme.fillRounded(barX, cy, barW, btn, PAL.bg, 1)
  Theme.strokeRounded(barX, cy, barW, btn, PAL.line, Theme.A.hairline, 1)
  Kit.text("small", Kit.ellipsizeLeft("small", FileBrowser.currentDir, barW - 2 * gap), barX + gap,
    cy + (btn - Kit.textHeight("small")) / 2, PAL.text)
  cy = cy + btn + gap

  -- quick places, as chips on one line (as many as fit)
  local chipH = math.max(Kit.tapMin(), math.floor(28 * s))
  local chipX = cx
  for i, pl in ipairs(FileBrowser.places) do
    local w = Kit.textWidth("micro", pl.label) + math.floor(24 * s)
    if chipX + w > cx + cw then break end
    if Kit.button(chipX, cy, w, chipH, pl.label, { id = "fb-place-" .. i, face = "chip",
        active = FileBrowser.currentDir == normalizePath(pl.path) }) then
      FileBrowser.setDirectory(pl.path)
    end
    chipX = chipX + w + gap
  end
  if #FileBrowser.places > 0 then cy = cy + chipH + gap end

  -- the listing
  local footH = btn + gap
  local listH = py + modalH - pad - footH - cy
  local rowH = math.max(Kit.tapMin(), math.floor(34 * s))
  local total = #FileBrowser.entries
  if total == 0 then
    Kit.emptyBox(cx, cy, cw, math.min(listH, rowH * 3),
      "No " .. (MODE_LABEL[FileBrowser.mode] or "matching") .. " files in this folder.")
  else
    local contentH = total * rowH
    local maxAt = Kit.scrollExtent(contentH, listH)
    -- keyboard / pad selection stays in view
    local selTop = (FileBrowser.selectedIdx - 1) * rowH
    local at = FileBrowser.scroll or 0
    if FileBrowser.followSel then
      if selTop < at then at = selTop end
      if selTop + rowH > at + listH then at = selTop + rowH - listH end
      FileBrowser.followSel = false
    end
    at = Kit.scrollInput(Kit.scrollClamp(at, maxAt), maxAt, cx, cy, cw, listH)
    FileBrowser.scroll = at
    local top = Kit.scrollBegin(cx, cy, cw, listH, at, maxAt)
    local rw = cw - (maxAt > 0 and Kit.scrollGutter(s) or 0)
    local first = math.max(1, math.floor(at / rowH) + 1)
    local last = math.min(total, first + math.ceil(listH / rowH) + 1)
    for i = first, last do
      local e = FileBrowser.entries[i]
      local ry = top + (i - 1) * rowH
      local clicked, ink = Kit.row(cx, ry, rw, rowH - 2, FileBrowser.selectedIdx == i, "fb-row-" .. i)
      local icon = math.floor(18 * s)
      local col = ink or (e.isDir and PAL.blue or PAL.text)
      Icons.draw(e.isDir and "folder" or "file", cx + gap, ry + (rowH - 2 - icon) / 2, icon, col)
      Kit.text("small", Kit.ellipsize("small", e.name, rw - icon - 3 * gap), cx + 2 * gap + icon,
        ry + (rowH - 2 - Kit.textHeight("small")) / 2, col)
      if clicked then
        FileBrowser.selectedIdx = i
        if e.isDir then FileBrowser.setDirectory(e.path) else FileBrowser.close(e.path) end
        break
      end
    end
    Kit.scrollEnd(cx, cy, cw, listH, at, maxAt, PAL.surface)
  end

  -- footer: cancel, and the pad's keys
  local fy = py + modalH - pad - btn
  local cancelW = math.max(btn, Kit.textWidth("small", "Cancel") + math.floor(32 * s))
  if Kit.button(cx + cw - cancelW, fy, cancelW, btn, "Cancel", { id = "fb-cancel", font = "small" }) then
    FileBrowser.close(nil)
    return
  end
  local hint = "A open   B up   X next place"
  if Kit.textWidth("micro", hint) < cw - cancelW - gap then
    Kit.text("micro", hint, cx, fy + (btn - Kit.textHeight("micro")) / 2, PAL.muted)
  end
end

return FileBrowser
