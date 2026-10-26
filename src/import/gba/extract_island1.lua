-- Staged Island 1 extract: tilesets → maps → collide → quantize → pack → mod.cache.
-- Outdoors (SeviiIslands123) + interiors (Network Center, Harbor, Houses) share
-- one 2bpp sheet; metatile ids are namespaced by tileset pair.

local Versions = require("src.import.gba.versions")
local Rom = require("src.import.gba.rom")
local Tileset = require("src.import.gba.tileset")
local Collision = require("src.core.game3.scripting.collision")
local Maps = require("src.import.gba.maps")

local Extract = {}

local CachePaths = require("src.core.game3.cache_paths")
setmetatable(Extract, {
  __index = function(t, k)
    if k == "CACHE_ROOT" then return CachePaths.CACHE_ROOT end
    if k == "NATIVE_ROOT" then return CachePaths.NATIVE_ROOT end
    return rawget(t, k)
  end,
  __newindex = function(t, k, v)
    if k == "CACHE_ROOT" then CachePaths.CACHE_ROOT = v
    elseif k == "NATIVE_ROOT" then CachePaths.NATIVE_ROOT = v
    else rawset(t, k, v)
    end
  end,
})
Extract.STAGE_COUNT = 7

local function progress(cb, stage, name, cur, total)
  if cb then cb(stage, Extract.STAGE_COUNT, name, cur or 0, total or 1) end
end

local function json_escape(s)
  return (tostring(s):gsub("\\", "\\\\"):gsub('"', '\\"'))
end

