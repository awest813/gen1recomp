--   luajit tests/engine/update_signed_mount.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.harness")
local eq = T.eq
local Boot = require("src.update.Boot")
local love = require("tests.love_stub")
_G.love = love

local REL = "updates/gen1recomp-9.9.9.love"
local VERSION = "return { engine = '9.9.9', minShell = 1, payloadHost = 'love' }\n"

local function seed()
  love.filesystem._mounts = {}
  love.filesystem.write(REL .. "/src/core/Version.lua", VERSION)
end

seed()
local direct = 0
Boot._directMount = function()
  direct = direct + 1
  return true
end
local info = Boot.probePayload(REL)
eq(info and info.engine, "9.9.9", "probe reads the payload through love.filesystem.mount")
eq(direct, 0, "a successful love.filesystem.mount does not fall through to PhysFS")
Boot._directMount = nil

seed()
local seen = {}
local realMount = love.filesystem.mount
love.filesystem.mount = function() return false end
Boot._directMount = function(abs, mountpoint, append)
  seen.path, seen.mountpoint, seen.append = abs, mountpoint, append
  love.filesystem._mounts[#love.filesystem._mounts + 1] = {
    archive = REL, mountpoint = mountpoint, append = append and true or false,
  }
  return true
end
Boot._directUnmount = function(abs)
  seen.unmounted = abs
  return true
end
info = Boot.probePayload(REL)
eq(info and info.engine, "9.9.9", "probe reads the payload when love.filesystem.mount refuses")
eq(info.minShell, 1, "direct mount still reports minShell")
eq(info.payloadHost, "love", "direct mount still reports payloadHost")
eq(seen.mountpoint, "__pokeport_probe", "direct mount uses the isolated probe point")
eq(seen.append, false, "direct mount prepends, matching love.filesystem.mount")
eq(seen.path, "/tmp/pokeport-stub-save/" .. REL,
  "direct mount is the absolute save-directory path")
eq(seen.unmounted, seen.path, "unmount uses the same absolute path that was mounted")

love.system.getOS = function() return "Windows" end
eq(Boot.saveArchivePath("updates/gen1recomp-1.2.3.love"),
  "\\tmp\\pokeport-stub-save\\updates\\gen1recomp-1.2.3.love",
  "Windows joins the save directory with backslashes")

love.filesystem.mount = realMount
Boot._directMount = nil
Boot._directUnmount = nil

-- a payload's Version.lua is read as data, never run: probing happens
-- before anything chooses the archive
love.filesystem._mounts = {}
love.filesystem.write(REL .. "/src/core/Version.lua",
  "PROBE_RAN = true\nreturn { engine = \"9.9.9\", minShell = 2, payloadHost = \"love\" }\n")
_G.PROBE_RAN = nil
local probed = Boot.probePayload(REL)
eq(_G.PROBE_RAN, nil, "probing a payload runs none of its code")
eq(probed and probed.engine, "9.9.9", "and still reads its engine version")
eq(probed and probed.minShell, 2, "and its minShell")

-- only GitHub release links become update buttons or downloads
local Check = require("src.update.Check")
eq(Check.trustedAssetUrl("https://github.com/awest813/gen1recomp/releases/download/v1/x.AppImage"), true,
  "a GitHub release link is trusted")
eq(Check.trustedAssetUrl("https://evil.example/x.AppImage"), false, "another host is not")
eq(Check.trustedAssetUrl("http://github.com/x"), false, "nor plain http")

T.finish("update signed mount")
