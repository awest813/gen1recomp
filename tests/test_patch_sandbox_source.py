"""Released mod source encoding across browser Lua and native LuaJIT."""
import unittest
from lupa.lua51 import LuaRuntime as Lua51
from lupa.luajit21 import LuaRuntime as LuaJIT


class SandboxSourceTests(unittest.TestCase):
    def test_bom_source_retains_environment_and_bytecode_rejection(self):
        for runtime in (Lua51, LuaJIT):
            with self.subTest(runtime=runtime.__module__):
                lua = runtime()
                lua.execute(r'''
                  local Sandbox = require("src.mods.Sandbox")
                  local bom = string.char(239,187,191)
                  local env = {value=42}
                  local chunk = assert(Sandbox.compile(bom.."return value", "@bom.lua", env))
                  assert(chunk()==42, "BOM source must retain sandbox environment")
                  local bytecode = string.dump(function() return 1 end)
                  for _,source in ipairs({bytecode,bom..bytecode}) do
                    local denied,err=Sandbox.compile(source,"@denied.lua",env)
                    assert(not denied and err:find("not bytecode",1,true))
                  end
                  assert(assert(Sandbox.compile('return "inside'..bom..'"',"@literal.lua",env))()=="inside"..bom,
                    "only a leading BOM is removed")
                  local calls=0
                  local fs={read=function() return bom.."return value" end,
                    load=function() calls=calls+1; error("must normalize first") end}
                  assert(assert(Sandbox.loadFile(fs,"bom.lua",env))()==42)
                  assert(calls==0)
                  fs.read=function() return bom..bytecode end
                  local denied,err=Sandbox.loadFile(fs,"denied.lua",env)
                  assert(not denied and err:find("not bytecode",1,true) and calls==0)
                  fs.read=function() return "return value" end
                  fs.load=function() calls=calls+1; return assert(loadstring("return value")) end
                  assert(assert(Sandbox.loadFile(fs,"plain.lua",env))()==42)
                  assert(calls==1,"ordinary files retain filesystem loader")
                ''')


if __name__ == "__main__":
    unittest.main()
