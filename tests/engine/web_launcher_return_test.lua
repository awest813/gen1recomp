-- Exercise the actual launcher-return function: a browser return must not
-- write a restart marker, tear down the process, or end the love.js loop.
package.path = "./?.lua;./?/init.lua;" .. package.path
local T = require("tests.harness")
local check, eq = T.check, T.eq
local f = assert(io.open("main.lua", "rb"))
local src = f:read("*a"):gsub("\r\n", "\n")
f:close()
local fn = assert(src:match("local function returnToLauncher%(opts%).-\nend\n"))
local osName = "Web"
love = { system = { getOS = function() return osName end } }
local HostShell = require("src.core.HostShell")
local calls, received = {}, nil
local function record(name) calls[#calls + 1] = name end
local env = {
  Game = {}, quitToLauncher = false,
  rebuildLauncherInProcess = function(opts)
    record("rebuild")
    received = opts
  end,
  require = function(name)
    eq(name, "src.core.HostShell", "browser return only needs the restart capability gate")
    return HostShell
  end,
  endProcessOnce = function() error("browser process must stay alive") end,
  love = { filesystem = { write = function() error("browser must not stage a native relaunch") end } },
}
setmetatable(env, { __index = _G })
local chunk = assert(loadstring(fn .. "\nreturn returnToLauncher", "=web-launcher-return"))
setfenv(chunk, env)
local returnToLauncher = chunk()
for _, loopRestart in ipairs({ false, true }) do
  _G.POKEPORT_LOOP_RESTART = loopRestart
  calls = {}
  local opts = { tab = "games", invite = "test", request = { version = "blue" } }
  local ok, err = pcall(returnToLauncher, opts)
  check(ok, "browser return survives loop flag " .. tostring(loopRestart) .. ": " .. tostring(err))
  eq(#calls, 1, "browser returns exactly once")
  eq(calls[1], "rebuild", "browser rebuilds the launcher in the running runtime")
  eq(received, opts, "browser preserves the requested launcher handoff")
  eq(env.quitToLauncher, false, "browser remains available for another launch")
end
env.Game = nil
calls = {}
returnToLauncher({})
eq(#calls, 0, "return without a game does nothing")
_G.POKEPORT_LOOP_RESTART = nil
T.finish("web_launcher_return_test")
