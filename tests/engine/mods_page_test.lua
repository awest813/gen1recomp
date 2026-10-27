-- The PK:GB launcher's mod and cart pages (src/launcher/ModsPage.lua,
-- src/launcher/CartsPage.lua), headless.  No pokered cite: port-only chrome.
--
-- Pins what a player relies on: mod updates are found, downloaded and
-- installed without blocking a frame, Update all reports back to main.lua's
-- shortcut boot, the catalog lists and installs from the indexes the player
-- added, safe mode and all on / off write the options the loader reads,
-- options, load order and profiles round-trip, a cart can be saved, shared,
-- filled with its pinned mods (hash checked) and unsealed, and every page
-- fits a phone and a desktop window.
--   luajit tests/engine/mods_page_test.lua

package.path = "./?.lua;./?/init.lua;" .. package.path
love = love or require("tests.love_stub")
love.graphics.setLineJoin = love.graphics.setLineJoin or function() end
love.graphics.newShader = love.graphics.newShader or function() return {} end

local T = require("tests.harness")
local check, eq = T.check, T.eq

-- ----------------------------------------------------------------- seams
-- Options live in memory; the pure SaveData helpers stay real.
local SaveData = require("src.core.SaveData")
local opts = {}
local writes = 0
SaveData.loadOptions = function() return opts end
SaveData.saveOptions = function(o) opts = o; writes = writes + 1 return true end
local activeSlots, sealBroken = { gold = "slot1" }, {}
SaveData.listSlots = function(version)
  if version ~= "gold" then return {} end
  return { { id = "slot1", exists = true, name = "GOLD" }, { id = "slot2", exists = true, name = "KRIS" } }
end
SaveData.activeSlot = function(version) return activeSlots[version] end
SaveData.setActiveSlot = function(version, id) activeSlots[version] = id return true end
SaveData.listCartSlots = function() return { { id = "c1", exists = true, name = "HARD" } } end
SaveData.activeCartSlot = function() return "c1" end
SaveData.setActiveCartSlot = function() return true end
SaveData.slotSealBroken = function(cart, slot) return sealBroken[cart .. ":" .. slot] == true end
SaveData.markSlotSealBroken = function(cart, slot) sealBroken[cart .. ":" .. slot] = true return true end

package.loaded["src.import.CacheContract"] = setmetatable({
  isReady = function(version) return version == "gold" end,
  isImported = function(version) return version == "gold" end,
}, { __index = require("src.import.CacheContract") })

local Platform = require("src.core.Platform")
local online = true
Platform.canFetchRemote = function() return online end
Platform.isWeb = function() return false end

