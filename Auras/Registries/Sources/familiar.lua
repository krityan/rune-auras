-- The Familiar data type's sources: the summoned familiar's lifepoints. A
-- fixed list, not built from game config.

local familiarTracker = require("GameData/Trackers/familiar")

local familiar = {}

---@type DataSource[]
local SOURCES = {
    {
        id = "familiarLifepoints",
        type = "familiar",
        label = "Familiar lifepoints",
        colour = 0x8E44ADFF,
        read = function()
            return familiarTracker.GetLifepoints(), familiarTracker.GetMaxLifepoints()
        end,
    },
}

--- The familiar sources.
---@return DataSource[]
function familiar.Build()
    return SOURCES
end

return familiar
