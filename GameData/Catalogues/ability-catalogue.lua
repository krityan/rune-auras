-- Lists the player's combat abilities from game config, with their names
-- and icons, so cooldown sources don't need writing by hand.
-- Each combat style has an enum COMBATV2_ABILITIES_<STYLE> whose values are
-- structs named COMBATV2_ABILITY_<SKILL>_<ABILITY> (spells: MAGIC_<SPELL>),
-- carrying params such as COMBATV2_ABILITY_NAME and COMBATV2_ABILITY_ICON (a
-- sprite id). The name, without COMBATV2_ABILITY_, normally matches the
-- ability's cooldown vars COMBATV2_COOLDOWN_<name>_START/_END; VAR_ALIASES
-- covers the ones that don't, including abilities that share another's
-- cooldown. Only abilities with a var pair are listed.
-- Usage:
--   local abilityCatalogue = require("GameData/Catalogues/ability-catalogue")
--   for _, ability in ipairs(abilityCatalogue.List()) do ... end
--   -- ability = { id, label, var (cooldown var base), icon (sprite id or nil) }
--   abilityCatalogue.ApplyGreaterUnlocks()   -- in game, until it reports complete
--   abilityCatalogue.OnVarChanged(name, value)   -- for each var update
-- Abilities with a greater version (e.g. Greater Ricochet) have an unlock
-- flag COMBATV2_ABILITY_<SKILL>_GREATER_<ABILITY>_UNLOCKED and a struct
-- COMBATV2_ABILITY_<SKILL>_GREATER_<ABILITY> with the greater icon. Once the
-- player is in game, ApplyGreaterUnlocks switches unlocked ones to it, and
-- OnVarChanged follows the flags as they arrive or change mid-session.

local vars = require("GameData/vars")

local abilityCatalogue = {}

-- Hand-written abilities, used only while the config can't be read (e.g.
-- loading at the login screen). They predate the catalogue, so they have no
-- `id` (the data sources name them by their var); `legacyID` is the name
-- auras saved before then used, migrated through data-sources' RENAMED_IDS.
abilityCatalogue.FALLBACK = {
    { legacyID = "berserk", label = "Berserk", var = "COMBATV2_COOLDOWN_STRENGTH_BERSERK" },
    { legacyID = "sunshine", label = "Sunshine", var = "COMBATV2_COOLDOWN_MAGIC_SUNSHINE" },
    { legacyID = "deaths_swiftness", label = "Death's Swiftness", var = "COMBATV2_COOLDOWN_RANGED_DEATHS_SWIFTNESS" },
    { legacyID = "living_death", label = "Living Death", var = "COMBATV2_COOLDOWN_NECROMANCY_LIVING_DEATH" },
    { legacyID = "surge", label = "Surge", var = "COMBATV2_COOLDOWN_MAGIC_SURGE" },
    { legacyID = "escape", label = "Escape", var = "COMBATV2_COOLDOWN_RANGED_ESCAPE" },
    { legacyID = "bladed_dive", label = "Bladed Dive", var = "COMBATV2_COOLDOWN_ATTACK_BLADED_DIVE" },
    { legacyID = "freedom", label = "Freedom", var = "COMBATV2_COOLDOWN_DEFENCE_FREEDOM" },
    { legacyID = "anticipation", label = "Anticipation", var = "COMBATV2_COOLDOWN_DEFENCE_ANTICIPATION" },
    { legacyID = "resonance", label = "Resonance", var = "COMBATV2_COOLDOWN_DEFENCE_RESONANCE" },
    { legacyID = "barricade", label = "Barricade", var = "COMBATV2_COOLDOWN_DEFENCE_BARRICADE" },
    { legacyID = "devotion", label = "Devotion", var = "COMBATV2_COOLDOWN_DEFENCE_DEVOTION" },
}

