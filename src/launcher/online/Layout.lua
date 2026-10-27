-- Layout helpers for the PK:GB launcher's Online page views
-- (src/launcher/OnlinePage.lua and its src/launcher/online/ views).
--
-- Every helper sizes its controls to at least Kit.tapMin() and wraps to a
-- new line instead of overflowing, so the same view works on a 390-wide
-- phone and a 1280-wide desktop window.

local Kit = require("src.ui.kit.Kit")
local Theme = require("src.ui.kit.Theme")

local PAL = Theme.PAL

local Layout = {}

-- Sizes shared by every view, from the launcher's scale.
function Layout.metrics(s)
  return {
    s = s,
    rowH = math.max(Kit.tapMin(), math.floor(40 * s)),
    smallH = math.max(Kit.tapMin(), math.floor(32 * s)),
    gap = math.floor(10 * s),
    inset = math.floor(12 * s),
  }
end

function Layout.buttonW(s, label, font)
  return math.max(Kit.tapMin(), Kit.textWidth(font or "small", label) + math.floor(28 * s))
end

-- Buttons left to right, wrapping when a line is full.  Each item is
-- { label, id, kind, enabled, active, w, run } (or false to skip it); a
-- pressed item's run is queued on the launcher.  Returns the y below the
-- last line.
function Layout.buttons(l, x, y, w, h, m, items)
  local bx, by = x, y
  local any = false
  for _, it in ipairs(items) do
    if it then
      local bw = math.min(w, it.w or Layout.buttonW(m.s, it.label))
      if bx > x and bx + bw > x + w then bx, by = x, by + h + m.gap end
      if Kit.button(bx, by, bw, h, it.label, { id = it.id, font = "small", kind = it.kind,
          enabled = it.enabled, active = it.active }) and it.run then
        l:queue(it.run)
      end
      bx = bx + bw + m.gap
      any = true
    end
  end
  return any and (by + h) or y
end

-- One choice among options ({ value, label }), drawn as chips that wrap.
-- Returns the picked value (or nil) and the y below the chips.
function Layout.choices(x, y, w, m, options, current, idPrefix, enabled)
  local h = m.smallH
  local bx, by = x, y
  local picked
  for _, opt in ipairs(options) do
    local bw = math.min(w, math.max(Kit.tapMin(),
      Kit.textWidth("micro", opt.label) + math.floor(28 * m.s)))
    if bx > x and bx + bw > x + w then bx, by = x, by + h + math.floor(6 * m.s) end
    local on = opt.value == current
    if enabled == false then
      Kit.button(bx, by, bw, h, opt.label, { face = "chip", font = "micro", active = on,
        enabled = false })
    elseif Kit.chip(bx, by, bw, h, opt.label, on, nil, idPrefix .. tostring(opt.value)) then
      picked = opt.value
    end
    bx = bx + bw + math.floor(6 * m.s)
  end
  return picked, by + h
end

-- A labelled "[-] value [+]" line.  Returns -1, 0 or 1 and the y below it.
function Layout.stepper(x, y, w, m, label, valueText, id, canDown, canUp)
  local h = m.smallH
  local bw = h
  local valueW = math.max(Kit.textWidth("small", "Any Lv100"), math.floor(56 * m.s))
  local right = x + w
  local delta = 0
  if Kit.stepper(right - bw, y, bw, h, "+", { id = id .. "-up", enabled = canUp ~= false }) then
    delta = 1
  end
  Kit.textCenter("small", valueText, right - bw - valueW, y + (h - Kit.textHeight("small")) / 2,
    valueW, PAL.text)
  if Kit.stepper(right - 2 * bw - valueW, y, bw, h, "-", { id = id .. "-down",
      enabled = canDown ~= false }) then
    delta = -1
  end
  local labelW = w - 2 * bw - valueW - m.gap
  Kit.text("small", Kit.ellipsize("small", label, math.max(0, labelW)), x,
    y + (h - Kit.textHeight("small")) / 2, PAL.muted)
  return delta, y + h
end

-- "m:ss" until at (relay milliseconds) from now (relay milliseconds), or
-- nil when either is unknown.
function Layout.countdown(at, now)
  if type(at) ~= "number" or type(now) ~= "number" then return nil end
  local left = math.max(0, math.ceil((at - now) / 1000))
  return ("%d:%02d"):format(math.floor(left / 60), left % 60)
end

-- Wrapped text; returns the y below it.
function Layout.para(font, text, x, y, w, color)
  Kit.textWrapped(font, text, x, y, w, color)
  return y + Kit.wrapHeight(font, text, w)
end

-- One line of text cut to the width; returns the y below it.
function Layout.line(font, text, x, y, w, color)
  Kit.text(font, Kit.ellipsize(font, text, w), x, y, color)
  return y + Kit.textHeight(font)
end

return Layout
