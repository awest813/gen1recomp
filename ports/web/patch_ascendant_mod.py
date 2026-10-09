"""Create a complete Voxel Ascendant 3.0.62 ZIP with capped web battle presentation.

Usage: python ports/web/patch_ascendant_mod.py ORIGINAL.zip PATCHED.zip
Gameplay and covered preparation keep their existing update cadence.
"""
import argparse
import json
from pathlib import Path
import zipfile

ANCHOR = b'  BattleCam.steerable = not OverworldBattle.playerBackPinned(session.battle)'
REPLACEMENT = b'''  -- Browser updates continue between capped presents. Reuse the committed
  -- shot instead of recapturing textures/rendering an invisible battle frame.
  -- Retirement and covered preparation above still run on every update.
  local webDue, webDt = V.require("WebBattlePresentation").step(session, dt)
  if not webDue then return end
  dt = webDt
''' + ANCHOR

HELPER = b'''-- Presentation-only cadence; never called by battle simulation.
local P = {}
function P.step(session, dt)
  local web = love and love.system and love.system.getOS
    and love.system.getOS() == "Web"
  if not web then return true, dt end
  local cap = require("src.core.FrameCap").current
  local now = love.timer.getTime()
  local state = session._webBattlePresentation
  if not state then
    state = { pacer = require("src.core.WebFramePacer").new(), elapsed = 0 }
    session._webBattlePresentation = state
  end
  state.elapsed = state.elapsed + dt
  local battle = session.battle
  local player = battle and battle.player
  local enemy = battle and battle.enemy
  -- A replacement battler must never display the preceding battler's shot.
  local playerMon, enemyMon = player and player.mon, enemy and enemy.mon
  local changed = state.player ~= player or state.enemy ~= enemy
    or state.playerMon ~= playerMon or state.enemyMon ~= enemyMon
  state.player, state.enemy = player, enemy
  state.playerMon, state.enemyMon = playerMon, enemyMon
  if changed or session.presentationCommitted ~= true or not session.shot then
    state.pacer.deadline = nil
  end
  if not state.pacer:due(now, cap) then return false end
  local elapsed = state.elapsed
  state.elapsed = 0
  return true, elapsed
end
return P
'''


def patch_zip(source, destination):
    source, destination = Path(source), Path(destination)
    if source.resolve() == destination.resolve():
        raise ValueError("Choose a separate output ZIP; keep the original")
    with zipfile.ZipFile(source) as archive:
        manifest = json.loads(archive.read("manifest.json"))
        if (manifest.get("id"), manifest.get("version")) != ("VOXEL_ASCENDANT", "3.0.62"):
            raise ValueError("This patch only supports Voxel Ascendant 3.0.62")
        path = "lib/OverworldBattle.lua"
        original = archive.read(path)
        normalized = original.replace(b"\r\n", b"\n")
        if normalized.count(ANCHOR) != 1 or "lib/WebBattlePresentation.lua" in archive.namelist():
            raise ValueError("OverworldBattle has changed or already has this patch")
        replacement = normalized.replace(ANCHOR, REPLACEMENT)
        if b"\r\n" in original:
            replacement = replacement.replace(b"\n", b"\r\n")
        with zipfile.ZipFile(destination, "x") as output:
            for entry in archive.infolist():
                output.writestr(entry, replacement if entry.filename == path else archive.read(entry))
            output.writestr("lib/WebBattlePresentation.lua", HELPER,
                            compress_type=zipfile.ZIP_DEFLATED)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source")
    parser.add_argument("destination")
    arguments = parser.parse_args()
    patch_zip(arguments.source, arguments.destination)
    print("Created local Ascendant web presentation fix:", arguments.destination)
