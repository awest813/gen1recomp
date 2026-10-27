-- Scrolling for a menu line too long for its box: hold, step one character
-- at a time, hold on the tail, snap back.  Shared by the Gen 1 four-box
-- viewport (src/ui/OptionRows.lua) and the Gen 2 textbox
-- (src/ui/gen2/OptionsMenu.lua) -- different widths, same problem.

local Marquee = {}

Marquee.HOLD = 1.0
Marquee.STEP = 0.25

-- One phase per key, so a row's label and value (same key) step together,
-- and two lines scrolling at once (a hot row and a detail line) do not keep
-- restarting each other.  A key not drawn for a moment starts over.
local phases, count = {}, 0
local FORGET = 0.5

local function clock()
  local timer = love and love.timer and love.timer.getTime
  return timer and timer() or 0
end

-- Characters, not bytes: "é" is one character and two bytes, and a cut
-- through it leaves text the font cannot draw.
local function chars(text)
  local out = {}
  for ch in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do out[#out + 1] = ch end
  return out
end

local function slice(list, from, to)
  return table.concat(list, "", from, math.min(to, #list))
end

-- Pure, so a test can step it without a clock.
function Marquee.at(text, maxChars, elapsed)
  text = text or ""
  local list = chars(text)
  local over = #list - maxChars
  if over <= 0 then return text end
  local span = Marquee.HOLD * 2 + over * Marquee.STEP
  local now = elapsed % span
  local offset
  if now < Marquee.HOLD then
    offset = 0
  elseif now < Marquee.HOLD + over * Marquee.STEP then
    offset = math.floor((now - Marquee.HOLD) / Marquee.STEP)
  else
    offset = over
  end
  return slice(list, offset + 1, offset + maxChars)
end

-- `key` identifies the highlighted row; changing it restarts the cycle.
function Marquee.scroll(text, maxChars, key)
  if not text or #text <= maxChars then return text or "" end
  local now = clock()
  local p = phases[key]
  if not p or now - p.seen > FORGET then
    if not p then
      count = count + 1
      if count > 64 then phases, count = {}, 1 end
    end
    p = { start = now }
    phases[key] = p
  end
  p.seen = now
  return Marquee.at(text, maxChars, now - p.start)
end

-- Cut to maxChars, ending in "…" (the charmap's own ellipsis, $75 in Gen 1
-- and 2) so a cut name reads as cut and not as the whole name.
function Marquee.clip(text, maxChars)
  text = text or ""
  if #text <= maxChars then return text end
  local list = chars(text)
  if #list <= maxChars then return text end
  if maxChars < 2 then return slice(list, 1, maxChars) end
  return (slice(list, 1, maxChars - 1):gsub("%s+$", "")) .. "…"
end

return Marquee
