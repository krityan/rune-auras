-- The player's combat abilities from game config: names, icons and cooldown
-- vars. Owns the AbilityEntry record, recast stages and greater versions' icons.

local gameApi = require("GameData/game-api")

local abilityCatalogue = {}

--- A greater version of an ability (e.g. Greater Ricochet), which has an
--- unlock flag and a separate icon.
---@class GreaterVersion
---@field unlockVar string COMBATV2_ABILITY_<SKILL>_GREATER_<ABILITY>_UNLOCKED, or an Elite Dungeon 2 flag (see ED_GREATERS).
---@field icon integer? Sprite id; nil if the greater struct couldn't be found.

--- An ability with a cooldown.
---@class AbilityEntry
---@field id string? Source id, "cooldown_<struct name>"; FALLBACK entries have none.
---@field legacyID string? FALLBACK only: the id auras saved before the catalogue used.
---@field label string
---@field structName string? Its struct's name (COMBATV2_ABILITY_ATTACK_BARGE, or a spell's MAGIC_<SPELL>); FALLBACK entries have none.
---@field var string Cooldown var base (COMBATV2_COOLDOWN_<name>, without _START/_END).
---@field icon integer? Sprite id: the greater one while that's unlocked.
---@field baseIcon integer? The base icon, kept once a greater unlock has been applied.
---@field greater GreaterVersion?
---@field channelled boolean? COMBATV2_ABILITY_IS_CHANNELLED.
---@field key string? Names it across versions (see Key).
---@field stages AbilityStage[]? What it turns into as it's used, in order (Dismember: Slaughter, then Massacre).
---@field command AbilityCommand? For a conjure, the command the action bar swaps it for while the conjure is out.
---@field movedFrom string[]? Ids of abilities left out in its favour (see REPLACED_BY), so auras saved with them follow it.
---@field levelReq integer? COMBATV2_ABILITY_LEVEL_REQ: the level it needs in levelSkill.
---@field levelSkill string? The SkillType key levelReq is in, from its struct's name; nil where that doesn't name one skill (MELEE_).
---@field unlockVar string? <struct name>_UNLOCKED, for an ability unlocked by more than a level (a quest, a codex): non-zero once it is.

--- The command a conjure turns into on the action bar while the conjure is
--- out (Conjure Skeleton Warrior, then Command Skeleton Warrior).
---@class AbilityCommand
---@field label string? nil if its struct couldn't be read.
---@field icon integer?
---@field var string The command's cooldown var base.
---@field activeVar string COMBATV2_ABILITY_<conjure>_ACTIVE, 1 while the conjure is out.

--- A later stage of an ability that turns into others as it's used: its
--- recast, COMBATV2_ABILITY_<var name>_RECAST_<n>. It's the current stage
--- while its flag is set, which the game clears when the last stage is used
--- or the ability's cooldown ends.
---@class AbilityStage
---@field label string? nil if its struct couldn't be read.
---@field icon integer?
---@field activeVar string COMBATV2_ABILITY_<var name>_RECAST_<n>_ACTIVE, 1 while it's the current stage.

--- A Magic spell's name and icon, whether or not it has a cooldown (see
--- MagicSpell).
---@class MagicSpell
---@field name string?
---@field icon integer? Sprite id.

