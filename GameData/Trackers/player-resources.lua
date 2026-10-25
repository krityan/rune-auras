-- The player's resources (lifepoints, adrenaline, prayer, summoning), read
-- from game vars when asked.

local gameApi = require("GameData/game-api")

local playerResources = {}

local readVarPlayer = gameApi.VarPlayer

-- Prayer, summoning and adrenaline vars hold tenths of a point.
local TENTHS = 10
-- Prayer and summoning points per level of the skill.
local POINTS_PER_LEVEL = 10
local MAX_ADRENALINE = 100

--- A var holding tenths, as whole points, dropping the fraction to match the
--- game's orbs.
---@param name string
---@return integer? points nil if it can't be read.
local function readWholePoints(name)
    local value = readVarPlayer(name)
    if value == nil then return nil end
    return value // TENTHS
end

--- A skill's maximum points: there's no max var, so it's derived from the
--- skill's level.
---@param skill integer A SkillType value.
---@return integer? points nil if the level can't be read.
local function maxPointsFor(skill)
    local level = gameApi.SkillLevel(skill)
    return level and level * POINTS_PER_LEVEL
end

---@return integer?
function playerResources.GetPrayerPoints()
    return readWholePoints("PRAYER_POINTS")
end

---@return integer?
function playerResources.GetMaxPrayerPoints()
    return maxPointsFor(SkillType.PRAYER)
end

---@return integer?
function playerResources.GetLifepoints()
    return readVarPlayer("LIFEPOINTS")
end

---@return integer?
function playerResources.GetMaxLifepoints()
    return readVarPlayer("MAXLIFEPOINTS")
end

--- Adrenaline, as a percentage. No var is named for it, but RS3 reuses the
--- old special attack energy var (SA_ENERGY, varp 679), in tenths of a
--- percent. Inferred from the var dumps; needs checking in game.
---@return integer?
function playerResources.GetAdrenaline()
    return readWholePoints("SA_ENERGY")
end

---@return integer
function playerResources.GetMaxAdrenaline()
    return MAX_ADRENALINE
end

--- Summoning points. "Lore" is the game's internal name for Summoning;
--- LORE_POINTS is laid out exactly like PRAYER_POINTS (confirmed in game).
---@return integer?
function playerResources.GetSummoningPoints()
    return readWholePoints("LORE_POINTS")
end

---@return integer?
function playerResources.GetMaxSummoningPoints()
    return maxPointsFor(SkillType.SUMMONING)
end

return playerResources
