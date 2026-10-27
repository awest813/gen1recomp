-- The in-game mod manager (src/mods/ManagerState.lua), from a menu audit.
--   luajit tests/engine/mod_manager_audit_test.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
love = love or require("tests.love_stub")
local T = require("tests.harness")
local check, eq = T.check, T.eq

local SaveData = require("src.core.SaveData")
SaveData.saveOptions = function() return true end
local Events = require("src.mods.Events")
local ManagerState = require("src.mods.ManagerState")

local function manifest(id, over)
  local m = { id = id, name = id:upper(), version = "1.0.0", category = "OTHER",
    state = "loaded", enabled = true, dependencySpecs = {}, conflictSpecs = {},
    permissions = {}, description = "a mod" }
  for k, v in pairs(over or {}) do m[k] = v end
  return m
end

local function game(available)
  local loader = { optionSchemas = {}, modOptions = {}, events = Events.new(), errors = {} }
  function loader:status() return { available = available, loaded = {}, errors = {}, order = {} } end
  function loader:setEnabled(id, en)
    for _, m in ipairs(available) do if m.id == id then m.enabled = en end end
    return true
  end
  loader.forced = {}
  function loader:setGen2Forced(id, want) self.forced[id] = want return true, true end
  local stack = { states = {} }
  function stack:push(s) self.states[#self.states + 1] = s end
  function stack:pop() return table.remove(self.states) end
  function stack:top() return self.states[#self.states] end
  return { data = {}, stack = stack, save = { options = { mods = {} } }, mods = loader,
    modStatus = loader:status(), input = { wasPressed = function() return false end } }, loader
end

-- the detail text stops scrolling at its last page
do
  local long = string.rep("WORDS THAT WRAP ", 12)
  local g = game({ manifest("long", { description = long }) })
  local ms = ManagerState.new(g)
  ms.currentMod = g.modStatus.available[1]
  ms.screen = "detail"
  ms.focusedRow = function() return nil end
  local lines = #ms:detailBody(ms.currentMod)
  for _ = 1, 50 do ms:adjustOrTab(1) end
  eq(ms.descScroll, math.max(1, lines - 5 + 1), "Right stops on the last page of the text")
  for _ = 1, 50 do ms:adjustOrTab(-1) end
  eq(ms.descScroll, 1, "and Left back at the top")
end

-- a profile is never saved without a name
do
  local g = game({ manifest("one") })
  local ms = ManagerState.new(g)
  ms:refresh()
  local naming
  g.stack.push = function(self, s) naming = s; self.states[#self.states + 1] = s end
  ms:saveCurrentAs()
  if check(naming and naming.onDone ~= nil or (naming and naming.opts), "SAVE CURRENT AS opens the naming screen") then
    local done = naming.onDone or (naming.opts and naming.opts.onDone)
    done("")
    local opts = ms:optionsTable()
    eq(#(opts.modProfiles or {}), 0, "an empty name saves nothing")
    eq(opts.activeProfile, nil, "and makes nothing active")
  end
end

-- TRY HERE ANYWAY is listed as pending and undone by DISCARD
do
  local g, loader = game({ manifest("redonly", { state = "wrong_generation", enabled = true }) })
  local ms = ManagerState.new(g)
  ms:refresh()
  ms.openConfirm = function(_, _, yes) yes() end
  local m = g.modStatus.available[1]
  ms:toggleGen2Force(m)
  eq(loader.forced.redonly, true, "the override is set")
  eq(ms.gen2Pending, true, "and a restart is pending")
  local text = {}
  local Font = require("src.render.Font")
  local realDraw = Font.draw
  Font.draw = function(s) text[#text + 1] = tostring(s) end
  pcall(ms.drawApply, ms)
  Font.draw = realDraw
  local all = table.concat(text, "\n")
  check(not all:find("NO CHANGES", 1, true), "the apply screen does not say NO CHANGES")
  check(all:find("TRY REDONLY", 1, true) ~= nil, "it names the override")
  ms:discardChanges()
  eq(loader.forced.redonly, false, "DISCARD puts the override back")
  eq(ms.gen2Pending, false, "and nothing is pending")
end

-- permission labels fit the 15 columns a row has
do
  local g = game({ manifest("net", { permissions = { "network", "engine_internals", "filesystem" } }) })
  local ms = ManagerState.new(g)
  local rows = ms:permissionRows(g.modStatus.available[1])
  eq(#rows, 3, "one row per declared permission")
  for _, row in ipairs(rows) do
    check(#row.label <= 15, "permission row fits: " .. row.label)
  end
end

T.finish("mod manager audit")
