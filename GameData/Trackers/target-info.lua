-- The player's target as the target info panel shows it: its lifepoints,
-- read when asked (at most once a Logic tick), and its combat level, the
-- player's hit chance against it and its weakness, read once a server tick. The panel unloads with no target, so these are only
-- known while the player has one.

local gameApi = require("GameData/game-api")
local gameClock = require("GameData/Trackers/game-clock")
local playerTarget = require("GameData/Trackers/player-target")

local targetInfo = {}

local EVENT_ID = "runeAuras_targetInfo"

-- The panel's lifepoints text ("94,903"), its combat level text ("18"), and
-- its weakness sprite. Each reads "N/A" (or the no-weakness sprite) while
-- the panel waits for a target's details.
local LIFEPOINTS_COMPONENT = "TOPLEVEL_V2_TARGET_INFO__ENTITY_HEALTH_LEFT"
local LEVEL_COMPONENT = "TOPLEVEL_V2_TARGET_INFO__LEVEL"
local WEAKNESS_COMPONENT = "TOPLEVEL_V2_TARGET_INFO__WEAKNESS"
-- The player's chance to hit the target, in tenths of a percent; NO_HIT_CHANCE
-- for targets without one (training dummies).
local HIT_CHANCE_VAR = "TOPLEVEL_V2_TARGET_HITCHANCE"
local NO_HIT_CHANCE = -1
-- The target's health in percent, rounded down; 0 with no target or while
-- the panel is closed. Re-sent every 3 server ticks, so it can lag the
-- lifepoints text.
local HEALTH_PERCENT_VAR = "COMBATV2_TARGET_SIDE_PANEL_HEALTH"
local FULL_PERCENT = 100
local TENTHS_PER_PERCENT = 10

-- The panel's weakness is an attack type's icon. This enum gives each
-- attack type's icon; nothing in the game names them, so ATTACK_TYPE_NAMES
-- does.
local ATTACK_TYPE_ICONS_ENUM = "COMBATV2_ATTACK_TYPE_ICONS"
local ATTACK_TYPE_NAMES = {
    [0] = "None", [1] = "Air", [2] = "Water", [3] = "Earth", [4] = "Fire",
    [5] = "Stab", [6] = "Slash", [7] = "Crush", [8] = "Arrows", [9] = "Bolts", [10] = "Thrown",
    [11] = "Magic", [37] = "Necromancy",
}
-- An enum entry is { key, value }.
local ENUM_KEY, ENUM_VALUE = 1, 2

---@type table<integer, string>? A weakness sprite to its name; nil until the enum has been read.
local weaknessNames = nil

--- Each attack type's icon to its name, read from the enum the first time
--- it can be (config can't be read at the login screen).
---@return table<integer, string>?
local function readWeaknessNames()
    if weaknessNames ~= nil then return weaknessNames end
    local entries = gameApi.EnumValues(ATTACK_TYPE_ICONS_ENUM)
    if type(entries) ~= "table" then return nil end
    local names = {}
    for _, entry in ipairs(entries) do
        local name = type(entry) == "table" and ATTACK_TYPE_NAMES[entry[ENUM_KEY]]
        local sprite = name and math.tointeger(entry[ENUM_VALUE])
        if sprite ~= nil then names[sprite] = name end
    end
    weaknessNames = names
    return names
end

--- What the text fields about the target show. A new table whenever any
--- of it changes, so displays can tell a change by comparing tables.
---@class TargetInfo
---@field name string? The target's name.
---@field level integer? Its combat level.
---@field hitChance number? The player's chance to hit it, in percent.
---@field weakness string? Its weakness.

---@type TargetInfo
local EMPTY = {}

---@type TargetInfo The latest target's details: kept once it's gone, as its name is.
local info = EMPTY
---@type integer? The target the lifepoints are for.
local lifepointsTarget = nil
---@type integer? The current target's lifepoints; nil while unknown.
local lifepoints = nil
---@type integer The current target's max as far as is known (the game doesn't give it): the most lifepoints seen, or more if its health percent says so.
local maxLifepoints = 0
---@type string? The lifepoints text last read, so it's only parsed when it changes.
local lastLifepointsText = nil
---@type integer? The health percent last read, so a max is only worked out from it when it changes.
local lastPercent = nil
---@type integer? gameClock.LogicTick() when the lifepoints were last read.
local lifepointsReadTick = nil

--- A panel component, if the panel is loaded.
---@param name string
---@return Component?
local function panelComponent(name)
    local combinedID = gameApi.Cached(gameApi.ComponentID, name)
    return combinedID and gameApi.ComponentByID(combinedID)
end

--- A panel text as a whole number ("94,903" is 94903); nil for "N/A".
---@param text string?
---@return integer?
local function parseNumber(text)
    if text == nil then return nil end
    return math.tointeger(tonumber((text:gsub(",", ""))))
end

