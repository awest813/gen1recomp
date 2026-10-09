package.path = "./?.lua;./?/init.lua;" .. package.path
love = require("tests.love_stub")
local S = require("tests.harness").suite("web picker cancellation")
local Platform = require("src.core.Platform")
local RomImporter = require("src.import.RomImporter")
love.system.getOS = function() return "Web" end
Platform._resetForTests()
for _, kind in ipairs({"rom", "mod", "required_import", "importer", "skin", "sav", "cart"}) do
  local ri = setmetatable({pickerPendingKind=kind, pickerPendingVersion="blue",
    pickerPendingModId="mod", pickerPendingImportId="source", pickerPendingImporterId="loader",
    saveNotice={}}, RomImporter)
  ri:_handleNativePickError("cancelled:No file was selected.")
  S.eq(ri.workState, nil, kind .. " cancellation leaves ROM import usable")
  S.eq(ri.pickerPendingKind, nil, kind .. " clears pending picker")
  S.eq(ri.pickerPendingImporterId, nil, kind .. " clears importer routing")
  local notice = ri.modNotice or ri._skinNotice or ri.saveNotice.blue or ri.notice
  S.eq(notice and (notice.text or notice.status) or ri._cartNotice,
    "Import cancelled.", kind .. " shows cancellation without failure")
  if notice and notice.ok ~= nil then S.eq(notice.ok, true, kind .. " is neutral feedback") end
end
local ri = setmetatable({pickerPendingKind="mod", pickerPendingVersion="blue", saveNotice={}}, RomImporter)
ri:_handleNativePickError("Could not read the selected file")
S.eq(ri.modNotice.ok, false, "real read errors remain failures")
S.eq(ri.modNotice.text, "Could not read the selected file", "real error detail retained")
love.system.getOS = function() return "Android" end
Platform._resetForTests()
ri.pickerPendingKind, ri.pickerPendingVersion = "mod", "blue"
ri:_handleNativePickError("cancelled:TV file manager returned nothing")
S.eq(ri.modNotice.ok, false, "native file manager failures keep their handling")
S.finish()
