package.path = "./?.lua;./?/init.lua;" .. package.path
local T = require("tests.harness")
love = love or require("tests.love_stub")
local LegacyCompat = require("src.mods.LegacyCompat")
local files = {}
local fs = {
  write=function(path, value) files[path]=value; return true end,
  read=function(path) return files[path] end,
  getInfo=function(path) if files[path] then return {type="file",size=#files[path]} end end,
  createDirectory=function() return true end,
}
local compat = LegacyCompat.new({modId="binary_probe", modPath="mods/binary_probe", fs=fs})
local shim = compat.love.filesystem
local bytes = "\137PNG\r\n\26\n\0\255binary"
local data = newproxy(true)
getmetatable(data).__index = {getString=function() return bytes end}
getmetatable(data).__tostring = function() return "FileData: description" end
T.check(shim.write("art.png", data), "FileData write succeeds")
T.eq(shim.read("art.png"), bytes, "binary bytes survive compatibility storage")
T.check(shim.append("art.png", data, 8), "Data append supports byte count")
T.eq(shim.read("art.png"), bytes .. bytes:sub(1,8), "append preserves embedded zero and high bytes")
local file = shim.newFile("file.png", "w")
T.check(file:write(data), "File:write accepts Data")
file:close()
T.eq(shim.read("file.png"), bytes, "File:write preserves bytes")
local bad = newproxy(true)
getmetatable(bad).__index = {getString=function() error("broken data") end}
T.check(not shim.write("art.png", bad), "unreadable Data fails")
T.eq(shim.read("art.png"), bytes .. bytes:sub(1,8), "failed conversion preserves previous file")
T.finish("legacy binary writes")
