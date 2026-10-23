-- Reads ability cooldowns from game vars.
-- Each ability has a VarPlayer pair COMBATV2_COOLDOWN_<SKILL>_<ABILITY>_START
-- and _END holding the server tick it was used on and the tick it comes
-- off cooldown. Nothing exposes the current server
-- tick, so this keeps its own: it counts ServerLogic events (one per tick)
-- and lines that count up with the server whenever a _START var changes,
-- since a fresh _START is "now". Until the first ability use after loading
-- or entering the game, an ability that is still on cooldown can't be timed.
-- Usage:
--   local abilityCooldowns = require("GameData/Trackers/ability-cooldowns")
--   abilityCooldowns.Start()   -- once, at load
--   abilityCooldowns.Reset()   -- on leaving the game
--   abilityCooldowns.GetCooldown("COMBATV2_COOLDOWN_STRENGTH_BERSERK")
--     --> remaining, total, unroundedRemaining

local gameClock = require("GameData/Trackers/game-clock")
local gameApi = require("GameData/game-api")

local abilityCooldowns = {}

local EVENT_ID = "runeAuras_abilityCooldowns"
-- A tick is 0.6 seconds; kept as a fraction so whole seconds stay exact.
local TICK_SECONDS_NUMERATOR, TICK_SECONDS_DENOMINATOR = 6, 10
-- Entering the game sends every var's saved value, including _START ticks
-- from past uses. Those aren't "now", so _START changes are ignored for
-- this many ticks after entering the game.
local SETTLE_TICKS = 3

