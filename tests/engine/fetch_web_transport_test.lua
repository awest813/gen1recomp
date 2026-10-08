-- src/net/Fetch.lua's browser transport: with the lovejs bridge's fetch
-- functions present, jobs run through the page's fetch() instead of worker
-- threads and keep the same submit/poll contract.  The bridge is faked here:
-- fetchStart records the request and fetchPoll replays a scripted state.
--   luajit tests/engine/fetch_web_transport_test.lua   (also runs on lua5.1)
package.path = "./?.lua;./?/init.lua;" .. package.path
local T = require("tests.harness")
local eq, check = T.eq, T.check
love = love or require("tests.love_stub")
love.system = love.system or {}
love.filesystem = love.filesystem or {}

local TMP = os.getenv("TMPDIR") or "/tmp"
os.execute("mkdir -p " .. TMP .. "/g1r_fetch_test_save /tmp/g1r_fetch")
love.filesystem.getSaveDirectory = function() return TMP .. "/g1r_fetch_test_save" end

local started, states, forgotten = {}, {}, {}
local fake = {}
function fake.fetchStart(id, method, url, headers, body, dest, flags, timeoutMs)
  started[id] = { method = method, url = url, headers = headers, body = body, dest = dest,
    flags = flags, timeoutMs = timeoutMs }
  states[id] = { "pending", 0, 0.25, nil }
  return true
end
function fake.fetchPoll(id)
  local st = states[id] or { "unknown", 0, 0, nil }
  return st[1], st[2], st[3], st[4]
end
function fake.fetchForget(id) forgotten[id] = true end
local function land(id, bytes, code)
  local fh = assert(io.open(started[id].dest, "wb"))
  fh:write(bytes)
  fh:close()
  states[id] = { "ok", code or 200, 1, nil }
end

local dirtied = 0
package.loaded["src.core.WebHost"] = {
  fetchBridge = function() return fake end,
  markDirty = function() dirtied = dirtied + 1 end,
  isWeb = function() return true end,
  openURL = function(url) return love.system.openURL and love.system.openURL(url) or false end,
}

local Fetch = require("src.net.Fetch")
check(Fetch.available(), "the browser transport counts as available")

-- GET: the body comes back through poll, the temp file is cleaned up
local get = Fetch.get("https://example.github.io/index.json",
  { accept = "application/json", userAgent = "gen1recomp-mod-index" })
local req = started[get]
eq(req and req.method, "GET", "a get is a GET")
check(req and req.headers:find("Accept: application/json", 1, true), "Accept is sent")
check(req and not req.headers:lower():find("user-agent", 1, true), "User-Agent is not (browsers forbid it)")
local st = Fetch.poll(get)
eq(st.status, "pending", "pending while the page fetches")
eq(st.progress, 0.25, "progress comes through")
land(get, '{"mods":[]}')
st = Fetch.poll(get)
eq(st.status, "ok", "finished")
eq(st.body, '{"mods":[]}', "with the body")
eq(st.code, 200, "and the HTTP status")
check(forgotten[get], "the page forgets the finished job")
eq(io.open(req.dest, "rb"), nil, "the temp body file is removed")

-- download: lands under the save directory and dirties storage
local dl = Fetch.download("https://example.com/mod.zip", "mod_downloads/mod.zip")
eq(started[dl].dest, love.filesystem.getSaveDirectory() .. "/mod_downloads/mod.zip",
  "a download goes straight to its save-directory path")
os.execute("mkdir -p " .. love.filesystem.getSaveDirectory() .. "/mod_downloads")
land(dl, "PK\3\4")
st = Fetch.poll(dl)
eq(st.status, "ok", "download finished")
eq(st.path, "mod_downloads/mod.zip", "path is the save-relative one, like the worker's")
eq(dirtied, 1, "and the save store is marked for an IndexedDB sync")

-- errors carry the page's reason
local bad = Fetch.get("https://blocked.example/x")
states[bad] = { "error", 0, 0, "network error (offline, or the host does not allow browser requests)" }
st = Fetch.poll(bad)
eq(st.status, "error", "a refused request is an error")
check(tostring(st.err):find("browser requests", 1, true), "with the page's reason")