local function write_json(cache, rel, obj)
  local function enc(v)
    local t = type(v)
    if t == "nil" then return "null" end
    if t == "boolean" then return v and "true" or "false" end
    if t == "number" then return tostring(v) end
    if t == "string" then return '"' .. json_escape(v) .. '"' end
    if t == "table" then
      local isArray = #v > 0
      if isArray then
        local parts = {}
        for i = 1, #v do parts[i] = enc(v[i]) end
        return "[" .. table.concat(parts, ",") .. "]"
      end
      local keys = {}
      for k in pairs(v) do keys[#keys + 1] = k end
      table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
      local parts = {}
      for _, k in ipairs(keys) do
        parts[#parts + 1] = '"' .. json_escape(k) .. '":' .. enc(v[k])
      end
      return "{" .. table.concat(parts, ",") .. "}"
    end
    return "null"
  end
  return cache:write(rel, enc(obj) .. "\n")
end

--- Pad odd FRLG grids so 2×2 pack does not clip the last row/column.
-- Outdoors: extend edge tiles (ocean/cliff continues). Indoors: black void mid
-- so the duplicated right/bottom column does not stretch walls/stairs.
local function pad_even(grid)
  local w, h = grid.width, grid.height
  local nw = w + (w % 2)
  local nh = h + (h % 2)
  if nw == w and nh == h then return grid end
  local indoor = grid.environment == "INDOOR" or grid.kind == "indoor"
  local voidCell = { mid = 0, coll = 1, elev = 0 }
  local cells = {}
  local function at(x, y)
    if indoor and (x >= w or y >= h) then
      return voidCell
    end
    local sx = math.min(x, w - 1)
    local sy = math.min(y, h - 1)
    return grid.cells[sy * w + sx + 1]
  end
  for y = 0, nh - 1 do
    for x = 0, nw - 1 do
      local c = at(x, y)
      cells[#cells + 1] = { mid = c.mid, coll = c.coll, elev = c.elev }
    end
  end
  return {
    width = nw,
    height = nh,
    cells = cells,
    map_id = grid.map_id,
    kind = grid.kind,
    pair = grid.pair,
    environment = grid.environment,
    padded_from = { width = w, height = h },
  }
end

Extract.padEven = pad_even

local DYNAMIC_MIDS_BY_PAIR = {
  network = {
    0x2D0, 0x2D1, 0x2D8, 0x2D9, 0x2E3, 0x2E4, 0x2EB, 0x2EC,
    0x308, 0x309, 0x30A, 0x30B, 0x310, 0x311, 0x312, 0x313,
    0x314, 0x315, 0x316, 0x317, 0x31C, 0x31E,
  },
  pokemon_center = {
    0x2D0, 0x2D1, 0x2D8, 0x2D9, 0x2E3, 0x2E4, 0x2EB, 0x2EC,
    0x308, 0x309, 0x30A, 0x30B, 0x310, 0x311, 0x312, 0x313,
    0x314, 0x315, 0x316, 0x317, 0x31C, 0x31E,
  },
  dept_store = {
    0x28D, 0x2D0, 0x2D1, 0x2D8, 0x2D9, 0x2E3, 0x2E4, 0x2EB, 0x2EC,
    0x308, 0x309, 0x30A, 0x30B, 0x310, 0x311, 0x312, 0x313,
    0x314, 0x315, 0x316, 0x317, 0x31C, 0x31E,
  },
}

local function script_mids_by_pair(scriptBundle, grids)
  local NativePack = require("src.import.gba.native_pack")
  if not scriptBundle then return {} end
  return NativePack.scriptMidsByPair(scriptBundle.scripts, scriptBundle.events, function(mapId)
    local grid = grids[mapId]
    return grid and (grid.pair or "sevii_outdoor") or nil
  end)
end

local function unique_mids_by_pair(grids, scriptMids)
  local byPair = {}
  for _, grid in pairs(grids) do
    local pair = grid.pair or "sevii_outdoor"
    local seen = byPair[pair]
    if not seen then
      seen = {}
      byPair[pair] = seen
    end
    for _, cell in ipairs(grid.cells) do
      seen[cell.mid] = true
    end
  end
  for pair, mids in pairs(scriptMids or {}) do
    local seen = byPair[pair]
    if seen then
      for mid in pairs(mids) do seen[mid] = true end
    end
  end
  for pair, extraMids in pairs(DYNAMIC_MIDS_BY_PAIR) do
    local seen = byPair[pair]
    if seen then
      for _, mid in ipairs(extraMids) do
        seen[mid] = true
      end
    end
  end
  for pair, seen in pairs(byPair) do
    require("src.import.gba.native_pack").addDynamicMids(seen, pair)
  end
  local NativePack = require("src.import.gba.native_pack")
  local out = {}
  for pair, seen in pairs(byPair) do
    NativePack.addPcOnMids(seen)
    local list = {}
    for mid in pairs(seen) do list[#list + 1] = mid end
    table.sort(list)
    out[pair] = list
  end
  return out
end

function Extract.findImport(imports)
  local GameVersion = require("src.core.GameVersion")
  for _, id in ipairs(GameVersion.ORDER) do
    if GameVersion.generation(id) == 3 then
      local info = imports:info(id)
      if info then return id, info end
    end
  end
  return nil, nil
end

function Extract.cacheReady(cache)
  return cache and cache:exists(Extract.CACHE_ROOT .. "/meta.json")
    and Extract.nativeReady(cache)
end

function Extract.nativeReady(cache)
  if not cache then return false end
  local OwExtract = require("src.import.gba.ow_extract")
  local AnimPack = require("src.import.gba.tileset_anim_pack")
  if not cache:exists(Extract.NATIVE_ROOT .. "/manifest.lua") then return false end
  if not OwExtract.ready(cache, Extract.CACHE_ROOT) then return false end
  if not AnimPack.ready(cache, Extract.CACHE_ROOT) then return false end
  -- Dual-layer under/over atlases (NATIVE_VERSION >= 5).
  local src = cache:read(Extract.NATIVE_ROOT .. "/manifest.lua")
  if not src then return false end
  local chunk = load(src, "@native/manifest.lua", "t", {})
  local man = chunk and chunk()
  if not man or (tonumber(man.native_version) or 0) < (Versions.NATIVE_VERSION or 5) then
    return false
  end
  local checked = 0
  for pairName in pairs(man.pairs or {}) do
    if not cache:exists(Extract.NATIVE_ROOT .. "/" .. pairName .. "/mids_over.idx") then
      return false
    end
    checked = checked + 1
  end
  return checked > 0
end

function Extract.metaMd5Matches(cache, md5)
  local raw = cache:read(Extract.CACHE_ROOT .. "/meta.json")
  if not raw then return false end
  local want = Versions.identitySha1(md5) or Versions.normalizeMd5(md5)
  return want ~= nil and raw:find('"md5"%s*:%s*"' .. want .. '"', 1, false) ~= nil
end

function Extract.metaMatches(cache, md5)
  local raw = cache:read(Extract.CACHE_ROOT .. "/meta.json")
  if not raw then return false end
  local want = Versions.identitySha1(md5) or Versions.normalizeMd5(md5)
  return want ~= nil
    and raw:find('"md5"%s*:%s*"' .. want .. '"', 1, false) ~= nil
    and raw:find('"cache_version"%s*:%s*' .. tostring(Versions.CACHE_VERSION)) ~= nil
end

--- Patch meta.json cache_version / native_version in place (native-only migration).
local function bump_meta_version(cache)
  local raw = cache:read(Extract.CACHE_ROOT .. "/meta.json")
  if not raw then return end
  local updated = raw:gsub(
    '"cache_version"%s*:%s*%d+',
    '"cache_version":' .. tostring(Versions.CACHE_VERSION))
  if updated:find('"native_version"%s*:') then
    updated = updated:gsub(
      '"native_version"%s*:%s*%d+',
      '"native_version":' .. tostring(Versions.NATIVE_VERSION or 1))
  else
    updated = updated:gsub(
      '"cache_version"%s*:%s*%d+',
      '%0,"native_version":' .. tostring(Versions.NATIVE_VERSION or 1))
  end
  cache:write(Extract.CACHE_ROOT .. "/meta.json", updated)
end

--- Stable map pack order: outdoors first, then interiors.
-- Include Kanto starter + Pewter (Running Shoes / Brock) with Island 1.
local MAP_ORDER = {
  "SEVII_ONE_ISLAND",
  "SEVII_ONE_ISLAND_KINDLE_ROAD",
  "SEVII_ONE_ISLAND_TREASURE_BEACH",
  "SEVII_ONE_ISLAND_POKECENTER",
  "SEVII_ONE_ISLAND_POKECENTER_2F",
  "SEVII_ONE_ISLAND_HARBOR",
  "SEVII_ONE_ISLAND_HOUSE1",
  "SEVII_ONE_ISLAND_HOUSE2",
  "FR_PALLET_TOWN",
  "FR_ROUTE_1",
  "FR_VIRIDIAN_CITY",
  "FR_ROUTE_2",
  "FR_PLAYERS_HOUSE_1F",
  "FR_PLAYERS_HOUSE_2F",
  "FR_RIVALS_HOUSE",
  "FR_OAKS_LAB",
  "FR_PEWTER_CITY",
  "FR_PEWTER_CITY_GYM",
}

function Extract.run(imports, cache, progressCb, opts)
  local importId, info = Extract.findImport(imports)
  if not importId then
    return false, "no FireRed/LeafGreen optional import installed"
  end
  local version, verr = Versions.lookup(info.md5)
  if not version then return false, verr end

  if Extract.cacheReady(cache) and Extract.metaMd5Matches(cache, info.md5) then
    if Extract.metaMatches(cache, info.md5) and Extract.nativeReady(cache) then
      return true, { skipped = true, md5 = info.md5 }
    end
  end

  progress(progressCb, 0, "open_rom", 0, 1)
  local rom, rerr = Rom.open(imports, importId)
  if not rom then return false, rerr end

  -- Full gMapGroups census -> CacheFS. Seeds only affect pack order (front).
  local MapTree = require("src.import.gba.map_tree")
  local MapCatalog = require("src.import.gba.map_catalog")
  MapCatalog.rebuildIndex()
  local census = assert(MapTree.walk(rom, version))
  local mapOrder, byEngine = MapCatalog.allOrder(census, MAP_ORDER)
  MapCatalog.registerOrder(rom, version, mapOrder, byEngine)
  rom:clearCache()
  progress(progressCb, 0, "census", #mapOrder, #mapOrder)

  -- Collect which pairs registered maps need, load each once.
  local needed = {}
  for _, mapId in ipairs(mapOrder) do
    local spec = Versions.MAPS[mapId]
    needed[(spec and spec.pair) or "sevii_outdoor"] = true
  end
  local pairNames = {}
  for name in pairs(needed) do pairNames[#pairNames + 1] = name end
  table.sort(pairNames)

  progress(progressCb, 1, "tilesets", 0, #pairNames)
  local bundles = {}
  for i, pairName in ipairs(pairNames) do
    progress(progressCb, 1, "tilesets", i - 1, #pairNames)
    local okLoad, bundleOrErr = pcall(Tileset.loadPair, rom, version, pairName)
    if okLoad and bundleOrErr then
      bundles[pairName] = bundleOrErr
    else
      print("[extract] skip tileset pair " .. tostring(pairName) .. ": " .. tostring(bundleOrErr))
    end
  end
  rom:clearCache()

  progress(progressCb, 2, "maps", 0, 1)
  local Maps = require("src.import.gba.maps")
  local grids = {}
  local dropped = {}
  for _, mapId in ipairs(mapOrder) do
    local spec = Versions.MAPS[mapId]
    local layoutName = spec and spec.layout
    local layoutSpec = layoutName and version.layouts and version.layouts[layoutName]
    if layoutSpec and bundles[spec.pair] then
      local grid = Maps.loadGrid(rom, layoutSpec)
      grid.map_id = mapId
      grid.kind = spec.kind
      grid.pair = spec.pair
      grid.environment = spec.environment
      grids[mapId] = pad_even(grid)
    elseif spec then
      dropped[#dropped + 1] = mapId
      print("[extract] drop map " .. tostring(mapId) .. ": "
        .. (not layoutSpec and "missing layout spec" or "missing tileset pair "
           .. tostring(spec.pair)))
    end
  end
  if #dropped > 0 then
    return false, "dropped " .. #dropped .. " map(s): " .. table.concat(dropped, ",")
  end
  local borders = {}
  for _, mapId in ipairs(mapOrder) do
    if grids[mapId] then
      borders[mapId] = Maps.loadBorder(rom, version, mapId)
    end
  end
  require("src.import.gba.alt_layouts").build(rom, version, grids, borders, pad_even)
  local extractedScripts = require("src.import.gba.extract_scripts").extractFromRom(rom, version)
  local scriptMids = script_mids_by_pair(extractedScripts, grids)
  rom:clearCache()

  local midsByPair = unique_mids_by_pair(grids, scriptMids)
  local totalMids = 0
  for _, list in pairs(midsByPair) do totalMids = totalMids + #list end

  -- Build midIndex dictionary without 2bpp quantize
  local midIndex = {}
  for _, pairName in ipairs(pairNames) do
    midIndex[pairName] = {}
    local pairMids = midsByPair[pairName] or {}
    for _, mid in ipairs(pairMids) do
      local behavior = (Tileset.behaviorOf and Tileset.behaviorOf(bundles[pairName], mid)) or 0
      local coll = (Collision.fromCell and Collision.fromCell(mid, 0, behavior, "outdoor")) or 0
      midIndex[pairName][mid] = {
        tiles = { 0, 0, 0, 0 },
        coll = coll,
        behavior = behavior,
        category = "misc",
      }
    end
  end

  local miL = { "return {\n" }
  for _, pairName in ipairs(pairNames) do
    miL[#miL + 1] = ("  [%q] = {\n"):format(pairName)
    for _, mid in ipairs(midsByPair[pairName] or {}) do
      local info2 = midIndex[pairName][mid]
      miL[#miL + 1] = ("    [%d] = { tiles = {%s}, coll = %d, behavior = %d, category = %q },\n"):format(
        mid,
        table.concat(info2.tiles, ","),
        info2.coll,
        info2.behavior,
        info2.category
      )
    end
    miL[#miL + 1] = "  },\n"
  end
  miL[#miL + 1] = "}\n"
  cache:write(Extract.CACHE_ROOT .. "/mid_index.lua", table.concat(miL))

  write_json(cache, Extract.CACHE_ROOT .. "/meta.json", {
    cache_version = Versions.CACHE_VERSION,
    native_version = Versions.NATIVE_VERSION or 5,
    md5 = Versions.normalizeMd5(info.md5),
    version_id = version.id,
    import_id = importId,
    mid_count = totalMids,
    tile_count = 0,
    block_count = 0,
    imageWidth = 0,
    imageHeight = 0,
    tilesPerRow = 16,
    maps = mapOrder,
  })

  local warps = Versions.WARPS
  local connections = {}
  do
    local ExtractMapEvents = require("src.import.gba.extract_map_events")
    local romW = assert(Rom.open(imports, importId))
    local romWarps, romConns = ExtractMapEvents.extractWarpsAndConnections(romW, version)
    romW:clearCache()
    warps = {}
    for _, mapId in ipairs(mapOrder) do
      local list = romWarps[mapId]
      if list and #list > 0 then
        for _, w in ipairs(list) do
          if not w.destMap and w.mapGroup ~= nil then
            w.destMap = MapCatalog.mapIdFor(w.mapGroup, w.mapNum)
          end
        end
        warps[mapId] = list
      else
        warps[mapId] = Versions.WARPS[mapId] or {}
      end
    end
    connections = {}
    for _, mapId in ipairs(mapOrder) do
      local conns = romConns[mapId] or {}
      local fixed = {}
      for _, c in ipairs(conns) do
        local dest = c.map
        if (not dest or dest:match("^g%d+_m%d+$")) and c.mapGroup ~= nil then
          dest = MapCatalog.mapIdFor(c.mapGroup, c.mapNum) or dest
        elseif dest then
          dest = MapCatalog.resolve(dest) or dest
        end
        if dest then
          fixed[#fixed + 1] = { dir = c.dir, map = dest, offset = tonumber(c.offset) or 0 }
        end
      end
      connections[mapId] = fixed
    end
  end

  -- Native FRLG mid atlas + pret palettes (game3 live path).
  progress(progressCb, 6, "native_pack", 0, 1)
  local NativePack = require("src.import.gba.native_pack")
  local warpCells = {}
  for mapId, list in pairs(warps or {}) do
    local set = {}
    for _, w in ipairs(list) do
      local x, y = tonumber(w.x), tonumber(w.y)
      if x and y then set[NativePack.warpKey(x, y)] = true end
    end
    warpCells[mapId] = set
  end
  NativePack.writeExtract(
    cache, Extract.CACHE_ROOT, bundles, grids, borders, pairNames, midIndex,
    Tileset.behaviorOf, Collision.fromCell, scriptMids, warpCells)

  -- OW sprites + tileset anims + encounters + audio + chrome from ROM
  do
    local rom2 = assert(Rom.open(imports, importId))
    if not (opts and opts.skipScriptsAndOw) then
      require("src.import.gba.help_extract").writeExtract(rom2, cache)
      require("src.import.gba.quest_log_extract").writeExtract(rom2, cache)
      require("src.import.gba.object_interactions_extract").writeExtract(rom2, cache, Extract.CACHE_ROOT, version)
    end
    local midLists = {}
    for _, pairName in ipairs(pairNames) do
      midLists[pairName] = NativePack.collectMidsForPair(grids, borders, pairName, scriptMids)
    end
    local AnimPack = require("src.import.gba.tileset_anim_pack")
    AnimPack.writeExtract(rom2, cache, Extract.CACHE_ROOT, bundles, midLists, version)
    if not (opts and opts.skipScriptsAndOw) then
      local OwExtract = require("src.import.gba.ow_extract")
      OwExtract.writeExtract(rom2, cache, Extract.CACHE_ROOT, version)
      local EncExtract = require("src.import.gba.encounters_extract")
      EncExtract.writeExtract(rom2, cache, Extract.CACHE_ROOT, version)
      local FxExtract = require("src.import.gba.field_effect_extract")
      FxExtract.writeExtract(rom2, cache, Extract.CACHE_ROOT, version)
      do
        local MartsExtract = require("src.import.gba.marts_extract")
        local okM, detailM = pcall(MartsExtract.run, rom2, cache, {
          cacheRoot = Extract.CACHE_ROOT,
        })
        if okM and detailM then
          print(string.format("[marts] %d lists → %s",
            detailM.listCount or 0, tostring(detailM.path)))
        end
      end
      for _, name in ipairs({ "online_ui_extract", "berry_crush_extract", "dodrio_extract", "pokemon_jump_extract" }) do
        require("src.import.gba." .. name).run(rom2, cache, { cacheRoot = Extract.CACHE_ROOT })
      end
    end
    rom2:clearCache()
  end

  local wl = { "return {\n" }
  for _, mapId in ipairs(mapOrder) do
    local list = warps[mapId] or {}
    wl[#wl + 1] = ("  %s = {\n"):format(mapId)
    for _, w in ipairs(list) do
      local dest = w.destMap or MapCatalog.mapIdFor(w.mapGroup, w.mapNum)
      if dest then
        wl[#wl + 1] = ("    { x = %d, y = %d, destMap = %q, destWarp = %d },\n"):format(
          w.x, w.y, dest, w.destWarp or 1
        )
      else
        wl[#wl + 1] = ("    { x = %d, y = %d, destMap = nil, destWarp = %d, mapGroup = %d, mapNum = %d },\n"):format(
          w.x, w.y, w.destWarp or 1, w.mapGroup or 0, w.mapNum or 0
        )
      end
    end
    wl[#wl + 1] = "  },\n"
  end
  wl[#wl + 1] = "}\n"
  cache:write(Extract.CACHE_ROOT .. "/warps.lua", table.concat(wl))

  local cl = { "return {\n" }
  for _, mapId in ipairs(mapOrder) do
    local conns = connections[mapId] or {}
    cl[#cl + 1] = ("  %s = {\n"):format(mapId)
    for _, c in ipairs(conns) do
      cl[#cl + 1] = ("    { dir = %q, map = %q, offset = %d },\n"):format(
        c.dir, c.map, tonumber(c.offset) or 0)
    end
    cl[#cl + 1] = "  },\n"
  end
  cl[#cl + 1] = "}\n"
  cache:write(Extract.CACHE_ROOT .. "/connections.lua", table.concat(cl))

  local scriptBundle = nil
  if not (opts and opts.skipScriptsAndOw) then
    -- game3 scripts/events/text/movements from ROM MapEvents + BFS
    local ExtractScripts = require("src.import.gba.extract_scripts")
    rom = assert(Rom.open(imports, importId))
    scriptBundle = ExtractScripts.writeBundleFromRom(
      rom, cache, Extract.CACHE_ROOT, version, extractedScripts)

    -- Extract full trainer parties, AI flags, dialogs, and sprites
    do
      local TrainerExtract = require("src.import.gba.trainer_extract")
      TrainerExtract.run(rom, cache, {
        cacheRoot = Extract.CACHE_ROOT,
        scripts = scriptBundle and scriptBundle.scripts,
        text = scriptBundle and scriptBundle.text,
      })
    end

    -- Normalized map_tree mirror
    do
      local MapTreeExtract = require("src.import.gba.map_tree_extract")
      local okTree, treeDetail = MapTreeExtract.run(rom, cache, {
        version = version,
        root = Extract.CACHE_ROOT .. "/map_tree",
      })
      if not okTree then
        print("[extract] map_tree warn: " .. tostring(treeDetail))
      end
    end
    rom:clearCache()
  end

  progress(progressCb, 7, "done", 1, 1)
  bundles = nil
  collectgarbage()
  return true, {
    md5 = info.md5,
    tile_count = 0,
    block_count = 0,
    mid_count = totalMids,
    map_count = #mapOrder,
    script_count = scriptBundle and scriptBundle.scriptCount,
    script_seeds = scriptBundle and scriptBundle.seedCount,
  }
end

function Extract.runNativeOnly(imports, cache, progressCb)
  return Extract.run(imports, cache, progressCb)
end

function Extract.runScriptsAndOw(imports, cache, progressCb)
  local importId, info = Extract.findImport(imports)
  if not importId then
    return false, "no FireRed/LeafGreen optional import installed"
  end
  local version, verr = Versions.lookup(info.md5)
  if not version then return false, verr end

  local rom = assert(Rom.open(imports, importId))

  if progressCb then progressCb(1, 4, "help_quest_log", 0, 1) end
  require("src.import.gba.help_extract").writeExtract(rom, cache)
  require("src.import.gba.quest_log_extract").writeExtract(rom, cache)
  require("src.import.gba.object_interactions_extract").writeExtract(rom, cache, Extract.CACHE_ROOT, version)

  if progressCb then progressCb(2, 4, "ow_sprites", 0, 1) end
  local OwExtract = require("src.import.gba.ow_extract")
  OwExtract.writeExtract(rom, cache, Extract.CACHE_ROOT, version)
  local EncExtract = require("src.import.gba.encounters_extract")
  EncExtract.writeExtract(rom, cache, Extract.CACHE_ROOT, version)
  local FxExtract = require("src.import.gba.field_effect_extract")
  FxExtract.writeExtract(rom, cache, Extract.CACHE_ROOT, version)

  if progressCb then progressCb(3, 4, "scripts_events", 0, 1) end
  local ExtractScripts = require("src.import.gba.extract_scripts")
  local scriptBundle = ExtractScripts.writeBundleFromRom(rom, cache, Extract.CACHE_ROOT, version)

  if progressCb then progressCb(4, 4, "trainers_map_tree", 0, 1) end
  local TrainerExtract = require("src.import.gba.trainer_extract")
  TrainerExtract.run(rom, cache, {
    cacheRoot = Extract.CACHE_ROOT,
    scripts = scriptBundle and scriptBundle.scripts,
    text = scriptBundle and scriptBundle.text,
  })

  local MapTreeExtract = require("src.import.gba.map_tree_extract")
  local okTree, treeDetail = MapTreeExtract.run(rom, cache, {
    version = version,
    root = Extract.CACHE_ROOT .. "/map_tree",
  })
  if not okTree then
    print("[extract] map_tree warn: " .. tostring(treeDetail))
  end

  do
    local MartsExtract = require("src.import.gba.marts_extract")
    local okM, detailM = pcall(MartsExtract.run, rom, cache, {
      cacheRoot = Extract.CACHE_ROOT,
    })
    if okM and detailM then
      print(string.format("[marts] %d lists → %s",
        detailM.listCount or 0, tostring(detailM.path)))
    end
  end

  for _, name in ipairs({ "online_ui_extract", "berry_crush_extract", "dodrio_extract", "pokemon_jump_extract" }) do
    require("src.import.gba." .. name).run(rom, cache, { cacheRoot = Extract.CACHE_ROOT })
  end

  rom:clearCache()
  return true
end

--- Rebuild native blobs only (demake cache already valid). Seconds, not minutes.
-- Uses full gMapGroups census → CacheFS (same pair set as Extract.run).
function Extract.runNativeOnly(imports, cache, progressCb)
  local importId, info = Extract.findImport(imports)
  if not importId then
    return false, "no FireRed/LeafGreen optional import installed"
  end
  local version, verr = Versions.lookup(info.md5)
  if not version then return false, verr end
  if not Extract.cacheReady(cache) or not Extract.metaMd5Matches(cache, info.md5) then
    return false, "demake cache missing — run full extract first"
  end

  progress(progressCb, 0, "open_rom", 0, 1)
  local rom, rerr = Rom.open(imports, importId)
  if not rom then return false, rerr end

  local MapTree = require("src.import.gba.map_tree")
  local MapCatalog = require("src.import.gba.map_catalog")
  MapCatalog.rebuildIndex()
  local census = assert(MapTree.walk(rom, version))
  local mapOrder, byEngine = MapCatalog.allOrder(census, MAP_ORDER)
  MapCatalog.registerOrder(rom, version, mapOrder, byEngine)
  rom:clearCache()

  local needed = {}
  for _, mapId in ipairs(mapOrder) do
    local spec = Versions.MAPS[mapId]
    needed[(spec and spec.pair) or "sevii_outdoor"] = true
  end
  local pairNames = {}
  for name in pairs(needed) do pairNames[#pairNames + 1] = name end
  table.sort(pairNames)

  progress(progressCb, 1, "tilesets", 0, #pairNames)
  local bundles = {}
  for i, pairName in ipairs(pairNames) do
    progress(progressCb, 1, "tilesets", i - 1, #pairNames)
    local okLoad, bundleOrErr = pcall(Tileset.loadPair, rom, version, pairName)
    if okLoad and bundleOrErr then
      bundles[pairName] = bundleOrErr
    else
      print("[extract] skip tileset pair " .. tostring(pairName) .. ": " .. tostring(bundleOrErr))
    end
  end
  rom:clearCache()

  progress(progressCb, 2, "maps", 0, 1)
  local grids = {}
  do
    for _, mapId in ipairs(mapOrder) do
      local spec = Versions.MAPS[mapId]
      local layoutName = spec and spec.layout
      local layoutSpec = layoutName and version.layouts and version.layouts[layoutName]
      if layoutSpec and bundles[spec.pair] then
        local grid = Maps.loadGrid(rom, layoutSpec)
        grid.map_id = mapId
        grid.kind = spec.kind
        grid.pair = spec.pair
        grid.environment = spec.environment
        grids[mapId] = pad_even(grid)
      end
    end
  end
  local borders = {}
  for _, mapId in ipairs(mapOrder) do
    if grids[mapId] then
      borders[mapId] = Maps.loadBorder(rom, version, mapId)
    end
  end
  require("src.import.gba.alt_layouts").build(rom, version, grids, borders, pad_even)
  local scriptMids = script_mids_by_pair(
    require("src.import.gba.extract_scripts").extractFromRom(rom, version), grids)
  rom:clearCache()

  local midIndex = {}
  do
    local src = cache:read(Extract.CACHE_ROOT .. "/mid_index.lua")
    if src then
      local chunk = load(src, "@mid_index.lua", "t", {})
      if chunk then midIndex = chunk() or {} end
    end
  end

  progress(progressCb, 6, "native_pack", 0, 1)
  local NativePack = require("src.import.gba.native_pack")
  NativePack.writeExtract(
    cache, Extract.CACHE_ROOT, bundles, grids, borders, pairNames, midIndex,
    Tileset.behaviorOf, Collision.fromCell, scriptMids)

  do
    local rom2 = assert(Rom.open(imports, importId))
    require("src.import.gba.help_extract").writeExtract(rom2, cache)
    require("src.import.gba.quest_log_extract").writeExtract(rom2, cache)
    require("src.import.gba.object_interactions_extract").writeExtract(rom2, cache, Extract.CACHE_ROOT, version)
    local midLists = {}
    for _, pairName in ipairs(pairNames) do
      midLists[pairName] = NativePack.collectMidsForPair(grids, borders, pairName, scriptMids)
    end
    local AnimPack = require("src.import.gba.tileset_anim_pack")
    AnimPack.writeExtract(rom2, cache, Extract.CACHE_ROOT, bundles, midLists, version)
    local OwExtract = require("src.import.gba.ow_extract")
    OwExtract.writeExtract(rom2, cache, Extract.CACHE_ROOT, version)
    local EncExtract = require("src.import.gba.encounters_extract")
    EncExtract.writeExtract(rom2, cache, Extract.CACHE_ROOT, version)
    local FxExtract = require("src.import.gba.field_effect_extract")
    FxExtract.writeExtract(rom2, cache, Extract.CACHE_ROOT, version)
    rom2:clearCache()
  end
  bump_meta_version(cache)

  progress(progressCb, 7, "done", 1, 1)
  bundles = nil
  collectgarbage()
  return true, { native_only = true, md5 = info.md5, pairs = #pairNames, maps = #mapOrder }
end

return Extract
