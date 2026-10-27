-- What a file that failed ROM verification most likely is, in words a player
-- can act on.  ImportJob.verify accepts a ROM only by its SHA-1; this module
-- runs after that check has already failed, reads the cartridge header and
-- explains the mismatch: not a ROM at all, a save file, another game, another
-- language, an incomplete download, or a modified/damaged copy of a game PK:GB
-- does support.
--
-- Header layouts: Game Boy (Pan Docs, "The Cartridge Header", $0104-$014F)
-- and Game Boy Advance (GBATEK, "GBA Cartridge Header", $00-$BF).  Pure Lua
-- with no requires, so it runs under the test harness without LÖVE.

local RomIdentify = {}

local GB_LOGO = "\206\237\102\102\204\013\000\011" -- $0104, first 8 bytes
local GBA_LOGO = "\036\255\174\081\105\154\162\033" -- $04, first 8 bytes

-- Header title (Gen 1 / Gen 2) or 3-letter game code (Gen 3) -> game id.
local GB_TITLES = {
  { "POKEMON RED", "red" }, { "POKEMON BLUE", "blue" },
  { "POKEMON YELLOW", "yellow" }, { "POKEMON GREEN", "green" },
  { "POKEMON_GLD", "gold" }, { "POKEMON_SLV", "silver" },
  { "PM_CRYSTAL", "crystal" },
}
local GBA_CODES = {
  BPR = "firered", BPG = "leafgreen", BPE = "emerald",
  AXV = "ruby", AXP = "sapphire",
}
local NAMES = {
  red = "Pokémon Red", blue = "Pokémon Blue", yellow = "Pokémon Yellow",
  green = "Pokémon Green", gold = "Pokémon Gold", silver = "Pokémon Silver",
  crystal = "Pokémon Crystal", firered = "Pokémon FireRed",
  leafgreen = "Pokémon LeafGreen", emerald = "Pokémon Emerald",
  ruby = "Pokémon Ruby", sapphire = "Pokémon Sapphire",
}
-- Last letter of a Gen 2 / GBA product code.
local LANGUAGES = {
  J = "Japanese", D = "German", F = "French", I = "Italian", S = "Spanish",
  K = "Korean", C = "Chinese",
}

RomIdentify.ROM_SIZES = { 1048576, 2097152, 16777216 }

-- Battery save sizes: 8 KiB/32 KiB SRAM, 64/128 KiB flash, emulator saves
-- with an RTC footer (+44 / +48 bytes) or a 16-byte header.
local SAVE_SIZES = {}
for _, base in ipairs({ 8192, 32768, 65536, 131072 }) do
  for _, extra in ipairs({ 0, 16, 44, 48 }) do SAVE_SIZES[base + extra] = true end
end
local SAVE_EXT = { sav = true, srm = true, sa1 = true, dsv = true, sgm = true,
  ss0 = true, ss1 = true, st0 = true, ["state"] = true }

function RomIdentify.formatBytes(n)
  if n >= 1048576 and n % 1048576 == 0 then return ("%d MiB"):format(n / 1048576) end
  if n >= 1024 and n % 1024 == 0 then return ("%d KiB"):format(n / 1024) end
  local s = tostring(math.floor(n))
  local grouped = s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
  return grouped .. (n == 1 and " byte" or " bytes")
end

local function trimTitle(raw)
  return (raw:gsub("%z.*$", ""):gsub("[^\32-\126]", ""):gsub("%s+$", ""))
end

-- Sum of every byte but the two checksum bytes, mod 2^16 ($014E-$014F).
local function gbGlobalChecksumOk(data)
  local sum, n = 0, #data
  local byte = string.byte
  local i = 1
  while i + 7 <= n do
    local a, b, c, d, e, f, g, h = byte(data, i, i + 7)
    sum = sum + a + b + c + d + e + f + g + h
    i = i + 8
  end
  while i <= n do sum = sum + byte(data, i); i = i + 1 end
  local hi, lo = byte(data, 0x14F), byte(data, 0x150)
  sum = (sum - hi - lo) % 65536
  return sum == hi * 256 + lo
end

-- Header checksum over $0134-$014C (Pan Docs: x = x - byte - 1).
local function gbHeaderChecksumOk(data)
  local x = 0
  for i = 0x135, 0x14D do x = (x - data:byte(i) - 1) % 256 end
  return x == data:byte(0x14E)
end

-- Complement check over $A0-$BC (GBATEK).
local function gbaHeaderOk(data)
  local sum = 0
  for i = 0xA1, 0xBD do sum = sum + data:byte(i) end
  return (-(sum + 0x19)) % 256 == data:byte(0xBE)
end

