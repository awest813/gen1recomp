local Logger = require("src.core.Logger")

local Hooks = {}
Hooks.__index = Hooks
local unpack = table.unpack or unpack

local function pack(...) return { n = select("#", ...), ... } end

-- errors raised below the chain (the vanilla function itself) must not be
-- attributed to a mod link or retried; they ride out wrapped under this key
-- so every guard re-raises instead of skipping
local PASS = {}

function Hooks.new()
  return setmetatable({ chains = {} }, Hooks)
end

-- Chains are copy-on-write, as Events' listener lists are: wrap, unwrap and
-- removeOwner swap in a new list and never edit one in place, so a call in
-- progress keeps walking the chain it started with even when a link unwraps
-- itself or a sibling mid-call (an in-place table.remove used to shift the
-- links the call had not reached yet, skipping one).

local function byPriority(a, b)
  if a.priority ~= b.priority then return a.priority > b.priority end
  return a.seq < b.seq
end
local seq = 0

local function keepOnly(chain, keep)
  local out = {}
  for i = 1, #chain do
    if keep(chain[i]) then out[#out + 1] = chain[i] end
  end
  -- an empty chain is dropped so Runtime.wantsHook goes back to false
  if #out == 0 then return nil end
  return out
end

-- owner is the wrapping mod id; failures are attributed to it
function Hooks:wrap(name, callback, priority, owner)
  assert(type(name) == "string" and name ~= "", "hook name is required")
  assert(type(callback) == "function", "hook callback must be a function")
  seq = seq + 1
  local entry = { callback = callback, priority = tonumber(priority) or 0,
                  owner = owner, seq = seq }
  local old = self.chains[name]
  local chain = {}
  if old then for i = 1, #old do chain[i] = old[i] end end
  chain[#chain + 1] = entry
  -- table.sort is not stable; seq keeps equal priorities in wrap order
  table.sort(chain, byPriority)
  self.chains[name] = chain
  return function()
    local live = self.chains[name]
    if not live then return end
    self.chains[name] = keepOnly(live, function(e) return e ~= entry end)
  end
end

-- vanilla's pcall results, unpacked without a pack table: its values, or
-- the PASS-wrapped error
local function vanillaResult(ok, ...)
  if ok then return ... end
  error({ [PASS] = (...) }, 0)
end

-- the outermost pcall's results: the chain's values, or its error unwrapped
local function finish(ok, ...)
  if ok then return ... end
  local err = (...)
  if type(err) == "table" and err[PASS] ~= nil then error(err[PASS], 0) end
  error(err, 0)
end

-- each link runs under pcall: a throwing wrapper is logged and skipped and
-- the chain continues with the current arguments, so a broken mod degrades
-- to "not installed for this call" instead of breaking the pipeline.
-- vanilla must run at most once per call -- it has side effects -- so a link
-- that throws after its next() returned keeps the downstream results (its
-- post-processing is discarded) rather than re-walking the chain, and a link
-- that swallowed a vanilla error then threw propagates instead of retrying
function Hooks:call(name, vanilla, ...)
  local chain = self.chains[name]
  if not chain or #chain == 0 then return vanilla(...) end
  local args = pack(...)
  local ranVanilla = false
  local function run(index)
    if index > #chain then
      ranVanilla = true
      return vanillaResult(pcall(vanilla, unpack(args, 1, args.n)))
    end
    local entry = chain[index]
    local downstream
    local function nextFn(...)
      if select("#", ...) == 0 then
        downstream = pack(run(index + 1))
      else
        local saved = args
        args = pack(...)
        downstream = pack(run(index + 1))
        args = saved
      end
      return unpack(downstream, 1, downstream.n)
    end
    local res = pack(pcall(entry.callback, nextFn, unpack(args, 1, args.n)))
    if res[1] then return unpack(res, 2, res.n) end
    local err = res[2]
    if type(err) == "table" and err[PASS] ~= nil then error(err, 0) end
    if downstream ~= nil then
      Logger.warn("[%s] hook %s failed after next: %s -- downstream result kept",
        tostring(entry.owner or "?"), name, tostring(err))
      return unpack(downstream, 1, downstream.n)
    end
    if ranVanilla then
      Logger.warn("[%s] hook %s failed: %s -- vanilla already ran, not retried",
        tostring(entry.owner or "?"), name, tostring(err))
      error({ [PASS] = err }, 0)
    end
    Logger.warn("[%s] hook %s failed: %s -- link skipped",
      tostring(entry.owner or "?"), name, tostring(err))
    return run(index + 1)
  end
  return finish(pcall(run, 1))
end

-- drops every wrap a mod made; used by entry-chunk rollback
function Hooks:removeOwner(owner)
  if owner == nil then return end
  local names = {}
  for name in pairs(self.chains) do names[#names + 1] = name end
  for _, name in ipairs(names) do
    self.chains[name] = keepOnly(self.chains[name],
      function(e) return e.owner ~= owner end)
  end
end

-- deprecated no-op: wrapping stays legal for the life of the process
function Hooks:seal() end

return Hooks
