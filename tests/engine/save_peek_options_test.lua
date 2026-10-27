-- SaveData.peekOptions: the read-only view the launcher draws from.  One copy
-- is reused until the options change, so drawing does not deep-copy the whole
-- options tree several times a frame; a save is seen on the next peek.
--   luajit tests/engine/save_peek_options_test.lua

package.path = "./?.lua;./?/init.lua;" .. package.path
love = love or require("tests.love_stub")

local T = require("tests.modkit")
local SaveData = require("src.core.SaveData")

local fs = T.sdk.memfs({ ["options.lua"] = "return { musicVol = 3 }" })
local a = SaveData.peekOptions(fs)
local b = SaveData.peekOptions(fs)
T.eq(a.musicVol, 3, "peek reads the saved options")
T.check(a == b, "and hands back the same copy while nothing changed")

local opts = SaveData.loadOptions(fs)
T.check(opts ~= a, "loadOptions still gives a private copy to change")
opts.musicVol = 6
SaveData.saveOptions(opts, fs)
local c = SaveData.peekOptions(fs)
T.check(c ~= a, "a save retires the shared copy")
T.eq(c.musicVol, 6, "and the next peek sees the new value")

T.finish("save peek options")
