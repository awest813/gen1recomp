-- UI kit input fixes (src/ui/kit/Kit.lua): a toast's lone button does not
-- trap the pad ring; Enter after a click shows the ring before it presses
-- anything (it confirmed a save delete); rows, toggles and fields ignore
-- Enter / A under a modal or a page slide, as buttons do; an overlay flag a
-- failed draw left on is reset each frame; a drag a page cannot scroll
-- reaches the list inside it; a cancelled keyboard's old text does not
-- revert a field visited later.
--   luajit tests/engine/kit_input_review_test.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
love = love or require("tests.love_stub")

local T = require("tests.harness")
local check, eq = T.check, T.eq

local Kit = require("src.ui.kit.Kit")
Kit.layout(1280, 800)

local function navColumn(slot)
  local id = tostring(slot.id or "")
  if id:match("^nav%-") then return "rail" end
  return "content"
end

-- ---- a toast's one button does not hold the ring
do
  local function frame()
    Kit.navColumn, Kit.navColumnOrder = navColumn, { "rail", "content" }
    Kit.beginFrame(0, 0, false, 0)
    Kit.button(0, 100, 80, 30, "rail", { id = "nav-games" })
    Kit.button(300, 100, 200, 30, "A", { id = "btn-a" })
    Kit.button(300, 200, 200, 30, "B", { id = "btn-b" })
    local was = Kit._overlay
    Kit._overlay = true
    Kit.button(400, 40, 100, 30, "Open folder", { id = "toast-action" })
    Kit._overlay = was
    Kit.endFrame()
    Kit.navColumn, Kit.navColumnOrder = nil, nil
  end
  Kit.setFocus("toast-action")
  frame()
  Kit.navigate("down")
  frame()
  check(Kit.focusId ~= "toast-action", "the ring leaves a toast's lone button: " .. tostring(Kit.focusId))
end

-- ---- Enter after a click shows the ring first
do
  Kit.pointerUsed()
  local function frame(click, mx, my)
    Kit.beginFrame(mx or 0, my or 0, click, 0)
    local hit = Kit.button(100, 100, 100, 30, "Delete", { id = "save-delete" })
    Kit.endFrame()
    return hit
  end
  check(frame(true, 120, 110), "a click presses Delete")
  Kit.keypressed("return")
  eq(frame(false), false, "Enter then does not press it again unseen")
  check(Kit._ringShown, "it shows the ring on it instead")
  Kit.keypressed("return")
  eq(frame(false), true, "a second Enter, ring in view, presses it")
end

-- ---- under a modal, Enter reaches no row, toggle or field
do
  Kit.setFocus("row1")
  Kit.beginFrame(0, 0, false, 0)
  Kit.activateFocused()
  Kit.blockClicks = true
  local row = Kit.row(0, 0, 100, 30, false, "row1")
  local _, toggled = Kit.toggle(0, 40, 100, 30, false, "row1")
  Kit.textfield("row1", 0, 80, 100, 30, "", "")
  Kit.endFrame()
  eq(row, false, "a row under a modal ignores Enter")
  check(not toggled, "a toggle too")
  check(Kit.focus ~= "row1", "and a field does not take focus")
end

-- ---- a draw that failed with the overlay flag set does not leave it on
do
  Kit.beginFrame(0, 0, false, 0)
  pcall(function() Kit._overlay = true error("boom") end)
  Kit.endFrame()
  Kit.beginFrame(0, 0, false, 0)
  eq(Kit._overlay, false, "the next frame starts with no overlay")
  Kit.endFrame()
end

-- ---- a drag the page cannot scroll goes to the list inside it
do
  Kit.beginFrame(0, 0, false, 0)
  Kit.dragBegin(100, 150)
  Kit.dragAdd(40)
  local outer = Kit.scrollInput(50, 50, 0, 0, 400, 300)
  Kit.scrollBegin(0, 0, 400, 300, outer, 50)
  local inner = Kit.scrollInput(0, 200, 0, 100, 400, 100)
  Kit.resetClip()
  Kit.endFrame()
  eq(outer, 50, "the page, at its end, stays")
  eq(inner, 40, "the list inside it scrolls")
  Kit.dragEnd()
end

-- ---- a cancelled keyboard's text is for the next frame only
do
  Kit._restore = { id = "late-field", value = "old" }
  Kit.beginFrame(0, 0, false, 0)
  Kit.endFrame()
  Kit.beginFrame(0, 0, false, 0)
  Kit.endFrame()
  Kit.beginFrame(0, 0, false, 0)
  local v = Kit.textfield("late-field", 0, 0, 100, 30, "new", "")
  Kit.endFrame()
  eq(v, "new", "a field drawn later keeps its own text")
end

T.finish("kit input review")
