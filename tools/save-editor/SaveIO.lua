local SaveData = require("src.core.SaveData")

local SaveIO = {}

local function join(a, b)
  if a:sub(-1) == "/" or a:sub(-1) == "\\" then return a .. b end
  local sep = package.config:sub(1, 1)
  return a .. sep .. b
end

local function trim(value)
  return value and value:gsub("^%s+", ""):gsub("%s+$", "") or ""
end

local function commandOutput(command)
  local pipe = io.popen(command, "r")
  if not pipe then return nil end
  local result = pipe:read("*a")
  pipe:close()
  result = trim(result)
  return result ~= "" and result or nil
end

function SaveIO.defaultPath()
  -- same override conf.lua honors, so a mod-dev profile edits the save it
  -- actually plays
  local identity = os.getenv("POKEPORT_IDENTITY") or "pokemon-love2d"
  local home = os.getenv("HOME") or os.getenv("USERPROFILE") or ""
  local uname = io.popen and io.popen("uname -s 2>/dev/null")
  local sys = uname and uname:read("*l") or ""
  if uname then uname:close() end
  if sys == "Darwin" then
    -- LÖVE identity folder lives under Application Support/LOVE/
    return join(join(join(join(home, "Library"), "Application Support"), "LOVE"),
                join(identity, "save.lua"))
  end
  -- Linux LOVE default
  if home ~= "" and sys ~= "" then
    return join(join(join(home, ".local/share"), "love"),
                join(identity, "save.lua"))
  end
  -- Windows
  local appdata = os.getenv("APPDATA")
  if appdata then
    return join(join(appdata, "love"), join(identity, "save.lua"))
  end
  return join(identity, "save.lua")
end

-- Native file picker (same approach as src/core/FilePicker.lua). Returns an absolute
-- path, or nil if the user cancelled / no dialog is available.
function SaveIO.choosePath()
  local platform = (love and love.system and love.system.getOS
                    and love.system.getOS()) or ""
  if platform == "OS X" then
    return commandOutput(
      [[osascript -e 'POSIX path of (choose file with prompt "Choose a Pokemon save.lua")' 2>/dev/null]])
  elseif platform == "Windows" then
    local script = table.concat({
      "Add-Type -AssemblyName System.Windows.Forms;",
      "$o=New-Object System.Windows.Forms.Form;",
      "$o.TopMost=$true;",
      "$o.ShowInTaskbar=$false;",
      "$d=New-Object System.Windows.Forms.OpenFileDialog;",
      "$d.Title='Choose a Pokemon save.lua';",
      "$d.Filter='Save files (*.lua)|*.lua|All files (*.*)|*.*';",
      "if($d.ShowDialog($o) -eq 'OK'){[Console]::Write($d.FileName)}",
    })
    return commandOutput(
      'powershell -NoProfile -STA -Command "' .. script .. '"')
  elseif platform == "Linux" then
    local path = commandOutput(
      [[zenity --file-selection --title="Choose a Pokemon save.lua" --file-filter="Lua save | *.lua" 2>/dev/null]])
    if path then return path end
    return commandOutput(
      [[kdialog --getopenfilename "$HOME" "*.lua|Lua save" 2>/dev/null]])
  end
  return nil
end

local function readFile(path)
  local f, err = io.open(path, "rb")
  if not f then return nil, err end
  local body = f:read("*a")
  f:close()
  return body
end
SaveIO.readFile = readFile

-- One per save, never reused: two saves in the same second kept only the
-- second, which overwrote the copy from before any edit.
function SaveIO.backupPath(path)
  local base = path .. ".bak-" .. os.date("%Y%m%d-%H%M%S")
  local candidate, n = base, 1
  while true do
    local f = io.open(candidate, "rb")
    if not f then return candidate end
    f:close()
    n = n + 1
    candidate = base .. "-" .. n
  end
end

-- The game's own copies beside a save (src/core/SaveData.lua slotNames):
-- it stages a write in .tmp and keeps the last good save in .bak, and
-- loads them, in that order, when the main file is missing or corrupt.
SaveIO.GAME_RECOVERY = { ".tmp", ".bak" }
-- The editor's own staging file: never the game's .tmp, which may be the
-- only copy of the progress.
SaveIO.EDIT_TMP = ".editor-tmp"

-- Returns save, err, recoveredFrom (".tmp" / ".bak" when the main file
-- was missing or corrupt, as the game would), and the main file's bytes
-- as read (nil when there was none) for SaveIO.changedOnDisk.
function SaveIO.load(path)
  local body, err = readFile(path)
  if body then
    local save, derr = SaveData.decode(body)
    if type(save) == "table" then return save, nil, nil, body end
    err = derr or "the file could not be read"
  end
  for _, suffix in ipairs(SaveIO.GAME_RECOVERY) do
    local copy = readFile(path .. suffix)
    local save = copy and SaveData.decode(copy)
    if type(save) == "table" then return save, nil, suffix, body end
  end
  return nil, err, nil, body
end

-- Whether the main file is no longer what was loaded (the game or a sync
-- wrote it since): saving then would replace that progress.
function SaveIO.changedOnDisk(path, loadedBody)
  return readFile(path) ~= loadedBody
end

function SaveIO.save(path, data)
  local encoded = SaveData.encode(data)
  local existing = io.open(path, "rb")
  if existing then
    local prev = existing:read("*a")
    existing:close()
    local bak = SaveIO.backupPath(path)
    local bf, berr = io.open(bak, "wb")
    if not bf then return false, berr end
    local bwok, bwerr = bf:write(prev)
    if not bwok then
      bf:close()
      os.remove(bak)
      return false, bwerr
    end
    local bcok, bcerr = bf:close()
    if not bcok then
      os.remove(bak)
      return false, bcerr
    end
  end
  local tmp = path .. SaveIO.EDIT_TMP
  local f, err = io.open(tmp, "wb")
  if not f then return false, err end
  local wok, werr = f:write(encoded)
  if not wok then
    f:close()
    os.remove(tmp)
    return false, werr
  end
  local cok, cerr = f:close()
  if not cok then
    os.remove(tmp)
    return false, cerr
  end
  local ok, rerr = os.rename(tmp, path)
  if not ok and existing then
    -- Windows will not rename onto a file: move it aside (not delete it),
    -- and put it back if the new one still will not go in
    local aside = path .. ".editor-old"
    os.remove(aside)
    if os.rename(path, aside) then
      ok, rerr = os.rename(tmp, path)
      if ok then os.remove(aside) else os.rename(aside, path) end
    end
  end
  if not ok then
    os.remove(tmp)
    return false, tostring(rerr)
  end
  return true
end

return SaveIO
