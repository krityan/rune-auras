-- Damage over time and debuffs the player has put on their targets
-- (TargetDebuffRun), timed from each use of the ability or spell that
-- applies them, since no var holds their time, and on the enemies a DoT
-- spreads to when its target dies. Which NPC is the target is
-- player-target's job.

local abilityCooldowns = require("GameData/Trackers/ability-cooldowns")
local gameApi = require("GameData/game-api")
local gameClock = require("GameData/Trackers/game-clock")
local playerState = require("GameData/Trackers/player-state")
local playerTarget = require("GameData/Trackers/player-target")
local targetDebuffCatalogue = require("GameData/Catalogues/target-debuff-catalogue")
local varChanges = require("GameData/Trackers/var-changes")

local targetDebuffs = {}

local EVENT_ID = "runeAuras_targetDebuffs"
local NO_TARGET = playerTarget.NONE
-- Greater Chain's extra targets, by NPC uid in vars numbered from 1: set when
-- Chain is cast, cleared on the tick of the use it passes on, just before
-- that use's _START arrives.
local CHAIN_TARGET_PREFIX = "COMBATV2_GREATER_CHAIN_CHILD_NPC_UID_"
-- The target info panel's 12 buff slots, which show the current target's effects.
local SLOT_PREFIX = "TOPLEVEL_V2_TARGET_INFO__GRAPHIC_"
local SLOT_COUNT = 12
-- Server ticks after a use before a missing icon counts.
local GRACE_TICKS = 2
-- Server ticks after a spell's cast before its missing icon counts.
local SPELL_GRACE_TICKS = 8
-- How many times longer the magic master cape's perk makes hex spells last.
local HEX_PERK_MULTIPLIER = 2
-- The struct id of the ability or spell just used, sent again on every use.
local JUST_USED_VAR = "COMBATV2_JUST_USED_ABILITY"
-- The server tick of the latest use of any ability or spell.
local CAST_TICK_VAR = "COMBATV2_GLOBAL_COOLDOWN_START"
-- Reads in a row without the DoT (its icon, or its target's NPC) before it counts as gone.
local ABSENT_READS = 2
local START_SUFFIX = "_START"

--- One use of what applies a DoT, on one target.
---@class TargetDebuffRun
---@field startTick integer The server tick of the use (its _START), of the death it spread from, or that a spell landed (its cast until it's seen to land).
---@field castTick integer? A spell's cast.
---@field lengthTicks integer? A spell's length, set at the cast (see castLength); nil for an ability's DoT.
---@field hasLanded boolean? A spell's icon has shown on the panel, or it refreshed one that had.
---@field landingTicks integer? Server ticks from a spell's cast to it landing, once seen, so a recast that refreshes it lands as far after its cast.
---@field spread boolean It spread from another target's death, so it lasts the spread's length.
---@field target integer The target's NPC uid.
---@field targetConfig integer? The target's NPC config id at the use, so an NPC uid reused by another NPC isn't taken for it; nil when the NPC list has no NPC for its uid, as for enemies in some areas, whose NPCTARGET ids the client's NPC list doesn't use.
---@field absentReads integer Reads in a row without the DoT.
---@field ended boolean It's gone from the target.

---@type table<string, table<integer, TargetDebuffRun>> Entry key to its runs by target.
local runs = {}
---@type table<string, integer> Entry key to the latest _START a run was made for.
local lastStarts = {}

--- Greater Chain's extra targets for one use.
---@class ChainedTargets
---@field logicTick integer? The Logic tick Chain's target vars were cleared on, which is the use's.
---@field targets integer[] Their NPC uids.

--- A DoT's _START arriving through VarTransmit.
---@class StartChange
---@field logicTick integer The Logic tick it arrived on.
---@field startTick integer Its value: the server tick of the use.
---@field target integer? The player's target as it arrived (NO_TARGET with none); nil if not yet known.

--- A use Greater Chain passed on.
---@class ChainedUse
---@field startTick integer The use's _START.
---@field targets integer[] Chain's extra targets, by NPC uid.

---@type ChainedTargets The extra targets Chain cleared most recently.
local clearedChain = { targets = {} }
---@type table<string, integer> Entry key to the server tick its latest spread began: when the player's target died with a run of it.
local spreadStarts = {}
---@type table<string, StartChange> Entry key to its latest _START change.
local startChanges = {}
---@type table<string, ChainedUse> Entry key to its latest use Chain passed on.
local chainedUses = {}
---@type table<string, string>? A DoT's _START var name to its entry key, built once.
local startVarKeys = nil
---@type string[]? The slots' sprite component names, built once.
local slotNames = nil
---@type table<integer, TargetDebuffEntry>? A spell's struct id to its entry, built in game.
local spellEntries = nil
---@type integer? The server tick of the latest use of any ability or spell (CAST_TICK_VAR).
local lastCastTick = nil
---@type table<string, integer> Entry key to the server ticks its spell's latest seen cast took to land.
local lastLandingTicks = {}

--- A DoT's length, or its spreads'.
---@param entry TargetDebuffEntry
---@param isSpread boolean
---@return integer ticks Server ticks from the use (or the death it spread from) until it ends.
local function durationTicks(entry, isSpread)
    if isSpread then return entry.spreadTicks or entry.durationTicks end
    return entry.durationTicks
end

--- A run's length: its own (a hex spell's, set at the cast), else its DoT's or spread's.
---@param entry TargetDebuffEntry
---@param run TargetDebuffRun
---@return integer ticks
local function runLength(entry, run)
    return run.lengthTicks or durationTicks(entry, run.spread)
end

--- A spell's length if cast now: doubled for a hex spell while the magic
--- master cape's perk is on.
---@param entry TargetDebuffEntry
---@return integer ticks
local function castLength(entry)
    local isDoubled = entry.isHex and playerState.HasMagicMasterPerk()
    if isDoubled then return entry.durationTicks * HEX_PERK_MULTIPLIER end
    return entry.durationTicks
end

--- A new run of a DoT on one target.
---@param startTick integer
---@param target integer An NPC uid.
---@param isSpread boolean Whether it spread from another target's death.
---@return TargetDebuffRun
local function newRun(startTick, target, isSpread)
    return {
        startTick = startTick,
        spread = isSpread,
        target = target,
        targetConfig = gameApi.NPCConfigID(target),
        absentReads = 0,
        ended = false,
    }
end

--- The target a use went on: the one the player had as its _START arrived
--- (the target var arrives first, so it's already the use's), else, for a
--- use found without its change (after a reload), the latest target.
---@param key string The DoT's entry key.
---@param startTick integer The use's _START.
---@return integer? target An NPC uid; nil if the player hasn't had one (or it isn't known yet).
local function useTarget(key, startTick)
    local change = startChanges[key]
    local isThisUse = change ~= nil and change.startTick == startTick
    if isThisUse and change.target ~= nil and change.target ~= NO_TARGET then return change.target end
    return playerTarget.Latest()
