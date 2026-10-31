-- Ability and special attack cooldowns and charges, from game vars. Each
-- ability has a VarPlayer pair COMBATV2_COOLDOWN_<SKILL>_<ABILITY>_START and
-- _END holding the server tick it was used on and the tick it comes off
-- cooldown; special attacks' pairs are named otherwise but work the same.
-- Nothing exposes the current server tick, so this keeps its own clock: it
-- counts ServerLogic events (one per tick) and syncs that count with the
-- server whenever a _START var changes, since a fresh _START is "now", or
-- after a reload from the latest _START's _START_CLIENT.

local abilityCatalogue = require("GameData/Catalogues/ability-catalogue")
local gameClock = require("GameData/Trackers/game-clock")
local gameApi = require("GameData/game-api")
local varChanges = require("GameData/Trackers/var-changes")

local abilityCooldowns = {}

local EVENT_ID = "runeAuras_abilityCooldowns"
-- Entering the game sends every var's saved value, including _START ticks
-- from past uses. Those aren't "now", so _START changes are ignored for
-- this many ticks after entering the game.
local SETTLE_TICKS = 3
-- A _START up to this many ticks older than the clock still syncs it.
local CLOCK_SLACK_TICKS = 1
local ONE_CHARGE, TWO_CHARGES = 1, 2

-- ServerLogic events counted since loading.
local localTick = 0
-- serverTick = localTick + tickOffset, once known.
local tickOffset = nil
-- Ticks left before _START changes count as ability uses again.
local settleTicks = SETTLE_TICKS
---@type table<string, integer> Var base name to the full cooldown in ticks, last seen while on cooldown, for when a reset zeroes _END.
local lastTotals = {}
-- Cooldown var name to its value (false if it can't be read). The vars only
-- change through VarTransmit, which updates this, so drawing every frame
-- reads Lua instead of asking the game each time.
local cachedValues = {}
---@type table<string, { startName: string, endName: string }> Var base name to its var names, built once.
local varNames = {}
-- Every cooldown var base the sources use (see Watch), and the highest
-- _START tick seen. A _START is always in the past, so the server tick is at
-- least that: any cooldown ending by then is over, even before the clock is
-- synced by an ability use.
local watched = {}
local watchedSet = {}
local watchedScanned = false
local highestStart = nil
-- The highest _START with a _START_CLIENT, to sync the clock from after a
-- reload: an ability's, never a second charge's or a special attack's (not
-- all have one).
local syncStart = nil
---@type string?
local syncStartName = nil
-- The ServerLogic count (localTick) syncFromClient last tried on.
local syncTriedTick = nil

-- Bumped whenever a cached cooldown var changes or the clock is reset, so
-- results computed before it are recalculated.
local varVersion = 0
-- Var base name to the last GetCooldown result and what it depended on.
-- Every input changes only on a game event, never between frames, so a
-- frame with no new event reuses it (and auras sharing an ability share it).
---@type table<string, { remaining: number?, total: number?, unrounded: number?, logicTick: integer?, localTick: integer?, tickOffset: integer?, varVersion: integer }>
local results = {}

local readVarPlayer = gameApi.VarPlayer

-- A few abilities (Surge, Escape, Barge) can hold a second charge, timed by
-- a second var pair, <base>_CHARGE2_START/_END.
local CHARGE2_SUFFIX = "_CHARGE2"
local COOLDOWN_VAR_PREFIX = abilityCatalogue.COOLDOWN_VAR_PREFIX
-- Necromancy guards' special attack cooldowns share abilities' prefix, but
-- not all have a _START_CLIENT (Soul Crush's hasn't).
local WEAPON_COOLDOWN_PREFIX = COOLDOWN_VAR_PREFIX .. "WEAPON_"
-- A cooldown's vars are its base name with these: the server tick it started and ends on.
local START_SUFFIX, END_SUFFIX = "_START", "_END"
-- A _START's VarClient counterpart holds the client Logic tick of the same cast.
local CLIENT_SUFFIX = "_CLIENT"
local TWO_CHARGES_STORAGE_KEY = "abilityTwoCharges"
---@type table<string, boolean>? Var base names of abilities seen with a second charge; loaded from storage on first use.
local twoCharges = nil

