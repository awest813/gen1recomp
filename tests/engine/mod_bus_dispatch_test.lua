-- The mod event and hook buses (src/mods/Events.lua, src/mods/Hooks.lua)
-- keep their listener lists copy-on-write.  Pinned here:
--   * a hook link that unwraps itself mid-call no longer makes the call skip
--     the next link (an in-place table.remove used to shift it under the
--     walk);
--   * equal priorities dispatch in subscription order, every time;
--   * a non-number priority from a mod is treated as 0, not a sort crash;
--   * an emit allocates nothing per call (it used to copy the list).
--   luajit tests/engine/mod_bus_dispatch_test.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.harness")
local check, eq = T.check, T.eq

local Logger = require("src.core.Logger")
Logger.warn, Logger.error = function() end, function() end
local Events = require("src.mods.Events")
local Hooks = require("src.mods.Hooks")

-- ------- hooks: unwrap mid-call

do
  local hooks = Hooks.new()
  local seen = {}
  local unwrapA
  unwrapA = hooks:wrap("h", function(nextFn, x)
    seen[#seen + 1] = "a"
    unwrapA()
    return nextFn(x)
  end, 10, "a")
  hooks:wrap("h", function(nextFn, x)
    seen[#seen + 1] = "b"
    return nextFn(x + 1)
  end, 5, "b")
  local result = hooks:call("h", function(x) seen[#seen + 1] = "v" return x * 10 end, 1)
  eq(table.concat(seen, ","), "a,b,v", "a link unwrapping itself mid-call does not skip the next")
  eq(result, 20, "and the chain's result is intact")
  seen = {}
  hooks:call("h", function(x) seen[#seen + 1] = "v" return x end, 1)
  eq(table.concat(seen, ","), "b,v", "the unwrap holds for the next call")
  hooks:removeOwner("b")
  eq(hooks.chains.h, nil, "removing the last link drops the chain")
end

-- ------- order and priorities

do
  local events = Events.new()
  local order = {}
  for i = 1, 12 do
    events:on("e", function() order[#order + 1] = i end, 0, "m" .. i)
  end
  events:on("e", function() order[#order + 1] = 0 end, 1, "first")
  events:emit("e")
  eq(table.concat(order, ","), "0,1,2,3,4,5,6,7,8,9,10,11,12",
    "higher priority first, then subscription order among equals")

  local ok = pcall(events.on, events, "e", function() end, "high", "odd")
  check(ok, "a string priority does not crash the sort")
  local okH = pcall(Hooks.wrap, Hooks.new(), "h", function(n) return n() end, {}, "odd")
  check(okH, "nor on a hook")
end

-- ------- emit during subscribe/unsubscribe

do
  local events = Events.new()
  local fired = {}
  local off
  off = events:on("e", function()
    fired[#fired + 1] = "self"
    off()
    events:on("e", function() fired[#fired + 1] = "late" end)
  end)
  events:on("e", function() fired[#fired + 1] = "sibling" end)
  events:emit("e")
  eq(table.concat(fired, ","), "self,sibling",
    "an emit walks the list it started with: no skip, no late joiner")
  fired = {}
  events:emit("e")
  eq(table.concat(fired, ","), "sibling,late", "the next emit sees the changes")
  events:removeOwner(nil)
  local once = 0
  events:once("o", function() once = once + 1 end)
  events:emit("o")
  events:emit("o")
  eq(once, 1, "once fires once")
  eq(events.listeners.o, nil, "and leaves no empty list behind")
end

-- ------- emit allocates nothing

do
  local events = Events.new()
  local total = 0
  events:on("tick", function(n) total = total + n end)
  collectgarbage("collect")
  collectgarbage("stop")
  local before = collectgarbage("count")
  for i = 1, 20000 do events:emit("tick", i) end
  local grew = collectgarbage("count") - before
  collectgarbage("restart")
  check(grew < 64, ("20000 emits allocate (almost) nothing: %.1f KB"):format(grew))
  eq(total, 20000 * 20001 / 2, "and every one reached the listener")
end

T.finish("mod bus dispatch")