--- The target's health percent; nil if it can't be read.
---@return integer?
local function readHealthPercent()
    local varConfig = gameApi.VarClient(HEALTH_PERCENT_VAR)
    return varConfig and math.tointeger(tonumber(gameApi.VarValue(varConfig)))
end

--- Raises the max to the least a target can have, from its lifepoints and
--- its health percent, for a target first seen hurt (targeted mid-fight, or
--- after a reload). The percent is rounded down, so the max is above
--- lifepoints / (percent + 1). Only a percent that has just changed is
--- used, as the lifepoints text can have moved on from an older one.
local function raiseMaxFromPercent()
    -- Kept for when the panel shows the lifepoints.
    if lifepoints == nil then return end
    local percent = readHealthPercent()
    if percent == lastPercent then return end
    lastPercent = percent
    if percent == nil or percent <= 0 or percent >= FULL_PERCENT then return end
    local leastMax = lifepoints * FULL_PERCENT // (percent + 1) + 1
    if leastMax > maxLifepoints then maxLifepoints = leastMax end
end

--- Reads the current target's lifepoints, keeping the most seen (or
--- more, from its health percent) as its max.
---@param current integer?
local function readLifepoints(current)
    if current ~= lifepointsTarget then
        -- Swapping straight from one target to another, the health percent
        -- is still the old target's until it's next sent, so only a change
        -- from it counts.
        local isSwap = lifepointsTarget ~= nil and current ~= nil
        lifepointsTarget, lifepoints, maxLifepoints, lastLifepointsText = current, nil, 0, nil
        lastPercent = isSwap and readHealthPercent() or nil
    end
    local component = panelComponent(LIFEPOINTS_COMPONENT)
    local text = component and gameApi.TextContent(component)
    if text ~= lastLifepointsText then
        lastLifepointsText = text
        lifepoints = parseNumber(text)
        if lifepoints ~= nil and lifepoints > maxLifepoints then maxLifepoints = lifepoints end
    end
    if current ~= nil then raiseMaxFromPercent() end
end

--- The hit chance in percent; nil without one.
---@return number?
local function readHitChance()
    local varConfig = gameApi.VarClient(HIT_CHANCE_VAR)
    local value = varConfig and tonumber(gameApi.VarValue(varConfig))
    if value == nil or value == NO_HIT_CHANCE then return nil end
    return value / TENTHS_PER_PERCENT
end

--- Reads the panel's details, keeping the last known ones while it's
--- unloaded or still waiting for them, and starting afresh for a new
--- target.
---@param isNewTarget boolean
local function readDetails(isNewTarget)
    local name = playerTarget.Name()
    local level, hitChance, weakness
    if not isNewTarget then level, hitChance, weakness = info.level, info.hitChance, info.weakness end
    local levelComponent = panelComponent(LEVEL_COMPONENT)
    if levelComponent ~= nil then
        level = parseNumber(gameApi.TextContent(levelComponent)) or level
        hitChance = readHitChance()
        local weaknessComponent = panelComponent(WEAKNESS_COMPONENT)
        local sprite = weaknessComponent and gameApi.SpriteID(weaknessComponent)
        local names = sprite and readWeaknessNames()
        weakness = names and names[sprite] or weakness
    end
    if name == info.name and level == info.level and hitChance == info.hitChance and weakness == info.weakness then
        return
    end
    info = { name = name, level = level, hitChance = hitChance, weakness = weakness }
end

---@type integer? The latest target the details were read for.
local detailsTarget = nil

local function onServerTick()
    local latest = playerTarget.Latest()
    readDetails(latest ~= detailsTarget)
    detailsTarget = latest
end

--- The current target's lifepoints and its max as far as is known (the
--- most seen, or the least its health percent allows); 0 of 0 with no
--- target, or until the panel shows them.
---@return integer curr
---@return integer max
function targetInfo.Lifepoints()
    -- The panel updates after the server tick's event, so reading it then
    -- would show the tick before; it's read on demand instead.
    local tick = gameClock.LogicTick()
    if tick ~= lifepointsReadTick then
        lifepointsReadTick = tick
        local current = playerTarget.Current()
        if current == playerTarget.NONE then current = nil end
        readLifepoints(current)
    end
    return lifepoints or 0, maxLifepoints
end

--- The latest target's details, for the text fields about it.
---@return TargetInfo
function targetInfo.Details()
    return info
end

--- Forgets the target, e.g. on leaving the game.
function targetInfo.Reset()
    info, detailsTarget = EMPTY, nil
    lifepointsTarget, lifepoints, maxLifepoints, lastLifepointsText, lastPercent = nil, nil, 0, nil, nil
    lifepointsReadTick = nil
end

--- Starts reading the panel each server tick. Call once, at load.
function targetInfo.Start()
    Event.ServerLogic.Subscribe(EVENT_ID, onServerTick)
end

--- Stops reading the panel.
function targetInfo.Stop()
    Event.ServerLogic.Unsubscribe(EVENT_ID)
end

return targetInfo
