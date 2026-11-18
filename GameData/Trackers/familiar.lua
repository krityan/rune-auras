-- The player's summoned familiar, read from game vars when asked (through
-- var-cache, so a step with no var changes reads nothing from the game).

local varCache = require("GameData/Trackers/var-cache")

local familiar = {}

local readVarPlayer = varCache.VarPlayer

--- The familiar's lifepoints; 0 with no familiar out.
--- TODO: check in game that this is 0 with no familiar, and that it's in whole lifepoints.
---@return integer?
function familiar.GetLifepoints()
    return readVarPlayer("LORE_FOLLOWER_LIFEPOINTS")
end

--- The familiar's maximum lifepoints; 0 with no familiar out.
--- TODO: check in game that this is the maximum, including boosts.
---@return integer?
function familiar.GetMaxLifepoints()
    return readVarPlayer("LORE_FOLLOWER_BASE_LIFEPOINTS")
end

return familiar
