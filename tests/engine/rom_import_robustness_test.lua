-- ROM import robustness: what a player sees for the wrong file, and what
-- the import does when it is interrupted, re-run or run twice.  Headless,
-- ROM-free: every "ROM" here is a synthetic header.  No pokered cite:
-- port-only import plumbing (src/import/ImportJob.lua, RomIdentify.lua,
-- RomArchive.lua, CacheFs.lua, src/core/FilePicker.lua).
--   luajit tests/engine/rom_import_robustness_test.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
love = love or require("tests.love_stub")

local T = require("tests.harness")
local check, eq = T.check, T.eq

local GameVersion = require("src.core.GameVersion")
local RomIdentify = require("src.import.RomIdentify")

-- A sentence for a player: no Lua location, no traceback, ends in a full stop.
local function playerSentence(text, what)
  text = tostring(text)
  check(not text:find("%.lua:%d+"), what .. " names no Lua file: " .. text)
  check(not text:find("traceback", 1, true), what .. " has no traceback: " .. text)
  check(text:match("[%.%)]$") ~= nil, what .. " is a finished sentence: " .. text)
end

-- ------------------------------------------------------- synthetic ROMs

local GB_LOGO = "\206\237\102\102\204\013\000\011"

local function bytesAt(image, at, s)
  return image:sub(1, at) .. s .. image:sub(at + #s + 1)
end

-- A Game Boy image with a valid header and global checksum.
local function gbRom(title, opts)
  opts = opts or {}
  local size = opts.size or 1048576
  local img = string.rep("\0", size)
  img = bytesAt(img, 0x104, GB_LOGO)
  local t = title .. string.rep("\0", 15 - #title)
  img = bytesAt(img, 0x134, t:sub(1, 15))
  img = bytesAt(img, 0x143, string.char(opts.cgb or 0))
  img = bytesAt(img, 0x148, string.char(opts.sizeCode or 5))
  img = bytesAt(img, 0x14A, string.char(opts.destination or 1))
  local x = 0
  for i = 0x135, 0x14D do x = (x - img:byte(i) - 1) % 256 end
  img = bytesAt(img, 0x14D, string.char(x))
  local sum = 0
  for i = 1, #img do sum = sum + img:byte(i) end
  sum = sum % 65536
  img = bytesAt(img, 0x14E, string.char(math.floor(sum / 256), sum % 256))
  -- the two checksum bytes are not part of their own sum, so writing them
  -- does not change it
  return img
end

local function gbaRom(code)
  local img = string.rep("\0", 0xC0)
  img = bytesAt(img, 0x04, "\036\255\174\081\105\154\162\033")
  img = bytesAt(img, 0xA0, "POKEMON FIRE")
  img = bytesAt(img, 0xAC, code)
  img = bytesAt(img, 0xB2, "\150")
  local sum = 0
  for i = 0xA1, 0xBD do sum = sum + img:byte(i) end
  img = bytesAt(img, 0xBD, string.char((-(sum + 0x19)) % 256))
  return img .. string.rep("\0", 16777216 - #img)
end

-- ------------------------------------------------------- RomIdentify

eq(RomIdentify.formatBytes(1048576), "1 MiB", "whole MiB")
eq(RomIdentify.formatBytes(524288), "512 KiB", "whole KiB")
eq(RomIdentify.formatBytes(1048575), "1,048,575 bytes", "odd sizes in bytes")

local yellow = gbRom("POKEMON YELLOW", { cgb = 0x80 })
local info = RomIdentify.header(yellow)
eq(info.platform, "gb", "the Nintendo logo makes it a Game Boy ROM")
eq(info.game, "yellow", "Yellow's full title survives its Color flag")
check(info.headerOk, "the synthetic header checksum passes")

local why = RomIdentify.explain(yellow, "y.gb", "abc")
check(why:find("does not match the original English release", 1, true) ~= nil,
  "a clean-checksum Yellow that fails the SHA-1 is a hack or revision: " .. why)
check(why:find("SHA-1 abc", 1, true) ~= nil, "and names its SHA-1 for support")
playerSentence(why, "the hack message")

local damaged = bytesAt(yellow, 0x40000, "\1")
why = RomIdentify.explain(damaged, "y.gb")
check(why:find("damaged or has been modified", 1, true) ~= nil,
  "a broken global checksum reads as damaged: " .. why)

why = RomIdentify.explain(gbRom("POKEMON RED", { destination = 0 }), "r.gb")
check(why:find("Japanese release of Pokémon Red", 1, true) ~= nil,
  "a Japan-destination header names the language: " .. why)

why = RomIdentify.explain(gbRom("POKEMON_GLDAAUJ", { cgb = 0x80, sizeCode = 6, size = 2097152 }), "g.gbc")
check(why:find("Japanese release of Pokémon Gold", 1, true) ~= nil,
  "a Gen 2 product code names the language: " .. why)

why = RomIdentify.explain(gbRom("TETRIS"), "t.gb")
check(why:find('another game ("TETRIS")', 1, true) ~= nil, "another game is named: " .. why)

why = RomIdentify.explain(gbRom("POKEMON GREEN"), "g.gb", nil,
  { supported = function(game) return GameVersion.VERSIONS[game] ~= nil end })
check(why:find("Pokémon Green is not supported", 1, true) ~= nil,
  "a Pokémon game PK:GB lacks says so: " .. why)

why = RomIdentify.explain(string.rep("x", 1048576), "x.gb")
check(why:find("not a Game Boy", 1, true) ~= nil, "no logo, no ROM: " .. why)

why = RomIdentify.explainSize(524288, yellow:sub(1, 524288), "y.gb")
check(why:find("incomplete: it is 512 KiB, but the cartridge holds 1 MiB", 1, true) ~= nil,
  "a truncated dump is called incomplete with both sizes: " .. why)

why = RomIdentify.explainSize(32768, string.rep("\0", 32768), "game.sav")
check(why:find("save file", 1, true) ~= nil, "a .sav is recognised as a save: " .. why)
why = RomIdentify.explainSize(32768, string.rep("\255", 32768), "game.gb")
check(why:find("save file", 1, true) ~= nil, "so is a 32 KiB SRAM image named .gb: " .. why)

why = RomIdentify.explainSize(9, "not a rom", "notes.txt")
check(why:find("MiB", 1, true) ~= nil and why:find("9 bytes", 1, true) ~= nil,
  "a tiny file gets its size and the real sizes: " .. why)

local fr = gbaRom("BPRE")
info = RomIdentify.header(fr)
eq(info.platform, "gba", "the GBA logo and fixed byte make it a GBA ROM")
eq(info.game, "firered", "BPR is FireRed")
check(info.headerOk, "the complement check passes")
why = RomIdentify.explain(gbaRom("BPRJ"), "f.gba")
check(why:find("Japanese release of Pokémon FireRed", 1, true) ~= nil, "BPRJ is Japanese: " .. why)
why = RomIdentify.explainSize(15 * 1048576, fr:sub(1, 15 * 1048576), "f.gba")
check(why:find("incomplete: it is 15 MiB", 1, true) ~= nil, "a short GBA dump is incomplete: " .. why)

-- ------------------------------------------------------- ImportJob.verify

-- SHA-1 stand-in: "red" for exactly the image registered as Red's.
local RED_IMAGE = gbRom("POKEMON RED")
love.data = {
  hash = function(_, data) return { data = data } end,
  encode = function(_, _, digest)
    if digest.data == RED_IMAGE then return GameVersion.info("red").sha1 end
    return ("%040x"):format(#digest.data)
  end,
}
local ImportJob = require("src.import.ImportJob")

local rom = ImportJob.verify(RED_IMAGE, "red.gb")
eq(rom and rom.version, "red", "a clean image verifies")
eq(rom and rom.note, nil, "with nothing to report")

rom, why = ImportJob.verify(string.rep("\0", 512) .. RED_IMAGE, "red.gb")
eq(rom and rom.version, "red", "a copier-headered dump verifies once the header is cut: " .. tostring(why))
eq(rom and #rom.data, 1048576, "and imports the bare cartridge")
check(rom and rom.note and rom.note:find("header", 1, true), "with a note saying so")

rom, why = ImportJob.verify(RED_IMAGE .. RED_IMAGE, "red.gb")
eq(rom and rom.version, "red", "a mirrored 2 MiB overdump verifies as its first 1 MiB: " .. tostring(why))
rom = ImportJob.verify(RED_IMAGE .. string.rep("\255", 3 * 1048576), "red.gb")
eq(rom and rom.version, "red", "so does a 4 MiB 0xFF-padded one")

rom, why = ImportJob.verify(RED_IMAGE:sub(1, 1047552), "red.gb")
eq(rom, nil, "1 KiB short is refused")
check(why:find("incomplete", 1, true) ~= nil and why:find("1023 KiB", 1, true) ~= nil,
  "as an incomplete Pokémon Red, not as '1.00 MiB is not 1 MiB': " .. why)
playerSentence(why, "the short-dump message")

rom, why = ImportJob.verify(bytesAt(RED_IMAGE, 0x150, "HACK"), "hack.gb")
eq(rom, nil, "a modified Red is refused")
check(why:find("Pokémon Red", 1, true) ~= nil, "naming the game it was: " .. why)
playerSentence(why, "the modified-ROM message")

rom, why = ImportJob.verify("", "empty.gb")
eq(rom, nil, "an empty file is refused")
playerSentence(why, "the empty-file message")
rom, why = ImportJob.verify(nil, "x.gb")
eq(rom, nil, "an unread file is refused")
playerSentence(why, "the unreadable-file message")

-- ------------------------------------------------------- errors

local cases = {
  { "Could not write file: No space left on device", "not enough free disk space" },
  { "src/import/RomExtractorGen2.lua:812: could not write gold/x.png: disk full", "not enough free disk space" },
  { "Permission denied", "not allowed to write" },
  { "could not write data/generated/gba/x.rgba: Could not open file", "could not save" },
  { "src/import/gba/pokemon_extract.lua:77: attempt to index a nil value", "attempt to index a nil value" },
  { "Parallel extraction error:\naux: src/import/gba/x.lua:9: bad pointer", "bad pointer" },
}
for _, case in ipairs(cases) do
  local text = ImportJob.explainFailure(case[1], "Pokémon Gold")
  check(text:find(case[2], 1, true) ~= nil, ("%q explains as %q: %s"):format(case[1], case[2], text))
  playerSentence(text, "the failure for " .. case[1])
end

-- ------------------------------------------------------- progress text

eq(ImportJob.stageText("Finalizing pokemon_gfx"), nil, "a worker finishing never reaches the player")
eq(ImportJob.stageText("Audio & Intro Ready"), nil, "nor do bookkeeping steps")
eq(ImportJob.stageText("World Maps: tilesets (3/20)"), "World maps: tilesets (3/20)", "map stages keep their counter")
eq(ImportJob.stageText("Scripts & OW: trainers_map_tree"), "Scripts and characters", "OW is spelled out")
eq(ImportJob.stageText("Game Data: region_map"), "Region map", "snake_case is tidied")
eq(ImportJob.stageText("Maps"), "Maps", "plain names pass through")

local clock = 0
local realGetTime = love.timer.getTime
love.timer.getTime = function() return clock end
local job = setmetatable({ progress = 0, timings = {} }, ImportJob)
job:_progress(0.5, "Pokemon")
job:_progress(0.3, "Finalizing aux")
eq(job.progress, 0.5, "progress never moves backwards when parallel tasks report out of order")
eq(job.stage, "Pokemon", "and a task finishing keeps the caption that is up")
clock = 0.1
job:_progress(0.55, "Game Data: Teachy TV")
eq(job.stage, "Pokemon", "a caption from another task waits out the hold instead of flickering")
job:_progress(0.56, "Pokemon (3/10)")
eq(job.stage, "Pokemon (3/10)", "the same stage's counter still moves")
clock = 1
job:_progress(0.6, "Game Data: Teachy TV")
eq(job.stage, "Teachy TV", "after the hold the newest stage shows")
love.timer.getTime = realGetTime

-- ------------------------------------------------------- the import itself

-- A recording CacheFs and a scripted extractor stand in for the real ones.
local calls = {}
local fakeFs = { prefix = "", files = {} }
function fakeFs.remove(rel) calls[#calls + 1] = "remove " .. fakeFs.prefix .. rel; fakeFs.files[fakeFs.prefix .. rel] = nil end
function fakeFs.clearTree(rel) calls[#calls + 1] = "clear " .. fakeFs.prefix .. rel end
function fakeFs.removeTree() error("clearTree must be preferred") end
function fakeFs.read(rel) return fakeFs.files[fakeFs.prefix .. rel] end
function fakeFs.write(rel, data) fakeFs.files[fakeFs.prefix .. rel] = data return true end
package.loaded["src.import.CacheFs"] = fakeFs
package.loaded["src.import.RomManifest"] = { decode = function() return {} end }
local seenPrefix = {}
local Extractor = {
  new = function(_, _, progress)
    return { run = function()
      for i = 1, 3 do
        seenPrefix[#seenPrefix + 1] = fakeFs.prefix
        progress(i, 3, "Stage " .. i)
      end
    end }
  end,
}
package.loaded["src.import.RomExtractor"] = Extractor
package.loaded["src.import.RomExtractorGen2"] = Extractor
local CacheContract = require("src.import.CacheContract")
local realPublish = CacheContract.publish
CacheContract.publish = function() return true end

local realGetenv = os.getenv
os.getenv = function(k) -- luacheck: ignore 122
  if k == "POKEPORT_NO_THREAD" then return "1" end return realGetenv(k) end

local function verified(version)
  return { version = version, sha1 = GameVersion.info(version).sha1, data = "bytes" }
end

-- 1. the marker goes before the trees (an import killed mid-clear must not
--    leave a "complete" cache behind), and both trees are really cleared
calls = {}
local a = ImportJob.start(verified("red"))
eq(a.state, "working", "an import starts: " .. tostring(a.error))
local markerAt, dataAt
for i, c in ipairs(calls) do
  if c == "remove red/" .. CacheContract.MARKER_PATH then markerAt = markerAt or i end
  if c == "clear red/data/generated" then dataAt = i end
end
check(markerAt and dataAt and markerAt < dataAt, "the completion marker is removed before the old trees")
check(fakeFs.files["red/" .. ImportJob.LOCK_PATH] ~= nil, "a running import holds its lock")

-- 2. the same game twice is refused with a sentence, not a corrupted cache
local twin = ImportJob.start(verified("red"))
eq(twin.state, "error", "a second import of the same game is refused")
playerSentence(twin.error, "the duplicate-import message")
eq(a.state, "working", "and the first keeps going")

-- 3. two coroutine imports of different games interleave without crossing
--    cache folders, and the frame between steps sees the caller's prefix
fakeFs.prefix = "caller/"
local b = ImportJob.start(verified("gold"))
eq(b.state, "working", "a different game may import alongside")
for _ = 1, 10 do
  a:step(0)
  eq(fakeFs.prefix, "caller/", "between steps the caller's prefix is back")
  b:step(0)
  if a.state ~= "working" and b.state ~= "working" then break end
end
eq(a.state, "done", "the first import finishes: " .. tostring(a.error))
eq(b.state, "done", "the second import finishes: " .. tostring(b.error))
local crossed = false
for _, p in ipairs(seenPrefix) do
  if p ~= "red/" and p ~= "gold/" then crossed = true end
end
check(not crossed and #seenPrefix == 6, "each extractor only ever wrote under its own game")
eq(fakeFs.files["red/" .. ImportJob.LOCK_PATH], nil, "a finished import drops its lock")
fakeFs.prefix = ""

-- 4. another window's live lock refuses; a crashed window's stale one does not
fakeFs.files["gold/" .. ImportJob.LOCK_PATH] = tostring(os.time()) .. "\n"
local locked = ImportJob.start(verified("gold"))
eq(locked.state, "error", "a fresh lock from another process refuses the import")
check(locked.error:find("Another PK:GB window", 1, true) ~= nil, locked.error)
check(fakeFs.files["gold/" .. ImportJob.LOCK_PATH] ~= nil, "and leaves that window's lock alone")
fakeFs.files["gold/" .. ImportJob.LOCK_PATH] = tostring(os.time() - 3600) .. "\n"
local stale = ImportJob.start(verified("gold"))
eq(stale.state, "working", "a lock left by a crash an hour ago does not block a new import")
check(fakeFs.files["gold/" .. ImportJob.LOCK_PATH]:match("^%d+ %d*\n$") ~= nil,
  "the new lock records its time and, where known, its process")
for _ = 1, 10 do if stale:step(0) ~= "working" then break end end

-- where the host can tell, a fresh lock whose process is gone (quit or
-- killed a moment ago) does not block either; a live one does
local okFfi, ffi = pcall(require, "ffi")
if okFfi and ffi.os ~= "Windows" then
  pcall(ffi.cdef, "int getpid(void);")
  fakeFs.files["gold/" .. ImportJob.LOCK_PATH] = os.time() .. " 4194303\n"
  local afterQuit = ImportJob.start(verified("gold"))
  eq(afterQuit.state, "working", "a lock from a process that is gone is ignored at once")
  for _ = 1, 10 do if afterQuit:step(0) ~= "working" then break end end
  fakeFs.files["gold/" .. ImportJob.LOCK_PATH] = os.time() .. " " .. ffi.C.getpid() .. "\n"
  local live = ImportJob.start(verified("gold"))
  eq(live.state, "error", "a lock from a running process still refuses")
end
fakeFs.files["gold/" .. ImportJob.LOCK_PATH] = nil

-- a refused import never empties the tree the other window is filling;
-- a failed one empties its own (a half-built cache is what filled the disk)
calls = {}
fakeFs.files["gold/" .. ImportJob.LOCK_PATH] = tostring(os.time()) .. "\n"
ImportJob.start(verified("gold"))
local cleared = false
for _, c in ipairs(calls) do if c:find("^clear gold/") then cleared = true end end
check(not cleared, "a refused import leaves the other window's tree alone")
fakeFs.files["gold/" .. ImportJob.LOCK_PATH] = nil

-- 5. an extractor error reaches the player as a sentence; the cause is kept
calls = {}
Extractor.new = function()
  return { run = function() error("src/import/RomExtractor.lua:99: attempt to index a nil value", 0) end }
end
local bad = ImportJob.start(verified("red"))
for _ = 1, 10 do if bad:step(0) ~= "working" then break end end
eq(bad.state, "error", "an extractor crash fails the job")
playerSentence(bad.error, "the extractor-crash message")
check(bad.detail:find("RomExtractor.lua:99", 1, true) ~= nil, "the technical cause stays in job.detail")
eq(fakeFs.files["red/" .. ImportJob.LOCK_PATH], nil, "a failed import drops its lock too")
local emptied = 0
for _, c in ipairs(calls) do if c == "clear red/data/generated" then emptied = emptied + 1 end end
eq(emptied, 2, "and empties the half-built tree it started (once to start, once on failure)")

-- 6. a publish that raises (an adapter's I/O error) fails the job cleanly
Extractor.new = function() return { run = function() end } end
CacheContract.publish = function() error("disk full") end
local pub = ImportJob.start(verified("red"))
for _ = 1, 10 do if pub:step(0) ~= "working" then break end end
eq(pub.state, "error", "a raising publish fails the job instead of the launcher")
check(pub.error:find("disk space", 1, true) ~= nil, pub.error)

CacheContract.publish = realPublish
os.getenv = realGetenv -- luacheck: ignore 122

-- ------------------------------------------------------- CacheFs.clearTree

package.loaded["src.import.CacheFs"] = nil
local CacheFs = require("src.import.CacheFs")
local files = {
  ["gold/data/generated/maps.lua"] = "old",
  ["gold/data/generated/gba/stale.rgba"] = "old",
  ["gold/assets/generated/x.png"] = "old",
  ["red/data/generated/maps.lua"] = "keep",
}
for k, v in pairs(files) do love.filesystem.write(k, v) end
CacheFs.prefix = "gold/"
CacheFs.clearTree("data/generated")
CacheFs.prefix = ""
eq(love.filesystem.read("gold/data/generated/maps.lua"), nil, "a save-directory cache is cleared for re-import")
eq(love.filesystem.read("gold/data/generated/gba/stale.rgba"), nil, "nested files too")
eq(love.filesystem.read("gold/assets/generated/x.png"), "old", "only the named tree")
eq(love.filesystem.read("red/data/generated/maps.lua"), "keep", "and only this game's")

-- ------------------------------------------------------- FilePicker.read

local FilePicker = require("src.core.FilePicker")
local dir = os.tmpname()
os.remove(dir)
os.execute(('mkdir "%s"'):format(dir))
local data, err = FilePicker.read(dir)
local _
eq(data, nil, "a folder is not read")
check(err and err:find("is a folder", 1, true), "and says it is a folder: " .. tostring(err))
_, err = FilePicker.read(dir .. "/missing.gb")
check(err and err:find("could not be opened", 1, true), "a missing file says so: " .. tostring(err))
local empty = dir .. "/empty.gb"
io.open(empty, "wb"):close()
_, err = FilePicker.read(empty)
check(err and err:find("empty (0 bytes)", 1, true), "an empty file says so: " .. tostring(err))
local big = dir .. "/big.gb"
local fh = io.open(big, "wb") fh:write(string.rep("x", 4096)) fh:close()
data, err = FilePicker.read(big, 1024)
eq(data, nil, "a file over the cap is never read into memory")
check(err and err:find("far larger", 1, true), tostring(err))
eq(#FilePicker.read(big), 4096, "and one under it reads whole")
os.remove(empty) os.remove(big) os.remove(dir)

T.finish("rom import robustness")
