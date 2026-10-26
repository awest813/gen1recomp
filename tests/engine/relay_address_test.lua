-- The online relay address is configurable (src/link/Net.lua): typed in
-- the launcher's Settings, given for one run with --relay, or set by
-- POKEPORT_RELAY_ADDR.  No pokered cite: port-only online plumbing.
--   luajit tests/engine/relay_address_test.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
love = love or require("tests.love_stub")

local T = require("tests.harness")
local check, eq = T.check, T.eq

local options = {}
package.loaded["src.core.SaveData"] = {
  loadOptions = function() return options end,
  saveOptions = function(o) options = o return true end,
  listSlots = function() return {} end,
}
local env = {}
local realGetenv = os.getenv
os.getenv = function(k) if env[k] ~= nil then return env[k] or nil end return realGetenv(k) end
env.POKEPORT_RELAY_ADDR = false

local Net = require("src.link.Net")
local LaunchOptions = require("src.core.LaunchOptions")

-- ---------------------------------------------------------- what is typed
local function norm(text) return (Net.normalizeRelayAddress(text)) end
eq(norm("relay.example.com:9000"), "relay.example.com:9000", "host:port is kept")
eq(norm("  Relay.Example.com  "), "relay.example.com:7778", "a bare host gets the relay port")
eq(norm("ws://relay.example.com:9000/"), "relay.example.com:9000", "a pasted scheme and slash are dropped")
eq(norm("192.168.1.20:7778"), "192.168.1.20:7778", "an IPv4 address works")
eq(norm(""), nil, "empty is not an address")
eq(norm("relay example.com"), nil, "spaces are refused")
eq(norm("relay.example.com:0"), nil, "port 0 is refused")
eq(norm("relay.example.com:70000"), nil, "so is a port past 65535")
eq(norm("-bad.example.com"), nil, "a host cannot start with a dash")
local _, why = Net.normalizeRelayAddress("a b")
check(type(why) == "string" and why ~= "", "a refusal says why")

-- --------------------------------------------------------------- priority
local address, source = Net.relaySetting()
eq(address, Net.DEFAULT_RELAY_ADDRESS, "nothing set: the default relay")
eq(source, "default", "and says so")
options.relayAddress = "saved.example.com:7000"
eq(Net.defaultRelayAddress(), "saved.example.com:7000", "a saved address is used")
options.relayAddress = "not valid!"
eq(Net.defaultRelayAddress(), Net.DEFAULT_RELAY_ADDRESS, "a broken saved one falls back to the default")
options.relayAddress = "saved.example.com:7000"
Net.relayOverride = LaunchOptions.relayAddress({ "--relay=run.example.com" })
eq(Net.relayOverride, "run.example.com:7778", "--relay is parsed like a typed address")
eq(select(2, Net.relaySetting()), "launch", "--relay wins over the saved one for this run")
eq(LaunchOptions.relayAddress({ "--relay=bad host" }), nil, "a bad --relay is ignored")
env.POKEPORT_RELAY_ADDR = "127.0.0.1:17778"
eq(Net.defaultRelayAddress(), "127.0.0.1:17778", "POKEPORT_RELAY_ADDR wins over everything")
env.POKEPORT_RELAY_ADDR = false
Net.relayOverride = nil

-- ----------------------------------------------------- launcher Settings
local Launcher = require("src.launcher.Launcher")
local l = Launcher.new(function() end, { noUpdateCheck = true })
l:setRelay("my-relay.example.org:7778")
eq(options.relayAddress, "my-relay.example.org:7778", "Settings saves a relay address")
eq(Net.defaultRelayAddress(), "my-relay.example.org:7778", "and online play uses it")
l:setRelay("nope nope")
eq(options.relayAddress, "my-relay.example.org:7778", "a bad address leaves the saved one alone")
check(l.message.kind == "error", "and says why")
l:setRelay("")
eq(options.relayAddress, nil, "an empty address goes back to the default")
eq(select(2, Net.relaySetting()), "default", "which is what connects")
love.graphics.getDimensions = function() return 1280, 720 end
l.page = "settings"
local seen = {}
local realPrint = love.graphics.print
love.graphics.print = function(str, ...) seen[#seen + 1] = tostring(str) return realPrint(str, ...) end
local ok, err = pcall(l.draw, l)
love.graphics.print = realPrint
check(ok, "Settings draws: " .. tostring(err))
local text = table.concat(seen, "\n")
check(text:find("Online relay", 1, true) ~= nil, "Settings has an Online relay row")
check(text:find("(default)", 1, true) ~= nil, "showing which relay is in use and why")

os.getenv = realGetenv
T.finish("relay address")
