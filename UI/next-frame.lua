-- Runs a function on the next frame, e.g. to rebuild UI from inside one of
-- its own controls' callbacks without destroying the control mid-callback.
-- Asking again under the same id before then replaces the function, so a
-- burst of requests runs once.
-- Usage:
--   local nextFrame = require("UI/next-frame")
--   nextFrame.Run("runeAuras_somethingRender", render)
--   nextFrame.Cancel("runeAuras_somethingRender")   -- e.g. on teardown

local nextFrame = {}

-- Event id -> the function waiting to run, and the Draw handler that runs
-- it (made once per id, so asking allocates nothing).
local pending = {}
local runners = {}

local function runner(eventID)
    local run = runners[eventID]
    if run == nil then
        run = function()
            Event.Draw.Unsubscribe(eventID)
            local fn = pending[eventID]
            pending[eventID] = nil
            if fn ~= nil then fn() end
        end
        runners[eventID] = run
    end
    return run
end

function nextFrame.Run(eventID, fn)
    pending[eventID] = fn
    Event.Draw.Subscribe(eventID, runner(eventID))
end

function nextFrame.Cancel(eventID)
    pending[eventID] = nil
    Event.Draw.Unsubscribe(eventID)
end

return nextFrame
