-- Active buffs, read from the game's own vars (found by buff-catalogue) and,
-- for the buffs it decides, the game's buff bar. Every read of every kind of
-- buff asks the same two things in turn: what its vars say (whether it's
-- running, and its values), then whether a running buff counts as active
-- (its required var, and the bar for a buff the bar decides). A buff seen
-- starting counts as active for a grace, as both can lag its vars. Owns
-- timing each buff and following its max as it's extended or refreshed.

local gameApi = require("GameData/game-api")
local gameClock = require("GameData/Trackers/game-clock")
local abilityCooldowns = require("GameData/Trackers/ability-cooldowns")
local buffCatalogue = require("GameData/Catalogues/buff-catalogue")
local varCache = require("GameData/Trackers/var-cache")
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
-- How long (in Logic ticks: two server ticks) a buff seen starting counts
-- as active whatever its required var and the bar say. Both can lag its
-- other vars: a required var by a server tick (as Sunshine's area varbit
-- did), the bar a new icon by a few Logic ticks (and Greater Barge's until
-- its next redraw); without this the buff would show a tick late.
local GRACE_TICKS = 60
-- How close (in seconds) two buffs sharing a bar icon can be in time left
-- and still not be told apart by a bar slot's time: the bar shows whole
-- seconds, about a second off the end time.
local GROUP_TOLERANCE_SECONDS = 2
-- VarPlayers holding the server tick of the player's latest attack: an
-- ability's use, and a channel's end (its last hit).
-- TODO: check whether an interrupted channel's end moves to when it stopped.
local LAST_ATTACK_VARS = { "COMBATV2_GLOBAL_COOLDOWN_START", "COMBATV2_CHANNEL_END" }
-- A toggled buff's var holds this (or 0) while it's off: Debilitate's holds
-- the target's id, -1 without one.
local NO_TARGET = -1
-- What a toggled buff reads while on: 1 of 1.
local ON, TOGGLE_MAX = 1, 1
-- The most a buff shown as a percentage reads.
local FULL_PERCENT = 100
-- What a buff without other sprites on the bar has (see BuffEntry.barIcons).
local NO_ICONS = {}
-- A shared-icon group's match before it has had one.
local NONE_KEPT = {}

--- One run of a buff, from when its vars say it started to when they say it
--- stopped. It's kept while the buff runs, whether or not it counts as
--- active, so a timer carries on with the same max once it counts again
--- (stepping back into Sunshine).
---@class BuffRun
---@field kind string How it's read (see measureFor); a run read another way is a new run.
---@field key any What started it: a timer's end tick (see followKey), a start-timed buff's start tick, else true.
---@field max number? A timer's full length, grown by extensions.
---@field graceUntil integer? The Logic tick it counts as active until (see GRACE_TICKS); nil when it was found already running.

--- A buff's last Read, and the Logic tick it was read on.
---@class BuffReading
---@field logicTick integer
---@field curr number
---@field max number
---@field unrounded number?
---@field stacks integer?

---@type table<integer, BuffRun> Struct id to its run while it runs.
local runs = {}
---@type table<integer, BuffReading> Struct id to its last Read. Timers count Logic ticks, so reading more often than once a tick (20 ms) shows nothing new.
local readings = {}
---@type table<integer, integer> Struct id to the most stacks seen this session.
local maxStacks = {}
---@type table<string, table<integer, boolean>> BuffIconGroup.key to the members its last match of bar slots kept (see isShownInGroup).
local groupMatches = {}

local varPlayerValue = varCache.VarPlayer

--- Whether a buff has vars this can read.
---@type fun(entry: BuffEntry): boolean
activeBuffs.Handles = buffCatalogue.HasVars

--- The item a buff shows while it runs (see BuffEntry.objectVar).
---@param entry BuffEntry
---@return integer? objectID nil if it has none, or none is set.
function activeBuffs.Object(entry)
    if entry.objectVar == nil then return nil end
    local itemID = gameApi.ItemID(varPlayerValue(entry.objectVar))
    if itemID == nil or itemID < 0 then return nil end
    return itemID
end

--- The Logic tick an end-time VarClient holds (the client sets it, so it
--- never comes through VarTransmit). Its config is cached, so reading every
--- frame skips the lookup.
---@param varName string
---@return integer? endTick nil if it can't be read.
local function endTickOf(varName)
    local varConfig = gameApi.Cached(gameApi.VarClient, varName)
    return varConfig and tonumber(gameApi.VarValue(varConfig))
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

--- Whether a buff's requirement is met now: its required var (see
--- BuffEntry.requiredVar) is non-zero.
---@param entry BuffEntry
---@return boolean met Always true for a buff without one.
local function isRequirementMet(entry)
    if entry.requiredVar == nil then return true end
    return (tonumber(varPlayerValue(entry.requiredVar)) or 0) ~= 0
end

-- What the vars say, one function per way a buff is read (see measureFor).
-- Each gives whether it's running, then its value, max and unrounded value,
-- and the key its run starts from (see BuffRun.key). A max of nil is the
-- run's, for a timer, whose max follows its extensions.

