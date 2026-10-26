-- Retry a shader whose link failed on mismatched uniform precision.
--
-- GLSL ES (the browser build, Android, iOS) gives float uniforms a default
-- precision per stage: highp in the vertex stage, whatever the fragment
-- stage's default is in the pixel stage.  A uniform that BOTH stages declare
-- with no qualifier can then link as two different types, and WebGL refuses
-- the program:
--
--   Precisions of uniform 'swellPhase' differ between VERTEX and FRAGMENT
--   shaders.
--
-- Desktop GL ignores precision, so a shader written there (most voxel mods'
-- terrain shaders) works natively and fails only in the browser.  The audit
-- in docs/web-voxel-audit-2026-10-08.md found Terrarium's four shader
-- variants failing exactly like this; giving the shared uniforms LÖVE's
-- LOVE_HIGHP_OR_MEDIUMP qualifier, which both stages resolve the same way,
-- made them link.
--
-- install() wraps love.graphics.newShader once.  A shader that compiles pays
-- nothing: the rewrite only runs after the driver has already refused the
-- program for a precision mismatch, then retries with the uniforms
-- qualified.  Any other error, or a retry that still fails, raises the
-- original error untouched.

local ShaderPrecision = {}

local unpack = unpack or table.unpack

local QUALIFIER = "LOVE_HIGHP_OR_MEDIUMP"

-- Types whose default precision differs between stages.  Samplers default to
-- lowp in both stages and bool has no precision, so neither is touched.
local QUALIFIABLE = {
  float = true, vec2 = true, vec3 = true, vec4 = true,
  mat2 = true, mat3 = true, mat4 = true,
  int = true, ivec2 = true, ivec3 = true, ivec4 = true,
}

local PRECISIONS = { lowp = true, mediump = true, highp = true,
  [QUALIFIER] = true }

-- Is this error a uniform-precision link failure?  Drivers word it
-- differently (ANGLE/Chromium: "Precisions of uniform 'x' differ ...";
-- others mention "precision" and "uniform" in one line), so match loosely
-- and let the rewrite decide whether there is anything to fix.
function ShaderPrecision.isPrecisionError(err)
  if type(err) ~= "string" then return false end
  local lower = err:lower()
  return lower:find("precision", 1, true) ~= nil
    and lower:find("uniform", 1, true) ~= nil
end

-- The uniform names the error message quotes, if any.
function ShaderPrecision.namesIn(err)
  local names = {}
  if type(err) ~= "string" then return names end
  for name in err:gmatch("[Pp]recisions? of uniform%s+'([%w_]+)'") do
    names[#names + 1] = name
  end
  return names
end

-- Qualify every unqualified uniform/extern declaration of a qualifiable type
-- in `src` (or only those in `only`, a name set, when given).  Returns the
-- new source and how many declarations changed.  Declarations listing
-- several names ("uniform float a, b;") are qualified as a whole.
function ShaderPrecision.qualify(src, only)
  if type(src) ~= "string" then return src, 0 end
  local changed = 0
  local out = src:gsub("(%f[%w_])(%a+)(%s+)([%w_]+)(%s+)([%w_][%w_%s,%[%]]-);",
    function(lead, keyword, s1, typ, s2, names)
      if keyword ~= "uniform" and keyword ~= "extern" then return nil end
      if PRECISIONS[typ] or not QUALIFIABLE[typ] then return nil end
      if only then
        local hit = false
        for name in names:gmatch("[%a_][%w_]*") do
          if only[name] then hit = true break end
        end
        if not hit then return nil end
      end
      changed = changed + 1
      return lead .. keyword .. s1 .. QUALIFIER .. " " .. typ .. s2 .. names .. ";"
    end)
  return out, changed
end

local function looksLikeCode(v)
  return type(v) == "string"
    and (v:find("uniform", 1, true) or v:find("extern", 1, true)) ~= nil
end

-- Call newShader(...) and, on a precision link failure, retry with the
-- uniforms qualified: first only the names the error quoted (the smallest
-- change), then every qualifiable uniform.  Returns what newShader returns,
-- or raises the ORIGINAL error.
function ShaderPrecision.create(newShader, ...)
  local ok, shader = pcall(newShader, ...)
  if ok then return shader end
  local err = shader
  if not ShaderPrecision.isPrecisionError(err) then error(err, 0) end
  local args = { ... }
  local n = select("#", ...)
  local codeArgs = {}
  for i = 1, n do
    if looksLikeCode(args[i]) then codeArgs[#codeArgs + 1] = i end
  end
  if #codeArgs == 0 then error(err, 0) end

  local function retry(only)
    local copy, total = {}, 0
    for i = 1, n do copy[i] = args[i] end
    for _, i in ipairs(codeArgs) do
      local changed
      copy[i], changed = ShaderPrecision.qualify(copy[i], only)
      total = total + changed
    end
    if total == 0 then return false end
    local ok2, result = pcall(newShader, unpack(copy, 1, n))
    if ok2 then return true, result end
    return false
  end

  local named = ShaderPrecision.namesIn(err)
  if #named > 0 then
    local set = {}
    for _, name in ipairs(named) do set[name] = true end
    local fixed, result = retry(set)
    if fixed then
      ShaderPrecision.retried = (ShaderPrecision.retried or 0) + 1
      return result
    end
  end
  local fixed, result = retry(nil)
  if fixed then
    ShaderPrecision.retried = (ShaderPrecision.retried or 0) + 1
    return result
  end
  error(err, 0)
end

-- Wrap love.graphics.newShader once.  Safe to call repeatedly.
function ShaderPrecision.install()
  local g = love and love.graphics
  if not g or type(g.newShader) ~= "function" or ShaderPrecision.installed then
    return false
  end
  ShaderPrecision.installed = true
  local real = g.newShader
  ShaderPrecision.real = real
  g.newShader = function(...)
    return ShaderPrecision.create(real, ...)
  end
  return true
end

return ShaderPrecision
