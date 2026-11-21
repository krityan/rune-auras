-- Active buffs: whether each is running, from the game's vars (found by
-- buff-catalogue), whether it counts as active, and its values. The buff bar
-- fills in where vars fall short. Owns timing buffs and their worn-slot items.

local gameApi = require("GameData/game-api")
local gameClock = require("GameData/Trackers/game-clock")
local abilityCooldowns = require("GameData/Trackers/ability-cooldowns")
local abilityCatalogue = require("GameData/Catalogues/ability-catalogue")
local buffCatalogue = require("GameData/Catalogues/buff-catalogue")
local varCache = require("GameData/Trackers/var-cache")
local buffBar = require("GameData/Trackers/buff-bar")
local buffData = require("GameData/Catalogues/Buffs/buff-data")
local varChanges = require("GameData/Trackers/var-changes")
local wornEquipment = require("GameData/Trackers/worn-equipment")

local activeBuffs = {}

local LOGIC_TICKS_PER_SECOND = gameClock.LOGIC_TICKS_PER_SECOND
local SECONDS_PER_SERVER_TICK = gameClock.SECONDS_PER_SERVER_TICK
-- An end time moving later by at most this much is an extension rather
-- than a refresh: Galeshot gains a server tick (0.6s) at a time. Unless it
-- puts the timer back at its full length (see updateRunForNewKey).
local EXTENSION_SECONDS = 1.2
-- Moves smaller than this (in Logic ticks: half a server tick) are noise,
-- not extensions: counting them would ratchet the max up over a long buff
-- if the client ever rewrites an end time a tick or two either way.
local JITTER_TICKS = 15
-- How long (in Logic ticks: two server ticks) a buff seen starting counts as
-- active whatever its required var and the bar say: both can lag its other
-- vars by a tick or so, which would show it late.
local GRACE_TICKS = 60
-- How far apart (in Logic ticks: two server ticks) an ability's buff starting
-- and its use being reported can be, either way round, for the start to be
-- that use.
local USE_SLACK_TICKS = 60
-- How close (in seconds) two buffs sharing a bar icon can be in time left
-- and still not be told apart by a bar slot's time: the bar shows whole
-- seconds, about a second off the end time.
local GROUP_TOLERANCE_SECONDS = 2
-- VarPlayers holding the server tick of the player's latest attack: an
-- ability's use, and a channel's end (its last hit).
local LAST_ATTACK_VARS = { "COMBATV2_GLOBAL_COOLDOWN_START", "COMBATV2_CHANNEL_END" }
-- A toggled buff's var holds this (or 0) while it's off: Debilitate's holds
-- the target's id, -1 without one.
local NO_TARGET = -1
-- What a toggled buff reads while on: 1 of 1.
local ON, TOGGLE_MAX = 1, 1
-- The most a buff shown as a percentage reads.
local FULL_PERCENT = 100
-- How far behind the buff bar's timer can be when it's read: the bar
-- redraws every 10 Logic ticks, and is read at most every 10 (see buff-bar).
local BAR_LAG_TICKS = 20
local LOGIC_TICKS_PER_SERVER_TICK = gameClock.LOGIC_TICKS_PER_SERVER_TICK
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
---@field key any What started it: a timer's end tick (see updateRunForNewKey), a start-timed buff's start tick, otherwise true.
---@field max number? A timer's full length, grown by extensions.
---@field graceUntil integer? The Logic tick it counts as active until (see GRACE_TICKS); nil when it was found already running.
---@field counted boolean? Whether it counted as active at its last read (see isCountedActive).
---@field usedStruct integer? The struct last used when it started or was refreshed, for a buff in a use group (see isOtherInGroupUsed).

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
---@type table<integer, number> Struct id to the most a toggled buff's bar count has shown this session.
local maxCounts = {}

--- What's been worked out about a bar-timed buff's latest use (see
--- measureBarTimer).
---@class BarTiming
---@field castTick integer The Logic tick it was used.
---@field seconds integer? The bar's timer at the last read.
---@field endTick integer? The Logic tick it ends on, once known or guessed.
---@field settled boolean? Whether endTick is exact: it came from the timer stepping down.

---@type table<integer, BarTiming> Struct id to its bar-timed buff's latest use.
local barTimings = {}
---@type table<integer, integer> Struct id to its bar-timed buff's last length, in server ticks, for a use the bar doesn't show yet.
local barLengths = {}

