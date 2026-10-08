-- GPU twin of the engine's per-pixel 4-shade recolor bakes, for the browser.
--
-- SpriteRenderer, BattleState, PartyMenu and OverworldController each bake a
-- palette variant of an extracted DMG-gray image with ImageData:mapPixel and
-- a Lua callback that buckets the red channel at 0.83 / 0.5 / 0.17.  Under
-- LuaJIT that is cheap.  In the love.js build (PUC Lua in WebAssembly) every
-- pixel is a C->Lua call: an intro sprite cost 60-70 ms of one frame.  This
-- runs the same bucketing as a shader, once, into a nearest-filtered Canvas,
-- with replace/premultiplied blending so the stored texels are exactly the
-- colours the CPU path writes.
--
-- Web only: desktop keeps its CPU bakes byte for byte (obp3100 below holds
-- both paths for the two OBP0 callers).  Every caller keeps
-- the CPU path as the fallback, used whenever available() is false or a bake
-- fails.  Extracted art has alpha 0 or 1 only, so drawing the Canvas later
-- is indistinguishable from drawing the baked Image.

local GpuBake = {}

local SHADER = [[
extern vec3 c1;
extern vec3 c2;
extern vec3 c3;
extern vec3 c4;
extern float clear1;   // 1: bucket 1 (r > 0.83) becomes transparent
extern float keepZero; // 1: alpha-0 texels pass through untouched
vec4 effect(vec4 color, Image tex, vec2 uv, vec2 screen) {
  vec4 p = Texel(tex, uv);
  if (keepZero > 0.5 && p.a == 0.0) { return p; }
  if (p.r > 0.83) {
    if (clear1 > 0.5) { return vec4(p.rgb, 0.0); }
    return vec4(c1, p.a);
  }
  vec3 c = p.r > 0.5 ? c2 : (p.r > 0.17 ? c3 : c4);
  return vec4(c, p.a);
}
]]

local shader = nil -- nil = untried, false = unavailable

function GpuBake.available()
  if shader ~= nil then return shader ~= false end
  shader = false
  local g = love and love.graphics
  if not (g and g.newShader and g.newCanvas and g.setCanvas) then return false end
  local okP, Platform = pcall(require, "src.core.Platform")
  if not (okP and Platform.isWeb()) then return false end
  local ok, compiled = pcall(g.newShader, SHADER)
  if ok and compiled then shader = compiled end
  return shader ~= false
end

local function unit(c)
  return { (c[1] or 0) / 255, (c[2] or 0) / 255, (c[3] or 0) / 255 }
end

local function bake(source, colors, opts)
  local g = love.graphics
  local w, h = source:getDimensions()
  local canvas = g.newCanvas(w, h, { dpiscale = 1 })
  canvas:setFilter("nearest", "nearest")
  local black = { 0, 0, 0 }
  shader:send("c1", unit(colors[1] or black))
  shader:send("c2", unit(colors[2] or black))
  shader:send("c3", unit(colors[3] or black))
  shader:send("c4", unit(colors[4] or black))
  shader:send("clear1", opts.clear1 and 1 or 0)
  shader:send("keepZero", opts.keepZero == false and 0 or 1)
  g.push("all")
  g.setCanvas(canvas)
  g.clear(0, 0, 0, 0)
  g.origin()
  g.setScissor()
  g.setShader(shader)
  g.setBlendMode("replace", "premultiplied")
  g.setColor(1, 1, 1, 1)
  g.draw(source, 0, 0)
  g.pop()
  return canvas
end

-- Recolor `source` (an Image) into a new Canvas.  colors[1..4] are 0-255
-- {r, g, b} for the buckets r > 0.83, > 0.5, > 0.17 and the rest.
--   opts.clear1   bucket 1 becomes alpha 0, keeping its source rgb (OBJ
--                 colour 0 is always transparent)
--   opts.keepZero false: alpha-0 texels are recoloured too (default: they
--                 pass through untouched)
-- Returns nil when unavailable or the bake failed; callers fall back to CPU.
function GpuBake.recolor(source, colors, opts)
  if not source or not GpuBake.available() then return nil end
  local ok, canvas = pcall(bake, source, colors, opts or {})
  if ok then return canvas end
  return nil
end

-- OBP0 at "3100" (GBPalNormal): OBJ colors 0/1 -> shade 0 (white), color 2
-- -> shade 1 (170 grey), color 3 -> shade 3 (black).  Alpha passes through
-- (colour 0's tRNS keys sprite corners out).
local OBP_3100 = { { 255, 255, 255 }, { 255, 255, 255 }, { 170, 170, 170 }, { 0, 0, 0 } }

-- The "3100" lift baked into an asset (PartyMenu icons, overworld emotes):
-- a GPU bake in the browser, otherwise the CPU mapPixel bake.  Resolves
-- through Assets so a mod's override still wins.
function GpuBake.obp3100(path)
  local Assets = require("src.render.Assets")
  if not (love.image and love.image.newImageData) then
    return love.graphics.newImage(Assets.resolve(path)) -- headless stub
  end
  if GpuBake.available() then
    local ok, source = pcall(love.graphics.newImage, Assets.resolve(path))
    local baked = ok and GpuBake.recolor(source, OBP_3100, { keepZero = false })
    -- the bake has drawn by now (popping the canvas flushes); free the
    -- throwaway source instead of leaving its texture to the GC
    if ok and source.release then source:release() end
    if baked then return baked end
  end
  local id = Assets.imageData(path)
  id:mapPixel(function(_, _, r, _, _, a)
    -- the extracted art is the four DMG grays, keyed off the red channel
    -- exactly the way PaletteFX's shade-remap shader keys them
    local v = 0
    if r > 0.5 then v = 1               -- OBJ colors 0 and 1 -> shade 0
    elseif r > 0.17 then v = 170 / 255  -- OBJ color 2 -> shade 1
    end                                 -- OBJ color 3 -> shade 3
    return v, v, v, a
  end)
  return love.graphics.newImage(id)
end

-- Tests only.
function GpuBake._resetForTests()
  shader = nil
end

return GpuBake
