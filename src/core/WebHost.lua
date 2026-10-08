-- Browser (love.js) host glue.  See docs/proposals/web-port.md and ports/web/.
--
-- Everything here is a no-op off the web, so main.lua calls it
-- unconditionally.  Three jobs:
--
--   * Bridge.  The custom love.js build preloads a native `lovejs` module
--     (ports/web/native/lovejs_bridge.cpp).  install() copies its picker
--     functions onto love.system under the names the UWP picker bridge
--     already uses (pickFile / getPickedFile / getPickError / pickFileKinds),
--     so RomImporter's native-picker path drives the browser's file input
--     without knowing it is on the web.  It must run before anything calls
--     Platform.detect(), which caches whether love.system.pickFile exists.
--
--   * Storage.  love.js keeps the save directory on an IndexedDB-backed
--     filesystem but only flushes it on page load and beforeunload, which a
--     closed tab or a crash can skip.  install() wraps the write entry points
--     (io.open for writing, os.remove/rename, love.filesystem.write/append/
--     remove/createDirectory, and File write/flush/close) to mark the store
--     dirty, and update() flushes
--     it shortly after the writes stop -- one sync per import, save or
--     options change instead of one per file.
--
--   * Drops.  SDL's emscripten backend has no file-drop support, so the page
--     shell catches drops itself, writes them under /tmp and queues the path;
--     update() turns each into a love.filedropped call with a DroppedFile-
--     shaped object.

local WebHost = {}

local SYNC_DEBOUNCE = 0.75   -- seconds after the last write
local SYNC_MAX_DELAY = 5     -- never hold a dirty store longer than this

-- captured before install() wraps os.remove: deleting a consumed /tmp drop is
-- not a save-directory write and must not schedule a sync
local rawRemove = os.remove

local bridge = nil
local installed = false
local dirty = false
local quietFor = 0
local dirtyFor = 0
local syncs = 0

function WebHost.isWeb()
  return love ~= nil and love.system ~= nil and love.system.getOS ~= nil
    and love.system.getOS() == "Web"
end

-- the page's close-tab prompt needs to know about writes still waiting for
-- their debounced sync, not just a sync already running (index.html)
local function publishDirty(value)
  if bridge and type(bridge.setDirty) == "function" then pcall(bridge.setDirty, value) end
end

local function markDirty()
  if not dirty then
    dirtyFor = 0
    publishDirty(true)
  end
  dirty = true
  quietFor = 0
end

WebHost.markDirty = markDirty

local function writesMode(mode)
  return type(mode) == "string" and mode:find("[wa+]") ~= nil
end

-- Wrap fn so calling it marks the store dirty (when pred allows).
local function dirtying(fn, pred)
  return function(...)
    if not pred or pred(...) then markDirty() end
    return fn(...)
  end
end

-- /tmp is MEMFS (picks, drops, scratch), never persisted: touching it needs
-- no IndexedDB sync, and every sync walks the whole persisted store
local function persistent(path)
  return type(path) ~= "string" or path:sub(1, 5) ~= "/tmp/"
end

local function wrapWrites()
  if io and io.open then
    io.open = dirtying(io.open, function(path, mode)
      return writesMode(mode) and persistent(path)
    end)
  end
  if os then
    if os.remove then os.remove = dirtying(os.remove, persistent) end
    if os.rename then
      os.rename = dirtying(os.rename, function(from, to)
        return persistent(from) or persistent(to)
      end)
    end
  end
  local fs = love.filesystem
  if fs then
    for _, name in ipairs({ "write", "append", "remove", "createDirectory" }) do
      if type(fs[name]) == "function" then fs[name] = dirtying(fs[name]) end
    end
    -- Streamed writes (CacheFs.openWrite: newFile + open("w") + write...) go
    -- through File methods, which every File shares via its type metatable;
    -- patch those once, on the first File created.
    if type(fs.newFile) == "function" then
      local newFile = fs.newFile
      local patched = false
      fs.newFile = function(...)
        local file, err = newFile(...)
        if file and not patched then
          patched = true
          local mt = getmetatable(file)
          local methods = mt and (type(mt.__index) == "table" and mt.__index or mt)
          if type(methods) == "table" then
            for _, name in ipairs({ "write", "flush" }) do
              if type(methods[name]) == "function" then
                methods[name] = dirtying(methods[name])
              end
            end
            if type(methods.close) == "function" then
              methods.close = dirtying(methods.close, function(self)
                local ok, mode = pcall(self.getMode, self)
                return not ok or mode ~= "r"
              end)
            end
          end
        end
        return file, err
      end
    end
  end