local EVENT_ID = "runeAuras_activeBuffs"
-- The struct id of the ability or spell just used, sent again on every use.
local JUST_USED_VAR = "COMBATV2_JUST_USED_ABILITY"
---@type integer? The struct last used (JUST_USED_VAR), as it arrived.
local lastUsedStruct = nil
---@type table<string, integer> Ability key (see abilityCatalogue.Key) to the Logic tick its use was last reported (JUST_USED_VAR).
local usedTicks = {}
---@type table<integer, integer>? Struct id to its USE_GROUPS index, built in game.
local useGroups = nil
---@type integer? The server tick building useGroups last found none, so it's tried at most once a tick.
local useGroupsFailedTick = nil

-- Where the items remembered for buffs' worn-slot icons are saved, as
-- "STRUCT_NAME=itemID" pairs joined by commas.
local WORN_ICONS_STORAGE_KEY = "buffWornIcons"
---@type table<string, integer>? Struct name to the item last taken from its icon's slot (see WornIcon); loaded on first use.
local wornIcons = nil
---@type table<integer, string|false> Item id to its config name, false where it can't be read, as names don't change.
local itemConfigNames = {}
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
    if entry.objectVar == nil then
        return nil
    end

    local itemID = gameApi.ItemID(varPlayerValue(entry.objectVar))
    if itemID == nil or itemID < 0 then
        return nil
    end

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
    if entry.stacksVar == nil then
        return nil
    end

    local stacks = tonumber(varPlayerValue(entry.stacksVar)) or 0
    if entry.stacksPercent then
        if entry.stacksAtFull ~= nil then
            stacks = stacks * FULL_PERCENT // entry.stacksAtFull
        end

        return stacks, FULL_PERCENT
    end

    local most = math.max(maxStacks[entry.structID] or 0, stacks)
    maxStacks[entry.structID] = most
    return stacks, most
end

--- Whether a buff's requirement is met now: any of its required vars (see
--- BuffEntry.requiredVars) is non-zero.
---@param entry BuffEntry
---@return boolean met Always true for a buff without one.
local function isRequirementMet(entry)
    local requiredVars = entry.requiredVars
    if requiredVars == nil then
        return true
    end

    for _, varName in ipairs(requiredVars) do
        if (tonumber(varPlayerValue(varName)) or 0) ~= 0 then
            return true
        end
    end

    return false
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
    if endTick == nil or endTick <= now then
        return false, 0, run and run.max or 0
    end

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
    if start == nil or serverTick == nil then
        return false, 0, duration
    end

    local elapsed = (serverTick - start + gameClock.TickFraction()) * SECONDS_PER_SERVER_TICK
    local remaining = duration - elapsed
    if elapsed < 0 or remaining <= 0 then
        return false, 0, duration
    end

    return true, gameClock.ToTenths(remaining), duration, remaining, start
end

--- A buff with only stacks: they're its value too, and it runs while it has any.
---@param stacks integer?
---@param most integer?
local function measureStacks(_, _, _, stacks, most)
    if stacks == nil or stacks <= 0 then
        return false, 0, 0
    end

    return true, stacks, most, nil, true
end

