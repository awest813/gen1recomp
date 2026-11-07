-- The in-app file browser, the ROM loading audit: a linked folder is listed;
-- a typed or pasted path opens a folder or picks a file; a letter jumps to
-- the next entry starting with it; Backspace in the folder it opened in no
-- longer closes it; X only cycles quick jumps that exist; and an empty
-- folder opens instead of jumping to the disk root.
--   luajit tests/engine/file_browser_audit_test.lua
package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.harness")
local check, eq = T.check, T.eq
love = love or require("tests.love_stub")

package.loaded["src.import.RomArchive"] = {
  capabilities = function() return { zip = true, z7 = false } end,
}
local FileBrowser = require("src.ui.kit.FileBrowser")

local root = os.tmpname()
os.remove(root)
os.execute("mkdir -p '" .. root .. "/roms/inner' '" .. root .. "/elsewhere'")
for _, name in ipairs({ "Blue.gb", "Gold.gbc", "Green.gb", "notes.txt" }) do
  local f = assert(io.open(root .. "/roms/" .. name, "wb")); f:write("x"); f:close()
end
os.execute("ln -s '" .. root .. "/elsewhere' '" .. root .. "/roms/linked'")

local picked
FileBrowser.open({ mode = "rom", initialPath = root .. "/roms", onSelect = function(p) picked = p end })
local names = {}
for _, e in ipairs(FileBrowser.entries) do names[e.name] = e.isDir and "dir" or "file" end
eq(names.linked, "dir", "a linked folder is listed as a folder")
eq(names["notes.txt"], nil, "a file that is not a ROM is hidden")

-- a letter jumps, and again to the next match
FileBrowser.selectedIdx = 1
FileBrowser.textinput("g")
local first = FileBrowser.entries[FileBrowser.selectedIdx].name
check(first:sub(1, 1) == "G", "G jumps to an entry starting with G")
FileBrowser.textinput("g")
local second = FileBrowser.entries[FileBrowser.selectedIdx].name
check(second:sub(1, 1) == "G" and second ~= first, "and G again to the next one")

-- Backspace where it opened does nothing; Esc still closes
FileBrowser.keypressed("backspace")
check(FileBrowser.active, "Backspace in the starting folder leaves it open")

-- a typed path
FileBrowser.goTo(root .. "/roms/inner")
eq(FileBrowser.currentDir, root .. "/roms/inner", "a typed folder opens")
FileBrowser.goTo(root .. "/nowhere")
check(FileBrowser.pathError and FileBrowser.pathError:find("was found", 1, true), "a missing one says so")
-- a bare name is in the folder on screen
FileBrowser.setDirectory(root .. "/roms")
FileBrowser.goTo("inner")
eq(FileBrowser.currentDir, root .. "/roms/inner", "a bare folder name opens inside the folder shown")
FileBrowser.setDirectory(root .. "/roms")
FileBrowser.goTo(root .. "/roms/notes.txt")
check(FileBrowser.active and FileBrowser.pathError:find("not one this can open", 1, true),
  "a file of the wrong kind is refused")
FileBrowser.goTo('"' .. root .. '/roms/Gold.gbc"')
eq(picked, root .. "/roms/Gold.gbc", "a pasted path in quotes picks the ROM")
check(not FileBrowser.active, "and closes the browser")

-- X: only places that exist
FileBrowser.open({ mode = "rom", initialPath = root .. "/roms" })
FileBrowser.places = { { label = "Here", path = root .. "/elsewhere" } }
FileBrowser.cycleShortcut()
eq(FileBrowser.currentDir, root .. "/elsewhere", "X goes to a place that exists")
FileBrowser.keypressed("escape")
check(not FileBrowser.active, "Esc closes")

-- an empty folder (only hidden files) opens where asked, not at the disk
-- root; a folder that is gone still falls back to the usual start
os.execute("mkdir -p '" .. root .. "/empty/.hidden'")
FileBrowser.open({ mode = "rom", initialPath = root .. "/empty" })
eq(FileBrowser.currentDir, root .. "/empty", "an empty folder opens, not the disk root")
eq(#FileBrowser.entries, 0, "and lists nothing")
FileBrowser.keypressed("escape")
local realStart = FileBrowser._startDir
FileBrowser._startDir = function() return root .. "/roms" end
FileBrowser.open({ mode = "rom", initialPath = root .. "/gone" })
eq(FileBrowser.currentDir, root .. "/roms", "a folder that is gone opens the usual start")
FileBrowser._startDir = realStart
FileBrowser.keypressed("escape")

os.execute("rm -rf '" .. root .. "'")
T.finish("file browser audit")
