-- Active buffs, read from the game's own vars (found by buff-catalogue):
-- exact, and independent of the player's buff bar settings. Owns timing
-- each buff and following its max as it's extended or refreshed.

local gameApi = require("GameData/game-api")
local gameClock = require("GameData/Trackers/game-clock")
local abilityCooldowns = require("GameData/Trackers/ability-cooldowns")
local buffCatalogue = require("GameData/Catalogues/buff-catalogue")

local activeBuffs = {}

local LOGIC_TICKS_PER_SECOND = gameClock.LOGIC_TICKS_PER_SECOND
local SECONDS_PER_SERVER_TICK = gameClock.SECONDS_PER_SERVER_TICK
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
-- A toggled buff's var holds this (or 0) while it's off: Debilitate's holds
-- the target's id, -1 without one.
local NO_TARGET = -1
-- What a toggled buff reads while on: 1 of 1.
local ON, OFF, TOGGLE_MAX = 1, 0, 1

--- A timed buff being followed.
---@class BuffTimer
---@field endTick integer The Logic tick it ends on.
---@field startTick integer When it started (or was refreshed), for an area buff's grace.
---@field max number Seconds: its full length, grown by extensions.
---@field entered boolean? An area buff's in-area varbit has been seen set since it started.

---@type table<integer, BuffTimer> Struct id to its timer while the buff is followed.
local timers = {}
---@type table<integer, integer> Struct id to the most stacks seen this session.
local maxStacks = {}

--- A buff's last Read, and the Logic tick it was read on.
---@class BuffReading
---@field logicTick integer
---@field curr number
---@field max number
---@field unrounded number?
---@field stacks integer?

---@type table<integer, BuffReading> Struct id to its last Read. Timers count Logic ticks, so reading more often than once a tick (20 ms) shows nothing new.
local readings = {}

--- A VarClient's config by name, cached so reading every frame skips the
--- lookup.
---@param name string
---@return userdata?
local function varClientConfig(name)
    return gameApi.Cached(gameApi.VarClient, name)
end

local varPlayerValue = gameApi.CachedVarPlayer

--- Whether a buff has vars this can read.
---@type fun(entry: BuffEntry): boolean
activeBuffs.Handles = buffCatalogue.HasVars

--- Whether a toggled buff (no timer: Bone Shield, prayers) is on: its var
--- is a number other than 0 or NO_TARGET (an OBJ var, the quiver's, gives
--- an item).
---@param entry BuffEntry
---@return boolean
local function isOn(entry)
    local raw = varPlayerValue(entry.activeVar)
    local value = tonumber(raw) or gameApi.ItemID(raw)
    return value ~= nil and value ~= 0 and value ~= NO_TARGET
end

--- The item a buff shows while it runs (see BuffEntry.objectVar).
---@param entry BuffEntry
---@return integer? objectID nil if it has none, or none is set.
function activeBuffs.Object(entry)
    if entry.objectVar == nil then return nil end
    local itemID = gameApi.ItemID(varPlayerValue(entry.objectVar))
    if itemID == nil or itemID < 0 then return nil end
    return itemID
end

--- A buff timed from its ability's use (Unsullied): it has only the
--- ability's _START VarPlayer (the server tick it was used, kept current by
--- the cooldown tracker), and lasts its duration from it.
---@param entry BuffEntry
---@return number curr Seconds left, to a tenth; 0 when it's over or the server tick isn't known yet.
---@return number max Its duration.
---@return number? unrounded
local function readFromStart(entry)
    local duration = entry.duration
    local start = tonumber(abilityCooldowns.VarValue(entry.startVar))
    local now = abilityCooldowns.ServerTick()
    if start == nil or now == nil then return 0, duration end
    local elapsed = (now - start + gameClock.TickFraction()) * SECONDS_PER_SERVER_TICK
    local remaining = duration - elapsed
    if elapsed < 0 or remaining <= 0 then return 0, duration end
    return gameClock.ToTenths(remaining), duration, remaining
end

--- A buff's stacks, from its stacks VarPlayer.
---@param entry BuffEntry
---@return integer? stacks nil when it has no stacks var.
---@return integer? most The most seen this session.
local function readStacks(entry)
    if entry.stacksVar == nil then return nil end
    local stacks = tonumber(varPlayerValue(entry.stacksVar)) or 0
    local most = math.max(maxStacks[entry.structID] or 0, stacks)
    maxStacks[entry.structID] = most
    return stacks, most
end

