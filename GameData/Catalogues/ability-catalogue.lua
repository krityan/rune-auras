-- The player's combat abilities, listed from game config with their names,
-- icons and cooldown vars, so cooldown sources don't need writing by hand.
-- Owns the AbilityEntry record and switching icons for greater versions.

local gameApi = require("GameData/game-api")

local abilityCatalogue = {}

--- A greater version of an ability (e.g. Greater Ricochet), which has an
--- unlock flag and its own icon.
---@class GreaterVersion
---@field unlockVar string COMBATV2_ABILITY_<SKILL>_GREATER_<ABILITY>_UNLOCKED.
---@field icon integer? Sprite id; nil if the greater struct couldn't be found.

--- An ability with a cooldown.
---@class AbilityEntry
---@field id string? Source id, "cooldown_<struct name>"; FALLBACK entries have none.
---@field legacyID string? FALLBACK only: the id auras saved before the catalogue used.
---@field label string
---@field var string Cooldown var base (COMBATV2_COOLDOWN_<name>, without _START/_END).
---@field icon integer? Sprite id: the greater one while that's unlocked.
---@field baseIcon integer? The base icon, kept once a greater unlock has been applied.
---@field greater GreaterVersion?
---@field channelled boolean? COMBATV2_ABILITY_IS_CHANNELLED.
---@field key string? Names it across versions (see Key).

--- Names an ability across every struct of it (its greater version,
--- Flurry's Bloodlust and DoT variants): COMBATV2_ABILITY_ID is only unique
--- within a skill, so it's paired with COMBATV2_ABILITY_PARENT_STAT. The one
--- place this format lives (the channel tracker reports the same).
---@param abilityID any
---@param skill any
---@return string? key "id:skill"; nil without both.
function abilityCatalogue.Key(abilityID, skill)
    if abilityID == nil or skill == nil then return nil end
    return tostring(abilityID) .. ":" .. tostring(skill)
end

--- Hand-written abilities, used only while the config can't be read (e.g.
--- loading at the login screen). They predate the catalogue, so they have no
--- `id` (the data sources name them by their var); `legacyID` is migrated
--- through data-sources' RENAMED_IDS.
---@type AbilityEntry[]
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

