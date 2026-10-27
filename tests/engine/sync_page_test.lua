-- The PK:GB launcher's save-sync page (src/launcher/SyncPage.lua) over a
-- scripted sync engine.  No pokered cite: port-only sync UI.
--   luajit tests/engine/sync_page_test.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
love = love or require("tests.love_stub")
love.graphics.setLineJoin = love.graphics.setLineJoin or function() end

local T = require("tests.harness")
local check, eq = T.check, T.eq

package.loaded["src.core.SaveData"] = {
  listSlots = function() return {} end, activeSlot = function() return nil end,
  loadOptions = function() return {} end, saveOptions = function() return true end,
}
local calls = {}
local eng = { status = "Not linked", isLinked = false, isBusy = false, conflicts = {},
  updates = 0, notices = {} }
function eng:linked() return self.isLinked end
function eng:busy() return self.isBusy end
function eng:update() self.updates = self.updates + 1 end
function eng:takeNotice() return table.remove(self.notices, 1) end
function eng:createAccount(label) calls[#calls + 1] = "create:" .. label self.isLinked = true
  self.codes = { code1 = "1234-5678", code2 = "8765-4321" } return true end
function eng:linkDevice(a, b) calls[#calls + 1] = "link:" .. a .. "/" .. b
  if #a < 8 then return false, "both codes are 8 digits" end return true end
function eng:syncNow() calls[#calls + 1] = "sync" end
function eng:unlink() calls[#calls + 1] = "unlink" self.isLinked = false end
function eng:resolveConflict(key, choice) calls[#calls + 1] = "resolve:" .. key .. ":" .. choice return true end
package.loaded["src.sync.SyncEngine"] = { shared = function() return eng end, _shared = eng }

local Launcher = require("src.launcher.Launcher")
local SyncPage = require("src.launcher.SyncPage")
love.graphics.getDimensions = function() return 1280, 720 end
local realPrint = love.graphics.print
local function drawText(l)
  local seen = {}
  love.graphics.print = function(str, ...) seen[#seen + 1] = tostring(str) return realPrint(str, ...) end
  local ok, err = pcall(l.draw, l)
  love.graphics.print = realPrint
  check(ok, "the launcher draws: " .. tostring(err))
  return table.concat(seen, "\n")
end

local l = Launcher.new(function() end, { noUpdateCheck = true })
l.page = "settings"
check(drawText(l):find("Save sync", 1, true) ~= nil, "Settings has Save sync")
l.sync = SyncPage.new(l)
l.page = "sync"
local t = drawText(l)
check(t:find("Create a sync account", 1, true) and t:find("Link", 1, true),
  "unlinked, it offers to create an account or link with codes")
l.sync:link("12", "34")
check(l.message and l.message.kind == "error", "bad codes are refused with the reason")
l.sync:create()
check(calls[#calls]:find("^create:PK:GB on "), "Create makes an account named for this device")
t = drawText(l)
check(t:find("1234-5678", 1, true) ~= nil, "linked, it shows the codes for another device")
check(t:find("Sync now", 1, true) ~= nil, "and offers Sync now")
l.sync:syncNow()
eq(calls[#calls], "sync", "Sync now syncs")

-- linked devices: each other one can be unlinked (two presses), new codes
function eng:unlinkDevice(id) calls[#calls + 1] = "unlinkDevice:" .. id return true end
function eng:reissueCodes() calls[#calls + 1] = "reissue" return true end
function eng:setEnabled(on) calls[#calls + 1] = "auto:" .. tostring(on) self.state.enabled = on end
eng.state = { enabled = true }
eng.devices = { { id = "me", label = "PK:GB on Linux", current = true },
  { id = "phone", label = "PK:GB on Android" } }
t = drawText(l)
check(t:find("PK:GB on Android", 1, true) ~= nil, "with the other device by name")
check(t:find("(this device)", 1, true) ~= nil, "and this one marked")
l.sync:unlinkDevice("phone")
check(calls[#calls] ~= "unlinkDevice:phone", "the first Unlink only arms")
l.sync:unlinkDevice("phone")
eq(calls[#calls], "unlinkDevice:phone", "the second removes that device")
l.sync:reissue()
eq(calls[#calls], "reissue", "New codes asks for a fresh pair")
l.sync:setAuto(false)
eq(calls[#calls], "auto:false", "auto sync can be turned off")
l.sync:unlink()
check(calls[#calls] ~= "unlink", "Unlink takes two presses")
l.sync:unlink()
eq(calls[#calls], "unlink", "the second unlinks")
eng.isLinked = true
eng.conflicts = { { key = "gold:slot1", version = "gold", slot = "slot1",
  localMeta = { summary = { name = "GOLD", timeText = "3:00" } },
  remoteMeta = { summary = { name = "GOLD", timeText = "4:10" } } } }
t = drawText(l)
check(t:find("3:00", 1, true) and t:find("4:10", 1, true), "a conflict shows both copies")
l.sync:resolve("gold:slot1", "remote")
eq(calls[#calls], "resolve:gold:slot1:remote", "and settles it as chosen")
local before = eng.updates
eng.notices = { "Synced 2 saves" }
l:update(0.1)
eq(eng.updates, before + 1, "the launcher pumps a linked engine")
eq(l.message and l.message.text, "Synced 2 saves", "and shows its notices")

T.finish("sync page")
