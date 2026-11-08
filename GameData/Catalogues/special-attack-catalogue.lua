-- Weapon special attacks with a cooldown (Instability), listed from the
-- cooldown debuffs the buff catalogue finds. Owns the SpecialAttackEntry
-- record and what links a special to its debuff, vars and weapons. Timing
-- them is ability-cooldowns' job.

local gameApi = require("GameData/game-api")

local specialAttackCatalogue = {}

--- A weapon special attack with a cooldown.
---@class SpecialAttackEntry
---@field key string Its name in config, e.g. INSTABILITY.
---@field name string The special's name (Instability).
---@field weapon string? The weapon's name (Fractured Staff of Armadyl), without a tier; nil if it can't be read.
---@field icon integer? Sprite id.
---@field object integer? The weapon, whose icon it shows.
---@field var string Its cooldown vars without _START/_END (server ticks, like an ability's).
---@field endClientVar string? The VarClient holding the client Logic tick its cooldown ends on, if it has one.

local WEAPON_COOLDOWN_VAR_PREFIX = "COMBATV2_ABILITY_WEAPON_COOLDOWN_"
-- The start of newer specials' cooldown vars, and of every special's end
-- VarClient (COMBATV2_COOLDOWN_WEAPON_INSTABILITY_END_CLIENT).
local NEWER_COOLDOWN_VAR_PREFIX = "COMBATV2_COOLDOWN_WEAPON_"
local END_CLIENT_SUFFIX = "_END_CLIENT"
-- A special's cooldown debuff, and the prefix its key takes to make its
-- cooldown vars. Necromancy guards (Death Grasp) and newer weapons are
-- named the second way.
local COOLDOWN_DEBUFF_NAMES = {
    { debuff = "^COMBATV2_ABILITY_WEAPON_(.+)_COOLDOWN$", varPrefix = WEAPON_COOLDOWN_VAR_PREFIX },
    { debuff = "^COMBATV2_DEBUFF_(.+)_WEAPON_COOLDOWN$", varPrefix = NEWER_COOLDOWN_VAR_PREFIX },
}
-- Debuff keys to the special's key, where the cooldown vars are named
-- after the special instead.
local SPECIAL_KEYS = {
    -- Malachi's tooth's Sanguine Volley.
    RANGED_GHRAZI_CROSSBOW_T95 = "SANGUINE_VOLLEY",
}
-- An item param naming the plain version of a weapon with a special.
local SPECIAL_BASE_PARAM = "COMBATV2_SPECIAL_ATTACK_BASE_ITEM"
-- The tier a weapon's name ends with ("Death guard (tier 70)").
local TIER_SUFFIX_PATTERN = "%s*%([Tt]ier %d+%)$"

---@type table<integer, string> A special's weapon (SpecialAttackEntry.object) to its key, from the last List.
local keysByObject = {}
---@type table<string, string> A special's weapon name to its key, from the last List.
local keysByWeapon = {}

--- A special's key and cooldown vars, from its cooldown debuff's struct name.
---@param structName string
---@return string? key nil if it isn't a special's cooldown debuff.
---@return string? var Its cooldown vars without _START/_END.
local function cooldownDebuffKey(structName)
    for _, names in ipairs(COOLDOWN_DEBUFF_NAMES) do
        local key = structName:match(names.debuff)
        -- Vars named after the special take the usual prefix.
        local specialKey = key and SPECIAL_KEYS[key]
        if specialKey ~= nil then return specialKey, WEAPON_COOLDOWN_VAR_PREFIX .. specialKey end
        if key ~= nil then return key, names.varPrefix .. key end
    end
    return nil, nil
end

--- Whether a struct is a special's cooldown debuff.
---@param structName string
---@return boolean
function specialAttackCatalogue.IsCooldownDebuff(structName)
    return cooldownDebuffKey(structName) ~= nil
end

--- The item a weapon's special belongs to: every version of a weapon
--- (augmented, dyed, Third Age) names its plain version, which is the item
--- a special is listed under (SpecialAttackEntry.object). An item that
--- names none (the plain version may not) is its own.
---@param itemID integer
---@return integer
local function baseItem(itemID)
    local item = gameApi.Item(itemID)
    local param = item and gameApi.Param(SPECIAL_BASE_PARAM)
    if param == nil or not gameApi.HasParam(item, param) then return itemID end
    return gameApi.ItemID(gameApi.ParamValue(item, param)) or itemID
end

--- A weapon's name without a tier, as specials are listed by.
---@param itemID integer
---@return string? name nil if it can't be read.
local function weaponName(itemID)
    local weapon = gameApi.ItemName(itemID)
    -- Every tier shares the special, and the debuff names only one.
    return weapon and (weapon:gsub(TIER_SUFFIX_PATTERN, ""))
end

--- The special a worn weapon has: by the item its special belongs to,
--- else by its name without a tier (the debuff names only one tier).
--- Matches against the last List.
---@param itemID integer
---@return string? key nil if the weapon has no special with a cooldown.
function specialAttackCatalogue.Find(itemID)
    local key = keysByObject[baseItem(itemID)]
    if key ~= nil then return key end
    local weapon = weaponName(itemID)
    return weapon and keysByWeapon[weapon]
end

--- A special's end VarClient, if it has one.
---@param var string Its cooldown vars without _START/_END.
---@return string?
local function endClientVar(var)
    local name = var
    -- Older specials' end VarClients take the newer prefix; newer ones have it already.
    if string.sub(var, 1, #WEAPON_COOLDOWN_VAR_PREFIX) == WEAPON_COOLDOWN_VAR_PREFIX then
        name = NEWER_COOLDOWN_VAR_PREFIX .. string.sub(var, #WEAPON_COOLDOWN_VAR_PREFIX + 1)
    end
    name = name .. END_CLIENT_SUFFIX
    if gameApi.VarClient(name) == nil then return nil end
    return name
end

--- A special, if its cooldown vars exist.
---@param key string
---@param name string
---@param var string Its cooldown vars without _START/_END.
---@param object integer? The weapon.
---@param icon integer? A sprite id, when the debuff has one.
---@return SpecialAttackEntry?
local function specialAttack(key, name, var, object, icon)
    if not gameApi.VarExists(var .. "_START") then return nil end
    return {
        key = key,
        name = name,
        weapon = object and weaponName(object),
        icon = icon,
        object = object,
        var = var,
        endClientVar = endClientVar(var),
    }
end

--- The specials with cooldown vars, named by their cooldown debuffs in the
--- buff list, which Find then matches weapons against. Reads whether each
--- var exists, and each weapon's name, so call it when the buff list changes.
---@param buffs BuffEntry[] The buff catalogue's list.
---@return SpecialAttackEntry[]
function specialAttackCatalogue.List(buffs)
    local specials = {}
    keysByObject, keysByWeapon = {}, {}
    for _, entry in ipairs(buffs) do
        local key, var = nil, nil
        if entry.kind == "debuff" then key, var = cooldownDebuffKey(entry.structName) end
        local special = var and specialAttack(key, entry.name, var, entry.object, entry.icon)
        if special ~= nil then
            specials[#specials + 1] = special
            if special.object ~= nil then keysByObject[special.object] = special.key end
            if special.weapon ~= nil then keysByWeapon[special.weapon] = special.key end
        end
    end
    return specials
end

return specialAttackCatalogue