-- The combat style enums, COMBATV2_ABILITIES_<STYLE> (melee abilities are
-- all in MELEE; there's no ATTACK or STRENGTH enum).
local STYLES = { "MELEE", "RANGED", "MAGIC", "NECROMANCY", "DEFENCE", "CONSTITUTION" }
local STRUCT_PREFIX = "COMBATV2_ABILITY_"
local COOLDOWN_PREFIX = "COMBATV2_COOLDOWN_"
-- Struct name (without COMBATV2_ABILITY_) -> the cooldown var name it uses,
-- where they differ. Found by matching every ability enum's structs against
-- Data/cooldowns.txt.
local VAR_ALIASES = {
    -- Shares Bladed Dive's cooldown.
    ATTACK_DIVE = "ATTACK_BLADED_DIVE",
    MAGIC_DRAGONBREATH = "MAGIC_DRAGON_BREATH",
    MAGIC_MAGMA_TEMPEST_REVOLUTION = "MAGIC_MAGMA_TEMPEST",
    STRENGTH_DISMEMBER = "MELEE_DISMEMBER",
    -- The other Vengeance spells share Vengeance's cooldown.
    MAGIC_VENGEANCE_OTHER = "MAGIC_VENGEANCE",
    MAGIC_VENGEANCE_GROUP = "MAGIC_VENGEANCE",
}
-- Ability name -> its greater version's name, where that isn't
-- <SKILL>_GREATER_<ABILITY>.
local GREATER_ALIASES = {
    -- Sonic Wave's struct still has its old name.
    MAGIC_SONIC_BOOM = "MAGIC_GREATER_SONIC_WAVE",
}
-- Greater icons for the greater versions with no struct under that name
-- (their structs exist, sharing the base's COMBATV2_ABILITY_ID, but under
-- names nothing points to). These sprites sit right after the base icons
-- (20183 Sunshine, 20185 Death's Swiftness) and are the greater art; found by
-- decoding the neighbouring sprites from the game cache.
local GREATER_ICONS = {
    MAGIC_GREATER_SUNSHINE = 20184,
    RANGED_GREATER_DEATHS_SWIFTNESS = 20186,
}
local NAME_PARAM = "COMBATV2_ABILITY_NAME"
local ICON_PARAM = "COMBATV2_ABILITY_ICON"

local abilities = nil
-- Whether ApplyGreaterUnlocks has read every unlock flag since the last Reset.
local greaterChecked = false
-- Unlock var name -> the abilities it upgrades, built with the list.
local unlockIndex = {}
-- The abilities' icon sprite ids, as "id,id,...", saved for
-- Tools/make-grey-icons.py, which reads them from the client's plugin
-- database to make the greyed-out icons in resources/GreyIcons.
local ICON_IDS_STORAGE_KEY = "abilityIconIDs"

local function varExists(name)
    local found, exists = pcall(function() return var.VarPlayer[name] ~= nil end)
    return found and exists
end

-- Param configs by name, looked up once.
local paramConfigs = {}
local function paramConfig(name)
    if paramConfigs[name] == nil then
        local found, param = pcall(function() return config.Param[name] end)
        paramConfigs[name] = found and param or false
    end
    return paramConfigs[name] or nil
end

-- Reads one param by name. A struct's params are a list of param configs,
-- so fall back to finding it there if the by-name lookup isn't available.
local function readParam(struct, name)
    local param = paramConfig(name)
    if param ~= nil then
        local ok, value = pcall(function() return struct:GetParamValue(param) end)
        if ok then return value end
    end
    local value = nil
    pcall(function()
        for _, candidate in pairs(struct.params) do
            if candidate.configName == name then
                value = struct:GetParamValue(candidate)
                return
            end
        end
    end)
    return value
end

-- The ability's name without COMBATV2_ABILITY_, or a spell's own name
-- (MAGIC_<SPELL>); nil for anything else in the enum.
local function abilityName(structName)
    if structName:sub(1, #STRUCT_PREFIX) == STRUCT_PREFIX then
        return structName:sub(#STRUCT_PREFIX + 1)
    end
    if structName:sub(1, 6) == "MAGIC_" then return structName end
    return nil
end

-- The greater version of an ability, if it has one: { unlockVar, icon }.
-- icon is nil if the greater struct couldn't be found.
local function greaterVersion(name)
    local greaterName = GREATER_ALIASES[name]
    if greaterName == nil then
        local skill, rest = string.match(name, "^(%u+)_(.+)$")
        if skill == nil then return nil end
        greaterName = skill .. "_GREATER_" .. rest
    end
    local unlockVar = STRUCT_PREFIX .. greaterName .. "_UNLOCKED"
    if not varExists(unlockVar) then return nil end
    local icon = nil
    pcall(function()
        local struct = config.Struct[STRUCT_PREFIX .. greaterName]
        if struct ~= nil then icon = readParam(struct, ICON_PARAM) end
    end)
    if type(icon) ~= "number" or icon <= 0 then icon = GREATER_ICONS[greaterName] end
    return { unlockVar = unlockVar, icon = icon }
end

local function addEntry(entry, seen)
    local struct = entry[2]
    local structName = struct and tostring(struct.configName or "") or ""
    local name = abilityName(structName)
    -- Several abilities can share one cooldown, so entries are kept apart by
    -- struct rather than by var.
    if name == nil or seen[name] then return end
    local varBase = COOLDOWN_PREFIX .. (VAR_ALIASES[name] or name)
    if not varExists(varBase .. "_START") or not varExists(varBase .. "_END") then return end
    seen[name] = true
    local label = readParam(struct, NAME_PARAM)
    local icon = readParam(struct, ICON_PARAM)
    abilities[#abilities + 1] = {
        -- Named after the struct: for most abilities that's also the var, so
        -- ids saved before aliases existed still match.
        id = "cooldown_" .. string.lower(name),
        label = type(label) == "string" and label ~= "" and label or structName,
        var = varBase,
        icon = type(icon) == "number" and icon or nil,
        greater = greaterVersion(name),
    }
end

local function addStyle(style, seen)
    local found, values = pcall(function() return config.Enum["COMBATV2_ABILITIES_" .. style].values end)
    if not found or values == nil then return end
    -- Each entry on its own, so one that can't be read only skips itself.
    for _, entry in ipairs(values) do
        pcall(addEntry, entry, seen)
    end
end

-- Every ability with a cooldown, in style then enum order. Built on first
-- use; empty if the config can't be read, in which case the next call tries
-- again (config may not be loaded before entering the game).
local function saveIconIDs()
    local ids, seen = {}, {}
    -- Greater icons too, so their grey copies get made before they're used.
    local function add(icon)
        if icon ~= nil and not seen[icon] then
            seen[icon] = true
            ids[#ids + 1] = icon
        end
    end
    for _, ability in ipairs(abilities) do
        add(ability.baseIcon or ability.icon)
        add(ability.greater and ability.greater.icon)
    end
    table.sort(ids)
    local value = table.concat(ids, ",")
    pcall(function()
        if PersistentDB:GetString(ICON_IDS_STORAGE_KEY) ~= value then
            PersistentDB:SetString(ICON_IDS_STORAGE_KEY, value)
        end
    end)
end

function abilityCatalogue.List()
    if abilities ~= nil and #abilities > 0 then return abilities end
    abilities = {}
    local seen = {}
    for _, style in ipairs(STYLES) do addStyle(style, seen) end
    unlockIndex = {}
    for _, ability in ipairs(abilities) do
        local greater = ability.greater
        if greater ~= nil and greater.icon ~= nil then
            local list = unlockIndex[greater.unlockVar] or {}
            list[#list + 1] = ability
            unlockIndex[greater.unlockVar] = list
        end
    end
    if #abilities > 0 then saveIconIDs() end
    return abilities
end

-- Sets an ability's icon for its greater unlock flag's value. Returns
-- whether the icon changed.
local function applyUnlock(ability, value)
    ability.baseIcon = ability.baseIcon or ability.icon
    local icon = (value or 0) ~= 0 and ability.greater.icon or ability.baseIcon
    if icon == ability.icon then return false end
    ability.icon = icon
    return true
end

-- Switches abilities whose greater version is unlocked to the greater icon.
-- Call it in game. Returns changed (any icon changed) and complete (every
-- flag could be read); flags that haven't arrived yet are left for a later
-- call, so keep calling until complete.
function abilityCatalogue.ApplyGreaterUnlocks()
    if greaterChecked then return false, true end
    if abilities == nil or #abilities == 0 then return false, false end
    local changed, complete = false, true
    for _, ability in ipairs(abilities) do
        local greater = ability.greater
        if greater ~= nil and greater.icon ~= nil then
            local value = vars.ReadVarPlayer(greater.unlockVar)
            if value == nil then
                complete = false
            elseif applyUnlock(ability, value) then
                changed = true
            end
        end
    end
    greaterChecked = complete
    return changed, complete
end

-- Applies a var update if it's a greater unlock flag, e.g. one arriving
-- late or the player unlocking a greater ability. One table lookup for any
-- other var. Returns whether any icon changed.
function abilityCatalogue.OnVarChanged(name, value)
    local list = unlockIndex[name]
    if list == nil then return false end
    local changed = false
    for _, ability in ipairs(list) do
        if applyUnlock(ability, tonumber(value)) then changed = true end
    end
    return changed
end

-- Lets the next login check the unlocks again (it may be another account).
function abilityCatalogue.Reset()
    greaterChecked = false
end

return abilityCatalogue