end

--- Whether a recast stage's _START was set by using the stage before it
--- (see TargetDebuffEntry.earlierStartVar), not by using this stage.
---@param entry TargetDebuffEntry
---@param startTick integer
---@return boolean
local function isSetByEarlierStage(entry, startTick)
    if entry.earlierStartVar == nil then return false end
    return abilityCooldowns.VarValue(entry.earlierStartVar .. START_SUFFIX) == startTick
end

--- Whether the player's weapon is the style a DoT's ability needs (see
--- TargetDebuffEntry.style); always true for one without a style.
---@param entry TargetDebuffEntry
---@return boolean
local function isUsedWithStyle(entry)
    if entry.style == nil then return true end
    return playerState.WeaponStyle() == entry.style
end

--- Makes a run for a new use of an ability that applies a DoT, on the
--- target it was used on, and on Greater Chain's extra targets when Chain
--- passed it on. A use whose target isn't known yet is tried again on the
--- next call. Spells' casts are recorded as they arrive (see onSpellCast).
---@param entry TargetDebuffEntry
local function recordUse(entry)
    if entry.startVar == nil then return end
    local startTick = abilityCooldowns.VarValue(entry.startVar .. START_SUFFIX)
    if startTick == nil or startTick <= 0 or startTick == lastStarts[entry.key] then return end
    if isSetByEarlierStage(entry, startTick) then return end
    if not isUsedWithStyle(entry) then
        -- Another style's ability set it; not tried again for this _START.
        lastStarts[entry.key] = startTick
        return
    end
    local target = useTarget(entry.key, startTick)
    if target == nil then return end
    lastStarts[entry.key] = startTick
    runs[entry.key] = runs[entry.key] or {}
    local isSpread = false
    runs[entry.key][target] = newRun(startTick, target, isSpread)
    local chained = chainedUses[entry.key]
    if chained == nil or chained.startTick ~= startTick then return end
    for _, chainTarget in ipairs(chained.targets) do
        if chainTarget ~= target then runs[entry.key][chainTarget] = newRun(startTick, chainTarget, isSpread) end
    end