--- A timed buff, from its end-time VarClient, the Logic tick it ends on.
---@param entry BuffEntry
---@param now integer Logic tick.
---@param run BuffRun?
local function measureTimer(entry, now, run)
    local endTick = endTickOf(entry.endVar)
    if endTick == nil or endTick <= now then return false, 0, run and run.max or 0 end
    local remaining = (endTick - now) / LOGIC_TICKS_PER_SECOND
    return true, gameClock.ToTenths(remaining), nil, remaining, endTick
end

--- A buff timed from its ability's use (Unsullied): it has only the
--- ability's _START VarPlayer (the server tick it was used, kept current by
--- the cooldown tracker), and lasts its duration from it.
---@param entry BuffEntry
local function measureStart(entry)
    local duration = entry.duration
    local start = tonumber(abilityCooldowns.VarValue(entry.startVar))
    local serverTick = abilityCooldowns.ServerTick()
    if start == nil or serverTick == nil then return false, 0, duration end
    local elapsed = (serverTick - start + gameClock.TickFraction()) * SECONDS_PER_SERVER_TICK
    local remaining = duration - elapsed
    if elapsed < 0 or remaining <= 0 then return false, 0, duration end
    return true, gameClock.ToTenths(remaining), duration, remaining, start
end

--- A buff with only stacks: they're its value too, and it runs while it has any.
---@param stacks integer?
---@param most integer?
local function measureStacks(_, _, _, stacks, most)
    if stacks == nil or stacks <= 0 then return false, 0, 0 end
    return true, stacks, most, nil, true
end

--- A toggled buff (no timer: Bone Shield, prayers): its var is a number
--- other than 0 or NO_TARGET while it's on (an OBJ var, the quiver's, gives
--- an item). One the bar decides (the porter) follows the bar both ways
--- while it can be read, as its var can be wrong (the porter's isn't set
--- again on login).
---@param entry BuffEntry
local function measureToggle(entry)
    local shown = entry.endsOffBuffBar and buffBar.ShownSeconds(entry.icon, entry.object) or nil
    local on
    if shown ~= nil then
        on = #shown > 0
    else
        local raw = varPlayerValue(entry.activeVar)
        local value = tonumber(raw) or gameApi.ItemID(raw)
        on = value ~= nil and value ~= 0 and value ~= NO_TARGET
    end
    if not on then return false, 0, TOGGLE_MAX end
    return true, ON, TOGGLE_MAX, nil, true
end

--- A buff that comes once the player has gone a while without attacking
--- (Greater Barge, see BuffEntry.quietTicks): it runs from their latest
--- attack plus its quiet ticks. Its required var is read here, as it says
--- whether the player has it at all, so a grace mustn't show it without
--- it. Before the server tick is known (just after entering the game,
--- before any ability use) the player counts as not attacking, as they're
--- out of combat on entering.
---@param entry BuffEntry
local function measureQuiet(entry)
    if not isRequirementMet(entry) then return false, 0, TOGGLE_MAX end
    local serverTick = abilityCooldowns.ServerTick()
    if serverTick ~= nil then
        local lastAttack = 0
        for _, varName in ipairs(LAST_ATTACK_VARS) do
            lastAttack = math.max(lastAttack, tonumber(varPlayerValue(varName)) or 0)
        end
        if serverTick < lastAttack + entry.quietTicks then return false, 0, TOGGLE_MAX end
    end
    return true, ON, TOGGLE_MAX, nil, true
end

--- How a buff is read, by the vars it has. A buff that shows its stacks
--- while untimed (Electrified) is read by its stacks until its timer runs.
---@param entry BuffEntry
---@param now integer Logic tick.
---@param stacks integer?
---@return string kind
---@return function measure
local function measureFor(entry, now, stacks)
    if entry.endVar ~= nil then
        local untimed = entry.stacksWhileUntimed and stacks ~= nil and stacks > 0
            and (endTickOf(entry.endVar) or 0) <= now
        if untimed then return "stacks", measureStacks end
        return "timer", measureTimer
    end
    if entry.startVar ~= nil then return "start", measureStart end
    if entry.quietTicks ~= nil then return "quiet", measureQuiet end
    if stacks == nil and entry.activeVar ~= nil then return "toggle", measureToggle end
    return "stacks", measureStacks
end

--- The running group member not yet matched that a bar slot's time left
--- points to. Any whose time left is within GROUP_TOLERANCE_SECONDS of the
--- closest could be it: of those, the one kept last time, else the
--- earliest. A slot whose time is unknown could be any of them.
---@param secondsLeft table<integer, number> Member index to its seconds left, for the running ones.
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
    if shown == nil then return true end
    local group = entry.iconGroup
    local secondsLeft, running = {}, 0
    for index, endVar in ipairs(group.endVars) do
        local endTick = endVar and endTickOf(endVar) or nil
        if endTick ~= nil and endTick > now then
            secondsLeft[index] = (endTick - now) / LOGIC_TICKS_PER_SECOND
            running = running + 1
        end
    end
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

