-- Opt-in regression against a downloaded PotatoVoxel package, not bundled art.
-- luajit tests/engine/voxel_shadow_probe.lua /path/to/extracted/mod
local root = assert(arg and arg[1], "pass the extracted PotatoVoxel folder")
local allocations = 0
local function canvas()
  return { setFilter = function() end, setWrap = function() end,
           release = function() end }
end
love = { graphics = {
  newCanvas = function() allocations = allocations + 1; return canvas() end,
  newShader = function() return { send = function() end } end,
  setDepthMode = function() end, setMeshCullMode = function() end,
  setCanvas = function() end, getBlendMode = function() return "alpha", "alphamultiply" end,
  clear = function() end, setBlendMode = function() end,
  setShader = function() end, setColor = function() end,
} }
local Mat4 = assert(loadfile(root .. "/lib/Mat4.lua"))()
local V = { require = function(name)
  if name == "Mat4" then return Mat4 end
  if name == "VoxelState" then return { level = 1, angle = 0.9, FOCAL = 1 } end
  if name == "ShadowSettings" then return { quality = function() return nil end } end
  if name == "Platform" then return { isIOS = function() return false end } end
  if name == "PixelCanvas" then return assert(loadfile(root .. "/lib/PixelCanvas.lua"))() end
  error("unexpected module " .. name)
end }
local ShadowMap = assert(loadfile(root .. "/lib/ShadowMap.lua"))(V)
ShadowMap.BRICK_HIGH_RES = 1536
assert(ShadowMap.available(), "initial capability probe failed")
assert(ShadowMap.begin(0, 0, 160, 144, false), "initial shadow pass failed")
ShadowMap.finish("world", false)
local steady = allocations
for i = 1, 120 do
  assert(ShadowMap.available(), "capability disappeared")
  assert(ShadowMap.begin(0, 0, 160, 144, false), "shadow pass failed")
  ShadowMap.finish("world", false)
end
assert(allocations == steady,
  "capability probes allocated " .. (allocations - steady) .. " extra canvases in 120 frames")
print("shadow probe: zero additional canvas allocations in 120 steady frames")
