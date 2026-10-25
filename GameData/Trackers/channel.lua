-- The ability the player is channelling (Rapid Fire, Flurry, Snipe, ...),
-- and how long it has left, from the game's own channel vars (found by
-- logging every var while channelling).

local gameApi = require("GameData/game-api")
local gameClock = require("GameData/Trackers/game-clock")
local abilityCatalogue = require("GameData/Catalogues/ability-catalogue")

local channel = {}

-- VarClients holding the client Logic tick the channel started and ends
-- on, so the timing is exact and smooth. The client sets them, so they're
-- read when asked rather than through VarTransmit.
local START_VAR = "COMBATV2_CHANNEL_START_CLIENT"
local END_VAR = "COMBATV2_COOLDOWN_CHANNELLING_END_EFFECT_CLIENT"
-- RUNNING while the channel runs; COMPLETED on the end tick when it
-- completes (so the extra tick still runs); anything else when it's cut
-- short, which ends it straight away.
local REASON_VAR = "COMBATV2_CHANNEL_END_REASON"
local RUNNING, COMPLETED = -1, 1
-- The ability's struct (or its id). Its COMBATV2_ABILITY_ID and
-- COMBATV2_ABILITY_PARENT_STAT name the ability, the same for every version
-- of it (Greater Flurry, Flurry's Bloodlust and DoT variants), so a source
-- can follow one ability.
local STRUCT_VAR = "COMBATV2_CHANNEL_ABILITY_STRUCT"
local LOGIC_TICKS_PER_SECOND = gameClock.LOGIC_TICKS_PER_SECOND
-- The game's own channel bar runs a server tick past the end var, until
-- COMBATV2_CHANNEL_ITERATIONS goes back to 0 (Rapid Fire 4.8s, Snipe 1.8s),
-- so this does too: one server tick in Logic ticks.
local END_TICK_LOGIC = LOGIC_TICKS_PER_SECOND * gameClock.SECONDS_PER_SERVER_TICK
-- The ability struct is set on the same server tick as the start time, but
-- may arrive a moment after it, so it's read again for this long (in Logic
-- ticks: a server tick and a bit) after a channel starts.
local STRUCT_SETTLE_TICKS = 40

--- A VarClient's value as a number, through its cached config.
---@param name string
---@return number?
local function clientValue(name)
    local varConfig = gameApi.Cached(gameApi.VarClient, name)
    return varConfig and tonumber(gameApi.VarValue(varConfig))
end

local playerValue = gameApi.CachedVarPlayer

--- A param config by name, cached.
---@param name string
---@return userdata?
local function param(name)
    return gameApi.Cached(gameApi.Param, name)
end

-- The channel being followed: its start tick, its ability's key (kept once
-- it's over) and whether it's a cast.
local startTick = nil
local abilityKey = nil
local isCast = false
-- The last channel's length, kept as the max once it's over.
local lastTotal = 0
-- This Logic tick's result, so every aura showing a channel reads once.
local readTick = nil
local result = { shown = 0, total = 0, unrounded = nil }

--- The ability the channel var names, and whether it's a cast (charges up
--- and then fires: COMBATV2_ABILITY_CHANNEL_IS_CAST, only Snipe).
---@param value any The struct var's value: a struct, or its id.
---@return string? key As abilityCatalogue.Key; nil if it can't be told.
---@return boolean isCast
local function keyOf(value)
    local struct = value
    if type(value) == "number" then
        if value < 0 then return nil, false end
        struct = gameApi.StructByID(value)
    end
    local idParam, skillParam = param("COMBATV2_ABILITY_ID"), param("COMBATV2_ABILITY_PARENT_STAT")
    if struct == nil or type(struct) == "boolean" or idParam == nil or skillParam == nil then
        return nil, false
    end
    local castParam = param("COMBATV2_ABILITY_CHANNEL_IS_CAST")
    local cast = castParam ~= nil and gameApi.ParamValue(struct, castParam) == true
    return abilityCatalogue.Key(gameApi.ParamValue(struct, idParam), gameApi.ParamValue(struct, skillParam)), cast
end

--- Reads the channel at a Logic tick, following a new one when it starts.
---@param now integer? The current Logic tick.
---@return number shown Seconds left (time so far for a cast), to a tenth; 0 when none is running.
---@return number total The channel's length, or the last channel's length.
---@return number? unrounded
local function readNow(now)
    if now == nil then return 0, lastTotal end
    local start, finish = clientValue(START_VAR), clientValue(END_VAR)
    if start == nil or finish == nil or finish <= start then return 0, lastTotal end
    finish = finish + END_TICK_LOGIC
    if start ~= startTick then
        startTick, abilityKey, isCast = start, nil, false
    end
    -- Read through the settle time even once found: until then it may still
    -- hold the last channel's ability.
    if now - start <= STRUCT_SETTLE_TICKS then
        abilityKey, isCast = keyOf(playerValue(STRUCT_VAR))
    end
    lastTotal = (finish - start) / LOGIC_TICKS_PER_SECOND
    if finish <= now then return 0, lastTotal end
    local reason = tonumber(playerValue(REASON_VAR))
    local cutShort = reason ~= nil and reason ~= RUNNING and reason ~= COMPLETED
    if cutShort then return 0, lastTotal end
    local remaining = (finish - now) / LOGIC_TICKS_PER_SECOND
    -- Rounded up either way, so a running cast is never 0 (which Hide when
    -- empty would hide).
    local shown = isCast and lastTotal - remaining or remaining
    return gameClock.ToTenths(shown), lastTotal, shown
end

--- The current channel, read at most once a Logic tick.
---@return number shown Seconds left (time so far for a cast, so its bar fills up), to a tenth; 0 when none is running.
---@return number total The channel's length, or the last channel's length.
---@return number? unrounded
function channel.Read()
    local now = gameClock.LogicTick()
    if now == nil or now ~= readTick then
        readTick = now
        result.shown, result.total, result.unrounded = readNow(now)
    end
    return result.shown, result.total, result.unrounded
end

--- The ability channelling, or last channelled.
---@return string? key As abilityCatalogue.Key.
function channel.Key()
    channel.Read()
    return abilityKey
end

--- Forgets the channel being followed, e.g. on leaving the game.
function channel.Reset()
    startTick, abilityKey, isCast, lastTotal, readTick = nil, nil, false, 0, nil
end

return channel
