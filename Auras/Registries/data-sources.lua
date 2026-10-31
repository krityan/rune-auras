-- Data sources: the game values an aura can show, grouped by data type
-- (resources, cooldowns, ...) for picking in the editor. Owns the
-- DataSource record and building the lists; the values themselves are read
-- by GameData/Trackers, and the sets of abilities and buffs come from
-- GameData/Catalogues.

local abilityCatalogue = require("GameData/Catalogues/ability-catalogue")
local abilityCooldowns = require("GameData/Trackers/ability-cooldowns")
local activeBuffs = require("GameData/Trackers/active-buffs")
local buffCatalogue = require("GameData/Catalogues/buff-catalogue")
local channel = require("GameData/Trackers/channel")
local playerResources = require("GameData/Trackers/player-resources")
local gameApi = require("GameData/game-api")

local dataSources = {}

--- A game value an aura can show. Every source reads a current and max
--- value, so any display type can show it as a fraction.
---@class DataSource
---@field id string Stable: named after game config, so saved auras keep working.
---@field type string A data type id (see Types).
---@field label string Shown in the picker; may say more than `name` to tell sources apart.
---@field name string? What auras show as $name, when it differs from `label`.
---@field colour integer Default fill (0xRRGGBBAA) when an aura picks this source.
---@field icon integer? Sprite id, for the Icon display.
---@field iconObject integer? An item whose icon is shown instead.
---@field read fun(): number?, number?, number?, number? Returns curr, max, the unrounded curr (smooth sources), and stacks or charges.
---@field smooth boolean? `read` rounds its current value, and gives the unrounded one third, for a bar's Smooth fill.
---@field timed boolean? Values are times in seconds (cooldowns, timed buffs, channels), which bar ticks and the radial swipe need.
---@field state "cooldown"|"active"|nil Whether running means on cooldown or active (buffs, channels), for the Icon display's dimming and hiding; nil for values with no on/off.
---@field details fun(): string?, integer?, integer? | nil Name, sprite icon and item icon right now, instead of the fields (see Details).
---@field movedFrom string[]? Ids it used to have, so auras saved with them follow it.
---@field ability AbilityEntry? Its ability, so a greater icon swap can be picked up (ApplyGreaterIcons).

---@class DataType
---@field id string
---@field label string

---@type DataType[]
local TYPES = {
    { id = "resource", label = "Resources" },
    { id = "cooldown", label = "Ability cooldowns" },
    { id = "buff", label = "Buffs" },
    { id = "channel", label = "Channels" },
}

---@type DataSource[]
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
-- from game config (ability-catalogue), falling back to the hand-written
-- abilityCatalogue.FALLBACK if that can't be read yet (e.g. loading at the
-- login screen), until Refresh succeeds.
local COOLDOWN_COLOUR = 0x9B59B6FF
local COOLDOWN_VAR_PREFIX = abilityCatalogue.COOLDOWN_VAR_PREFIX
local COOLDOWN_ID_PREFIX = abilityCatalogue.SOURCE_ID_PREFIX

