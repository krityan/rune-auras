-- Registry of game values an aura can display. Each source reads a current
-- and max value, so any display type can show it as a fraction. Sources are
-- grouped by data type (resources, cooldowns, ...) for picking in the editor.
-- Usage: local dataSources = require("Auras/Registries/data-sources")

local abilityCatalogue = require("GameData/Catalogues/ability-catalogue")
local abilityCooldowns = require("GameData/Trackers/ability-cooldowns")
local buffVars = require("GameData/Trackers/buff-vars")
local buffCatalogue = require("GameData/Catalogues/buff-catalogue")
local channel = require("GameData/Trackers/channel")
local playerResources = require("GameData/Trackers/player-resources")
local gameApi = require("GameData/game-api")

local dataSources = {}

local TYPES = {
    { id = "resource", label = "Resources" },
    { id = "cooldown", label = "Ability cooldowns" },
    { id = "buff", label = "Buffs" },
    { id = "channel", label = "Channels" },
}

-- `type` is one of TYPES; `colour` is the default fill used when an aura
-- picks this source. A source whose `read` rounds its current value (e.g.
-- cooldowns, to a tenth of a second) sets `smooth = true` and returns the
-- unrounded value third, for a bar's Smooth fill. A fourth value, stacks,
-- is a buff's stack count, for the $stacks placeholder.
-- Other fields:
--   timed      true when the values are times in seconds (cooldowns, timed
--              buffs, channels), which bar ticks and the radial swipe need
--   state      "cooldown" (on/off: running is "on cooldown") or "active"
--              (buffs and channels: running is active), for the Icon
--              display's dimming and hiding; nil for values with no on/off
--   details    optional function returning the name, sprite icon and item
--              icon right now, instead of label/icon/iconObject (see Details)
--   movedFrom  ids this source used to have, so auras saved with them follow
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
-- Every old id -> current id: RENAMED_IDS plus the sources' movedFrom
-- (a buff's twins, a channel's old buff id). Rebuilt with the sources.
local MOVED_IDS = {}

-- SOURCES is the resources, then the cooldowns, the buffs and the channels;
-- the last three are rebuilt from game config (rebuildSources).
local RESOURCES = { table.unpack(SOURCES) }
local cooldownSources = {}
local buffSources = {}
local channelSources = {}
local SOURCES_BY_ID = {}
local usingCatalogue = false

local function rebuildSources()
    for index = #SOURCES, 1, -1 do SOURCES[index] = nil end
    for _, list in ipairs({ RESOURCES, cooldownSources, buffSources, channelSources }) do
        for _, source in ipairs(list) do SOURCES[#SOURCES + 1] = source end
    end
    for key in pairs(SOURCES_BY_ID) do SOURCES_BY_ID[key] = nil end
    for _, source in ipairs(SOURCES) do
        SOURCES_BY_ID[source.id] = source
    end
    MOVED_IDS = {}
    for oldID, sourceID in pairs(RENAMED_IDS) do MOVED_IDS[oldID] = sourceID end
    for _, source in ipairs(SOURCES) do
        for _, oldID in ipairs(source.movedFrom or {}) do
            MOVED_IDS[oldID] = source.id
            -- Auras still saved with it read the source in its place.
            if SOURCES_BY_ID[oldID] == nil then SOURCES_BY_ID[oldID] = source end
        end
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
            timed = true,
            state = "cooldown",
            read = function()
                return abilityCooldowns.GetCooldown(varBase)
            end,
        }
    end
end

-- Buffs: current is the seconds left (or the stacks; 0 while inactive)
-- over the buff's full duration, read from the buff's own vars
-- (GameData/Trackers/buff-vars). Only buffs whose vars are known are listed
-- (see GameData/Catalogues/buff-catalogue).
-- `icon` is a sprite id and `iconObject` an item whose icon is shown
-- instead, for the Icon display.
local BUFF_COLOUR = 0x27AE60FF

-- The ability a buff belongs to, when that ability has a greater version:
-- the buff's own struct is the ability's (COMBATV2_ABILITY_MAGIC_SUNSHINE),
-- or for a greater buff, its base's (baseStruct, see buff-catalogue). The
-- buff then shows the ability's icon, which follows the greater unlock, so
-- Sunshine and Greater Sunshine both show the version the player has.
local function greaterAbility(entry, cooldownsByID)
    local structName = entry.baseStruct or entry.structName
    local name = structName:gsub("^COMBATV2_ABILITY_", "")
    local cooldown = cooldownsByID["cooldown_" .. name:lower()]
    local ability = cooldown and cooldown.ability
    if ability == nil or ability.greater == nil then return nil end
    return ability
end

