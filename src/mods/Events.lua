local Logger = require("src.core.Logger")

local Events = {}
Events.__index = Events

function Events.new()
  return setmetatable({ listeners = {} }, Events)
end

-- Listener lists are copy-on-write: on/unsubscribe/removeOwner build a new
-- list and swap it in, and never touch one in place.  An emit walks the list
-- it read at the start, so a listener retiring itself or a sibling
-- mid-dispatch is safe without emit copying the list first -- emit
-- allocates nothing, which matters for events fired every frame.

local function byPriority(a, b)
  if a.priority ~= b.priority then return a.priority > b.priority end
  return a.seq < b.seq
end
local seq = 0

-- the entries of `list` that `keep` accepts, as a new list; nil when none
local function without(list, keep)
  local out = {}
  for i = 1, #list do
    if keep(list[i]) then out[#out + 1] = list[i] end
  end
  if #out == 0 then return nil end
  return out
end

-- owner is the subscribing mod id; failures are attributed to it
function Events:on(name, callback, priority, owner)
  assert(type(name) == "string" and name ~= "", "event name is required")
  assert(type(callback) == "function", "event callback must be a function")
  seq = seq + 1
  local entry = { callback = callback, priority = tonumber(priority) or 0, owner = owner,
                  seq = seq }
  local old = self.listeners[name]
  local list = {}
  if old then for i = 1, #old do list[i] = old[i] end end
  list[#list + 1] = entry
  -- table.sort is not stable; the sequence number keeps subscription order
  -- among equal priorities
  table.sort(list, byPriority)
  self.listeners[name] = list
  return function()
    local live = self.listeners[name]
    if not live then return end
    -- an emptied name drops its key, as removeOwner does, so Runtime.wants
    -- stops telling hot call sites to build payloads for nobody
    self.listeners[name] = without(live, function(e) return e ~= entry end)
  end
end

-- retires itself after the first fire; safe to unsubscribe from inside the
-- dispatch because the list emit walks is never mutated
function Events:once(name, callback, priority, owner)
  assert(type(callback) == "function", "event callback must be a function")
  local unsubscribe
  unsubscribe = self:on(name, function(payload)
    unsubscribe()
    return callback(payload)
  end, priority, owner)
  return unsubscribe
end

-- a throwing listener is logged and skipped so the emitting engine path
-- always completes; the error never propagates
function Events:emit(name, payload)
  local list = self.listeners[name]
  if not list then return end
  for i = 1, #list do
    local entry = list[i]
    local ok, err = pcall(entry.callback, payload)
    if not ok then
      Logger.error("[%s] event %s: %s",
        tostring(entry.owner or "?"), name, tostring(err))
    end
  end
end

-- drops every subscription a mod made; used by entry-chunk rollback
function Events:removeOwner(owner)
  if owner == nil then return end
  local names = {}
  for name in pairs(self.listeners) do names[#names + 1] = name end
  for _, name in ipairs(names) do
    self.listeners[name] = without(self.listeners[name],
      function(e) return e.owner ~= owner end)
  end
end

-- deprecated no-op: subscription stays legal for the life of the process
function Events:seal() end

return Events
