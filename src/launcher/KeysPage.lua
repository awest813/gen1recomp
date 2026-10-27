-- Settings > Keys and buttons: every key and controller button the launcher
-- and the games answer to, in one place.  The hotkeys (F1 quick save, 1 for
-- game speed...) were otherwise only discoverable by accident.  Read-only:
-- the game buttons are rebound in each game's START > OPTION > CONTROLS.
local Kit = require("src.ui.kit.Kit")
local Theme = require("src.ui.kit.Theme")

local PAL = Theme.PAL

local KeysPage = {}

-- { section, { { keys, what }, ... } }
KeysPage.SECTIONS = {
  { "IN A GAME: KEYBOARD", {
    { "Arrows or W A S D", "Move" },
    { "Z, Enter or Space", "A" },
    { "X or Backspace", "B" },
    { "Esc", "START" },
    { "Tab", "SELECT" },
    { "Q / E", "L / R (FireRed, LeafGreen)" },
    { "F1 / F2", "Quick save / quick load" },
    { "1 / 0", "Game speed faster / slower" },
    { "2", "Colours (Game Boy games)" },
    { "3", "Tilt" },
    { "4, - and =", "Zoom" },
    { "F10", "Mod manager (Red, Blue, Yellow)" },
  } },
  { "IN A GAME: CONTROLLER", {
    { "D-pad or left stick", "Move" },
    { "A / B", "A / B" },
    { "Start / Back (View)", "START / SELECT" },
    { "LB / RB", "Game speed (Game Boy games); L / R (FireRed, LeafGreen)" },
    { "LT / RT", "Game speed (FireRed, LeafGreen)" },
  } },
  { "IN THIS LAUNCHER", {
    { "Arrows, Tab, d-pad or stick", "Move the highlight (hold to repeat)" },
    { "Enter, Space or A", "Choose" },
    { "Esc or B", "Back" },
    { "Ctrl+Tab or LB / RB", "Next / previous section" },
    { "Start", "Play the chosen save, or start one" },
    { "F11", "Full screen" },
  } },
}

-- Draws the page and returns the height it needs (Launcher:drawFitted).
function KeysPage.draw(l, x, y, w, h, s)
  local pad = math.floor(18 * s)
  Kit.card(x, y, w, h)
  local cx, cw = x + pad, w - 2 * pad
  local cy = y + pad
  cy = l:pageHeader(cx, cy, cw, s, { title = "Keys and buttons",
    subtitle = "The defaults. Change the game buttons in a game: START, then OPTION, then CONTROLS.",
    back = function() l.page = "settings" end, backId = "keys-back" })
  local gap = Theme.space("s", s)
  -- two columns when there is room, the key above its meaning when not
  local keyW = math.floor(math.min(cw * 0.42, 260 * s))
  local stacked = cw < 420 * s
  local n = 0
  for _, sec in ipairs(KeysPage.SECTIONS) do
    cy = cy + gap
    Kit.caption(cx, cy, sec[1], PAL.caption)
    cy = cy + Kit.textHeight("caption") + gap
    for _, row in ipairs(sec[2]) do
      n = n + 1
      local rowH = stacked
        and Kit.textHeight("small") + Kit.wrapHeight("small", row[2], cw)
        or math.max(Kit.textHeight("small"), Kit.wrapHeight("small", row[2], cw - keyW))
      -- each row takes the ring, so arrows and the d-pad walk (and scroll)
      -- the list; it was only the Back button before
      local half = math.floor(gap / 2)
      if Kit.focusable("keys-row-" .. n, cx - half, cy - half, cw + 2 * half, rowH + 2 * half) then
        Theme.fillRounded(cx - half, cy - half, cw + 2 * half, rowH + 2 * half, PAL.raised, 1)
      end
      if stacked then
        Kit.text("small", row[1], cx, cy, PAL.text)
        Kit.textWrapped("small", row[2], cx, cy + Kit.textHeight("small"), cw, PAL.muted)
      else
        Kit.text("small", Kit.ellipsize("small", row[1], keyW - gap), cx, cy, PAL.text)
        Kit.textWrapped("small", row[2], cx + keyW, cy, cw - keyW, PAL.muted)
      end
      cy = cy + rowH + gap
    end
  end
  return cy + pad - y
end

return KeysPage