--- Loads which abilities have a second charge, once.
local function loadTwoCharges()
    if twoCharges ~= nil then return end
    twoCharges = {}
    for varBase in tostring(PersistentDB:GetString(TWO_CHARGES_STORAGE_KEY) or ""):gmatch("[^,]+") do
        twoCharges[varBase] = true
    end
end

--- Notes, and saves, that an ability has a second charge. Nothing says
--- whether the player has one (both read 0 until used), so an ability
--- counts as having it once its CHARGE2 vars are seen in use.
---@param name string One of its CHARGE2 var names.
local function noteSecondCharge(name)
    local varBase = string.match(name, "^(.-)" .. CHARGE2_SUFFIX .. "_")
    if varBase == nil then return end
    loadTwoCharges()
    if twoCharges[varBase] then return end
    twoCharges[varBase] = true
    local list = {}
    for base in pairs(twoCharges) do list[#list + 1] = base end
    table.sort(list)
    PersistentDB:SetString(TWO_CHARGES_STORAGE_KEY, table.concat(list, ","))
end

--- A cooldown's _START and _END var names.
---@param varBase string
---@return { startName: string, endName: string }
local function namesFor(varBase)
    local names = varNames[varBase]
    if names == nil then
        names = { startName = varBase .. START_SUFFIX, endName = varBase .. END_SUFFIX }
        varNames[varBase] = names
    end
    return names
end

--- Raises the lower bound on the server tick to a _START value, and notes
--- the latest ability _START to sync the clock from (see syncFromClient).
---@param value number?
---@param name string The _START var.
local function noteStart(value, name)
    if value == nil or value <= 0 then return end
    if highestStart == nil or value > highestStart then highestStart = value end
    local isAbility = string.sub(name, 1, #COOLDOWN_VAR_PREFIX) == COOLDOWN_VAR_PREFIX
        and string.sub(name, 1, #WEAPON_COOLDOWN_PREFIX) ~= WEAPON_COOLDOWN_PREFIX
    local hasClientVar = isAbility and string.find(name, CHARGE2_SUFFIX, 1, true) == nil
    if hasClientVar and (syncStart == nil or value > syncStart) then
        syncStart, syncStartName = value, name
    end
end

--- A cooldown var's value, from the cache, reading the game on a miss.
---@param name string
---@return number? value nil if it can't be read.
local function readCached(name)
    local value = cachedValues[name]
    if value == nil then
        value = readVarPlayer(name)
        if value == nil then value = false end
        cachedValues[name] = value
    end
    return value or nil
end

local ticksToSeconds = gameClock.TicksToSeconds

local toTenths = gameClock.ToTenths

--- Registers a cooldown so its _START counts towards the lower bound on the
--- server tick. The data sources register every ability and special attack.
---@param varBase string E.g. COMBATV2_COOLDOWN_STRENGTH_BERSERK.
function abilityCooldowns.Watch(varBase)
    if watchedSet[varBase] then return end
    watchedSet[varBase] = true
    watched[#watched + 1] = varBase
    -- Include it in the next lower-bound scan.
    watchedScanned = false
end

--- The highest _START tick known, reading every watched ability's _START
--- once (a reload mid-session has had no var updates yet).
---@return number?
local function tickLowerBound()
    if not watchedScanned then
        watchedScanned = true
        for _, varBase in ipairs(watched) do
            local startName = namesFor(varBase).startName
            noteStart(readCached(startName), startName)
        end
    end
    return highestStart
end

--- A cooldown var's value (a _START or _END, e.g. an ability's
--- COMBATV2_COOLDOWN_<name>_START), from the cache VarTransmit keeps current, so it costs nothing to
--- read every frame.
---@param name string
---@return number? value nil if there's none.
function abilityCooldowns.VarValue(name)
    return readCached(name)
end

--- Syncs the clock from the latest ability use, for when none has been
--- seen since loading (a reload): its _START_CLIENT is the Logic tick of the
--- server tick its _START holds.
local function syncFromClient()
    local logicTick = gameClock.LogicTick()
    -- Scans the watched _STARTs, which finds syncStart after a reload.
    tickLowerBound()
    if syncStart == nil or logicTick == nil then return end
    local varConfig = gameApi.Cached(gameApi.VarClient, syncStartName .. CLIENT_SUFFIX)
    local startClient = varConfig and tonumber(gameApi.VarValue(varConfig))
    if startClient == nil or startClient < 0 or startClient > logicTick then return end
    local ticksSince = (logicTick - startClient) / gameClock.LOGIC_TICKS_PER_SERVER_TICK
    tickOffset = math.floor(syncStart + ticksSince - gameClock.TickFraction() + 0.5) - localTick
end

--- The current server tick, syncing the clock from the latest use's
--- _START_CLIENT if no use has yet (tried once a server tick).
---@return integer? tick nil until the clock is synced.
function abilityCooldowns.ServerTick()
    if tickOffset == nil and syncTriedTick ~= localTick then
        syncTriedTick = localTick
        syncFromClient()
    end
    if tickOffset == nil then return nil end
    return localTick + tickOffset
end

--- Times a cooldown from its vars. The vars only change once a server
--- tick, so the time left is extrapolated through the current tick (see
--- game-clock).
---@param varBase string
---@return number? remaining Seconds, to a tenth; 0 when ready; nil when it can't be timed yet.
---@return number? total Seconds.
---@return number? unrounded The remaining time unrounded, for a bar that moves every frame.
local function computeCooldown(varBase)
    local names = namesFor(varBase)
    local startTick = readCached(names.startName)
    local endTick = readCached(names.endName)
    if startTick == nil or endTick == nil then return nil end
    if endTick > startTick then lastTotals[varBase] = endTick - startTick end
    local total = lastTotals[varBase] or 0

    -- Some resets (e.g. War's Altar) set _END to 0.
    if endTick <= 0 then return 0, ticksToSeconds(total), 0 end

    local now = abilityCooldowns.ServerTick()
    if now == nil then
        -- Not synced yet, but a cooldown that ended before the latest
        -- known ability use is certainly over.
        local lowerBound = tickLowerBound()
        if lowerBound ~= nil and endTick <= lowerBound then return 0, ticksToSeconds(total), 0 end
        return nil
    end
    local remaining = ticksToSeconds(math.max(0, endTick - now - gameClock.TickFraction()))
    return toTenths(remaining), ticksToSeconds(total), remaining
end

--- A cooldown, computed at most once per game event (see `results`).
---@param varBase string E.g. COMBATV2_COOLDOWN_STRENGTH_BERSERK.
---@return number? remaining Seconds, to a tenth; 0 when ready; nil when it can't be timed yet (running, with the clock not synced).
---@return number? total Seconds.
---@return number? unrounded
function abilityCooldowns.GetCooldown(varBase)
    local logicTick = gameClock.LogicTick()
    local result = results[varBase]
    if result == nil then
        result = {}
        results[varBase] = result
    elseif result.logicTick == logicTick and result.localTick == localTick
        and result.tickOffset == tickOffset and result.varVersion == varVersion then
        return result.remaining, result.total, result.unrounded
    end
    result.remaining, result.total, result.unrounded = computeCooldown(varBase)
    result.logicTick, result.localTick = logicTick, localTick
    result.tickOffset, result.varVersion = tickOffset, varVersion
    return result.remaining, result.total, result.unrounded
end

--- How many charges an ability has ready. Seen in game with Surge: using a
--- charge while both are ready sets only CHARGE2 (the ability stays
--- usable); using the last sets the base vars, whose cooldown runs until a
--- charge is back, and CHARGE2_END is when both are.
---@param varBase string
---@return integer? ready 0 while the base cooldown runs, 1 while only CHARGE2 does, else the most; nil when it can't be timed yet.
---@return integer? most 1, or 2 once a second charge has been seen.
function abilityCooldowns.GetCharges(varBase)
    local remaining = abilityCooldowns.GetCooldown(varBase)
    if remaining == nil then return nil end
    loadTwoCharges()
    if not twoCharges[varBase] then return remaining > 0 and 0 or ONE_CHARGE, ONE_CHARGE end
    if remaining > 0 then return 0, TWO_CHARGES end
    local secondRemaining = abilityCooldowns.GetCooldown(varBase .. CHARGE2_SUFFIX)
    local secondRecharging = secondRemaining ~= nil and secondRemaining > 0
    return secondRecharging and ONE_CHARGE or TWO_CHARGES, TWO_CHARGES
end

--- Like GetCooldown, but for an ability with a second charge it times
--- whichever charge comes back next: the base cooldown while none are left,
--- else the second charge recharging (the ability is usable meanwhile).
---@param varBase string
---@return number? remaining
---@return number? total
---@return number? unrounded
function abilityCooldowns.GetNextCharge(varBase)
    local remaining, total, unrounded = abilityCooldowns.GetCooldown(varBase)
    if remaining == nil or remaining > 0 then return remaining, total, unrounded end
    loadTwoCharges()
    if not twoCharges[varBase] then return remaining, total, unrounded end
    local secondRemaining, secondTotal, secondUnrounded = abilityCooldowns.GetCooldown(varBase .. CHARGE2_SUFFIX)
    if secondRemaining == nil or secondRemaining <= 0 then return remaining, total, unrounded end
    return secondRemaining, secondTotal, secondUnrounded
end

--- Whether a var is a cooldown's _START or _END. This runs for every var
--- change in the game, so it sticks to plain-text checks (no patterns) and
--- leaves most names after one find.
---@param name string
---@return "start"|"end"|nil
local function cooldownVarKind(name)
    if string.find(name, "COOLDOWN", 1, true) == nil then return nil end
    if string.sub(name, -#START_SUFFIX) == START_SUFFIX then return "start" end
    if string.sub(name, -#END_SUFFIX) == END_SUFFIX then return "end" end
    return nil
end

--- Forgets the tick clock, e.g. on leaving the game: the server keeps
--- ticking while ServerLogic doesn't fire, so the old offset would be behind.
function abilityCooldowns.Reset()
    tickOffset = nil
    settleTicks = SETTLE_TICKS
    -- Entering the game resends every var, refilling these.
    cachedValues = {}
    varVersion = varVersion + 1
    highestStart, syncStart, syncStartName = nil, nil, nil
    watchedScanned = false
    syncTriedTick = nil
end

--- Follows a var change: updates the cache, notes second charges, and syncs
--- the clock on a fresh _START.
---@param name string
---@param value any Its new value.
---@param oldValue any
local function onVarChanged(name, value, oldValue)
    if oldValue == value then return end
    local kind = cooldownVarKind(name)
    if kind == nil then return end
    local newValue = tonumber(value)
    cachedValues[name] = newValue or false
    varVersion = varVersion + 1
    local isSecondCharge = string.find(name, CHARGE2_SUFFIX, 1, true) ~= nil
    if newValue ~= nil and newValue > 0 and isSecondCharge then
        noteSecondCharge(name)
    end
    if kind ~= "start" or newValue == nil or newValue <= 0 then return end
    noteStart(newValue, name)
    local now = abilityCooldowns.ServerTick()
    -- Skip the values sent on entering the game, and any _START older than
    -- the clock already says it is.
    local isFresh = now == nil or newValue >= now - CLOCK_SLACK_TICKS
    if settleTicks == 0 and isFresh then
        tickOffset = newValue - localTick
    end
end

--- Starts counting ticks and following cooldown vars. Call once, at load.
function abilityCooldowns.Start()
    Event.ServerLogic.Subscribe(EVENT_ID, function()
        localTick = localTick + 1
        if settleTicks > 0 then settleTicks = settleTicks - 1 end
    end)
    varChanges.Listen(EVENT_ID, onVarChanged)
end

--- Stops following events.
function abilityCooldowns.Stop()
    Event.ServerLogic.Unsubscribe(EVENT_ID)
    varChanges.Unlisten(EVENT_ID)
end

return abilityCooldowns
