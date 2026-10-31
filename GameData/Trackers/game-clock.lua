-- The game's clock: how far it is through the current server tick (0.6s),
-- so values that only change once a tick can be extrapolated between
-- ticks, plus the tick constants and timer rounding the trackers share.
-- There's no wall clock, so this counts client Logic ticks (event.logicTick)
-- between ServerLogic events and takes the median of the last few gaps as
-- the length of a server tick.

local gameClock = {}

-- The client's Logic ticks run at 50 a second; a server tick is 0.6s, kept
-- as a fraction so whole seconds stay exact (see TicksToSeconds).
gameClock.LOGIC_TICKS_PER_SECOND = 50
local TICK_SECONDS_NUMERATOR, TICK_SECONDS_DENOMINATOR = 6, 10
gameClock.SECONDS_PER_SERVER_TICK = TICK_SECONDS_NUMERATOR / TICK_SECONDS_DENOMINATOR
gameClock.LOGIC_TICKS_PER_SERVER_TICK = gameClock.LOGIC_TICKS_PER_SECOND * TICK_SECONDS_NUMERATOR // TICK_SECONDS_DENOMINATOR

--- Server ticks as seconds, exact for whole seconds (where * 0.6 can land
--- just off them). Whole seconds come back as integers so "$current"
--- doesn't read "6.0".
---@param ticks number
---@return number
function gameClock.TicksToSeconds(ticks)
    local seconds = ticks * TICK_SECONDS_NUMERATOR / TICK_SECONDS_DENOMINATOR
    return math.tointeger(seconds) or seconds
end

local TENTHS_PER_SECOND = 10
-- Taken off before rounding up, so a float's error just above a tenth
-- doesn't round up to the next one.
local ROUNDING_SLACK = 1e-9

--- Rounds up to a tenth of a second, so a timer reads like the game's own
--- and only reaches 0 once it's really over. Whole values come back as
--- integers so "$current" doesn't read "6.0".
---@param seconds number
---@return number
function gameClock.ToTenths(seconds)
    local tenths = math.ceil(seconds * TENTHS_PER_SECOND - ROUNDING_SLACK)
    return math.tointeger(tenths / TENTHS_PER_SECOND) or tenths / TENTHS_PER_SECOND
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

--- Records a measured server tick length and updates the median.
---@param measured integer Logic ticks between two server ticks.
local function addSample(measured)
    sampleIndex = sampleIndex % SAMPLE_COUNT + 1
    samples[sampleIndex] = measured
    local sorted = { table.unpack(samples) }
    table.sort(sorted)
    logicTicksPerServerTick = sorted[(#sorted + 1) // 2]
end

--- Starts following Logic and ServerLogic events. Call once, at load.
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

--- How far through the current server tick the game is.
---@return number fraction From 0 up to just under 1; 0 until a couple of ticks have been measured.
function gameClock.TickFraction()
    if logicTick == nil or logicTickAtServerTick == nil or logicTicksPerServerTick == nil then
        return 0
    end
    local fraction = (logicTick - logicTickAtServerTick) / logicTicksPerServerTick
    return math.max(0, math.min(MAX_FRACTION, fraction))
end

--- The latest client Logic tick. It changes 50 times a second, so values
--- derived from TickFraction can be cached until it does.
---@return integer? tick nil before the first Logic event.
function gameClock.LogicTick()
    return logicTick
end

--- How many server ticks have passed since loading. Lets per-frame code do
--- something once a tick, when once-a-tick values have just been refreshed.
---@return integer
function gameClock.ServerTicks()
    return serverTicks
end

--- Forgets the last tick, e.g. on leaving the game, so the gap until the
--- next one isn't measured. The samples are kept: the tick rate doesn't
--- change.
function gameClock.Reset()
    logicTickAtServerTick = nil
end

--- Stops following events.
function gameClock.Stop()
    Event.Logic.Unsubscribe(EVENT_ID)
    Event.ServerLogic.Unsubscribe(EVENT_ID)
end

return gameClock