-- POST sends its body
local post = Fetch.post("https://example.com/log", "payload", { contentType = "text/plain" })
eq(started[post].method, "POST", "a post is a POST")
eq(started[post].body, "payload", "with its body")

-- cancel: the late result is dropped
local c = Fetch.get("https://example.com/slow")
Fetch.cancel(c)
land(c, "late")
st = Fetch.poll(c)
eq(st.status, "cancelled", "a cancelled job stays cancelled when its response lands")
eq(st.body, nil, "and keeps no body")
check(forgotten[c], "the page job is still forgotten")

-- every page fetch has a ceiling (Fetch never waits forever); the caller's
-- maxSeconds wins over the default
eq(started[get].timeoutMs, 120000, "a get without maxSeconds gets the default ceiling")
local quick = Fetch.download("https://example.com/t.png", "t.png", { maxSeconds = 15 })
eq(started[quick].timeoutMs, 15000, "maxSeconds becomes the page's timeout")
eq(started[quick].flags, 2, "a download fails on an empty body")
local rq = Fetch.request("https://example.com/api", { method = "PUT", body = "x" })
eq(started[rq].flags, 1, "a request keeps any HTTP status as a result")
eq(started[rq].method, "PUT", "and its method")

-- releasing a job still running in the page keeps it until it lands, so the
-- page job is forgotten and its temp file removed
local rel = Fetch.get("https://example.com/released")
Fetch.release(rel)
eq(Fetch.poll(rel).status, "cancelled", "a released in-flight job reads as cancelled")
land(rel, "late body")
Fetch.poll(rel)
check(forgotten[rel], "the page job is forgotten when it lands")
eq(io.open(started[rel].dest, "rb"), nil, "and its temp file removed")
eq(Fetch.poll(rel).err, "unknown job", "then the job is gone")

-- Platform: the browser can fetch remotely once the bridge has fetch
package.loaded["src.core.Platform"] = nil
local savedGetOS = love.system.getOS
love.system.getOS = function() return "Web" end
local Platform = require("src.core.Platform")
if Platform._resetForTests then Platform._resetForTests() end
check(Platform.canFetchRemote(), "Platform.canFetchRemote is true on Web with the fetch bridge")

-- GitHub release zips send no CORS headers: on Web the browser downloads
-- them itself (opened from the Install click) instead of a doomed fetch
local ModUpdate = require("src.mods.ModUpdate")
local REL = "https://github.com/someone/mod/releases/download/v1.0.1/MOD-1.0.1.zip"
check(ModUpdate.browserMustDownload(REL), "a GitHub release zip is a browser download on Web")
check(not ModUpdate.browserMustDownload("https://example.github.io/x/mod.zip"),
  "a host that allows CORS still downloads in the page")
local opened
love.system.openURL = function(url) opened = url; return true end
local before = 0
for _ in pairs(started) do before = before + 1 end
local h = ModUpdate.beginDownloadZip(REL, "mod.zip", 3584)
eq(opened, REL, "the browser is sent to the release zip")
check(h.browserDownload and h.err and h.err:find("Drop the .zip", 1, true),
  "and the handle carries the next step for the player")
local after = 0
for _ in pairs(started) do after = after + 1 end
eq(after, before, "no page fetch is started for it")
-- a pop-up the browser blocks (no click left to ride on) says so
love.system.openURL = function() return false end
local blocked = ModUpdate.beginDownloadZip(REL, "mod.zip", 3584)
check(blocked.err and blocked.err:find(REL, 1, true) and not blocked.err:find("opened", 1, true),
  "a blocked tab gives the link to download by hand instead")

love.system.getOS = savedGetOS
if Platform._resetForTests then Platform._resetForTests() end
check(not ModUpdate.browserMustDownload(REL), "desktop downloads release zips normally")

os.execute("rm -rf " .. TMP .. "/g1r_fetch_test_save")
T.finish()