-- Read the header.  Returns a table:
--   platform  "gb" / "gba" / nil (no Nintendo logo: not a ROM)
--   title     header title, trimmed
--   game      a Pokémon game id from GB_TITLES / GBA_CODES, or nil
--   language  "Japanese", "German", ... when the header names a non-English
--             release, else nil
--   romBytes  the size the GB header declares ($0148), when it is valid
--   headerOk  the header's own checksum passes
function RomIdentify.header(data)
  local info = { size = #data }
  if #data >= 0x150 and data:sub(0x105, 0x10C) == GB_LOGO then
    info.platform = "gb"
    -- A Color-aware cart ($0143 bit 7) may end its title with a 4-letter
    -- manufacturer code ("POKEMON_GLD" + "AAUE"); Yellow sets the bit too but
    -- spells its whole title out, which the code pattern then rejects.
    local cgb = data:byte(0x144) >= 0x80
    local title = trimTitle(data:sub(0x135, cgb and 0x143 or 0x144))
    local code = cgb and data:sub(0x140, 0x143)
    if code and code:match("^%u%u%u%u$") then
      title = trimTitle(title:sub(1, 11))
      info.code = code
      info.language = LANGUAGES[code:sub(4)]
    end
    info.title = title
    for _, row in ipairs(GB_TITLES) do
      if title:sub(1, #row[1]) == row[1] then info.game = row[2] break end
    end
    if not info.language and data:byte(0x14B) == 0 then info.language = "Japanese" end
    local sizeCode = data:byte(0x149)
    if sizeCode <= 8 then info.romBytes = 32768 * 2 ^ sizeCode end
    info.headerOk = gbHeaderChecksumOk(data)
  elseif #data >= 0xC0 and data:sub(5, 12) == GBA_LOGO and data:byte(0xB3) == 0x96 then
    info.platform = "gba"
    info.title = trimTitle(data:sub(0xA1, 0xAC))
    local code = data:sub(0xAD, 0xB0)
    info.code = code
    info.game = GBA_CODES[code:sub(1, 3)]
    info.language = LANGUAGES[code:sub(4)]
    info.headerOk = gbaHeaderOk(data)
  end
  return info
end

local function gameName(info)
  return NAMES[info.game] or ('"' .. tostring(info.title) .. '"')
end

-- Whether `data` (with `name`) looks like a battery or emulator save.
function RomIdentify.looksLikeSave(data, name)
  local ext = type(name) == "string" and name:lower():match("%.([%w]+)$")
  if ext and SAVE_EXT[ext] then return true end
  return SAVE_SIZES[#data] == true and RomIdentify.header(data).platform == nil
end

local CHOOSE = "Choose an unmodified dump of your own cartridge"

-- One or two sentences explaining why `data` did not verify.  `sha1` (hex)
-- is appended for the cases a support request would need it.  `opts`:
--   supported(gameId) -> true when PK:GB offers that game (hides the rest)
function RomIdentify.explain(data, name, sha1, opts)
  opts = opts or {}
  if type(data) ~= "string" or #data == 0 then
    return "That file is empty. Choose your .gb, .gbc or .gba ROM file instead."
  end
  if RomIdentify.looksLikeSave(data, name) then
    return "That is a save file, not a game ROM. Import the game's ROM "
      .. "(.gb, .gbc or .gba) first; your save can be added after that."
  end
  local info = RomIdentify.header(data)
  if not info.platform then
    return "That file is not a Game Boy, Game Boy Color or Game Boy Advance "
      .. "ROM. Choose the .gb, .gbc or .gba file dumped from your cartridge."
  end
  local supported = info.game and (not opts.supported or opts.supported(info.game))
  if not supported then
    if info.game then
      return ("%s is not supported by this version of PK:GB."):format(gameName(info))
    end
    return ("That is a ROM of another game (%s), not a Pokémon game PK:GB "
      .. "supports. Choose your Pokémon ROM instead."):format(gameName(info))
  end
  local game = gameName(info)
  if info.language then
    return ("That is the %s release of %s. PK:GB needs the English "
      .. "(US) release of the game."):format(info.language, game)
  end
  local expected = info.platform == "gb" and info.romBytes or 16777216
  if expected and #data < expected then
    return ("That %s ROM is incomplete: it is %s, but the cartridge holds %s. "
      .. "The download or dump was cut short; dump your cartridge again.")
      :format(game, RomIdentify.formatBytes(#data), RomIdentify.formatBytes(expected))
  end
  local damaged = not info.headerOk
    or (info.platform == "gb" and #data >= 0x150 and not gbGlobalChecksumOk(data))
  local hash = sha1 and (" (SHA-1 " .. sha1 .. ")") or ""
  if damaged then
    return ("That %s ROM is damaged or has been modified: its checksum is "
      .. "wrong. %s, or dump it again.%s"):format(game, CHOOSE, hash)
  end
  return ("That %s ROM does not match the original English release: it is a "
    .. "ROM hack, a patched or translated copy, or a revision PK:GB does not "
    .. "know. %s.%s"):format(game, CHOOSE, hash)
end

-- Why a file of `size` bytes cannot be a ROM, for files that fail before any
-- hashing.  `data` may be nil.
function RomIdentify.explainSize(size, data, name)
  if data and size > 0 and RomIdentify.looksLikeSave(data, name) then
    return RomIdentify.explain(data, name)
  end
  if data and size > 0 then
    local info = RomIdentify.header(data)
    if info.platform and info.game then
      local expected = info.platform == "gb" and info.romBytes or 16777216
      if expected and size < expected then
        return RomIdentify.explain(data, name)
      end
    end
    if not info.platform then
      return ("That file (%s) is not a Game Boy, Game Boy Color or Game Boy "
        .. "Advance ROM; those are 1 MiB, 2 MiB and 16 MiB. Choose the .gb, "
        .. ".gbc or .gba file dumped from your cartridge.")
        :format(RomIdentify.formatBytes(size))
    end
  end
  return ("That file is %s, which is not the size of any Pokémon cartridge "
    .. "(Game Boy ROMs are 1 MiB, Game Boy Color 2 MiB, Game Boy Advance "
    .. "16 MiB). It may be incomplete or not a ROM; dump your cartridge "
    .. "again."):format(RomIdentify.formatBytes(size))
end

return RomIdentify
