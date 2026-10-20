-- Registry of game values an aura can display. Each source reads a current
-- and max value, so any display type can show it as a fraction. Sources are
-- grouped by data type (resources, cooldowns, ...) for picking in the editor.
-- Usage: local dataSources = require("Auras/Registries/data-sources")

local abilityCatalogue = require("GameData/Catalogues/ability-catalogue")
local abilityCooldowns = require("GameData/Trackers/ability-cooldowns")
local buffBar = require("GameData/Trackers/buff-bar")
local buffCatalogue = require("GameData/Catalogues/buff-catalogue")
local playerResources = require("GameData/Trackers/player-resources")

local dataSources = {}

local TYPES = {
    { id = "resource", label = "Resources" },
    { id = "cooldown", label = "Ability cooldowns" },
    { id = "buff", label = "Buffs" },
}

-- `type` is one of TYPES; `colour` is the default fill used when an aura
-- picks this source. A source whose `read` rounds its current value (e.g.
-- cooldowns, to a tenth of a second) sets `smooth = true` and returns the
-- unrounded value third, for a bar's Smooth fill. A fourth value, untimed,
-- means the value has no number worth showing (an active buff with no
-- timer), so displays leave their text out. A fifth, initial, marks an
-- estimate for a buff's first tick on the bar (see GameData/Trackers/buff-bar),
-- which displays show only if the aura's showInitialTick is on.
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
-- from game config (GameData/Catalogues/ability-catalogue), falling back to the
-- hand-written abilityCatalogue.FALLBACK if that can't be read yet (e.g.
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
for _, ability in ipairs(abilityCatalogue.FALLBACK) do
    RENAMED_IDS["cooldown_" .. ability.legacyID] = cooldownID(ability.var)
end

-- SOURCES is the resources, then the cooldowns, then the buffs; the last
-- two are rebuilt from game config (rebuildSources).
local RESOURCES = { table.unpack(SOURCES) }
local cooldownSources = {}
local buffSources = {}
local SOURCES_BY_ID = {}
local usingCatalogue = false

local function rebuildSources()
    for index = #SOURCES, 1, -1 do SOURCES[index] = nil end
    for _, list in ipairs({ RESOURCES, cooldownSources, buffSources }) do
        for _, source in ipairs(list) do SOURCES[#SOURCES + 1] = source end
    end
    for key in pairs(SOURCES_BY_ID) do SOURCES_BY_ID[key] = nil end
    for _, source in ipairs(SOURCES) do
        SOURCES_BY_ID[source.id] = source
    end
end

local function buildCooldownSources()
    local abilities = abilityCatalogue.List()
    usingCatalogue = #abilities > 0
    if not usingCatalogue then abilities = abilityCatalogue.FALLBACK end
    cooldownSources = {}
    for _, ability in ipairs(abilities) do
        local varBase = ability.var
        -- Every ability's last use helps show the others are ready before
        -- the cooldown clock is lined up.
        abilityCooldowns.Watch(varBase)
        cooldownSources[#cooldownSources + 1] = {
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
end

-- Buffs: current is the seconds left (0 while inactive), max the longest
-- it's been since it started, read off the game's buff bar (see
-- GameData/Trackers/buff-bar). The list comes from GameData/Catalogues/buff-catalogue.
-- `icon` is a sprite id and `iconObject` an item whose icon is shown
-- instead, for the Icon display.
local BUFF_COLOUR = 0x27AE60FF

local function buildBuffSources()
    buffSources = {}
    for _, entry in ipairs(buffCatalogue.List()) do
        if entry.kind == "buff" then
            buffSources[#buffSources + 1] = {
                id = entry.id,
                type = "buff",
                label = entry.label,
                colour = BUFF_COLOUR,
                icon = entry.icon,
                iconObject = entry.icon == nil and entry.object or nil,
                smooth = not entry.stacks,
                read = function()
                    return buffBar.Read(entry)
                end,
            }
        end
    end
end

buildCooldownSources()
buffCatalogue.LoadCached()
buildBuffSources()
rebuildSources()

-- Tries the ability and buff catalogues again if they couldn't be read
-- before, e.g. on entering the game. Returns true when the sources changed,
-- so displays showing them (names, icons) need refreshing.
function dataSources.Refresh()
    local changed = false
    if not usingCatalogue then
        buildCooldownSources()
        changed = usingCatalogue
    end
    if buffCatalogue.LoadCached() then
        buildBuffSources()
        changed = true
    end
    if changed then rebuildSources() end
    return changed
end

-- Rebuilds the buff sources after the buff catalogue changed (its
-- background scan found different buffs).
function dataSources.RefreshBuffs()
    buildBuffSources()
    rebuildSources()
end

local function syncAbilityIcons()
    for _, source in ipairs(SOURCES) do
        if source.ability ~= nil then source.icon = source.ability.icon end
    end
end

-- Switches unlocked greater abilities to their greater icons (see
-- GameData/Catalogues/ability-catalogue). Returns changed, so displays showing them
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
