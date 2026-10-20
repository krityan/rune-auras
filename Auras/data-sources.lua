-- Registry of game values an aura can display. Each source reads a current
-- and max value, so any display type can show it as a fraction. Sources are
-- grouped by data type (resources, cooldowns, ...) for picking in the editor.
-- Usage: local dataSources = require("Auras/data-sources")

local abilityCatalogue = require("GameData/ability-catalogue")
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
-- full cooldown, so a bar drains as the ability comes back. The list comes
-- from game config (GameData/ability-catalogue), falling back to the
-- hand-written abilityCooldowns.ABILITIES if that can't be read yet (e.g.
-- loading at the login screen), until Refresh succeeds. `icon` is the
-- ability's sprite id, for the Icon display.
local COOLDOWN_COLOUR = 0x9B59B6FF
local COOLDOWN_VAR_PREFIX = "COMBATV2_COOLDOWN_"

-- Ids are named after the cooldown var so they stay stable across lists.
local function cooldownID(varBase)
    return "cooldown_" .. string.lower(varBase:sub(#COOLDOWN_VAR_PREFIX + 1))
end

-- Old source id -> current id, for auras saved before ids followed the var.
local RENAMED_IDS = {}
for _, ability in ipairs(abilityCooldowns.ABILITIES) do
    RENAMED_IDS["cooldown_" .. ability.id] = cooldownID(ability.var)
end

-- Everything after the resources is a cooldown source, rebuilt by Refresh.
local RESOURCE_COUNT = #SOURCES
local SOURCES_BY_ID = {}
local usingCatalogue = false

local function buildCooldownSources()
    local abilities = abilityCatalogue.List()
    usingCatalogue = #abilities > 0
    if not usingCatalogue then abilities = abilityCooldowns.ABILITIES end
    for index = #SOURCES, RESOURCE_COUNT + 1, -1 do SOURCES[index] = nil end
    for _, ability in ipairs(abilities) do
        local varBase = ability.var
        -- Every ability's last use helps show the others are ready before
        -- the cooldown clock is lined up.
        abilityCooldowns.Watch(varBase)
        SOURCES[#SOURCES + 1] = {
            -- Abilities sharing a cooldown share a var, so the catalogue names
            -- each one; the hand-written fallback is named by its var.
            id = ability.id or cooldownID(varBase),
            type = "cooldown",
            label = ability.label,
            colour = COOLDOWN_COLOUR,
            icon = ability.icon,
            -- Kept so a greater icon swap can be picked up (ApplyGreaterIcons).
            ability = ability,
            smooth = true,
            read = function()
                return abilityCooldowns.GetCooldown(varBase)
            end,
        }
    end
    for key in pairs(SOURCES_BY_ID) do SOURCES_BY_ID[key] = nil end
    for _, source in ipairs(SOURCES) do
        SOURCES_BY_ID[source.id] = source
    end
end
buildCooldownSources()

-- Tries the ability catalogue again if it couldn't be read before, e.g. on
-- entering the game. Returns true when the sources changed, so displays
-- showing them (names, icons) need refreshing.
function dataSources.Refresh()
    if usingCatalogue then return false end
    buildCooldownSources()
    return usingCatalogue
end

local function syncAbilityIcons()
    for _, source in ipairs(SOURCES) do
        if source.ability ~= nil then source.icon = source.ability.icon end
    end
end

-- Switches unlocked greater abilities to their greater icons (see
-- GameData/ability-catalogue). Returns changed, so displays showing them
-- need refreshing, and complete, false while some flags haven't arrived.
function dataSources.ApplyGreaterIcons()
    if not usingCatalogue then return false, false end
    local changed, complete = abilityCatalogue.ApplyGreaterUnlocks()
    if changed then syncAbilityIcons() end
    return changed, complete
end

-- Follows a var update that may be a greater unlock flag. Returns whether
-- any icon changed.
function dataSources.OnVarChanged(name, value)
    if not usingCatalogue or not abilityCatalogue.OnVarChanged(name, value) then return false end
    syncAbilityIcons()
    return true
end

-- Lets the next login check greater unlocks again.
function dataSources.ResetGreaterIcons()
    abilityCatalogue.Reset()
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

-- The current id for a saved source id, which may predate a rename.
function dataSources.CurrentID(sourceID)
    return RENAMED_IDS[sourceID] or sourceID
end

function dataSources.Get(sourceID)
    return SOURCES_BY_ID[sourceID]
end

-- Returns curr, max (plus the unrounded curr for a `smooth` source), or nil
-- when the source is unknown or no player is logged in.
function dataSources.Read(sourceID)
    if not Player.IsAvailable() then return nil end
    return dataSources.ReadAvailable(sourceID)
end

-- Read, for a caller that has already checked Player.IsAvailable() (the
-- aura manager checks once per frame rather than once per source).
function dataSources.ReadAvailable(sourceID)
    local source = SOURCES_BY_ID[sourceID]
    if source == nil then return nil end
    return source.read()
end

return dataSources
