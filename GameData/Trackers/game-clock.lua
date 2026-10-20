-- Estimates how far the game is through the current server tick (0.6s), so
-- values that only change once a tick can be extrapolated between ticks.
-- There's no wall clock, so this counts client Logic ticks (event.logicTick)
-- between ServerLogic events and takes the median of the last few gaps as
-- the length of a server tick.
-- Usage:
--   local gameClock = require("GameData/Trackers/game-clock")
--   gameClock.Start()            -- once, at load
--   gameClock.Reset()            -- on leaving the game
--   gameClock.TickFraction()     --> 0 to just under 1

local gameClock = {}

local EVENT_ID = "runeAuras_gameClock"
-- Gaps measured for the median. A median shrugs off the odd hitch or
-- bunched-up ticks, yet follows a real change in rate within a few ticks,
-- where rejecting outliers could lock onto a bad first sample.
local SAMPLE_COUNT = 9
-- Never run into the next tick before the server says it has started.
local MAX_FRACTION = 0.99

local logicTick = nil
local logicTickAtServerTick = nil
local logicTicksPerServerTick = nil
-- The last SAMPLE_COUNT gaps, written round-robin.
local samples = {}
local sampleIndex = 0

local function addSample(measured)
    sampleIndex = sampleIndex % SAMPLE_COUNT + 1
    samples[sampleIndex] = measured
    local sorted = { table.unpack(samples) }
    table.sort(sorted)
    logicTicksPerServerTick = sorted[(#sorted + 1) // 2]
end

function gameClock.Start()
    Event.Logic.Subscribe(EVENT_ID, function(event)
        logicTick = event.logicTick
    end)
    Event.ServerLogic.Subscribe(EVENT_ID, function()
        if logicTick == nil then return end
        if logicTickAtServerTick ~= nil then
            local measured = logicTick - logicTickAtServerTick
            -- Two server ticks handled in one logic tick tell us nothing.
            if measured > 0 then addSample(measured) end
        end
        logicTickAtServerTick = logicTick
    end)
end

-- How far through the current server tick the game is, from 0 up to just
-- under 1. 0 until a couple of ticks have been measured.
function gameClock.TickFraction()
    if logicTick == nil or logicTickAtServerTick == nil or logicTicksPerServerTick == nil then
        return 0
    end
    local fraction = (logicTick - logicTickAtServerTick) / logicTicksPerServerTick
    return math.max(0, math.min(MAX_FRACTION, fraction))
end

-- The latest client Logic tick, or nil before the first Logic event. It
-- changes 50 times a second, so values derived from TickFraction can be
-- cached until it does.
function gameClock.LogicTick()
    return logicTick
end

-- Forgets the last tick, e.g. on leaving the game, so the gap until the next
-- one isn't measured. The samples are kept: the tick rate doesn't change.
function gameClock.Reset()
    logicTickAtServerTick = nil
end

function gameClock.Stop()
    Event.Logic.Unsubscribe(EVENT_ID)
    Event.ServerLogic.Unsubscribe(EVENT_ID)
end

return gameClock
