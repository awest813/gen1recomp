-- \x / \u{} escape scan for scripts/ci/lua51_compat.sh.
--
-- PUC Lua 5.1 reads "\xc3" as the text "xc3" with no error, so a hex or
-- unicode escape in a quoted string silently changes a string's bytes in the
-- browser build.  Only quoted strings matter: comments never run, and long
-- brackets ([[...]], [==[...]==]) take backslashes literally in every Lua.
-- This walks each file with a minimal lexer so those don't false-positive.
--
--   lua5.1 scripts/ci/lua_escape_scan.lua FILE...   (exit 1 on a hit)

local function longBracket(src, i)
  -- at "[": returns the level and the index after the opening bracket
  local eq = src:match("^%[(=*)%[", i)
  if eq then return #eq, i + #eq + 2 end
end

local function scan(path)
  local fh = io.open(path, "rb")
  if not fh then return {} end
  local src = fh:read("*a")
  fh:close()
  local hits, i, n, line = {}, 1, #src, 1
  while i <= n do
    local c = src:sub(i, i)
    if c == "\n" then
      line = line + 1
      i = i + 1
    elseif c == "-" and src:sub(i + 1, i + 1) == "-" then
      local level, after = longBracket(src, i + 2)
      local close
      if level then
        close = select(2, src:find("]" .. ("="):rep(level) .. "]", after, true))
      else
        close = src:find("\n", i, true)
        close = close and close - 1
      end
      close = close or n
      local _, nl = src:sub(i, close):gsub("\n", "")
      line = line + nl
      i = close + 1
    elseif c == "[" and longBracket(src, i) then
      local level, after = longBracket(src, i)
      local close = select(2, src:find("]" .. ("="):rep(level) .. "]", after, true)) or n
      local _, nl = src:sub(i, close):gsub("\n", "")
      line = line + nl
      i = close + 1
    elseif c == '"' or c == "'" then
      local j = i + 1
      while j <= n do
        local d = src:sub(j, j)
        if d == "\\" then
          local e = src:sub(j + 1, j + 1)
          if e:match("x") and src:sub(j + 2, j + 3):match("^%x%x$")
              or e == "u" and src:sub(j + 2, j + 2) == "{" then
            hits[#hits + 1] = line
          end
          if e == "\n" then line = line + 1 end
          j = j + 2
        elseif d == c or d == "\n" then
          break
        else
          j = j + 1
        end
      end
      i = j + 1
    else
      i = i + 1
    end
  end
  return hits
end

local bad = 0
for _, path in ipairs(arg) do
  for _, line in ipairs(scan(path)) do
    io.write("  ", path, ":", line, "\n")
    bad = bad + 1
  end
end
os.exit(bad == 0 and 0 or 1)
