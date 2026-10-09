import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import zipfile
from lupa.lua51 import LuaRuntime as Lua51
from lupa.luajit21 import LuaRuntime as LuaJIT

spec = importlib.util.spec_from_file_location("patch_ascendant_mod",
    Path(__file__).resolve().parents[1] / "ports/web/patch_ascendant_mod.py")
patch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(patch)


class AscendantPresentationTest(unittest.TestCase):
    def test_cadence_retains_elapsed_time_and_forces_new_battlers(self):
        for runtime in (Lua51, LuaJIT):
            with self.subTest(runtime=runtime.__module__):
                lua = runtime()
                helper = lua.execute(patch.HELPER.decode())
                lua.globals().presentation = helper
                lua.execute('''
                  local now, osName = 0, "Web"
                  love = {system={getOS=function() return osName end},
                    timer={getTime=function() return now end}}
                  local cap = {current=30}
                  package.loaded["src.core.FrameCap"] = cap
                  local session = {presentationCommitted=true, shot={},
                    battle={player={mon={}}, enemy={mon={}}}}
                  local count, elapsed = 0, 0
                  for i=0,119 do
                    now=i/120
                    local due, dt=presentation.step(session,1/120)
                    if due then count=count+1; elapsed=elapsed+dt end
                  end
                  assert(count==30, "120 callbacks must capture 30 battle shots")
                  assert(math.abs(elapsed+session._webBattlePresentation.elapsed-1)<1e-9,
                    "skipped callbacks retain their visual elapsed time")
                  cap.current=60; now=2
                  assert(presentation.step(session,1/120),"cap change presents immediately")
                  now=2+1/120
                  assert(not presentation.step(session,1/120))
                  session.battle.enemy.mon={}; now=2+2/120
                  assert(presentation.step(session,1/120),"new mon must retire the old shot")
                  now=3
                  local due,dt=presentation.step(session,.4)
                  assert(due and dt>=.4,"hitches present once and retain elapsed time")
                  assert(not presentation.step(session,0),"no burst after a hitch")
                  cap.current=0
                  assert(presentation.step(session,.001))
                  assert(presentation.step(session,.001),"unlocked does not skip")
                  cap.current=30; session.presentationCommitted=false
                  assert(presentation.step(session,.001))
                  assert(presentation.step(session,.001),"cold preparation is not capped")
                  osName="Windows"; session={}
                  local due,dt=presentation.step(session,.123)
                  assert(due and dt==.123 and not session._webBattlePresentation,
                    "native behavior is unchanged")
                ''')

    def test_archive_retains_assets_and_refuses_unknown_or_repeat_patch(self):
        with tempfile.TemporaryDirectory() as directory:
            source, output = Path(directory)/"source.zip", Path(directory)/"output.zip"
            with zipfile.ZipFile(source,"w") as archive:
                archive.writestr("manifest.json",json.dumps({"id":"VOXEL_ASCENDANT","version":"3.0.62"}))
                archive.writestr("lib/OverworldBattle.lua",patch.ANCHOR.replace(b"\n",b"\r\n"))
                archive.writestr("assets/art.bin",b"preserve all artwork")
            before=source.read_bytes()
            patch.patch_zip(source,output)
            self.assertEqual(before,source.read_bytes())
            with zipfile.ZipFile(output) as changed:
                self.assertEqual(changed.read("assets/art.bin"),b"preserve all artwork")
                self.assertEqual(changed.read("lib/WebBattlePresentation.lua"),patch.HELPER)
                self.assertIn(b"if not webDue then return end",changed.read("lib/OverworldBattle.lua"))
            with self.assertRaises(ValueError): patch.patch_zip(output,Path(directory)/"twice.zip")
            with self.assertRaises(FileExistsError): patch.patch_zip(source,output)
            with self.assertRaises(ValueError): patch.patch_zip(source,source)
            with zipfile.ZipFile(source,"w") as archive:
                archive.writestr("manifest.json",json.dumps({"id":"VOXEL_ASCENDANT","version":"3.0.63"}))
            with self.assertRaises(ValueError): patch.patch_zip(source,Path(directory)/"unsupported.zip")


if __name__ == "__main__": unittest.main()