--- Whether a running buff counts as active: it's in its grace, or its
--- requirement is met and, for a buff the bar decides (see
--- BuffEntry.endsOffBuffBar), the bar shows it, by its own icon or another
--- it shows for it (BuffEntry.barIcons). A bar that can't be read counts as
--- showing it.
---@param entry BuffEntry
---@param run BuffRun
---@param now integer Logic tick.
---@return boolean
local function counts(entry, run, now)
    if run.graceUntil ~= nil and now <= run.graceUntil then return true end
    if not isRequirementMet(entry) then return false end
    if not entry.endsOffBuffBar then return true end
    if entry.iconGroup ~= nil then return isShownInGroup(entry, now) end
    if not buffBar.HasDropped(entry.icon, entry.object) then return true end
    for _, icon in ipairs(entry.barIcons or NO_ICONS) do
        if not buffBar.HasDropped(icon) then return true end
    end
    return false
end

--- Follows a run's key moving. A timer's end tick moving later by a little
--- is an extension (Galeshot during Rapid Fire) and adds to its max; by more
--- it's a refresh, which starts the max over. Any other kind's key moving is
--- a new start (a recast). A refresh or new start is seen starting, so its
--- grace starts over (a new area, for an area buff).
---@param entry BuffEntry
---@param run BuffRun Changed in place.
---@param key any
---@param remaining number? Seconds left, for a timer.
---@param now integer Logic tick.
local function followKey(entry, run, key, remaining, now)
    local moved = run.kind == "timer" and key - run.key or math.huge
    run.key = key
    -- Earlier, or later by less than the jitter: followed without touching the max.
    if moved < JITTER_TICKS then return end
    local added = moved / LOGIC_TICKS_PER_SECOND
    if added <= EXTENSION_SECONDS then
        run.max = run.max + added
        return
    end
    if run.kind == "timer" then run.max = math.max(remaining, entry.duration or 0) end
    run.graceUntil = now + GRACE_TICKS
end

--- A buff's values now (see activeBuffs.Read).
---@param entry BuffEntry
---@param now integer Logic tick.
---@return number curr
---@return number max
---@return number? unrounded
---@return integer? stacks
local function readNow(entry, now)
    local id = entry.structID
    local stacks, most = readStacks(entry)
    local kind, measure = measureFor(entry, now, stacks)
    local run = runs[id]
    if run ~= nil and run.kind ~= kind then run = nil end
    local running, curr, max, unrounded, key = measure(entry, now, run, stacks, most)
    if not running then
        runs[id] = nil
        return 0, max, nil, stacks
    end
    if run == nil then
        -- Seen starting if it was read just before, else found already
        -- running (an aura made, picked or loaded mid-buff), which gets no
        -- grace so it doesn't flash on. A timer found part way takes the
        -- config duration as its max when there is one.
        local reading = readings[id]
        run = { kind = kind, key = key }
        if kind == "timer" then run.max = math.max(unrounded, entry.duration or 0) end
        if reading ~= nil and now - reading.logicTick <= GRACE_TICKS then run.graceUntil = now + GRACE_TICKS end
        runs[id] = run
    elseif key ~= run.key then
        followKey(entry, run, key, unrounded, now)
    end
    max = max or run.max
    if counts(entry, run, now) then return curr, max, unrounded, stacks end
    -- Off, though its run's kept. A buff read by its stacks has none while off.
    if kind == "stacks" then return 0, 0, nil, 0 end
    return 0, max, nil, stacks
end

--- A buff's values now, read from the game at most once per Logic tick.
--- Stacks are reported on their own, so a buff with a timer and stacks
--- (Blood Tithe) reads its timer as its value and its stacks for $stacks;
--- one that shows its stacks while untimed (Electrified) reads them as its
--- value until its timer runs. Everything reads as off until the game clock
--- has ticked.
---@param entry BuffEntry
---@return number curr Seconds left; for a buff with only stacks, the stacks; for a toggled one, 1 or 0.
---@return number max
---@return number? unrounded
---@return integer? stacks
function activeBuffs.Read(entry)
    local now = gameClock.LogicTick()
    if now == nil then return 0, 0, nil, nil end
    local reading = readings[entry.structID]
    if reading ~= nil and reading.logicTick == now then
        return reading.curr, reading.max, reading.unrounded, reading.stacks
    end
    local curr, max, unrounded, stacks = readNow(entry, now)
    if reading == nil then
        reading = {}
        readings[entry.structID] = reading
    end
    reading.logicTick, reading.curr, reading.max, reading.unrounded, reading.stacks = now, curr, max, unrounded, stacks
    return curr, max, unrounded, stacks
end

--- Forgets the buffs being followed, e.g. on leaving the game.
function activeBuffs.Reset()
    runs, readings, maxStacks, groupMatches = {}, {}, {}, {}
end

return activeBuffs
