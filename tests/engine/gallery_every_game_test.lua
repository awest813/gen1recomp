-- The gallery entries written for Gold and FireRed as well as Red, Blue and
-- Yellow.  tests/mod_examples_tests.lua covers the original eight, but it
-- needs an imported Red dataset; these six are ROM-free, so this tier holds
-- them to the same metadata checklist and runs each one's own suite.
--   luajit tests/engine/gallery_every_game_test.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
love = love or require("tests.love_stub")

local T = require("tests.harness")
local Json = require("src.link.Json")
local Manifest = require("src.mods.Manifest")
local ModTargets = require("src.mods.ModTargets")

local ROOT = "mods/examples"
-- id -> the games it must claim, and one it must not
local ENTRIES = {
  example_exp_boost = { claims = { "yellow", "gold", "firered" } },
  example_lucky_ball = { claims = { "yellow", "gold", "firered" } },
  example_safe_escape = { claims = { "yellow", "gold", "firered" } },
  example_quiet_alarm = { claims = { "yellow", "gold", "firered" } },
  example_rainy_kanto = { claims = { "firered", "leafgreen" }, not_ = "red" },
  example_kanto_visitors = { claims = { "gold", "silver" }, not_ = "firered" },
}

local function read(path)
  local handle = io.open(path, "rb")
  if not handle then return nil end
  local body = handle:read("*a")
  handle:close()
  return body
end

local ids = {}
for id in pairs(ENTRIES) do ids[#ids + 1] = id end
table.sort(ids)

local lua = (arg and arg[-1]) or "luajit"

for _, id in ipairs(ids) do
  local dir = ROOT .. "/" .. id
  local tag = id .. ": "
  local body = read(dir .. "/manifest.json")
  if T.check(body ~= nil, tag .. "ships a manifest.json") then
    local ok, parsed = pcall(Manifest.validate, Json.decode(body), dir)
    if T.check(ok, tag .. "the manifest validates (" .. tostring(parsed) .. ")") then
      T.eq(parsed.id, id, tag .. "the id matches the directory")
      T.eq(parsed.api, 2, tag .. "is an api 2 mod")
      T.check(parsed.game_version ~= nil, tag .. "declares a game_version range")
      for _, game in ipairs(ENTRIES[id].claims) do
        T.check(ModTargets.supports(parsed, game), tag .. "claims " .. game)
      end
      if ENTRIES[id].not_ then
        T.check(not ModTargets.supports(parsed, ENTRIES[id].not_),
          tag .. "does not claim " .. ENTRIES[id].not_)
      end
    end
  end
  for _, file in ipairs({ "README.md", "CHANGELOG.md", "main.lua", ".modkitignore" }) do
    T.check(read(dir .. "/" .. file) ~= nil, tag .. "ships " .. file)
  end
  local chunk = loadfile(dir .. "/mod.card")
  local okCard, card = pcall(chunk or error)
  if T.check(okCard and type(card) == "table", tag .. "mod.card returns a table") then
    T.check(type(card.summary) == "string" and #card.summary > 0 and #card.summary <= 100,
      tag .. "summary is 1..100 chars")
    T.check(type(card.tags) == "table" and #card.tags > 0, tag .. "carries a tag")
    T.check(type(card.differences) == "table" and type(card.differences.known) == "table",
      tag .. "declares a differences ledger")
    T.check(type(card.credits) == "table" and #card.credits > 0, tag .. "names a credit")
    T.eq(card.compat and card.compat.modApi, 2, tag .. "compat declares modApi 2")
  end
  local suite = dir .. "/tests/" .. id .. "_test.lua"
  if T.check(read(suite) ~= nil, tag .. "ships its own suite") then
    local status = os.execute(("%s %s >/dev/null 2>&1"):format(lua, suite))
    T.check(status == 0 or status == true, tag .. "its own suite passes")
  end
end

-- the gallery index lists every entry
local index = read(ROOT .. "/README.md") or ""
for _, id in ipairs(ids) do
  T.check(index:find("(" .. id .. ")", 1, true) ~= nil, "the gallery README lists " .. id)
end

T.finish("gallery: every-game entries")
