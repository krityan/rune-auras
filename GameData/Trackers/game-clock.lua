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
--   gameClock.ToTenths(seconds)  --> rounded up to a tenth

local gameClock = {}

-- The client's Logic ticks run at 50 a second; a server tick is 0.6s.
gameClock.LOGIC_TICKS_PER_SECOND = 50
gameClock.SECONDS_PER_SERVER_TICK = 0.6

-- Rounds up to a tenth of a second, so a timer reads like the game's own
-- and only reaches 0 once it's really over. Whole values come back as
-- integers so "$current" doesn't read "6.0".
function gameClock.ToTenths(seconds)
    local tenths = math.ceil(seconds * 10 - 1e-9)
    return math.tointeger(tenths / 10) or tenths / 10
end

local EVENT_ID = "runeAuras_gameClock"
-- Gaps measured for the median. A median shrugs off the odd hitch or
-- bunched-up ticks, yet follows a real change in rate within a few ticks,
-- where rejecting outliers could lock onto a bad first sample.
local SAMPLE_COUNT = 9
-- Never run into the next tick before the server says it has started.
local MAX_FRACTION = 0.99

local logicTick = nil
-- ServerLogic events seen since loading.
local serverTicks = 0
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
        serverTicks = serverTicks + 1
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

-- How many server ticks have passed since loading. Lets per-frame code do
-- something once a tick, when once-a-tick values have just been refreshed.
function gameClock.ServerTicks()
    return serverTicks
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