--- Whether the player is in an area buff's area (Sunshine): its end time
--- belongs to the area, and carries on after leaving, so it's only active while
--- its in-area varbit is 1. The varbit arrives a server tick after the end
--- time, so until it's first seen set a new area counts as entered for
--- AREA_GRACE_TICKS.
---@param entry BuffEntry
---@param timer BuffTimer
---@param now integer Logic tick.
---@return boolean inArea Always true for a buff without an area.
local function inArea(entry, timer, now)
    if entry.inAreaVar == nil then return true end
    if tonumber(varPlayerValue(entry.inAreaVar)) == 1 then
        timer.entered = true
        return true
    end
    return not timer.entered and now - timer.startTick <= AREA_GRACE_TICKS
end

--- Updates a timer's max for a new end time: a small move later is an
--- extension (Galeshot during Rapid Fire) and adds to it; a bigger one is a
--- refresh and starts it over.
---@param timer BuffTimer Changed in place.
---@param entry BuffEntry
---@param endTick integer The new end tick.
---@param now integer Logic tick.
---@param remaining number Seconds left.
local function followEndTick(timer, entry, endTick, now, remaining)
    local movedTicks = endTick - timer.endTick
    if movedTicks >= JITTER_TICKS then
        local added = movedTicks / LOGIC_TICKS_PER_SECOND
        if added <= EXTENSION_SECONDS then
            timer.max = timer.max + added
        else
            -- Refreshed: a new area, if it's an area buff.
            timer.max = math.max(remaining, entry.duration or 0)
            timer.startTick, timer.entered = now, false
        end
    end
    -- Earlier, or later by less than the jitter: followed without touching the max.
    timer.endTick = endTick
end

--- A timed buff, from its end-time VarClient (the Logic tick it ends on;
--- the client sets it, so it never comes through VarTransmit). Active while
--- that's in the future.
---@param entry BuffEntry
---@return number curr Seconds left, to a tenth like cooldowns; 0 when it's over.
---@return number max Its full length, or the last one's length.
---@return number? unrounded
local function readTimer(entry)
    local varConfig = varClientConfig(entry.endVar)
    local now = gameClock.LogicTick()
    local endTick = varConfig and tonumber(gameApi.VarValue(varConfig))
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
    elseif endTick ~= timer.endTick then
        followEndTick(timer, entry, endTick, now, remaining)
    end
    -- Out of the area: inactive, though the timer's kept so stepping back
    -- in carries on with the same max.
    if not inArea(entry, timer, now) then return 0, timer.max end
    return gameClock.ToTenths(remaining), timer.max, remaining
end

--- A buff's values now (see activeBuffs.Read).
---@param entry BuffEntry
---@return number curr
---@return number max
---@return number? unrounded
---@return integer? stacks
local function readNow(entry)
    local stacks, most = readStacks(entry)
    if entry.endVar == nil and entry.startVar ~= nil then
        local curr, max, remaining = readFromStart(entry)
        return curr, max, remaining, stacks
    end
    if entry.endVar == nil and stacks == nil and entry.activeVar ~= nil then
        return isOn(entry) and ON or OFF, TOGGLE_MAX, nil, nil
    end
    if entry.endVar == nil then
        -- Stacks only: they're its value too, and active while it has any.
        if stacks == nil or stacks <= 0 then return 0, 0, nil, stacks end
        return stacks, most, nil, stacks
    end
    local curr, max, remaining = readTimer(entry)
    return curr, max, remaining, stacks
end

--- A buff's values now, read from the game at most once per Logic tick.
--- Stacks are reported on their own, so a buff with a timer and stacks
--- (Blood Tithe) reads its timer as its value and its stacks for $stacks.
---@param entry BuffEntry
---@return number curr Seconds left; for a buff with only stacks, the stacks; for a toggled one, 1 or 0.
---@return number max
---@return number? unrounded
---@return integer? stacks
function activeBuffs.Read(entry)
    local now = gameClock.LogicTick()
    local reading = readings[entry.structID]
    if reading ~= nil and reading.logicTick == now then
        return reading.curr, reading.max, reading.unrounded, reading.stacks
    end
    local curr, max, unrounded, stacks = readNow(entry)
    if now == nil then return curr, max, unrounded, stacks end
    if reading == nil then
        reading = {}
        readings[entry.structID] = reading
    end
    reading.logicTick, reading.curr, reading.max, reading.unrounded, reading.stacks = now, curr, max, unrounded, stacks
    return curr, max, unrounded, stacks
end

--- Forgets the buffs being followed, e.g. on leaving the game.
function activeBuffs.Reset()
    timers = {}
    maxStacks = {}
    readings = {}
end

return activeBuffs
