-- The ability the player is channelling (Rapid Fire, Flurry, Snipe, ...),
-- and how long it has left, from the game's own channel vars (found by
-- logging every var while channelling):
-- - COMBATV2_CHANNEL_START_CLIENT and COMBATV2_COOLDOWN_CHANNELLING_END_EFFECT_CLIENT
--   are VarClients holding the client Logic tick (50 a second) the channel
--   started and ends on, so the timing is exact and smooth. The client sets
--   them, so they're read when asked rather than through VarTransmit. The
--   game's own channel bar runs a server tick past that end, until
--   COMBATV2_CHANNEL_ITERATIONS goes back to 0 (Rapid Fire 4.8s, Snipe 1.8s),
--   so this does too.
-- - COMBATV2_CHANNEL_END_REASON is -1 while it runs and set once it stops:
--   1 when it completes (on the end tick, so the extra tick still runs),
--   anything else when it's cut short, which ends it straight away.
-- - COMBATV2_CHANNEL_ABILITY_STRUCT is the ability's struct. Its
--   COMBATV2_ABILITY_ID and COMBATV2_ABILITY_PARENT_STAT name the ability
--   (Key, as abilityCatalogue.Key), the same for every version of it
--   (Greater Flurry, Flurry's Bloodlust and DoT variants), so a source can
--   follow one ability.
-- - A cast (COMBATV2_ABILITY_CHANNEL_IS_CAST: Snipe, which charges up and
--   then fires) reads as the time so far instead, so its bar fills up.
-- Usage:
--   local channel = require("GameData/Trackers/channel")
--   channel.Read()   --> seconds left (time so far for a cast; to a tenth), total, unrounded
--   channel.Key()    --> the ability channelling (or last channelled), as abilityCatalogue.Key
--   channel.Reset()  -- on leaving the game

local gameApi = require("GameData/game-api")
local gameClock = require("GameData/Trackers/game-clock")
local abilityCatalogue = require("GameData/Catalogues/ability-catalogue")

local channel = {}

local START_VAR = "COMBATV2_CHANNEL_START_CLIENT"
local END_VAR = "COMBATV2_COOLDOWN_CHANNELLING_END_EFFECT_CLIENT"
local REASON_VAR = "COMBATV2_CHANNEL_END_REASON"
local STRUCT_VAR = "COMBATV2_CHANNEL_ABILITY_STRUCT"
local LOGIC_TICKS_PER_SECOND = gameClock.LOGIC_TICKS_PER_SECOND
-- One server tick in Logic ticks: how far the game's channel bar runs past
-- the end var.
local END_TICK_LOGIC = LOGIC_TICKS_PER_SECOND * gameClock.SECONDS_PER_SERVER_TICK
local COMPLETED = 1
-- The ability struct is set on the same server tick as the start time, but
-- may arrive a moment after it, so it's read again for this long (in Logic
-- ticks: a server tick and a bit) after a channel starts.
local STRUCT_SETTLE_TICKS = 40

local function clientValue(name)
    local config = gameApi.Cached(gameApi.VarClient, name)
    return config and tonumber(gameApi.VarValue(config))
end

local function playerValue(name)
    local config = gameApi.Cached(gameApi.VarPlayerConfig, name)
    return config and gameApi.VarValue(config)
end

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
local result = { 0, 0, nil }

-- The key of the ability whose struct the channel var holds (a struct, or
-- its id), and whether it's a cast; nil, false if it can't be told.
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
    if reason ~= nil and reason ~= -1 and reason ~= COMPLETED then return 0, lastTotal end
    local remaining = (finish - now) / LOGIC_TICKS_PER_SECOND
    -- Rounded up either way, so a running cast is never 0 (which Hide when
    -- empty would hide).
    local shown = isCast and lastTotal - remaining or remaining
    return gameClock.ToTenths(shown), lastTotal, shown
end

function channel.Read()
    local now = gameClock.LogicTick()
    if now == nil or now ~= readTick then
        readTick = now
        result[1], result[2], result[3] = readNow(now)
    end
    return result[1], result[2], result[3]
end

function channel.Key()
    channel.Read()
    return abilityKey
end

-- Forgets the channel being followed, e.g. on leaving the game.
function channel.Reset()
    startTick, abilityKey, isCast, lastTotal, readTick = nil, nil, false, 0, nil
end

return channel
