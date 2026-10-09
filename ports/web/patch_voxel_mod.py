"""Make a local PotatoVoxel 1.9.6 ZIP with stable shadow probes and lower web build memory.

Usage: python ports/web/patch_voxel_mod.py ORIGINAL.zip PATCHED.zip
Import PATCHED.zip through the web port's MODS tab. The original is preserved.
"""
import argparse
import json
from pathlib import Path
import zipfile

OLD = b"if getCanvas(ShadowMap.SIZES[1]) == nil then"
NEW = b"if getCanvas(canvas and canvasRes or ShadowMap.SIZES[1]) == nil then"
MESH_OLD = b'if MeshCache.available() then\n    job.phase = "save"'
MESH_NEW = b'''if MeshCache.available() and not require("src.core.Platform").isWeb() then
    job.phase = "save"'''
QUALITY_OLD = b'''  QualityMode.renderSetting:setValue(p.render, game)
  Water.setting:setValue(p.water, game)
  AntiAlias.setting:setValue(p.aa, game)
  WorldCurve.setting:setValue(p.curve, game)
  VoxelGrid.setting:setValue(p.grid, game)
  OverworldBattle.setting:setValue(p.btl, game)
  ShadowSettings.enabledSetting:setValue(p.shadows, game)
  ShadowSettings.qualitySetting:setValue(p.shadowQuality, game)'''
QUALITY_NEW = QUALITY_OLD.replace(b", game)", b", target)")
QUALITY_NEW = b'''  local target = game
  local batch = game and require("src.core.Platform").isWeb()
  if batch then target = { save = game.save, mods = game.mods } end
''' + QUALITY_NEW + b'''
  if batch and game.writeOptions then pcall(game.writeOptions, game) end'''


def patch_zip(source, destination):
    source, destination = Path(source), Path(destination)
    if source.resolve() == destination.resolve():
        raise ValueError("Choose a separate output ZIP; keep the original")
    with zipfile.ZipFile(source) as archive:
        manifest = json.loads(archive.read("manifest.json"))
        if (manifest.get("id"), manifest.get("version")) != ("potato_voxel", "1.9.6"):
            raise ValueError("This patch only supports PotatoVoxel 1.9.6")
        shadow = archive.read("lib/ShadowMap.lua")
        if shadow.count(OLD) != 1:
            raise ValueError("ShadowMap has changed or already has the fix")
        shadow = shadow.replace(OLD, NEW)
        # On the browser's PUC Lua, flattening all vertex rows for a cache
        # write duplicates a map's largest arrays while its GPU upload is
        # still live. Keep cache reads; skip this optional write on web.
        mesh = archive.read("lib/ChunkMesher.lua")
        if mesh.count(MESH_OLD) != 1:
            raise ValueError("ChunkMesher has changed or already has the fix")
        quality = archive.read("lib/QualityMode.lua")
        if quality.count(QUALITY_OLD) != 1:
            raise ValueError("QualityMode has changed or already has the fix")
        replacements = {"lib/ShadowMap.lua": shadow,
                        "lib/ChunkMesher.lua": mesh.replace(MESH_OLD, MESH_NEW),
                        "lib/QualityMode.lua": quality.replace(QUALITY_OLD, QUALITY_NEW)}
        # Validate everything before creating the destination. Exclusive
        # creation keeps an existing downloaded/patched archive untouched.
        with zipfile.ZipFile(destination, "x") as output:
            for entry in archive.infolist():
                data = replacements[entry.filename] if entry.filename in replacements else archive.read(entry)
                output.writestr(entry, data)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source")
    parser.add_argument("destination")
    arguments = parser.parse_args()
    patch_zip(arguments.source, arguments.destination)
    print("Created local web voxel fixes:", arguments.destination)
