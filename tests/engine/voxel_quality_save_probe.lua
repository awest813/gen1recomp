-- Opt-in against the downloaded mod: verify preset persistence on both hosts.
local root = assert(arg and arg[1], "pass extracted PotatoVoxel folder")
local web = true
package.loaded["src.core.Platform"] = { isWeb = function() return web end }
local settings = {}
local function setting(key)
  local s = { values = {} }
  function s:get() return self.value end
  function s:setValue(value, game)
    self.value = value
    if game then
      game.save.options[key] = value
      game.mods[key] = value
      if game.writeOptions then game:writeOptions() end
    end
  end
  settings[key] = s
  return s
end
local modules = {
  ModSetting = { new = function() return setting("render") end },
  ShadowSettings = { enabledSetting = setting("shadows"), qualitySetting = setting("shadowQuality") },
}
for name, key in pairs({ Water = "water", AntiAlias = "aa", WorldCurve = "curve",
                       VoxelGrid = "grid", OverworldBattle = "btl" }) do
  modules[name] = { setting = setting(key) }
end
local q = assert(loadfile(root .. "/lib/QualityMode.lua"))({ require = function(name) return assert(modules[name]) end })
for _, host in ipairs({ true, false }) do
  web = host
  for level = 1, 4 do
    local writes = 0
    local game = { save = { options = {} }, mods = {}, writeOptions = function() writes = writes + 1 end }
    q.applyMode(level, game)
    assert(writes == (web and 1 or 8), "preset save count")
    for key, value in pairs(q.PRESETS[level]) do
      assert(game.save.options[key] == value and game.mods[key] == value, "preset persisted " .. key)
    end
  end
end
q.applyMode(1, nil)
assert(q.matches(1), "HIGH matches its preset")
settings.render.value = 50
assert(not q.matches(1), "changing render scale breaks the preset match")
local chosen, writes = nil, 0
package.loaded["src.render.Pipelines"] = {
  setLevel = function(_, level) chosen = level end,
  syncOptions = function() end,
}
package.loaded["src.core.Game"] = { save = { options = {} }, writeOptions = function() writes = writes + 1 end }
q.enforce(1)
assert(chosen == 5 and writes == 1, "a changed quality knob selects and persists CUSTOM")
print("voxel quality save probe: web 1 save/preset; native 8; all values preserved")
