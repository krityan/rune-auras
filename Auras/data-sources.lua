-- Registry of game values an aura can display. Each source reads a current
-- and max value, so any display type can show it as a fraction. Sources are
-- grouped by data type (resources, cooldowns, ...) for picking in the editor.
-- Usage: local dataSources = require("Auras/data-sources")

local abilityCooldowns = require("GameData/ability-cooldowns")
local playerResources = require("GameData/player-resources")

local dataSources = {}

local TYPES = {
    { id = "resource", label = "Resources" },
    { id = "cooldown", label = "Ability cooldowns" },
}

-- `type` is one of TYPES; `colour` is the default fill used when an aura
-- picks this source. A source whose `read` rounds its current value (e.g.
-- cooldowns, to a tenth of a second) sets `smooth = true` and returns the
-- unrounded value third, for a bar's Smooth fill.
local SOURCES = {
    {
        id = "lifepoints",
        type = "resource",
        label = "Lifepoints",
        colour = 0xC0392BFF,
        read = function()
            return playerResources.GetLifepoints(), playerResources.GetMaxLifepoints()
        end,
    },
    {
        id = "adrenaline",
        type = "resource",
        label = "Adrenaline",
        colour = 0xE8B923FF,
        read = function()
            return playerResources.GetAdrenaline(), playerResources.GetMaxAdrenaline()
        end,
    },
    {
        id = "prayer",
        type = "resource",
        label = "Prayer points",
        colour = 0x3FA9D6FF,
        read = function()
            return playerResources.GetPrayerPoints(), playerResources.GetMaxPrayerPoints()
        end,
    },
    {
        id = "summoning",
        type = "resource",
        label = "Summoning points",
        colour = 0x2FB79AFF,
        read = function()
            return playerResources.GetSummoningPoints(), playerResources.GetMaxSummoningPoints()
        end,
    },
}

-- Ability cooldowns: current is the seconds left (0 when ready), max is the
-- full cooldown, so a bar drains as the ability comes back.
local COOLDOWN_COLOUR = 0x9B59B6FF
for _, ability in ipairs(abilityCooldowns.ABILITIES) do
    SOURCES[#SOURCES + 1] = {
        id = "cooldown_" .. ability.id,
        type = "cooldown",
        label = ability.label,
        colour = COOLDOWN_COLOUR,
        smooth = true,
        read = function()
            return abilityCooldowns.GetCooldown(ability.var)
        end,
    }
end

local SOURCES_BY_ID = {}
for _, source in ipairs(SOURCES) do
    SOURCES_BY_ID[source.id] = source
end

function dataSources.Types()
    return TYPES
end

-- The sources of one data type, in registry order.
function dataSources.ListByType(typeID)
    local list = {}
    for _, source in ipairs(SOURCES) do
        if source.type == typeID then list[#list + 1] = source end
    end
    return list
end

function dataSources.List()
    return SOURCES
end

function dataSources.Get(sourceID)
    return SOURCES_BY_ID[sourceID]
end

-- Returns curr, max (plus the unrounded curr for a `smooth` source), or nil
-- when the source is unknown or no player is logged in.
function dataSources.Read(sourceID)
    local source = SOURCES_BY_ID[sourceID]
    if source == nil or not Player.IsAvailable() then
        return nil
    end
    return source.read()
end

return dataSources
