-- The launcher's navigation chrome: where you are and how to get elsewhere.
-- No pokered cite: the launcher is port-only chrome.
--
-- Two shapes, picked per frame from the window:
--
--   RAIL (desktop, tablet landscape, TV).  A sidebar pinned to the left edge
--   of the safe area: the wordmark, a LIBRARY list naming every cartridge
--   with its import state, a TOOLS list (Box, Mods, Online, Skins), and the
--   Save Sync / settings / quit cluster at the bottom.  Every game is one
--   click away instead of behind a dropdown, and the page column to the
--   right is capped to a readable measure and centred in what is left.
--
--   BAR (phones, narrow windows).  A slim top bar (wordmark, then the same
--   sync / settings / quit cluster) and a bottom navigation bar with five
--   thumb-reachable destinations: the current game (tap again for the game
--   picker) plus the four tools.
--
-- The rail needs room for the wordmark, a few library rows, the tools and
-- the cluster; a window too short or too narrow for that gets the bar.
--
-- The page panels never know which shape is up: frame() hands them a copy of
-- the metrics narrowed to the page column (x / w / contentX / contentW and
-- the column breakpoints), while modals, toasts and the loader keep the
-- full-window table and centre on the whole window.

local Kit = require("src.ui.kit.Kit")
local Icons = require("src.ui.kit.Icons")
local Theme = require("src.ui.kit.Theme")
local Layout = require("src.ui.kit.Layout")
local Version = require("src.core.Version")
local Strings = require("src.core.Strings")

local PAL = Theme.PAL
local Nav = {}

-- Window width (in layout units) the rail needs before it replaces the bars.
Nav.RAIL_MIN_W = 760
-- Library rows the rail must be able to show before it scrolls them.
local RAIL_MIN_LIB_ROWS = 3
-- The page column's readable measure beside the rail.
local PAGE_MAX_W = 1200
-- Two page columns beside the rail from this width (layout units).  Lower
-- than Layout.BP.twoCol: the rail already took the chrome's share of the
-- width, and the default 1024x768 window should keep its side-by-side cards.
local RAIL_TWO_COL = 600

local TOOL_ICONS = { box = "package", mods = "puzzle", online = "globe",
  skins = "paintbrush" }
local TOOL_LABELS = { box = "Box", mods = "Mods", online = "Online",
  skins = "Skins" }
Nav.TOOL_ICONS, Nav.TOOL_LABELS = TOOL_ICONS, TOOL_LABELS

-- ------------------------------------------------------------------ metrics

local function railWidth(m)
  return math.floor(Theme.clamp(m.w * 0.18, 184 * m.s, 240 * m.s))
end

local function railRowH(m)
  return math.max(Kit.tapMin(), math.floor(32 * m.s))
end

local function railPad(m) return math.floor(14 * m.s) end

local function railLogoH(m)
  return math.floor(Theme.clamp(m.h * 0.08, 36 * m.s, 56 * m.s))
end

local function captionH(m)
  return Kit.textHeight("caption") + math.floor(10 * m.s)
end

-- Rail vertical budget: { top of the library list, bottom of it, top of the
-- tools caption, y of the cluster }.  One function so drawRail and the fit
-- check in frame() cannot disagree.
local function railSlots(m, toolsN, nx)
  local pad, rowH, gap = railPad(m), railRowH(m), math.floor(2 * m.s)
  local top = m.top + math.floor(18 * m.s)
  local logoBottom = top + railLogoH(m) + math.floor(18 * m.s)
  local libTop = logoBottom + captionH(m)
  local clusterY = m.top + m.h - pad - m.chip
  if nx then clusterY = clusterY - m.chip - math.floor(8 * m.s) end
  local toolsH = captionH(m) + toolsN * (rowH + gap)
  local toolsTop = clusterY - math.floor(16 * m.s) - toolsH
  local libBottom = toolsTop - math.floor(10 * m.s)
  return libTop, libBottom, toolsTop, clusterY
end

local function bottomNavH(m)
  return m.chip + Kit.textHeight("micro") + math.floor(12 * m.s)
end

local function topBarH(m)
  return m.chip + math.floor(16 * m.s)
end

