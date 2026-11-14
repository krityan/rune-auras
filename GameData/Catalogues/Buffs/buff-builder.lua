-- Building the buff list from game config: a struct read as a buff (its
-- name, icon, kind and vars), and the list finished (versions of an ability
-- sharing vars, how the buff bar shows each buff, duplicates dropped, names
-- that clash told apart). Hand-written facts are buff-data's; names are
-- buff-naming's and vars buff-vars'. Finding the structs is buff-catalogue's
-- job.

local gameApi = require("GameData/game-api")
local abilityCatalogue = require("GameData/Catalogues/ability-catalogue")
local gameClock = require("GameData/Trackers/game-clock")
local specialAttackCatalogue = require("GameData/Catalogues/special-attack-catalogue")
local buffData = require("GameData/Catalogues/Buffs/buff-data")
local buffNaming = require("GameData/Catalogues/Buffs/buff-naming")
local buffVars = require("GameData/Catalogues/Buffs/buff-vars")

local buffBuilder = {}

--- A buff or debuff the game's buff bars can show: a struct with a
--- COMBATV2_BUFF_TYPE param. Many are ability structs, which carry the buff
--- params too.
---@class BuffEntry
---@field id string Source id, "buff_<struct name>".
---@field structID integer
---@field structName string Without control characters (see cleanStructName).
---@field name string Its name (see buff-naming).
---@field label string `name`, plus the struct's name when two clash, so the picker can tell them apart.
---@field icon integer? Sprite id (COMBATV2_ABILITY_ICON, or buff-data's ICONS).
---@field object integer? An item whose icon it shows instead (COMBATV2_ABILITY_OBJECT).
---@field kind "buff"|"debuff"
---@field stacks boolean Whether it uses stacks.
---@field stacksPercent boolean Whether the game shows its stacks as a percentage (COMBATV2_BUFF_USES_STACKS_PERCENT).
---@field stacksAtFull integer? For such a buff, its stacks var's value at 100%; nil when the var holds the percentage itself (see buff-data's STACKS).
---@field duration number? Seconds, for buffs from abilities (Death's Swiftness: 30).
---@field ability string? The ability it belongs to (see abilityCatalogue.Key).
---@field endVar string? VarClient holding the Logic tick it ends on.
---@field stacksVar string? VarPlayer holding its stacks.
---@field stacksWhileUntimed boolean? Active while it has stacks and its timer isn't running, its value then the stacks (see buff-data's STACKS).
---@field requiredVar string? A VarPlayer that must also be non-zero for it to count as active (see buff-data's REQUIRES).
---@field endsOffBuffBar boolean Whether it's active only while the game's buff bar shows its icon, or for a toggled buff follows the bar both ways (see endsOffBuffBar).
---@field barIcons integer[]? Sprites the buff bar can show for it besides `icon`: its ability's base and greater icons (see greaterAbilityIcons).
---@field iconGroup BuffIconGroup? The other buffs showing the same icon on the bar (see buff-data's SHARED_ICONS).
---@field quietTicks integer? For a buff that comes once the player stops attacking, the server ticks it takes (see buff-data's QUIET_TICKS).
---@field startVar string? Its ability's _START VarPlayer, for a buff timed from the cast (see buff-vars' START_VAR_NAMES).
---@field activeVar string? VarPlayer that's on while a toggled buff is (see buff-vars' ACTIVE_VAR_NAMES).
---@field objectOverride boolean Whether its icon is an item the game picks while it runs (COMBATV2_BUFF_OBJ_OVERRIDE: the quiver's ammo).
---@field iconSwapped boolean Whether the game swaps its icon by script while it runs (COMBATV2_BUFF_ICON_OVERRIDE: Bloodlust, Perfect Equilibrium), so the buff bar can show a sprite other than its own.
---@field objectVar string? For such a buff, the OBJ VarPlayer holding that item: its active var.
---@field baseStruct string? For a greater ability's buff, its base buff's struct (see shareAbilityVars).
---@field duplicateIDs string[]? Ids of duplicates dropped in its favour (see dropDuplicates).

local SOURCE_ID_PREFIX = "buff_"
-- How the struct names of buffs a boss gains itself start.
local BOSS_BUFF_PREFIX = "COMBATV2_BOSS_BUFF_"
-- The channelled param's value for a channelled ability.
local IS_CHANNELLED = 1
-- COMBATV2_BUFF_TYPE values: 0 buff, 1 debuff, 2 a neutral "stat modified"
-- marker (listed as a buff).
local KINDS = { [0] = "buff", [1] = "debuff", [2] = "buff" }
-- Params every buff is read with; buffs can't be read until all are found.
local REQUIRED_PARAMS = {
    type = "COMBATV2_BUFF_TYPE",
    name = "COMBATV2_ABILITY_NAME",
    icon = "COMBATV2_ABILITY_ICON",
    object = "COMBATV2_ABILITY_OBJECT",
    stacks = "COMBATV2_BUFF_USES_STACKS",
    duration = "COMBATV2_ABILITY_EFFECT_DURATION",
}
-- Params read where they're found. The ability's id and skill only share a
-- var between versions of an ability; a channelled ability is listed as a
-- channel instead; a priority marks the few buffs without a type; the
-- overrides mark an icon the game picks or swaps while the buff runs.
local OPTIONAL_PARAMS = {
    abilityID = "COMBATV2_ABILITY_ID",
    skill = "COMBATV2_ABILITY_PARENT_STAT",
    channelled = "COMBATV2_ABILITY_IS_CHANNELLED",
    priority = "COMBATV2_BUFF_PRIORITY",
    objectOverride = "COMBATV2_BUFF_OBJ_OVERRIDE",
    iconSwapped = "COMBATV2_BUFF_ICON_OVERRIDE",
    stacksPercent = "COMBATV2_BUFF_USES_STACKS_PERCENT",
}

---@type table<string, userdata>? Param configs by key, nil until every required one has been found.
local params = nil

--- The param configs buffs are read with, looked up once.
---@return table<string, userdata>? params nil while a required one can't be found (config may not be readable yet).
local function lookupParams()
    if params ~= nil then return params end
    local found = {}
    for key, name in pairs(REQUIRED_PARAMS) do
        found[key] = gameApi.Param(name)
        if found[key] == nil then return nil end
    end
    for key, name in pairs(OPTIONAL_PARAMS) do found[key] = gameApi.Param(name) end
    params = found
    return params
end

--- Whether buffs can be read yet: every param they need can be found, which
--- it can't before config is readable.
---@return boolean
function buffBuilder.CanRead()
    return lookupParams() ~= nil
end

--- A struct's value for a param it sets.
---@param struct userdata
---@param param userdata?
---@return any value nil if the struct doesn't set it (GetParamValue alone would give the param's default, e.g. 0 for COMBATV2_BUFF_TYPE), the param wasn't found, or it can't be read.
local function readParam(struct, param)
    if param == nil or not gameApi.HasParam(struct, param) then return nil end
    return gameApi.ParamValue(struct, param)
end

--- A struct name without control characters: a few end in a NUL
--- (COMBATV2_BUFF_NECROMANCY_DARKNESS, COMBATV2_TELEBLOCKED), which would keep
--- the var names built from them from matching.
---@param name string
---@return string
local function cleanStructName(name)
    return (name:gsub("%c", ""))
end

--- A struct id's name, as BuffEntry.structName has it.
---@param structID integer
---@return string? name nil if the struct is gone (after a game update) or can't be read.
function buffBuilder.StructName(structID)
    local name = gameApi.StructName(structID)
    if type(name) ~= "string" or name == "" then return nil end
    return cleanStructName(name)
end

--- A buff source's id, from its struct name.
---@param structName string
---@return string
function buffBuilder.SourceID(structName)
    return SOURCE_ID_PREFIX .. structName:lower()
end

--- Whether a source id is a buff source's id, listed or not.
---@param sourceID any
---@return boolean
function buffBuilder.IsSourceID(sourceID)
    return type(sourceID) == "string" and sourceID:sub(1, #SOURCE_ID_PREFIX) == SOURCE_ID_PREFIX
end

--- Whether a config name is one of buff-data's RETIRED_PATTERNS.
---@param name string?
---@return boolean
local function hasRetiredName(name)
    if name == nil then return false end
    for _, pattern in ipairs(buffData.RETIRED_PATTERNS) do
        if name:find(pattern) ~= nil then return true end
    end
    return false
end

--- A struct's name, icon, item, duration and ability params. A buff without
--- its own takes them from the ability it shows (see buff-data's DETAILS_FROM).
---@param struct userdata
---@param structName string
---@return table<string, any> details Param key to its value, nil for each the struct doesn't set.
local function readDetails(struct, structName)
    local details = {}
    local ability = buffData.DETAILS_FROM[structName] and gameApi.Struct(buffData.DETAILS_FROM[structName])
    for _, key in ipairs({ "name", "icon", "object", "duration", "abilityID", "skill" }) do
        details[key] = readParam(struct, params[key])
        if details[key] == nil and ability ~= nil then details[key] = readParam(ability, params[key]) end
    end
    return details
end

--- A struct as a buff, with its vars.
---@param structID integer
---@return BuffEntry? entry nil if it isn't a buff, is a channelled ability's or one the game no longer gives (see buff-data's RETIRED), or can't be read.
function buffBuilder.Read(structID)
    if lookupParams() == nil then return nil end
    local struct = gameApi.StructByID(structID)
    if struct == nil then return nil end
    local buffType = readParam(struct, params.type)
    local kind = KINDS[buffType]
    -- A few buffs have no type, only the buff bar's other params (Undead Instinct).
    if buffType == nil and params.priority ~= nil and gameApi.HasParam(struct, params.priority) then kind = "buff" end
    if kind == nil or readParam(struct, params.channelled) == IS_CHANNELLED then return nil end
    local structName = cleanStructName(tostring(gameApi.ConfigName(struct) or structID))
    local details = readDetails(struct, structName)
    local object = gameApi.ItemID(details.object)
    local isRetired = buffData.RETIRED[structName] or hasRetiredName(structName)
        or (object ~= nil and hasRetiredName(gameApi.ItemConfigName(object)))
    if isRetired then return nil end
    local icon, durationTicks = details.icon, details.duration
    local entry = {
        id = buffBuilder.SourceID(structName),
        structID = structID,
        structName = structName,
        name = buffNaming.For(structName, details.name),
        icon = buffData.ICONS[structName] or ((type(icon) == "number" and icon >= 0) and icon or nil),
        object = object,
        kind = kind,
        stacks = readParam(struct, params.stacks) == true,
        stacksPercent = readParam(struct, params.stacksPercent) == true,
        objectOverride = readParam(struct, params.objectOverride) == true,
        iconSwapped = readParam(struct, params.iconSwapped) == true,
        duration = type(durationTicks) == "number" and durationTicks > 0 and gameClock.TicksToSeconds(durationTicks) or nil,
        ability = abilityCatalogue.Key(details.abilityID, details.skill),
    }
    buffVars.Resolve(entry)
    return entry
end

--- Whether a buff has any var to be read from (active-buffs reads it if so).
---@type fun(entry: BuffEntry): boolean
buffBuilder.HasVars = buffVars.HasAny

--- Whether a buff has an icon (a sprite or an item). Only buffs with one can
--- show in the game's buff bar, so only those may be listed as sources.
---@param entry BuffEntry
---@return boolean
function buffBuilder.HasIcon(entry)
    return entry.icon ~= nil or entry.object ~= nil
end

--- Whether a buff or debuff is listed as a source of its kind: it has an
--- icon and vars, and is the player's. A boss's own buffs (Rasial's Death
--- Spark, Nakatra's Devourer's Corruption) aren't. A debuff that belongs to
--- an ability (Dismember, Blood Tendrils) is the effect it puts on the
--- target, timed from the player's use, so only debuffs on the player are
--- listed; special attacks' cooldown debuffs are listed as special attacks
--- instead.
---@param entry BuffEntry
---@return boolean
function buffBuilder.IsListed(entry)
    if not buffBuilder.HasIcon(entry) or not buffVars.HasAny(entry) then return false end
    if entry.structName:sub(1, #BOSS_BUFF_PREFIX) == BOSS_BUFF_PREFIX then return false end
    if entry.kind == "buff" then return true end
    return entry.ability == nil and not specialAttackCatalogue.IsCooldownDebuff(entry.structName)
end

--- Gives a greater ability's buff its base buff's vars. Its struct is named
--- after nothing its var is (Greater Sunshine is
--- COMBATV2_ABILITY_MAGIC_SOLAR_CHARGE), but it's the same ability, with the
--- same COMBATV2_ABILITY_ID and skill, and uses the base's var. So a buff
--- without a timer takes another buff's of the same ability, and notes that
--- buff's struct as its baseStruct (so the data sources can show whichever
--- version the player has unlocked).
---@param list BuffEntry[] Changed in place.
local function shareAbilityVars(list)
    local byAbility = {}
    for _, entry in ipairs(list) do
        if entry.ability ~= nil and buffVars.IsTimed(entry) and byAbility[entry.ability] == nil then
            byAbility[entry.ability] = entry
        end
    end
    for _, entry in ipairs(list) do
        local base = not buffVars.IsTimed(entry) and entry.ability ~= nil and byAbility[entry.ability] or nil
        if base ~= nil then
            entry.endVar, entry.startVar = base.endVar, base.startVar
            entry.duration = entry.duration or base.duration
            entry.requiredVar = entry.requiredVar or base.requiredVar
            entry.baseStruct = base.structName
        end
    end
end

--- Each ability with a greater version, by key (see abilityCatalogue.Key),
--- to its icons: the bar shows whichever version was cast.
---@return table<string, integer[]>
local function greaterAbilityIcons()
    local iconsByKey = {}
    for _, ability in ipairs(abilityCatalogue.List()) do
        local greater = ability.greater
        if ability.key ~= nil and greater ~= nil then
            local icons = {}
            -- An ability's icon is its greater one while that's unlocked.
            for _, icon in ipairs({ ability.baseIcon or ability.icon or false, greater.icon or false }) do
                if icon then icons[#icons + 1] = icon end
            end
            if #icons > 0 then iconsByKey[ability.key] = icons end
        end
    end
    return iconsByKey
end

--- Whether a buff is active only while the game's buff bar shows its icon
--- (see BuffEntry.endsOffBuffBar): the default for the player's timed and
--- stacking buffs, as many are spent or lost (Chaos Roar's next attack,
--- leaving the Fight Kiln or Kharid-et) with no var saying so. Left out:
--- debuffs, as only the buff bar is read (the debuff bar also tidies away
--- cooldowns, such as Crackling's, that are still running); toggled buffs,
--- whose var is exact; buffs that come once the player stops attacking,
--- which have their own rule; and buffs the bar can show with an icon other
--- than their own (an item or a sprite the game picks), which would read as
--- off while they run. buff-data's BAR overrides it either way.
---@param entry BuffEntry
---@return boolean
local function endsOffBuffBar(entry)
    local bar = buffData.BAR[entry.structName]
    if bar ~= nil then return bar == "decides" end
    if entry.kind ~= "buff" or entry.quietTicks ~= nil or entry.objectOverride or entry.iconSwapped then return false end
    return entry.endVar ~= nil or entry.startVar ~= nil or entry.stacksVar ~= nil
end

--- Whether a buff's struct is a _DUMMY copy.
---@param entry BuffEntry
---@return boolean
local function isDummy(entry)
    return entry.structName:find("_DUMMY", 1, true) ~= nil
end

--- Which duplicate to keep: one with an icon, then not a _DUMMY copy, then
--- one linked to an ability (so it can show the greater version's icon).
---@param candidate BuffEntry
---@param current BuffEntry The one kept so far.
---@return boolean better Whether `candidate` is better than `current`.
local function isBetterDuplicate(candidate, current)
    local candidateHasIcon = buffBuilder.HasIcon(candidate)
    if candidateHasIcon ~= buffBuilder.HasIcon(current) then return candidateHasIcon end
    if isDummy(candidate) ~= isDummy(current) then return isDummy(current) end
    return candidate.ability ~= nil and current.ability == nil
end

--- What makes two buffs duplicates: the same name, vars and requirement.
---@param entry BuffEntry
---@return string? key nil without vars: before the vars can be read none have any, so they aren't compared.
local function duplicateKey(entry)
    if not buffVars.HasAny(entry) then return nil end
    return table.concat({ entry.name, tostring(entry.endVar), tostring(entry.startVar), tostring(entry.stacksVar),
        tostring(entry.activeVar), tostring(entry.quietTicks), tostring(entry.requiredVar) }, "|")
end

--- Lists one of each set of duplicates: some buffs have duplicate structs
--- with the same name that read the same vars (Deflect Magic and
--- COMBATV2_CURSE_DEFLECT_MAGIC_DUMMY, or Berserk's buff and ability
--- structs). The others' ids are kept on it (`duplicateIDs`), so auras saved
--- with them carry on.
---@param list BuffEntry[]
---@return BuffEntry[] kept A new list.
local function dropDuplicates(list)
    -- Duplicates grouped by key, in the order first seen; a buff without
    -- vars is a group of its own.
    local groups, order = {}, {}
    for _, entry in ipairs(list) do
        entry.duplicateIDs = nil
        local key = duplicateKey(entry) or entry
        if groups[key] == nil then
            groups[key] = {}
            order[#order + 1] = groups[key]
        end
        table.insert(groups[key], entry)
    end
    local kept = {}
    for _, group in ipairs(order) do
        local best = group[1]
        for index = 2, #group do
            if isBetterDuplicate(group[index], best) then best = group[index] end
        end
        for _, entry in ipairs(group) do
            if entry ~= best then
                best.duplicateIDs = best.duplicateIDs or {}
                best.duplicateIDs[#best.duplicateIDs + 1] = entry.id
            end
        end
        kept[#kept + 1] = best
    end
    return kept
end

--- What a buff's name must be unique among: the listed buffs or debuffs
--- (see IsListed), as each kind has its own picker.
---@param entry BuffEntry
---@return string? key nil for one that isn't listed, so it clashes with nothing.
local function clashKey(entry)
    if not buffBuilder.IsListed(entry) then return nil end
    return entry.kind .. "|" .. entry.name
end

--- Finishes a list of buffs read with Read: versions of an ability share
--- vars, each buff learns how the buff bar shows it (endsOffBuffBar,
--- barIcons), duplicates are dropped, and names that clash get the struct's
--- own name added, so the picker can tell them apart (Feasting Spores is two
--- buffs and a debuff: the buffs get it, the debuff doesn't). Safe to run
--- again, on a longer list, as more buffs are read.
---@param list BuffEntry[] Its entries are changed in place.
---@return BuffEntry[] finished A new list, sorted by label.
function buffBuilder.Finish(list)
    shareAbilityVars(list)
    local greaterIcons = greaterAbilityIcons()
    for _, entry in ipairs(list) do
        entry.endsOffBuffBar = endsOffBuffBar(entry)
        entry.barIcons = entry.ability and greaterIcons[entry.ability] or nil
    end
    list = dropDuplicates(list)
    local counts = {}
    for _, entry in ipairs(list) do
        local key = clashKey(entry)
        if key ~= nil then counts[key] = (counts[key] or 0) + 1 end
    end
    for _, entry in ipairs(list) do
        local key = clashKey(entry)
        local clashes = key ~= nil and counts[key] > 1
        entry.label = clashes and (entry.name .. " (" .. buffNaming.FromStruct(entry.structName) .. ")") or entry.name
    end
    table.sort(list, function(first, second) return first.label:lower() < second.label:lower() end)
    return list
end

return buffBuilder
