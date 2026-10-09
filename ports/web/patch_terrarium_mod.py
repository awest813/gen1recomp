"""Create a separate Terrarium 1.30.1 ZIP with browser compatibility fixes.

Import the output through the web port's MODS tab. The original is preserved.
"""
import argparse
import json
from pathlib import Path
import re
import zipfile

OLD = b'require("src.render.GBCFX")'
NEW = b'legacyGbcFx()'
BUDGET_OLD = b'if buildCo and coroutine.running() == buildCo and clock() > deadline then'
BUDGET_NEW = b'''-- begin/finish scope a single synchronous resume, including protected
  -- child coroutines used by PUC Lua's yieldable pcall compatibility shim.
  if buildCo and clock() > deadline then'''
HELPER = b'''-- Compatibility with engines that removed the legacy GBC FX pass.
-- Cache the lookup: pinEngineFx runs during rendering.
local cachedLegacyGbcFx
local function legacyGbcFx()
  if not cachedLegacyGbcFx then
    local ok, fx = pcall(require, "src.render.GBCFX")
    cachedLegacyGbcFx = ok and fx or { setLevel = function() end }
  end
  return cachedLegacyGbcFx
end

'''


UNIFORM_ANCHOR = b'local activeShader = nil'
UNIFORM_HELPER = b'''-- Shader variants remove unused uniforms. Cache presence per shader so
-- optional effects do not throw native exceptions on every draw.
local uniformPresence = setmetatable({}, { __mode = "k" })
local function sendUniform(sh, name, ...)
  if sh.hasUniform then
    local known = uniformPresence[sh]
    if not known then known = {}; uniformPresence[sh] = known end
    local present = known[name]
    if present == nil then
      local ok, value = pcall(sh.hasUniform, sh, name)
      if ok then present = value; known[name] = value end
    end
    if present == false then return false end
  end
  local ok, result = pcall(sh.send, sh, name, ...)
  return ok, result
end

'''


def patch_uniform_sends(source):
    call = b'pcall(sh.send, sh, '
    if source.count(call) != 177 or source.count(UNIFORM_ANCHOR) != 1:
        raise ValueError("Voxel3D uniform sends have changed or already have the fix")
    source = source.replace(call, b'sendUniform(sh, ')
    active_call = b'pcall(activeShader.send, activeShader, '
    if source.count(active_call) != 6:
        raise ValueError("Voxel3D active shader sends have changed")
    source = source.replace(active_call, b'sendUniform(activeShader, ')
    return source.replace(UNIFORM_ANCHOR, UNIFORM_HELPER + UNIFORM_ANCHOR)


def patch_shader(source):
    start = source.index(b"local SHADER = [[")
    vertex = re.search(rb"^#ifdef VERTEX\s*$", source[start:], re.M)
    if vertex is None:
        raise ValueError("Voxel3D shader stage boundary has changed")
    end = start + vertex.start()
    shared = source[start:end]
    pattern = rb"\buniform (float|vec[234]|mat[234])\b"
    if len(re.findall(pattern, shared)) != 36:
        raise ValueError("Voxel3D shared uniforms have changed or already have the fix")
    # GLES requires matching precision for uniforms active in both stages.
    # LOVE's macro chooses highp when supported, mediump otherwise.
    shared = re.sub(pattern, rb"uniform LOVE_HIGHP_OR_MEDIUMP \1", shared)
    return source[:start] + shared + source[end:]


TREE_LOOKUP_OLD = b'return V.require("Structures").forMap(map)'
TREE_LOOKUP_NEW = b'''local structures = V.require("Structures")
    if cachedOnly then return structures.peek(map) end
    return structures.forMap(map)'''
TREE_PENDING_OLD = b'    local sites = sitesFor(map)'
TREE_PENDING_NEW = b'''    -- The terrain builder owns analysis. Drawing a distant neighbour must
    -- wait for its cache instead of rebuilding it synchronously on this frame.
    local sites = sitesFor(map, true)
    if not sites then return nil end'''

MESH_OLD = b'''  local ok, mesh = pcall(love.graphics.newMesh, Voxel3D.FORMAT, verts,
                         "triangles", "static")'''
MESH_NEW = b'''  local mesh
  local ok
  if love.system and love.system.getOS and love.system.getOS() == "Web" and #verts > 2048 then
    local Budget = V.require("BuildBudget")
    ok = pcall(function()
      mesh = love.graphics.newMesh(Voxel3D.FORMAT, #verts, "triangles", "static")
      for first = 1, #verts, 256 do
        local slice = {}
        for i = first, math.min(first + 255, #verts) do
          slice[#slice + 1] = verts[i]
        end
        mesh:setVertices(slice, first)
        Budget.check()
      end
    end)
    if not ok and mesh then mesh:release(); mesh = nil end
  else
    ok, mesh = pcall(love.graphics.newMesh, Voxel3D.FORMAT, verts,
                     "triangles", "static")
  end'''
TREE_SLICE_OLD = b'''  local last = math.min(st.i + Trees3D.SLICE_SITES - 1, #st.sites)
  Trees3D.stampRange(st, st.i, last)
  st.i = last + 1
  if st.i <= #st.sites then return nil end

  local built = Trees3D.finishBuild(st)'''