--- Whether a toggled buff is on: its var is a number other than 0 or
--- NO_TARGET (an OBJ var, the quiver's, gives an item). One the bar decides
--- (the porter) follows the bar both ways while it can be read, as its var
--- can be wrong (the porter's isn't set again on login).
---@param entry BuffEntry
---@return boolean
local function isToggledOn(entry)
    local shown = entry.endsOffBuffBar and buffBar.ShownSeconds(entry.icon, entry.object) or nil
    if shown ~= nil then
        return #shown > 0
    end

    local raw = varPlayerValue(entry.activeVar)
    local value = tonumber(raw) or gameApi.ItemID(raw)
    return value ~= nil and value ~= 0 and value ~= NO_TARGET
end

--- The count the buff bar shows under a toggled buff (see
--- buffBar.ShownCount), by its icon or another the bar shows for it.
---@param entry BuffEntry
---@return number? count nil when the bar shows none.
local function barCount(entry)
    local count = buffBar.ShownCount(entry.icon, entry.object)
    for _, icon in ipairs(entry.barIcons or NO_ICONS) do
        if count ~= nil then
            break
        end

        count = buffBar.ShownCount(icon)
    end

    return count
end

--- A toggled buff (no timer: Bone Shield, prayers), on as isToggledOn
--- says. While on, its value is the count the bar shows under its icon
--- (Bone Shield's level, the porter's charges), over the most shown this
--- session, otherwise 1 of 1.
---@param entry BuffEntry
local function measureToggle(entry)
    local most = maxCounts[entry.structID] or TOGGLE_MAX
    if not isToggledOn(entry) then
        return false, 0, most
    end

    local count = barCount(entry)
    if count == nil then
        return true, ON, most, nil, true
    end

    most = math.max(most, count)
    maxCounts[entry.structID] = most
    return true, count, most, nil, true
end

--- The Logic tick a buff timed from its use ends on: a whole number of
--- server ticks after the use, the nearest to an estimate.
---@param castTick integer
---@param estimate number
---@return integer endTick
local function endOnServerTick(castTick, estimate)
    local serverTicks = math.max(1, math.floor((estimate - castTick) / LOGIC_TICKS_PER_SERVER_TICK + 0.5))
    return castTick + serverTicks * LOGIC_TICKS_PER_SERVER_TICK
end

--- Works out when a bar-timed buff ends from the bar's timer (seconds rounded
--- up, up to BAR_LAG_TICKS late). It's a guess until the timer first steps
--- down, which narrows the end to under a server tick.
---@param entry BuffEntry
---@param timing BarTiming Changed in place.
---@param now integer Logic tick.
local function followBarTimer(entry, timing, now)
    local shown = buffBar.ShownSeconds(entry.icon, entry.object)
    local seconds = shown and shown[1]
    if type(seconds) ~= "number" or seconds == timing.seconds or timing.settled then
        return
    end

    -- A bigger drop means reads were missed, so when it stepped isn't known.
    local steppedDown = timing.seconds ~= nil and seconds == timing.seconds - 1
    timing.seconds = seconds
    local shownEnd = now + seconds * LOGIC_TICKS_PER_SECOND
    -- Stepped down: it ends `seconds` after a step up to BAR_LAG_TICKS ago.
    -- Else it ends within the second (and the lag) before `seconds` from now.
    local slack = steppedDown and BAR_LAG_TICKS or LOGIC_TICKS_PER_SECOND + BAR_LAG_TICKS
    timing.endTick = endOnServerTick(timing.castTick, shownEnd - slack / 2)
    timing.settled = steppedDown
    barLengths[entry.structID] = (timing.endTick - timing.castTick) // LOGIC_TICKS_PER_SERVER_TICK
end

--- A toggled buff timed by the buff bar (Debilitate, see BuffEntry.barCastVar):
--- on as isToggledOn says, timed from its ability's use, ending as
--- followBarTimer works out. Until the bar shows this use, it takes the
--- last use's length, and without one reads 1 of 1.
---@param entry BuffEntry
---@param now integer Logic tick.
local function measureBarTimer(entry, now)
    if not isToggledOn(entry) then
        return false, 0, 0
    end

    local castTick = endTickOf(entry.barCastVar)
    if castTick == nil then
        return true, ON, TOGGLE_MAX, nil, true
    end

    local id = entry.structID
    local timing = barTimings[id]
    if timing == nil or timing.castTick ~= castTick then
        timing = { castTick = castTick }
        local length = barLengths[id]
        if length ~= nil then
            timing.endTick = castTick + length * LOGIC_TICKS_PER_SERVER_TICK
        end

        barTimings[id] = timing
    end

    followBarTimer(entry, timing, now)

    if timing.endTick == nil then
        return true, ON, TOGGLE_MAX, nil, castTick
    end

    local remaining = math.max(0, (timing.endTick - now) / LOGIC_TICKS_PER_SECOND)
    local length = (timing.endTick - castTick) / LOGIC_TICKS_PER_SECOND
    return true, gameClock.ToTenths(remaining), length, remaining, castTick
end

