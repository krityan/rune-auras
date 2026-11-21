-- The Buff and Debuff data types' sources: the seconds left (or stacks) over
-- the full duration, from active-buffs. Only those with an icon and known vars
-- are listed; special attacks' cooldown debuffs are listed as special attacks.

local abilityCatalogue = require("GameData/Catalogues/ability-catalogue")
local activeBuffs = require("GameData/Trackers/active-buffs")
local buffCatalogue = require("GameData/Catalogues/buff-catalogue")
local gameApi = require("GameData/game-api")

local buffs = {}

local BUFF_COLOUR = 0x27AE60FF
-- A toggled buff's value can be the count the buff bar shows under its icon
-- (see measureToggle in GameData/Trackers/active-buffs), which text writes
-- as the bar does.
---@type TextInfo
local COMPACT_VALUES = { compactValues = true }
-- Also the target debuff sources' colour.
buffs.DEBUFF_COLOUR = 0xE74C3CFF
local COOLDOWN_ID_PREFIX = abilityCatalogue.SOURCE_ID_PREFIX

--- The ability a buff belongs to, when that ability has a greater version.
--- It's found by the first of these: the ability struct the buff names
--- (BuffEntry.iconAbility: Flow names Sonic Wave), its base buff's struct
--- for a greater buff, or the buff's own struct where that's the ability's
--- (COMBATV2_ABILITY_MAGIC_SUNSHINE). The buff then shows the ability's icon,
--- which follows the greater unlock, so Sunshine and Greater Sunshine both
--- show the version the player has.
---@param entry BuffEntry
---@param cooldownsByID table<string, DataSource>
---@return AbilityEntry? ability nil if it has no greater version.
local function greaterAbility(entry, cooldownsByID)
    local structName = entry.iconAbility or entry.baseStruct or entry.structName
    local abilityName = structName:gsub("^COMBATV2_ABILITY_", "")
    local cooldown = cooldownsByID[COOLDOWN_ID_PREFIX .. abilityName:lower()]
    local ability = cooldown and cooldown.ability
    if ability == nil or ability.greater == nil then
        return nil
    end

    return ability
end

-- The end of an ammo item's name that $ammo leaves off ("Ful arrows" is "Ful").
local AMMO_NAME_ENDINGS = { "%s+[Aa]rrows?$", "%s+[Bb]olts?$" }
---@type table<integer, string> Item id to its $ammo name, as names don't change.
local ammoNames = {}

--- An ammo item's name without "arrows" or "bolts", for $ammo.
---@param itemID integer?
---@return string?
local function ammoName(itemID)
    if itemID == nil then
        return nil
    end

    local cached = ammoNames[itemID]
    if cached ~= nil then
        return cached
    end

    local name = gameApi.ItemName(itemID)
    if name == nil then
        return nil
    end

    for _, ending in ipairs(AMMO_NAME_ENDINGS) do
        name = name:gsub(ending, "")
    end

    ammoNames[itemID] = name
    return name
end

--- The details of a buff whose icon is an item that changes while it runs:
--- the quiver's ammo (see BuffEntry.objectVar), also named for $ammo, or
--- the item worn in a slot for it (see activeBuffs.WornIcon).
---@param entry BuffEntry
---@return (fun(): string?, integer?, integer?, string?)?
local function itemDetails(entry)
    if entry.objectVar ~= nil then
        return function()
            local item = activeBuffs.Object(entry)
            return entry.name, nil, item or entry.object, ammoName(item)
        end
    end

    if entry.wornIcon == nil then
        return nil
    end

    return function()
        return entry.name, nil, activeBuffs.WornIcon(entry) or entry.object, nil
    end
end

--- Builds a buff or debuff source per listed catalogue entry (see
--- buffCatalogue.IsListed).
---@param cooldownSources DataSource[] The ability cooldowns, for buffs that show their ability's greater icon.
---@return DataSource[] buffSources
---@return DataSource[] debuffSources
function buffs.Build(cooldownSources)
    local buffSources, debuffSources = {}, {}
    local cooldownsByID = {}
    for _, source in ipairs(cooldownSources) do
        cooldownsByID[source.id] = source
    end

    for _, entry in ipairs(buffCatalogue.List()) do
        if buffCatalogue.IsListed(entry) then
            local isBuff = entry.kind == "buff"
            local list = isBuff and buffSources or debuffSources
            local ability = greaterAbility(entry, cooldownsByID)
            -- Timed (so it can move every frame) unless all it has is stacks
            -- or an on/off var.
            local timed = entry.endVar ~= nil or entry.startVar ~= nil or entry.barCastVar ~= nil
            local onOff = not timed and entry.stacksVar == nil
            list[#list + 1] = {
                -- A debuff's id is "buff_<struct name>" too, as the catalogue names it.
                id = entry.id,
                type = entry.kind,
                -- The picker's label has the struct's name added when two
                -- clash, which only shows once every buff is loaded; what an
                -- aura shows ($name) is the buff's name, which doesn't.
                label = entry.label,
                name = entry.name,
                colour = isBuff and BUFF_COLOUR or buffs.DEBUFF_COLOUR,
                icon = ability and ability.icon or entry.icon,
                iconObject = entry.icon == nil and entry.object or nil,
                ability = ability,
                smooth = timed,
                timed = timed,
                onOff = onOff,
                textInfo = onOff and COMPACT_VALUES or nil,
                hasStacks = entry.stacksVar ~= nil,
                hasAmmo = entry.objectVar ~= nil,
                state = "active",
                -- Its duplicates' ids (see dropDuplicates in Buffs/buff-list).
                movedFrom = entry.duplicateIDs,
                read = function() return activeBuffs.Read(entry) end,
                details = itemDetails(entry),
            }
        end
    end

    return buffSources, debuffSources
end

return buffs
