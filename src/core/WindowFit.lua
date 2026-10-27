-- Keep a window on its display after a resize.  love.window.setMode takes
-- the flags getMode returned, and those carry the window's old x and y: a
-- launcher window rebuilt where the smaller game window sat (or a window
-- grown for a fixed resolution) hung off the right and top of the screen.
-- The position is kept where the new size still fits, and moved in only as
-- far as it has to be.
local WindowFit = {}

-- Room for a title bar above the window's content, where the display has it.
WindowFit.TITLE_BAR = 32

function WindowFit.clamp(w, h, flags)
  if type(flags) ~= "table" or flags.fullscreen then return flags end
  if not (love and love.window and love.window.getDesktopDimensions) then return flags end
  local ok, dw, dh = pcall(love.window.getDesktopDimensions, flags.display or 1)
  if not (ok and tonumber(dw) and tonumber(dh)) then return flags end
  if tonumber(flags.x) then
    flags.x = math.max(0, math.min(flags.x, dw - w))
  end
  if tonumber(flags.y) then
    local top = (dh - h >= WindowFit.TITLE_BAR) and WindowFit.TITLE_BAR or 0
    flags.y = math.max(top, math.min(flags.y, dh - h))
  end
  return flags
end

return WindowFit