end

--- Whether the current target has a DoT, by its flag varbit.
---@param entry TargetDebuffEntry
---@return boolean
local function isFlagged(entry)
    if entry.flagVar == nil then return false end
    local value = tonumber(gameApi.CachedVarPlayer(entry.flagVar))
    return value ~= nil and value > 0
end

--- Makes a spread run on the current target when the DoT spread recently
--- and the target's flag shows it, unless it has a run of its own. Spreads
--- only need a run once the player targets an enemy they reached, as a
--- source shows the current target's.
---@param entry TargetDebuffEntry
---@param now integer
local function recordSpread(entry, now)
    local spreadTick = spreadStarts[entry.key]
    local current = playerTarget.Current()
    if spreadTick == nil or current == nil or current == NO_TARGET then return end
    local isSpread = true
    if now - spreadTick > durationTicks(entry, isSpread) then
        spreadStarts[entry.key] = nil
        return
    end
    local existing = runs[entry.key] and runs[entry.key][current]
    if existing ~= nil and not existing.ended then return end
    if not isFlagged(entry) then return end
    runs[entry.key] = runs[entry.key] or {}
    runs[entry.key][current] = newRun(spreadTick, current, isSpread)
end

--- Whether a target has a live run of a DoT that spreads.
---@param entry TargetDebuffEntry
---@param target integer?
---@param now integer
---@return boolean
local function hasSpreadingRun(entry, target, now)
    if entry.spreadTicks == nil or target == nil then return false end
    local run = runs[entry.key] and runs[entry.key][target]
    return run ~= nil and not run.ended and now - run.startTick <= runLength(entry, run)
end

--- Notes the player's target being lost with a run of a spreading DoT on
--- it, which is how its death shows (NPCTARGET goes to NO_TARGET first).
---@param target integer The NPC uid the player had targeted.
local function onTargetLost(target)
    local now = abilityCooldowns.ServerTick()
    if now == nil then return end
    for _, entry in ipairs(targetDebuffCatalogue.ENTRIES) do
        if hasSpreadingRun(entry, target, now) then
            spreadStarts[entry.key] = now
        end
        -- A target the NPC list can't find can't be seen to die once it's
        -- off the panel, and losing it is most often its death, so its runs end.
        local run = runs[entry.key] and runs[entry.key][target]
        if run ~= nil and run.targetConfig == nil then run.ended = true end
    end
end

--- A run's server ticks left, unrounded.
---@param entry TargetDebuffEntry
---@param run TargetDebuffRun
---@param now integer
---@return number ticks 0 once it's over; at most its length, while a refresh is in flight.
local function ticksLeft(entry, run, now)
    if run.ended then return 0 end
    local length = runLength(entry, run)
    local left = run.startTick + length - now - gameClock.TickFraction()
    return math.max(0, math.min(length, left))
end

