-- Platform capability detection for console, mobile and desktop builds.

local Platform = {}

local cached

local function compute()
  local osName = (love and love.system and love.system.getOS and love.system.getOS())
    or "Unknown"
  local nx = osName == "NX"
  local uwp = osName == "UWP"
  local mobile = osName == "Android" or osName == "iOS"
  -- love.js (LÖVE compiled to WebAssembly).  No processes, no threads to
  -- trust (the compat build has none), no self-update, and no curl: see
  -- docs/proposals/web-port.md.  Its file picker is the love.system.pickFile
  -- / getPickedFile bridge src/core/WebHost.lua installs from the native
  -- `lovejs` module, so it lands on the native-picker path below.
  local web = osName == "Web"
  local nativePicker = love and love.system
    and type(love.system.pickFile) == "function"
  local nativeHttp = love and love.system
    and type(love.system.httpDownload) == "function"
  return {
    os = osName,
    nx = nx,
    uwp = uwp,
    mobile = mobile,
    web = web,
    console = nx or uwp,
    -- love.thread workers are actually scheduled.  Every worker in the engine
    -- has a main-thread fallback, but most only take it when thread creation
    -- *fails*; a thread that starts and never runs would hang the caller, so
    -- the hosts without real threads opt out up front.
    hasThreads = not web,
    hasNativePicker = nativePicker,
    canSpawnProcess = osName == "OS X" or osName == "Windows" or osName == "Linux",
    romImportMode = nx and "save-directory"
      or (nativePicker and "native-picker")
      or "desktop",
    networkValidated = not nx and not uwp and not web,
    -- networkValidated is the self-updater's gate and stays a per-platform
    -- policy call: a console package cannot replace itself on disk, so that
    -- answer never depends on whether a transport exists.  Fetching a mod
    -- index or a mod zip is the narrower question, and #876 showed the two
    -- had been conflated, so Xbox lost the mod catalog for the updater's
    -- reason.  Desktop answers it with curl through HostShell; the mobile and
    -- console ports answer it with the native love.system.httpDownload bridge
    -- (#597).  The UWP LOVE backend does not export that bridge yet, so this
    -- still resolves false on Xbox and the launcher still says so, but the
    -- day the backend grows one, nothing here or in RomImporter has to change.
    canFetchRemote = (not nx and not uwp and not web) or nativeHttp,
    -- Picked files are scratch copies the host made for this one import, so
    -- the importer deletes them once read.  UWP copies into LocalState; the
    -- browser bridge writes into a non-persistent /tmp so a ROM never lands
    -- in IndexedDB.
    pickedFilesAreTemporary = uwp or web,
  }
end

function Platform.detect()
  if not cached then cached = compute() end
  return cached
end

function Platform.isNX()
  return Platform.detect().nx
end

function Platform.isUWP()
  return Platform.detect().uwp
end

function Platform.isWeb()
  return Platform.detect().web
end

function Platform.hasThreads()
  return Platform.detect().hasThreads
end

function Platform.pickedFilesAreTemporary()
  return Platform.detect().pickedFilesAreTemporary
end

function Platform.romImportMode()
  return Platform.detect().romImportMode
end

function Platform.canSpawnProcess()
  return Platform.detect().canSpawnProcess
end

function Platform.networkValidated()
  return Platform.detect().networkValidated
end

function Platform.canFetchRemote()
  return Platform.detect().canFetchRemote
end

-- Tests may swap love.system between cases.
function Platform._resetForTests()
  cached = nil
end

return Platform
