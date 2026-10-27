-- Immediate-mode widget kit shared by the launcher and the save editor.
--
-- This is the replacement for the vendored FlexLove tree that the launcher
-- used to rebuild every frame.  The contract that mattered there is kept --
-- the UI is rebuilt from owner state each frame, so it can never drift --
-- but without a retained element tree, per-element id hashing, or a
-- property snapshot pass.  Measured effect on the launcher's build+draw:
-- ~9.2ms/frame down to well under 1ms (see POKEPORT_LAUNCHER_PROF).
--
-- Usage, once per love.draw():
--     Kit.layout(w, h)                     -- fonts + scale, only on resize
--     Kit.beginFrame(mx, my, clicked, wheel)
--     ... widgets ...
--     Kit.endFrame()
--
-- WHY IT IS FAST (the rules any new widget must follow):
--  1. No allocation in the steady state.  Widgets take and return scalars;
--     the per-frame tables that do exist (nav list, audit) are reused and
--     truncated, never rebuilt.  LuaJIT's GC is the difference between a
--     6ms frame and a 0.6ms one when a list has 200 rows.
--  2. Text is cached as love.graphics.Text objects keyed by font+string
--     (Kit.text).  G.print re-shapes the string every call; a Text object
--     shapes once and then costs one batched draw.  Colour is applied at
--     draw time, which does NOT break the batch -- switching FONTS does,
--     which is the other reason the cache pays.
--  3. Measurement (font:getWidth, ellipsize) is memoised per font+string.
--     Ellipsising is O(glyphs) with a getWidth per step and list rows do it
--     for every visible cell, every frame, on strings that never change.
--  4. Lists PAGINATE.  Row count is bounded by the page size, so a 500-mod
--     index costs exactly what a 10-mod one does.  There is no virtualised
--     scroller and no momentum integrator to run.
--  5. Draw flat.  No stencil, no mesh, no canvas, no shader, no blend-mode
--     change -- every one is a pipeline flush.  Rounded corners, the emboss
--     and a card's drop shadow are allowed because they only add VERTICES at
--     the same pipeline state (see Theme.lua's header for the full rule).
--
-- ACCESSIBILITY / INPUT: every control is reachable four ways -- mouse,
-- touch (>= 30px targets), keyboard (spatial focus ring, arrows + Enter),
-- and gamepad (the same ring, driven by the d-pad, plus a virtual cursor).
-- Hit testing is a plain rect with no z-order, so overlapping layers must be
-- drawn in dispatch order and a modal raises Kit.blockClicks over what it
-- covers.

local Theme = require("src.ui.kit.Theme")
local PAL = Theme.PAL
local VirtualKeyboard = require("src.ui.kit.VirtualKeyboard")
local FileBrowser = require("src.ui.kit.FileBrowser")
local Transition = require("src.ui.kit.Transition")

local Kit = {
  scale = 1,
  time = 0,
  focus = nil,       -- active text-input id (nil = no focused field)
  focusId = nil,     -- spatial-nav ring id (nil = nothing selected by pad/arrows)
  VirtualKeyboard = VirtualKeyboard,
  FileBrowser = FileBrowser,
  Transition = Transition,
}

Kit.mouseX, Kit.mouseY = 0, 0
Kit.mouseClicked = false   -- left button pressed this frame
Kit.mouseDown = false      -- held, polled (drag / press-and-hold)
Kit.wheelY = 0             -- wheel notches queued since the last frame
Kit.scale = 1
Kit.blockClicks = false
Kit.audit = nil

local G = love and love.graphics or nil
local edits = {}           -- queued textinput / backspace since the last frame
local kbField = nil        -- id of the field the soft keyboard is raised for

local function has(name)
  return Theme.probe(name)
end

-- ------------------------------------------------------------ soft keyboard
-- Mobile LOVE only delivers love.textinput while setTextInput(true) is
-- active, and that call is what raises the Android/iOS soft keyboard; the
-- rect keeps the focused field visible above it.  setTextInput is global SDL
-- state, not per-widget, so desktop text input is never turned off (#529).
local function mobile()
  local osName = love and love.system and love.system.getOS
    and love.system.getOS()
  return osName == "Android" or osName == "iOS"
end
Kit.isMobile = mobile

local function syncSoftKeyboard(id, x, y, w, h)
  if not (love and love.keyboard and love.keyboard.setTextInput) then return end
  if id then
    if kbField ~= id then
      kbField = id
      love.keyboard.setTextInput(true, math.floor(x), math.floor(y),
        math.ceil(w), math.ceil(h))
    end
  elseif kbField then
    kbField = nil
    if mobile() then love.keyboard.setTextInput(false) end
  end
end

-- ------------------------------------------------------------- text caching
-- Two caches, both keyed by font name + string, both cleared wholesale when
-- the font set is rebuilt (a resize).  A wholesale clear is correct and
-- cheap: an LRU would cost more bookkeeping per lookup than it saves, and
-- the working set of a UI is small and stable between resizes.
local textCache, textCacheN = {}, 0
local widthCache = {}
local ellipsisCache = {}
local CACHE_MAX = 1024

local wrapCacheRef  -- forward declaration; the table is defined below
local function clearCaches()
  textCache, textCacheN = {}, 0
  widthCache = {}
  ellipsisCache = {}
  if wrapCacheRef then
    for k in pairs(wrapCacheRef) do wrapCacheRef[k] = nil end
  end
end
Kit.clearCaches = clearCaches

local function font(name)
  return Kit.fonts[name] or Kit.fonts.small
end
Kit.font = font

-- Rebuild the font set when the window size changes.  The scale never dips
-- below 0.9 so text and the 30px tap targets stay readable on a phone; a
-- narrow window is answered by REFLOW (see Layout.lua), never by shrinking.
-- Global size multiplier.  Everything in the UI derives from Kit.scale, so
-- one factor here moves text, tap targets, padding and row heights together
-- and nothing drifts out of proportion.  1.3 because the launcher is read at
-- couch distance as often as at desk distance, and the old sizing was tuned
-- for the latter only.
local UI_SCALE = 1.3

function Kit.layout(width, height)
  local s = Theme.clamp(math.min(width / 640, height / 768), 0.9, 1.6) * UI_SCALE
  -- Two numbers, not a formatted key: this runs once per frame and the
  -- string:format allocated on every one of them.
  local kw, kh = math.floor(width), math.floor(height)
  if Kit._fontW ~= kw or Kit._fontH ~= kh then
    Kit._fontW, Kit._fontH = kw, kh
    Kit.fonts = Theme.fonts(s)
    clearCaches()   -- every cached Text/width belongs to the old font set
  end
  Kit.scale = s
  Kit.width, Kit.height = width, height
  return s
end

function Kit.textWidth(name, str)
  str = tostring(str)
  local key = name .. "\0" .. str
  local w = widthCache[key]
  if w then return w end
  local f = font(name)
  -- Never let a malformed string (a mod name from a third-party index) throw
  -- out of a measurement: an unmeasurable string is treated as zero-width and
  -- the ellipsis logic clips it away.
  if f then
    local ok, got = pcall(f.getWidth, f, str)
    w = ok and got or 0
  else
    w = 0
  end
  widthCache[key] = w
  return w
end

function Kit.textHeight(name)
  local f = font(name)
  return f and f:getHeight() or 12
end

function Kit.ellipsize(name, str, maxW)
  str = tostring(str or "")
  local key = name .. "\0" .. math.floor(maxW) .. "\0" .. str
  local c = ellipsisCache[key]
  if c then return c end
  c = Theme.ellipsize(font(name), str, maxW)
  ellipsisCache[key] = c
  return c
end

function Kit.ellipsizeLeft(name, str, maxW)
  str = tostring(str or "")
  local key = name .. "\1" .. math.floor(maxW) .. "\0" .. str
  local c = ellipsisCache[key]
  if c then return c end
  c = Theme.ellipsizeLeft(font(name), str, maxW)
  ellipsisCache[key] = c
  return c
end

-- A cached, pre-shaped Text object.  Falls back to G.print under a stub or
-- when the cache is saturated.
local function textObject(name, str)
  if not (G and has("newText")) then return nil end
  local key = name .. "\0" .. str
  local t = textCache[key]
  if t then return t end
  if textCacheN >= CACHE_MAX then clearCaches() end
  local f = font(name)
  if not f then return nil end
  local ok, obj = pcall(G.newText, f, str)
  if not ok then return nil end
  textCache[key] = obj
  textCacheN = textCacheN + 1
  return obj
end

-- Bold text: the same cached run drawn twice, one pixel apart.  The UI face
-- has a single weight, so this is the only way to get emphasis without
-- shipping a second font -- and it keeps the measurement identical, which
-- matters because every layout here is measured, not flowed.
function Kit.textBold(name, str, x, y, c, a)
  local w = Kit.text(name, str, x, y, c, a)
  Kit.text(name, str, x + Theme.BOLD_OFFSET, y, c, a)
  return w
end

function Kit.textCenterBold(name, str, x, y, w, c, a)
  local tw = Kit.textWidth(name, tostring(str))
  return Kit.textBold(name, str, x + (w - tw) / 2, y, c, a)
end

-- Draw a string.  Returns its width, so callers can lay out inline runs
-- without a second measurement.
function Kit.text(name, str, x, y, c, a)
  if not G then return 0 end
  str = tostring(str)
  Theme.col(c or PAL.text, a or 1)
  local obj = textObject(name, str)
  if obj then
    G.draw(obj, Theme.snap(x), Theme.snap(y))
  else
    local f = font(name)
    if not f then return 0 end
    G.setFont(f)
    -- Same guard as the measurement path: a string LOVE cannot shape must
    -- not take the whole frame down with it.
    pcall(G.print, str, Theme.snap(x), Theme.snap(y))
  end
  return Kit.textWidth(name, str)
end

function Kit.textRight(name, str, x2, y, c, a)
  return Kit.text(name, str, x2 - Kit.textWidth(name, tostring(str)), y, c, a)
end

function Kit.textCenter(name, str, x, y, w, c, a)
  return Kit.text(name, str, x + (w - Kit.textWidth(name, tostring(str))) / 2,
    y, c, a)
end

-- Word-wrapped text.  Font:getWrap re-shapes the whole string every call and
-- list rows ask for the same (font, width, string) every frame, so the line
-- split is memoised alongside the other measurement caches.  `maxLines`
-- truncates with an ellipsis rather than overflowing the box the caller
-- reserved -- an immediate-mode layout has no way to grow after the fact.
local wrapCache = {}
wrapCacheRef = wrapCache

function Kit.wrapLines(name, str, w)
  str = tostring(str or "")
  if str == "" or w <= 0 then return nil end
  local key = name .. "\0" .. math.floor(w) .. "\0" .. str
  local lines = wrapCache[key]
  if lines then return lines end
  local f = font(name)
  if not f then return nil end
  local ok, _, wrapped = pcall(f.getWrap, f, str, w)
  lines = (ok and wrapped) or { str }
  wrapCache[key] = lines
  return lines
end

-- Returns the height consumed.
function Kit.textWrapped(name, str, x, y, w, c, maxLines, a)
  local lines = Kit.wrapLines(name, str, w)
  if not lines then return 0 end
  local lh = Kit.textHeight(name)
  local n = #lines
  if maxLines and n > maxLines then n = maxLines end
  for i = 1, n do
    local line = lines[i]
    if maxLines and i == maxLines and #lines > maxLines then
      line = Kit.ellipsize(name, line .. "...", w)
    end
    Kit.text(name, line, x, y + (i - 1) * lh, c, a)
  end
  return n * lh
end

-- Height a wrapped run will need, without drawing it.  Panels call this to
-- reserve space before laying the block out.
function Kit.wrapHeight(name, str, w, maxLines)
  local lines = Kit.wrapLines(name, str, w)
  if not lines then return 0 end
  local n = #lines
  if maxLines and n > maxLines then n = maxLines end
  return n * Kit.textHeight(name)
end

-- 12px / 2px-tracked uppercase section caption -- the design's one and only
-- section header.  Returns its height so callers can stack below.
function Kit.caption(x, y, str, c)
  if not G then return Kit.textHeight("caption") end
  local f = font("caption")
  if not f then return 12 end
  G.setFont(f)
  Theme.col(c or PAL.caption, 1)
  Theme.spaced(f, str, Theme.snap(x), Theme.snap(y), 2 * Kit.scale)
  return f:getHeight()
end

function Kit.captionWidth(str)
  return Theme.spacedWidth(font("caption"), str, 2 * Kit.scale)
end

-- ------------------------------------------------------------- frame cycle
function Kit.beginFrame(mx, my, clicked, wheel)
  Kit.mouseX, Kit.mouseY = mx or 0, my or 0
  Kit.mouseClicked = clicked and true or false
  Kit.wheelY = wheel or 0
  Kit._fieldHit, Kit._focusDrawn = false, false
  local down = false
  if love and love.mouse and love.mouse.isDown then
    down = love.mouse.isDown(1) and true or false
  end
  Kit.mouseDown = down
  if not down then Kit._drag = nil end
  Kit.resetClip()
  Kit.blockClicks = false
  Kit.occlude(nil)
  if love and love.timer and love.timer.getTime then
    Kit.time = love.timer.getTime()
  end
  Transition.update(Kit.time)
  if Transition.active() then Kit.blockClicks = true end
  -- Resolve any queued focus-ring movement against LAST frame's geometry.
  -- Immediate mode has no geometry until the frame is built, and the ring
  -- must move before widgets test themselves against it.
  -- compared with last frame, not just this resolve: a host that moves the
  -- ring itself (the game a finished import selects) scrolls it into view too
  -- the on-screen keyboard's Done / Cancel, pressed after its field already
  -- drew this frame, reach the field on the next
  if Kit._carry then
    for _, e in ipairs(Kit._carry) do edits[#edits + 1] = e end
    Kit._carry = nil
  end
  local before = Kit._focusShownLast
  Kit._resolveNav()
  if Kit.focusId ~= before and Kit._ringShown then Kit._revealFocus() end
  Kit._focusShownLast = Kit.focusId
  -- Start collecting this frame's focusables.
  Kit._navN = 0
end

-- The ring moved onto a control a scroll region has clipped out of view:
-- remember where it sat, and that region's next Kit.scrollInput scrolls it
-- back into view.
function Kit._revealFocus()
  Kit._reveal = nil
  for i = 1, Kit._navPrevN or 0 do
    local c = Kit._nav[i]
    if c.id == Kit.focusId then
      if c.clipH and (c.y < c.clipY or c.y + c.h > c.clipY + c.clipH) then
        Kit._reveal = { y = c.y, h = c.h, clipX = c.clipX, clipY = c.clipY, clipH = c.clipH }
      end
      return
    end
  end
end

local function getNavLayer(slot)
  if not slot then return 3 end
  local id = tostring(slot.id or "")
  local y = slot.y or 0

  -- Layer 1: Top Bar (Settings / Gear, Close / Quit, Save Sync).  tab-sync
  -- rides the gear's cluster; by its tab- prefix alone it fell into layer 2,
  -- so Right from it found nothing and Up jumped sideways to the gear.
  if id == "gear" or id == "settings" or id == "close" or id == "quit"
      or id == "tab-sync"
      or (y < 45 * Kit.scale and not id:match("^tab%-")) then
    return 1
  end

  -- Layer 2: ROM Select & Feature Tabs (Red, Blue, Yellow, Gold, Silver, Crystal, Mods, Find, Skins, Bug)
  if id:match("^tab%-") or (y >= 45 * Kit.scale and y < 105 * Kit.scale and (slot.h and slot.h < 50 * Kit.scale)) then
    return 2
  end

  -- Layer 4: Footer (Patch notes, Updater, BCG, Export, etc.)
  local screenH = (love and love.graphics and love.graphics.getHeight and love.graphics.getHeight()) or 480
  if id == "patch-notes" or id == "updater" or id == "bcg"
      or id:match("^footer") or (y > screenH - 55 * Kit.scale) then
    return 4
  end

  -- Layer 3: Main content panel (Import ROM / Play, Manage, Save slots, Mods list, Find mods, etc.)
  return 3
end

-- Retire this frame's keystrokes, wheel notches and one-shot activations.
-- Anything typed while no field had focus is dropped here rather than
-- replayed into the next field that gets clicked.
function Kit.endFrame()
  -- the on-screen keyboard is the field's input while it is up: a tap on its
  -- keys is not a click away from the field
  local vkUp = VirtualKeyboard.active or (Kit._carry and #Kit._carry > 0)
  if Kit.focus and not vkUp
      and ((Kit.mouseClicked and not Kit._fieldHit) or not Kit._focusDrawn) then
    Kit.blur()
  end
  for i = #edits, 1, -1 do edits[i] = nil end
  Kit.wheelY = 0
  Kit._activateId, Kit._padActivate = nil, nil
  -- This frame's focusables become next frame's navigation graph.
  local n = Kit._navN or 0
  Kit._navPrevN = n
  -- If the focused id vanished or not set yet, park the ring on Layer 3 (Import ROM / Play)
  -- a host mid-transition (the launcher's page slide registers nothing it
  -- is sliding in) keeps the ring where it is until there is a page to land on
  if (not Kit.focusId or not Kit._navSeen[Kit.focusId]) and n > 0 and not Kit.holdFocus then
    -- 0. A host with columns names where the ring belongs (the launcher:
    --    the chosen save, else the chosen game)
    local chosen = nil
    if Kit.navAnchor then
      for _, col in ipairs({ "content", "list" }) do
        local id = Kit.navAnchor(col)
        if id and Kit._navSeen[id] then chosen = id break end
      end
    end
    -- 0b. The control that held the ring went away under it (a "-" that
    --     disabled itself at 0, a row that closed): the nearest one left on
    --     the same side of the rail, not the rail's first button
    local gone = Kit._lastFocusRect
    if not chosen and gone and Kit.focusId and gone.id == Kit.focusId then
      local gx, gy = gone.x + gone.w / 2, gone.y + gone.h / 2
      local rail = tostring(gone.id):match("^nav%-") ~= nil
      local best
      for i = 1, n do
        local slot = Kit._nav[i]
        if slot and slot.id and (tostring(slot.id):match("^nav%-") ~= nil) == rail then
          local dx, dy = slot.x + slot.w / 2 - gx, slot.y + slot.h / 2 - gy
          -- the same row first: "-" at 0 hands the ring to its own "+"
          local d = dx * dx + 9 * dy * dy
          if not best or d < best then best, chosen = d, slot.id end
        end
      end
    end
    -- 1. Prefer ROM Action (Layer 3)
    for i = 1, chosen and 0 or n do
      local slot = Kit._nav[i]
      if slot and slot.id and tostring(slot.id):match("^rom%-") then
        chosen = slot.id; break
      end
    end
    -- 2. Prefer any Layer 3 control
    if not chosen then
      for i = 1, n do
        local slot = Kit._nav[i]
        if slot and getNavLayer(slot) == 3 then
          chosen = slot.id; break
        end
      end
    end
    Kit.focusId = chosen or (Kit._nav[1] and Kit._nav[1].id) or nil
  end
  for k in pairs(Kit._navSeen) do Kit._navSeen[k] = nil end
end

-- ------------------------------------------------------------ focus ring
-- Spatial navigation.  Every focusable control registers its rect as it
-- draws; a queued direction picks the nearest candidate in that direction
-- from the previous frame's set.
Kit._nav = {}
Kit._navN = 0
Kit._navPrevN = 0
Kit._navSeen = {}
Kit._navQueue = nil
Kit._activateId = nil
Kit._ringShown = true

-- Register a focusable.  Returns true when it currently holds the ring.
function Kit.focusable(id, x, y, w, h)
  if Kit.blockClicks then return false end
  local n = (Kit._navN or 0) + 1
  Kit._navN = n
  local slot = Kit._nav[n]
  if not slot then slot = {}; Kit._nav[n] = slot end
  slot.id, slot.x, slot.y, slot.w, slot.h = id, x, y, w, h
  local clip = Kit._clipRect
  slot.clipX, slot.clipY, slot.clipH = clip and clip.x, clip and clip.y, clip and clip.h
  -- drawn inside a popup (Kit._overlay): the ring stays among its items
  slot.overlay = Kit._overlay and true or nil
  Kit._navSeen[id] = true
  if id == Kit.focusId then
    local r = Kit._lastFocusRect or {}
    r.id, r.x, r.y, r.w, r.h = id, x, y, w, h
    Kit._lastFocusRect = r
  end
  if Kit.focusId == nil and tostring(id):match("^rom%-") then
    Kit.focusId = id
  end
  return Kit._ringShown and Kit.focusId == id
end

function Kit.navigate(dir)
  Kit._navQueue = dir
  Kit._ringShown = true
end

function Kit.activateFocused()
  if Kit.focusId then Kit._activateId = Kit.focusId end
end

function Kit.setFocus(id)
  Kit.focusId = id
  Kit._ringShown = id ~= nil
end

function Kit.pointerUsed()
  Kit._ringShown = false
end

-- Column navigation, for a host that lays its screen out in columns (the
-- launcher: rail | game list | content).  The host sets, for its own frame
-- only:
--   Kit.navColumn(slot) -> column name, or "skip" to leave a control out
--   Kit.navColumnOrder  -> column names left to right
--   Kit.navAnchor(col)  -> optional id to land on when entering that column
-- Left/Right stay in the row they are in, else step to the next column;
-- Up/Down stay in the column, crossing only when nothing is left that way.
function Kit._resolveColumns(cur, dir, n)
  local colOf = Kit.navColumn
  local curCol = colOf(cur)
  local cx, cy = cur.x + cur.w / 2, cur.y + cur.h / 2
  local function each(fn)
    for i = 1, n do
      local c = Kit._nav[i]
      -- inside a popup, only its own items: the cards under it are not reachable
      if c.id ~= cur.id and colOf(c) ~= "skip" and (not cur.overlay or c.overlay) then
        fn(c, colOf(c))
      end
    end
  end
  local best, bestScore
  local function offer(c, score)
    if not bestScore or score < bestScore then best, bestScore = c, score end
  end
  if dir == "left" or dir == "right" then
    each(function(c, col)
      local dx = c.x + c.w / 2 - cx
      local dy = math.abs(c.y + c.h / 2 - cy)
      local forward = dir == "right" and dx or -dx
      if col == curCol and forward > 1 and dy < math.max(cur.h, c.h) / 2 then offer(c, forward) end
    end)
    if best then Kit.focusId = best.id return end
    local order, at = Kit.navColumnOrder or {}, nil
    for i, name in ipairs(order) do if name == curCol then at = i end end
    if not at then return end
    local step = dir == "right" and 1 or -1
    local i = at + step
    while order[i] do
      local target = order[i]
      local anchor = Kit.navAnchor and Kit.navAnchor(target)
      -- a column with no anchor of its own (the Settings page) is entered at
      -- its first control, top left, not whichever sits level with the rail
      -- button (Sound volume "-")
      local hasAnchor = false
      if anchor then
        each(function(c, col) if col == target and c.id == anchor then hasAnchor = true end end)
      end
      each(function(c, col)
        if col == target then
          local score
          if hasAnchor then
            score = c.id == anchor and -1 or math.abs(c.y + c.h / 2 - cy)
          elseif target == "content" then
            score = c.y * 4096 + c.x
          else
            score = math.abs(c.y + c.h / 2 - cy)
          end
          offer(c, score)
        end
      end)
      if best then Kit.focusId = best.id return end
      i = i + step
    end
    return
  end
  -- Down / Up go to the NEXT row first, then to the control in it nearest
  -- sideways: scoring distance and sideways gap together let a control far
  -- to the right (Mod tools' Back, its Safe mode switch) skip a whole row of
  -- buttons for one further down that happened to sit under it.
  local function vertical(sameColumn)
    local cands, nearest = {}, nil
    each(function(c, col)
      if (col == curCol) == sameColumn then
        local dy = (c.y + c.h / 2) - cy
        local forward = dir == "down" and dy or -dy
        local gap = math.max(0, c.x - (cur.x + cur.w), cur.x - (c.x + c.w))
        -- into another column only straight down/up (a stacked phone layout,
        -- the tab bar), never sideways into the next column over
        if forward > 1 and (sameColumn or gap == 0) then
          cands[#cands + 1] = { c = c, forward = forward, gap = gap }
          if not nearest or forward < nearest then nearest = forward end
        end
      end
    end)
    if not nearest then return end
    local band = nearest + math.max(cur.h, 12)
    for _, it in ipairs(cands) do
      if it.forward <= band then offer(it.c, it.gap * 4 + it.forward) end
    end
  end
  vertical(true)
  if not best then vertical(false) end
  if best then Kit.focusId = best.id end
end

function Kit._resolveNav()
  local dir = Kit._navQueue
  Kit._navQueue = nil
  local n = Kit._navPrevN or 0
  if not dir or n == 0 then return end
  local cur
  for i = 1, n do
    if Kit._nav[i].id == Kit.focusId then cur = Kit._nav[i]; break end
  end
  if not cur then
    Kit.focusId = Kit._nav[1].id
    return
  end

  if Kit.navColumn then return Kit._resolveColumns(cur, dir, n) end

  local curLayer = getNavLayer(cur)
  local cx, cy = cur.x + cur.w / 2, cur.y + cur.h / 2

  if tostring(cur.id):match("^gamepop%-") then
    local best, bestScore
    for i = 1, n do
      local c = Kit._nav[i]
      if c.id ~= cur.id and tostring(c.id):match("^gamepop%-") then
        local dx, dy = c.x + c.w / 2 - cx, c.y + c.h / 2 - cy
        local horizontal = dir == "left" or dir == "right"
        local forward = (dir == "left" and -dx) or (dir == "right" and dx)
          or (dir == "up" and -dy) or dy
        local cross = math.abs(horizontal and dy or dx)
        if forward > 1 and (not horizontal or cross < 1) then
          local score = forward + cross * 2
          if not bestScore or score < bestScore then
            best, bestScore = c, score
          end
        end
      end
    end
    if best then Kit.focusId = best.id end
    return
  end

  if dir == "left" or dir == "right" then
    -- STRICT SAME-LAYER HORIZONTAL NAVIGATION (Left/Right NEVER jumps between layers)
    local best, bestDx
    for i = 1, n do
      local c = Kit._nav[i]
      if c.id ~= cur.id and getNavLayer(c) == curLayer then
        local cMidX = c.x + c.w / 2
        local dx = cMidX - cx
        if dir == "left" and dx < -1 then
          local dist = -dx
          if not bestDx or dist < bestDx then
            best, bestDx = c, dist
          end
        elseif dir == "right" and dx > 1 then
          local dist = dx
          if not bestDx or dist < bestDx then
            best, bestDx = c, dist
          end
        end
      end
    end
    if best then
      Kit.focusId = best.id
      return
    end
    return
  elseif dir == "up" or dir == "down" then
    -- Within the layer first: the nearest control above/below in the same
    -- layer wins, so Down from the cart reaches the Scan / Import button under
    -- it instead of jumping over it to the footer.  The horizontal gap weighs
    -- double so a control straight below beats one off to the side.
    do
      local best, bestScore
      for i = 1, n do
        local c = Kit._nav[i]
        if c.id ~= cur.id and getNavLayer(c) == curLayer then
          local dy = (c.y + c.h / 2) - cy
          local forward = dir == "down" and dy or -dy
          if forward > 1 then
            local gap = math.max(0, c.x - (cur.x + cur.w), cur.x - (c.x + c.w))
            local score = forward + gap * 2
            if not bestScore or score < bestScore then
              best, bestScore = c, score
            end
          end
        end
      end
      if best then
        Kit.focusId = best.id
        return
      end
    end
    -- VERTICAL LAYER NAVIGATION (Up/Down steps between layers: 1 <-> 2 <-> 3 <-> 4)
    local targetLayer = dir == "up" and (curLayer - 1) or (curLayer + 1)
    targetLayer = math.max(1, math.min(4, targetLayer))

    local best, bestScore
    for i = 1, n do
      local c = Kit._nav[i]
      if c.id ~= cur.id then
        local l = getNavLayer(c)
        if (dir == "up" and l < curLayer) or (dir == "down" and l > curLayer) then
          local layerDiff = math.abs(l - targetLayer)
          local cMidX = c.x + c.w / 2
          local xDist = math.abs(cMidX - cx)
          local score = layerDiff * 10000 + xDist
          if not bestScore or score < bestScore then
            best, bestScore = c, score
          end
        end
      end
    end
    if best then
      Kit.focusId = best.id
      return
    end
  end
end

-- ------------------------------------------------------------ input plumbing
function Kit.textinput(text)
  if VirtualKeyboard.active then
    return VirtualKeyboard.textinput(text)
  end
  if not Kit.focus then return false end
  edits[#edits + 1] = text
  return true
end

-- Returns true when the key was consumed, so the host can leave its own
-- shortcuts alone while the user is typing or driving the ring.
function Kit.keypressed(key)
  if VirtualKeyboard.active then
    return VirtualKeyboard.keypressed(key)
  end
  if FileBrowser.active then
    return FileBrowser.keypressed(key)
  end
  if Kit.focus then
    local isDown = love and love.keyboard and love.keyboard.isDown
    local ctrl = isDown and (isDown("lctrl") or isDown("rctrl") or isDown("lgui") or isDown("rgui"))
    if ctrl and key == "a" then edits[#edits + 1] = "\1" return true end
    if key == "backspace" then edits[#edits + 1] = "\b" return true
    elseif key == "return" or key == "kpenter" then
      edits[#edits + 1] = "\r" return true
    elseif key == "escape" then
      edits[#edits + 1] = "\27" return true
    elseif key == "tab" or key == "up" or key == "down" then
      Kit.blur()
      Kit.navigate(key == "up" and "up" or "down")
      return true
    end
    -- printable keys arrive through textinput; everything else falls through
    return false
  end
  if key == "up" or key == "down" or key == "left" or key == "right" then
    Kit.navigate(key)
    return true
  elseif key == "return" or key == "kpenter" or key == "space" then
    Kit.activateFocused()
    return true
  end
  return false
end

-- Gamepad d-pad / stick, routed by the host's pad handling.
function Kit.gamepadpressed(button)
  local GamepadMap = require("src.core.GamepadMap")
  local action = (GamepadMap.mapLauncherButton and GamepadMap.mapLauncherButton(button)) or button
  if VirtualKeyboard.active then
    return VirtualKeyboard.gamepadpressed(action)
  end
  if FileBrowser.active then
    return FileBrowser.gamepadpressed(action)
  end
  -- B leaves a text field the way Escape does: the field ends "cancel", so
  -- its owner closes it too (a bare blur left the save Rename row open)
  if Kit.focus and action == "b" then edits[#edits + 1] = "\27" return true end
  if action == "dpup" then Kit.navigate("up") return true
  elseif action == "dpdown" then Kit.navigate("down") return true
  elseif action == "dpleft" then Kit.navigate("left") return true
  elseif action == "dpright" then Kit.navigate("right") return true
  elseif action == "a" then
    Kit.activateFocused()
    -- a text field opened from the pad gets the on-screen keyboard, wherever
    -- it runs: there may be no keyboard to type with (a Steam Deck)
    Kit._padActivate = true
    return true
  end
  return false
end

function Kit.blur()
  Kit.focus = nil
  Kit.selectAll = nil
  syncSoftKeyboard(nil)
end

-- -------------------------------------------------------------- hit testing
local occluderBoxes = {}
Kit._occluders = 0
Kit._occluder = nil
Kit._overlay = false

function Kit.occlude(x, y, w, h)
  if x == nil then
    Kit._occluders = 0
    Kit._occluder = nil
    return
  end
  local n = Kit._occluders + 1
  local o = occluderBoxes[n]
  if not o then
    o = {}
    occluderBoxes[n] = o
  end
  o.x, o.y, o.w, o.h = x, y, w, h
  Kit._occluders = n
  Kit._occluder = occluderBoxes[1]
end

function Kit.occluded()
  if Kit._occluders == 0 or Kit._overlay then return false end
  local mx, my = Kit.mouseX, Kit.mouseY
  for i = 1, Kit._occluders do
    local o = occluderBoxes[i]
    if mx >= o.x and mx <= o.x + o.w and my >= o.y and my <= o.y + o.h then
      return true
    end
  end
  return false
end

-- A widget inside a clip region can sit at coordinates outside the visible
-- rect, so the active clip bounds the hit: what the user cannot see cannot
-- take the tap.
-- A pointer press inside the rect this frame.  A row that holds a button
-- asks this, not Kit.hit, before treating its own press as the row's: a row
-- activated by Enter or A while the pointer happens to rest over its button
-- is still the row being chosen.
function Kit.clickIn(x, y, w, h)
  return Kit.mouseClicked and Kit.hit(x, y, w, h)
end

function Kit.hit(x, y, w, h)
  local c = Kit._clipRect
  if c and not (Kit.mouseX >= c.x and Kit.mouseX <= c.x + c.w
      and Kit.mouseY >= c.y and Kit.mouseY <= c.y + c.h) then
    return false
  end
  if Kit._occluders > 0 and Kit.occluded() then return false end
  return Kit.mouseX >= x and Kit.mouseX <= x + w
     and Kit.mouseY >= y and Kit.mouseY <= y + h
end

function Kit.hover(x, y, w, h)
  -- Shielded widgets (drawn while a modal owns the frame) must not glow
  -- either: a hover highlight under the scrim reads as "still clickable".
  if Kit.blockClicks then return false end
  return Kit.hit(x, y, w, h)
end

function Kit.press(x, y, w, h)
  if Kit.blockClicks then return false end
  return Kit.mouseClicked and Kit.hit(x, y, w, h)
end

-- Layout audit: when a test sets Kit.audit to a table, every control that
-- could take a click this frame appends its rect (plus the clip that bounds
-- it), so a window-size sweep can assert no two controls overlap and none
-- escapes the window.  Shielded widgets are skipped: under a modal they
-- cannot take the tap, and the modal legitimately covers them.
local function audit(class, x, y, w, h, label)
  local a = Kit.audit
  if not a or Kit.blockClicks then return end
  local c = Kit._clipRect
  a[#a + 1] = { class = class, x = x, y = y, w = w, h = h,
    label = tostring(label or ""),
    clip = c and { x = c.x, y = c.y, w = c.w, h = c.h } or nil }
end
Kit._audit = audit

-- ------------------------------------------------------------------ metrics
-- Minimum tap target.  30px at scale 1 (up from the editor's 26) because the
-- launcher is the first thing a phone user touches and these are the only
-- controls that matter.
function Kit.tapMin() return math.floor(30 * Kit.scale) end

-- ---------------------------------------------------------------- surfaces
function Kit.card(x, y, w, h, variant)
  Theme.card(x, y, w, h, variant)
end

function Kit.row(x, y, w, h, selected, id)
  audit("row", x, y, w, h, id or "row")
  local focused = id and Kit.focusable(id, x, y, w, h) or false
  local hot = Kit.hover(x, y, w, h)
  local state = selected and "selected" or (hot and "hover" or nil)
  local ink = Theme.row(x, y, w, h, state)
  -- The focus ring is the accent, inset, so it reads on both a dark row and
  -- a white selected one (white on white vanished).
  if focused then
    Theme.strokeRounded(x + 1, y + 1, w - 2, h - 2, PAL.blue, 1, 3, Theme.radius())
  end
  local clicked = Kit.press(x, y, w, h)
    or (id ~= nil and Kit._activateId == id)
  return clicked, ink
end

-- Empty-state box: hairline outline and a centred hint.  (The old dashed
-- border sampled a rounded path into a polyline every frame; a solid
-- hairline says the same thing for one rect.)
function Kit.emptyBox(x, y, w, h, message)
  if not G then return end
  Theme.card(x, y, w, h, "empty")
  Kit.textCenter("button", Kit.ellipsize("button", message, w - 24 * Kit.scale),
    x, y + (h - Kit.textHeight("button")) / 2, w, PAL.muted)
end

-- ----------------------------------------------------------------- buttons
-- Primary actions carry color; secondary and destructive actions use a quiet
-- surface and an outline. All faces share an inset hover/press highlight and
-- a solid keyboard focus border, so controls never grow into their neighbors.
local Button = require("src.ui.kit.Button")
local Icons = require("src.ui.kit.Icons")
Kit.KINDS = Button.KINDS
local NO_OPTS = {}

function Kit.button(x, y, w, h, label, opts)
  opts = opts or NO_OPTS
  local enabled = opts.enabled ~= false
  audit("control", x, y, w, h, label)
  local focused = enabled and opts.id
    and Kit.focusable(opts.id, x, y, w, h) or false
  local hot = enabled and Kit.hover(x, y, w, h)
  Button.draw(Kit, x, y, w, h, label, opts, hot, focused)
  if not enabled then return false end
  return Kit.press(x, y, w, h)
    or (not Kit.blockClicks and opts.id ~= nil
      and Kit._activateId == opts.id)
end

function Kit.stepper(x, y, w, h, glyph, opts)
  opts = opts or {}
  opts.kind = opts.kind or "ghost"
  opts.font = opts.font or "small"
  return Kit.button(x, y, w, h, glyph, opts)
end

local CHIP_OPTS = { face = "chip", font = "micro" }

function Kit.chip(x, y, w, h, label, on, color, id)
  CHIP_OPTS.active = on
  CHIP_OPTS.color = color
  CHIP_OPTS.id = id
  return Kit.button(x, y, w, h, label, CHIP_OPTS)
end

-- A status label with no interaction: outlined text, the "INSTALLED"/"UPDATE"
-- markers on mod rows.  Pass opts.fill for a solid chip (BETA badges); ink
-- then follows the fill so the label stays readable.
function Kit.tag(x, y, w, h, label, color, opts)
  if not G then return end
  opts = opts or {}
  if opts.fill then
    Theme.fillRounded(x, y, w, h, color or PAL.yellow, 1, h / 2)
  else
    Theme.strokeRounded(x, y, w, h, color or PAL.line, 0.7, 1)
  end
  local ink = opts.ink or (opts.fill and Theme.inkOn(color or PAL.yellow)) or color or PAL.muted
  local ty = y + (h - Kit.textHeight("micro")) / 2
  if opts.bold then
    Kit.textCenterBold("micro", label, x, ty, w, ink)
  else
    Kit.textCenter("micro", label, x, ty, w, ink)
  end
end

local TOAST_ACCEPT = { kind = "primary", font = "small" }
local TOAST_DECLINE = { kind = "ghost", font = "small" }

function Kit.toastRect(W, text, top, slide)
  local s = Kit.scale
  local margin = math.floor(16 * s)
  local w = math.floor(math.min(360 * s, (W or 0) - 2 * margin))
  local pad = math.floor(12 * s)
  local gap = math.floor(8 * s)
  local icon = math.floor(22 * s)
  local btnH = math.max(Kit.tapMin(), math.floor(30 * s))
  local barH = math.max(2, math.floor(3 * s))
  local textW = w - 2 * pad - icon - gap
  local textH = Kit.wrapHeight("small", text or "", textW, 2)
  local h = pad + math.max(icon, textH) + gap + btnH + gap + barH + pad
  local x = (W or 0) - w - margin
  x = x + math.floor((1 - (slide or 1)) * (w + margin))
  return x, top or margin, w, h
end

function Kit.toast(opts)
  opts = opts or NO_OPTS
  local s = Kit.scale
  local x, y, w, h = Kit.toastRect(opts.W, opts.text, opts.top, opts.slide)
  local pad = math.floor(12 * s)
  local gap = math.floor(8 * s)
  local icon = math.floor(22 * s)
  local btnH = math.max(Kit.tapMin(), math.floor(30 * s))
  local barH = math.max(2, math.floor(3 * s))
  local wasOverlay, wasBlock = Kit._overlay, Kit.blockClicks
  Kit._overlay = true
  Kit.blockClicks = opts.blocked == true
  local action = nil
  if G then
    Kit.card(x, y, w, h, true)
    Theme.strokeRounded(x, y, w, h, PAL.lineStrong, Theme.A.focus, 1)
    Icons.draw(opts.icon or "mail", x + pad, y + pad, icon, PAL.heading, 1)
  end
  local tx = x + pad + icon + gap
  Kit.textWrapped("small", opts.text or "", tx, y + pad, w - 2 * pad - icon - gap,
    PAL.heading, 2)
  local by = y + h - pad - barH - gap - btnH
  local half = math.floor((w - 2 * pad - gap) / 2)
  local id = opts.id or "toast"
  TOAST_DECLINE.id = id .. "-decline"
  TOAST_ACCEPT.id = id .. "-accept"
  if Kit.button(x + pad, by, half, btnH, opts.decline or "Decline",
      TOAST_DECLINE) then
    action = "decline"
  end
  if Kit.button(x + pad + half + gap, by, w - 2 * pad - half - gap, btnH,
      opts.accept or "Accept", TOAST_ACCEPT) then
    action = "accept"
  end
  if G then
    local bw = w - 2 * pad
    local left = math.max(0, math.min(1, opts.progress or 1))
    Theme.fillRounded(x + pad, y + h - pad - barH, bw, barH, PAL.line, 0.5, barH / 2)
    if left > 0 then
      Theme.fillRounded(x + pad, y + h - pad - barH, math.max(barH, bw * left), barH,
        left < 0.25 and PAL.red or PAL.green, 1, barH / 2)
    end
  end
  Kit._overlay, Kit.blockClicks = wasOverlay, wasBlock
  return action, x, y, w, h
end

-- Checkbox row.  Returns (newChecked, changed).
function Kit.checkbox(x, y, w, h, checked, label, id, labelColor)
  local clicked, ink = Kit.row(x, y, w, h, false, id)
  local box = 20 * Kit.scale
  local bx, by = x + 12 * Kit.scale, y + (h - box) / 2
  if G then
    local br = math.min(Theme.radius(), box / 3)
    if checked then
      Theme.fillRounded(bx, by, box, box, PAL.ink, 1, br)
      Kit.textCenter("small", "X", bx,
        by + (box - Kit.textHeight("small")) / 2, box, PAL.inverse)
    else
      Theme.strokeRounded(bx, by, box, box, PAL.line, Theme.A.hover, 1, br)
    end
    local lx = bx + box + 12 * Kit.scale
    Kit.text("mono", Kit.ellipsize("mono", label, x + w - lx - 10 * Kit.scale),
      lx, y + (h - Kit.textHeight("mono")) / 2,
      labelColor or ink or PAL.text)
  end
  if clicked then return not checked, true end
  return checked, false
end

-- A two-state switch, for the settings ladders.
function Kit.toggle(x, y, w, h, on, id)
  audit("control", x, y, w, h, "toggle")
  local focused = id and Kit.focusable(id, x, y, w, h) or false
  if G then
    -- Track, then a knob inset inside it, so the control reads as a switch
    -- rather than as a white square with a word next to it.  The label sits
    -- in the empty half, which is the half that says what pressing does.
    local r = math.min(Theme.radius(), h / 2)
    Theme.fillRounded(x, y, w, h, PAL.rowBg, 1, r)
    Theme.strokeRounded(x, y, w, h, PAL.line,
      (focused or Kit.hover(x, y, w, h)) and Theme.A.focus or Theme.A.hover, 1, r)
    local inset = 3
    local knob = w / 2 - inset
    Theme.fillRounded(on and (x + w / 2) or (x + inset), y + inset, knob,
      h - 2 * inset, PAL.ink, 1, math.min(r, (h - 2 * inset) / 2))
    Kit.textCenter("micro", on and "ON" or "OFF",
      on and x or (x + w / 2), y + (h - Kit.textHeight("micro")) / 2, w / 2,
      PAL.text)
  end
  local hitTaken = Kit.press(x, y, w, h) or (id ~= nil and Kit._activateId == id)
  if hitTaken then return not on, true end
  return on, false
end

-- A determinate progress bar with an optional caption.
function Kit.progress(x, y, w, h, frac, label)
  Theme.meter(x, y, w, h, (frac or 0) * 100, PAL.ink)
  if label then
    Kit.text("micro", label, x, y + h + 4 * Kit.scale, PAL.muted)
  end
end

-- --------------------------------------------------------------- text field
-- opts (optional): { digits = true, maxLen = n } opens the on-screen
-- keyboard on its number pad with that limit (a room PIN).
function Kit.textfield(id, x, y, w, h, value, placeholder, opts)
  audit("control", x, y, w, h, id)
  local focusRing = Kit.focusable(id, x, y, w, h)
  value = tostring(value or "")

  local isHandheld = os.getenv("HANDHELD") == "1" or os.getenv("PORTMASTER") == "1"
    or os.getenv("POKEPORT_HANDHELD") == "1" or os.getenv("TRIMUI") == "1"
    or os.getenv("MUOS") == "1" or os.getenv("KNULLI") == "1"
    or os.getenv("POKEPORT_SBC") == "1" or os.getenv("ANBERNIC") == "1"

  local clickedOrActivated = (Kit._activateId == id) or (isHandheld and Kit.press(x, y, w, h))
  local fromPad = Kit._activateId == id and Kit._padActivate
  if (isHandheld or fromPad) and clickedOrActivated and not mobile() then
    local before = value
    VirtualKeyboard.open({
      digits = opts and opts.digits or nil,
      maxLen = opts and opts.maxLen or nil,
      force = fromPad,
      text = value,
      targetId = id,
      title = placeholder or "Enter Text",
      onDone = function(newText, confirmed)
        -- carried to the next frame (beginFrame): a tap on Done lands after
        -- this field has drawn, and endFrame would drop it
        Kit._carry = Kit._carry or {}
        if confirmed then
          Kit._carry[#Kit._carry + 1] = "\r"
        else
          -- cancelled: the text goes back to what it was, and the field ends
          Kit._restore = { id = id, value = before }
          Kit._carry[#Kit._carry + 1] = "\27"
        end
      end
    })
  end

  if VirtualKeyboard.active and VirtualKeyboard.targetId == id then
    value = VirtualKeyboard.text
  elseif Kit._restore and Kit._restore.id == id then
    value = Kit._restore.value
    Kit._restore = nil
  end

  if Kit.press(x, y, w, h) then Kit._fieldHit = true end
  if Kit.press(x, y, w, h) or (Kit._activateId == id) then Kit.focus = id end
  local focused = (Kit.focus == id)
  local ended
  if focused then
    syncSoftKeyboard(id, x, y, w, h)
    for _, e in ipairs(edits) do
      -- select all (Ctrl+A, or a host that opens a field to be replaced):
      -- the next key replaces the whole text
      if e == "\1" then
        Kit.selectAll = id
      elseif Kit.selectAll == id and e ~= "\r" and e ~= "\27" then
        value = ""
        Kit.selectAll = nil
      end
      if e == "\1" then -- luacheck: ignore 542
      elseif e == "\b" then
        -- one whole character: a UTF-8 lead byte and its continuation bytes
        value = value:gsub("[^\128-\191][\128-\191]*$", "", 1)
      elseif e == "\r" or e == "\27" then
        Kit.blur()
        focused = false
        ended = e == "\r" and "submit" or "cancel"
        break
      else
        value = value .. e
      end
    end
    if focused then Kit._focusDrawn = true end
  end
  if G then
    Theme.fillRounded(x, y, w, h, PAL.bg, 1)
    Theme.strokeRounded(x, y, w, h, PAL.line,
      (focused or focusRing) and Theme.A.focus or Theme.A.hairline,
      focused and 2 or 1)
    local pad = 10 * Kit.scale
    local ty = y + (h - Kit.textHeight("mono")) / 2
    if value == "" and not focused then
      Kit.text("mono", Kit.ellipsize("mono", placeholder or "", w - 2 * pad), x + pad, ty, PAL.faint)
    else
      local shown = Kit.ellipsizeLeft("mono", value, w - 2 * pad)
      if focused and Kit.selectAll == id and value ~= "" then
        Theme.fill(x + pad - 2, ty - 1, Kit.textWidth("mono", shown) + 4,
          Kit.textHeight("mono") + 2, PAL.blue, 0.45)
      end
      local tw = Kit.text("mono", shown, x + pad, ty, PAL.heading)
      if focused and (Kit.time % 1) < 0.55 then
        Theme.fill(x + pad + tw + 2, ty, math.max(1, Kit.scale),
          Kit.textHeight("mono"), PAL.ink, 1)
      end
    end
  end
  -- "submit" on Enter, "cancel" on Escape, the frame the field lets go
  return value, ended
end

-- -------------------------------------------------------------------- pager
-- Prev / Next / "1-12 of 151".  Drawn even for a single page, so a list is
-- never silently truncated.  A long list still PAGES rather than scrolling:
-- no momentum, bounded row count per frame.
-- Returns the new page (1-based) and the row height consumed.
local pagerLabels = {}

function Kit.pager(x, y, w, page, total, perPage, idPrefix, compact)
  local h = math.max(Kit.tapMin(), 30 * Kit.scale)
  local bw = 74 * Kit.scale
  local pages = math.max(1, math.ceil(total / math.max(1, perPage)))
  page = math.floor(Theme.clamp(page or 1, 1, pages))
  local gap = 8 * Kit.scale
  idPrefix = idPrefix or "pager"

  if Kit.button(x, y, bw, h, "Prev", { kind = "ghost", font = "small", icon = "chevron-left",
      enabled = page > 1, id = idPrefix .. ":prev" }) then
    page = math.max(1, page - 1)
  end
  if Kit.button(x + bw + gap, y, bw, h, "Next", { kind = "ghost", icon = "chevron-right",
      font = "small", enabled = page < pages, id = idPrefix .. ":next" }) then
    page = math.min(pages, page + 1)
  end

  local first = total > 0 and ((page - 1) * perPage + 1) or 0
  local last = math.min(total, page * perPage)
  -- One memo per pager id.  The counts only change when the user pages or the
  -- list does; formatting them every frame minted a new string that then
  -- missed the width / ellipsis / Text caches by content.
  local memo = pagerLabels[idPrefix]
  if not memo then memo = {}; pagerLabels[idPrefix] = memo end
  if memo.first ~= first or memo.last ~= last or memo.total ~= total
      or memo.page ~= page or memo.pages ~= pages then
    memo.first, memo.last, memo.total = first, last, total
    memo.page, memo.pages = page, pages
    memo.label = ("%d-%d of %d   (page %d/%d)")
      :format(first, last, total, page, pages)
  end
  local label = compact and (tostring(page) .. " / " .. tostring(pages)) or memo.label
  local labelX = x + 2 * bw + 2 * gap + gap
  Kit.text("mono", Kit.ellipsize("mono", label, math.max(0, x + w - labelX)),
    labelX, y + (h - Kit.textHeight("mono")) / 2, PAL.caption)
  return page, h
end

-- Slice helper so callers never hand-roll page arithmetic (and never draw a
-- row that is off the page -- the entire performance claim rests on this).
function Kit.pageBounds(page, total, perPage)
  local pages = math.max(1, math.ceil(total / math.max(1, perPage)))
  page = math.floor(Theme.clamp(page or 1, 1, pages))
  local first = (page - 1) * perPage + 1
  local last = math.min(total, page * perPage)
  return first, last, page, pages
end

-- How many rows of `rowH` (plus `gap`) fit in `h` pixels.  Panels call this
-- to derive perPage from the real viewport instead of a magic number, so a
-- tall window shows more rows and a phone shows fewer -- with no scrolling
-- either way.
function Kit.rowsThatFit(h, rowH, gap, minRows, maxRows)
  local per = math.floor((h + (gap or 0)) / math.max(1, rowH + (gap or 0)))
  return math.max(minRows or 1, math.min(maxRows or 99, per))
end

Kit.dragX = nil
Kit.dragY = nil
Kit.dragAccum = 0

function Kit.dragBegin(x, y)
  Kit.dragX, Kit.dragY, Kit.dragAccum = x, y, 0
end

function Kit.dragAdd(dy)
  if Kit.dragX then Kit.dragAccum = Kit.dragAccum + (dy or 0) end
end

function Kit.dragEnd()
  Kit.dragX, Kit.dragY, Kit.dragAccum = nil, nil, 0
end

local function dragOriginIn(x, y, w, h)
  if not Kit.dragX then return false end
  local x1, y1, x2, y2 = x, y, x + w, y + h
  local c = Kit._clipRect
  if c then
    x1, y1 = math.max(x1, c.x), math.max(y1, c.y)
    x2, y2 = math.min(x2, c.x + c.w), math.min(y2, c.y + c.h)
  end
  return Kit.dragX >= x1 and Kit.dragX <= x2
    and Kit.dragY >= y1 and Kit.dragY <= y2
end

-- Mouse wheel over a paginated list turns PAGES.  The wheel still has to do
-- something (users expect it), but it moves a bounded page index rather than
-- driving a pixel offset, so there is no scroll state and no interpolation.
function Kit.wheelPage(x, y, w, h, page, total, perPage)
  if Kit.blockClicks then return page end
  local pages = math.max(1, math.ceil(total / math.max(1, perPage)))
  local out = page
  if (Kit.wheelY or 0) ~= 0 and Kit.hit(x, y, w, h) then
    out = math.floor(Theme.clamp((out or 1) + (Kit.wheelY > 0 and -1 or 1),
      1, pages))
    Kit.wheelY = 0
  end
  local acc = Kit.dragAccum or 0
  if acc ~= 0 and dragOriginIn(x, y, w, h) then
    local stepPx = math.max(1, math.floor((h or 0) / 2))
    local flips = acc >= 0 and math.floor(acc / stepPx)
      or -math.floor(-acc / stepPx)
    if flips ~= 0 then
      local want = (out or 1) + flips
      out = math.floor(Theme.clamp(want, 1, pages))
      Kit.dragAccum = out ~= want and 0 or acc - flips * stepPx
    end
  end
  return out
end

function Kit.scrollExtent(contentH, viewH)
  return math.max(0, (contentH or 0) - math.max(0, viewH or 0))
end

function Kit.scrollClamp(offset, maxScroll)
  return math.max(0, math.min(offset or 0, math.max(0, maxScroll or 0)))
end

function Kit.scrollStep(scale)
  return math.floor(48 * (scale or Kit.scale))
end

function Kit.scrollBarW(scale)
  return math.max(2, math.floor(4 * (scale or Kit.scale)))
end

function Kit.scrollGutter(scale)
  return Kit.scrollBarW(scale) + math.max(2, math.floor(4 * (scale or Kit.scale)))
end

function Kit.scrollHandoff(offset, maxScroll, delta)
  local want = (offset or 0) + (delta or 0)
  local at = Kit.scrollClamp(want, maxScroll)
  return at, want - at
end

function Kit.scrollWheel(offset, maxScroll, x, y, w, h, step)
  local at = Kit.scrollClamp(offset, maxScroll)
  local wheel = Kit.wheelY or 0
  if Kit.blockClicks or wheel == 0 or (maxScroll or 0) <= 0 then
    return at, false
  end
  if not Kit.hit(x, y, w, h) then return at, false end
  local moved = Kit.scrollClamp(at - wheel * (step or Kit.scrollStep()),
    maxScroll)
  if moved == at then return at, false end
  Kit.wheelY = 0
  return moved, true
end

function Kit.scrollInput(offset, maxScroll, x, y, w, h)
  local at = Kit.scrollWheel(offset, maxScroll, x, y, w, h)
  if not Kit.blockClicks and (Kit.dragAccum or 0) ~= 0
      and dragOriginIn(x, y, w, h) then
    at = Kit.scrollClamp(at + Kit.dragAccum, maxScroll)
    Kit.dragAccum = 0
  end
  local r = Kit._reveal
  if r and r.clipX >= x - 1 and r.clipX <= x + w and r.clipY >= y - 1 and r.clipY <= y + h then
    local margin = math.floor(8 * Kit.scale)
    if r.y < r.clipY then
      at = Kit.scrollClamp(at - (r.clipY - r.y) - margin, maxScroll)
    elseif r.y + r.h > r.clipY + r.clipH then
      at = Kit.scrollClamp(at + (r.y + r.h - r.clipY - r.clipH) + margin, maxScroll)
    end
    Kit._reveal = nil
  end
  return at
end

function Kit.scrollBegin(x, y, w, h, offset, maxScroll)
  Kit.pushClip(x, y, math.max(0, w or 0), math.max(0, h or 0))
  return y - Kit.scrollClamp(offset, maxScroll)
end

function Kit.scrollEnd(x, y, w, h, offset, maxScroll, background)
  if (maxScroll or 0) > (offset or 0) + 1 and h > 0 then
    local fadeH = math.min(math.floor(24 * Kit.scale), math.floor(h / 4))
    local strength = math.min(1, (maxScroll - (offset or 0)) / math.max(1, fadeH))
    for i = 0, fadeH - 1 do
      Theme.fill(x, y + h - fadeH + i, w - Kit.scrollGutter(), 1,
        background or PAL.field, strength * ((i + 1) / fadeH) ^ 2)
    end
  end
  Kit.popClip()
  if (maxScroll or 0) <= 0 or (h or 0) <= 0 or (w or 0) <= 0 then return end
  local barW = Kit.scrollBarW()
  local barX = x + w - barW
  local at = Kit.scrollClamp(offset, maxScroll)
  local thumbH = math.max(math.floor(20 * Kit.scale),
    math.floor(h * (h / (h + maxScroll))))
  local thumbY = y + (h - thumbH) * (at / maxScroll)
  Kit.scrollBar(barX, y, barW, h, thumbY, thumbH)
end

-- Track and thumb share a capsule so a list scroller matches the meters.
function Kit.scrollBar(x, y, w, h, thumbY, thumbH, trackA, thumbA)
  if w <= 0 or h <= 0 then return end
  Theme.fillRounded(x, y, w, h, PAL.bg, trackA or 0.35, math.min(w, h) / 2)
  local th = thumbH or 0
  if th > 0 then
    Theme.fillRounded(x, thumbY, w, th, PAL.muted, thumbA or 0.7,
      math.min(w, th) / 2)
  end
end

-- ------------------------------------------------------------------ spinner
-- The one animated element in the UI: a rotating arc of ticks.  Drawn as N
-- short lines at descending alpha, which needs no shader, no canvas and no
-- blend-mode change.  `t` defaults to the frame clock so every spinner on
-- screen stays in phase.
function Kit.spinner(cx, cy, r, t)
  if not G or not has("line") then return end
  t = t or Kit.time
  local ticks = 12
  local step = (math.pi * 2) / ticks
  local head = math.floor((t * 10) % ticks)
  if has("setLineWidth") then G.setLineWidth(math.max(2, 2 * Kit.scale)) end
  for i = 0, ticks - 1 do
    local a = ((ticks - ((head - i) % ticks)) / ticks)
    local ang = i * step - math.pi / 2
    local c, s = math.cos(ang), math.sin(ang)
    Theme.col(PAL.ink, a * a)
    G.line(cx + c * r * 0.55, cy + s * r * 0.55, cx + c * r, cy + s * r)
  end
  if has("setLineWidth") then G.setLineWidth(1) end
end

-- ------------------------------------------------------------------- clip
-- Clip drawing to a rect.  A stack: pushes intersect with the rect above and
-- a pop restores that rect rather than clearing the scissor, so a nested
-- region can never unclip its parent.  The tracked rect also bounds Kit.hit,
-- so a widget clipped out of view is inert instead of taking taps aimed at
-- whatever is drawn where it left.
-- The stack rects are pooled by depth and fully overwritten on every push,
-- so a frame that clips a dozen lists allocates nothing.
local clipStack = {}
local clipPool = {}

local function applyClip(rect)
  Kit._clipRect = rect
  if not (G and G.setScissor) then return end
  if not rect then
    G.setScissor()
  elseif rect.w <= 0 or rect.h <= 0 then
    -- LOVE rejects negative scissor dimensions; an exhausted clip region is
    -- empty, not invalid.
    G.setScissor(0, 0, 0, 0)
  else
    G.setScissor(math.floor(rect.x), math.floor(rect.y),
      math.ceil(rect.w), math.ceil(rect.h))
  end
end

function Kit.pushClip(x, y, w, h)
  local prev = clipStack[#clipStack]
  local x2, y2 = x + math.max(0, w), y + math.max(0, h)
  if prev then
    x, y = math.max(x, prev.x), math.max(y, prev.y)
    x2 = math.min(x2, prev.x + prev.w)
    y2 = math.min(y2, prev.y + prev.h)
  end
  local n = #clipStack + 1
  local rect = clipPool[n]
  if not rect then rect = {}; clipPool[n] = rect end
  rect.x, rect.y = x, y
  rect.w, rect.h = math.max(0, x2 - x), math.max(0, y2 - y)
  clipStack[n] = rect
  applyClip(rect)
end

function Kit.popClip()
  clipStack[#clipStack] = nil
  applyClip(clipStack[#clipStack])
end

-- A pcall-ed draw that raised mid-clip must not leak the stack into later
-- frames (every hit test would stay fenced to the dead rect), so the frame
-- boundary clears it.
function Kit.resetClip()
  for i = #clipStack, 1, -1 do clipStack[i] = nil end
  applyClip(nil)
end

return Kit
