-- Box review fixes: a Box keeps its Showcase wallpaper and music under any
-- theme (the theme popup wiped them), and a Box export never writes over an
-- earlier one whose revision repeats (a restored backup, a sync).
--   luajit tests/engine/box_review_fixes_test.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
love = love or require("tests.love_stub")
local T = require("tests.harness")
local Store = require("src.box.Store")
local Service = require("src.box.Service")
local Showcase = require("src.box.Showcase")

local function filesystem()
  local files = {}
  return {
    read = function(path) return files[path] end,
    getInfo = function(path) return files[path] and { type = "file" } or nil end,
    createDirectory = function() return true end,
    remove = function(path) files[path] = nil return true end,
    write = function(path, body) files[path] = body return true end,
  }, files
end

-- ---- theme: the wallpaper and music stay with the Box
do
  -- as BoxPanel's theme popup calls it
  local function pick(state, theme)
    local box = state.boxes[1]
    return assert(Store.theme(state, 1, theme, box.wallpaper,
      theme == "Showcase" and box.showcaseMusic or nil))
  end
  local wallpaper = "box/showcase/12341.png"
  local state = Store.new()
  local stage = Showcase.new()
  stage.music = "Waves"
  state.stages = { stage }
  local showcase = assert(Store.theme(state, 1, "Showcase", wallpaper, "Waltz"))
  T.eq(Showcase.boxMusic(showcase, showcase.boxes[1]), "Waltz", "Showcase plays its music")
  local again = pick(showcase, "Showcase")
  T.eq(Showcase.boxMusic(again, again.boxes[1]), "Waltz", "picking Showcase again keeps the music")
  local forest = pick(again, "Forest")
  T.eq(forest.boxes[1].wallpaper, wallpaper, "another theme keeps the wallpaper")
  T.eq(Showcase.boxMusic(forest, forest.boxes[1]), "Silent", "and plays nothing")
  local back = pick(forest, "Showcase")
  T.eq(back.boxes[1].wallpaper, wallpaper, "so Showcase can be chosen again")
  T.eq(Showcase.boxMusic(back, back.boxes[1]), "Waves", "with its stage's music")
end

-- ---- an export never replaces an earlier one
do
  local fs, files = filesystem()
  local service = assert(Service.open(fs))
  local GCI = require("src.box.GCI")
  local realExport = GCI.export
  local n = 0
  GCI.export = function() n = n + 1 return ("collection " .. n) end
  local ok1, first = service:exportGCI()
  local ok2, second = service:exportGCI()
  GCI.export = realExport
  T.check(ok1 and ok2, "both exports are written")
  T.check(first ~= second, "the second gets its own name: " .. tostring(second))
  T.eq(files[first], "collection 1", "the first export is untouched")
  T.eq(files[second], "collection 2", "beside the second")
end

T.finish("box review fixes")
