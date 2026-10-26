-- A file a legacy mod wrote through its compat filesystem can be drawn by
-- the engine at the path the mod wrote it to (src/render/Assets.lua,
-- src/mods/LegacyCompat.lua).  No pokered cite: mod plumbing is port-only.
--
-- Terrarium bakes roamer / town-life sprite sheets, writes them with
-- love.filesystem.write -- which, for a legacy mod, lands in its overlay
-- under mod_compat/<id>/ -- and hands the path it wrote to Assets.image.  The
-- engine looked on the real filesystem, found nothing, and every one of
-- those sprites failed to load (docs/web-voxel-audit-2026-10-08.md).
--   luajit tests/engine/legacy_compat_asset_path_test.lua

package.path = "./?.lua;./?/init.lua;" .. package.path
local T = require("tests.harness")
love = love or require("tests.love_stub")

-- one save directory shared by the compat overlay and LÖVE's own lookups
local files = {}
local fs = {
  write = function(path, value) files[path] = value return true end,
  read = function(path) return files[path] end,
  getInfo = function(path)
    if files[path] then return { type = "file", size = #files[path] } end
  end,
  createDirectory = function() return true end,
}
local realGetInfo = love.filesystem.getInfo
love.filesystem.getInfo = function(path)
  if files[path] then return { type = "file", size = #files[path] } end
  return nil
end
local loaded = {}
local realNewImage, realNewImageData = love.graphics.newImage, love.image.newImageData
love.graphics.newImage = function(path)
  loaded[#loaded + 1] = path
  return { path = path }
end
love.image.newImageData = function(path) return { path = path } end

local Assets = require("src.render.Assets")

-- Before any compat layer exists the lookup is the identity, and costs no
-- filesystem probe for a path that is already right.
local plain = Assets.image("assets/ui/plain.png")
T.eq(plain.path, "assets/ui/plain.png", "no compat layer: the path is used as given")

local LegacyCompat = require("src.mods.LegacyCompat")
local compat = LegacyCompat.new({ modId = "terrarium",
  modPath = "mods/terrarium", fs = fs })
local shim = compat.love.filesystem

T.check(shim.write("terrarium_cache/roamers/PIDGEY.png", "\137PNG pidgey"),
  "the mod writes its baked sheet through the compat filesystem")
local real = LegacyCompat.resolveWritten("terrarium_cache/roamers/PIDGEY.png")
T.check(real ~= nil and files[real] == "\137PNG pidgey",
  "the overlay knows where that write really landed")
T.check(real:sub(1, #"mod_compat/terrarium/") == "mod_compat/terrarium/",
  "inside the mod's own compat overlay")

local img = Assets.image("terrarium_cache/roamers/PIDGEY.png")
T.eq(img.path, real, "the engine draws the file the mod wrote")
local again = Assets.image("terrarium_cache/roamers/PIDGEY.png")
T.check(again == img, "and caches it under the mod's path")
T.eq(Assets.imageData("terrarium_cache/roamers/PIDGEY.png").path, real,
  "pixel reads follow the same redirect")

-- A file written into the mod's own folder goes to the overlay too.
shim.write("mods/terrarium/derived/town/RATTATA.png", "\137PNG rattata")
T.eq(Assets.image("mods/terrarium/derived/town/RATTATA.png").path,
  LegacyCompat.resolveWritten("mods/terrarium/derived/town/RATTATA.png"),
  "a write into the mod's own folder is found as well")

-- A later boot: the sheet is already on disk from last time and the mod only
-- hands the path back, so nothing depends on seeing the write this session.
local nextBoot = LegacyCompat.new({ modId = "terrarium",
  modPath = "mods/terrarium", fs = fs })
T.check(nextBoot ~= nil, "a fresh compat context")
T.eq(LegacyCompat.resolveWritten("terrarium_cache/roamers/PIDGEY.png"), real,
  "a sheet written in an earlier session still resolves")

-- Real files keep winning, and a path nobody wrote stays as given (LÖVE then
-- raises its usual error).
files["terrarium_cache/roamers/PIDGEY.png"] = "real file"
Assets.invalidate()
T.eq(Assets.image("terrarium_cache/roamers/PIDGEY.png").path,
  "terrarium_cache/roamers/PIDGEY.png", "a file on the real filesystem wins")
T.eq(LegacyCompat.resolveWritten("nobody/wrote/this.png"), nil,
  "an unwritten path has no redirect")
T.eq(Assets.image("nobody/wrote/this.png").path, "nobody/wrote/this.png",
  "and is loaded as given")

love.filesystem.getInfo = realGetInfo
love.graphics.newImage, love.image.newImageData = realNewImage, realNewImageData
Assets.invalidate()
T.finish("legacy compat asset path")
