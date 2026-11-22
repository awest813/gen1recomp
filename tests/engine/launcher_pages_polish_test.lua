-- Launcher pages polish: store failures read as sentences (no "false", no
-- file:line), sync errors are sentences and the link codes clear once a
-- link starts, a cart whose missing mods cannot be downloaded still says
-- which they are, and the Keys page lists every default binding.
--   luajit tests/engine/launcher_pages_polish_test.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
love = love or require("tests.love_stub")

local T = require("tests.harness")
local check, eq = T.check, T.eq

-- ---- Reason: why a pcall'd call failed
do
  local Reason = require("src.launcher.Reason")
  eq(Reason(false, "src/carts/CartStore.lua:12: disk full.\nstack traceback:"), "disk full",
    "a raised error loses its file:line, its trace and its full stop")
  eq(Reason(true, false, nil), "it did not work", "a bare false is not printed as 'false'")
  eq(Reason(true, nil, "cart \"x\" is not installed"), "cart \"x\" is not installed",
    "a returned reason is kept")
end

-- ---- Sync page: sentences, and the codes clear after a link starts
do
  local said = {}
  local l = { say = function(_, text, kind) said[#said + 1] = { text = text, kind = kind } end }
  local SyncPage = require("src.launcher.SyncPage")
  eq(SyncPage._sentence("sync is busy"), "Sync is busy.", "a reason becomes a sentence")
  eq(SyncPage._sentence("Done."), "Done.", "a sentence is left alone")
  local page = SyncPage.new(l)
  local linkOk = false
  page.engine = function()
    return { linkDevice = function()
      if linkOk then return true end
      return false, "both codes are 8 digits"
    end }
  end
  page.code1, page.code2 = "1234", "5678"
  page:link(page.code1, page.code2)
  eq(said[#said].text, "Both codes are 8 digits.", "a refused link says why, as a sentence")
  eq(page.code1, "1234", "and keeps the codes to correct")
  linkOk = true
  page:link("12345678", "87654321")
  eq(page.code1, "", "a link that starts clears the first code")
  eq(page.code2, "", "and the second")
end

-- ---- Carts page: missing mods with no release still answer
do
  local said = {}
  local l = {
    say = function(_, text, kind) said[#said + 1] = { text = text, kind = kind } end,
    activeCart = function() return "hard", { id = "hard", seal = "open" } end,
  }
  local CartsPage = require("src.launcher.CartsPage")
  local page = CartsPage.new(l)
  page.cartSave = function() return nil, false end
  page.pinsToFetch = function() return { fetch = {}, manual = { "secret_mod" } } end
  local fetch
  for _, item in ipairs(page:activeItems("gold")) do
    if item.id == "cart-fetch" then fetch = item end
  end
  check(fetch ~= nil, "the cart offers its missing mods")
  eq(fetch and fetch.label, "Missing mods (1)", "named for what it does when nothing downloads")
  check(fetch and fetch.enabled ~= false, "and can be pressed")
  fetch.run()
  check(said[#said] and said[#said].text:find("secret_mod", 1, true),
    "a press names the mod to install by hand")
end

-- ---- Keys page: every default the games answer to
do
  local KeysPage = require("src.launcher.KeysPage")
  local all = {}
  for _, sec in ipairs(KeysPage.SECTIONS) do
    for _, row in ipairs(sec[2]) do all[#all + 1] = row[1] .. " = " .. row[2] end
  end
  local text = table.concat(all, "\n")
  check(text:find("Tab or Shift = SELECT", 1, true), "Shift is listed for SELECT")
  check(text:find("LT / RT = Game speed (every game)", 1, true), "the triggers change speed in every game")
end

T.finish("launcher pages polish")
