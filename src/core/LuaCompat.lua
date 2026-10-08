-- PUC Lua 5.1 shims: a 5.2-style load(), and a pcall that yields (below).
--
-- load():
--
-- LuaJIT (every native build) accepts load(string, name, mode, env).  PUC Lua
-- 5.1 -- what love.js runs in the browser, since there is no JIT in
-- WebAssembly -- only accepts a reader function there and raises
-- "bad argument #1 to 'load' (function expected, got string)".  The engine
-- calls the 5.2 form to sandbox generated cache modules (src/core/Data.lua and
-- the game3 chrome loaders), so on 5.1 every boot from the cache died.
--
-- install() is idempotent and a no-op where load already takes strings, so
-- conf.lua and main.lua can both call it without caring which ran first.  It
-- has zero requires so conf.lua can load it before anything else.

local LuaCompat = {}

local BINARY_SIGNATURE = "\27"

local function modeAllows(mode, chunk)
  if mode == nil then return true end
  local binary = chunk:sub(1, 1) == BINARY_SIGNATURE
  if binary and not mode:find("b", 1, true) then
    return false, ("attempt to load a binary chunk (mode is '%s')"):format(mode)
  end
  if not binary and not mode:find("t", 1, true) then
    return false, ("attempt to load a text chunk (mode is '%s')"):format(mode)
  end
  return true
end

-- Builds the 5.2-compatible load around the 5.1 primitives.  Exposed for the
-- tests, which run under LuaJIT and so never see install() take effect.
function LuaCompat.makeLoad(baseLoad, loadstring, setfenv)
  return function(chunk, chunkname, mode, env)
    local fn, err
    if type(chunk) == "string" then
      local ok, why = modeAllows(mode, chunk)
      if not ok then return nil, why end
      fn, err = loadstring(chunk, chunkname)
    else
      fn, err = baseLoad(chunk, chunkname)
    end
    if fn and env ~= nil then setfenv(fn, env) end
    return fn, err
  end
end

function LuaCompat.loadAcceptsStrings(G)
  G = G or _G
  return type(G.load) == "function" and (pcall(G.load, "return true"))
end

function LuaCompat.install(G)
  G = G or _G
  if LuaCompat.loadAcceptsStrings(G) then return false end
  if type(G.loadstring) ~= "function" or type(G.setfenv) ~= "function" then
    return false
  end
  G.load = LuaCompat.makeLoad(G.load, G.loadstring, G.setfenv)
  return true
end

-- Yield across pcall.  LuaJIT lets a coroutine yield from inside a pcall'd
-- function; PUC Lua 5.1 raises "attempt to yield across metamethod/C-call
-- boundary" instead.  yieldablePcall is pcall built from a coroutine (the
-- coxpcall pattern): the call runs in its own coroutine and every yield is
-- passed through to the caller's resumer and back, so code that reports
-- progress by yielding works under a pcall on both.  Costs a coroutine per
-- call, so callers swap it in only around such code (RomExtractorGen3:run).

local unpack = unpack or table.unpack
local function pack(...) return { n = select("#", ...), ... } end

local yieldsThroughPcall = nil

function LuaCompat.pcallYields()
  if yieldsThroughPcall == nil then
    local co = coroutine.create(function() return pcall(coroutine.yield, true) end)
    local ok, value = coroutine.resume(co)
    yieldsThroughPcall = ok and value == true
  end
  return yieldsThroughPcall
end

function LuaCompat.yieldablePcall(f, ...)
  -- coroutine.create needs a Lua function on 5.1
  local co = coroutine.create(function(...) return f(...) end)
  local res = pack(coroutine.resume(co, ...))
  while true do
    if not res[1] then return false, res[2] end
    if coroutine.status(co) == "dead" then return true, unpack(res, 2, res.n) end
    res = pack(coroutine.resume(co, coroutine.yield(unpack(res, 2, res.n))))
  end
end

-- `goto continue` on PUC Lua 5.1.  LuaJIT (every native build) accepts Lua
-- 5.2's goto, and community mods use it -- almost always as "skip to the next
-- loop iteration":
--     for i = 1, n do  if skip then goto continue end  ...  ::continue::  end
-- PUC Lua 5.1 (the browser build) rejects the whole file.  rewriteGoto turns
-- exactly that shape into its 5.1 equivalent and returns nil for anything
-- else, so the caller keeps the original compile error:
--     for i = 1, n do repeat  if skip then do break end end  ...  until true end
-- A real `break` in the same loop body becomes a flag that leaves the outer
-- loop after the inner repeat.  Edits are spliced in place with no newlines,
-- so line numbers in later errors still match the mod's file.  Only `for` and
-- `while` loops whose last statement is the label are handled (a repeat loop's
-- `until` can see body locals, which the wrapper would hide).

