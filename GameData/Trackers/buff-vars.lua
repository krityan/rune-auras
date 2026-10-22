-- Reads buffs from the game's own vars (endVar and stacksVar, found by
-- GameData/Catalogues/buff-catalogue): exact, and independent of the
-- player's buff bar settings.
-- - End times are VarClients holding the client Logic tick (50 a second,
--   GameData/Trackers/game-clock) the buff ends on, so the time left is
--   (end - now) / 50. The client sets them itself, so they never come
--   through VarTransmit: they're read when asked for.
-- - Stacks are VarPlayers holding the count.
-- - Area buffs (Sunshine) also have an in-area varbit: their end time is
--   the area's, so they're only active while it's 1. It's set a server
--   tick after the end time, so a fresh area counts as entered until the
--   varbit has had time to arrive (AREA_GRACE_TICKS).
-- A buff with an end time is active while it's in the future; one with only
-- stacks while it has any. Stacks are reported on their own (fourth from
-- Read), so a buff with both, like Blood Tithe, reads its timer as its value
-- and its stacks for $stacks.
-- The max follows the end time: when the buff starts it's the config
-- duration (or the time left, if longer); a small increase while it runs is
-- an extension (e.g. Galeshot during Rapid Fire) and adds to it; a bigger
-- one is a refresh and starts it over.
-- Usage:
--   local buffVars = require("GameData/Trackers/buff-vars")
--   buffVars.Handles(entry)   -- whether it reads this buff
--   buffVars.Read(entry)      --> curr, max, unrounded curr, stacks
--   buffVars.Reset()          -- on leaving the game

local gameApi = require("GameData/game-api")
local gameClock = require("GameData/Trackers/game-clock")

local buffVars = {}

local LOGIC_TICKS_PER_SECOND = 50
-- An end time moving later by at most this much is an extension rather
-- than a refresh: Galeshot gains a server tick (0.6s) at a time.
local EXTENSION_SECONDS = 1.2
-- Moves smaller than this (in Logic ticks: half a server tick) are noise,
-- not extensions: counting them would ratchet the max up over a long buff
-- if the client ever rewrites an end time a tick or two either way.
local JITTER_TICKS = 15
-- How long (in Logic ticks: two server ticks) a new area counts as entered
-- before its in-area varbit is first seen set. The varbit arrives a server
-- tick after the end time; without this the buff would show a tick late.
local AREA_GRACE_TICKS = 60

-- Var name -> its config (false if there's none), looked up once, so
-- reading every frame skips the by-name lookup.
local clientConfigs = {}
local playerConfigs = {}
-- Struct id -> { endTick, max } while the buff is followed.
local timers = {}
-- Struct id -> the most stacks seen this session.
local maxStacks = {}

local function cachedConfig(cache, lookup, name)
    local found = cache[name]
    if found == nil then
        found = lookup(name) or false
        cache[name] = found
    end
    return found or nil
end

local function varClientConfig(name)
    return cachedConfig(clientConfigs, gameApi.VarClient, name)
end

-- A VarPlayer's value, through its cached config.
local function varPlayerValue(name)
    local config = cachedConfig(playerConfigs, gameApi.VarPlayerConfig, name)
    return config and gameApi.VarValue(config)
end

function buffVars.Handles(entry)
    return entry.endVar ~= nil or entry.stacksVar ~= nil
end

-- The buff's stacks and the most seen, or nil when it has no stacks var.
local function readStacks(entry)
    if entry.stacksVar == nil then return nil end
    local stacks = tonumber(varPlayerValue(entry.stacksVar)) or 0
    local most = math.max(maxStacks[entry.structID] or 0, stacks)
    maxStacks[entry.structID] = most
    return stacks, most
end

-- Whether the player is in the buff's area: always, for buffs without one.
-- Until the varbit has first been seen set for this area, a new area counts
-- as entered for AREA_GRACE_TICKS, as the varbit arrives a tick late.
local function inArea(entry, timer, now)
    if entry.inAreaVar == nil then return true end
    if tonumber(varPlayerValue(entry.inAreaVar)) == 1 then
        timer.entered = true
        return true
    end
    return not timer.entered and now - timer.startTick <= AREA_GRACE_TICKS
end

-- Seconds left (rounded up to a tenth, like cooldowns) over the max, plus
-- the unrounded value; 0 / last max when it's over.
local function readTimer(entry)
    local config = varClientConfig(entry.endVar)
    local now = gameClock.LogicTick()
    local endTick = config and tonumber(gameApi.VarValue(config))
    local timer = timers[entry.structID]
    if endTick == nil or now == nil or endTick <= now then
        timers[entry.structID] = nil
        return 0, timer and timer.max or 0
    end
    local remaining = (endTick - now) / LOGIC_TICKS_PER_SECOND
    if timer == nil then
        -- Just started, or found running: a running one is only part way,
        -- so the config duration is the better max when there is one.
        timer = { endTick = endTick, startTick = now, max = math.max(remaining, entry.duration or 0) }
        timers[entry.structID] = timer
    elseif endTick - timer.endTick >= JITTER_TICKS then
        local added = (endTick - timer.endTick) / LOGIC_TICKS_PER_SECOND
        if added <= EXTENSION_SECONDS then
            timer.max = timer.max + added
        else
            -- Refreshed: a new area, if it's an area buff.
            timer.max = math.max(remaining, entry.duration or 0)
            timer.startTick, timer.entered = now, false
        end
        timer.endTick = endTick
    elseif endTick ~= timer.endTick then
        -- Earlier, or later by less than the jitter: follow it without
        -- touching the max.
        timer.endTick = endTick
    end
    -- Out of the area: inactive, though the timer's kept so stepping back
    -- in carries on with the same max.
    if not inArea(entry, timer, now) then return 0, timer.max end
    local rounded = math.ceil(remaining * 10 - 1e-9) / 10
    return rounded, timer.max, remaining
end

function buffVars.Read(entry)
    local stacks, most = readStacks(entry)
    if entry.endVar == nil then
        -- Stacks only: they're its value too.
        if stacks == nil or stacks <= 0 then return 0, 0, nil, stacks end
        return stacks, most, nil, stacks
    end
    local curr, max, remaining = readTimer(entry)
    return curr, max, remaining, stacks
end

-- Forgets the buffs being followed, e.g. on leaving the game. Var configs
-- are kept: they're the same for every login.
function buffVars.Reset()
    timers = {}
    maxStacks = {}
end

return buffVars
