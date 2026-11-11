-- The player's resources (lifepoints, adrenaline, prayer, summoning), read
-- from game vars when asked (through var-cache, so a step with no var
-- changes reads nothing from the game).

local gameApi = require("GameData/game-api")
local gameClock = require("GameData/Trackers/game-clock")
local varCache = require("GameData/Trackers/var-cache")

local playerResources = {}

local readVarPlayer = varCache.VarPlayer

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

---@type table<integer, integer?> Skill to its level as of levelsTick.
local levels = {}
local levelsTick = nil

--- A skill's level, read at most once a server tick: max prayer and
--- summoning are read every step, and levels rarely change.
---@param skill integer A SkillType value.
---@return integer? level
local function skillLevel(skill)
    local tick = gameClock.ServerTicks()
    if tick ~= levelsTick then
        levelsTick = tick
        for known in pairs(levels) do levels[known] = nil end
    end
    local level = levels[skill]
    if level == nil then
        level = gameApi.SkillLevel(skill)
        levels[skill] = level
    end
    return level
end

--- A skill's maximum points: there's no max var, so it's derived from the
--- skill's level.
---@param skill integer A SkillType value.
---@return integer? points nil if the level can't be read.
local function maxPointsFor(skill)
    local level = skillLevel(skill)
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
--- LORE_POINTS is laid out exactly like PRAYER_POINTS.
---@return integer?
function playerResources.GetSummoningPoints()
    return readWholePoints("LORE_POINTS")
end

---@return integer?
function playerResources.GetMaxSummoningPoints()
    return maxPointsFor(SkillType.SUMMONING)
end

return playerResources
