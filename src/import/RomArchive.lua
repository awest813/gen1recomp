local RomArchive = {}

RomArchive.MAX_ARCHIVE_BYTES = 64 * 1024 * 1024

local capsCache = {}

function RomArchive._resetForTests()
  capsCache = {}
end

function RomArchive.kind(data)
  if type(data) ~= "string" or #data < 8 then return nil end
  local head = data:sub(1, 4)
  if head == "PK\3\4" or head == "PK\5\6" then return "zip" end
  if data:sub(1, 6) == "7z\188\175\39\28" then return "7z" end
  return nil
end

local function u16(n)
  return string.char(n % 256, math.floor(n / 256) % 256)
end

local function u32(n)
  return string.char(n % 256, math.floor(n / 256) % 256,
    math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256)
end

function RomArchive._zipProbeBytes()
  local name, body = "probe", "ok"
  local localHeader = "PK\3\4" .. u16(20) .. u16(0) .. u16(0) .. u16(0)
    .. u16(0) .. u32(2044517703) .. u32(#body) .. u32(#body) .. u16(#name)
    .. u16(0) .. name .. body
  local central = "PK\1\2" .. u16(20) .. u16(20) .. u16(0) .. u16(0)
    .. u16(0) .. u16(0) .. u32(2044517703) .. u32(#body) .. u32(#body)
    .. u16(#name) .. u16(0) .. u16(0) .. u16(0) .. u16(0) .. u32(0)
    .. u32(0) .. name
  local eocd = "PK\5\6" .. u16(0) .. u16(0) .. u16(1) .. u16(1)
    .. u32(#central) .. u32(#localHeader) .. u16(0)
  return localHeader .. central .. eocd
end

local SEVENZ_PROBE_HEX =
  "377abcaf271c00044e999ef910000000000000005200000000000000f427ec00"
  .. "67656e317265636f6d702d70726f62650104060001091000070b0100010100"
  .. "0c1000080a01451423990000050111170070002e0072006f006d0070007200"
  .. "6f00620065000000190400000000140a0100332a3077cb55dd011506010020"
  .. "80a4810000"

local function sevenZProbeBytes()
  return (SEVENZ_PROBE_HEX:gsub("%x%x", function(h)
    return string.char(tonumber(h, 16))
  end))
end

local function probeFormat(fs, ext, bytes)
  local okFd, fd = pcall(fs.newFileData, bytes, "rom_probe." .. ext)
  if not okFd or not fd then return false end
  local point = "_rom_probe_" .. ext
  local okMount, mounted = pcall(fs.mount, fd, point)
  local found = false
  if okMount and mounted then
    local okList, items = pcall(fs.getDirectoryItems, point)
    found = okList and type(items) == "table" and #items > 0
  end
  pcall(fs.unmount, fd)
  return found and true or false
end

function RomArchive.capabilities(fs)
  fs = fs or (love and love.filesystem)
  if type(fs) ~= "table" or not (fs.newFileData and fs.mount
      and fs.getDirectoryItems and fs.unmount) then
    return { zip = false, z7 = false }
  end
  local cached = capsCache[fs]
  if cached then return cached end
  local caps = {
    zip = probeFormat(fs, "zip", RomArchive._zipProbeBytes()),
    z7 = probeFormat(fs, "7z", sevenZProbeBytes()),
  }
  capsCache[fs] = caps
  return caps
end

-- How many plausible entries one archive may make us inflate, and how many
-- bytes in all.  A real ROM archive holds one to a few carts; a zip of
-- hundreds of 16 MiB entries (every one of them deflating to zeros) would
-- otherwise freeze the launcher for minutes on the main thread.
RomArchive.MAX_CANDIDATE_READS = 8
RomArchive.MAX_INFLATED_BYTES = 96 * 1024 * 1024
-- An archive inside the archive is opened once; deeper nesting is refused.
RomArchive.MAX_DEPTH = 1

local function label(displayName)
  return displayName and ('"' .. tostring(displayName) .. '"') or "the archive"
end

local NESTED = { zip = true, ["7z"] = true }

local function unwrapAt(data, displayName, opts, depth)
  local fs = opts.fs or (love and love.filesystem)
  local kind = RomArchive.kind(data)
  if not kind then
    return nil, ("%s is not a .zip or .7z archive."):format(label(displayName))
  end
  local caps = RomArchive.capabilities(fs)
  if (kind == "zip" and not caps.zip) or (kind == "7z" and not caps.z7) then
    return nil, ("PK:GB cannot open .%s files on this device. Extract the "
      .. ".gb, .gbc or .gba file from it first and choose that instead."):format(kind)
  end

  local isRomName = opts.isRomName or function(name)
    return type(name) == "string" and name:lower():match("%.gb[ac]?$") ~= nil
  end
  local acceptedSize = opts.acceptedSize or function(n)
    return n == 1048576 or n == 2097152 or n == 16777216
  end

  -- every level gets its own mount point, so an inner archive never reuses
  -- the outer one's
  local mount = "_rom_pick_" .. kind .. "_" .. depth
  local fd, staged
  if fs.newFileData then
    local okFd, made = pcall(fs.newFileData, data, "rom_pick." .. kind)
    if okFd and made then
      local okMount, mounted = pcall(fs.mount, made, mount)
      if okMount and mounted then fd = made end
    end
  end
  if not fd then
    staged = "rom_pick_tmp" .. depth .. "." .. kind
    local wrote = fs.write and fs.write(staged, data)
    local okMount, mounted = false, false
    if wrote then okMount, mounted = pcall(fs.mount, staged, mount) end
    if not (okMount and mounted) then
      if fs.remove then pcall(fs.remove, staged) end
      return nil, ("%s could not be opened; it may be damaged or only partly "
        .. "downloaded. Download it again, or extract the ROM yourself and "
        .. "choose the .gb, .gbc or .gba file."):format(label(displayName))
    end
  end
  local function cleanup()
    pcall(fs.unmount, fd or staged)
    if staged and fs.remove then pcall(fs.remove, staged) end
  end

  local candidates, inner = {}, {}
  local function scan(dir)
    local okItems, items = pcall(fs.getDirectoryItems, dir)
    if not okItems or type(items) ~= "table" then return end
    for _, item in ipairs(items) do
      if item ~= "." and item ~= ".." then
        local path = dir .. "/" .. item
        local okInfo, info = pcall(fs.getInfo, path)
        if okInfo and info then
          local hidden = item:sub(1, 1) == "." or dir:find("__MACOSX", 1, true)
          if info.type == "directory" then
            if not hidden then scan(path) end
          elseif not hidden and type(info.size) == "number" then
            local ext = item:lower():match("%.([%w]+)$")
            if isRomName(item) then
              candidates[#candidates + 1] =
                { path = path, name = item, size = info.size }
            elseif ext and NESTED[ext] then
              inner[#inner + 1] = { path = path, name = item, size = info.size }
            end
          end
        end
      end
    end
  end
  scan(mount)
  table.sort(candidates, function(a, b) return a.path < b.path end)
  table.sort(inner, function(a, b) return a.path < b.path end)

  local fallback, chosen
  local reads, inflated, capped = 0, 0, false
  for _, cand in ipairs(candidates) do
    if acceptedSize(cand.size) then
      if reads >= RomArchive.MAX_CANDIDATE_READS
          or inflated + cand.size > RomArchive.MAX_INFLATED_BYTES then
        capped = true
        break
      end
      reads, inflated = reads + 1, inflated + cand.size
      local okRead, bytes = pcall(fs.read, cand.path)
      if okRead and type(bytes) == "string" and #bytes == cand.size then
        local pick = { bytes = bytes, name = cand.name }
        fallback = fallback or pick
        if not opts.prefer then break end
        local okPref, hit = pcall(opts.prefer, bytes)
        if okPref and hit then chosen = pick break end
      end
    end
  end

  -- No ROM at this level: open the first inner archive that fits.
  if not fallback and #inner > 0 and depth < RomArchive.MAX_DEPTH
      and inner[1].size <= RomArchive.MAX_ARCHIVE_BYTES then
    local nested = inner[1]
    local okRead, bytes = pcall(fs.read, nested.path)
    cleanup()
    if okRead and type(bytes) == "string" and #bytes == nested.size then
      local romBytes, entry = unwrapAt(bytes, nested.name, opts, depth + 1)
      if romBytes then return romBytes, nested.name .. " / " .. entry end
      return nil, entry
    end
    return nil, ("%s inside %s could not be read. Extract it yourself and "
      .. "choose the ROM inside."):format(label(nested.name), label(displayName))
  end
  cleanup()

  -- Stopped early with no entry preferred: the first one read is a guess,
  -- not an answer, among that many.
  if capped and not chosen and opts.prefer then fallback = nil end
  chosen = chosen or fallback
  if chosen then return chosen.bytes, chosen.name end

  if #candidates == 0 then
    if #inner > 0 then
      return nil, ("%s holds another archive (%s) inside it. Extract that "
        .. "and choose the .gb, .gbc or .gba file inside.")
        :format(label(displayName), inner[1].name)
    end
    return nil, ("There is no .gb, .gbc or .gba file inside %s. Choose the "
      .. "archive that holds your ROM, or the ROM file itself.")
      :format(label(displayName))
  end
  if capped then
    return nil, ("%s holds too many large files to check them all. Extract "
      .. "your ROM from it and choose the .gb, .gbc or .gba file directly.")
      :format(label(displayName))
  end
  local fmt = opts.formatBytes or function(n) return n .. " bytes" end
  local sizes = {}
  for i, cand in ipairs(candidates) do
    if i > 4 then sizes[#sizes + 1] = "..." break end
    sizes[#sizes + 1] = ("%s is %s"):format(cand.name, fmt(cand.size))
  end
  return nil, ("The ROM inside %s is not a complete cartridge dump (%s). A "
    .. "Game Boy ROM is 1 MB, a Game Boy Color ROM 2 MB and a Game Boy "
    .. "Advance ROM 16 MB; dump your cartridge again.")
    :format(label(displayName), table.concat(sizes, ", "))
end

-- The ROM bytes inside a .zip or .7z plus that entry's name, or nil plus a
-- sentence a player can act on.  opts:
--   isRomName(name)    which entries are ROMs (default .gb/.gbc/.gba)
--   acceptedSize(n)    which entry sizes are worth reading
--   prefer(bytes)      true for the entry to pick among several
--   formatBytes(n)     size wording for the error message
--   fs                 a love.filesystem-like table (tests)
function RomArchive.unwrap(data, displayName, opts)
  return unwrapAt(data, displayName, opts or {}, 0)
end

return RomArchive