--- Names an ability across every struct of it (its greater version,
--- Flurry's Bloodlust and DoT variants): COMBATV2_ABILITY_ID is only unique
--- within a skill, so it's paired with COMBATV2_ABILITY_PARENT_STAT. The one
--- place this format lives (the channel tracker reports the same).
---@param abilityID any
---@param skill any
---@return string? key "id:skill"; nil without both.
function abilityCatalogue.Key(abilityID, skill)
    if abilityID == nil or skill == nil then
        return nil
    end

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
-- Icons for greater versions whose struct isn't under the expected name (it
-- shares the base's COMBATV2_ABILITY_ID): the sprites right after the base
-- icons (20183 Sunshine, 20185 Death's Swiftness).
local GREATER_ICONS = {
    MAGIC_GREATER_SUNSHINE = 20184,
    RANGED_GREATER_DEATHS_SWIFTNESS = 20186,
}
-- Conjures (by var name) to the command the action bar shows in their
-- place while they're out, which has a separate cooldown. Conjure Undead Army
-- is left out: it summons up to all four, so which command isn't known.
local COMMANDS = {
    NECROMANCY_CONJURE_SKELETON_WARRIOR = "NECROMANCY_COMMAND_SKELETON_WARRIOR",
    NECROMANCY_CONJURE_PUTRID_ZOMBIE = "NECROMANCY_COMMAND_PUTRID_ZOMBIE",
    NECROMANCY_CONJURE_VENGEFUL_GHOST = "NECROMANCY_COMMAND_VENGEFUL_GHOST",
    NECROMANCY_CONJURE_PHANTOM_GUARDIAN = "NECROMANCY_COMMAND_PHANTOM_GUARDIAN",
}
-- Abilities left out of the list, to the ability listed in their place,
-- which shares their cooldown var. Auras saved with them move to it.
local REPLACED_BY = {
    -- "Magma Tempest (Targeted)": the targeted mode of the same ability, which
    -- MAGIC_MAGMA_TEMPEST_REVOLUTION lists as plain Magma Tempest.
    MAGIC_MAGMA_TEMPEST = "MAGIC_MAGMA_TEMPEST_REVOLUTION",
}
-- Greater versions unlocked from codices in Elite Dungeon 2, by ability name,
-- with their unlock flag and COMBAT_ABILITY_ICON_MUTATED_<ABILITY> sprite.
-- TODO: check the flag is set once the codex is used.
local ED_GREATERS = {
    ATTACK_BARGE = { unlockVar = "DUNGEON_REWARD_SHOP_BARGE_OVERRIDE_UNLOCK", icon = 840 },
    ATTACK_FLURRY = { unlockVar = "DUNGEON_REWARD_SHOP_FLURRY_OVERRIDE_UNLOCK", icon = 841 },
    STRENGTH_FURY = { unlockVar = "DUNGEON_REWARD_SHOP_FURY_OVERRIDE_UNLOCK", icon = 842 },
}
local NAME_PARAM = "COMBATV2_ABILITY_NAME"
local ICON_PARAM = "COMBATV2_ABILITY_ICON"
local CHANNELLED_PARAM = "COMBATV2_ABILITY_IS_CHANNELLED"
local ID_PARAM = "COMBATV2_ABILITY_ID"
local SKILL_PARAM = "COMBATV2_ABILITY_PARENT_STAT"
local LEVEL_REQ_PARAM = "COMBATV2_ABILITY_LEVEL_REQ"
-- An ability's level requirement is in the skill its struct's name starts
-- with (the parent stat is its combat style, one for Attack and Strength):
-- that word to the SkillType key.
local LEVEL_SKILLS = {
    ATTACK = "ATTACK", STRENGTH = "STRENGTH", RANGED = "RANGED", MAGIC = "MAGIC",
    DEFENCE = "DEFENCE", CONSTITUTION = "HITPOINTS", NECROMANCY = "NECROMANCY",
}
-- An unlock flag's name is the struct's name with this after it.
local UNLOCKED_SUFFIX = "_UNLOCKED"
-- A recast stage's struct and vars are the ability's var name with this and
-- its number (see AbilityStage).
local RECAST_INFIX = "_RECAST_"
local ACTIVE_SUFFIX = "_ACTIVE"
-- Dismember and Spectral Scythe have two; looked for up to this many.
local MAX_STAGES = 4
-- An enum entry is { key, value }; the value is the ability's struct, and in
-- the Magic enum the key is its COMBATV2_ABILITY_ID.
local ENUM_KEY, ENUM_VALUE = 1, 2
-- The combat style whose enum lists the spells.
local MAGIC_STYLE = "MAGIC"
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
    if param == nil then
        return nil
    end

    return gameApi.ParamValue(struct, param)
end

--- The key (see Key) of the ability an ability var names: a struct, as read
--- directly, or its id, as VarTransmit gives it.
---@param value any
---@return string? key nil for none (-1) or a struct that isn't an ability's struct.
---@return userdata? struct The struct, for reading more of its params; nil with no key.
function abilityCatalogue.StructKey(value)
    local struct = value
    if type(value) == "number" then
        if value < 0 then
            return nil
        end

        struct = gameApi.StructByID(value)
    end

    if struct == nil or type(struct) == "boolean" then
        return nil
    end

    local key = abilityCatalogue.Key(readParam(struct, "COMBATV2_ABILITY_ID"), readParam(struct, "COMBATV2_ABILITY_PARENT_STAT"))
    if key == nil then
        return nil
    end

    return key, struct
end

--- An ability's name from its struct's name: without COMBATV2_ABILITY_, or a
--- spell's name (MAGIC_<SPELL>).
---@param structName string
---@return string? name nil for anything else in the enum.
local function abilityName(structName)
    if structName:sub(1, #STRUCT_PREFIX) == STRUCT_PREFIX then
        return structName:sub(#STRUCT_PREFIX + 1)
    end

    if structName:sub(1, #SPELL_PREFIX) == SPELL_PREFIX then
        return structName
    end

    return nil
end

--- The greater version of an ability.
---@param name string The ability's name (see abilityName).
---@return GreaterVersion? greater nil if it has none.
local function greaterVersion(name)
    local edGreater = ED_GREATERS[name]
    if edGreater ~= nil then
        if not varExists(edGreater.unlockVar) then
            return nil
        end

        return { unlockVar = edGreater.unlockVar, icon = edGreater.icon }
    end

    local greaterName = GREATER_ALIASES[name]
    if greaterName == nil then
        local skill, rest = string.match(name, "^(%u+)_(.+)$")
        if skill == nil then
            return nil
        end

        greaterName = skill .. "_GREATER_" .. rest
    end

    local unlockVar = STRUCT_PREFIX .. greaterName .. "_UNLOCKED"
    if not varExists(unlockVar) then
        return nil
    end

    local icon = nil
    local struct = gameApi.Struct(STRUCT_PREFIX .. greaterName)
    if struct ~= nil then
        icon = readParam(struct, ICON_PARAM)
    end

    if type(icon) ~= "number" or icon <= 0 then
        icon = GREATER_ICONS[greaterName]
    end

    return { unlockVar = unlockVar, icon = icon }
end

--- The stages an ability turns into, found by name from its var name.
---@param varName string The ability's cooldown var without COMBATV2_COOLDOWN_ (e.g. MELEE_DISMEMBER).
---@return AbilityStage[]? stages nil if it has none.
local function abilityStages(varName)
    local stages = nil
    for number = 1, MAX_STAGES do
        local name = varName .. RECAST_INFIX .. number
        local activeVar = STRUCT_PREFIX .. name .. ACTIVE_SUFFIX
        if not varExists(activeVar) then
            break
        end

        local struct = gameApi.Struct(STRUCT_PREFIX .. name)
        local label = struct and readParam(struct, NAME_PARAM)
        local icon = struct and readParam(struct, ICON_PARAM)
        stages = stages or {}
        stages[number] = {
            label = type(label) == "string" and label ~= "" and label or nil,
            icon = type(icon) == "number" and icon or nil,
            activeVar = activeVar,
        }
    end

    return stages
end

--- The command a conjure turns into while it's out (see COMMANDS).
---@param varName string The conjure's cooldown var without COMBATV2_COOLDOWN_.
---@return AbilityCommand? command nil for anything but a listed conjure, or one whose vars aren't there.
local function conjureCommand(varName)
    local commandName = COMMANDS[varName]
    if commandName == nil then
        return nil
    end

    local activeVar = STRUCT_PREFIX .. varName .. ACTIVE_SUFFIX
    local commandVar = abilityCatalogue.COOLDOWN_VAR_PREFIX .. commandName
    if not varExists(activeVar) or not varExists(commandVar .. "_START") then
        return nil
    end

    local struct = gameApi.Struct(STRUCT_PREFIX .. commandName)
    local label = struct and readParam(struct, NAME_PARAM)
    local icon = struct and readParam(struct, ICON_PARAM)
    return {
        label = type(label) == "string" and label ~= "" and label or nil,
        icon = type(icon) == "number" and icon or nil,
        var = commandVar,
        activeVar = activeVar,
    }
end

--- The ids of the abilities left out in an ability's favour (see REPLACED_BY).
---@param name string The ability's name (see abilityName).
---@return string[]? ids nil if none were.
local function replacedIDs(name)
    local ids = nil
    for replaced, replacement in pairs(REPLACED_BY) do
        if replacement == name then
            ids = ids or {}
            ids[#ids + 1] = abilityCatalogue.SOURCE_ID_PREFIX .. string.lower(replaced)
        end
    end

    return ids
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
    if name == nil or seen[name] or REPLACED_BY[name] then
        return
    end

    local varName = VAR_ALIASES[name] or name
    local varBase = abilityCatalogue.COOLDOWN_VAR_PREFIX .. varName
    if not varExists(varBase .. "_START") or not varExists(varBase .. "_END") then
        return
    end

    seen[name] = true
    local label = readParam(struct, NAME_PARAM)
    local icon = readParam(struct, ICON_PARAM)
    local abilityID, skill = readParam(struct, ID_PARAM), readParam(struct, SKILL_PARAM)
    local hasLabel = type(label) == "string" and label ~= ""
    local levelReq = math.tointeger(readParam(struct, LEVEL_REQ_PARAM))
    local unlockVar = structName .. UNLOCKED_SUFFIX
    abilities[#abilities + 1] = {
        -- Named after the struct: for most abilities that's also the var, so
        -- ids saved before aliases existed still match.
        id = abilityCatalogue.SOURCE_ID_PREFIX .. string.lower(name),
        label = hasLabel and label or structName,
        structName = structName,
        var = varBase,
        icon = type(icon) == "number" and icon or nil,
        greater = greaterVersion(name),
        channelled = readParam(struct, CHANNELLED_PARAM) == IS_CHANNELLED,
        key = abilityCatalogue.Key(abilityID, skill),
        stages = abilityStages(varName),
        command = conjureCommand(varName),
        movedFrom = replacedIDs(name),
        levelReq = levelReq,
        levelSkill = LEVEL_SKILLS[name:match("^(%u+)_")],
        unlockVar = varExists(unlockVar) and unlockVar or nil,
    }
end

--- Adds one combat style's abilities.
---@param style string A STYLES entry.
---@param seen table<string, boolean>
local function addStyle(style, seen)
    local values = gameApi.EnumValues(STYLE_ENUM_PREFIX .. style)
    if values == nil then
        return
    end

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
    if abilities ~= nil and #abilities > 0 then
        return abilities
    end

    abilities = {}
    local seen = {}
    for _, style in ipairs(STYLES) do
        addStyle(style, seen)
    end

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
    if icon == ability.icon then
        return false
    end

    ability.icon = icon
    return true
end

--- Switches abilities whose greater version is unlocked to the greater
--- icon. Call it in game; flags that haven't arrived yet are left for a
--- later call, so keep calling until complete.
---@return boolean changed Whether any icon changed.
---@return boolean complete Whether every flag could be read.
function abilityCatalogue.ApplyGreaterUnlocks()
    if greaterChecked then
        return false, true
    end

    if abilities == nil or #abilities == 0 then
        return false, false
    end

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
    if list == nil then
        return false
    end

    local changed = false
    for _, ability in ipairs(list) do
        if applyUnlock(ability, tonumber(value)) then
            changed = true
        end
    end

    return changed
end

--- A Magic spell's name and icon, by its COMBATV2_ABILITY_ID (what the
--- autocast var holds). Read from the Magic enum, so it covers spells the
--- list leaves out for having no cooldown (the combat spells).
---@param abilityID integer
---@return MagicSpell|false|nil spell false if the enum doesn't list it; nil if the enum can't be read.
function abilityCatalogue.MagicSpell(abilityID)
    local values = gameApi.EnumValues(STYLE_ENUM_PREFIX .. MAGIC_STYLE)
    if values == nil then
        return nil
    end

    for _, entry in ipairs(values) do
        local struct = type(entry) == "table" and entry[ENUM_KEY] == abilityID and entry[ENUM_VALUE] or nil
        if struct ~= nil then
            local name, icon = readParam(struct, NAME_PARAM), readParam(struct, ICON_PARAM)
            return {
                name = type(name) == "string" and name ~= "" and name or nil,
                icon = math.tointeger(icon),
            }
        end
    end

    return false
end

--- Lets the next login check the unlocks again (it may be another account).
function abilityCatalogue.Reset()
    greaterChecked = false
end

return abilityCatalogue
