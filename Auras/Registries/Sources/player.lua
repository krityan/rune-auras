-- The Player data type's sources: the player's lifepoints, adrenaline,
-- prayer and summoning points, and the spell they have set to autocast. A
-- fixed list, not built from game config. The familiar's lifepoints are
-- the Familiar type's (Sources/familiar).

local autocast = require("GameData/Trackers/autocast")
local playerResources = require("GameData/Trackers/player-resources")

local player = {}

local AUTOCAST_NAME = "Autocast Spell"
-- Buff bar icons that stand for a resource: Prayer Points Reduced's and
-- Familiar Summoned's.
local PRAYER_ICON = 18857
local SUMMONING_ICON = 26095

--- The autocast spell's details: the name and icon of the spell set (or
--- last set).
---@return string name
---@return integer? spriteID
---@return nil objectID
local function autocastDetails()
    local spell = autocast.Spell()
    if spell == nil then return AUTOCAST_NAME, nil, nil end
    return spell.name or AUTOCAST_NAME, spell.icon, nil
end

---@type DataSource[]
local SOURCES = {
    {
        id = "lifepoints",
        type = "player",
        label = "Lifepoints",
        colour = 0xC0392BFF,
        iconImage = "Lifepoints",
        read = function()
            return playerResources.GetLifepoints(), playerResources.GetMaxLifepoints()
        end,
    },
    {
        id = "adrenaline",
        type = "player",
        label = "Adrenaline",
        colour = 0xE8B923FF,
        iconImage = "Adrenaline",
        read = function()
            return playerResources.GetAdrenaline(), playerResources.GetMaxAdrenaline()
        end,
    },
    {
        id = "prayer",
        type = "player",
        label = "Prayer points",
        colour = 0x3FA9D6FF,
        icon = PRAYER_ICON,
        read = function()
            return playerResources.GetPrayerPoints(), playerResources.GetMaxPrayerPoints()
        end,
    },
    {
        id = "summoning",
        type = "player",
        label = "Summoning points",
        colour = 0x2FB79AFF,
        icon = SUMMONING_ICON,
        read = function()
            return playerResources.GetSummoningPoints(), playerResources.GetMaxSummoningPoints()
        end,
    },
    {
        id = "autocast_spell",
        type = "player",
        label = AUTOCAST_NAME,
        colour = 0x8E44ADFF,
        onOff = true,
        state = "active",
        read = autocast.Read,
        details = autocastDetails,
    },
}

--- The player sources.
---@return DataSource[]
function player.Build()
    return SOURCES
end

return player
