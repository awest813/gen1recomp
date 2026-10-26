-- The two services the Box UI (BoxPanel, BoxUI, BoxTools, ...) needs from
-- whichever launcher hosts it: a button whose action runs after the frame,
-- and a centered modal panel.  A launcher that hosts the Box installs its own
-- with BoxHost.use(); until one does, the original launcher's are used.
--
-- BoxHost.kit is a host written for the PK:GB launcher (src/launcher/) on the
-- shared UI kit alone: its buttons queue their action through imp:queue().

local Kit = require("src.ui.kit.Kit")
local Theme = require("src.ui.kit.Theme")

local BoxHost = {}

local current

function BoxHost.use(host) current = host end

local function host()
  return current or require("src.import.LauncherView")
end

function BoxHost.btn(imp, x, y, w, h, key, label, opts)
  return host().btn(imp, x, y, w, h, key, label, opts)
end

function BoxHost.modalPanel(m, width, height, opts)
  return host().modalPanel(m, width, height, opts)
end

BoxHost.kit = {}

function BoxHost.kit.btn(imp, x, y, w, h, key, label, opts)
  opts = opts or {}
  opts.id = key
  if Kit.button(x, y, w, h, label, opts) and opts.action then
    imp:queue(opts.action, opts.keepArm)
  end
end

-- A panel `width` x `height` (shrunk to fit the window) centered over a scrim.
function BoxHost.kit.modalPanel(m, width, height, opts)
  opts = opts or {}
  local margin = math.floor(16 * (m.s or 1))
  local w = math.min(width, m.W - 2 * margin)
  local h = math.min(height, m.H - 2 * margin)
  local x, y = math.floor((m.W - w) / 2), math.floor((m.H - h) / 2)
  Theme.col(Theme.PAL.bg, opts.scrim or 0.7)
  love.graphics.rectangle("fill", 0, 0, m.W, m.H)
  Kit.card(x, y, w, h)
  return x, y, w, h
end

return BoxHost