--- A DoT's time left on one target, from the use's tick and its length; 0
--- once it's gone.
---@param entry TargetDebuffEntry
---@param target integer? An NPC uid; nil for none.
---@return number remaining Seconds, to a tenth.
---@return number total Seconds.
---@return number unrounded The remaining time unrounded, for a bar that moves every frame.
local function readOn(entry, target)
    local now = abilityCooldowns.ServerTick()
    if now ~= nil then recordUse(entry) end
    local run = target ~= nil and runs[entry.key] and runs[entry.key][target] or nil
    if now == nil or run == nil then
        local isSpread = false
        local length = entry.spell ~= nil and castLength(entry) or durationTicks(entry, isSpread)
        return 0, gameClock.TicksToSeconds(length), 0
    end
    local total = gameClock.TicksToSeconds(runLength(entry, run))
    local remaining = gameClock.TicksToSeconds(ticksLeft(entry, run, now))
    return gameClock.ToTenths(remaining), total, remaining
end

--- A DoT's time left on the current target, else the latest one the player
--- had (playerTarget.Latest); see readOn.
---@param entry TargetDebuffEntry
---@return number remaining Seconds, to a tenth.
---@return number total Seconds.
---@return number unrounded
function targetDebuffs.Read(entry)
    return readOn(entry, playerTarget.Latest())
end

--- The sprites the target info panel shows for the current target.
---@return table<integer, boolean>? icons The sprites in its buff slots; nil while the game has the panel unloaded (no target, or the panel turned off).
---@return integer filled How many slots show something.
local function readPanel()
    if slotNames == nil then
        slotNames = {}
        for index = 0, SLOT_COUNT - 1 do slotNames[#slotNames + 1] = SLOT_PREFIX .. index end
    end
    local icons, filled = {}, 0
    for _, name in ipairs(slotNames) do
        local combinedID = gameApi.Cached(gameApi.ComponentID, name)
        local slot = combinedID and gameApi.ComponentByID(combinedID)
        if slot == nil then return nil, 0 end
        local sprite = gameApi.SpriteID(slot)
        if sprite ~= nil and sprite >= 0 then
            icons[sprite] = true
            filled = filled + 1
        end
    end
    return icons, filled
end

--- Notes whether a run's debuff was found on a read, ending it after enough
--- reads in a row without it.
---@param entry TargetDebuffEntry
---@param run TargetDebuffRun
---@param now integer
---@param isPresent boolean
local function noteRead(entry, run, now, isPresent)
    if isPresent then
        run.absentReads = 0
        return
    end
    -- A spell's projectile can take several ticks to land.
    local isInFlight = entry.spell ~= nil and not run.hasLanded
    local graceTicks = isInFlight and SPELL_GRACE_TICKS or GRACE_TICKS
    if now - run.startTick <= graceTicks then return end
    run.absentReads = run.absentReads + 1
    if run.absentReads >= ABSENT_READS then run.ended = true end
end

--- Whether a run's target is still in the world: its NPC uid still names
--- an NPC of the same config. A target the NPC list couldn't find at the
--- use (see TargetDebuffRun.targetConfig) can't be checked, so it counts
--- as there, and only its length or the panel ends it.
---@param run TargetDebuffRun
---@return boolean
local function isTargetLoaded(run)
    if run.targetConfig == nil then return true end
    return gameApi.NPCConfigID(run.target) == run.targetConfig
end

--- Whether a run is still going: not ended, and within its length.
---@param entry TargetDebuffEntry
---@param run TargetDebuffRun
---@param now integer
---@return boolean
local function isRunning(entry, run, now)
    return not run.ended and now - run.startTick <= runLength(entry, run)
end

--- Times a spell's run from when it landed: the panel shows an effect from
--- the server tick after it's applied.
---@param entry TargetDebuffEntry
---@param run TargetDebuffRun
---@param shownTick integer The server tick its icon first showed.
local function noteLanded(entry, run, shownTick)
    run.hasLanded = true
    run.startTick = math.max(run.castTick, shownTick - 1)
    run.landingTicks = run.startTick - run.castTick
    lastLandingTicks[entry.key] = run.landingTicks
end

--- Whether one of our binds holds a target, so another bind cast on it does nothing.
---@param target integer
---@param now integer
---@return boolean
local function isBound(target, now)
    for _, entry in ipairs(targetDebuffCatalogue.ENTRIES) do
        local run = entry.isBind and runs[entry.key] and runs[entry.key][target]
        if run and isRunning(entry, run, now) then return true end
    end
    return false
end

--- The catalogue entry of a spell, by its struct id.
---@param structID integer
---@return TargetDebuffEntry? entry nil for anything else (abilities, other spells).
local function spellEntry(structID)
    if spellEntries == nil then
        spellEntries = {}
        for _, entry in ipairs(targetDebuffCatalogue.ENTRIES) do
            local struct = entry.spell and gameApi.Struct(entry.spell)
            local spellID = struct and gameApi.ID(struct)
            if spellID ~= nil then spellEntries[spellID] = entry end
        end
        -- Config can be unreadable for a moment; try again next cast.
        if next(spellEntries) == nil then spellEntries = nil end
    end
    return spellEntries and spellEntries[structID]
end

--- Makes a run for a spell cast on a target. A recast on a target it's
--- still on refreshes it, landing as long after the cast as the last one
--- did. One already on the panel as it's cast may be an instant spell
--- that landed with the cast, or another player's, so it lands as long
--- after the cast as this spell's last seen cast did (at the cast if none
--- has been seen).
---@param entry TargetDebuffEntry
---@param castTick integer
---@param target integer An NPC uid.
local function recordCast(entry, castTick, target)
    local now = abilityCooldowns.ServerTick() or castTick
    if entry.isBind and isBound(target, now) then return end
    runs[entry.key] = runs[entry.key] or {}
    local previous = runs[entry.key][target]
    local isSpread = false
    local run = newRun(castTick, target, isSpread)
    run.castTick = castTick
    run.lengthTicks = castLength(entry)
    local isRefresh = previous ~= nil and previous.hasLanded and isRunning(entry, previous, now)
    if isRefresh then
        run.hasLanded, run.landingTicks = true, previous.landingTicks
        run.startTick = castTick + previous.landingTicks
    elseif target == playerTarget.Current() then
        local icons = readPanel()
        if icons ~= nil and icons[entry.icon] then
            run.hasLanded, run.landingTicks = true, lastLandingTicks[entry.key] or 0
            run.startTick = castTick + run.landingTicks
        end
    end
    runs[entry.key][target] = run
