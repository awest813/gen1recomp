-- Signed in-place updates (src/update/Signing.lua): the checksum list must
-- carry the project's ed25519 signature, and Boot opens nothing in updates/
-- unless the stored signature and the payload's checksum both hold.
--
-- The vector was made with the commands the release workflow runs
-- (openssl pkeyutl -sign -rawin over sha256sums.txt); its private key was
-- thrown away.
--   luajit tests/engine/update_signing_test.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
love = love or require("tests.love_stub")
local T = require("tests.harness")
local Signing = require("src.update.Signing")

local PUB = "5576720111f0ded3b764fbf15de27722d7108f5d1aca0022ef4cb33a9496bf28"
local HEX = ("a"):rep(64)
local SUMS = HEX .. "  gen1recomp-1.0.0.love\n"
local SIG = "fe73a2efe5c289c3741ac9e22e5d1cfcf207187269c49b186d5acbbc4cac33c4"
  .. "4b28075a8f682903a31edbcbb00586aec86866c5a736447ca66d54c443444b06"

-- no key yet: nothing verifies
Signing.PUBKEY = nil
T.eq((Signing.verifySums(SUMS, SIG)), false, "with no key set, no update verifies")

Signing.PUBKEY = PUB
T.eq((Signing.verifySums(SUMS, SIG)), true, "the project's signature over the list verifies")
T.eq((Signing.verifySums(SUMS .. "x", SIG)), false, "a changed list does not")
T.eq((Signing.verifySums(SUMS, SIG:sub(1, 127) .. "0")), false, "nor a changed signature")
T.eq((Signing.verifySums(SUMS, nil)), false, "nor a missing one")
T.eq(Signing.sumFor(SUMS, "gen1recomp-1.0.0.love"), HEX, "the list names the payload's sum")

-- Boot's check of what is stored beside a payload
local files = {}
local realFs, realData = love.filesystem, love.data
love.filesystem = setmetatable({
  read = function(p) return files[p] end,
  write = function(p, d) files[p] = d return true end,
  remove = function(p) files[p] = nil return true end,
}, { __index = realFs })
love.data = { hash = function(_, data) return data end,
  encode = function(_, _, d) return d == "good payload" and HEX or ("b"):rep(64) end }

local dir, name = "updates", "gen1recomp-1.0.0.love"
files[dir .. "/" .. name] = "good payload"
T.eq((Signing.verifyStored(dir, name)), false, "a payload with no stored signature is refused")
Signing.store(dir, name, SUMS, SIG)
T.eq((Signing.verifyStored(dir, name)), true, "with its signed list beside it, it passes")
files[dir .. "/" .. name] = "swapped payload"
T.eq((Signing.verifyStored(dir, name)), false, "a payload swapped after download is refused")
files[dir .. "/" .. name] = "good payload"
files[dir .. "/" .. name .. ".sums"] = SUMS:gsub("a", "b", 1)
T.eq((Signing.verifyStored(dir, name)), false, "and so is an edited list")

local Boot = require("src.update.Boot")
files[dir .. "/" .. name .. ".sums"] = SUMS
T.eq(Boot.verifyPayload(name), true, "Boot accepts the signed payload")
files[dir .. "/" .. name .. ".sig"] = nil
T.eq(Boot.verifyPayload(name), false, "and refuses it without the signature")

love.filesystem, love.data = realFs, realData
Signing.PUBKEY = nil
T.finish("update signing")
