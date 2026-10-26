-- Engine-side support for the voxel renderer mods
-- (docs/web-voxel-audit-2026-10-08.md, docs/proposals/web-mods.md).
-- No pokered cite: mod plumbing is port-only.
--
--   * a mod that requires the retired src.render.GBCFX gets an inert
--     stand-in instead of a hard error (Terrarium's save.created handler);
--   * a shader the browser refuses for mismatched uniform precision is
--     retried with LOVE_HIGHP_OR_MEDIUMP uniforms (Terrarium's four terrain
--     shaders), while a shader that compiles is created exactly once and any
--     other error comes back untouched;
--   * a mod call site that creates canvases every frame is named once
--     (PotatoVoxel's shadow-map thrash), while engine calls are never counted.
--   luajit tests/engine/mod_voxel_compat_test.lua

package.path = "./?.lua;./?/init.lua;" .. package.path
love = love or require("tests.love_stub")

local S = require("tests.harness").suite("mod voxel compat")
local check, eq = S.check, S.eq

local Logger = require("src.core.Logger")
local warnings = {}
local realWarn = Logger.warn
Logger.warn = function(fmt, ...)
  warnings[#warnings + 1] = fmt:format(...)
end

-- ----------------------------------------------------- shader precision

local SP = require("src.render.ShaderPrecision")
local Q = "LOVE_HIGHP_OR_MEDIUMP"

local src = table.concat({
  "uniform float swellPhase;",
  "extern vec3 windDir;",
  "uniform highp float already;",
  "uniform Image noiseTex;",
  "uniform vec4 lights[4];",
  "uniform float a, b;",
  "precision mediump float;",
  "float local = 1.0;",
}, "\n")
local out, n = SP.qualify(src)
eq(n, 4, "four unqualified numeric uniform declarations are qualified")
check(out:find("uniform " .. Q .. " float swellPhase;", 1, true) ~= nil,
  "a float uniform gets the shared qualifier")
check(out:find("extern " .. Q .. " vec3 windDir;", 1, true) ~= nil,
  "LÖVE's extern spelling is qualified too")
check(out:find("uniform highp float already;", 1, true) ~= nil,
  "an explicit precision is left alone")
check(out:find("uniform Image noiseTex;", 1, true) ~= nil,
  "samplers are left alone")
check(out:find("uniform " .. Q .. " vec4 lights[4];", 1, true) ~= nil,
  "arrays are qualified")
check(out:find("uniform " .. Q .. " float a, b;", 1, true) ~= nil,
  "multi-name declarations are qualified as a whole")
check(out:find("precision mediump float;", 1, true) ~= nil
    and out:find("float local = 1.0;", 1, true) ~= nil,
  "statements that are not uniform declarations are untouched")
local again, n2 = SP.qualify(out)
eq(n2, 0, "qualifying is idempotent")
eq(again, out, "and leaves qualified source byte-identical")
local onlyOut, onlyN = SP.qualify(src, { windDir = true })
eq(onlyN, 1, "a name filter qualifies only the named uniform")
check(onlyOut:find("uniform float swellPhase;", 1, true) ~= nil,
  "and leaves the rest as written")

eq(SP.namesIn("Precisions of uniform 'swellPhase' differ between VERTEX "
  .. "and FRAGMENT shaders.")[1], "swellPhase", "the quoted uniform is read")
check(SP.isPrecisionError("Error linking: Precisions of uniform 'x' differ"),
  "the ANGLE wording is a precision error")
check(not SP.isPrecisionError("Cannot compile pixel shader code: syntax error"),
  "a syntax error is not")

-- A driver that refuses any unqualified uniform both stages share.
local calls
local function strictNewShader(code, code2)
  calls = calls + 1
  for _, c in ipairs({ code, code2 }) do
    if type(c) == "string" then
      local name = c:match("uniform%s+float%s+([%w_]+);")
      if name then
        error("Error validating shader: Precisions of uniform '" .. name
          .. "' differ between VERTEX and FRAGMENT shaders.", 0)
      end
    end
  end
  return { code = code, code2 = code2 }
end

calls = 0
local shader = SP.create(strictNewShader,
  "uniform float swellPhase;\nuniform float other;\nvoid main() {}",
  "uniform float swellPhase;\nvoid main() {}")
check(shader and shader.code:find(Q, 1, true) ~= nil,
  "a precision-refused shader links on retry")
check(shader.code2:find("uniform " .. Q .. " float swellPhase;", 1, true) ~= nil,
  "with both stages qualified alike")
check(calls <= 3, "within a bounded number of attempts")

calls = 0
local plain = SP.create(strictNewShader, "uniform highp float ok;\nvoid main() {}")
eq(calls, 1, "a shader that compiles is created exactly once")
check(plain.code == "uniform highp float ok;\nvoid main() {}",
  "and its source is not rewritten")

local function syntaxError() error("Cannot compile shader: syntax error", 0) end
local ok, err = pcall(SP.create, syntaxError, "uniform float x;")
check(not ok and err == "Cannot compile shader: syntax error",
  "any other error comes back untouched")

local function alwaysPrecision()
  error("Precisions of uniform 'x' differ between VERTEX and FRAGMENT shaders.", 0)
end
ok, err = pcall(SP.create, alwaysPrecision, "uniform float x;")
check(not ok and err:find("Precisions of uniform 'x'", 1, true) ~= nil,
  "a retry that still fails raises the ORIGINAL error")
ok, err = pcall(SP.create, alwaysPrecision, "shaders/terrain.glsl")
check(not ok and err:find("Precisions", 1, true) ~= nil,
  "a file-path argument is not rewritten; the original error stands")

local realNew = love.graphics.newShader
calls = 0
love.graphics.newShader = strictNewShader
SP.installed = nil
check(SP.install(), "install wraps love.graphics.newShader")
local viaLove = love.graphics.newShader("uniform float swell;\nvoid main() {}")
check(viaLove.code:find(Q, 1, true) ~= nil,
  "the installed wrapper retries through love.graphics.newShader")
love.graphics.newShader = realNew
SP.installed = nil

-- --------------------------------------------------------- resource guard

local RG = require("src.mods.ResourceGuard")
check(RG.isModSource("@mods/potatovoxel/lib/ShadowMap.lua"), "a mod file is a mod source")
check(not RG.isModSource("@src/render/Renderer.lua"), "an engine file is not")
check(not RG.isModSource("@main.lua"), "main.lua is not")
check(not RG.isModSource("=[C]"), "a C frame is not")

RG.reset()
for i = 1, RG.LIMIT do
  RG.note("newCanvas", { source = "@mods/v/lib/ShadowMap.lua", currentline = 42 },
    10 + i * 0.01)
end
eq(#RG.report(), 0, "up to the limit inside a second is fine")
RG.note("newCanvas", { source = "@mods/v/lib/ShadowMap.lua", currentline = 42 }, 10.5)
eq(#RG.report(), 1, "one more inside the window flags the call site")
eq(RG.report()[1].site, "mods/v/lib/ShadowMap.lua:42", "naming file and line")
local nWarn = #warnings
for _ = 1, 50 do
  RG.note("newCanvas", { source = "@mods/v/lib/ShadowMap.lua", currentline = 42 }, 10.6)
end
eq(#RG.report(), 1, "a flagged site is reported once")
eq(#warnings, nWarn, "and warned once")

RG.reset()
for i = 1, 200 do
  RG.note("newImage", { source = "@mods/v/lib/Loader.lua", currentline = 7 }, i * 1.5)
end
eq(#RG.report(), 0, "steady creation spread across seconds is not a thrash")

-- the installed wrappers, driven from a chunk named like a mod file and one
-- named like an engine file
RG.reset()
local created = 0
love.graphics.newCanvas = function() created = created + 1 return {} end
RG.installed = nil
check(RG.install(), "install wraps the creation calls")
local modChunk = assert(loadstring(
  "for i = 1, 60 do love.graphics.newCanvas(8, 8) end", "@mods/v/lib/ShadowMap.lua"))
modChunk()
eq(created, 60, "every call still reaches LÖVE")
eq(#RG.report(), 1, "the mod's per-frame canvas site is flagged")
RG.reset()
local engineChunk = assert(loadstring(
  "for i = 1, 60 do love.graphics.newCanvas(8, 8) end", "@src/render/Pipelines.lua"))
engineChunk()
eq(#RG.report(), 0, "engine creation is never counted")

-- ------------------------------------------------------------ retired module

local Loader = require("src.mods.Loader")
local function memfs(files)
  return {
    read = function(path) return files[path] end,
    write = function(path, content) files[path] = content return true end,
    remove = function(path) files[path] = nil return true end,
    getInfo = function(path)
      if files[path] then return { type = "file" } end
      local prefix = path .. "/"
      for key in pairs(files) do
        if key:sub(1, #prefix) == prefix then return { type = "directory" } end
      end
      return nil
    end,
    load = function(path)
      if not files[path] then return nil, "no file: " .. path end
      return loadstring(files[path], "@" .. path)
    end,
    createDirectory = function() return true end,
    getDirectoryItems = function(path)
      local seen, items = {}, {}
      local prefix = path .. "/"
      for key in pairs(files) do
        if key:sub(1, #prefix) == prefix then
          local child = key:sub(#prefix + 1):match("^[^/]+")
          if child and not seen[child] then
            seen[child] = true
            items[#items + 1] = child
          end
        end
      end
      table.sort(items)
      return items
    end,
  }
end

local files = {
  ["mods/terrarium/manifest.json"] =
    [[{"id":"terrarium","name":"terrarium","version":"1.30.1","entry":"main.lua"}]],
  ["mods/terrarium/main.lua"] = [[
    return function(mod)
      local fx = require("src.render.GBCFX")
      fx.setLevel(0)
      fx.disable()
      assert(type(fx.anything) == "function", "stand-in field is not callable")
      assert(fx.getLevel() == nil, "stand-in calls return nothing")
    end
  ]],
}
nWarn = #warnings
local loader = Loader.new({ fs = memfs(files) })
local okLoad, loadErr = pcall(loader.load, loader, { pokemon = {} })
check(okLoad, "a mod requiring the retired GBCFX loads: " .. tostring(loadErr))
eq(next(loader.errors) == nil and true or loader.errors, true,
  "with no load error recorded (the stand-in's asserts held)")
local saw
for i = nWarn + 1, #warnings do
  if warnings[i]:find("src.render.GBCFX", 1, true) then saw = warnings[i] end
end
check(saw ~= nil and saw:find("terrarium", 1, true) ~= nil,
  "the entry ran the require, and the author hears about it by mod id")
eq(package.loaded["src.render.GBCFX"], nil,
  "the stand-in is never registered as the engine's own module")
local okEngine = pcall(require, "src.render.GBCFX")
check(not okEngine, "engine code requiring it still fails loudly")

Logger.warn = realWarn
S.finish()