end

--- Notes a spell being cast, on the player's target, if it's one of ours.
--- Values sent on entering the game are past uses, so they're ignored.
---@param structID integer?
local function onSpellCast(structID)
    if structID == nil or not abilityCooldowns.IsSettled() then return end
    local entry = spellEntry(structID)
    if entry == nil then return end
    local target = playerTarget.Current()
    if target == nil or target == NO_TARGET then target = playerTarget.Latest() end
    local castTick = lastCastTick or abilityCooldowns.ServerTick()
    if target == nil or castTick == nil then return end
    recordCast(entry, castTick, target)
end

--- Follows every running DoT once a server tick: the current target's on
--- the panel, others' by whether their NPC is still there. Drops runs that
--- are over.
local function onServerTick()
    local now = abilityCooldowns.ServerTick()
    if now == nil then return end
    local followed = {}
    for _, entry in ipairs(targetDebuffCatalogue.ENTRIES) do
        recordUse(entry)
        recordSpread(entry, now)
        for target, run in pairs(runs[entry.key] or {}) do
            if isRunning(entry, run, now) then
                followed[#followed + 1] = { entry = entry, run = run }
            else
                runs[entry.key][target] = nil
            end
        end
    end
    if #followed == 0 then return end
    local current = playerTarget.Current()
    local icons, filled = nil, 0
    if current ~= NO_TARGET then icons, filled = readPanel() end
    for _, item in ipairs(followed) do
        local entry, run = item.entry, item.run
        local isOnPanel = icons ~= nil and run.target == current
        if isOnPanel then
            -- The flag where the game sets it; the icon covers dummies, which don't.
            local hasIcon = icons[entry.icon] == true or isFlagged(entry)
            -- With every slot full, the DoT may be on the target but not shown, so it isn't ended.
            local isPanelFull = filled >= SLOT_COUNT
            if hasIcon and entry.spell ~= nil and not run.hasLanded then noteLanded(entry, run, now) end
            noteRead(entry, run, now, hasIcon or isPanelFull)
        else
            noteRead(entry, run, now, isTargetLoaded(run))
        end
    end
end

--- Notes a DoT's _START arriving, as Chain's for its use if Chain's extra
--- targets were cleared on the same Logic tick.
---@param key string The DoT's entry key.
---@param startTick integer?
local function onStartChanged(key, startTick)
    if startTick == nil or startTick <= 0 then return end
    local logicTick = gameClock.LogicTick()
    startChanges[key] = { logicTick = logicTick, startTick = startTick, target = playerTarget.Current() }
    if clearedChain.logicTick == logicTick then
        chainedUses[key] = { startTick = startTick, targets = clearedChain.targets }
    end
end

--- Notes one of Chain's extra targets being cleared, which happens on the
--- tick of the use Chain passes on, and links it to any DoT _START that
--- arrived on the same Logic tick.
---@param target integer The NPC uid the var held.
local function onChainTargetCleared(target)
    local logicTick = gameClock.LogicTick()
    if clearedChain.logicTick ~= logicTick then clearedChain = { logicTick = logicTick, targets = {} } end
    local targets = clearedChain.targets
    targets[#targets + 1] = target
    for key, change in pairs(startChanges) do
        if change.logicTick == logicTick then
            chainedUses[key] = { startTick = change.startTick, targets = targets }
        end
    end
end

--- Follows spell casts, Chain's extra targets and the DoTs' _STARTs. This
--- runs for every var change in the game, so it sticks to a lookup and
--- plain-text checks.
---@param name string
---@param value any
---@param oldValue any
local function onVarChanged(name, value, oldValue)
    if name == CAST_TICK_VAR then
        lastCastTick = tonumber(value)
        return
    end
    if name == JUST_USED_VAR then
        onSpellCast(tonumber(value))
        return
    end
    if startVarKeys == nil then
        startVarKeys = {}
        for _, entry in ipairs(targetDebuffCatalogue.ENTRIES) do
            if entry.startVar ~= nil then startVarKeys[entry.startVar .. START_SUFFIX] = entry.key end
        end
    end
    local key = startVarKeys[name]
    if key ~= nil then
        onStartChanged(key, tonumber(value))
        return
    end
    if string.find(name, CHAIN_TARGET_PREFIX, 1, true) ~= 1 then return end
    local oldTarget = tonumber(oldValue)
    if tonumber(value) == NO_TARGET and oldTarget ~= nil and oldTarget ~= NO_TARGET then
        onChainTargetCleared(oldTarget)
    end
end

--- Forgets the runs, Chain's targets, spreads, the latest cast and spells' landing times, e.g. on leaving the game.
function targetDebuffs.Reset()
    runs, lastStarts = {}, {}
    clearedChain, startChanges, chainedUses = { targets = {} }, {}, {}
    spreadStarts = {}
    lastCastTick = nil
    lastLandingTicks = {}
end

--- Starts following the DoTs' uses and the target being lost, and reading
--- the panel each server tick. Call once, at load, after playerTarget.Start.
function targetDebuffs.Start()
    playerTarget.SetOnLost(onTargetLost)
    varChanges.Listen(EVENT_ID, onVarChanged)
    Event.ServerLogic.Subscribe(EVENT_ID, onServerTick)
end

--- Stops following events.
function targetDebuffs.Stop()
    playerTarget.SetOnLost(nil)
    varChanges.Unlisten(EVENT_ID)
    Event.ServerLogic.Unsubscribe(EVENT_ID)
end

return targetDebuffs
