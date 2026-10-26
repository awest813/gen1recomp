-- Name the mod call site that creates GPU resources every frame.
--
-- PotatoVoxel's shadow map rebuilt three canvases every frame: a probe
-- allocated the smallest rung, then fit() replaced it with the rung it
-- wanted.  In the browser each canvas costs synchronous glGetError round
-- trips, which ate 30% of the main thread, and finding it took a
-- named-symbol wasm build and a profiler session (docs/proposals/web-mods.md,
-- phase 4).  A one-line warning naming the file and line would have shown it
-- at once.
--
-- install() wraps love.graphics.newCanvas / newImage / newShader / newMesh /
-- newSpriteBatch once.  Engine calls pass straight through after one source
-- check; a call from a mod file is counted per call site, and a site that
-- creates more than LIMIT resources inside one WINDOW-second window is
-- reported once, with its count, to the log and to report().  Creation calls
-- are rare outside a thrash, so the cost when nothing is wrong is a
-- debug.getinfo per creation.

local Logger = require("src.core.Logger")

local ResourceGuard = {}

ResourceGuard.LIMIT = 20
ResourceGuard.WINDOW = 1.0
ResourceGuard.WATCHED = { "newCanvas", "newImage", "newShader", "newMesh",
  "newSpriteBatch" }

local sites = {}
local flaggedBy, flagged = {}, {}

-- Engine source paths, as LÖVE's require names them.  Anything else that
-- runs Lua -- a mod's chunk, named after its own path -- is a mod.
local ENGINE_ROOTS = { "src/", "main.lua", "conf.lua", "data/", "tools/",
  "ports/" }

function ResourceGuard.isModSource(source)
  if type(source) ~= "string" or source:sub(1, 1) ~= "@" then return false end
  local path = source:sub(2):gsub("\\", "/"):gsub("^%./", "")
  for _, root in ipairs(ENGINE_ROOTS) do
    if path:sub(1, #root) == root then return false end
  end
  return true
end

local function now()
  if love and love.timer and love.timer.getTime then return love.timer.getTime() end
  return os.clock()
end

-- Count one creation by `what` at `info` (a debug.getinfo "Sl" table).
function ResourceGuard.note(what, info, t)
  local key = info.source .. ":" .. tostring(info.currentline)
  local site = sites[key]
  t = t or now()
  if not site then
    site = { start = t, count = 0 }
    sites[key] = site
  end
  if t - site.start > ResourceGuard.WINDOW then
    site.start, site.count = t, 0
  end
  site.count = site.count + 1
  if site.count > ResourceGuard.LIMIT and not flaggedBy[key] then
    local row = { site = key:gsub("^@", ""), what = what, count = site.count,
      window = ResourceGuard.WINDOW }
    flaggedBy[key] = row
    flagged[#flagged + 1] = row
    Logger.warn("%s calls love.graphics.%s more than %d times a second; "
      .. "create it once and reuse it (each creation stalls the GPU, worst "
      .. "in the browser)", row.site, what, ResourceGuard.LIMIT)
  end
end

-- The flagged call sites, in the order they tripped.
function ResourceGuard.report()
  local out = {}
  for i = 1, #flagged do out[i] = flagged[i] end
  return out
end

function ResourceGuard.reset()
  sites, flaggedBy, flagged = {}, {}, {}
end

local getinfo = debug.getinfo

function ResourceGuard.install()
  local g = love and love.graphics
  if not g or ResourceGuard.installed then return false end
  ResourceGuard.installed = true
  for _, name in ipairs(ResourceGuard.WATCHED) do
    local real = g[name]
    if type(real) == "function" then
      g[name] = function(...)
        local info = getinfo(2, "Sl")
        if info and ResourceGuard.isModSource(info.source) then
          ResourceGuard.note(name, info)
        end
        return real(...)
      end
    end
  end
  return true
end

return ResourceGuard