local function buildBuffSources()
    buffSources = {}
    local cooldownsByID = {}
    for _, source in ipairs(cooldownSources) do cooldownsByID[source.id] = source end
    for _, entry in ipairs(buffCatalogue.List()) do
        if entry.kind == "buff" and buffVars.Handles(entry) then
            local ability = greaterAbility(entry, cooldownsByID)
            local timed = entry.endVar ~= nil or entry.startVar ~= nil
            buffSources[#buffSources + 1] = {
                id = entry.id,
                type = "buff",
                label = entry.label,
                colour = BUFF_COLOUR,
                icon = ability and ability.icon or entry.icon,
                iconObject = entry.icon == nil and entry.object or nil,
                -- Kept so a greater icon swap can be picked up (ApplyGreaterIcons).
                ability = ability,
                -- Timed (so it can move every frame) unless all it has is
                -- stacks or an on/off var.
                smooth = timed,
                timed = timed,
                state = "active",
                -- Its twins' ids (see dropTwins in buff-catalogue).
                movedFrom = entry.twinIDs,
                read = function() return buffVars.Read(entry) end,
            }
        end
    end
end

-- Channels (GameData/Trackers/channel): current is the seconds left of the
-- channel (so far, for a cast like Snipe), max its length, so a bar is a
-- channel or cast bar. "Any channel" shows whatever is being channelled;
-- the others one channelled ability each (any version of it, e.g. Greater
-- Flurry for Flurry), from the ability catalogue.
local CHANNEL_COLOUR = 0x5DADE2FF
-- Ability key -> its ability, so "Any channel" can name and show it.
local channelAbilities = {}

-- "Any channel" is named, and shows the icon of, whatever is (or was last)
-- being channelled.
local function anyChannelDetails()
    local key = channel.Key()
    local ability = key ~= nil and channelAbilities[key] or nil
    if ability == nil then return "Any channel", nil, nil end
    return ability.label, ability.icon, nil
end

-- One ability's channel: the channel while it's this ability's, else 0 of
-- its own last length.
local function abilityChannelReader(key)
    local lastMax = 0
    return function()
        local curr, max, remaining = channel.Read()
        if channel.Key() ~= key then return 0, lastMax end
        lastMax = max
        return curr, max, remaining
    end
end

local function buildChannelSources()
    channelSources = {
        {
            id = "channel_any",
            type = "channel",
            label = "Any channel",
            colour = CHANNEL_COLOUR,
            smooth = true,
            timed = true,
            state = "active",
            read = channel.Read,
            details = anyChannelDetails,
        },
    }
    channelAbilities = {}
    if not usingCatalogue then return end
    for _, ability in ipairs(abilityCatalogue.List()) do
        if ability.channelled and ability.key ~= nil then
            channelAbilities[ability.key] = ability
            local name = ability.id:gsub("^cooldown_", "")
            channelSources[#channelSources + 1] = {
                id = "channel_" .. name,
                type = "channel",
                label = ability.label,
                colour = CHANNEL_COLOUR,
                icon = ability.icon,
                -- Kept so a greater icon swap can be picked up (ApplyGreaterIcons).
                ability = ability,
                smooth = true,
                timed = true,
                state = "active",
                -- Channelled abilities were once listed as buffs.
                movedFrom = { "buff_combatv2_ability_" .. name },
                read = abilityChannelReader(ability.key),
            }
        end
    end
end

buildCooldownSources()
buffCatalogue.LoadCached()
buildBuffSources()
buildChannelSources()
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
    -- Buffs link to the cooldowns' abilities, so they're rebuilt with them.
    -- Both buff calls run: either can change the list.
    local buffsChanged = buffCatalogue.LoadCached()
    buffsChanged = buffCatalogue.ResolveVars() or buffsChanged
    if buffsChanged or changed then
        buildBuffSources()
        changed = true
    end
    if changed then
        -- Channels come from the ability catalogue too.
        buildChannelSources()
        rebuildSources()
    end
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
    return MOVED_IDS[sourceID] or sourceID
end

function dataSources.Get(sourceID)
    return SOURCES_BY_ID[sourceID]
end

-- A source's name, sprite icon and item icon as they are now: its own,
-- except "Any channel", which takes whatever is being channelled.
function dataSources.Details(sourceID)
    local source = SOURCES_BY_ID[sourceID]
    if source == nil then return nil end
    if source.details ~= nil then return source.details() end
    return source.label, source.icon, source.iconObject
end

-- Returns curr, max (plus the unrounded curr for a `smooth` source), or nil
-- when the source is unknown or no player is logged in.
function dataSources.Read(sourceID)
    if not gameApi.PlayerAvailable() then return nil end
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
