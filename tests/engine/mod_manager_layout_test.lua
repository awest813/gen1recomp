-- The in-game mod manager (src/mods/ManagerState.lua) draws inside a 20x18
-- tile textbox: column 0, column 19, row 0 and row 17 are the frame.  Every
-- line must stay in columns 1..18, the tab line must not touch the list, a
-- category header after the first gets a blank line above it, and the hot
-- row scrolls a name too long for its room instead of clipping mid-word.

package.path = "./?.lua;./?/init.lua;" .. package.path

local clock = 0
_G.love = _G.love or {}
love.graphics = love.graphics or {}
love.graphics.setColor = love.graphics.setColor or function() end
love.graphics.rectangle = love.graphics.rectangle or function() end
love.timer = { getTime = function() return clock end }

local Font = require("src.render.Font")
local drawn = {}
Font.draw = function(text, x, y)
  drawn[#drawn + 1] = { text = tostring(text), x = x, y = y }
end
Font.drawCode = function(code, x, y)
  drawn[#drawn + 1] = { text = "#", code = code, x = x, y = y }
end
Font.drawBox = function() end

local Events = require("src.mods.Events")
local Runtime = require("src.mods.Runtime")
local ManagerState = require("src.mods.ManagerState")

local failures, checks = 0, 0
local function check(cond, label)
  checks = checks + 1
  if not cond then
    failures = failures + 1
    print("[FAIL] " .. label)
  end
end

local function mod(id, name, category)
  return { id = id, name = name, version = "1.0.0", category = category,
    state = "loaded", enabled = true, dependencySpecs = {},
    conflictSpecs = {}, permissions = {}, description = "a mod" }
end

local available = {
  mod("mew", "Mew Starter Example", "GAMEPLAY"),
  mod("lttp", "Link to the Past Overhaul", "GRAPHICS"),
  mod("a", "SHORT", "GRAPHICS"),
}
for i = 1, 12 do available[#available + 1] = mod("q" .. i, "QOL " .. i, "QOL") end

local loader = { optionSchemas = {}, modOptions = {}, events = Events.new(),
  errors = {} }
function loader.status()
  return { available = available, loaded = {}, errors = {}, order = {} }
end
function loader.setEnabled() return true end

local game = { data = nil, stack = { pop = function() end }, mods = loader,
  save = { options = { mods = {} } } }
game.modStatus = loader.status()
Runtime.safeMode = false

local m = ManagerState.new(game)
m:enter()

local function frame()
  drawn = {}
  m:draw()
  return drawn
end

local function inside(list, label)
  for _, d in ipairs(list) do
    local col = d.x / 8
    local lastCol = col + #d.text - 1
    local row = d.y / 8
    check(col >= 1 and lastCol <= 18 and row >= 1 and row <= 16,
      ("%s: %q at col %d..%d row %d stays inside the frame")
        :format(label, d.text, col, lastCol, row))
  end
end

local function rowOf(list, text)
  for _, d in ipairs(list) do
    if d.text == text then return d.y / 8 end
  end
end

local function textAtRow(list, row, col)
  for _, d in ipairs(list) do
    if d.y / 8 == row and d.x / 8 == col then return d.text end
  end
end

-- ------- the list screen

local list = frame()
inside(list, "list")
local tabRow = rowOf(list, "[MODS] PROF ERRS")
check(tabRow == 2, "the tab line sits on row 2")
check(textAtRow(list, 3, 2) == nil and textAtRow(list, 3, 4) == nil,
  "row 3 is a gap between the tabs and the list")
local gameplay, graphics = rowOf(list, "GAMEPLAY"), rowOf(list, "GRAPHICS")
check(gameplay == 4, "the first category header opens the list on row 4")
check(graphics and gameplay and graphics - gameplay == 3,
  "the next header leaves one blank line after the previous group")
check(rowOf(list, "START:APPLY B:EXIT") == 16,
  "the bottom hint is on row 16 and (checked above) clear of the frame")

-- ------- the hot row scrolls its full name

-- cursor sits on the first mod (Mew Starter Example, 19 chars, room 15)
clock = 0
check(rowOf(frame(), "Mew Starter Exa") ~= nil,
  "the hot row starts at the head of its name")
local seenTail = false
for t = 0, 40 do
  clock = t * 0.25
  if rowOf(frame(), "Starter Example") then seenTail = true end
end
check(seenTail, "the hot row scrolls to the end of a long name")

-- a non-hot row is clipped, never scrolled
m:moveCursor(1)
clock = 3
local moved = frame()
check(rowOf(moved, "Mew Starter Exa") ~= nil,
  "a row the cursor left goes back to a clipped head")
inside(moved, "list after a move")

-- ------- scrolling keeps the cursor on screen through the group gaps

for _ = 1, 20 do
  m:moveCursor(1)
  local f = frame()
  inside(f, "scrolled list")
  local cursorRow
  for _, d in ipairs(f) do
    if d.code and d.x == 8 then cursorRow = d.y / 8 end
  end
  check(cursorRow and cursorRow >= 4 and cursorRow <= 13,
    "the cursor stays in the list rows (row " .. tostring(cursorRow) .. ")")
end

-- ------- the other tabs and screens fit too

m:adjustOrTab(1)
inside(frame(), "profiles tab")
m:adjustOrTab(1)
inside(frame(), "errors tab")
m:adjustOrTab(1)
m.cursor = 2
m:activate()
check(m.screen == "detail", "A opens the detail screen")
inside(frame(), "detail")
m:goTo("errors")
inside(frame(), "errors screen")
m:goBack()
m:goTo("permissions")
inside(frame(), "permissions screen")
m:goBack()
m:notify("A NOTICE THAT IS FAR TOO LONG FOR ONE LINE")
inside(frame(), "notice footer")

print(("%d/%d checks passed  (mod manager layout)"):format(checks - failures, checks))
if failures > 0 then os.exit(1) end
