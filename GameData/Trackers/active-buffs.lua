-- Active buffs, read from the game's own vars (found by buff-catalogue):
-- exact, and independent of the player's buff bar settings. Owns timing
-- each buff and following its max as it's extended or refreshed.

local gameApi = require("GameData/game-api")
local gameClock = require("GameData/Trackers/game-clock")
local abilityCooldowns = require("GameData/Trackers/ability-cooldowns")
local buffCatalogue = require("GameData/Catalogues/buff-catalogue")
local varCache = require("GameData/Trackers/var-cache")
local wornEquipment = require("GameData/Trackers/worn-equipment")
local buffBar = require("GameData/Trackers/buff-bar")

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
-- How long (in Logic ticks: two server ticks) a timer seen starting passes
-- its checks whatever they say. What they read can lag the end time: an
-- area's varbit by a server tick (Sunshine), the buff bar by a few Logic
-- ticks; without this the buff would show a tick late.
local START_GRACE_TICKS = 60
-- How close (in seconds) two buffs sharing a bar icon can be in time left
-- and still not be told apart by a bar slot's time: the bar shows whole
-- seconds, about a second off the end time.
local GROUP_TOLERANCE_SECONDS = 2
-- How far (in Logic ticks) a pausing buff's time left can run ahead of its
-- end time while it's running: the time left counts down 10 server ticks
-- (300 Logic ticks) at a time, and the end time wobbles by a few Logic
-- ticks. Paused, it stands still and falls behind a Logic tick a tick, so
-- the buff shows as paused at most about 7 s after.
local TIME_LEFT_TOLERANCE_TICKS = 360
local LOGIC_TICKS_PER_SERVER_TICK = gameClock.LOGIC_TICKS_PER_SERVER_TICK
-- VarPlayers holding the server tick of the player's latest attack: an
-- ability's use, and a channel's end (its last hit).
-- TODO: check whether an interrupted channel's end moves to when it stopped.
local LAST_ATTACK_VARS = { "COMBATV2_GLOBAL_COOLDOWN_START", "COMBATV2_CHANNEL_END" }
-- How long (in server ticks) a buff that comes once the player stops
-- attacking skips the buff bar check after it's due: the bar only shows it
-- on its next redraw.
local QUIET_GRACE_SERVER_TICKS = START_GRACE_TICKS // LOGIC_TICKS_PER_SERVER_TICK
-- A toggled buff's var holds this (or 0) while it's off: Debilitate's holds
-- the target's id, -1 without one.
local NO_TARGET = -1
-- What a toggled buff reads while on: 1 of 1.
local ON, OFF, TOGGLE_MAX = 1, 0, 1
-- The most a buff shown as a percentage reads.
local FULL_PERCENT = 100

--- A timed buff being followed.
---@class BuffTimer
---@field endTick integer The Logic tick it ends on.
---@field max number Seconds: its full length, grown by extensions.
---@field graceUntil integer? The Logic tick it passes its checks until (see START_GRACE_TICKS); nil when it was found already running.

---@type table<integer, BuffTimer> Struct id to its timer while the buff is followed.
local timers = {}

---@type table<string, table<integer, boolean>> BuffIconGroup.key to the members its last match of bar slots kept (see isShownInGroup).
local groupMatches = {}
-- A group's match before it has had one.
local NONE_KEPT = {}

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

local varPlayerValue = varCache.VarPlayer

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

--- A buff's stacks, from its stacks VarPlayer. One the game shows as a
--- percentage reads as a whole percent, rounded down so it shows 100 only
--- when full.
---@param entry BuffEntry
---@return integer? stacks nil when it has no stacks var.
---@return integer? most The most seen this session; 100 for a percentage.
local function readStacks(entry)
    if entry.stacksVar == nil then return nil end
    local stacks = tonumber(varPlayerValue(entry.stacksVar)) or 0
    if entry.stacksPercent then
        if entry.stacksAtFull ~= nil then stacks = stacks * FULL_PERCENT // entry.stacksAtFull end
        return stacks, FULL_PERCENT
    end
    local most = math.max(maxStacks[entry.structID] or 0, stacks)
    maxStacks[entry.structID] = most
    return stacks, most
end

--- Whether a requirement is met now: its var is non-zero, or its slot holds a
--- matching item.
---@param requirement BuffRequirement
---@return boolean
local function isRequirementMet(requirement)
    if requirement.var ~= nil then return (tonumber(varPlayerValue(requirement.var)) or 0) ~= 0 end
    local itemID = wornEquipment.Item(requirement.slot)
    local name = itemID and gameApi.Cached(gameApi.ItemConfigName, itemID)
    return name ~= nil and name:find(requirement.item) ~= nil
end

--- Whether any of a buff's requirements is met now.
---@param entry BuffEntry
---@return boolean met Always true for a buff without requirements.
local function isAnyRequirementMet(entry)
    if entry.requirements == nil then return true end
    for _, requirement in ipairs(entry.requirements) do
        if isRequirementMet(requirement) then return true end
    end
    return false
end

