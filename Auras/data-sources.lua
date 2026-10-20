-- Registry of game values an aura can display. Each source reads a current
-- and max value, so any display type can show it as a fraction.
-- Usage: local dataSources = require("Auras/data-sources")

local playerResources = require("GameData/player-resources")

local dataSources = {}

-- `colour` is the default fill used when an aura picks this source.
local SOURCES = {
    {
        id = "lifepoints",
        label = "Lifepoints",
        colour = 0xC0392BFF,
        read = function()
            return playerResources.GetLifepoints(), playerResources.GetMaxLifepoints()
        end,
    },
    {
        id = "adrenaline",
        label = "Adrenaline",
        colour = 0xE8B923FF,
        read = function()
            return playerResources.GetAdrenaline(), playerResources.GetMaxAdrenaline()
        end,
    },
    {
        id = "prayer",
        label = "Prayer points",
        colour = 0x3FA9D6FF,
        read = function()
            return playerResources.GetPrayerPoints(), playerResources.GetMaxPrayerPoints()
        end,
    },
    {
        id = "summoning",
        label = "Summoning points",
        colour = 0x2FB79AFF,
        read = function()
            return playerResources.GetSummoningPoints(), playerResources.GetMaxSummoningPoints()
        end,
    },
}

local SOURCES_BY_ID = {}
for _, source in ipairs(SOURCES) do
    SOURCES_BY_ID[source.id] = source
end

function dataSources.List()
    return SOURCES
end

function dataSources.Get(sourceID)
    return SOURCES_BY_ID[sourceID]
end

-- Returns curr, max, or nil when the source is unknown or no player is
-- logged in.
function dataSources.Read(sourceID)
    local source = SOURCES_BY_ID[sourceID]
    if source == nil or not Player.IsAvailable() then
        return nil
    end
    return source.read()
end

return dataSources