--- A buff that comes once the player stops attacking for a while (Greater
--- Barge, see BuffEntry.quietTicks): it runs from their latest attack plus its
--- quiet ticks, if they have its required var. Before the server tick is known,
--- the player counts as not attacking, as they enter the game out of combat.
---@param entry BuffEntry
local function measureQuiet(entry)
    if not isRequirementMet(entry) then
        return false, 0, TOGGLE_MAX
    end

    local serverTick = abilityCooldowns.ServerTick()
    if serverTick ~= nil then
        local lastAttack = 0
        for _, varName in ipairs(LAST_ATTACK_VARS) do
            lastAttack = math.max(lastAttack, tonumber(varPlayerValue(varName)) or 0)
        end

        if serverTick < lastAttack + entry.quietTicks then
            return false, 0, TOGGLE_MAX
        end
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
        if untimed then
            return "stacks", measureStacks
        end

        return "timer", measureTimer
    end

    if entry.startVar ~= nil then
        return "start", measureStart
    end

    if entry.quietTicks ~= nil then
        return "quiet", measureQuiet
    end

    if entry.barCastVar ~= nil then
        return "barTimer", measureBarTimer
    end

    if stacks == nil and entry.activeVar ~= nil then
        return "toggle", measureToggle
    end

    return "stacks", measureStacks
end

--- The running group member not yet matched that a bar slot's time left
--- points to. Any whose time left is within GROUP_TOLERANCE_SECONDS of the
--- closest could be it: of those, the one kept last time, otherwise the
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
            if keptBefore[index] then
                return index
            end

            earliest = earliest or index
        end
    end

    return earliest
end

--- Whether the buff bar still shows a buff that shares its icon with others
--- (see BuffEntry.iconGroup). When it shows fewer than are running, each slot is
--- matched to the member whose time left is closest, preferring the one kept
--- last time when the times can't tell them apart, then the earliest.
---@param entry BuffEntry
---@param now integer Logic tick.
---@return boolean
local function isShownInGroup(entry, now)
    local shown = buffBar.ShownSeconds(entry.icon, entry.object)
    if shown == nil then
        return true
    end

    local group = entry.iconGroup
    local secondsLeft, running = {}, 0
    for index, endVar in ipairs(group.endVars) do
        local endTick = endVar and endTickOf(endVar) or nil
        if endTick ~= nil and endTick > now then
            secondsLeft[index] = (endTick - now) / LOGIC_TICKS_PER_SECOND
            running = running + 1
        end
    end

    if #shown >= running then
        return true
    end

    local keptBefore = groupMatches[group.key] or NONE_KEPT
    local kept = {}
    for _, slotSeconds in ipairs(shown) do
        local index = closestMember(secondsLeft, #group.endVars, kept, slotSeconds, keptBefore)
        if index ~= nil then
            kept[index] = true
        end
    end

    groupMatches[group.key] = kept
    return kept[group.index] == true
end

--- The use group a buff's struct is in (see buff-data's USE_GROUPS).
---@param structID integer?
---@return integer? group nil for none.
local function useGroupOf(structID)
    if structID == nil then
        return nil
    end

    local serverTick = gameClock.ServerTicks()
    if useGroups == nil and serverTick ~= useGroupsFailedTick then
        useGroups = {}

        for index, names in ipairs(buffData.USE_GROUPS) do
            for _, name in ipairs(names) do
                local struct = gameApi.Struct(name)
                local id = struct and gameApi.ID(struct)
                if id ~= nil then
                    useGroups[id] = index
                end
            end
        end

        -- Config can be unreadable for a moment: try again next server
        -- tick, not on every read.
        if next(useGroups) == nil then
            useGroups, useGroupsFailedTick = nil, serverTick
        end
    end

    return useGroups and useGroups[structID]
end

--- Whether a buff sharing every var with others (see buff-data's
--- USE_GROUPS) is running only because another of them was used: the
--- ability used as it started or was refreshed was another in its group.
--- When that isn't known (found already running), it counts as the bar says.
---@param entry BuffEntry
---@param run BuffRun
---@return boolean
local function isOtherInGroupUsed(entry, run)
    local group = useGroupOf(entry.structID)
    if group == nil or run.usedStruct == nil then
        return false
    end

    return run.usedStruct ~= entry.structID and useGroupOf(run.usedStruct) == group
end

