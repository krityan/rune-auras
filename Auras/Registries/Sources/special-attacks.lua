-- The Special attack cooldown data type's sources: "Equipped weapon", which
-- follows the worn weapon's special, then a source per special attack with
-- a cooldown, found with the buffs (see specialAttackCatalogue.List).

local abilityCooldowns = require("GameData/Trackers/ability-cooldowns")
local buffCatalogue = require("GameData/Catalogues/buff-catalogue")
local specialAttackCatalogue = require("GameData/Catalogues/special-attack-catalogue")
local wornEquipment = require("GameData/Trackers/worn-equipment")
local cooldowns = require("Auras/Registries/Sources/cooldowns")

local specialAttacks = {}

local SPECIAL_ATTACK_ID_PREFIX = "special_attack_"
local EQUIPPED_SPECIAL_NAME = "Equipped weapon"
specialAttacks.EQUIPPED_ID = SPECIAL_ATTACK_ID_PREFIX .. "equipped"
---@type table<string, DataSource> A special's key (see SpecialAttackEntry.key) to its source.
local specialsByKey = {}
---@type table<string, DataSource> Each special's source by id.
local specialsByID = {}
-- The main hand item equippedSpecial was found for (false: not found yet).
local equippedWeapon = false
---@type DataSource?
local equippedSpecial = nil
---@type string? The last special source found worn this session, for auras that remember it (see EquippedSpecialID).
local lastSpecialID = nil

--- The special source for a worn weapon (see specialAttackCatalogue.Find).
---@param itemID integer?
---@return DataSource?
local function specialFor(itemID)
    if itemID == nil then return nil end
    local key = specialAttackCatalogue.Find(itemID)
    return key and specialsByKey[key]
end

--- The special of the main hand weapon, where every special with a cooldown
--- is. Found again only when the weapon changes.
---@return DataSource?
local function findEquippedSpecial()
    local mainHand = wornEquipment.Item(wornEquipment.SLOTS.MAIN_HAND)
    if mainHand ~= equippedWeapon then
        equippedWeapon = mainHand
        equippedSpecial = specialFor(mainHand)
        if equippedSpecial ~= nil then lastSpecialID = equippedSpecial.id end
    end
    return equippedSpecial
end

--- The special source "Equipped weapon" stands for now: the worn weapon's,
--- else, when remembering, the last one worn this session.
---@param remember boolean
---@return string? sourceID nil if there's none.
function specialAttacks.EquippedSpecialID(remember)
    local special = findEquippedSpecial()
    if special ~= nil then return special.id end
    if remember and lastSpecialID ~= nil and specialsByID[lastSpecialID] ~= nil then return lastSpecialID end
    return nil
end

--- "Equipped weapon"'s values: its special's cooldown, else 0 of 0.
---@return number? remaining
---@return number? total
---@return number? unrounded
---@return integer? charges
local function readEquippedSpecial()
    local special = findEquippedSpecial()
    if special == nil then return 0, 0 end
    return special.read()
end

--- "Equipped weapon"'s details: its special's name and icon.
---@return string name
---@return integer? spriteID
---@return integer? objectID
local function equippedSpecialDetails()
    local special = findEquippedSpecial()
    if special == nil then return EQUIPPED_SPECIAL_NAME, nil, nil end
    return special.name or special.label, special.icon, special.iconObject
end

--- Builds "Equipped weapon", then a source per special attack with a
--- cooldown, found with the buffs (see specialAttackCatalogue.List).
---@return DataSource[]
function specialAttacks.Build()
    local sources = {
        {
            id = specialAttacks.EQUIPPED_ID,
            type = "specialAttack",
            label = EQUIPPED_SPECIAL_NAME,
            colour = cooldowns.COLOUR,
            smooth = true,
            timed = true,
            state = "cooldown",
            read = readEquippedSpecial,
            details = equippedSpecialDetails,
        },
    }
    specialsByKey, specialsByID = {}, {}
    equippedWeapon = false
    for _, special in ipairs(specialAttackCatalogue.List(buffCatalogue.List())) do
        local varBase = special.var
        abilityCooldowns.Watch(varBase, special.endClientVar)
        local source = {
            id = SPECIAL_ATTACK_ID_PREFIX .. string.lower(special.key),
            type = "specialAttack",
            -- Named after the weapon, which is what players search for;
            -- $name is the special's.
            label = special.weapon or special.name,
            name = special.name,
            colour = cooldowns.COLOUR,
            icon = special.icon,
            iconObject = special.icon == nil and special.object or nil,
            smooth = true,
            timed = true,
            state = "cooldown",
            read = function() return cooldowns.Read(varBase) end,
        }
        sources[#sources + 1] = source
        specialsByKey[special.key] = source
        specialsByID[source.id] = source
    end
    return sources
end

return specialAttacks
