-- The Buff and Debuff data types' sources: current is the seconds left (or
-- the stacks; 0 while inactive) over the full duration, read from their own
-- vars (active-buffs). Only those with an icon and known vars are listed
-- (see buff-catalogue). Special attacks' cooldown debuffs are listed as
-- special attacks instead.

local abilityCatalogue = require("GameData/Catalogues/ability-catalogue")
local activeBuffs = require("GameData/Trackers/active-buffs")
local buffCatalogue = require("GameData/Catalogues/buff-catalogue")
local gameApi = require("GameData/game-api")

local buffs = {}

local BUFF_COLOUR = 0x27AE60FF
-- Also the target debuff sources' colour.
buffs.DEBUFF_COLOUR = 0xE74C3CFF
local COOLDOWN_ID_PREFIX = abilityCatalogue.SOURCE_ID_PREFIX

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

-- The end of an ammo item's name that $ammo leaves off ("Ful arrows" is "Ful").
local AMMO_NAME_ENDINGS = { "%s+[Aa]rrows?$", "%s+[Bb]olts?$" }
---@type table<integer, string> Item id to its $ammo name, as names don't change.
local ammoNames = {}

--- An ammo item's name without "arrows" or "bolts", for $ammo.
---@param itemID integer?
---@return string?
local function ammoName(itemID)
    if itemID == nil then return nil end
    local cached = ammoNames[itemID]
    if cached ~= nil then return cached end
    local name = gameApi.ItemName(itemID)
    if name == nil then return nil end
    for _, ending in ipairs(AMMO_NAME_ENDINGS) do name = name:gsub(ending, "") end
    ammoNames[itemID] = name
    return name
end

--- Builds a buff or debuff source per listed catalogue entry (see
--- buffCatalogue.IsListed).
---@param cooldownSources DataSource[] The ability cooldowns, for buffs that show their ability's greater icon.
---@return DataSource[] buffSources
---@return DataSource[] debuffSources
function buffs.Build(cooldownSources)
    local buffSources, debuffSources = {}, {}
    local cooldownsByID = {}
    for _, source in ipairs(cooldownSources) do cooldownsByID[source.id] = source end
    for _, entry in ipairs(buffCatalogue.List()) do
        if buffCatalogue.IsListed(entry) then
            local isBuff = entry.kind == "buff"
            local list = isBuff and buffSources or debuffSources
            local ability = greaterAbility(entry, cooldownsByID)
            -- Timed (so it can move every frame) unless all it has is stacks
            -- or an on/off var.
            local timed = entry.endVar ~= nil or entry.startVar ~= nil
            list[#list + 1] = {
                -- A debuff's id is "buff_<struct name>" too, as the catalogue names it.
                id = entry.id,
                type = entry.kind,
                -- The picker's label has the struct's name added when two
                -- clash, which only shows once every buff is loaded; what an
                -- aura shows ($name) is the buff's own name, which doesn't.
                label = entry.label,
                name = entry.name,
                colour = isBuff and BUFF_COLOUR or buffs.DEBUFF_COLOUR,
                icon = ability and ability.icon or entry.icon,
                iconObject = entry.icon == nil and entry.object or nil,
                ability = ability,
                smooth = timed,
                timed = timed,
                onOff = not timed and entry.stacksVar == nil,
                hasStacks = entry.stacksVar ~= nil,
                hasAmmo = entry.objectVar ~= nil,
                state = "active",
                -- Its duplicates' ids (see dropDuplicates in Buffs/buff-list).
                movedFrom = entry.duplicateIDs,
                read = function() return activeBuffs.Read(entry) end,
                -- The quiver's icon is its ammo (see BuffEntry.objectVar), and
                -- $ammo its name.
                details = entry.objectVar ~= nil and function()
                    local item = activeBuffs.Object(entry)
                    return entry.name, nil, item or entry.object, ammoName(item)
                end or nil,
            }
        end
    end
    return buffSources, debuffSources
end

return buffs