end

local PICKER_FUNCTIONS = { "pickFile", "getPickedFile", "getPickError", "pickFileKinds" }

-- opts.bridge / opts.force are for the tests (no love.js there).
function WebHost.install(opts)
  opts = opts or {}
  if installed then return bridge ~= nil end
  if not opts.force and not WebHost.isWeb() then return false end
  installed = true
  local mod = opts.bridge
  if mod == nil then
    local ok, loaded = pcall(require, "lovejs")
    mod = ok and type(loaded) == "table" and loaded or nil
  end
  bridge = mod
  if bridge then
    for _, name in ipairs(PICKER_FUNCTIONS) do
      if type(bridge[name]) == "function" and love.system[name] == nil then
        love.system[name] = bridge[name]
      end
    end
  end
  wrapWrites()
  return bridge ~= nil
end

function WebHost.hasBridge()
  return bridge ~= nil
end

-- Open a URL in a new browser tab.  False when the browser would block the
-- pop-up (only allowed during a click or key press's user activation) or off
-- the web.
function WebHost.openURL(url)
  if bridge and type(bridge.openURL) == "function" then
    local ok, opened = pcall(bridge.openURL, url)
    return ok and opened == true
  end
  return false
end

-- The bridge's browser fetch() transport (fetchStart/fetchPoll/fetchForget),
-- or nil.  src/net/Fetch.lua routes its jobs here on the web.
function WebHost.fetchBridge()
  if bridge and type(bridge.fetchStart) == "function"
      and type(bridge.fetchPoll) == "function" then
    return bridge
  end
  return nil
end

function WebHost.syncNow()
  if dirty then publishDirty(false) end
  dirty = false
  quietFor, dirtyFor = 0, 0
  if bridge and type(bridge.syncStorage) == "function" then
    syncs = syncs + 1
    pcall(bridge.syncStorage)
    return true
  end
  return false
end

-- Offer a file in the save directory (an absolute MEMFS path) to the player
-- as a browser download -- the save directory itself is invisible in a
-- browser.  Returns false off the web or when the bridge lacks it.
function WebHost.download(path, name)
  if not (bridge and type(bridge.downloadFile) == "function") then return false end
  local ok, started = pcall(bridge.downloadFile, path,
    name or tostring(path):match("[^/\\]+$") or "download")
  return ok and started == true
end

function WebHost.syncCount()
  return syncs
end

-- A minimal DroppedFile stand-in over an absolute MEMFS path: the subset
-- RomImporter's drop handlers use (readDroppedFile, the extension routing).
local function droppedFile(path)
  local handle = nil
  local f = {}
  function f:getFilename() return path end
  function f:open(mode)
    local err
    handle, err = io.open(path, (mode == "w" or mode == "a") and mode .. "b" or "rb")
    if not handle then return false, err end
    return true
  end
  function f:getSize()
    local h = handle or io.open(path, "rb")
    if not h then return 0 end
    local here = h:seek()
    local size = h:seek("end")
    h:seek("set", here)
    if h ~= handle then h:close() end
    return size or 0
  end
  function f:read(n)
    if not handle then return nil, "file is not open" end
    local data = handle:read(n or "*a") or ""
    return data, #data
  end
  function f:close()
    if handle then handle:close() handle = nil end
    return true
  end
  function f:isOpen() return handle ~= nil end
  function f:typeOf(name) return name == "File" or name == "DroppedFile" or name == "Object" end
  return f
end

WebHost._droppedFile = droppedFile

function WebHost.update(dt)
  if not installed then return end
  dt = dt or 0
  if bridge and type(bridge.getDroppedFile) == "function" then
    local path = bridge.getDroppedFile()
    if path and love.handlers and love.handlers.filedropped then
      local file = droppedFile(path)
      -- the /tmp copy goes away even when the handler throws; the error
      -- itself still reaches the game's crash handling
      local ok, err = pcall(love.handlers.filedropped, file)
      file:close()
      rawRemove(path)
      if not ok then error(err, 0) end
    end
  end
  if dirty then
    quietFor = quietFor + dt
    dirtyFor = dirtyFor + dt
    if quietFor >= SYNC_DEBOUNCE or dirtyFor >= SYNC_MAX_DELAY then
      WebHost.syncNow()
    end
  end
end

function WebHost.isDirty()
  return dirty
end

-- Tests only.
function WebHost._resetForTests()
  bridge, installed, dirty = nil, false, false
  quietFor, dirtyFor, syncs = 0, 0, 0
end

return WebHost