--- Whether a run's start can have been a use, so its grace applies: always,
--- unless it's an ability's buff whose ability wasn't reported used within
--- USE_SLACK_TICKS of it, either side (the use and the end time can arrive
--- in either order). Some resets rewrite every ability buff's end time as
--- though each was just used, with no use reported: the Altar of War's, and
--- Warp time's end (which also sets every cooldown's _START to that tick).
---@param entry BuffEntry
---@param run BuffRun Has a grace.
---@return boolean
local function isGraceFromUse(entry, run)
    if entry.ability == nil then
        return true
    end

    local usedTick = usedTicks[entry.ability]
    local startTick = run.graceUntil - GRACE_TICKS
    return usedTick ~= nil and math.abs(usedTick - startTick) <= USE_SLACK_TICKS
end

--- Whether a running buff counts as active: not running because another in its
--- use group was used, and either in its grace (when its start can have been
--- a use) or with its requirement met and, for a buff the bar decides
--- (BuffEntry.endsOffBuffBar), shown on the bar by any of its icons. A bar
--- that can't be read counts as showing it.
---@param entry BuffEntry
---@param run BuffRun
---@param now integer Logic tick.
---@return boolean
local function isCountedActive(entry, run, now)
    if isOtherInGroupUsed(entry, run) then
        return false
    end

    if run.graceUntil ~= nil and now <= run.graceUntil and isGraceFromUse(entry, run) then
        return true
    end

    if not isRequirementMet(entry) then
        return false
    end

    if not entry.endsOffBuffBar then
        return true
    end

    if entry.iconGroup ~= nil then
        return isShownInGroup(entry, now)
    end

    if not buffBar.HasDropped(entry.icon, entry.object) then
        return true
    end

    for _, icon in ipairs(entry.barIcons or NO_ICONS) do
        if not buffBar.HasDropped(icon) then
            return true
        end
    end

    return false
end

--- Updates a run whose key changed (see BuffRun.key). A timer's end moving
--- later by a little is an extension, which adds to its max; anything else is
--- a refresh or a new start (a recast), which starts its max and grace over.
---@param entry BuffEntry
---@param run BuffRun Changed in place.
---@param key any
---@param remaining number? Seconds left, for a timer.
---@param now integer Logic tick.
local function updateRunForNewKey(entry, run, key, remaining, now)
    local isTimer = run.kind == "timer"

    -- While it doesn't count as active, a moved end is a different use whose
    -- max no longer applies (a scripture switched to another god book can end
    -- earlier). Only a later end is a new use (Greater Fury again after it was
    -- spent), which gets a grace as the bar can show it a few ticks late.
    if isTimer and run.counted == false then
        if key > run.key then
            run.graceUntil = now + GRACE_TICKS
        end

        run.key = key
        run.max = math.max(remaining, entry.duration or 0)
        return
    end

    local movedTicks = isTimer and key - run.key or math.huge
    run.key = key

    -- Earlier, or later by less than the jitter: the max stays.
    if movedTicks < JITTER_TICKS then
        return
    end

    -- Back to full length is a refresh however little it moved: Essence
    -- Corruption is set 30 seconds ahead with each stack, often a second apart.
    local addedSeconds = movedTicks / LOGIC_TICKS_PER_SECOND
    local isBackToFull = isTimer and remaining >= run.max - JITTER_TICKS / LOGIC_TICKS_PER_SECOND
    local isExtension = addedSeconds <= EXTENSION_SECONDS and not isBackToFull
    if isExtension then
        run.max = run.max + addedSeconds
        return
    end

    if isTimer then
        run.max = math.max(remaining, entry.duration or 0)
    end

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
    if run ~= nil and run.kind ~= kind then
        run = nil
    end

    local running, curr, max, unrounded, key = measure(entry, now, run, stacks, most)
    if not running then
        runs[id] = nil
        return 0, max, nil, stacks
    end

    if run == nil then
        -- Seen starting if it was read just before, otherwise found already
        -- running (an aura made, picked or loaded mid-buff), which gets no
        -- grace so it doesn't flash on. A timer found part way takes the
        -- config duration as its max when there is one.
        local reading = readings[id]
        run = { kind = kind, key = key }

        if kind == "timer" then
            run.max = math.max(unrounded, entry.duration or 0)
        end

        if reading ~= nil and now - reading.logicTick <= GRACE_TICKS then
            run.graceUntil = now + GRACE_TICKS
            run.usedStruct = lastUsedStruct
        end

        runs[id] = run
    elseif key ~= run.key then
        updateRunForNewKey(entry, run, key, unrounded, now)
        run.usedStruct = lastUsedStruct
    end

    max = max or run.max
    run.counted = isCountedActive(entry, run, now)

    if run.counted then
        return curr, max, unrounded, stacks
    end

    -- Off, though its run's kept. A buff read by its stacks has none while off.
    if kind == "stacks" then
        return 0, 0, nil, 0
    end

    return 0, max, nil, stacks
