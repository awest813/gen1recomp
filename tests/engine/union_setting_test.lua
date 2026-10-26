package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.harness")
local check, eq = T.check, T.eq
love = love or require("tests.love_stub")

local SaveData = require("src.core.SaveData")
local Setting = require("src.online.union.Setting")

local function memfs()
  local files = {}
  return {
    files = files,
    write = function(path, content) files[path] = content return true end,
    read = function(path) return files[path] end,
    remove = function(path) files[path] = nil return true end,
    getInfo = function(path)
      if files[path] ~= nil then return { type = "file" } end
      return nil
    end,
  }
end

eq(Setting.enabledIn(nil), true, "no options file at all: ON")
eq(Setting.enabledIn({}), true, "an install with no saved preference: ON")
eq(Setting.enabledIn({ unionRoom = true }), true, "explicit ON")
eq(Setting.enabledIn({ unionRoom = false }), false, "explicit OFF")

local fresh = memfs()
eq(Setting.enabled(fresh), true, "fresh install reads ON")

local old = memfs()
old.files["options.lua"] = [[return { textSpeed = 3, reduceMotion = true }]]
eq(Setting.enabled(old), true, "existing install without the key reads ON")

local off = memfs()
SaveData.saveOptions(SaveData.defaultOptions(), off)
local opts = SaveData.loadOptions(off)
opts[Setting.KEY] = false
check(SaveData.saveOptions(opts, off), "OFF writes")
local restarted = memfs()
restarted.files = off.files
for k, v in pairs(off) do if k ~= "files" then restarted[k] = v end end
eq(Setting.enabled(restarted), false, "explicit OFF survives a restart")
local again = SaveData.loadOptions(off)
again.textSpeed = 1
SaveData.saveOptions(again, off)
eq(Setting.enabled(off), false, "an unrelated options write keeps OFF")

for _, gen in ipairs({ 1, 2 }) do
  eq(Setting.patchesOn(gen, { unionRoom = false }), false, "gen " .. gen .. " restores vanilla when OFF")
  eq(Setting.patchesOn(gen, {}), true, "gen " .. gen .. " patches by default")
end
eq(Setting.patchesOn(3, { unionRoom = false }), true, "gen 3 Union Rooms ignore OFF")
eq(Setting.appliesTo(3), false, "the setting never applies to gen 3")

T.finish("union_setting")