-- ServerLogic events counted since loading.
local localTick = 0
-- serverTick = localTick + tickOffset, once known.
local tickOffset = nil
-- Ticks left before _START changes count as ability uses again.
local settleTicks = SETTLE_TICKS
-- Var base name -> full cooldown in ticks, last seen while on cooldown, for
-- when a reset zeroes _END.
local lastTotals = {}
-- Cooldown var name -> its value (false if it can't be read). The vars only
-- change through VarTransmit, which updates this, so drawing every frame
-- reads Lua instead of asking the game each time.
local cachedValues = {}
-- Var base name -> { "<base>_START", "<base>_END" }, built once.
local varNames = {}
-- Every cooldown var base the sources use (see Watch), and the highest
-- _START tick seen. A _START is always in the past, so the server tick is at
-- least that: any cooldown ending by then is over, even before the clock is
-- lined up by an ability use.
local watched = {}
local watchedSet = {}
local watchedScanned = false
local highestStart = nil

-- Bumped whenever a cached cooldown var changes or the clock is reset, so
-- results computed before it are recalculated.
local varVersion = 0
-- Var base name -> the last GetCooldown result and what it depended on.
-- Every input changes only on a game event, never between frames, so a
-- frame with no new event reuses it (and auras sharing an ability share it).
local results = {}

local readVarPlayer = gameApi.VarPlayer

local function namesFor(varBase)
    local names = varNames[varBase]
    if names == nil then
        names = { varBase .. "_START", varBase .. "_END" }
        varNames[varBase] = names
    end
    return names
end

local function noteStart(value)
    if value and value > 0 and (highestStart == nil or value > highestStart) then
        highestStart = value
    end
end

local function readCached(name)
    local value = cachedValues[name]
    if value == nil then
        value = readVarPlayer(name)
        if value == nil then value = false end
        cachedValues[name] = value
    end
    return value or nil
end

-- Whole seconds come back as integers so "$current" doesn't read "6.0".
local function ticksToSeconds(ticks)
    local seconds = ticks * TICK_SECONDS_NUMERATOR / TICK_SECONDS_DENOMINATOR
    return math.tointeger(seconds) or seconds
end

local toTenths = gameClock.ToTenths

-- Registers a cooldown var base so its _START counts towards the lower
-- bound on the server tick. The data sources register every ability.
function abilityCooldowns.Watch(varBase)
    if watchedSet[varBase] then return end
    watchedSet[varBase] = true
    watched[#watched + 1] = varBase
    -- Include it in the next lower-bound scan.
    watchedScanned = false
end

-- The highest _START tick known, reading every watched ability's _START
-- once (a reload mid-session has had no var updates yet).
local function tickLowerBound()
    if not watchedScanned then
        watchedScanned = true
        for _, varBase in ipairs(watched) do
            noteStart(readCached(namesFor(varBase)[1]))
        end
    end
    return highestStart
end

-- A cooldown var's value (an ability's COMBATV2_COOLDOWN_<name>_START or
-- _END), from the cache VarTransmit keeps current, so it costs nothing to
-- read every frame. nil if there's none.
function abilityCooldowns.VarValue(name)
    return readCached(name)
end

-- The current server tick, or nil until an ability use has lined us up.
function abilityCooldowns.ServerTick()
    if tickOffset == nil then return nil end
    return localTick + tickOffset
end

-- Returns remaining, total (in seconds) for a var base name such as
-- COMBATV2_COOLDOWN_STRENGTH_BERSERK. remaining is 0 when the ability is
-- ready; both are nil when it can't be timed yet. The vars only change once
-- a server tick, so remaining is extrapolated through the current tick (see
-- GameData/Trackers/game-clock) and rounded up to a tenth of a second. The third
-- value is remaining unrounded, for drawing a bar that moves every frame.
local function computeCooldown(varBase)
    local names = namesFor(varBase)
    local startTick = readCached(names[1])
    local endTick = readCached(names[2])
    if startTick == nil or endTick == nil then return nil end
    if endTick > startTick then lastTotals[varBase] = endTick - startTick end
    local total = lastTotals[varBase] or 0

    -- Some resets (e.g. War's Altar) set _END to 0.
    if endTick <= 0 then return 0, ticksToSeconds(total), 0 end

    local now = abilityCooldowns.ServerTick()
    if now == nil then
        -- Not lined up yet, but a cooldown that ended before the latest
        -- known ability use is certainly over.
        local lowerBound = tickLowerBound()
        if lowerBound ~= nil and endTick <= lowerBound then return 0, ticksToSeconds(total), 0 end
        return nil
    end
    local remaining = ticksToSeconds(math.max(0, endTick - now - gameClock.TickFraction()))
    return toTenths(remaining), ticksToSeconds(total), remaining
end

function abilityCooldowns.GetCooldown(varBase)
    local logicTick = gameClock.LogicTick()
    local result = results[varBase]
    if result == nil then
        result = {}
        results[varBase] = result
    elseif result.logicTick == logicTick and result.localTick == localTick
        and result.tickOffset == tickOffset and result.varVersion == varVersion then
        return result[1], result[2], result[3]
    end
    result[1], result[2], result[3] = computeCooldown(varBase)
    result.logicTick, result.localTick = logicTick, localTick
    result.tickOffset, result.varVersion = tickOffset, varVersion
    return result[1], result[2], result[3]
end

-- This runs for every var change in the game, so it sticks to plain-text
-- checks (no patterns) and leaves most names after one find.
local function cooldownVarKind(name)
    if string.find(name, "COOLDOWN", 1, true) == nil then return nil end
    local suffix = string.sub(name, -6)
    if suffix == "_START" then return "start" end
    if string.sub(suffix, -4) == "_END" then return "end" end
    return nil
end

-- Forgets the tick clock, e.g. on leaving the game: the server keeps ticking
-- while ServerLogic doesn't fire, so the old offset would be behind.
function abilityCooldowns.Reset()
    tickOffset = nil
    settleTicks = SETTLE_TICKS
    -- Entering the game resends every var, refilling these.
    cachedValues = {}
    varVersion = varVersion + 1
    highestStart = nil
    watchedScanned = false
end

function abilityCooldowns.Start()
    Event.ServerLogic.Subscribe(EVENT_ID, function()
        localTick = localTick + 1
        if settleTicks > 0 then settleTicks = settleTicks - 1 end
    end)
    Event.VarTransmit.Subscribe(EVENT_ID, function(event)
        if event.oldValue == event.newValue then return end
        local name = event.var and gameApi.EventVarName(event)
        if name == nil then return end
        local kind = cooldownVarKind(name)
        if kind == nil then return end
        local newValue = tonumber(event.newValue)
        cachedValues[name] = newValue or false
        varVersion = varVersion + 1
        if kind ~= "start" or newValue == nil or newValue <= 0 then return end
        noteStart(newValue)
        local now = abilityCooldowns.ServerTick()
        -- Skip the values sent on entering the game, and any _START older
        -- than the clock already says it is (allowing a tick of slack).
        if settleTicks == 0 and (now == nil or newValue >= now - 1) then
            tickOffset = newValue - localTick
        end
    end)
end

function abilityCooldowns.Stop()
    Event.ServerLogic.Unsubscribe(EVENT_ID)
    Event.VarTransmit.Unsubscribe(EVENT_ID)
end

return abilityCooldowns