-- Decide the shape and return the frame's nav layout.  L.page is the
-- metrics table the page panels lay out against: a copy of `m` (one reused
-- table, refreshed every frame) narrowed to the page column beside the rail.
-- `m` itself is Layout's shared cache and is never written here.
function Nav.frame(V, imp, m)
  local L = imp._navL
  if not L then L = { page = {} }; imp._navL = L end
  local p = L.page
  for k, v in pairs(m) do p[k] = v end
  local games = V.gameTabs(imp)
  local rowH = railRowH(m)
  local libTop, libBottom = railSlots(m, #V.HEADER_TABS, imp.isNX)
  local fitsRows = libBottom - libTop >= RAIL_MIN_LIB_ROWS * rowH
    or libBottom - libTop >= #games * rowH
  local rail = m.w >= Nav.RAIL_MIN_W * m.s and fitsRows
  L.mode = rail and "rail" or "bar"
  if rail then
    local rw = railWidth(m)
    L.railW = rw
    local x0, w0 = m.x + rw, m.w - rw
    local cw = math.min(w0, math.floor(PAGE_MAX_W * m.s))
    p.x = x0 + math.floor((w0 - cw) / 2)
    p.w = cw
    p.contentX = p.x + p.pad
    p.contentW = p.w - 2 * p.pad
    p.cols = (cw >= Layout.BP.threeCol * m.s and 3)
      or (cw >= RAIL_TWO_COL * m.s and 2) or 1
    p.twoCol = p.cols >= 2
    p.colW = p.twoCol and math.floor((p.contentW - p.colGap) / 2) or p.contentW
    L.topH = math.floor(18 * m.s)
    L.navH = 0
  else
    L.railW = 0
    local cw = math.min(m.w, math.floor(PAGE_MAX_W * m.s))
    if cw < m.w then
      p.x = m.x + math.floor((m.w - cw) / 2)
      p.w = cw
      p.contentX = p.x + p.pad
      p.contentW = p.w - 2 * p.pad
    end
    L.topH = topBarH(m) + 1
    L.navH = bottomNavH(m)
  end
  return L
end

-- ------------------------------------------------------------------ pieces

-- One table of nav-button opts per launcher, built once: only `active` and
-- the per-frame fields are written after that.
local function chrome(V, imp)
  local c = imp._navChrome
  if c then return c end
  local head = V.headerChrome(imp)
  c = { rows = {}, tools = {}, head = head }
  imp._navChrome = c
  return c
end

local function statusDot(imp, id, cx, cy, r)
  if imp.ready and imp.ready[id] then
    Theme.fillRounded(cx - r, cy - r, 2 * r, 2 * r, PAL.green, 1, r)
  else
    Theme.strokeRounded(cx - r, cy - r, 2 * r, 2 * r, PAL.muted, 0.7, 1, r)
  end
end

local BETA_TAG = { fill = true, bold = true, ink = PAL.inverse }

-- A BETA chip whose right edge sits at x, centred on y.
local function betaChip(x, y, s)
  local w = Kit.textWidth("micro", "BETA") + math.floor(10 * s)
  local h = Kit.textHeight("micro") + math.floor(4 * s)
  Kit.tag(x - w, y - h / 2, w, h, "BETA", PAL.yellow, BETA_TAG)
end

local function navInk(opts, x, y, w, h)
  if opts.active then return PAL.heading end
  return Kit.hover(x, y, w, h) and PAL.text or PAL.muted
end

local function gameRowOpts(V, imp, c, g)
  local o = c.rows[g.id]
  if o then return o end
  o = { face = "nav", color = g.color, action = c.head.tab[g.id] }
  o.drawFn = function(x, y, w, h)
    local s = Kit.scale
    local pip = math.floor(10 * s)
    local px = x + math.floor(14 * s)
    Theme.fillRounded(px, y + (h - pip) / 2, pip, pip, g.color, 1, pip / 2)
    local lx = px + pip + math.floor(10 * s)
    local dotR = math.max(2, math.floor(3 * s))
    local right = x + w - math.floor(12 * s) - 2 * dotR
    local name = Kit.ellipsize("tab", Strings(g.label), math.max(0, right - lx - 6 * s))
    local ink = navInk(o, x, y, w, h)
    if o.active then
      Kit.textBold("tab", name, lx, y + (h - Kit.textHeight("tab")) / 2, ink)
    else
      Kit.text("tab", name, lx, y + (h - Kit.textHeight("tab")) / 2, ink)
    end
    statusDot(imp, g.id, right + dotR, y + h / 2, dotR)
  end
  c.rows[g.id] = o
  return o
end

local function toolOpts(V, imp, c, t, bar)
  local key = bar and ("bar-" .. t.id) or t.id
  local o = c.tools[key]
  if o then return o end
  o = { face = "nav", accent = bar and "top" or nil, action = c.head.tab[t.id] }
  local label = TOOL_LABELS[t.id]
  if bar then
    o.drawFn = function(x, y, w, h)
      local s = Kit.scale
      local size = math.floor(20 * s)
      local lh = Kit.textHeight("micro")
      local top = y + (h - size - math.floor(4 * s) - lh) / 2
      local ink = navInk(o, x, y, w, h)
      Icons.draw(TOOL_ICONS[t.id], x + (w - size) / 2, top, size, ink, 1)
      if t.beta then
        local r = math.max(2, math.floor(3 * s))
        Theme.fillRounded(x + (w + size) / 2 - r, top - r, 2 * r, 2 * r, PAL.yellow, 1, r)
      end
      local shown = Kit.ellipsize("micro", Strings(label), w - 4)
      Kit.textCenter("micro", shown, x, top + size + math.floor(4 * s), w, ink)
    end
  else
    o.drawFn = function(x, y, w, h)
      local s = Kit.scale
      local size = math.floor(18 * s)
      local ix = x + math.floor(10 * s)
      local ink = navInk(o, x, y, w, h)
      Icons.draw(TOOL_ICONS[t.id], ix, y + (h - size) / 2, size, ink, 1)
      local lx = ix + size + math.floor(10 * s)
      local fh = Kit.textHeight("tab")
      if o.active then
        Kit.textBold("tab", Strings(label), lx, y + (h - fh) / 2, ink)
      else
        Kit.text("tab", Strings(label), lx, y + (h - fh) / 2, ink)
      end
      if t.beta then betaChip(x + w - math.floor(10 * s), y + h / 2, s) end
    end
  end
  c.tools[key] = o
  return o
end

local function toolActive(imp, id)
  return imp.tab == id or (id == "mods" and imp.tab == "find")
end

-- The wordmark, scaled into a box; a tap feeds the secret-game counter.
local function drawLogo(V, imp, x, y, maxW, maxH)
  if not imp.logo or maxW <= 0 or maxH <= 0 then return 0 end
  local lw, lh = imp.logo:getDimensions()
  local scale = math.min(maxW / lw, maxH / lh)
  local dw, dh = lw * scale, lh * scale
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.draw(imp.logo, Theme.snap(x), Theme.snap(y), 0, scale, scale)
  local r = imp._logoRect or {}
  r.x, r.y, r.w, r.h = x, y, dw, dh
  imp._logoRect = r
  if Kit.press(x, y, dw, dh) and imp._logoTap then
    V.queueAction(imp, "logo-tap-" .. tostring(imp._logoTaps or 0),
      function() imp:_logoTap() end)
  end
  return dw, dh
end

-- Save Sync, settings, quit, laid out left to right from x.  The gear is
-- REGISTERED before Quit: the first focusable of the first frame adopts the
-- keyboard ring, and that must never be the button that exits the app.
local function drawCluster(V, imp, m, x, by, align)
  local gear, gap = m.chip, math.floor(6 * m.s)
  local hasQuit = V.hasQuitButton(imp)
  local n = hasQuit and 3 or 2
  local total = n * gear + (n - 1) * gap
  local rx = align == "right" and x - total or x
  local head = chrome(V, imp).head
  local syncX, gearX = rx, rx + gear + gap
  local quitX = hasQuit and gearX + gear + gap or nil
  V.btn(imp, gearX, by, gear, gear, "gear", "", head.gear)
  local bx = syncX
  V.btn(imp, bx, by, gear, gear, "tab-sync", "", head.sync)
  local eng = imp._sync
  if eng and eng.busy and eng:busy() then
    Kit.spinner(bx + gear - math.floor(8 * m.s), by + math.floor(8 * m.s),
      math.max(2, math.floor(4 * m.s)))
  end
  if quitX then V.btn(imp, quitX, by, gear, gear, "quit", "", head.quit) end
  return total
end

-- ------------------------------------------------------------------ rail

local function drawRail(V, imp, m, L)
  local c = chrome(V, imp)
  local rw, pad, rowH = L.railW, railPad(m), railRowH(m)
  local gap = math.floor(2 * m.s)
  local x0 = m.x
  L.railRight = x0 + rw
  -- The rail owns everything left of its edge, safe-area inset included, so
  -- a notch or a sliding page never shows through beside it.
  Theme.fill(0, 0, x0 + rw, m.H, PAL.sidebar, 1)
  Theme.fill(x0 + rw - 1, 0, 1, m.H, PAL.line, 0.18)

  local top = m.top + math.floor(18 * m.s)
  drawLogo(V, imp, x0 + pad, top, rw - 2 * pad, railLogoH(m))

  local libTop, libBottom, toolsTop, clusterY =
    railSlots(m, #V.HEADER_TABS, imp.isNX)
  local ix, iw = x0 + math.floor(10 * m.s), rw - math.floor(20 * m.s)

  -- LIBRARY: every visible cartridge, scrolling when the rail is short.
  Kit.caption(x0 + pad, libTop - captionH(m) + math.floor(2 * m.s),
    Strings("LIBRARY"), PAL.caption)
  local games = V.gameTabs(imp)
  local viewH = math.max(0, libBottom - libTop)
  local contentH = #games * (rowH + gap) - gap
  local maxAt = Kit.scrollExtent(contentH, viewH)
  local at = Kit.scrollInput(imp._navLibScroll or 0, maxAt, ix, libTop, iw, viewH)
  -- Keep the open game in view after a tab switch from anywhere else.
  if imp._navLibFollow ~= imp.tab then
    imp._navLibFollow = imp.tab
    for i, g in ipairs(games) do
      if g.id == imp.tab then
        local gy = (i - 1) * (rowH + gap)
        if gy < at then at = gy end
        if gy + rowH > at + viewH then at = gy + rowH - viewH end
      end
    end
  end
  at = Kit.scrollClamp(at, maxAt)
  imp._navLibScroll = at
  local py = Kit.scrollBegin(ix, libTop, iw, viewH, at, maxAt)
  local rowW = maxAt > 0 and iw - Kit.scrollGutter(m.s) or iw
  for i, g in ipairs(games) do
    local o = gameRowOpts(V, imp, c, g)
    o.active = imp.tab == g.id
    V.btn(imp, ix, py + (i - 1) * (rowH + gap), rowW, rowH, g.key, "", o)
  end
  Kit.scrollEnd(ix, libTop, iw, viewH, at, maxAt, PAL.sidebar)

  -- TOOLS
  Kit.caption(x0 + pad, toolsTop + math.floor(2 * m.s), Strings("TOOLS"), PAL.caption)
  local ty = toolsTop + captionH(m)
  for _, t in ipairs(V.HEADER_TABS) do
    local o = toolOpts(V, imp, c, t, false)
    o.active = toolActive(imp, t.id)
    V.btn(imp, ix, ty, iw, rowH, t.key, "", o)
    ty = ty + rowH + gap
  end

  Theme.fill(x0 + pad, clusterY - math.floor(10 * m.s), rw - 2 * pad, 1,
    PAL.line, 0.18)

  -- Switch-only: show the running app version above the cluster so players
  -- can confirm which build is on the microSD (OTA / zip updates).
  if imp.isNX then
    local label = "v" .. tostring(Version.engine or "?")
    local tw = Kit.textWidth("small", label)
    local chipW = math.max(tw + math.floor(24 * m.s), m.chip)
    local cy = clusterY + m.chip + math.floor(8 * m.s)
    Kit.card(x0 + pad, cy, chipW, m.chip, "badge")
    Kit.text("small", label, x0 + pad + math.floor((chipW - tw) / 2),
      cy + math.floor((m.chip - Kit.textHeight("small")) / 2), PAL.yellow)
  end

  drawCluster(V, imp, m, x0 + pad, clusterY, "left")
end

-- ------------------------------------------------------------------ bars

local function drawTopBar(V, imp, m, L)
  local h = topBarH(m)
  local y = m.top
  Theme.fill(0, 0, m.W, y + h, PAL.sidebar, 1)
  Theme.fill(0, y + h, m.W, 1, PAL.line, 0.18)
  local by = y + math.floor((h - m.chip) / 2)
  local right = m.x + m.w - m.pad
  local clusterW = drawCluster(V, imp, m, right, by, "right")
  local logoW = right - clusterW - math.floor(12 * m.s) - (m.x + m.pad)
  local lh = math.floor(m.chip * 0.95)
  drawLogo(V, imp, m.x + m.pad, y + (h - lh) / 2,
    math.min(logoW, math.floor(200 * m.s)), lh)
  return y + h + 1
end

local function drawBottomNav(V, imp, m, L)
  local c = chrome(V, imp)
  local h = L.navH
  local y = m.top + m.h - h
  Theme.fill(0, y, m.W, m.H - y, PAL.sidebar, 1)
  Theme.fill(0, y, m.W, 1, PAL.line, 0.18)
  local n = 1 + #V.HEADER_TABS
  local inset = math.floor(6 * m.s)
  local w0 = math.min(m.w - 2 * inset, math.floor(560 * m.s))
  local x0 = m.x + math.floor((m.w - w0) / 2)
  local iw = math.floor(w0 / n)
  local ih = h - math.floor(8 * m.s)
  local iy = y + math.floor(4 * m.s)

  -- The game slot: the open cartridge's colour and name.  On its own page a
  -- second tap opens the game picker; anywhere else it returns to the game.
  local game = V.currentGame(imp)
  local o = c.gameSlot
  if not o then
    o = { face = "nav", accent = "top", action = c.head.game.action }
    o.drawFn = function(x, yy, w, hh)
      local s = Kit.scale
      local g = V.currentGame(imp)
      local size = math.floor(20 * s)
      local lh = Kit.textHeight("micro")
      local top = yy + (hh - size - math.floor(4 * s) - lh) / 2
      local ink = navInk(o, x, yy, w, hh)
      local px = x + (w - size) / 2
      Theme.fillRounded(px, top, size, size, g.color, 1, math.floor(6 * s))
      Icons.draw("gamepad-2", px + 2 * s, top + 2 * s, size - 4 * s, Theme.inkOn(g.color), 1)
      local name = Strings(g.label)
      local caret = o.active and math.floor(10 * s) or 0
      local shown = Kit.ellipsize("micro", name, w - 6 - caret)
      local tw = Kit.textWidth("micro", shown) + caret
      local tx = x + (w - tw) / 2
      Kit.text("micro", shown, tx, top + size + math.floor(4 * s), ink)
      if caret > 0 then
        Icons.draw("chevron-up", tx + tw - caret, top + size + math.floor(4 * s)
          + (lh - caret) / 2, caret, ink, 0.9)
      end
    end
    c.gameSlot = o
  end
  o.color = game.color
  o.active = imp.tab == game.id
  V.btn(imp, x0, iy, iw, ih, "tab-game", "", o)

  for i, t in ipairs(V.HEADER_TABS) do
    local to = toolOpts(V, imp, c, t, true)
    to.active = toolActive(imp, t.id)
    local bx = x0 + i * iw
    local bw = i == n - 1 and (x0 + w0 - bx) or iw
    V.btn(imp, bx, iy, bw, ih, t.key, "", to)
  end
end

-- ------------------------------------------------------------------ entry

-- Shared with the game picker so a cartridge reads the same everywhere.
Nav.rowHeight = railRowH
function Nav.gameRow(V, imp, g)
  return gameRowOpts(V, imp, chrome(V, imp), g)
end

-- The top of the page column: the top bar's bottom edge in BAR mode, a
-- breathing margin under the window top beside the rail.
function Nav.drawTop(V, imp, m, L)
  if L.mode == "rail" then return m.top + L.topH end
  return drawTopBar(V, imp, m, L)
end

-- The rail or the bottom bar.  Drawn AFTER the page so a sliding page never
-- paints over it; takes the full-window metrics, not L.page.
function Nav.drawChrome(V, imp, m, L)
  if L.mode == "rail" then
    drawRail(V, imp, m, L)
  else
    drawBottomNav(V, imp, m, L)
  end
end

return Nav