-- Installed mods: two with a GitHub repo, one without, one with options.
local installed = {
  cool = { id = "cool", name = "Cool Mod", version = "1.0.0", github = "someone/cool" },
  fancy = { id = "fancy", name = "Fancy Mod", version = "2.0.0", github = "someone/fancy",
    options_schema = "options.lua" },
  plain = { id = "plain", name = "Plain Mod", version = "0.1.0" },
}
local zips = {}
local ModLibrary = {
  list = function(version)
    local rows = {}
    local ids = {}
    for id in pairs(installed) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
      local m = installed[id]
      if m then
        local row = { id = id, name = m.name, version = m.version, folder = "mods/" .. id,
          manifest = m, supported = true }
        if version then
          local on = SaveData.modEnabled(opts, id, SaveData.modScope(version))
          row.enabled = on == nil or on
        end
        rows[#rows + 1] = row
      end
    end
    return rows
  end,
  setEnabled = function(id, on, version)
    SaveData.setModEnabled(opts, id, on, SaveData.modScope(version))
    return true
  end,
  installZip = function(bytes, name, o)
    zips[#zips + 1] = { bytes = bytes, name = name, opts = o }
    local id, version = bytes:match("^ZIP:([%w_]+):([%d%.]+)$")
    if not id then return nil, "that is not a .zip file" end
    installed[id] = installed[id] or { id = id, name = id }
    installed[id].version = version
    return { id = id, version = version, name = installed[id].name }
  end,
  missingDependencies = function() return {} end,
  modOptions = function() return opts.modOptions or {} end,
  setModOptions = function(id, values)
    opts.modOptions = opts.modOptions or {}
    opts.modOptions[id] = values
    return true
  end,
  uninstall = function() return true end,
}
package.loaded["src.mods.ModLibrary"] = ModLibrary

-- GitHub releases and downloads: answered after a pump, never inline.
local ModUpdate = require("src.mods.ModUpdate")
local releases = {
  ["someone/cool"] = { { version = "1.2.0", zip = { url = "https://dl/cool-1.2.0.zip", size = 3 } } },
  ["someone/fancy"] = { { version = "2.0.0", zip = { url = "https://dl/fancy-2.0.0.zip" } } },
  ["pins/base"] = { { version = "3.0.0", zip = { url = "https://dl/base-3.0.0.zip" } },
                    { version = "2.5.0", zip = { url = "https://dl/base-2.5.0.zip" } } },
}
local served = {
  ["https://dl/cool-1.2.0.zip"] = "ZIP:cool:1.2.0",
  ["https://dl/base-2.5.0.zip"] = "ZIP:base:2.5.0",
  ["https://dl/new-1.0.0.zip"] = "ZIP:newmod:1.0.0",
  ["https://dl/hard.g1rcart"] = "CART:hard2",
}
local fetches, downloads = 0, {}
ModUpdate.beginFetchReleases = function(repo) fetches = fetches + 1 return { repo = repo, pumps = 0 } end
ModUpdate.pumpFetchReleases = function(h)
  h.pumps = h.pumps + 1
  if h.pumps < 2 then return false end
  if not online then return true, nil, "offline" end
  return true, releases[h.repo] or {}, nil, {}
end
ModUpdate.beginDownloadZip = function(url, name)
  downloads[#downloads + 1] = url
  return { url = url, name = name, pumps = 0, stage = "fetching" }
end
ModUpdate.pumpDownloadZip = function(h)
  h.pumps = h.pumps + 1
  if h.pumps < 3 then return false, nil, nil, h.pumps / 3 end
  local body = served[h.url]
  if not body then return true, nil, "404" end
  love.filesystem.write(h.name, body)
  return true, h.name
end

-- sha256 for the pinned-mod check
love.data = love.data or {}
love.data.hash = function(_, bytes) return ("%064x"):format(#bytes) end

local realLoader = require("src.mods.Loader")
local Launcher = require("src.launcher.Launcher")
local ModsPage = require("src.launcher.ModsPage")
local Kit = require("src.ui.kit.Kit")

local function window(w, h)
  love.graphics.getDimensions = function() return w, h end
  love.graphics.getPixelDimensions = function() return w, h end
end

local function fresh()
  local l = Launcher.new(function() end, { noUpdateCheck = true })
  l.selected = "gold"
  return l
end

local function pump(l, n)
  for _ = 1, n or 12 do l:update(0) end
end

local realPrint = love.graphics.print
local function drawText(l)
  local seen = {}
  love.graphics.print = function(str, ...)
    seen[#seen + 1] = tostring(str)
    return realPrint(str, ...)
  end
  local ok, err = pcall(l.draw, l)
  love.graphics.print = realPrint
  check(ok, "the launcher draws " .. tostring(l.page) .. ": " .. tostring(err))
  return table.concat(seen, "\n")
end

-- --------------------------------------------------------------- updates
window(1280, 720)
local l = fresh()
l.page = "mods"
local mt = drawText(l)
check(mt:find("Check for updates", 1, true) and mt:find("Get mods", 1, true),
  "the Mods page offers to check for updates and to get mods")
l:modsUi():checkUpdates(true)
eq(fetches, 2, "only mods that name a GitHub repo are checked")
check(l:modsUi():checking(), "the check runs in the background")
pump(l, 3)
check(not l:modsUi():checking(), "and finishes over a few frames")
eq(l:modsUi().releases.cool.status, "available", "a newer release is an available update")
eq(l:modsUi().releases.fancy.status, "current", "the same version is up to date")
mt = drawText(l)
check(mt:find("Update available: v1.2.0", 1, true), "the row says an update is out")
check(mt:find("Update all (1)", 1, true), "and Update all counts it")
local cool
for _, row in ipairs(l:modsFor("gold")) do if row.id == "cool" then cool = row end end
l:modsUi():updateMod(cool)
pump(l, 1)
check(l:modsUi():jobLine():find("Updating Cool Mod", 1, true), "a running update says what it does")
pump(l, 6)
eq(zips[#zips].bytes, "ZIP:cool:1.2.0", "the downloaded package is installed")
check(zips[#zips].opts.upgrade, "as an upgrade")
eq(installed.cool.version, "1.2.0", "the mod is now the new version")
check(l.message and l.message.text:find("Updated Cool Mod v1.2.0", 1, true), "and the player is told")
eq(love.filesystem.read("launcher_download_cool.part"), nil, "the download is cleaned up")

-- Update all, as main.lua calls it before a shortcut boot
installed.cool.version = "1.0.0"
local result
l = fresh()
check(l:autoUpdateAll(function(r) result = r end, { tab = "mods" }) == true, "auto update starts")
eq(l.page, "mods", "and shows the Mods page")
eq(result, nil, "the boot waits while mods update")
pump(l, 20)
check(result and result.ok and result.updated == 1 and result.total == 1,
  "done reports one mod updated: " .. tostring(result and result.updated))
eq(installed.cool.version, "1.2.0", "the outdated mod was updated")
result = nil
l:autoUpdateAll(function(r) result = r end)
pump(l, 20)
check(result and result.ok and result.total == 0, "a second run has nothing to do")

-- a failed download fails the run, so the launcher stays up with the reason
installed.cool.version = "1.0.0"
releases["someone/cool"][1].zip.url = "https://dl/missing.zip"
l = fresh()
l:modsUi().releases = {}
result = nil
l:autoUpdateAll(function(r) result = r end)
pump(l, 20)
check(result and not result.ok and #result.failures == 1, "a failed update is reported")
check(l.message.kind == "error" and l.message.text:find("404", 1, true), "with why")
releases["someone/cool"][1].zip.url = "https://dl/cool-1.2.0.zip"

-- Stop
l = fresh()
result = nil
l:autoUpdateAll(function(r) result = r end)
l:modsUi():stop()
check(result and result.cancelled, "Stop ends the run as cancelled")

-- offline and safe mode answer at once
online = false
result = nil
fresh():autoUpdateAll(function(r) result = r end)
check(result and result.skipped, "offline, the update is skipped and the boot goes ahead")
online = true
opts.safeMode = true
result = nil
fresh():autoUpdateAll(function(r) result = r end)
check(result and result.skipped, "in safe mode mods are not updated")
opts.safeMode = nil

-- ------------------------------------------------------------- safe mode
l = fresh()
l.page = "modtools"
check(drawText(l):find("Safe mode", 1, true), "Tools offers safe mode")
l:modsUi():setSafeMode(true)
eq(SaveData.isSafeMode(opts), true, "safe mode is written where the loader reads it")
l.page = "mods"
check(drawText(l):find("Safe mode is on", 1, true), "and the Mods page says so while it is on")
l:modsUi():setSafeMode(false)
check(not drawText(l):find("Safe mode is on", 1, true), "and stops saying so")

l:modsUi():setAll("gold", false)
eq(SaveData.modEnabled(opts, "cool", "gold"), false, "all off turns every mod off for this game")
eq(SaveData.modEnabled(opts, "cool", "red"), nil, "and leaves other games alone")
l:modsUi():setAll("gold", true)
eq(SaveData.modEnabled(opts, "plain", "gold"), true, "all on turns them back on")

-- --------------------------------------------------------------- options
l = fresh()
local fancy
for _, row in ipairs(l:modsFor("gold")) do if row.id == "fancy" then fancy = row end end
l:modsUi().schemas = { ["mods/fancy"] = {
  { key = "speed", type = "number", label = "Speed", default = 2, min = 1, max = 4 },
  { key = "hard", type = "toggle", label = "Hard mode", default = false },
  { key = "style", type = "choice", label = "Style", default = "a", choices = { { "Alpha", "a" }, { "Beta", "b" } } },
  { key = "secret", type = "text", label = "Secret", visible_if = { key = "hard", equals = true } },
} }
l:modsUi().detailFolder, l.page = "mods/fancy", "mod"
check(drawText(l):find("Options", 1, true), "a mod with options offers them")
l.page = "modoptions"
local ot = drawText(l)
check(ot:find("Speed", 1, true) and ot:find("Alpha", 1, true), "the options page shows the schema")
check(not ot:find("Secret", 1, true), "a hidden option stays hidden")
l:modsUi():setOption("fancy", "hard", true)
check(drawText(l):find("Secret", 1, true), "until what it depends on is set")
l:modsUi():setOption("fancy", "speed", 4)
eq(opts.modOptions.fancy.speed, 4, "an option is saved for the mod")
eq(opts.modOptions.fancy.hard, true, "beside the others")
l:modsUi():resetOptions(fancy)
eq(opts.modOptions.fancy.speed, 2, "reset puts back the defaults")
eq(opts.modOptions.fancy.hard, false, "every one of them")

-- ------------------------------------------------------------ load order
l = fresh()
local order = l:modsUi():orderList("gold")
eq(table.concat(order, ","), "cool,fancy,plain", "the order starts by priority and id")
l:modsUi():moveOrder("gold", "plain", -1)
eq(table.concat(opts.modOrder, ","), "cool,plain,fancy", "a mod moves up")
l.page = "loadorder"
check(drawText(l):find("2.  Plain Mod", 1, true), "the page shows the new order")
l:modsUi():resetOrder()
eq(#opts.modOrder, 0, "reset clears the custom order")

-- -------------------------------------------------------------- profiles
l = fresh()
l:modsUi():setAll("gold", true)
l:modsUi():saveProfile("gold", "All on")
eq(opts.modProfiles[1].name, "All on", "the setup is saved as a profile")
eq(opts.activeProfile, "All on", "and marked in use")
l:modsUi():setAll("gold", false)
l:modsUi():saveProfile("gold", "Quiet")
l:modsUi():applyProfile("gold", "All on")
eq(SaveData.modEnabled(opts, "cool", "gold"), true, "applying a profile restores its mods")
eq(opts.activeProfile, "All on", "and marks it in use")
l:modsUi():renameProfile("Quiet", "Silent")
eq(opts.modProfiles[2].name, "Silent", "a profile can be renamed")
l:modsUi():renameProfile("Silent", "All on")
eq(opts.modProfiles[2].name, "Silent", "but not onto another's name")
l:modsUi():deleteProfile("Silent")
eq(#opts.modProfiles, 2, "the first Delete only arms")
l:modsUi():deleteProfile("Silent")
eq(#opts.modProfiles, 1, "the second deletes")
l.page = "profiles"
check(drawText(l):find("All on", 1, true), "the profiles page lists them")

-- ------------------------------------------------------ required imports
local removedFile
package.loaded["src.mods.RequiredImports"] = {
  specs = function(m) return m.required_imports or {} end,
  inspect = function(m)
    local rows = {}
    for _, spec in ipairs(m.required_imports or {}) do
      rows[#rows + 1] = { id = spec.id, name = spec.name, required = true, spec = spec,
        present = removedFile == nil }
    end
    return rows
  end,
  remove = function(_, id) removedFile = id return true end,
}
installed.plain.required_imports = { { id = "rom", name = "Stadium ROM" } }
l = fresh()
l:modsUi().detailFolder, l.page = "mods/plain", "mod"
check(drawText(l):find("Remove file", 1, true), "a stored file can be removed")
local plainRow = l:modsUi():rowByFolder("gold", "mods/plain")
local fileRow = package.loaded["src.mods.RequiredImports"].inspect(plainRow.manifest)[1]
l:modsUi():removeModFile(plainRow, fileRow)
eq(removedFile, nil, "after a second press")
l:modsUi():removeModFile(plainRow, fileRow)
eq(removedFile, "rom", "the stored file is removed")
installed.plain.required_imports = nil

-- --------------------------------------------------------------- catalog
local ModIndex = require("src.mods.ModIndex")
local sources = {}
ModIndex.sources = function() return sources end
ModIndex.addSource = function(text)
  if text == "bad" then return nil, "not an index" end
  local row = { feed = "https://idx/" .. text .. "/index.json", label = text, url = text }
  sources[#sources + 1] = row
  return row
end
ModIndex.removeSource = function(feed)
  for i, s in ipairs(sources) do if s.feed == feed then table.remove(sources, i) end end
  return true
end
local feedBody = {
  mods = {
    { id = "newmod", title = "New Mod", author = "ann", version = "1.0.0", summary = "fresh",
      games = { "gold" }, update_check = "ok", latest = { version = "1.0.0",
        zip = { url = "https://dl/new-1.0.0.zip" } }, permissions = { "network" } },
    { id = "redthing", title = "Red Thing", games = { "red" }, downloadURL = "https://dl/red.zip" },
  },
  carts = {
    { kind = "cart", id = "hard2", title = "Harder", author = "bo", version = "1.0.0", base = "gold",
      seal = "sealed", mods = { { id = "base" } }, downloadURL = "https://dl/hard.g1rcart" },
  },
}
ModIndex.beginFetch = function(source) return { source = source, pumps = 0 } end
ModIndex.pumpFetch = function(h)
  h.pumps = h.pumps + 1
  if h.pumps < 2 then return false end
  return true, feedBody, nil, {}
end

l = fresh()
l:modsUi():openCatalog()
eq(l.page, "catalog", "Get mods opens the catalog")
check(drawText(l):find("No mod indexes added yet", 1, true), "with no index it says how to add one")
l:modsUi():addFeed("bad")
check(l.message.kind == "error" and l.message.text:find("not an index", 1, true), "a bad index is refused")
l:modsUi():addFeed("me/index")
eq(#sources, 1, "an index can be added")
pump(l, 3)
local ct = drawText(l)
check(ct:find("New Mod", 1, true) and ct:find("Harder", 1, true), "its mods and carts are listed")
check(not ct:find("Red Thing", 1, true), "only for this game by default")
l:modsUi().allGames = true
check(drawText(l):find("Red Thing", 1, true), "or for every game")
l:modsUi().query = "fresh"
local list = l:modsUi():catalogFiltered("gold")
eq(#list, 1, "search narrows the list")
l:modsUi().query, l:modsUi().allGames = "", false
l:modsUi().entry, l.page = feedBody.mods[1], "catalogitem"
local it = drawText(l)
check(it:find("Requests permission: network", 1, true), "details show what a mod asks for")
l:modsUi():installEntry(feedBody.mods[1])
pump(l, 6)
eq(installed.newmod and installed.newmod.version, "1.0.0", "Install downloads and installs the mod")
check(l.message.text:find("Installed New Mod", 1, true), "and says so")
eq(l:modsUi():entryState(feedBody.mods[1]), "installed", "the listing now reads as installed")

-- importing a .zip that is already installed is a choice, not a failure
do
  local realInstall = ModLibrary.installZip
  ModLibrary.installZip = function()
    return nil, "old is already installed",
      { exists = true, manifest = { id = "old", name = "Old Mod", version = "2.0.0" } }
  end
  l:modsUi():installMod("x", "old.zip")
  check(l.message.kind == "info" and l.message.text:find("Old Mod 2.0.0 is already installed", 1, true)
    and l.message.text:find("Remove it first", 1, true),
    "an already-installed mod says which version and what to do: " .. tostring(l.message.text))
  ModLibrary.installZip = function()
    return { id = "exp", name = "Exp Mod", version = "0.1.0", experimental = true }
  end
  l:modsUi():installMod("x", "exp.zip")
  check(l.message.text:find("experimental, so it starts off", 1, true),
    "an experimental mod says it starts off: " .. tostring(l.message.text))
  ModLibrary.installZip = realInstall
end

-- a cart from the catalog
local cartStore = { carts = {}, installed = {}, exported = {} }
package.loaded["src.carts.CartStore"] = {
  install = function(bytes)
    local id = bytes:match("^CART:([%w_%-]+)$")
    if not id then return nil, "BAD CART" end
    local cart = cartStore.carts[id] or { id = id, title = id, version = "1.0.0", base = "gold",
      seal = "sealed", mods = { { id = "base", source = "github", repo = "pins/base",
      version = "2.5.0", sha256 = ("%064x"):format(#"ZIP:base:2.5.0") } }, load_order = { "base" } }
    cartStore.carts[id] = cart
    cartStore.installed[#cartStore.installed + 1] = id
    return cart
  end,
  listFor = function(version)
    local out = {}
    for _, c in pairs(cartStore.carts) do
      if c.base == version then out[#out + 1] = { id = c.id, title = c.title, version = c.version,
        seal = c.seal } end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
  end,
  list = function() return {} end,
  get = function(id) return cartStore.carts[id] end,
  export = function(id) return "CART:" .. id end,
  uninstall = function() return true end,
  capture = function(identity, rows)
    cartStore.captured = { identity = identity, rows = rows }
    local mods, order = {}, {}
    for _, r in ipairs(rows) do
      mods[#mods + 1] = { id = r.id, source = "local", version = r.version }
      order[#order + 1] = r.id
    end
    local cart = { id = identity.id, title = identity.title, version = identity.version,
      base = identity.base, seal = identity.seal, mods = mods, load_order = order }
    cartStore.carts[identity.id] = cart
    return cart, { { id = "x" } }
  end,
}
package.loaded["src.carts.CartManifest"] = { encode = function(cart) return "CART:" .. cart.id end }
package.loaded["src.mods.Loader"] = { planCart = function(cart, have, broken)
  return realLoader.planCart(cart, have, broken)
end }

l:modsUi():installEntry(feedBody.carts[1])
pump(l, 6)
eq(cartStore.installed[#cartStore.installed], "hard2", "a cart from the catalog installs as a cart")

-- --------------------------------------------------------------- carts
l = fresh()
l:selectCart("gold", "hard2")
eq(l:activeCart("gold"), "hard2", "the cart is chosen")
check(l:cartProblem("gold") ~= nil, "it will not start without its pinned mod")
l.page = "carts"
local cartText = drawText(l)
check(cartText:find("Get its mods (1)", 1, true), "the Carts page offers to fetch its pinned mod")
check(cartText:find("Break the seal", 1, true) and cartText:find("Export", 1, true),
  "and to export it or break its seal")
l:cartsUi():fetchPins("gold", "hard2")
pump(l, 12)
eq(installed.base and installed.base.version, "2.5.0", "the pinned version is fetched, not the newest")
eq(zips[#zips].opts.replace, true, "replacing whatever version was there")
check(l:cartProblem("gold") == nil, "and the cart can start")

-- a pinned archive whose hash is wrong is refused
installed.base = nil
cartStore.carts.hard2.mods[1].sha256 = ("%064x"):format(1)
l.modRows = nil
l:cartsUi():fetchPins("gold", "hard2")
pump(l, 12)
eq(installed.base, nil, "a download that does not match the pin is not installed")
check(l.message.kind == "error" and l.message.text:find("hash", 1, true), "and the player is told why")

-- break the seal
l:cartsUi():breakSeal("gold")
check(not sealBroken["hard2:c1"], "the first press only warns")
l:cartsUi():breakSeal("gold")
check(sealBroken["hard2:c1"], "the second breaks this save's seal")
check(l:cartProblem("gold") == nil, "and the save no longer enforces the pins")
check(not drawText(l):find("Break the seal", 1, true), "a broken seal is not offered again")

-- export
l:cartsUi():exportCart("hard2")
eq(love.filesystem.read("exports/carts/hard2.g1rcart"), "CART:hard2", "export writes the cart file")
check(l.message.text:find("hard2.g1rcart", 1, true), "and says where")

-- save the current setup as a cart
l:selectCart("gold", nil)
l.page = "cartnew"
check(drawText(l):find("New cart", 1, true), "the new cart form draws")
check(l:cartsUi():saveAsCart("gold", { title = "", author = "me" }) == nil, "a cart needs a title")
local made = l:cartsUi():saveAsCart("gold", { title = "My Run!", author = "me", open = true })
check(made and made.id == "my-run", "the cart gets an id from its title")
eq(cartStore.captured.identity.seal, "open", "with the seal chosen")
eq(cartStore.captured.identity.base, "gold", "for this game")
check(cartStore.captured.identity.shell:match("^#%x%x%x%x%x%x$"), "and a shell colour the format accepts")
check(#cartStore.captured.rows >= 3, "pinning the installed mods")
check(l.message.text:find("this device", 1, true), "and the player learns which pins stay local")
eq(l.page, "carts", "back on the Carts page")

-- ------------------------------------------------------ navigation + fit
l = fresh()
for page, parent in pairs({ catalog = "mods", catalogitem = "catalog", feeds = "catalog",
    mod = "mods", modoptions = "mod", modtools = "mods", loadorder = "modtools",
    profiles = "modtools", importers = "mods", cartnew = "carts" }) do
  l.page = page
  l:back()
  eq(l.page, parent, "Back from " .. page .. " goes to " .. parent)
end

package.loaded["src.import.Importers"] = {
  all = function() return { { id = "pmd", name = "Dungeon art", summary = "sprites" } } end,
  state = function() return "missing" end, get = function() return nil end,
  resolve = function() return {} end,
}
local realButton = Kit.button
for _, size in ipairs({ { 390, 844 }, { 1280, 720 }, { 360, 640 }, { 844, 390 } }) do
  window(size[1], size[2])
  l = fresh()
  l:modsUi().entry = feedBody.mods[1]
  l:modsUi().detailFolder = "mods/fancy"
  l:modsUi().schemas = { ["mods/fancy"] = { { key = "speed", type = "number", label = "Speed", default = 2 } } }
  l:modsUi():openCatalog()
  pump(l, 3)
  for _, page in ipairs({ "mods", "mod", "modoptions", "modtools", "loadorder", "profiles",
      "catalog", "catalogitem", "feeds", "importers", "carts", "cartnew", "examples" }) do
    l.page = page
    local bad
    Kit.button = function(x, y, w, h, label, o)
      if x < -0.5 or x + w > size[1] + 0.5 then bad = bad or (tostring(label) .. " overflows") end
      if h + 0.5 < Kit.tapMin() then bad = bad or (tostring(label) .. " is too short") end
      return realButton(x, y, w, h, label, o)
    end
    drawText(l)
    Kit.button = realButton
    check(bad == nil, size[1] .. "x" .. size[2] .. " " .. page .. ": " .. tostring(bad))
  end
end
Kit.button = realButton

-- a phone on its side: the Mods list never runs under its own buttons
do
  window(844, 390)
  local lo = fresh()
  lo.page = "mods"
  local realRow = Kit.row
  local rows, footer
  for _ = 1, 3 do
    rows, footer = {}, nil
    Kit.row = function(x, y, w, h, ...)
      local c = Kit._clipRect
      local top, bottom = y, y + h
      if c then top, bottom = math.max(top, c.y), math.min(bottom, c.y + c.h) end
      if bottom > top then rows[#rows + 1] = { top, bottom } end
      return realRow(x, y, w, h, ...)
    end
    Kit.button = function(x, y, w, h, label, o)
      if label == "Install mod .zip" then
        local c = Kit._clipRect
        footer = { c and math.max(y, c.y) or y, c and math.min(y + h, c.y + c.h) or y + h }
      end
      return realButton(x, y, w, h, label, o)
    end
    drawText(lo)
    lo:update(1 / 60)
  end
  Kit.row, Kit.button = realRow, realButton
  local overlap
  for _, r in ipairs(rows) do
    if footer and footer[2] > footer[1] and r[1] < footer[2] and footer[1] < r[2] then overlap = true end
  end
  check(not overlap, "844x390: no visible mod row sits under Install mod .zip")
end

-- a phone row for a mod that needs a pack: no second button, and a tap on
-- its name opens the mod, whose page says what it needs and offers it
do
  window(390, 844)
  local p = fresh()
  p.page = "mods"
  local ui = p:modsUi()
  local realNeeds = ui.modNeeds
  ui.modNeeds = function(_, row) if row.id == "fancy" then return { text = "Needs the Dungeon import" } end end
  local rects, seen = {}, {}
  local realRow, realBtn = Kit.row, Kit.button
  Kit.row = function(x, y, w, h, sel, id)
    if id then rects[id] = { x = x, y = y, w = w, h = h } end
    return realRow(x, y, w, h, sel, id)
  end
  Kit.button = function(x, y, w, h, label, o)
    seen[tostring(label)] = true
    return realBtn(x, y, w, h, label, o)
  end
  drawText(p)
  Kit.row, Kit.button = realRow, realBtn
  check(not seen["Get pack"], "a narrow row leaves Get pack to the mod's page")
  local r = rects["mod-mods/fancy"]
  check(r ~= nil, "the row is drawn")
  if r then
    local tx, ty = r.x + r.w * 0.4, r.y + r.h / 2
    local realPos = love.mouse.getPosition
    love.mouse.getPosition = function() return tx, ty end
    p.click = { x = tx, y = ty }
    drawText(p)
    love.mouse.getPosition = realPos
    p:update(0)
  end
  eq(p.page, "mod", "a tap on its name opens the mod")
  seen = {}
  Kit.button = function(x, y, w, h, label, o) seen[tostring(label)] = true return realBtn(x, y, w, h, label, o) end
  local t = drawText(p)
  Kit.button = realBtn
  check(t:find("Needs the Dungeon import", 1, true) ~= nil, "which says what it needs")
  check(seen["Get pack"], "and offers Get pack")
  ui.modNeeds = realNeeds
  window(1280, 720)
end

-- -------------------------------------------- what a row and a details page say
do
  window(1280, 720)
  -- a mod that cannot run on Gold, named to sort first alphabetically
  installed.aaa = { id = "aaa", name = "Aaa Red Only", version = "1.0.0", games = { "red" } }
  local realList = ModLibrary.list
  ModLibrary.list = function(version)
    local rows = realList(version)
    for _, row in ipairs(rows) do
      if row.id == "aaa" then row.supported = false end
      if row.id == "plain" then
        row.description = "Makes every battle plain."
        row.manifest.category = "TOTAL_CONVERSION"
        row.manifest.games = { "gold", "silver" }
      end
    end
    return rows
  end
  local lp = fresh()
  local order = {}
  for _, row in ipairs(lp:modsFor("gold")) do order[#order + 1] = row.id end
  eq(order[#order], "aaa", "a mod that cannot run on this game sorts after the ones that can")
  eq(order[1], "cool", "and the rest keep their name order")
  lp.page = "mods"
  local text = drawText(lp)
  check(text:find("Makes every battle plain.", 1, true), "a row says what the mod does")
  check(text:find("Not made for this game", 1, true), "and a mod for another game says so")
  lp:modsUi().detailFolder, lp.page = "mods/plain", "mod"
  text = drawText(lp)
  check(text:find("Runs on Gold and Silver", 1, true), "the details page names the games it runs on")
  check(text:find("Total conversion", 1, true), "and its category, in words")
  eq(ModsPage.runsOn({ games = { "red", "blue", "yellow" } }), "Red, Blue and Yellow",
    "the game list reads as a sentence")

  -- options a mod declares in code: no file, but the game reported them
  local Cache = require("src.mods.OptionSchemaCache")
  local realLoad = Cache.load
  Cache.load = function() return { plain = { { key = "rate", type = "toggle", label = "Fast" } } } end
  lp:modsUi():changed()
  check(drawText(lp):find("Options", 1, true), "a mod whose options came from the game offers them")
  lp.page = "modoptions"
  check(drawText(lp):find("Fast", 1, true), "and the options page draws them")
  Cache.load = function() return {} end
  lp:modsUi():changed()
  lp.page = "mod"
  check(not drawText(lp):find("Options", 1, true), "a mod with no known options offers none")
  Cache.load = realLoad
  ModLibrary.list = realList
  installed.aaa = nil
end

-- ------------------------------------- a page opened with the mouse takes focus
do
  window(1280, 720)
  local lf = fresh()
  drawText(lf)
  Kit.setFocus("game-gold")
  Kit._ringShown = false   -- the mouse was last used: the ring is hidden
  lf.page = "mods"
  for _ = 1, 12 do drawText(lf); lf:update(1 / 60) end
  eq(Kit.focusId, "mods-back", "the first arrow key starts on the page just opened, not the game row")
  Kit.setFocus("game-gold")    -- the keyboard was in use: its place is kept
  lf.page = "examples"
  for _ = 1, 12 do drawText(lf); lf:update(1 / 60) end
  eq(Kit.focusId, "game-gold", "a visible ring is never moved by a page change")
  Kit.setFocus(nil)
end

-- ------------------------------------------------------------ example mods
do
  window(1280, 720)
  local installedEx = {}
  ModLibrary.examples = function(version)
    return {
      { name = "ex_gold", id = "ex_gold", title = "Gold Example", description = "Gold things",
        manifest = { games = { "gold", "silver" } }, supported = version == "gold",
        installed = installedEx.ex_gold == true },
      { name = "ex_red", id = "ex_red", title = "Red Example", description = "Red things",
        manifest = { games = { "red" } }, supported = version == "red", installed = false },
    }
  end
  ModLibrary.installExample = function(name)
    installedEx[name] = true
    return { id = name }
  end
  local le = fresh()
  le.page = "mods"
  check(drawText(le):find("Examples", 1, true), "the Mods page offers the example mods")
  le.page = "examples"
  local text = drawText(le)
  check(text:find("Gold Example", 1, true) and text:find("Gold things", 1, true),
    "the Examples page lists one with what it does")
  check(text:find("Not for Pokemon Gold: runs on Red", 1, true),
    "and says when one does not run on this game")
  le:modsUi():installExample(le:modsUi():examplesFor("gold")[1])
  eq(installedEx.ex_gold, true, "Install installs it")
  check(tostring(le.message and le.message.text):find("installed and on for Pokemon Gold", 1, true),
    "and says it is on")
  check(drawText(le):find("Installed", 1, true), "the row then reads Installed")
  le:modsUi().exampleName, le.page = "ex_red", "example"
  text = drawText(le)
  check(text:find("Red things", 1, true) and text:find("Runs on Red", 1, true),
    "an example's own page says what it does and where it runs")
  check(text:find("does not run on Pokemon Gold", 1, true), "and when it cannot run here")
  check(text:find("Install", 1, true), "with its Install button")
  le:modsUi().exampleName = "ex_gold"
  check(drawText(le):find("Open in Mods", 1, true), "an installed one points to its Mods entry")
  eq(ModsPage.PARENT.example, "examples", "Back leads to the list")
  ModLibrary.examples, ModLibrary.installExample = nil, nil
end

-- ------------------------------------------------- launcher audit (fixes)
do
  window(1280, 720)
  local GamepadMap = require("src.core.GamepadMap")
  local la = fresh()
  local function settle(n) for _ = 1, n or 12 do drawText(la); la:update(1 / 60) end end

  -- the modal file browser: nothing drawn under it takes a press
  local blockedUnder
  local realGame = la.drawGame
  la.drawGame = function(self, ...) blockedUnder = Kit.blockClicks return realGame(self, ...) end
  local realBrowserDraw = Kit.FileBrowser.draw
  Kit.FileBrowser.active, Kit.FileBrowser.draw = true, function() end
  drawText(la)
  eq(blockedUnder, true, "the launcher under the file browser takes no press")
  Kit.FileBrowser.active, Kit.FileBrowser.draw = false, realBrowserDraw
  drawText(la)
  eq(blockedUnder, false, "and takes them again once it closes")
  la.drawGame = realGame

  -- the on-screen keyboard is drawn when a field opens it
  local VK = Kit.VirtualKeyboard
  VK.active, VK.title, VK.text, VK.row, VK.col, VK.mode = true, "Profile name", "", 1, 1, 1
  check(drawText(la):find("Profile name", 1, true), "the on-screen keyboard is drawn")
  la.page = "mods"
  la:gamepadpressed(nil, "rightshoulder")
  settle(2)
  eq(la.page, "mods", "a shoulder press goes to the keyboard, not to the next section")
  la:gamepadpressed(nil, "b")
  eq(VK.active, false, "B closes the keyboard")
  eq(la.page, "mods", "and only the keyboard")

  -- Switch swaps A and B on the way in: every launcher test reads the action
  local realMap = GamepadMap.mapLauncherButton
  GamepadMap.mapLauncherButton = function(b) return ({ a = "b", b = "a" })[b] or b end
  la.page = "mods"
  la:gamepadpressed(nil, "b") -- physical A on a Switch
  settle(2)
  eq(la.page, "mods", "a Switch's A does not go Back")
  la:gamepadpressed(nil, "a") -- physical B
  settle(2)
  eq(la.page, nil, "a Switch's B does")
  GamepadMap.mapLauncherButton = realMap

  -- raw buttons from an unmapped controller still reach the launcher
  local realRaw, realIgnore = GamepadMap.mapRawToGamepadButton, GamepadMap.ignoreRawForJoystick
  GamepadMap.ignoreRawForJoystick = function() return false end
  GamepadMap.mapRawToGamepadButton = function(i) return ({ [2] = "b" })[i] end
  la.page = "mods"
  la:joystickpressed({}, 2)
  settle(2)
  eq(la.page, nil, "a raw B press goes Back")
  GamepadMap.mapRawToGamepadButton, GamepadMap.ignoreRawForJoystick = realRaw, realIgnore

  -- Start plays the save the player picked, as Continue does
  local played
  local realPlay = la.play
  la.play = function(_, v, slot) played = { v, slot } end
  la.selectedSlot[la:scopeKey("gold")] = "slot2"
  la:gamepadpressed(nil, "start")
  la:update(0)
  eq(played and played[2], "slot2", "Start plays the chosen save")
  la.play = realPlay

  -- the file browser keeps B while it is up, even on a page
  local browserKey
  local realPad = Kit.FileBrowser.gamepadpressed
  Kit.FileBrowser.active = true
  Kit.FileBrowser.gamepadpressed = function(b) browserKey = b return true end
  la.page = "mods"
  la:gamepadpressed(nil, "b")
  settle(1)
  eq(browserKey, "b", "B goes to the browser (up a folder)")
  eq(la.page, "mods", "not to the page under it")
  Kit.FileBrowser.active, Kit.FileBrowser.gamepadpressed = false, realPad

  -- Escape / B close the Games page's own popups
  la.page, la.saveMenu = nil, "slot1"
  la:keypressed("escape")
  la:update(0)
  eq(la.saveMenu, nil, "Escape closes a save's menu")

  -- a .zip on any Mods page is a mod, and an exported .lua is a save
  local gotMod
  local realInstall = la.installMod
  la.installMod = function() gotMod = true end
  la.page = "examples"
  la:handleDrop({ getFilename = function() return "/tmp/cool.zip" end,
    open = function() end, read = function() return "PKzip" end, close = function() end })
  eq(gotMod, true, "a .zip dropped on Examples installs as a mod")
  la.installMod = realInstall
  eq(Launcher.isSaveName("gen1recomp-gold-KRIS.lua"), true, "an exported .lua is a save")

  -- a section's own button leaves its sub-page
  la.page = "sync"
  la:goSection("settings")
  eq(la.page, "settings", "Settings from Save sync goes to Settings")

  -- Back from a page with two ways in goes the way it came
  la.page = "catalog"
  settle(2)
  la.page = "examples"
  settle(2)
  la:back()
  eq(la.page, "catalog", "Examples opened from Get mods goes Back to Get mods")
  la.page = "mods"
  settle(2)
  la.page = "examples"
  settle(2)
  la.page = "example"
  settle(2)
  la.page = "examples"
  settle(2)
  la:back()
  eq(la.page, "mods", "and from Mods to Mods, even after visiting an example")

  -- an unsaved relay address is dropped when Settings is left
  la.page = "settings"
  settle(2)
  la.relayDraft = "typed.but.not.saved:1"
  la.page = nil
  settle(2)
  eq(la.relayDraft, nil, "an unsaved relay address is not kept")

  -- a row chosen by Enter is chosen even with the pointer over its button
  Kit.mouseClicked = false
  eq(Kit.clickIn(0, 0, 10000, 10000), false, "no click, no click-in")

  -- Mods page odds and ends
  eq(ModsPage.clip("Pokémon Gold", 5), "Pokém", "names are cut by character")
  local ui = la:modsUi()
  ui.current = { id = "x", name = "Big Mod", stage = "releases" }
  ui:stop()
  eq(ui.current, nil, "Stop drops a single download")
  check(tostring(la.message and la.message.text):find("Stopped getting Big Mod", 1, true),
    "and says so")
  local realSet = ModLibrary.setModOptions
  ModLibrary.setModOptions = function() return false, "disk full" end
  ui:resetOptions({ id = "fancy", name = "Fancy Mod", folder = "mods/fancy" })
  check(tostring(la.message.text):find("Could not reset", 1, true), "a failed reset says it failed")
  ModLibrary.setModOptions = realSet
  Kit.setFocus(nil)
end

T.finish("mods page")
