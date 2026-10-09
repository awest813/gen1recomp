import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import zipfile

try:
    from lupa.lua51 import LuaRuntime
except ImportError:
    LuaRuntime = None

spec = importlib.util.spec_from_file_location("patch_terrarium_mod", Path(__file__).resolve().parents[1] / "ports/web/patch_terrarium_mod.py")
patch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(patch)

TREE_FIXTURE = b'''local V = ...
local function sitesFor(map)
  local ok, S = pcall(function()
    return V.require("Structures").forMap(map)
  end)
  if not ok or not S then return nil end
  return S.treeSites
end
local function meshesFor(map)
    local sites = sitesFor(map)
    if not sites or #sites == 0 then return false end
    return sites
end
return {draw=meshesFor, probe=sitesFor}
'''
TREE_ARCHIVE_FIXTURE = TREE_FIXTURE + b"\n" + patch.TREE_SLICE_OLD


class PatchTerrariumTest(unittest.TestCase):
    def archive(self, path, version="1.30.1"):
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr("TERRARIUM/manifest.json", json.dumps({"id": "TERRARIUM", "version": version}))
            archive.writestr("TERRARIUM/main.lua", patch.OLD + b"\n" + patch.OLD)
            archive.writestr("TERRARIUM/lib/Voxel3D.lua", b'local SHADER = [[\n'
                             + b'uniform float swellPhase;\n' * 36
                             + b'#ifdef VERTEX\n#endif\n#ifdef PIXEL\nuniform float fragmentOnly;\n#endif\n]]\n' + patch.MESH_OLD
                             + b'\n' + patch.UNIFORM_ANCHOR + b'\n'
                             + b'pcall(sh.send, sh, "optional", 1)\n' * 177
                             + b'pcall(activeShader.send, activeShader, "optional", 1)\n' * 6
                             + b'function Voxel3D.beginScene(w, h, cx, cy, vw, vh, sky, slot)\nend')
            archive.writestr("TERRARIUM/assets/example.bin", b"unchanged")
            archive.writestr("TERRARIUM/lib/BuildBudget.lua", patch.BUDGET_OLD + b"\n" + patch.BUDGET_OLD)
            archive.writestr("TERRARIUM/lib/Trees3D.lua", TREE_ARCHIVE_FIXTURE)
            archive.writestr("TERRARIUM/lib/RoamerArt.lua", patch.ROAMER_ROOT_OLD + b"\n" + patch.ROAMER_WRITE_OLD)
            archive.writestr("TERRARIUM/lib/OverworldBattle.lua", patch.HUD_ORIGIN_OLD)

    def test_preserves_original_and_other_files(self):
        with tempfile.TemporaryDirectory() as directory:
            source, output = Path(directory) / "source.zip", Path(directory) / "output.zip"
            self.archive(source)
            before = source.read_bytes()
            patch.patch_zip(source, output)
            self.assertEqual(source.read_bytes(), before)
            with zipfile.ZipFile(source) as original, zipfile.ZipFile(output) as changed:
                self.assertEqual(original.namelist(), changed.namelist())
                for name in original.namelist():
                    expected = original.read(name)
                    if name.endswith("/main.lua"):
                        expected = patch.HELPER + expected.replace(patch.OLD, patch.NEW)
                    elif name.endswith("/Voxel3D.lua"):
                        expected = expected.replace(b'uniform float swellPhase;', b'uniform LOVE_HIGHP_OR_MEDIUMP float swellPhase;')
                        expected = patch.replace_lua(expected, patch.MESH_OLD, patch.MESH_NEW)
                        expected = patch.patch_uniform_sends(expected)
                    elif name.endswith("/BuildBudget.lua"):
                        expected = expected.replace(patch.BUDGET_OLD, patch.BUDGET_NEW)
                    elif name.endswith("/Trees3D.lua"):
                        expected = patch.patch_trees(expected)
                        expected = patch.replace_lua(expected, patch.TREE_SLICE_OLD, patch.TREE_SLICE_NEW)
                    elif name.endswith("/RoamerArt.lua"):
                        expected = patch.replace_lua(expected, patch.ROAMER_ROOT_OLD, patch.ROAMER_ROOT_NEW)
                        expected = patch.replace_lua(expected, patch.ROAMER_WRITE_OLD, patch.ROAMER_WRITE_NEW)
                    elif name.endswith("/OverworldBattle.lua"):
                        expected = patch.replace_lua(expected, patch.HUD_ORIGIN_OLD, patch.HUD_ORIGIN_NEW)
                    self.assertEqual(changed.read(name), expected)
            with self.assertRaises(FileExistsError):
                patch.patch_zip(source, output)

    @unittest.skipIf(LuaRuntime is None, "Lua behavior probe requires Lupa")
    def test_enemy_hud_padding_remains_inside_canvas(self):
        lua = LuaRuntime()
        source = '''return function(pw, ph)
          local s = math.min(pw/160, ph/144)
          local e = {8,0,80,32}
        ''' + patch.HUD_ORIGIN_NEW.decode() + '''
          return ex, ex+e[1]*s, s
        end'''
        origin = lua.execute(source)
        for pw, ph in [(320,288),(714,692),(1280,720),(360,640)]:
            band, panel, scale = origin(pw, ph)
            self.assertEqual(band, 0)
            self.assertGreaterEqual(panel-2*scale, 0, "shake must retain leading padding")
            self.assertLessEqual(band+160*scale, pw)

    @unittest.skipIf(LuaRuntime is None, "Lua behavior probe requires Lupa")
    def test_uniform_presence_is_cached_per_shader_without_caching_values(self):
        lua = LuaRuntime()
        lua.execute(patch.UNIFORM_HELPER.decode() + '''
          local queries, sends = 0, 0
          local sh = {hasUniform=function(_, name)
            queries=queries+1; return name=="model" end,
            send=function(_, name, value)
              sends=sends+1; assert(name=="model"); return value end}
          for i=1,120 do
            assert(sendUniform(sh,"missing",i)==false)
            local ok, value=sendUniform(sh,"model",i)
            assert(ok and value==i)
          end
          assert(queries==2 and sends==120)
          local other={hasUniform=function() queries=queries+1; return true end,
            send=function() sends=sends+1 end}
          assert(sendUniform(other,"missing",1)); assert(queries==3)
          local legacy={send=function() return 42 end}
          local ok,value=sendUniform(legacy,"x"); assert(ok and value==42)
          local broken={hasUniform=function() error("unsupported") end,
            send=function() error("bad value") end}
          assert(sendUniform(broken,"x")==false)
        ''')

    def test_refuses_other_versions_and_in_place_edits(self):
        with tempfile.TemporaryDirectory() as directory:
            source, output = Path(directory) / "source.zip", Path(directory) / "output.zip"
            self.archive(source, "2.0.0")
            with self.assertRaises(ValueError):
                patch.patch_zip(source, output)
            self.assertFalse(output.exists())
            with self.assertRaises(ValueError):
                patch.patch_zip(source, source)

    @unittest.skipIf(LuaRuntime is None, "Lua behavior probe requires Lupa")
    def test_drawing_waits_for_analysis_without_poisoning_cache(self):
        lua = LuaRuntime()
        lua.execute('''builds=0; ready=nil
            structures={peek=function() return ready end,
              forMap=function() builds=builds+1; return {treeSites={42}} end}
            V={require=function() return structures end}''')
        module = lua.execute(patch.patch_trees(TREE_FIXTURE).decode(), lua.globals().V)
        lua.globals().trees = module
        lua.execute('''map={id="distant"}
            for i=1,120 do assert(trees.draw(map)==nil) end
            assert(builds==0, "draw must never start synchronous analysis")
            ready={treeSites={7}}; assert(trees.draw(map)[1]==7)
            ready={treeSites={}}; assert(trees.draw(map)==false)
            assert(trees.probe(map)[1]==42 and builds==1,
              "explicit synchronous probes retain their contract")''')

    @unittest.skipIf(LuaRuntime is None, "Lua behavior probe requires Lupa")
    def test_sliced_upload_preserves_vertices_and_yields_inside_pcall(self):
        for platform in ("Web", "Linux"):
            lua = LuaRuntime()
            root = Path(__file__).resolve().parents[1]
            lua.globals().compat = lua.execute((root / "src/core/LuaCompat.lua").read_text())
            lua.globals().platform = platform
            lua.execute('''pcall=compat.coPcall; slices=0; checks=0
              love={system={getOS=function() return platform end},graphics={}}
              Budget={check=function() checks=checks+1; coroutine.yield("slice") end}
              V={require=function() return Budget end}; Voxel3D={FORMAT={}}
              love.graphics.newMesh=function(format,vertices)
                local mesh={vertices={}}
                if type(vertices)=="table" then
                  for i,v in ipairs(vertices) do mesh.vertices[i]=v end
                else mesh.count=vertices end
                function mesh:setVertices(values,first)
                  assert(#values<=256); slices=slices+1
                  for i,v in ipairs(values) do self.vertices[first+i-1]=v end
                end
                function mesh:release() self.released=true end
                return mesh
              end''')
            lua.execute('''worker=function(verts)
              ''' + patch.MESH_NEW.decode() + '''
              assert(ok); return mesh
            end
            verts={}; for i=1,2301 do verts[i]={i,-i,i/100,0,1,-0.8} end
            co=coroutine.create(function() result=worker(verts) end)
            yields=0
            repeat local ok,value=coroutine.resume(co); assert(ok,value)
              if coroutine.status(co)~="dead" then yields=yields+1 end
            until coroutine.status(co)=="dead"
            for i=1,#verts do for j=1,6 do
              assert(result.vertices[i][j]==verts[i][j]) end end
            assert(not result.released)
            assert(yields==(platform=="Web" and 9 or 0))
            assert(slices==yields and checks==yields)''')

    @unittest.skipIf(LuaRuntime is None, "Lua behavior probe requires Lupa")
    def test_tree_build_publishes_only_complete_mesh_and_retires_errors(self):
        lua = LuaRuntime()
        lua.execute('''active=false; stamped={}; finished=0; id="route"
          love={system={getOS=function() return "Web" end}}
          Budget={begin=function() assert(not active); active=true end,
            finish=function() active=false end,
            check=function() assert(active); coroutine.yield("budget") end}
          V={require=function() return Budget end}
          Trees3D={stampRange=function(st,first,last)
            assert(first==last); stamped[#stamped+1]=first end,
            finishBuild=function(st) finished=finished+1; return {complete=true} end}
          st={sites={1,2,3},i=1}; pending={[id]=st}; meshes={}
        ''')
        lua.execute('step=function(st)\n' + patch.TREE_SLICE_NEW.decode() + '\nreturn built end')
        lua.execute('''for i=1,3 do
            assert(step(st)==nil and not active and finished==0)
            assert(st.i==i+1 and #stamped==i)
          end
          result=step(st); assert(result.complete and finished==1 and not active)
          for i=1,3 do assert(stamped[i]==i) end
          st={sites={1},i=1}; pending[id]=st
          Trees3D.stampRange=function() error("failed upload") end
          assert(step(st)==nil and not active)
          assert(pending[id]==nil and meshes[id]==false)''')

    @unittest.skipIf(LuaRuntime is None, "Lua behavior probe requires Lupa")
    def test_roamer_png_uses_engine_visible_cache_bytes(self):
        lua = LuaRuntime()
        lua.execute('''bytes="\\137PNG\\r\\n\\26\\n\\0\\255"
          files={}; released=false
          V={mod={id="TERRARIUM",cache={write=function(self,rel,value)
            assert(type(value)=="string"); files["mod_cache/TERRARIUM/"..rel]=value
            return true end}}}
          love={filesystem={write=function() error("legacy write must not run") end}}
          sheet={encode=function() return {getString=function() return bytes end,
            release=function() released=true end} end}''')
        lua.execute('''root=function() local id=V.mod.id
          ''' + patch.ROAMER_ROOT_NEW.decode() + ''' end
          path=root().."POLIWAG-3.png"
          ''' + patch.ROAMER_WRITE_NEW.decode() + '''
          assert(ok and released)
          assert(files[path]==bytes, "the engine-visible path must contain PNG bytes")''')

    @unittest.skipIf(LuaRuntime is None, "Lua behavior probe requires Lupa's Lua 5.1 runtime")
    def test_legacy_fx_present_and_removed(self):
        for present in (True, False):
            lua = LuaRuntime()
            lua.globals().present = present
            lua.execute('''calls, levels = 0, {}
                require = function(name)
                  assert(name == "src.render.GBCFX")
                  calls = calls + 1
                  if not present then error("module removed") end
                  return {setLevel = function(level) levels[#levels + 1] = level end}
                end''')
            lua.execute(patch.HELPER.decode() + '''
                for i = 1, 120 do legacyGbcFx().setLevel(0) end
                assert(calls == 1, "module lookup must be cached")
                assert(#levels == (present and 120 or 0))
                for _, level in ipairs(levels) do assert(level == 0) end''')

    @unittest.skipIf(LuaRuntime is None, "Lua behavior probe requires Lupa's Lua 5.1 runtime")
    def test_budget_yields_through_protected_child_coroutine(self):
        # Use the real engine's protected-call shim and a controllable clock.
        root = Path(__file__).resolve().parents[1]
        compat = (root / "src/core/LuaCompat.lua").read_text()
        for fixed in (False, True):
            lua = LuaRuntime()
            lua.globals().compat = lua.execute(compat)
            lua.execute('now=0; love={timer={getTime=function() return now end}}')
            guard = patch.BUDGET_NEW if fixed else patch.BUDGET_OLD
            # Budget's exact deadline/coroutine guard is the behavior under test.
            lua.globals().budget = lua.execute('''local buildCo,deadline
                local clock=love.timer.getTime
                return {begin=function(co) buildCo,deadline=co,0 end,
                  finish=function() buildCo=nil end,
                  check=function() ''' + guard.decode() + '''
                    coroutine.yield("budget") end end}''')
            lua.execute('''done=false
                co=coroutine.create(function()
                  local ok=compat.coPcall(function() budget.check(); done=true end)
                  assert(ok)
                end)
                budget.begin(co); now=1
                ok,value=coroutine.resume(co); assert(ok)
                budget.finish()
                budget.check() -- outside pump must not attempt to yield
            ''')
            self.assertEqual(lua.globals().done, not fixed)
            if fixed:
                self.assertEqual(lua.globals().value, "budget")
                lua.execute('budget.begin(co); now=-1; assert(coroutine.resume(co)); budget.finish(); assert(done)')
