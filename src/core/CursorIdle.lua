-- The mouse pointer during play: hidden once it has sat still for a moment,
-- back the instant the mouse moves or clicks.  Nothing in a running game is
-- driven by the pointer, so a cursor parked over the picture is only in the
-- way; the launcher, the editors and desktop touch testing keep it.
local CursorIdle = {}

CursorIdle.DELAY = 2.5 -- seconds without motion before it hides

local idle, hidden = 0, false

local function setVisible(on)
  local mouse = love and love.mouse
  if mouse and mouse.setVisible then pcall(mouse.setVisible, on) end
  hidden = not on
end

-- Every frame.  `inGame` is true only while a game owns the window.
function CursorIdle.update(dt, inGame)
  if not inGame then
    idle = 0
    if hidden then setVisible(true) end
    return
  end
  idle = idle + (dt or 0)
  if not hidden and idle >= CursorIdle.DELAY then setVisible(false) end
end

-- The mouse moved or clicked: show it again and restart the clock.
function CursorIdle.moved()
  idle = 0
  if hidden then setVisible(true) end
end

function CursorIdle.isHidden() return hidden end

return CursorIdle
