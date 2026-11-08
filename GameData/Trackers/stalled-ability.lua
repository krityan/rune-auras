-- The ability the player has stalled: used with nothing to hit, so it fires
-- on their next attack. The game clears it when it fires, or when combat
-- ends, and it's shown for a server tick after that. Its time left is the
-- time until combat ends (see combat-timer), plus that tick.

local abilityCatalogue = require("GameData/Catalogues/ability-catalogue")
local abilityCooldowns = require("GameData/Trackers/ability-cooldowns")
local combatTimer = require("GameData/Trackers/combat-timer")
local gameApi = require("GameData/game-api")
local gameClock = require("GameData/Trackers/game-clock")
local varChanges = require("GameData/Trackers/var-changes")

local stalledAbility = {}

local LISTENER_ID = "runeAuras_stalledAbility"
-- The stalled ability's struct (its id through VarTransmit, the struct
-- itself read directly), -1 with none.
local STALLED_VAR = "COMBATV2_NEXT_ABILITY"
local NONE = -1
-- Logic ticks it still shows as stalled once the game clears it: a server
-- tick, as the game clears it on the tick the ability fires, which looks a
-- tick early beside the hit.
local HOLD_LOGIC_TICKS = gameClock.LOGIC_TICKS_PER_SERVER_TICK
-- The same in server ticks, added to the time until combat ends.
local HOLD_SERVER_TICKS = 1
-- The least time left shown while stalled, in seconds, so it still shows as
-- running once the combat timer's end has passed: being attacked keeps combat
-- going, and the client isn't told about an attack that does no damage.
local MIN_SHOWN_SECONDS = 0.1

---@type integer? The stalled ability's struct id: nil until known, NONE with nothing stalled.
local stalledID = nil
---@type string? The stalled ability's key (see abilityCatalogue.Key), kept once it's no longer stalled.
local stalledKey = nil
---@type integer? The Logic tick the game last cleared a stall on.
local clearedTick = nil
-- The last time shown in full, in seconds, kept as the max once it's over.
local lastTotal = 0

--- Follows a new value of the stalled var. Read directly, a STRUCT var
--- gives a struct even with none (UNKNOWN(-1)), so it's kept as its id.
---@param value any
local function setStalled(value)
    local wasStalled = stalledID ~= nil and stalledID ~= NONE
    local id = type(value) == "number" and value or (value ~= nil and gameApi.ID(value)) or nil
    stalledID = math.tointeger(id) or NONE
    if stalledID < 0 then
        stalledID = NONE
        if wasStalled then clearedTick = gameClock.LogicTick() end
        return
    end
    stalledKey = abilityCatalogue.StructKey(stalledID) or stalledKey
end

--- Whether the game has an ability stalled. The var is read directly until
--- a change brings it, as one that hasn't changed since a reload never comes
--- through.
---@return boolean
local function isStalled()
    if stalledID == nil and gameApi.PlayerAvailable() then setStalled(gameApi.CachedVarPlayer(STALLED_VAR)) end
    return stalledID ~= nil and stalledID ~= NONE
end

--- Whether a cleared stall is still within the server tick it's shown for.
---@return boolean
local function isHeld()
    local now = gameClock.LogicTick()
    return clearedTick ~= nil and now ~= nil and now - clearedTick < HOLD_LOGIC_TICKS
end

--- The time a stall has left: until combat ends, plus the tick it's still
--- shown for once cleared.
---@return number left Seconds, at least MIN_SHOWN_SECONDS.
---@return number total Seconds from the latest ability use.
local function stalledSeconds()
    local endTick, length = combatTimer.EndTick()
    local now = abilityCooldowns.ServerTick()
    if endTick == nil or now == nil then
        -- No use seen since a reload: its time can't be known, so it shows in full.
        local longest = gameClock.TicksToSeconds(combatTimer.LONGEST_TICKS + HOLD_SERVER_TICKS)
        return longest, longest
    end
    local total = gameClock.TicksToSeconds(length + HOLD_SERVER_TICKS)
    local ticksLeft = endTick + HOLD_SERVER_TICKS - now - gameClock.TickFraction()
    local left = math.min(total, gameClock.TicksToSeconds(ticksLeft))
    return math.max(MIN_SHOWN_SECONDS, left), total
end

--- The stalled ability's time left: until combat ends, which clears it, and
--- a server tick more. Once the game clears it, it keeps counting down for
--- that tick, then reads 0.
---@return number left Seconds, to a tenth; 0 with none stalled.
---@return number total Seconds.
---@return number unrounded
function stalledAbility.Read()
    local left = 0
    if isStalled() then
        left, lastTotal = stalledSeconds()
    elseif isHeld() then
        left = stalledSeconds()
    end
    return gameClock.ToTenths(left), lastTotal, left
end

--- The ability stalled, or last stalled.
---@return string? key As abilityCatalogue.Key; nil before any.
function stalledAbility.Key()
    isStalled()
    return stalledKey
end

--- Follows the stalled var through VarTransmit.
---@param name string
---@param value any
local function onVarChanged(name, value)
    if name == STALLED_VAR then setStalled(value) end
end

--- Forgets the stalled ability, e.g. on leaving the game.
function stalledAbility.Reset()
    stalledID, stalledKey, clearedTick, lastTotal = nil, nil, nil, 0
end

--- Starts following the var.
function stalledAbility.Start()
    varChanges.Listen(LISTENER_ID, onVarChanged)
end

--- Stops following the var.
function stalledAbility.Stop()
    varChanges.Unlisten(LISTENER_ID)
end

return stalledAbility
