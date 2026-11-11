-- The player's target as the target info panel shows it: its lifepoints
-- and max, read when asked, and its combat level, the player's hit chance
-- against it and its weakness, read once a server tick. The panel unloads
-- with no target, so these are only known while the player has one.

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
-- The panel's health bar: the fill, whose width is the target's health
-- percent (rounded down) of the bar's full width, rounded to a unit, and set
-- with the lifepoints text; and the layer behind it, which stays the full
-- width. (The health percent VarClient, COMBATV2_TARGET_SIDE_PANEL_HEALTH,
-- lags the text by several server ticks, so it isn't used.)
local BAR_FILL_COMPONENT = "TOPLEVEL_V2_TARGET_INFO__PROBAR_ACTUAL_HEALTH_LAYER"
local BAR_FULL_COMPONENT = "TOPLEVEL_V2_TARGET_INFO__PROBAR_FAKE_LAYER"
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
---@type integer The current target's max as far as is known (the game doesn't give it), from the panel's health bar; 0 until it's read.
local maxLifepoints = 0
---@type string? The lifepoints text last read, so it's only parsed when it changes.
local lastLifepointsText = nil
---@type integer? gameClock.LogicTick() when the lifepoints were last read.
local lifepointsReadTick = nil
-- The panel's lifepoints text changes this many Logic ticks after a server
-- tick's event.
local PANEL_UPDATE_DELAY = 1
-- Reads each server tick from then on: one for the update, and one more in
-- case it comes a Logic tick late.
local READS_PER_SERVER_TICK = 2
---@type integer? gameClock.ServerTicks() that readsThisServerTick counts for.
local readsServerTick = nil
local readsThisServerTick = 0

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

--- The target's health percent as the panel's health bar shows it (rounded
--- down); nil if the bar can't be read.
---@return integer?
local function readBarPercent()
    local fill, full = panelComponent(BAR_FILL_COMPONENT), panelComponent(BAR_FULL_COMPONENT)
    local fillWidth = fill and gameApi.Width(fill)
    local fullWidth = full and gameApi.Width(full)
    if fillWidth == nil or fullWidth == nil or fullWidth <= 0 then return nil end
    -- The fill is round(percent * fullWidth / 100), which this undoes while
    -- the bar is at least 100 units wide: it's 122 at every interface scale,
    -- as widths are in interface units.
    local percent = math.floor(fillWidth * FULL_PERCENT / fullWidth + 0.5)
    return math.min(percent, FULL_PERCENT)
end

--- Narrows the max to what the panel's health bar allows for the
--- lifepoints. At 100 percent the max is the lifepoints. Below, the percent
--- is rounded down, so the max is above lifepoints / (percent + 1) and at
--- most lifepoints / percent: kept within that, it closes in on the real
--- max as the target's health moves, and is exact once it's seen at full.
--- The bar is set with the lifepoints text, so the two describe the same
--- moment.
local function fitMaxToBar()
    if lifepoints == nil then return end
    local percent = readBarPercent()
    -- 0 percent gives no upper bound, and is also what a bar not yet drawn reads.
    if percent == nil or percent <= 0 then return end
    if percent >= FULL_PERCENT then
        maxLifepoints = lifepoints
        return
    end
    local leastMax = lifepoints * FULL_PERCENT // (percent + 1) + 1
    local mostMax = lifepoints * FULL_PERCENT // percent
    maxLifepoints = math.min(math.max(maxLifepoints, leastMax), mostMax)
end

--- Reads the current target's lifepoints, and its max from the panel's
--- health bar.
---@param current integer?
local function readLifepoints(current)
    if current ~= lifepointsTarget then
        lifepointsTarget, lifepoints, maxLifepoints, lastLifepointsText = current, nil, 0, nil
    end
    local component = panelComponent(LIFEPOINTS_COMPONENT)
    local text = component and gameApi.TextContent(component)
    if text ~= lastLifepointsText then
        lastLifepointsText = text
        lifepoints = parseNumber(text)
    end
    if current ~= nil then fitMaxToBar() end
end

--- The hit chance in percent; nil without one.
---@return number?
local function readHitChance()
    local varConfig = gameApi.Cached(gameApi.VarClient, HIT_CHANCE_VAR)
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

--- Whether the lifepoints are worth reading this Logic tick. The panel
--- updates PANEL_UPDATE_DELAY Logic ticks after the server tick's event, so
--- reading it then would show the tick before, and reading on every Logic
--- tick would mostly find nothing new: it's read on the first
--- READS_PER_SERVER_TICK reads from then on. A new target, or one whose
--- lifepoints the panel doesn't show yet ("N/A"), is read every time.
---@param tick integer?
---@param current integer? The current target's uid.
---@return boolean
local function isReadDue(tick, current)
    if current ~= lifepointsTarget or (current ~= nil and lifepoints == nil) then return true end
    local serverTickAt = gameClock.ServerTickLogicTick()
    if tick == nil or serverTickAt == nil then return true end
    if tick - serverTickAt < PANEL_UPDATE_DELAY then return false end
    local serverTick = gameClock.ServerTicks()
    if serverTick ~= readsServerTick then readsServerTick, readsThisServerTick = serverTick, 0 end
    if readsThisServerTick >= READS_PER_SERVER_TICK then return false end
    readsThisServerTick = readsThisServerTick + 1
    return true
end

--- The current target's lifepoints and its max as far as is known: exact
--- once it's been seen at full health, and before that close enough that
--- the fill is within a percent of the panel's bar. 0 of 0 with no target,
--- or until the panel shows them.
---@return integer curr
---@return integer max
function targetInfo.Lifepoints()
    local tick = gameClock.LogicTick()
    if tick ~= lifepointsReadTick then
        local current = playerTarget.Current()
        if current == playerTarget.NONE then current = nil end
        if isReadDue(tick, current) then
            lifepointsReadTick = tick
            readLifepoints(current)
        end
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
    lifepointsTarget, lifepoints, maxLifepoints, lastLifepointsText = nil, nil, 0, nil
    lifepointsReadTick = nil
    readsServerTick, readsThisServerTick = nil, 0
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
