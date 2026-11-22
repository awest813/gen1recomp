-- Why a pcall'd call failed, as a phrase for "Could not ...: <why>.":
-- the first line of a Lua error with its file:line taken off, or the reason
-- the call returned.  `pcall(fn)` gives ok, done, err; any may be missing.
return function(ok, done, err)
  local why
  if not ok then why = done else why = err end
  if why == nil or why == false or why == "" then return "it did not work" end
  return (tostring(why):match("^[^\n]*"):gsub("^[^:]*%.lua:%d+: ", ""):gsub("[%.%s]+$", ""))
end
