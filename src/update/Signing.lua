-- Signed in-place updates.
--
-- A release's sha256sums.txt is signed with the project's ed25519 key; the
-- signature ships as the release asset sha256sums.txt.sig (128 hex digits).
-- The download worker checks it before it keeps a payload, and stores the
-- two files beside the payload (updates/<payload>.sums and .sig) so Boot can
-- check them again, offline, before it probes or mounts anything: a .love
-- dropped into the save folder by anything else is never run.
--
-- PUBKEY is the public half, pinned here.  Until it is set, in-place updates
-- are refused (the launcher offers the full package instead).  How to make
-- the key and sign releases: docs/releasing-updates.md.
--
-- Zero heavy requires: Boot loads this before the game.

local Signing = {}

-- 64 hex digits, or nil while no key has been made.
Signing.PUBKEY = nil

Signing.SIG_ASSET = "sha256sums.txt.sig"
Signing.SUMS_SUFFIX = ".sums"
Signing.SIG_SUFFIX = ".sig"

function Signing.configured()
  return type(Signing.PUBKEY) == "string" and Signing.PUBKEY:match("^%x+$") ~= nil
    and #Signing.PUBKEY == 64
end

-- Whether `sigText` is the project's signature over `sumsText`.
function Signing.verifySums(sumsText, sigText)
  if not Signing.configured() then return false, "updates are not signed yet" end
  if type(sumsText) ~= "string" or sumsText == "" then return false, "no checksum list" end
  if type(sigText) ~= "string" then return false, "no signature" end
  local sig = sigText:match("^%s*(%x+)%s*$")
  if not sig or #sig ~= 128 then return false, "the signature is malformed" end
  local Ed25519 = require("src.core.crypto.ed25519")
  if not Ed25519.verify(Signing.PUBKEY, sumsText, sig) then
    return false, "the signature does not match"
  end
  return true
end

-- The sha256 the sums list gives for `name` ("<hex>  <name>" lines, as
-- shasum -a 256 writes them).
function Signing.sumFor(sumsText, name)
  if type(sumsText) ~= "string" or type(name) ~= "string" then return nil end
  for line in sumsText:gmatch("[^\r\n]+") do
    local hex, file = line:match("^(%x+)%s+%*?(.-)%s*$")
    if hex and #hex == 64 and file == name then return hex:lower() end
  end
  return nil
end

local function sha256hex(data)
  local digest = love.data.hash("sha256", data)
  if type(digest) == "userdata" and digest.getString then digest = digest:getString() end
  return love.data.encode("string", "hex", digest):lower()
end
Signing._sha256hex = sha256hex

-- Boot's check of a stored payload: its sums and signature are beside it,
-- the signature holds, and the payload's bytes hash to the listed sum.
function Signing.verifyStored(dir, name)
  local fs = love.filesystem
  local base = dir .. "/" .. name
  local sums = fs.read(base .. Signing.SUMS_SUFFIX)
  local sig = fs.read(base .. Signing.SIG_SUFFIX)
  local ok, why = Signing.verifySums(sums, sig)
  if not ok then return false, why end
  local want = Signing.sumFor(sums, name)
  if not want then return false, "the checksum list does not name " .. name end
  local data = fs.read(base)
  if not data then return false, "the payload could not be read" end
  if sha256hex(data) ~= want then return false, "the payload does not match its checksum" end
  return true
end

-- Keep the verified sums and signature beside a payload for Boot.
function Signing.store(dir, name, sumsText, sigText)
  local fs = love.filesystem
  local base = dir .. "/" .. name
  return fs.write(base .. Signing.SUMS_SUFFIX, sumsText)
    and fs.write(base .. Signing.SIG_SUFFIX, sigText)
end

function Signing.forget(dir, name)
  local fs = love.filesystem
  local base = dir .. "/" .. name
  fs.remove(base .. Signing.SUMS_SUFFIX)
  fs.remove(base .. Signing.SIG_SUFFIX)
end

return Signing
