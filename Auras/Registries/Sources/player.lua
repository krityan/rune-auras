-- The Player data type's sources: the player's lifepoints, adrenaline,
-- prayer and summoning points. A fixed list, not built from game config.

local playerResources = require("GameData/Trackers/player-resources")

local player = {}

---@type DataSource[]
local SOURCES = {
    {
        id = "lifepoints",
        type = "player",
        label = "Lifepoints",
        colour = 0xC0392BFF,
        read = function()
            return playerResources.GetLifepoints(), playerResources.GetMaxLifepoints()
        end,
    },
    {
        id = "adrenaline",
        type = "player",
        label = "Adrenaline",
        colour = 0xE8B923FF,
        read = function()
            return playerResources.GetAdrenaline(), playerResources.GetMaxAdrenaline()
        end,
    },
    {
        id = "prayer",
        type = "player",
        label = "Prayer points",
        colour = 0x3FA9D6FF,
        read = function()
            return playerResources.GetPrayerPoints(), playerResources.GetMaxPrayerPoints()
        end,
    },
    {
        id = "summoning",
        type = "player",
        label = "Summoning points",
        colour = 0x2FB79AFF,
        read = function()
            return playerResources.GetSummoningPoints(), playerResources.GetMaxSummoningPoints()
        end,
    },
}

--- The player sources.
---@return DataSource[]
function player.Build()
    return SOURCES
end

return player
