-- Switch launcher shows the running engine version in the nav chrome (NX only).
-- Desktop/Android/iOS must not paint that chip.

local function read(path)
  local f = assert(io.open(path, "r"))
  local s = f:read("*a")
  f:close()
  return s
end

local src = read("src/import/LauncherView.lua")
local nav = read("src/import/LauncherNav.lua")

assert(nav:find('local Version = require%("src%.core%.Version"%)')
  or nav:find('require%("src%.core%.Version"%)'),
  "LauncherNav must require Version")

assert(nav:find("imp%.isNX", 1, false), "version chip must gate on isNX")

-- The chip is inside an isNX block and prints Version.engine (layout between
-- the chip and the settings gear may change; anchor on the Switch-only comment).
local nxBlock = nav:match(
  "Switch%-only: show the running app version.-if imp%.isNX then(.-)end")
assert(nxBlock, "expected Switch-only version chip in the nav rail")
assert(nxBlock:find("Version%.engine", 1, false), "chip must show Version.engine")
assert(nxBlock:find('"v"', 1, true) or nxBlock:find('"v" %.%.', 1, false),
  "chip label should be a v-prefixed version")

print("ok — Switch launcher version chip is NX-gated and uses Version.engine")
