-- A short notice over the game for the host's own keys (F1 quick save, the
-- touch key bar's SPEED, ZOOM...): they changed something with nothing on
-- screen to say so.  Drawn by main.lua after the game, outside the Game Boy
-- picture's own pixels, so the game's look is untouched.
local HostToast = {}

HostToast.HOLD = 1.4 -- seconds on screen

local current

function HostToast.say(text)
  if type(text) ~= "string" or text == "" then return end
  local t = love and love.timer and love.timer.getTime and love.timer.getTime() or 0
  current = { text = text, at = t }
end

function HostToast.text() return current and current.text end

local fonts = {}
local function font(size)
  if not fonts[size] then
    local ok, f = pcall(love.graphics.newFont, size)
    fonts[size] = ok and f or love.graphics.getFont()
  end
  return fonts[size]
end

function HostToast.draw()
  if not current then return end
  local G = love and love.graphics
  if not (G and G.getDimensions) then return end
  local t = love.timer and love.timer.getTime and love.timer.getTime() or current.at
  local age = t - current.at
  if age > HostToast.HOLD then current = nil return end
  local alpha = math.min(1, (HostToast.HOLD - age) / 0.3)
  local w, h = G.getDimensions()
  local f = font(math.max(14, math.floor(math.min(w, h) / 28)))
  local tw, th = f:getWidth(current.text), f:getHeight()
  local padX, padY = th * 0.8, th * 0.4
  local bw, bh = tw + 2 * padX, th + 2 * padY
  local x, y = (w - bw) / 2, math.max(8, h * 0.04)
  G.push("all")
  G.setColor(0, 0, 0, 0.72 * alpha)
  G.rectangle("fill", x, y, bw, bh, bh / 2, bh / 2)
  G.setColor(1, 1, 1, alpha)
  G.setFont(f)
  G.print(current.text, x + padX, y + padY)
  G.pop()
end

return HostToast
