-- Reads ability cooldowns from game vars.
-- Each ability has a VarPlayer pair COMBATV2_COOLDOWN_<SKILL>_<ABILITY>_START
-- and _END (see Data/cooldowns.txt) holding the server tick it was used on
-- and the tick it comes off cooldown. Nothing exposes the current server
-- tick, so this keeps its own: it counts ServerLogic events (one per tick)
-- and lines that count up with the server whenever a _START var changes,
-- since a fresh _START is "now". Until the first ability use after loading
-- or entering the game, an ability that is still on cooldown can't be timed.
-- Usage:
--   local abilityCooldowns = require("GameData/ability-cooldowns")
--   abilityCooldowns.Start()   -- once, at load
--   abilityCooldowns.Reset()   -- on leaving the game
--   abilityCooldowns.GetCooldown("COMBATV2_COOLDOWN_STRENGTH_BERSERK")
--     --> remaining, total, unroundedRemaining

local gameClock = require("GameData/game-clock")
local vars = require("GameData/vars")

local abilityCooldowns = {}

local EVENT_ID = "runeAuras_abilityCooldowns"
-- A tick is 0.6 seconds; kept as a fraction so whole seconds stay exact.
local TICK_SECONDS_NUMERATOR, TICK_SECONDS_DENOMINATOR = 6, 10
-- Entering the game sends every var's saved value, including _START ticks
-- from past uses. Those aren't "now", so _START changes are ignored for
-- this many ticks after entering the game.
local SETTLE_TICKS = 3

-- A first set of abilities to prove the approach; the dump has ~160 pairs.
abilityCooldowns.ABILITIES = {
    { id = "berserk", label = "Berserk", var = "COMBATV2_COOLDOWN_STRENGTH_BERSERK" },
    { id = "sunshine", label = "Sunshine", var = "COMBATV2_COOLDOWN_MAGIC_SUNSHINE" },
    { id = "deaths_swiftness", label = "Death's Swiftness", var = "COMBATV2_COOLDOWN_RANGED_DEATHS_SWIFTNESS" },
    { id = "living_death", label = "Living Death", var = "COMBATV2_COOLDOWN_NECROMANCY_LIVING_DEATH" },
    { id = "surge", label = "Surge", var = "COMBATV2_COOLDOWN_MAGIC_SURGE" },
    { id = "escape", label = "Escape", var = "COMBATV2_COOLDOWN_RANGED_ESCAPE" },
    { id = "bladed_dive", label = "Bladed Dive", var = "COMBATV2_COOLDOWN_ATTACK_BLADED_DIVE" },
    { id = "freedom", label = "Freedom", var = "COMBATV2_COOLDOWN_DEFENCE_FREEDOM" },
    { id = "anticipation", label = "Anticipation", var = "COMBATV2_COOLDOWN_DEFENCE_ANTICIPATION" },
    { id = "resonance", label = "Resonance", var = "COMBATV2_COOLDOWN_DEFENCE_RESONANCE" },
    { id = "barricade", label = "Barricade", var = "COMBATV2_COOLDOWN_DEFENCE_BARRICADE" },
    { id = "devotion", label = "Devotion", var = "COMBATV2_COOLDOWN_DEFENCE_DEVOTION" },
}

-- ServerLogic events counted since loading.
local localTick = 0
-- serverTick = localTick + tickOffset, once known.
local tickOffset = nil
-- Ticks left before _START changes count as ability uses again.
local settleTicks = SETTLE_TICKS
-- Var base name -> full cooldown in ticks, last seen while on cooldown, for
-- when a reset zeroes _END.
local lastTotals = {}

local readVarPlayer = vars.ReadVarPlayer

-- Whole seconds come back as integers so "$current" doesn't read "6.0".
local function ticksToSeconds(ticks)
    local seconds = ticks * TICK_SECONDS_NUMERATOR / TICK_SECONDS_DENOMINATOR
    return math.tointeger(seconds) or seconds
end

-- Rounds up to a tenth of a second, so the value reads like the game's own
-- timers and only reaches 0 once the ability is actually ready.
local function toTenths(seconds)
    local tenths = math.ceil(seconds * 10 - 1e-9)
    return math.tointeger(tenths / 10) or tenths / 10
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
-- GameData/game-clock) and rounded up to a tenth of a second. The third
-- value is remaining unrounded, for drawing a bar that moves every frame.
function abilityCooldowns.GetCooldown(varBase)
    local startTick = readVarPlayer(varBase .. "_START")
    local endTick = readVarPlayer(varBase .. "_END")
    if startTick == nil or endTick == nil then return nil end
    if endTick > startTick then lastTotals[varBase] = endTick - startTick end
    local total = lastTotals[varBase] or 0

    -- Some resets (e.g. War's Altar) set _END to 0.
    if endTick <= 0 then return 0, ticksToSeconds(total), 0 end

    local now = abilityCooldowns.ServerTick()
    if now == nil then return nil end
    local remaining = ticksToSeconds(math.max(0, endTick - now - gameClock.TickFraction()))
    return toTenths(remaining), ticksToSeconds(total), remaining
end

local function isCooldownStart(name)
    return name:match("^COMBATV2_.*COOLDOWN.*_START$") ~= nil
end

-- Forgets the tick clock, e.g. on leaving the game: the server keeps ticking
-- while ServerLogic doesn't fire, so the old offset would be behind.
function abilityCooldowns.Reset()
    tickOffset = nil
    settleTicks = SETTLE_TICKS
end

function abilityCooldowns.Start()
    Event.ServerLogic.Subscribe(EVENT_ID, function()
        localTick = localTick + 1
        if settleTicks > 0 then settleTicks = settleTicks - 1 end
    end)
    Event.VarTransmit.Subscribe(EVENT_ID, function(event)
        if event.oldValue == event.newValue then return end
        local name = event.var and event.var.configName
        if name == nil or not isCooldownStart(name) then return end
        local newValue = tonumber(event.newValue)
        if newValue == nil or newValue <= 0 then return end
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