-- The combat style enums, COMBATV2_ABILITIES_<STYLE>, whose values are
-- structs named COMBATV2_ABILITY_<SKILL>_<ABILITY> (melee abilities are all
-- in MELEE; there's no ATTACK or STRENGTH enum).
local STYLES = { "MELEE", "RANGED", "MAGIC", "NECROMANCY", "DEFENCE", "CONSTITUTION" }
local STYLE_ENUM_PREFIX = "COMBATV2_ABILITIES_"
abilityCatalogue.STRUCT_PREFIX = "COMBATV2_ABILITY_"
local STRUCT_PREFIX = abilityCatalogue.STRUCT_PREFIX
-- Spells' structs are named MAGIC_<SPELL>, without the struct prefix.
local SPELL_PREFIX = "MAGIC_"
-- Every cooldown var is COMBATV2_COOLDOWN_<name>_START/_END, and buffs'
-- effect vars follow the same naming.
abilityCatalogue.COOLDOWN_VAR_PREFIX = "COMBATV2_COOLDOWN_"
-- A cooldown source's id is this plus the ability's name in lower case.
abilityCatalogue.SOURCE_ID_PREFIX = "cooldown_"
-- Struct name (without COMBATV2_ABILITY_) to the cooldown var name it uses,
-- where they differ. Found by matching every ability enum's structs against
-- the cooldown vars.
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
-- Ability name to its greater version's name, where that isn't
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
local CHANNELLED_PARAM = "COMBATV2_ABILITY_IS_CHANNELLED"
local ID_PARAM = "COMBATV2_ABILITY_ID"
local SKILL_PARAM = "COMBATV2_ABILITY_PARENT_STAT"
-- An enum entry is { key, value }; the value is the ability's struct.
local ENUM_VALUE = 2
-- The channelled param's value for a channelled ability.
local IS_CHANNELLED = 1

---@type AbilityEntry[]? nil until listed.
local abilities = nil
-- Whether ApplyGreaterUnlocks has read every unlock flag since the last Reset.
local greaterChecked = false
---@type table<string, AbilityEntry[]> Unlock var name to the abilities it upgrades, built with the list.
local unlockIndex = {}

local varExists = gameApi.VarExists

-- Param name to its config (false if missing), looked up once.
local paramConfigs = {}

--- A param config by name, looked up once.
---@param name string
---@return userdata?
local function paramConfig(name)
    if paramConfigs[name] == nil then
        paramConfigs[name] = gameApi.Param(name) or false
    end
    return paramConfigs[name] or nil
end

--- A struct's value for a param, by the param's name.
---@param struct userdata
---@param name string
---@return any value nil if it can't be read.
local function readParam(struct, name)
    local param = paramConfig(name)
    if param == nil then return nil end
    return gameApi.ParamValue(struct, param)
end

--- An ability's name from its struct's name: without COMBATV2_ABILITY_, or a
--- spell's own name (MAGIC_<SPELL>).
---@param structName string
---@return string? name nil for anything else in the enum.
local function abilityName(structName)
    if structName:sub(1, #STRUCT_PREFIX) == STRUCT_PREFIX then
        return structName:sub(#STRUCT_PREFIX + 1)
    end
    if structName:sub(1, #SPELL_PREFIX) == SPELL_PREFIX then return structName end
    return nil
end

--- The greater version of an ability.
---@param name string The ability's name (see abilityName).
---@return GreaterVersion? greater nil if it has none.
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
    local struct = gameApi.Struct(STRUCT_PREFIX .. greaterName)
    if struct ~= nil then icon = readParam(struct, ICON_PARAM) end
    if type(icon) ~= "number" or icon <= 0 then icon = GREATER_ICONS[greaterName] end
    return { unlockVar = unlockVar, icon = icon }
end

--- Adds a style enum's entry to the list, if it's an ability with a
--- cooldown var pair. Several abilities can share one cooldown, so entries
--- are kept apart by struct rather than by var.
---@param entry table An enum `{ key, value }` entry.
---@param seen table<string, boolean> Ability names added so far.
local function addEntry(entry, seen)
    local struct = entry[ENUM_VALUE]
    local structName = struct and tostring(gameApi.ConfigName(struct) or "") or ""
    local name = abilityName(structName)
    if name == nil or seen[name] then return end
    local varBase = abilityCatalogue.COOLDOWN_VAR_PREFIX .. (VAR_ALIASES[name] or name)
    if not varExists(varBase .. "_START") or not varExists(varBase .. "_END") then return end
    seen[name] = true
    local label = readParam(struct, NAME_PARAM)
    local icon = readParam(struct, ICON_PARAM)
    local abilityID, skill = readParam(struct, ID_PARAM), readParam(struct, SKILL_PARAM)
    local hasLabel = type(label) == "string" and label ~= ""
    abilities[#abilities + 1] = {
        -- Named after the struct: for most abilities that's also the var, so
        -- ids saved before aliases existed still match.
        id = abilityCatalogue.SOURCE_ID_PREFIX .. string.lower(name),
        label = hasLabel and label or structName,
        var = varBase,
        icon = type(icon) == "number" and icon or nil,
        greater = greaterVersion(name),
        channelled = readParam(struct, CHANNELLED_PARAM) == IS_CHANNELLED,
        key = abilityCatalogue.Key(abilityID, skill),
    }
end

--- Adds one combat style's abilities.
---@param style string A STYLES entry.
---@param seen table<string, boolean>
local function addStyle(style, seen)
    local values = gameApi.EnumValues(STYLE_ENUM_PREFIX .. style)
    if values == nil then return end
    -- Each entry is game config read at load, so one that's not the
    -- expected {key, struct} shape only skips itself rather than the list.
    for _, entry in ipairs(values) do
        gameApi.Read("an ability enum entry", addEntry, entry, seen)
    end
end

--- Indexes the abilities by the unlock flag of their greater version.
local function indexUnlocks()
    unlockIndex = {}
    for _, ability in ipairs(abilities) do
        local greater = ability.greater
        if greater ~= nil and greater.icon ~= nil then
            local list = unlockIndex[greater.unlockVar] or {}
            list[#list + 1] = ability
            unlockIndex[greater.unlockVar] = list
        end
    end
end

--- Every ability with a cooldown, in style then enum order. Built on first
--- use; empty if the config can't be read, in which case the next call
--- tries again (config may not be loaded before entering the game).
---@return AbilityEntry[]
function abilityCatalogue.List()
    if abilities ~= nil and #abilities > 0 then return abilities end
    abilities = {}
    local seen = {}
    for _, style in ipairs(STYLES) do addStyle(style, seen) end
    indexUnlocks()
    return abilities
end

--- Sets an ability's icon for its greater unlock flag's value.
---@param ability AbilityEntry Has a greater version with an icon.
---@param value number? The flag: non-zero when unlocked.
---@return boolean changed Whether the icon changed.
local function applyUnlock(ability, value)
    ability.baseIcon = ability.baseIcon or ability.icon
    local unlocked = (value or 0) ~= 0
    local icon = unlocked and ability.greater.icon or ability.baseIcon
    if icon == ability.icon then return false end
    ability.icon = icon
    return true
end

--- Switches abilities whose greater version is unlocked to the greater
--- icon. Call it in game; flags that haven't arrived yet are left for a
--- later call, so keep calling until complete.
---@return boolean changed Whether any icon changed.
---@return boolean complete Whether every flag could be read.
function abilityCatalogue.ApplyGreaterUnlocks()
    if greaterChecked then return false, true end
    if abilities == nil or #abilities == 0 then return false, false end
    local changed, complete = false, true
    for _, ability in ipairs(abilities) do
        local greater = ability.greater
        if greater ~= nil and greater.icon ~= nil then
            local value = gameApi.VarPlayer(greater.unlockVar)
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

--- Applies a var update if it's a greater unlock flag, e.g. one arriving
--- late or the player unlocking a greater ability. One table lookup for any
--- other var.
---@param name string
---@param value any
---@return boolean changed Whether any icon changed.
function abilityCatalogue.OnVarChanged(name, value)
    local list = unlockIndex[name]
    if list == nil then return false end
    local changed = false
    for _, ability in ipairs(list) do
        if applyUnlock(ability, tonumber(value)) then changed = true end
    end
    return changed
end

--- Lets the next login check the unlocks again (it may be another account).
function abilityCatalogue.Reset()
    greaterChecked = false
end

return abilityCatalogue