--- A cooldown source's id, named after its var so it stays stable.
---@param varBase string The cooldown var without _START/_END.
---@return string
local function cooldownID(varBase)
    return COOLDOWN_ID_PREFIX .. string.lower(varBase:sub(#COOLDOWN_VAR_PREFIX + 1))
end

---@type table<string, string> Old source id to current id, for auras saved before ids followed the var.
local RENAMED_IDS = {}
for _, ability in ipairs(abilityCatalogue.FALLBACK) do
    RENAMED_IDS[COOLDOWN_ID_PREFIX .. ability.legacyID] = cooldownID(ability.var)
end
---@type table<string, string> Every old id to its current one: RENAMED_IDS plus the sources' movedFrom (a buff's duplicates, a channel's old buff id). Rebuilt with the sources.
local MOVED_IDS = {}

-- SOURCES is the resources, then the cooldowns, the buffs and the channels;
-- the last three are rebuilt from game config (rebuildSources).
local RESOURCES = { table.unpack(SOURCES) }
local cooldownSources = {}
local buffSources = {}
local channelSources = {}
---@type table<string, DataSource>
local SOURCES_BY_ID = {}
-- Whether the cooldowns came from the ability catalogue rather than FALLBACK.
local usingCatalogue = false

--- Rebuilds SOURCES, the id lookup and MOVED_IDS from the four lists.
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

--- Builds a cooldown source per ability, from the catalogue or FALLBACK.
local function buildCooldownSources()
    local abilities = abilityCatalogue.List()
    usingCatalogue = #abilities > 0
    if not usingCatalogue then abilities = abilityCatalogue.FALLBACK end
    cooldownSources = {}
    for _, ability in ipairs(abilities) do
        local varBase = ability.var
        -- Every ability's last use helps show the others are ready before
        -- the cooldown clock is synced.
        abilityCooldowns.Watch(varBase)
        cooldownSources[#cooldownSources + 1] = {
            -- Abilities sharing a cooldown share a var, so the catalogue names
            -- each one; the hand-written fallback is named by its var.
            id = ability.id or cooldownID(varBase),
            type = "cooldown",
            label = ability.label,
            colour = COOLDOWN_COLOUR,
            icon = ability.icon,
            ability = ability,
            smooth = true,
            timed = true,
            state = "cooldown",
            -- Times the next charge for an ability with two (see
            -- GetNextCharge); the fourth value is the charges ready.
            read = function()
                local remaining, total, unrounded = abilityCooldowns.GetNextCharge(varBase)
                return remaining, total, unrounded, (abilityCooldowns.GetCharges(varBase))
            end,
        }
    end
end

-- Buffs: current is the seconds left (or the stacks; 0 while inactive) over
-- the buff's full duration, read from the buff's own vars (active-buffs). Only
-- buffs with an icon and known vars are listed (see buff-catalogue).
local BUFF_COLOUR = 0x27AE60FF

--- The ability a buff belongs to, when that ability has a greater version:
--- the buff's own struct is the ability's struct (COMBATV2_ABILITY_MAGIC_SUNSHINE),
--- or for a greater buff, its base buff's struct. The buff then shows the ability's
--- icon, which follows the greater unlock, so Sunshine and Greater Sunshine
--- both show the version the player has.
---@param entry BuffEntry
---@param cooldownsByID table<string, DataSource>
---@return AbilityEntry? ability nil if it has no greater version.
local function greaterAbility(entry, cooldownsByID)
    local structName = entry.baseStruct or entry.structName
    local abilityName = structName:gsub("^COMBATV2_ABILITY_", "")
    local cooldown = cooldownsByID[COOLDOWN_ID_PREFIX .. abilityName:lower()]
    local ability = cooldown and cooldown.ability
    if ability == nil or ability.greater == nil then return nil end
    return ability
end

--- Builds a buff source per catalogued buff with an icon and known vars.
local function buildBuffSources()
    buffSources = {}
    local cooldownsByID = {}
    for _, source in ipairs(cooldownSources) do cooldownsByID[source.id] = source end
    for _, entry in ipairs(buffCatalogue.List()) do
        if entry.kind == "buff" and buffCatalogue.HasIcon(entry) and activeBuffs.Handles(entry) then
            local ability = greaterAbility(entry, cooldownsByID)
            -- Timed (so it can move every frame) unless all it has is stacks
            -- or an on/off var.
            local timed = entry.endVar ~= nil or entry.startVar ~= nil
            buffSources[#buffSources + 1] = {
                id = entry.id,
                type = "buff",
                -- The picker's label has the struct's name added when two
                -- clash, which only shows once every buff is loaded; what an
                -- aura shows ($name) is the buff's own name, which doesn't.
                label = entry.label,
                name = entry.name,
                colour = BUFF_COLOUR,
                icon = ability and ability.icon or entry.icon,
                iconObject = entry.icon == nil and entry.object or nil,
                ability = ability,
                smooth = timed,
                timed = timed,
                state = "active",
                -- Its duplicates' ids (see dropDuplicates in buff-catalogue).
                movedFrom = entry.duplicateIDs,
                read = function() return activeBuffs.Read(entry) end,
                -- The quiver's icon is its ammo (see BuffEntry.objectVar).
                details = entry.objectVar ~= nil and function()
                    return entry.name, nil, activeBuffs.Object(entry) or entry.object
                end or nil,
            }
        end
    end
end

-- Channels (channel tracker): current is the seconds left of the channel
-- (so far, for a cast like Snipe), max its length, so a bar is a channel or
-- cast bar. "Any channel" shows whatever is being channelled; the others
-- one channelled ability each (any version of it, e.g. Greater Flurry for
-- Flurry), from the ability catalogue.
local CHANNEL_COLOUR = 0x5DADE2FF
local ANY_CHANNEL_NAME = "Any channel"
---@type table<string, AbilityEntry> Ability key to its ability, so "Any channel" can name and show it.
local channelAbilities = {}

--- "Any channel"'s details: the name and icon of whatever is (or was last)
--- being channelled.
---@return string name
---@return integer? spriteID
---@return nil objectID
local function anyChannelDetails()
    local key = channel.Key()
    local ability = key ~= nil and channelAbilities[key] or nil
    if ability == nil then return ANY_CHANNEL_NAME, nil, nil end
    return ability.label, ability.icon, nil
end

--- A read for one ability's channel: the channel while this ability is channelled,
--- else 0 of its own last length.
---@param key string The ability's key (see abilityCatalogue.Key).
---@return fun(): number, number, number?
local function abilityChannelReader(key)
    local lastMax = 0
    return function()
        local curr, max, remaining = channel.Read()
        if channel.Key() ~= key then return 0, lastMax end
        lastMax = max
        return curr, max, remaining
    end
end

--- Builds "Any channel", plus a source per channelled ability once the
--- catalogue can be read.
local function buildChannelSources()
    channelSources = {
        {
            id = "channel_any",
            type = "channel",
            label = ANY_CHANNEL_NAME,
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
            local abilityName = ability.id:gsub("^" .. COOLDOWN_ID_PREFIX, "")
            channelSources[#channelSources + 1] = {
                id = "channel_" .. abilityName,
                type = "channel",
                label = ability.label,
                colour = CHANNEL_COLOUR,
                icon = ability.icon,
                ability = ability,
                smooth = true,
                timed = true,
                state = "active",
                -- Channelled abilities were once listed as buffs.
                movedFrom = { buffCatalogue.SourceID(abilityCatalogue.STRUCT_PREFIX .. abilityName) },
                read = abilityChannelReader(ability.key),
            }
        end
    end
end

-- Buffs come in later: the catalogue loads in the background once in game
-- (see Auras/source-sync), then RefreshBuffs lists them.
buildCooldownSources()
buildBuffSources()
buildChannelSources()
rebuildSources()

--- Tries the ability catalogue again if it couldn't be read before, e.g. on
--- entering the game, rebuilding everything built from it.
---@return boolean changed Whether the sources changed, so displays showing them (names, icons) need refreshing.
function dataSources.Refresh()
    if usingCatalogue then return false end
    buildCooldownSources()
    if not usingCatalogue then return false end
    -- Buffs link to the cooldowns' abilities, and channels come from the
    -- ability catalogue too.
    buildBuffSources()
    buildChannelSources()
    rebuildSources()
    return true
end

--- Rebuilds the buff sources after the buff catalogue changed (its
--- background scan found different buffs).
function dataSources.RefreshBuffs()
    buildBuffSources()
    rebuildSources()
end

--- Copies each source's ability icon onto it, after greater unlocks changed.
local function syncAbilityIcons()
    for _, source in ipairs(SOURCES) do
        if source.ability ~= nil then source.icon = source.ability.icon end
    end
end

--- Switches unlocked greater abilities to their greater icons (see
--- ability-catalogue).
---@return boolean changed Whether any icon changed, so displays showing them need refreshing.
---@return boolean complete false while some unlock flags haven't arrived.
function dataSources.ApplyGreaterIcons()
    if not usingCatalogue then return false, false end
    local changed, complete = abilityCatalogue.ApplyGreaterUnlocks()
    if changed then syncAbilityIcons() end
    return changed, complete
end

--- Follows a var update that may be a greater unlock flag.
---@param name string The var's name.
---@param value any
---@return boolean changed Whether any icon changed.
function dataSources.OnVarChanged(name, value)
    if not usingCatalogue or not abilityCatalogue.OnVarChanged(name, value) then return false end
    syncAbilityIcons()
    return true
end

--- Lets the next login check greater unlocks again.
function dataSources.ResetGreaterIcons()
    abilityCatalogue.Reset()
end

--- Every data type, in the picker's order.
---@return DataType[]
function dataSources.Types()
    return TYPES
end

--- The sources of one data type, in registry order.
---@param typeID string
---@return DataSource[]
function dataSources.ListByType(typeID)
    local list = {}
    for _, source in ipairs(SOURCES) do
        if source.type == typeID then list[#list + 1] = source end
    end
    return list
end

--- Every source.
---@return DataSource[]
function dataSources.List()
    return SOURCES
end

--- The current id for a saved source id, which may predate a rename.
---@param sourceID string
---@return string
function dataSources.CurrentID(sourceID)
    return MOVED_IDS[sourceID] or sourceID
end

--- A source by id (or an old id it moved from).
---@param sourceID string?
---@return DataSource? source nil if unknown.
function dataSources.Get(sourceID)
    return SOURCES_BY_ID[sourceID]
end

--- A source's name, sprite icon and item icon as they are now: its own,
--- except "Any channel", which takes whatever is being channelled.
---@param sourceID string?
---@return string? name nil if the source is unknown.
---@return integer? spriteID
---@return integer? objectID
function dataSources.Details(sourceID)
    local source = SOURCES_BY_ID[sourceID]
    if source == nil then return nil end
    if source.details ~= nil then return source.details() end
    return source.name or source.label, source.icon, source.iconObject
end

--- A source's values now (see DataSource.read).
---@param sourceID string?
---@return number? curr nil when the source is unknown or no player is logged in.
---@return number? max
---@return number? unroundedCurr
---@return number? stacks
function dataSources.Read(sourceID)
    if not gameApi.PlayerAvailable() then return nil end
    return dataSources.ReadAvailable(sourceID)
end

--- Read, for a caller that has already checked the player is available (the
--- aura manager checks once a frame rather than once per source).
---@param sourceID string?
---@return number? curr nil when the source is unknown.
---@return number? max
---@return number? unroundedCurr
---@return number? stacks
function dataSources.ReadAvailable(sourceID)
    local source = SOURCES_BY_ID[sourceID]
    if source == nil then return nil end
    return source.read()
end

return dataSources
