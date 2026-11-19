-- When the player's combat ends, from their ability uses (Surge and Bladed
-- Dive included), as no var holds the combat timer. Attacks taken and
-- auto-attacks aren't followed, so combat may outlast it (see stalled-ability).

local abilityCooldowns = require("GameData/Trackers/ability-cooldowns")

local combatTimer = {}

-- Server ticks from an ability's use until combat ends: on the global
-- cooldown, or off it (Surge, Bladed Dive), which ends a tick later.
local TICKS_AFTER_GCD_USE = 16
local TICKS_AFTER_OFF_GCD_USE = 17
--- The longest combat lasts after a use, in server ticks.
combatTimer.LONGEST_TICKS = TICKS_AFTER_OFF_GCD_USE
local GCD_START_VAR = "COMBATV2_GLOBAL_COOLDOWN_START"

---@type integer? The server tick of the latest use.
local lastUseTick = nil
-- Whether the latest use was on the global cooldown (its tick is the global cooldown's start).
local isLatestOnGcd = false

--- Notes a use: a cooldown's _START, or the global cooldown's _START, with the
--- use's server tick. An ability's _START and the global cooldown's _START can
--- come in either order on the same tick.
---@param name string
---@param tick integer
local function noteUse(name, tick)
    local isGcd = name == GCD_START_VAR
    if lastUseTick == nil or tick > lastUseTick then
        lastUseTick, isLatestOnGcd = tick, isGcd
    elseif tick == lastUseTick and isGcd then
        isLatestOnGcd = true
    end
end

--- The server tick combat ends on, after the latest use.
---@return integer? endTick nil before any use.
---@return integer? length Server ticks from the latest use to the end.
function combatTimer.EndTick()
    if lastUseTick == nil then
        return nil
    end

    local length = isLatestOnGcd and TICKS_AFTER_GCD_USE or TICKS_AFTER_OFF_GCD_USE
    return lastUseTick + length, length
end

--- Forgets the latest use, e.g. on leaving the game.
function combatTimer.Reset()
    lastUseTick, isLatestOnGcd = nil, false
end

--- Starts following ability uses.
function combatTimer.Start()
    abilityCooldowns.SetOnUse(noteUse)
end

--- Stops following them.
function combatTimer.Stop()
    abilityCooldowns.SetOnUse(nil)
end

return combatTimer
