function love.run()
  _G.POKEPORT_LOOP_RESTART = true
  if love.load then love.load(love.arg.parseGameArguments(arg), arg) end

  -- don't let love.load's cost land in the first frame's dt
  if love.timer then love.timer.step() end

  local FrameCap = require("src.core.FrameCap")
  -- In the browser love.js drives this function from requestAnimationFrame,
  -- which already paces presentation to the display.  love.timer.sleep there
  -- busy-waits the page's only thread, and PresentSync's vsync probing has
  -- nothing to measure. Numeric caps skip drawing until their deadline;
  -- events and updates still run on every callback. FixedStep keeps game
  -- logic at 60 Hz regardless of the selected render rate.
  local web = WebHost.isWeb()
  local webPacer = web and require("src.core.WebFramePacer").new()
  local renderStats = false
  local profile = { updates = 0, updateMs = 0, worstUpdateMs = 0,
    draws = 0, drawMs = 0, worstDrawMs = 0 }
  if web then
    for _, value in pairs(arg or {}) do
      if value == "--renderstats" then renderStats = true end
    end
  end
  _G.POKEPORT_LOOP_PANEL_SYNC = not web
  if not web then FrameCap.bootPanelSync() end
  local RefreshRate = require("src.core.RefreshRate")
  local FixedStep = require("src.core.FixedStep")
  local VSync = require("src.core.VSync")
  local PresentSync = require("src.core.PresentSync")
  local paced = pacingEnabled() and not web
  -- The deadline the next present() should not beat.  Carried forward one
  -- budget per frame so pacing stays even instead of drifting with the
  -- per-frame sleep-granularity jitter.
  local nextFrame = love.timer and love.timer.getTime() or 0
  local dt = 0
  local idleFor = 0
  local SLEEP_FLOOR = 0.001
  -- Sleep until deadline with one or two kernel waits, not 1 ms polling.
  local function sleepUntilFrame(deadline)
    while true do
      local remaining = deadline - love.timer.getTime()
      if remaining <= SLEEP_FLOOR then break end
      if remaining > 0.004 then
        love.timer.sleep(remaining - 0.002)
      else
        love.timer.sleep(remaining)
      end
    end
  end
  local WAKE = {
    keypressed = true, keyreleased = true, textinput = true,
    mousepressed = true, mousereleased = true, mousemoved = true,
    wheelmoved = true, touchpressed = true, touchreleased = true,
    touchmoved = true, joystickpressed = true, joystickreleased = true,
    joystickhat = true, gamepadpressed = true, gamepadreleased = true,
    joystickadded = true, joystickremoved = true, filedropped = true,
    directorydropped = true, focus = true, visible = true, resize = true,
  }

  return function()
    -- process events
    if love.event then
      love.event.pump()
      for name, a, b, c, d, e, f in love.event.poll() do
        if name == "quit" then
          if not love.quit or not love.quit() then
            -- Android keeps the process and its task alive after LOVE's own
            -- teardown, so the relaunched task re-enters an activity whose
            -- native main already returned; end the process outright once the
            -- love.quit hook has run (#339)
            if a ~= "restart" and love.system and love.system.getOS() == "Android" then
              os.exit(a or 0)
            end
            return a or 0
          end
        end
        if WAKE[name] then
          idleFor = 0
        elseif name == "joystickaxis" and type(c) == "number" and math.abs(c) > 0.5 then
          idleFor = 0
        end
        if name == "focus" and a then
          PresentSync.onDisplayChange()
        elseif name == "resize" then
          PresentSync.onDisplayChange()
        end
        love.handlers[name](a, b, c, d, e, f)
      end
    end

    -- update dt
    if love.timer then dt = love.timer.step() end
    -- Pace Web against callback arrival, before variable update/storage work.
    -- Sampling after updates can miss an otherwise on-time RAF deadline and
    -- alternate 16/50 ms presents even when the frame fits its budget.
    local frameStarted = web and love.timer and love.timer.getTime() or 0
    idleFor = idleFor + dt
    RefreshRate.sample(dt)

    checkEmergencyQuit(dt)

    -- call update and draw
    if web then
      -- per-frame audio bookkeeping (src/core/ChipAudio.lua beginFrame);
      -- only once the game has loaded the module
      local chip = package.loaded["src.core.ChipAudio"]
      if chip and chip.beginFrame then chip.beginFrame() end
    end
    local updateStarted = renderStats and love.timer.getTime()
    if love.update then love.update(dt) end
    WebHost.update(dt)
    if updateStarted then
      local ms = (love.timer.getTime() - updateStarted) * 1000
      profile.updates = profile.updates + 1
      profile.updateMs = profile.updateMs + ms
      profile.worstUpdateMs = math.max(profile.worstUpdateMs, ms)
    end

    local visible = not (love.window and love.window.isVisible)
      or love.window.isVisible()
    local focused = not (love.window and love.window.hasFocus)
      or love.window.hasFocus()
    local cap = FrameCap.current
    if not visible then
      cap = 10
    elseif Importer and (not focused or idleFor > 30) then
      cap = 15
    else
      local idleCap = idlePresentationCap(idleFor)
      if idleCap then cap = idleCap end
    end
    if not web and cap == FrameCap.DISPLAY and not VSync.isOn() then
      cap = FrameCap.DEFAULT
    elseif not web and cap == FrameCap.DISPLAY and PresentSync.needsSoftwareCap() then
      -- Fallback cascade: probe failed / wait abandoned / sync non-
      -- deterministic â†’ FrameCap is the live pacing path on every OS.
      -- (During an active probe we intentionally leave DISPLAY uncapped so
      -- calibration is not grading our own limiter.)
      cap = FrameCap.DEFAULT
    end

    local renderDue = not web or webPacer:due(frameStarted, cap)
    if visible and renderDue and love.graphics and love.graphics.isActive() then
      local drawStarted = renderStats and love.timer.getTime()
      love.graphics.origin()
      love.graphics.clear(love.graphics.getBackgroundColor())
      if love.draw then love.draw() end
      if not web then PresentSync.waitBeforePresent() end
      love.graphics.present()
      if web and renderStats then
        local ms = (love.timer.getTime() - drawStarted) * 1000
        profile.draws = profile.draws + 1
        profile.drawMs = profile.drawMs + ms
        profile.worstDrawMs = math.max(profile.worstDrawMs, ms)
        local fps, timing = webPacer:presented(love.timer.getTime())
        if fps then
          print(string.format("[web-render] %.1f fps cap=%s", fps,
            cap == 0 and "UNLOCKED" or tostring(cap)))
          print(string.format("[web-frame-time] mean %.2fms worst %.2fms; late %d/%d",
            timing.meanMs, timing.maxMs, timing.late, timing.frames))
          print(string.format("[web-profile] update %.2fms worst %.2fms; draw %.2fms worst %.2fms",
            profile.updateMs / math.max(1, profile.updates), profile.worstUpdateMs,
            profile.drawMs / math.max(1, profile.draws), profile.worstDrawMs))
          profile = { updates = 0, updateMs = 0, worstUpdateMs = 0,
            draws = 0, drawMs = 0, worstDrawMs = 0 }
        end
      end
      if not web then PresentSync.notePresent() end
    end

    if not web then PresentSync.applyFixedStepPeriod() end

    if love.timer and not web then
      if paced and cap ~= FrameCap.DISPLAY and not PresentSync.hardwarePacesCap(cap) then
        -- Sleep out the remainder of the frame budget, measured from the
        -- carried deadline.  When vsync already gates at or above the cap,
        -- hardwarePacesCap skips this entirely.  Otherwise one kernel sleep
        -- covers the bulk; only the last couple ms re-check for overshoot.
        local budget = 1 / cap
        nextFrame = nextFrame + budget
        local now = love.timer.getTime()
        -- A stall (alt-tab, a GC pause, a blocked import) can leave the
        -- deadline more than a full budget in the past; re-anchor to now so
        -- we pace the next frame rather than burst uncapped to catch up.
        if now - nextFrame > budget then
          nextFrame = now
        end
        sleepUntilFrame(nextFrame)
      else
        love.timer.sleep(0.001)
      end
    end
  end
end