--- Whether a buff was read within the last START_GRACE_TICKS, so a timer
--- found now was seen starting rather than found already running (when an
--- aura showing it is made, picked or loaded).
---@param entry BuffEntry
---@param now integer Logic tick.
---@return boolean
local function wasJustRead(entry, now)
    local reading = readings[entry.structID]
    return reading ~= nil and now - reading.logicTick <= START_GRACE_TICKS
end

--- The Logic tick an end-time VarClient holds.
---@param varName string
---@return integer? endTick nil if it can't be read.
local function endTickOf(varName)
    local varConfig = varClientConfig(varName)
    return varConfig and tonumber(gameApi.VarValue(varConfig))
end

--- The seconds left of each running member of a shared-icon group.
---@param group BuffIconGroup
---@param now integer Logic tick.
---@return table<integer, number> secondsLeft Member index to its seconds left.
---@return integer running How many are running.
local function runningMembers(group, now)
    local secondsLeft, running = {}, 0
    for index, endVar in ipairs(group.endVars) do
        local endTick = endVar and endTickOf(endVar) or nil
        if endTick ~= nil and endTick > now then
            secondsLeft[index] = (endTick - now) / LOGIC_TICKS_PER_SECOND
            running = running + 1
        end
    end
    return secondsLeft, running
end

--- The running group member not yet matched that a bar slot's time left
--- points to. Any whose time left is within GROUP_TOLERANCE_SECONDS of the
--- closest could be it: of those, the one kept last time, else the
--- earliest. A slot whose time is unknown could be any of them.
---@param secondsLeft table<integer, number> See runningMembers.
---@param memberCount integer
---@param matched table<integer, boolean> Members already matched to a slot.
---@param slotSeconds number|false
---@param keptBefore table<integer, boolean> The members the group's last match kept.
---@return integer? index nil when none is left.
local function closestMember(secondsLeft, memberCount, matched, slotSeconds, keptBefore)
    local closestGap = math.huge
    for index = 1, memberCount do
        local left = secondsLeft[index]
        if slotSeconds and left ~= nil and not matched[index] then
            closestGap = math.min(closestGap, math.abs(left - slotSeconds))
        end
    end
    local nearEnough = closestGap + GROUP_TOLERANCE_SECONDS
    local earliest = nil
    for index = 1, memberCount do
        local left = secondsLeft[index]
        local isFree = left ~= nil and not matched[index]
        local isNear = isFree and (not slotSeconds or math.abs(left - slotSeconds) <= nearEnough)
        if isNear then
            if keptBefore[index] then return index end
            earliest = earliest or index
        end
    end
    return earliest
end

--- Whether the buff bar still shows a buff that shares its icon with others
--- (see BuffEntry.iconGroup). When it shows fewer of them than are running,
--- each slot is matched to the running member whose time left is closest
--- to the slot's, and the members left over count as dropped. Where the
--- times can't tell (unreadable, or too close), the member kept last time
--- stays, so the bar's whole-second timers drifting against the end ticks
--- can't swap two close ones; failing that the earliest is kept (mine 1
--- over mine 2).
---@param entry BuffEntry
---@param now integer Logic tick.
---@return boolean
local function isShownInGroup(entry, now)
    local shown = buffBar.ShownSeconds(entry.icon, entry.object)
    local group = entry.iconGroup
    if shown == nil or #shown >= #group.endVars then return true end
    local secondsLeft, running = runningMembers(group, now)
    if #shown >= running then return true end
    local keptBefore = groupMatches[group.key] or NONE_KEPT
    local kept = {}
    for _, slotSeconds in ipairs(shown) do
        local index = closestMember(secondsLeft, #group.endVars, kept, slotSeconds, keptBefore)
        if index ~= nil then kept[index] = true end
    end
    groupMatches[group.key] = kept
    return kept[group.index] == true
end

--- Whether a buff that pauses while switched off is running: its time left
--- (see BuffEntry.timeLeftVar) still agrees with its end time, which isn't
--- moved while it's paused.
---@param entry BuffEntry
---@param endTick integer
---@param now integer Logic tick.
---@return boolean
local function isTimeLeftRunning(entry, endTick, now)
    local serverTicksLeft = tonumber(varPlayerValue(entry.timeLeftVar))
    if serverTicksLeft == nil then return true end
    local endFromTimeLeft = now + serverTicksLeft * LOGIC_TICKS_PER_SERVER_TICK
    return endFromTimeLeft - endTick <= TIME_LEFT_TOLERANCE_TICKS
end

--- Whether a running timed buff still counts as active: one of its requirements
--- is met (see BuffEntry.requirements), a pausing one isn't paused (see
--- BuffEntry.timeLeftVar), and, for a buff that ends off the buff bar (see
--- BuffEntry.endsOffBuffBar), the bar still shows it. A timer seen starting
--- passes until its grace ends.
---@param entry BuffEntry
---@param timer BuffTimer
---@param now integer Logic tick.
---@return boolean
local function passesChecks(entry, timer, now)
    local inGrace = timer.graceUntil ~= nil and now <= timer.graceUntil
    if inGrace then return true end
    if not isAnyRequirementMet(entry) then return false end
    local isPaused = entry.timeLeftVar ~= nil and not isTimeLeftRunning(entry, timer.endTick, now)
    if isPaused then return false end
    if not entry.endsOffBuffBar then return true end
    if entry.iconGroup ~= nil then return isShownInGroup(entry, now) end
    return not buffBar.HasDropped(entry.icon, entry.object)
