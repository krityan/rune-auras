-- Weapon special attacks with a cooldown (Instability), listed from the
-- cooldown debuffs the buff catalogue finds.
-- Owns the SpecialAttackEntry record and the names that link a special to
-- its debuff and cooldown vars. Timing them is ability-cooldowns' job.

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

local WEAPON_COOLDOWN_VAR_PREFIX = "COMBATV2_ABILITY_WEAPON_COOLDOWN_"
-- A special's cooldown debuff, and the prefix its key takes to make its
-- cooldown vars. Necromancy guards (Death Grasp) and newer weapons are
-- named the second way.
local COOLDOWN_DEBUFF_NAMES = {
    { debuff = "^COMBATV2_ABILITY_WEAPON_(.+)_COOLDOWN$", varPrefix = WEAPON_COOLDOWN_VAR_PREFIX },
    { debuff = "^COMBATV2_DEBUFF_(.+)_WEAPON_COOLDOWN$", varPrefix = "COMBATV2_COOLDOWN_WEAPON_" },
}
-- Debuff keys to the special's key, where the cooldown vars are named
-- after the special instead.
local SPECIAL_KEYS = {
    -- Malachi's tooth's Sanguine Volley.
    RANGED_GHRAZI_CROSSBOW_T95 = "SANGUINE_VOLLEY",
}
-- The tier a weapon's name ends with ("Death guard (tier 70)").
local TIER_SUFFIX_PATTERN = "%s*%([Tt]ier %d+%)$"

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

--- A special, if its cooldown vars exist.
---@param key string
---@param name string
---@param var string Its cooldown vars without _START/_END.
---@param object integer? The weapon.
---@param icon integer? A sprite id, when the debuff has one.
---@return SpecialAttackEntry?
local function specialAttack(key, name, var, object, icon)
    if not gameApi.VarExists(var .. "_START") then return nil end
    local weapon = object and gameApi.ItemName(object)
    -- Every tier shares the special, and the debuff names only one.
    weapon = weapon and weapon:gsub(TIER_SUFFIX_PATTERN, "")
    return {
        key = key,
        name = name,
        weapon = weapon,
        icon = icon,
        object = object,
        var = var,
    }
end

--- The specials with cooldown vars, named by their cooldown debuffs in the
--- buff list. Reads whether each var exists, and each weapon's name, so call
--- it when the buff list changes.
---@param buffs BuffEntry[] The buff catalogue's list.
---@return SpecialAttackEntry[]
function specialAttackCatalogue.List(buffs)
    local specials = {}
    for _, entry in ipairs(buffs) do
        local key, var = nil, nil
        if entry.kind == "debuff" then key, var = cooldownDebuffKey(entry.structName) end
        local special = var and specialAttack(key, entry.name, var, entry.object, entry.icon)
        if special ~= nil then specials[#specials + 1] = special end
    end
    return specials
end

return specialAttackCatalogue