local KEYWORDS = {}
for w in ([[and break do else elseif end false for function goto if in local
  nil not or repeat return then true until while]]):gmatch("%a+") do KEYWORDS[w] = true end

local function longBracketAt(src, i)
  local eq = src:match("^%[(=*)%[", i)
  if not eq then return nil end
  local close = src:find("]" .. eq .. "]", i + #eq + 2, true)
  return close and (close + #eq + 1) or #src
end

-- tokens: { t = "name"|"kw"|"op"|"other", v = text, s = start, e = end }
local function tokenize(src)
  local toks, i, n = {}, 1, #src
  while i <= n do
    local c = src:sub(i, i)
    if c:match("%s") then
      i = i + 1
    elseif src:sub(i, i + 1) == "--" then
      local e = longBracketAt(src, i + 2)
      if not e then e = (src:find("\n", i, true) or (n + 1)) - 1 end
      i = e + 1
    elseif c == "[" and longBracketAt(src, i) then
      local e = longBracketAt(src, i)
      toks[#toks + 1] = { t = "other", v = "", s = i, e = e }
      i = e + 1
    elseif c == '"' or c == "'" then
      local j = i + 1
      while j <= n do
        local d = src:sub(j, j)
        if d == "\\" then j = j + 2
        elseif d == c or d == "\n" then break
        else j = j + 1 end
      end
      toks[#toks + 1] = { t = "other", v = "", s = i, e = j }
      i = j + 1
    elseif c:match("[%a_]") then
      local word = src:match("^[%w_]+", i)
      toks[#toks + 1] = { t = KEYWORDS[word] and "kw" or "name", v = word, s = i, e = i + #word - 1 }
      i = i + #word
    elseif c:match("%d") or (c == "." and src:sub(i + 1, i + 1):match("%d")) then
      local num = src:match("^0[xX]%x+", i) or src:match("^%d*%.?%d*[eE][%+%-]?%d+", i)
        or src:match("^%d*%.?%d*", i)
      toks[#toks + 1] = { t = "other", v = num, s = i, e = i + #num - 1 }
      i = i + #num
    else
      local op = src:match("^::", i) or src:match("^%.%.%.", i) or src:match("^%.%.", i)
        or src:match("^[=~<>]=", i) or c
      toks[#toks + 1] = { t = "op", v = op, s = i, e = i + #op - 1 }
      i = i + #op
    end
  end
  return toks
end

LuaCompat._tokenize = tokenize

function LuaCompat.rewriteGoto(src)
  if type(src) ~= "string" then return nil, "not a string" end
  if not (src:find("goto", 1, true) or src:find("::", 1, true)) then return nil, "no goto or label" end
  local toks = tokenize(src)
  -- A section is a block body that can end in a label: a loop or do body, or
  -- one branch of an if.  frames[k].sec is the frame's current section.
  local frames, headers, sections, gotos, breaks, labels = {}, {}, {}, {}, {}, {}
  local function newSection(frame, startTok)
    local sec = { frame = frame, start = startTok, labels = {} }
    frame.sec = sec
    sections[#sections + 1] = sec
    return sec
  end
  local function chain()
    local c = {}
    for k = #frames, 1, -1 do
      local f = frames[k]
      if f.kind == "function" then break end
      if f.sec then c[#c + 1] = f.sec end
      if f.kind == "repeat" then c[#c + 1] = { frame = f, labels = {} } end
    end
    return c
  end
  for idx, tk in ipairs(toks) do
    local v, prev = tk.v, toks[idx - 1]
    local afterDot = prev and prev.t == "op" and (prev.v == "." or prev.v == ":")
    if tk.t == "kw" and not afterDot then
      if v == "function" then
        frames[#frames + 1] = { kind = "function" }
      elseif v == "for" or v == "while" then
        headers[#headers + 1] = #frames
      elseif v == "do" then
        local loop = #headers > 0 and headers[#headers] == #frames
        if loop then headers[#headers] = nil end
        local f = { kind = loop and "loop" or "do" }
        frames[#frames + 1] = f
        newSection(f, idx)
      elseif v == "repeat" then
        frames[#frames + 1] = { kind = "repeat" }
      elseif v == "if" then
        frames[#frames + 1] = { kind = "if" }
      elseif v == "then" then
        local f = frames[#frames]
        if not (f and f.kind == "if") then return nil, "bail 42" end
        newSection(f, idx)
      elseif v == "elseif" or v == "else" then
        local f = frames[#frames]
        if not (f and f.kind == "if" and f.sec) then return nil, "bail 46" end
        f.sec.stop = idx
        f.sec = nil
        if v == "else" then newSection(f, idx) end
      elseif v == "end" then
        local f = table.remove(frames)
        if not f or f.kind == "repeat" then return nil, "bail 52" end
        if f.sec then f.sec.stop = idx end
      elseif v == "until" then
        local f = table.remove(frames)
        if not f or f.kind ~= "repeat" then return nil, "bail 56" end
      elseif v == "break" then
        breaks[#breaks + 1] = { tok = idx, chain = chain() }
      elseif v == "goto" then
        local name = toks[idx + 1]
        if not (name and name.t == "name") then return nil, "bail 61" end
        gotos[#gotos + 1] = { tok = idx, name = name.v, chain = chain() }
      end
    elseif tk.t == "op" and v == "::"
        and not (toks[idx - 2] and toks[idx - 2].v == "::" and prev.t == "name") then
      local name, close = toks[idx + 1], toks[idx + 2]
      if not (name and close and name.t == "name" and close.v == "::") then return nil, "bail 66" end
      local f = frames[#frames]
      if not (f and f.sec) then return nil, "bail 68" end   -- function / repeat level
      local label = { open = idx, name = name.v, sec = f.sec }
      f.sec.labels[name.v] = label
      labels[#labels + 1] = label
    end
  end
  if #frames ~= 0 then return nil, "bail 74" end
  local edits = {}
  local function edit(s, e, text) edits[#edits + 1] = { s = s, e = e, text = text } end
  local LOOP = { loop = true, ["repeat"] = true }
  for _, g in ipairs(gotos) do
    local target
    for _, sec in ipairs(g.chain) do
      local label = sec.labels[g.name]
      if label then
        -- a targeted label has to end its block for the wrapper to land there
        if sec.stop ~= label.open + 3 then return nil, "label not last" end
        target = sec
        break
      end
      -- leaving a loop: a `break` would stop there, not at the label
      if LOOP[sec.frame.kind] then return nil, "bail 87" end
    end
    if not target then return nil, "bail 89" end
    target.wrap = true
    edit(toks[g.tok].s, toks[g.tok + 1].e, "do break end")
  end
  local flags = 0
  for _, b in ipairs(breaks) do
    local crossed
    for _, sec in ipairs(b.chain) do
      if sec.wrap then
        if crossed then return nil, "bail 98" end   -- two wrappers to unwind
        crossed = sec
      end
      if LOOP[sec.frame.kind] then break end
    end
    if crossed then
      if not crossed.flag then flags = flags + 1; crossed.flag = "__g1r_brk" .. flags end
      edit(toks[b.tok].s, toks[b.tok].e, "do " .. crossed.flag .. " = true break end")
    end
  end
  -- labels go either way: a targeted one is replaced by the wrapper, an
  -- unused one is dead syntax 5.1 cannot parse
  for _, label in ipairs(labels) do
    edit(toks[label.open].s, toks[label.open + 2].e, "")
  end
  local any = #labels > 0
  for _, sec in ipairs(sections) do
    if sec.wrap then
      local open = toks[sec.start]
      edit(open.e + 1, open.e,
        (sec.flag and (" local " .. sec.flag .. " = false") or "") .. " repeat")
      local stop = toks[sec.stop]
      edit(stop.s, stop.s - 1,
        "until true " .. (sec.flag and ("if " .. sec.flag .. " then break end ") or ""))
    end
  end
  if not any then return nil, "bail 123" end
  table.sort(edits, function(x, y) return x.s > y.s end)
  local out = src
  for _, ed in ipairs(edits) do
    out = out:sub(1, ed.s - 1) .. ed.text .. out:sub(ed.e + 1)
  end
  return out
end

return LuaCompat
