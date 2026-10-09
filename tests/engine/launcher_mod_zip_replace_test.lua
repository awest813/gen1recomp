-- Duplicate ZIPs require explicit replacement and retain their validated id.
package.path = "./?.lua;./?/init.lua;" .. package.path
love = require("tests.love_stub")
local T = require("tests.harness")
local Mods = require("src.mods.LauncherMods")
local Importer = require("src.import.RomImporter")
local calls = {}
Mods.installZip = function(source, opts)
  calls[#calls + 1] = { source = source, opts = opts }
  if not opts then
    return nil, "already installed", { id = "voxel", name = "Voxel", version = "2.0" }
  end
  return true, "voxel", { id = "voxel" }
end
Mods.checkDependencies = function() return { hasIssues = false } end
local refreshed = 0
local imp = setmetatable({ _refreshMods = function() refreshed = refreshed + 1 end }, Importer)
imp:_installMod("download.zip")
T.eq(#calls, 1, "import probes once without replacement")
T.eq(refreshed, 0, "no refresh before the user accepts")
T.eq(imp._modConfirm.kind, "importModReplace", "duplicate opens replacement prompt")
local confirm = imp._modConfirm
imp._modConfirm = nil -- view closes the modal before invoking the callback
confirm.onYes()
T.eq(#calls, 2, "accept retries once")
T.eq(calls[2].opts.expectId, "voxel", "replacement pins the validated identity")
T.eq(calls[2].opts.replace, true, "accept enables replacement")
T.eq(refreshed, 1, "successful update refreshes installed mods")
T.eq(imp.modNotice.ok, true, "successful update is visible")
-- A replacement failure surfaces the error without reopening a loop.
Mods.installZip = function() return nil, "copy failed" end
imp:_installMod("download.zip", "voxel")
T.eq(imp.modNotice.text, "copy failed", "replacement failure is reported")
T.eq(imp._modConfirm, nil, "failure does not prompt again")
T.finish("launcher_mod_zip_replace_test")