end

--- A buff's values now, read at most once per Logic tick. Stacks are reported
--- separately: Blood Tithe's value is its timer, while Electrified's is its
--- stacks until its timer runs. Everything reads as off until the clock ticks.
---@param entry BuffEntry
---@return number curr Seconds left; for a buff with only stacks, the stacks; for a toggled one, the bar's count under it (see measureToggle), otherwise 1 or 0.
---@return number max
---@return number? unrounded
---@return integer? stacks
function activeBuffs.Read(entry)
    local now = gameClock.LogicTick()
    if now == nil then
        return 0, 0, nil, nil
    end

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

--- Loads the items remembered for buffs' worn-slot icons, once.
local function loadWornIcons()
    if wornIcons ~= nil then
        return
    end

    wornIcons = {}

    for structName, itemID in tostring(PersistentDB:GetString(WORN_ICONS_STORAGE_KEY) or ""):gmatch("([%w_]+)=(%d+)") do
        wornIcons[structName] = tonumber(itemID)
    end
end

--- Saves the items remembered for buffs' worn-slot icons.
local function saveWornIcons()
    local pairsList = {}
    for structName, itemID in pairs(wornIcons) do
        pairsList[#pairsList + 1] = structName .. "=" .. itemID
    end

    table.sort(pairsList)
    PersistentDB:SetString(WORN_ICONS_STORAGE_KEY, table.concat(pairsList, ","))
end

--- Whether an item's config name matches one of a buff's worn-icon
--- patterns (see BuffWornIcon.itemNames).
---@param wornIcon BuffWornIcon
---@param itemID integer
---@return boolean
local function isIconItem(wornIcon, itemID)
    local name = itemConfigNames[itemID]
    if name == nil then
        name = gameApi.ItemConfigName(itemID) or false
        itemConfigNames[itemID] = name
    end

    if not name then
        return false
    end

    for _, pattern in ipairs(wornIcon.itemNames) do
        if name:find(pattern) then
            return true
        end
    end

    return false
end

--- The item a buff shows as its icon from a worn slot (see BuffEntry.wornIcon):
--- what's worn there, if its name matches the buff's items or the buff is
--- active. It's remembered between sessions, and shown while the slot holds another.
---@param entry BuffEntry
---@return integer? itemID nil for a buff without a worn icon, or before any item has been taken.
function activeBuffs.WornIcon(entry)
    local wornIcon = entry.wornIcon
    local slot = wornIcon and wornEquipment.SLOTS[wornIcon.slot]
    if slot == nil then
        return nil
    end

    loadWornIcons()
    local worn = wornEquipment.Item(slot)
    local fits = worn ~= nil and (isIconItem(wornIcon, worn) or activeBuffs.Read(entry) > 0)
    if fits and worn ~= wornIcons[entry.structName] then
        wornIcons[entry.structName] = worn
        saveWornIcons()
    end

    return wornIcons[entry.structName]
end

--- Forgets the buffs being followed, e.g. on leaving the game.
function activeBuffs.Reset()
    runs, readings, maxStacks, maxCounts, groupMatches = {}, {}, {}, {}, {}
    barTimings, barLengths = {}, {}
    lastUsedStruct, usedTicks = nil, {}
    useGroups, useGroupsFailedTick = nil, nil
end

--- Notes the ability or spell just used (see buff-data's USE_GROUPS), and
--- when its ability's use was reported (see isGraceFromUse).
---@param name string
---@param value any
local function onVarChanged(name, value)
    if name ~= JUST_USED_VAR then
        return
    end

    lastUsedStruct = tonumber(value)
    local key = lastUsedStruct and abilityCatalogue.StructKey(lastUsedStruct)
    local now = gameClock.LogicTick()
    if key ~= nil and now ~= nil then
        usedTicks[key] = now
    end
end

--- Starts following which ability was used last. Call once, at load.
function activeBuffs.Start()
    varChanges.Listen(EVENT_ID, onVarChanged)
end

--- Stops following events.
function activeBuffs.Stop()
    varChanges.Unlisten(EVENT_ID)
end

return activeBuffs
