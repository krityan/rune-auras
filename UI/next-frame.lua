-- Runs a function on the next frame, e.g. to rebuild UI from inside one of
-- its own controls' callbacks without destroying the control mid-callback.

local nextFrame = {}

-- Event id to the function waiting to run.
local pending = {}
-- Event id to the Draw handler that runs it, made once per id, so asking
-- allocates nothing.
local runners = {}

--- The Draw handler for an id: it unsubscribes, then runs what's pending.
---@param eventID string
---@return fun()
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

--- Runs a function on the next frame. Asking again under the same id before
--- then replaces the function, so a burst of requests runs once.
---@param eventID string E.g. "runeAuras_somethingRender".
---@param fn fun()
function nextFrame.Run(eventID, fn)
    pending[eventID] = fn
    Event.Draw.Subscribe(eventID, runner(eventID))
end

--- Drops a function waiting under an id, e.g. on teardown.
---@param eventID string
function nextFrame.Cancel(eventID)
    pending[eventID] = nil
    Event.Draw.Unsubscribe(eventID)
end

return nextFrame
