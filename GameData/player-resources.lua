-- Reads player resource values (prayer, lifepoints) from game vars.
-- Var names come from Data/resource.txt.
-- Usage: local playerResources = require("GameData/player-resources")

local vars = require("GameData/vars")

local playerResources = {}

local readVarPlayer = vars.ReadVarPlayer

-- The var stores prayer in tenths of a point (8014 = 801.4), so drop the
-- fraction to match the prayer orb.
function playerResources.GetPrayerPoints()
    local value = readVarPlayer("PRAYER_POINTS")
    if value == nil then
        return nil
    end
    return value // 10
end

-- There is no max prayer var in the dumps, so this is derived from the
-- Prayer level (10 points per level).
function playerResources.GetMaxPrayerPoints()
    return Player.GetLevelGameplay(SkillType.PRAYER) * 10
end

function playerResources.GetLifepoints()
    return readVarPlayer("LIFEPOINTS")
end

function playerResources.GetMaxLifepoints()
    return readVarPlayer("MAXLIFEPOINTS")
end

-- No var is named for adrenaline, but RS3 reuses the old special attack
-- energy var (SA_ENERGY, varp 679), stored in tenths of a percent (0-1000).
-- This is inferred from the var dumps and needs checking in game.
function playerResources.GetAdrenaline()
    local value = readVarPlayer("SA_ENERGY")
    if value == nil then
        return nil
    end
    return value // 10
end

function playerResources.GetMaxAdrenaline()
    return 100
end

-- "Lore" is the game's internal name for Summoning. LORE_POINTS is laid out
-- exactly like PRAYER_POINTS and holds summoning points in tenths
-- (confirmed in game).
function playerResources.GetSummoningPoints()
    local value = readVarPlayer("LORE_POINTS")
    if value == nil then
        return nil
    end
    return value // 10
end

-- Derived from the Summoning level (10 points per level), like prayer.
function playerResources.GetMaxSummoningPoints()
    return Player.GetLevelGameplay(SkillType.SUMMONING) * 10
end

return playerResources
