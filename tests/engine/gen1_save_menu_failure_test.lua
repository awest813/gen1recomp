package.path = "./?.lua;./?/init.lua;" .. package.path
local T = require("tests.modkit")
local Data = T.fixtures.fresh()
local SaveData = require("src.core.SaveData")
local StartMenu = require("src.ui.StartMenu")
local TextBox = require("src.render.TextBox")
local original = TextBox.new
TextBox.new = function(_, text, done, options)
  return {text=text, done=done, options=options or {}}
end
local function attempt(result, raised)
  local stack = {states={}}
  function stack:push(s) self.states[#self.states+1]=s end
  function stack:pop() return table.remove(self.states) end
  function stack:top() return self.states[#self.states] end
  local writes=0
  local game={data=Data, save=SaveData.newGame(), stack=stack}
  game.writeSave=function() writes=writes+1; if raised then error("disk unavailable") end; return result end
  local menu=StartMenu.new(game)
  stack:push(menu)
  for _,item in ipairs(menu.items) do if item.label=="SAVE" then item.onSelect(); break end end
  local panel=stack:top()
  panel.openPrompt()
  local prompt=stack:pop()
  prompt.options.choice(true)
  local saving=stack:pop()
  T.eq(saving.text,"Now saving...","saving hold precedes the write")
  saving.done()
  T.eq(writes,1,"confirmation attempts one write")
  return stack
end
for _,scenario in ipairs({{value=false},{raised=true},{}}) do
  local stack=attempt(scenario.value,scenario.raised)
  local failure=stack:pop()
  T.eq(failure.text,"SAVE failed.\nPlease try again.","failed or missing result never claims success")
  T.eq(failure.options.auto,nil,"failure stays visible until acknowledged")
  failure.done()
  T.eq(#stack.states,0,"acknowledging failure returns to gameplay")
end
local stack=attempt(true)
local success=stack:pop()
T.check(success.text:find("saved",1,true),"a confirmed write still shows success")
T.check(success.options.auto and success.options.auto.sound,"success retains the save sound")
success.done()
T.eq(#stack.states,0,"successful save closes its panels")
TextBox.new=original
T.finish("Gen 1 save menu failure feedback")
