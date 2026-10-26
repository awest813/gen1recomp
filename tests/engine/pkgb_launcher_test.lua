-- The PK:GB launcher (src/launcher/Launcher.lua) and its import job
-- (src/import/ImportJob.lua), headless.  No pokered cite: port-only chrome.
--
-- Pins what a player relies on: every game is listed, the required credit
-- is on screen at every window size, a bad file is refused with a reason,
-- Continue plays the chosen save and New game makes a fresh one, and clicks
-- only queue work until update() runs it.
--   luajit tests/engine/pkgb_launcher_test.lua

package.path = "./?.lua;./?/init.lua;" .. package.path
love = love or require("tests.love_stub")
love.graphics.setLineJoin = love.graphics.setLineJoin or function() end
love.graphics.newShader = love.graphics.newShader or function() return {} end

local T = require("tests.harness")
local check, eq = T.check, T.eq

local GameVersion = require("src.core.GameVersion")
local ImportJob = require("src.import.ImportJob")

-- SaveData seam: two Gold saves, slot creation recorded.
local created, active, deleted, renamed = {}, {}, {}, {}
local savedOptions, saves = { musicVol = 5, sfxVol = 7, videoMode = "windowed" }, 0
local imported, exported = {}, {}
package.loaded["src.import.SaveFileIO"] = {
  importToSlot = function(source, version)
    imported[#imported + 1] = { source = source, version = version }
    active[version] = "slot7"
    return true
  end,
  exportActiveSlot = function(version)
    exported[#exported + 1] = { version = version, slot = active[version] }
    return true, "/exports/" .. version .. "/" .. tostring(active[version]) .. ".sav"
  end,
}
package.loaded["src.core.SaveData"] = {
  listSlots = function(version)
    if version ~= "gold" then return {} end
    return {
      { id = "slot1", exists = true, name = "GOLD",
        meta = { timeText = "3:15", badges = 2, dexCount = 31 } },
      { id = "slot2", exists = true, name = "KRIS",
        meta = { timeText = "0:42", badges = 0, dexCount = 4 } },
      { id = "slot3", exists = false },
    }
  end,
  activeSlot = function(version) return active[version] or "slot1" end,
  setActiveSlot = function(version, id) active[version] = id return true end,
  loadOptions = function() return savedOptions end,
  saveOptions = function(opts) savedOptions = opts; saves = saves + 1 return true end,
  deleteSlot = function(version, id) deleted[#deleted + 1] = version .. ":" .. id return true end,
  renameSlot = function(version, id, name) renamed[#renamed + 1] = { id = id, name = name } return true end,
  createSlot = function(version)
    local id = "slot" .. (10 + #created)
    created[#created + 1] = { version = version, id = id }
    return id
  end,
}
-- Only Gold is imported.
package.loaded["src.import.CacheContract"] = setmetatable({
  isReady = function(version) return version == "gold" end,
}, { __index = require("src.import.CacheContract") })

local Launcher = require("src.launcher.Launcher")

local launched = {}
local function fresh()
  launched = {}
  return Launcher.new(function(version) launched[#launched + 1] = version end)
end

local function window(w, h)
  love.graphics.getDimensions = function() return w, h end
  love.graphics.getPixelDimensions = function() return w, h end
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
  check(ok, "the launcher draws: " .. tostring(err))
  return table.concat(seen, "\n")
end

-- ------------------------------------------------------------- library
local l = fresh()
local inOrder = {}
for _, v in ipairs(GameVersion.ORDER) do inOrder[v] = true end
local allKnown = true
for _, v in ipairs(l.games) do allKnown = allKnown and inOrder[v] == true end
check(allKnown, "every listed game is a supported GameVersion")
check(#l.games >= 10, "every supported game is listed (" .. #l.games .. ")")
eq(l.selected, "gold", "an imported game is selected first")
check(l.ready.gold and not l.ready.red, "readiness comes from the cache contract")

local slots = l:slotsFor("gold")
eq(#slots, 2, "only saves that exist are offered")
eq(l.selectedSlot.gold, "slot1", "the active save is preselected")

-- ------------------------------------------------- credit at every size
for _, size in ipairs({ { 1280, 720 }, { 1024, 768 }, { 800, 600 },
    { 390, 844 }, { 360, 640 } }) do
  window(size[1], size[2])
  local text = drawText(fresh())
  local tag = size[1] .. "x" .. size[2]
  check(text:find("BOIS CLUB", 1, true) ~= nil
      and text:find("github.com/bryanthaboi/gen1recomp", 1, true) ~= nil,
    tag .. ": the license-required credit is on screen")
  check(text:find("Pokemon Gold", 1, true) ~= nil, tag .. ": the game list draws")
  check(text:find("Continue", 1, true) ~= nil and text:find("New game", 1, true) ~= nil,
    tag .. ": Continue and New game are offered for an imported game")
end
eq(Launcher.CREDIT, "Based on the Pokemon Gen 1 Recompilation Project by "
  .. "BOIS CLUB GAMES, LLC (https://github.com/bryanthaboi/gen1recomp)",
  "the credit is the exact wording LICENSE.MD requires")

-- --------------------------------------------- a game not yet imported
window(1280, 720)
l = fresh()
l.selected = "red"
local text = drawText(l)
check(text:find("Import ROM", 1, true) ~= nil, "a missing game offers Import ROM")
check(text:find("Continue", 1, true) == nil, "and no Continue")

-- ------------------------------------------------------- bad files
l = fresh()
l:importData("not a rom", "notes.txt")
check(l.message and l.message.kind == "error", "a wrong-size file is refused")
check(l.message.text:find("MiB", 1, true) ~= nil, "with the size explained")
eq(l.job, nil, "and no import starts")
local _, err = ImportJob.verify("", "empty.gb")
check(err ~= nil, "an empty file is refused")
local _, err2 = ImportJob.verify(nil, "x.gb")
check(err2 ~= nil, "an unreadable file is refused")

-- ------------------------------------------------------------ play
l = fresh()
l.selectedSlot.gold = "slot2"
l:play("gold", "slot2")
eq(active.gold, "slot2", "Continue makes the chosen save active")
eq(launched[1], "gold", "and launches that game")

l = fresh()
l:newGame("gold")
eq(#created, 1, "New game creates a save slot")
eq(active.gold, created[1].id, "makes it active")
eq(launched[1], "gold", "and launches")

-- ------------------------------------- clicks queue; update() runs them
window(1280, 720)
l = fresh()
local Kit = require("src.ui.kit.Kit")
local rects = {}
local realButton = Kit.button
Kit.button = function(x, y, w, h, label, opts)
  if opts and opts.id then rects[opts.id] = { x = x + w / 2, y = y + h / 2 } end
  return realButton(x, y, w, h, label, opts)
end
l:draw()
check(rects.newgame ~= nil, "New game has a button")
l:mousepressed(rects.newgame.x, rects.newgame.y, 1)
l:mousereleased(rects.newgame.x, rects.newgame.y, 1)
local before = #created
l:draw()
eq(#created, before, "a click does nothing inside draw")
l:update(0)
eq(#created, before + 1, "update() runs the queued New game")
eq(launched[#launched], "gold", "which launches the game")
Kit.button = realButton

-- ------------------------------------------------------- save files
l = fresh()
l.selectedSlot.gold = "slot2"
l:deleteSave()
eq(#deleted, 0, "the first Delete only arms")
check(l.message and l.message.kind == "error", "and warns")
l:deleteSave()
eq(deleted[1], "gold:slot2", "the second Delete removes that save")

l = fresh()
l.selectedSlot.gold = "slot1"
l:deleteSave()
l:queue(function() end)
l:update(0)
l:deleteSave()
eq(#deleted, 1, "any other action in between disarms Delete")

l = fresh()
l.selectedSlot.gold = "slot2"
l:renameSave("  Nuzlocke run  ")
eq(renamed[1].id, "slot2", "Rename targets the selected save")
eq(renamed[1].name, "Nuzlocke run", "with the name trimmed")
l:renameSave("   ")
eq(renamed[2].name, nil, "a blank name clears the label")

l = fresh()
l.selectedSlot.gold = "slot2"
l:exportSave()
eq(exported[1].slot, "slot2", "Export writes the selected save, not just the active one")
check(l.message.text:find("slot2.sav", 1, true) ~= nil, "and says where it went")

l = fresh()
local dropped = { getFilename = function() return "/home/me/Gold.sav" end }
l:filedropped(dropped)
eq(imported[1] and imported[1].source, dropped, "a dropped .sav is imported as a save")
eq(imported[1].version, "gold", "into the selected game")
eq(l.selectedSlot.gold, "slot7", "and the new save is selected")
check(Launcher.isSaveName("x.SRM") and not Launcher.isSaveName("x.gbc"),
  "save files are told from ROMs by extension")
l.selected = "red"
l:importSave("bytes", "Red.sav")
eq(#imported, 1, "a save for a game without its ROM is refused")

-- -------------------------------------------------------------- settings
-- (listing games runs SecretGames' unlock check, which may itself write the
-- options; start this section from a known options table)
l = fresh()
savedOptions, saves = { musicVol = 5, sfxVol = 7, videoMode = "windowed" }, 0
eq(l:options().musicVol, 5, "settings read the saved options")
l:setOption("musicVol", 6)
eq(savedOptions.musicVol, 6, "a change is written straight to the options")
eq(saves, 1, "once")
local applied
package.loaded["src.core.VideoMode"] = { apply = function(m) applied = m end,
  fixedDisplay = function() return false end,
  normalize = function(m) return m == "borderless" and m or "windowed" end }
l:setOption("videoMode", "borderless")
eq(applied, "borderless", "the display mode applies to the live window")
window(1280, 720)
l.page = "settings"
local stext = drawText(l)
check(stext:find("Music volume", 1, true) and stext:find("Sound volume", 1, true)
  and stext:find("Fullscreen", 1, true), "the settings page draws its rows")
check(stext:find("BOIS CLUB", 1, true) ~= nil, "with the credit still on screen")
l:queue(function() end)
local rects2 = {}
local realButton2 = Kit.button
Kit.button = function(x, y, w, h, label, opts)
  if opts and opts.id then rects2[opts.id] = { x = x + w / 2, y = y + h / 2 } end
  return realButton2(x, y, w, h, label, opts)
end
l:draw()
Kit.button = realButton2
check(rects2["musicVol-up"] and rects2["sfxVol-down"] and rects2["video-mode"],
  "every setting has a control")

-- ------------------------------------------------- browser file picker
local picks, queued, pickErr = {}, nil, nil
love.system = love.system or {}
local realSys = { pickFile = love.system.pickFile, getPickedFile = love.system.getPickedFile,
  getPickError = love.system.getPickError }
love.system.pickFile = function(kind) picks[#picks + 1] = kind return true end
love.system.getPickedFile = function() local p = queued queued = nil return p end
love.system.getPickError = function() local e = pickErr pickErr = nil return e end

l = fresh()
local nImported = #imported
l:pickSave()
eq(picks[1], "sav", "Import .sav asks the browser for a save file")
l:update(0)
eq(#imported, nImported, "nothing happens until the pick arrives")
local tmp = os.tmpname()
local fh = io.open(tmp, "wb") fh:write(("\0"):rep(32786)) fh:close()
queued = tmp
l:update(0)
eq(imported[#imported].source, tmp, "a picked save is imported by path (fits any save size)")
eq(io.open(tmp, "rb"), nil, "and the temporary copy is removed")

l:pickRom()
eq(picks[2], "rom", "Import ROM asks the browser for a ROM")
pickErr = "The picker was closed."
l:update(0)
check(l.message and l.message.text == "The picker was closed.", "a picker error is shown")
eq(l.pendingPick, nil, "and the pick is over")

local rom = os.tmpname()
fh = io.open(rom, "wb") fh:write("not a rom") fh:close()
l:pickRom()
queued = rom
l:update(0)
check(l.message and l.message.text:find("MiB", 1, true) ~= nil,
  "a picked ROM goes through the same verification as a dropped one")
eq(io.open(rom, "rb"), nil, "and its temporary copy is removed")
for k, v in pairs(realSys) do love.system[k] = v end

-- ------------------------------------------------ updater and notes
local checkState = { status = "uptodate" }
local downloads, fullUpdates = 0, 0
package.loaded["src.update.Check"] = {
  start = function() end,
  state = function() return checkState end,
  download = function() downloads = downloads + 1 end,
  fullUpdateAction = function() return { label = "Download full update" } end,
  performFullUpdate = function() fullUpdates = fullUpdates + 1 end,
}
package.loaded["src.update.PatchNotes"] = {
  body = function() return "## Issues closed\n\n- **#12** cart padding", "1.4.2" end,
}
l = fresh()
eq(l:updateChip(), nil, "no chip when the game is up to date")
checkState = { status = "available", latest = "1.4.2" }
local label, action, enabled = l:updateChip()
eq(label, "Update to 1.4.2", "a new release is offered by version")
check(enabled and action, "and can be started")
action()
eq(downloads, 1, "which downloads the update")
checkState = { status = "downloading", progress = 0.42 }
label, action, enabled = l:updateChip()
eq(label, "Downloading 42%", "the download shows its progress")
check(not enabled and action == nil, "and cannot be pressed twice")
checkState = { status = "ready" }
eq(select(1, l:updateChip()), "Restart to update", "a downloaded update asks for a restart")
checkState = { status = "needs_full" }
label, action = l:updateChip()
eq(label, "Download full update", "a full update names the platform's action")
action()
eq(fullUpdates, 1, "and performs it")
checkState = { status = "available", latest = "1.4.2" }
window(1280, 720)
local ut = drawText(l)
check(ut:find("Update to 1.4.2", 1, true) ~= nil, "the chip is on screen")
l.page = "notes"
local nt = drawText(l)
check(nt:find("v1.4.2", 1, true) and nt:find("cart padding", 1, true),
  "What's new shows the patch notes for that version")
check(not nt:find("**", 1, true) and not nt:find("##", 1, true),
  "with the markdown markers stripped")
local wrapped = l.notesLines
drawText(l)
check(l.notesLines == wrapped, "and wraps them once, not every frame")

-- ------------------------------------------------------------------- mods
local modState = { cool = true, exp = false }
local modCalls = { toggled = {}, removed = {}, installed = {} }
package.loaded["src.mods.ModLibrary"] = {
  list = function(version)
    return {
      { id = "cool", name = "Cool Mod", folder = "mods/cool", version = "1.0",
        author = "someone", supported = true, enabled = modState.cool },
      { id = "exp", name = "Experiment", folder = "mods/exp", experimental = true,
        supported = true, enabled = modState.exp },
      { id = "redonly", name = "Red Only", folder = "mods/redonly",
        supported = version == "red", enabled = true },
    }
  end,
  setEnabled = function(id, on, version)
    modCalls.toggled[#modCalls.toggled + 1] = id .. "=" .. tostring(on) .. "@" .. version
    modState[id] = on
    return true
  end,
  uninstall = function(folder)
    modCalls.removed[#modCalls.removed + 1] = folder
    return true
  end,
  installZip = function(bytes, name)
    modCalls.installed[#modCalls.installed + 1] = name
    if bytes == "bad" then return nil, "no manifest.json in that .zip" end
    return { id = "new", name = "New Mod", dependencies = { "base" } }
  end,
  missingDependencies = function() return { "base" } end,
}
window(1280, 720)
l = fresh()
l.selected = "gold"
local dt = drawText(l)
check(dt:find("Mods", 1, true) ~= nil, "an imported game offers its Mods page")
l.page = "mods"
local mt = drawText(l)
check(mt:find("Cool Mod", 1, true) and mt:find("Experiment", 1, true),
  "the Mods page lists installed mods")
check(mt:find("Not made for this game", 1, true) ~= nil,
  "a mod for another game says so")
check(mt:find("Install mod .zip", 1, true) ~= nil, "and offers to install one")
l:toggleMod("gold", l:modsFor("gold")[1])
eq(modCalls.toggled[1], "cool=false@gold", "a toggle switches the mod for this game only")
eq(l:modsFor("gold")[1].enabled, false, "and the page re-reads the answer")
local cool = l:modsFor("gold")[1]
l:removeMod(cool)
eq(#modCalls.removed, 0, "the first Remove only arms")
l:removeMod(cool)
eq(modCalls.removed[1], "mods/cool", "the second uninstalls")
l:installMod("zipbytes", "new.zip")
check(l.message and l.message.text:find("New Mod", 1, true)
  and l.message.text:find("base", 1, true), "an install names the mod and what it still needs")
l:installMod("bad", "bad.zip")
check(l.message.kind == "error" and l.message.text:find("no manifest", 1, true),
  "a bad package is refused with the reason")
local zipFile = { getFilename = function() return "/home/x/thing.zip" end,
  open = function() end, close = function() end, read = function() return "zipbytes" end }
local before = #modCalls.installed
l:filedropped(zipFile)
eq(#modCalls.installed, before + 1, "a .zip dropped on the Mods page installs as a mod")
l.page = nil
local importedData
local realImport = l.importData
l.importData = function(_, data) importedData = data end
l:filedropped(zipFile)
eq(importedData, "zipbytes", "elsewhere a dropped .zip is a ROM archive")
l.importData = realImport
window(390, 844)
l.page = "mods"
drawText(l)

-- ---------------------------------------------------- launcher choice
local LaunchOptions = require("src.core.LaunchOptions")
local choice, remember = LaunchOptions.launcherUi({ "--ui=new" })
check(choice == "new" and remember, "--ui=new picks this launcher and is remembered")
choice, remember = LaunchOptions.launcherUi({}, { "--ui", "classic" })
check(choice == "classic" and remember, "--ui classic goes back")
check(LaunchOptions.launcherUi({ "--ui=bogus" }) == nil, "an unknown value asks for nothing")
window(1280, 720)
l = fresh()
l.page = "settings"
check(drawText(l):find("Use classic", 1, true) ~= nil, "Settings offers the classic launcher")
l:setOption("launcherUi", "classic")
eq(savedOptions.launcherUi, "classic", "and remembers the switch")
check(drawText(l):find("Keep this one", 1, true) ~= nil, "which can be undone")

-- ------------------------------------------------------------------ carts
local cartSlots = { cartcreated = {}, active = {}, deleted = {} }
local SD = package.loaded["src.core.SaveData"]
SD.listCartSlots = function(id)
  if id ~= "hard" then return {} end
  return { { id = "c1", exists = true, name = "HARD", meta = { timeText = "1:00",
    badges = 1, dexCount = 9 } } }
end
SD.activeCartSlot = function(id) return cartSlots.active[id] or "c1" end
SD.setActiveCartSlot = function(id, slot) cartSlots.active[id] = slot return true end
SD.createCartSlot = function(id)
  cartSlots.cartcreated[#cartSlots.cartcreated + 1] = id
  return "c9"
end
SD.deleteCartSlot = function(id, slot)
  cartSlots.deleted[#cartSlots.deleted + 1] = id .. ":" .. slot
  return true
end
SD.renameCartSlot = function() return true end
local installedCarts = {
  { id = "hard", title = "Hard Mode", base = "gold", version = "1.2.0", author = "maker",
    seal = "sealed" },
  { id = "pinned", title = "Needs Mods", base = "gold", seal = "sealed" },
}
local cartCalls = { installed = {}, removed = {} }
package.loaded["src.carts.CartStore"] = {
  listFor = function(version)
    local out = {}
    for _, c in ipairs(installedCarts) do if c.base == version then out[#out + 1] = c end end
    return out
  end,
  get = function(id) return { id = id } end,
  install = function(bytes)
    cartCalls.installed[#cartCalls.installed + 1] = bytes
    if bytes == "junk" then return nil, "BAD CART" end
    installedCarts[#installedCarts + 1] = { id = "fresh", title = "Fresh", base = "gold" }
    return { id = "fresh", title = "Fresh", base = "gold" }
  end,
  uninstall = function(id)
    cartCalls.removed[#cartCalls.removed + 1] = id
    for i, c in ipairs(installedCarts) do
      if c.id == id then table.remove(installedCarts, i) break end
    end
    return true
  end,
}
package.loaded["src.mods.Loader"] = {
  planCart = function(cart)
    if cart and cart.id == "pinned" then
      return { refused = true, message = "Needs Mods: missing base-mod" }
    end
    return { refused = false }
  end,
}
window(1280, 720)
savedOptions.activeCart = nil
l = fresh()
l.selected = "gold"
check(drawText(l):find("Carts", 1, true) ~= nil, "an imported game offers its Carts page")
eq(l:activeCart("gold"), nil, "a game plays as the original until a cart is chosen")
l.page = "carts"
local ct = drawText(l)
check(ct:find("The original game", 1, true) and ct:find("Hard Mode", 1, true),
  "the Carts page lists the original and each installed cart")
check(ct:find("Install cart", 1, true) ~= nil, "and offers to install one")
l:selectCart("gold", "hard")
eq(savedOptions.activeCart and savedOptions.activeCart.gold, "hard",
  "the chosen cart is remembered for the next start")
eq(#l:slotsFor("gold"), 1, "a cart lists its own saves")
eq(l:slotsFor("gold")[1].id, "c1", "not the original game's")
l.page = nil
local pt = drawText(l)
check(pt:find("Playing as Hard Mode", 1, true) ~= nil, "the game panel names the cart")
launched = {}
local launchedCart
l.onLaunch = function(version, cartId) launched[#launched + 1] = version; launchedCart = cartId end
l:play("gold", "c1")
check(launched[1] == "gold" and launchedCart == "hard", "Continue boots the game as the cart")
eq(cartSlots.active.hard, "c1", "on the cart's chosen save")
-- SaveData's own writes (a new slot's registry) replace its options table
local replaced = {}
for k, v in pairs(savedOptions) do replaced[k] = v end
replaced.cartSlots = { hard = { list = { "c9" } } }
savedOptions = replaced
l:newGame("gold")
eq(cartSlots.cartcreated[1], "hard", "New game makes the save inside the cart")
check(savedOptions.cartSlots and savedOptions.cartSlots.hard,
  "and launching never writes back an older copy of the options over SaveData's")
l.selectedSlot[l:scopeKey("gold")] = "c1"
l:deleteSave(); l:deleteSave()
eq(cartSlots.deleted[1], "hard:c1", "a cart save is deleted from the cart")
l:importSave("/x.sav", "x.sav")
check(l.message.kind == "error", "a .sav does not import into a cart")

launched, launchedCart = {}, nil
l:selectCart("gold", "pinned")
l:play("gold", "c1")
eq(#launched, 0, "a cart the mod loader would refuse does not start")
check(l.message.text:find("missing base-mod", 1, true) ~= nil, "and says what is missing")

l:selectCart("gold", nil)
eq(l:scopeKey("gold"), "gold", "choosing the original goes back to its saves")
eq(savedOptions.activeCart, nil, "and forgets the cart")

l:installCart("cartbytes", "fresh.g1rcart")
eq(l:activeCart("gold"), "fresh", "an installed cart is chosen for its game")
check(l.message.text:find("Fresh", 1, true) ~= nil, "and named")
l:installCart("junk", "junk.g1rcart")
check(l.message.kind == "error" and l.message.text:find("BAD CART", 1, true), "a bad cart is refused")
local fresh2 = l:cartsFor("gold")[3]
l:removeCart("gold", fresh2)
eq(#cartCalls.removed, 0, "the first Remove only arms")
l:removeCart("gold", fresh2)
eq(cartCalls.removed[1], "fresh", "the second uninstalls")
eq(l:activeCart("gold"), nil, "and the game goes back to the original")
local cartFile = { getFilename = function() return "C:\\carts\\x.g1rcart" end,
  open = function() end, close = function() end, read = function() return "cartbytes" end }
l:filedropped(cartFile)
eq(#cartCalls.installed, 3, "a dropped .g1rcart installs as a cart")
window(390, 844)
l.page = "carts"
drawText(l)
l.page = nil
drawText(l)

-- ------------------------------------------------------------------ skins
window(1280, 720)
local studioOpened
l = Launcher.new(function() end, { onOpenSkinStudio = function(version, id)
  studioOpened = { version = version, id = id } end })
l.page = "settings"
check(drawText(l):find("Built-in pad", 1, true) ~= nil, "Settings shows the built-in pad in use")
savedOptions.touchControls = { enabled = true, skin = "gba_purple" }
check(drawText(l):find("gba_purple", 1, true) ~= nil, "or the skin in use")
savedOptions.touchControls = { enabled = false, skin = "gba_purple" }
eq(l:activeSkin(), nil, "a switched-off pad has no skin in use")
savedOptions.touchControls = { enabled = true, skin = "gba_purple" }
l:openStudio(l:activeSkin())
check(studioOpened and studioOpened.id == "gba_purple" and studioOpened.version == l.selected,
  "the skin button opens the Skin Studio on the skin in use")
savedOptions.touchControls = nil
local noStudio = Launcher.new(function() end)
noStudio.page = "settings"
check(not drawText(noStudio):find("Built-in pad", 1, true), "no skin button where the host has no Studio")

-- a press on a row's own button is not also a press on the row
installedCarts = { { id = "hard", title = "Hard Mode", base = "gold" } }
l = fresh()
l.selected, l.page = "gold", "carts"
l.cartRows = nil
local rect
local realKitButton = Kit.button
Kit.button = function(x, y, w, h, label, opts)
  if opts and opts.id == "cart-remove-hard" then rect = { x = x, y = y, w = w, h = h } end
  return realKitButton(x, y, w, h, label, opts)
end
drawText(l)
check(rect ~= nil, "the cart row has a Remove button")
local realGetPosition = love.mouse.getPosition
love.mouse.getPosition = function() return rect.x + rect.w / 2, rect.y + rect.h / 2 end
l.click = { x = rect.x + rect.w / 2, y = rect.y + rect.h / 2 }
drawText(l)
l:update(0)
Kit.button = realKitButton
love.mouse.getPosition = realGetPosition
eq(l.armedDelete, "cart:hard", "pressing Remove arms it")
eq(l:activeCart("gold"), nil, "without also choosing the cart")

-- -------------------------------------------------------------------- box
-- the Box reads real save files, so it runs on the real SaveData (over the
-- stubbed love.filesystem) rather than the stub the sections above use
local stubSaveData = package.loaded["src.core.SaveData"]
package.loaded["src.core.SaveData"] = nil
require("src.core.SaveData")
window(1280, 720)
l = fresh()
local ht = drawText(l)
check(ht:find("Box", 1, true) ~= nil, "the header offers the Box")
l:openBox()
eq(l.page, "box", "the Box opens as a page")
eq(l.tab, "box", "and tells the Box UI it is showing")
check(l._boxState ~= nil, "the Box state is loaded: " .. tostring(l.message and l.message.text))
local bt = drawText(l)
check(bt:find("BOX", 1, true) ~= nil or bt:find("Box", 1, true) ~= nil, "the Box draws")
check(bt:find("BOIS CLUB", 1, true) ~= nil, "with the credit still on screen")
check(l.boxContentH ~= nil, "and reports its height for scrolling")
require("src.import.BoxUI").open(l, "Pick", { { id = 1, label = "One" }, { id = 2, label = "Two" } }, 1,
  function() end)
local pop = drawText(l)
check(pop:find("Pick", 1, true) ~= nil, "a Box popup draws over the page")
check(Kit.blockClicks == false, "and the frame ends with clicks unblocked for the next one")
l:keypressed("escape")
check(l._boxPopup == nil, "Escape closes the popup first")
local renamed
require("src.import.BoxPrompt").open(l, "Rename box", "BOX 1", 8, function(t) renamed = t end)
check(l._boxPrompt ~= nil, "a Box rename opens a prompt here (no on-screen keyboard)")
check(drawText(l):find("Rename box", 1, true) ~= nil, "the Box rename prompt draws")
l._boxPrompt.text = "PARTY"
l:keypressed("return")
l:update(0)
eq(renamed, "PARTY", "Enter saves the prompt")
l:importBox("short", nil)
for _, size in ipairs({ { 390, 844 }, { 800, 600 } }) do
  window(size[1], size[2])
  drawText(l)
end
window(1280, 720)
l:keypressed("escape")
l:update(0)
eq(l.page, nil, "Escape leaves the Box")
eq(l.tab, nil, "and the Box UI knows it is hidden")
package.loaded["src.core.SaveData"] = stubSaveData

T.finish("pkgb launcher")