end

--- Whether a toggled buff is on. One that ends off the buff bar (see
--- BuffEntry.endsOffBuffBar) follows the bar whenever it can be read, both
--- ways, as its var can be wrong (the porter's isn't set again on login);
--- otherwise it's its var, and its requirements.
---@param entry BuffEntry
---@return boolean
local function isToggledOn(entry)
    if entry.endsOffBuffBar then
        local shown = buffBar.ShownSeconds(entry.icon, entry.object)
        if shown ~= nil then return #shown > 0 end
    end
    return isOn(entry) and isAnyRequirementMet(entry)
end

--- Whether a buff that comes once the player stops attacking (see
--- BuffEntry.quietTicks) is on: it's been that long since their latest
--- attack, one of its requirements is met, and, for one that ends off the
--- buff bar (see BuffEntry.endsOffBuffBar), the bar hasn't dropped it,
--- which catches attacks that change no var. Until a grace after it's due,
--- the bar isn't asked. Before the server tick is known (just after
--- entering the game, before any ability use) the player counts as not
--- attacking.
---@param entry BuffEntry
---@return boolean
local function isQuietOn(entry)
    if not isAnyRequirementMet(entry) then return false end
    local now = abilityCooldowns.ServerTick()
    if now ~= nil then
        local lastAttack = 0
        for _, varName in ipairs(LAST_ATTACK_VARS) do
            lastAttack = math.max(lastAttack, tonumber(varPlayerValue(varName)) or 0)
        end
        local dueTick = lastAttack + entry.quietTicks
        if now < dueTick then return false end
        if now < dueTick + QUIET_GRACE_SERVER_TICKS then return true end
    end
    if not entry.endsOffBuffBar then return true end
    return not buffBar.HasDropped(entry.icon, entry.object)
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
            -- Refreshed: seen starting again, so its grace starts over (a new
            -- area, for an area buff).
            timer.max = math.max(remaining, entry.duration or 0)
            timer.graceUntil = now + START_GRACE_TICKS
        end
    end
    -- Earlier, or later by less than the jitter: followed without touching the max.
    timer.endTick = endTick
end

--- A timed buff, from its end-time VarClient (the Logic tick it ends on;
--- the client sets it, so it never comes through VarTransmit). Active while
--- that's in the future and it passes its checks (see passesChecks).
---@param entry BuffEntry
---@return number curr Seconds left, to a tenth like cooldowns; 0 when it's over.
---@return number max Its full length, or the last one's length.
---@return number? unrounded
local function readTimer(entry)
    local now = gameClock.LogicTick()
    local endTick = endTickOf(entry.endVar)
    local timer = timers[entry.structID]
    if endTick == nil or now == nil or endTick <= now then
        timers[entry.structID] = nil
        return 0, timer and timer.max or 0
    end
    local remaining = (endTick - now) / LOGIC_TICKS_PER_SECOND
    if timer == nil then
        -- Just started, or found running: a running one is only part way,
        -- so the config duration is the better max when there is one.
        timer = { endTick = endTick, max = math.max(remaining, entry.duration or 0) }
        if wasJustRead(entry, now) then timer.graceUntil = now + START_GRACE_TICKS end
        timers[entry.structID] = timer
    elseif endTick ~= timer.endTick then
        followEndTick(timer, entry, endTick, now, remaining)
    end
    -- Checked off: inactive, though the timer's kept so it carries on with
    -- the same max if they pass again (stepping back into the area).
    if not passesChecks(entry, timer, now) then return 0, timer.max end
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
    if entry.quietTicks ~= nil then return isQuietOn(entry) and ON or OFF, TOGGLE_MAX, nil, nil end
    if entry.endVar == nil and stacks == nil and entry.activeVar ~= nil then
        return isToggledOn(entry) and ON or OFF, TOGGLE_MAX, nil, nil
    end
    if entry.endVar == nil then
        -- Stacks only: they're its value too, and active while it has any.
        if stacks == nil or stacks <= 0 then return 0, 0, nil, stacks end
        return stacks, most, nil, stacks
    end
    local curr, max, remaining = readTimer(entry)
    local showsStacks = entry.stacksWhileUntimed and curr <= 0 and stacks ~= nil and stacks > 0
    if showsStacks then return stacks, most, nil, stacks end
    return curr, max, remaining, stacks
end

--- A buff's values now, read from the game at most once per Logic tick.
--- Stacks are reported on their own, so a buff with a timer and stacks
--- (Blood Tithe) reads its timer as its value and its stacks for $stacks;
--- one that shows its stacks while untimed (Electrified) reads them as its
--- value until its timer runs.
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
    groupMatches = {}
end

return activeBuffs
