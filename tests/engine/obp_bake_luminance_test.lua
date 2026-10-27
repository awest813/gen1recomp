-- The OBJ bake (SpriteRenderer.obpImage) picks each pixel's shade by
-- luminance.  On the four DMG grays the extractor writes that is exactly
-- the red channel the bake used to key on, so vanilla art bakes the same;
-- a mod's recolored sheet (example_shiny_palette's teal) now falls into
-- the right shades where it used to bake solid black (red channel ~0).
--   luajit tests/engine/obp_bake_luminance_test.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
love = love or require("tests.love_stub")
local T = require("tests.harness")

-- a 1-pixel image per color, through the CPU bake path
local Assets = require("src.render.Assets")
local realImageData = Assets.imageData
local px
Assets.imageData = function()
  return { mapPixel = function(_, fn) px = { fn(0, 0, px[1], px[2], px[3], 1) } end }
end
local realNewImage = love.graphics.newImage
love.graphics.newImage = function() return {} end
local realNewImageData = love.image and love.image.newImageData
love.image = love.image or {}
love.image.newImageData = love.image.newImageData or function() return {} end
local SpriteRenderer = require("src.render.SpriteRenderer")

local PAL = { { 255, 255, 255 }, { 200, 0, 0 }, { 100, 0, 0 }, { 10, 0, 0 } }
local n = 0
local function bake(r, g, b)
  n = n + 1
  px = { r / 255, g / 255, b / 255 }
  SpriteRenderer.obpImage("test/sprite" .. n .. ".png", PAL, "lum" .. n)
  return math.floor(px[1] * 255 + 0.5), px[4]
end

-- the DMG grays: unchanged mapping
local r, a = bake(255, 255, 255)
T.eq(a, 0, "white is OBJ color 0: transparent")
T.eq((bake(170, 170, 170)), 200, "light gray takes shade 2")
T.eq((bake(85, 85, 85)), 100, "dark gray takes shade 3")
T.eq((bake(0, 0, 0)), 10, "black takes shade 4")
-- the shiny palette's teal: by brightness, not by its red
T.eq((bake(120, 224, 216)), 200, "light teal is a light shade")
T.eq((bake(32, 128, 152)), 100, "mid teal is a dark shade, not black")
T.eq((bake(8, 32, 64)), 10, "deep teal is the darkest shade")
local _ = r

Assets.imageData = realImageData
love.graphics.newImage = realNewImage
if realNewImageData then love.image.newImageData = realNewImageData end
T.finish("obp bake luminance")