TREE_SLICE_NEW = b'''  local built
  if love.system and love.system.getOS and love.system.getOS() == "Web" then
    local Budget = V.require("BuildBudget")
    if not st.co then
      st.co = coroutine.create(function()
        for i = 1, #st.sites do
          Trees3D.stampRange(st, i, i)
          st.i = i + 1
          Budget.check()
        end
        return Trees3D.finishBuild(st)
      end)
    end
    Budget.begin(st.co, 0.001)
    local ok, result = coroutine.resume(st.co)
    Budget.finish()
    if not ok then
      pending[id] = nil
      meshes[id] = false
      if V.mod and V.mod.log then
        pcall(V.mod.log.warn, V.mod.log, "tree build failed on %s: %s", id, tostring(result))
      end
      return nil
    end
    if coroutine.status(st.co) ~= "dead" then return nil end
    built = result
  else
    local last = math.min(st.i + Trees3D.SLICE_SITES - 1, #st.sites)
    Trees3D.stampRange(st, st.i, last)
    st.i = last + 1
    if st.i <= #st.sites then return nil end
    built = Trees3D.finishBuild(st)
  end'''


def replace_lua(source, old, new):
    newline = b"\r\n" if b"\r\n" in source else b"\n"
    source = source.replace(b"\r\n", b"\n")
    if source.count(old) != 1:
        raise ValueError("Mesh upload implementation has changed or already has the fix")
    return source.replace(old, new).replace(b"\n", newline)


ROAMER_ROOT_OLD = b'  return "save/mod-derived/" .. id .. "/roamers/"'
ROAMER_ROOT_NEW = b'''  if V.mod and V.mod.cache then
    return "mod_cache/" .. id .. "/roamers/"
  end
  return "save/mod-derived/" .. id .. "/roamers/"'''
ROAMER_WRITE_OLD = b'  local ok, err = love.filesystem.write(path, sheet:encode("png"))'
ROAMER_WRITE_NEW = b'''  local ok, err
  if V.mod and V.mod.cache then
    local rel = path:match("^mod_cache/[^/]+/(.+)$")
    local encoded = sheet:encode("png")
    ok, err = V.mod.cache:write(rel, encoded:getString())
    encoded:release()
  else
    ok, err = love.filesystem.write(path, sheet:encode("png"))
  end'''

HUD_ORIGIN_OLD = b'  local ex = -e[1] * s                       -- foe: panel\'s left edge to 0'
HUD_ORIGIN_NEW = b'''  -- Keep the full enemy band inside the canvas. Its leading tile is
  -- padding for names and HUD shake, not disposable letterbox space.
  local ex = 0'''


def patch_trees(source):
    newline = b"\r\n" if b"\r\n" in source else b"\n"
    source = source.replace(b"\r\n", b"\n")
    signature = b"local function sitesFor(map)"
    start = source.index(b"local function meshesFor(map)")
    before, draw = source[:start], source[start:]
    if before.count(signature) != 1 or before.count(TREE_LOOKUP_OLD) != 1 or draw.count(TREE_PENDING_OLD) != 1:
        raise ValueError("Trees3D analysis lookup has changed or already has the fix")
    before = before.replace(signature, b"local function sitesFor(map, cachedOnly)")
    before = before.replace(TREE_LOOKUP_OLD, TREE_LOOKUP_NEW)
    draw = draw.replace(TREE_PENDING_OLD, TREE_PENDING_NEW)
    return (before + draw).replace(b"\n", newline)


def patch_zip(source, destination):
    source, destination = Path(source), Path(destination)
    if source.resolve() == destination.resolve():
        raise ValueError("Choose a separate output ZIP; keep the original")
    with zipfile.ZipFile(source) as archive:
        manifest = json.loads(archive.read("TERRARIUM/manifest.json"))
        if (manifest.get("id"), manifest.get("version")) != ("TERRARIUM", "1.30.1"):
            raise ValueError("This patch only supports Terrarium 1.30.1")
        main = archive.read("TERRARIUM/main.lua")
        if main.count(OLD) != 2:
            raise ValueError("Terrarium main.lua has changed or already has the fix")
        main = HELPER + main.replace(OLD, NEW)
        shader = patch_shader(archive.read("TERRARIUM/lib/Voxel3D.lua"))
        shader = replace_lua(shader, MESH_OLD, MESH_NEW)
        shader = patch_uniform_sends(shader)
        budget = archive.read("TERRARIUM/lib/BuildBudget.lua")
        if budget.count(BUDGET_OLD) != 2:
            raise ValueError("BuildBudget has changed or already has the fix")
        budget = budget.replace(BUDGET_OLD, BUDGET_NEW)
        trees = patch_trees(archive.read("TERRARIUM/lib/Trees3D.lua"))
        trees = replace_lua(trees, TREE_SLICE_OLD, TREE_SLICE_NEW)
        roamers = archive.read("TERRARIUM/lib/RoamerArt.lua")
        roamers = replace_lua(roamers, ROAMER_ROOT_OLD, ROAMER_ROOT_NEW)
        roamers = replace_lua(roamers, ROAMER_WRITE_OLD, ROAMER_WRITE_NEW)
        battle = replace_lua(archive.read("TERRARIUM/lib/OverworldBattle.lua"),
                             HUD_ORIGIN_OLD, HUD_ORIGIN_NEW)
        replacements = {"TERRARIUM/main.lua": main, "TERRARIUM/lib/Voxel3D.lua": shader,
                        "TERRARIUM/lib/BuildBudget.lua": budget,
                        "TERRARIUM/lib/Trees3D.lua": trees,
                        "TERRARIUM/lib/RoamerArt.lua": roamers,
                        "TERRARIUM/lib/OverworldBattle.lua": battle}
        with zipfile.ZipFile(destination, "x") as output:
            for entry in archive.infolist():
                output.writestr(entry, replacements.get(entry.filename, archive.read(entry)))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source")
    parser.add_argument("destination")
    args = parser.parse_args()
    patch_zip(args.source, args.destination)
