-- Reading a struct as a buff: the BuffEntry record, its name, icon, kind and
-- details from the struct's params, and whether it's listed as a source.
-- Finding its vars is buff-vars' job.

local gameApi = require("GameData/game-api")
local abilityCatalogue = require("GameData/Catalogues/ability-catalogue")
local gameClock = require("GameData/Trackers/game-clock")
local specialAttackCatalogue = require("GameData/Catalogues/special-attack-catalogue")
local buffVars = require("GameData/Catalogues/Buffs/buff-vars")
local retiredBuffs = require("GameData/Catalogues/Buffs/retired-buffs")
local buffNames = require("GameData/Catalogues/Buffs/buff-names")

local buffEntries = {}

--- A buff or debuff the game's buff bars can show: a struct with a
--- COMBATV2_BUFF_TYPE param. Many are ability structs, which carry the buff
--- params too.
---@class BuffEntry
---@field id string Source id, "buff_<struct name>".
---@field structID integer
---@field structName string Without control characters (see cleanStructName).
---@field name string The tooltip name, cleaned (see cleanLabel).
---@field label string `name`, plus the struct's name when two clash, so the picker can tell them apart.
---@field icon integer? Sprite id (COMBATV2_ABILITY_ICON).
---@field object integer? An item whose icon it shows instead (COMBATV2_ABILITY_OBJECT).
---@field kind "buff"|"debuff"
---@field stacks boolean Whether it uses stacks.
---@field stacksPercent boolean Whether the game shows its stacks as a percentage (COMBATV2_BUFF_USES_STACKS_PERCENT).
---@field stacksAtFull integer? For such a buff, its stacks var's value at 100%; nil when the var holds the percentage itself (see buff-vars' STACKS_AT_FULL).
---@field duration number? Seconds, for buffs from abilities (Death's Swiftness: 30).
---@field ability string? The ability it belongs to (see abilityCatalogue.Key).
---@field endVar string? VarClient holding the Logic tick it ends on.
---@field stacksVar string? VarPlayer holding its stacks.
---@field stacksWhileUntimed boolean? Active while it has stacks and its timer isn't running, its value then the stacks (see buff-vars' STACKS_WHILE_UNTIMED).
---@field requirements BuffRequirement[]? What must also hold for it to count as active, any one of them (see buff-vars' ACTIVE_WHILE).
---@field endsOffBuffBar boolean Whether it also ends once the game's buff bar drops its icon, or for a toggled buff follows the bar both ways (see buff-vars' ENDS_OFF_BUFF_BAR).
---@field iconGroup BuffIconGroup? For such a buff, the others showing the same icon there (see buff-vars' SHARED_ICON_GROUPS).
---@field timeLeftVar string? For a buff that pauses while switched off, the VarPlayer holding its time left in server ticks: it's running only while that agrees with its end time (see buff-vars' TIME_LEFT_VARS).
---@field quietTicks integer? For a buff that comes once the player stops attacking, the server ticks it takes (see buff-vars' AFTER_NOT_ATTACKING).
---@field startVar string? Its ability's _START VarPlayer, for a buff timed from the cast (see buff-vars' startVarName).
---@field activeVar string? VarPlayer that's on while a toggled buff is (see buff-vars' activeVarName).
---@field objectOverride boolean Whether its icon is an item the game picks while it runs (COMBATV2_BUFF_OBJ_OVERRIDE: the quiver's ammo).
---@field objectVar string? For such a buff, the OBJ VarPlayer holding that item: its active var.
---@field baseStruct string? For a greater ability's buff, its base buff's struct (see buff-list's shareAbilityVars).
---@field duplicateIDs string[]? Ids of duplicates dropped in its favour (see buff-list's dropDuplicates).

-- A tooltip name longer than this is a sentence, not a name.
local MAX_LABEL = 34
-- How the struct names of buffs a boss gains itself start.
local BOSS_BUFF_PREFIX = "COMBATV2_BOSS_BUFF_"
local SOURCE_ID_PREFIX = "buff_"
-- The channelled param's value for a channelled ability.
local IS_CHANNELLED = 1

-- COMBATV2_BUFF_TYPE values: 0 buff, 1 debuff, 2 a neutral "stat modified"
-- marker (listed as a buff).
local KINDS = { [0] = "buff", [1] = "debuff", [2] = "buff" }

--- The param configs a buff is read with.
---@class BuffParams
---@field type userdata
---@field name userdata
---@field icon userdata
---@field object userdata
---@field stacks userdata
---@field duration userdata
---@field abilityID userdata? Only used to share a var between versions of an ability (see buff-list's shareAbilityVars), so buffs still list without it.
---@field skill userdata?
---@field channelled userdata? Channelled abilities are listed as channels instead (see the channel tracker), so they're left out.
---@field priority userdata? Marks the few buffs without a type (see buffKind).
---@field objectOverride userdata? Marks buffs whose icon is an item picked while they run (see BuffEntry.objectOverride).
---@field stacksPercent userdata? Marks buffs whose stacks show as a percentage (see BuffEntry.stacksPercent).

---@type BuffParams? nil until every required param has been found.
local buffParams = nil

--- The param configs a buff is read with, looked up once.
---@return BuffParams? params nil while a required one can't be found (config may not be readable yet).
local function lookupParams()
    if buffParams ~= nil then return buffParams end
    local found = {}
    for key, name in pairs({
        type = "COMBATV2_BUFF_TYPE",
        name = "COMBATV2_ABILITY_NAME",
        icon = "COMBATV2_ABILITY_ICON",
        object = "COMBATV2_ABILITY_OBJECT",
        stacks = "COMBATV2_BUFF_USES_STACKS",
        duration = "COMBATV2_ABILITY_EFFECT_DURATION",
    }) do
        local param = gameApi.Param(name)
        if param == nil then return nil end
        found[key] = param
    end
    found.abilityID = gameApi.Param("COMBATV2_ABILITY_ID")
    found.skill = gameApi.Param("COMBATV2_ABILITY_PARENT_STAT")
    found.channelled = gameApi.Param("COMBATV2_ABILITY_IS_CHANNELLED")
    found.priority = gameApi.Param("COMBATV2_BUFF_PRIORITY")
    found.objectOverride = gameApi.Param("COMBATV2_BUFF_OBJ_OVERRIDE")
    found.stacksPercent = gameApi.Param("COMBATV2_BUFF_USES_STACKS_PERCENT")
    buffParams = found
    return buffParams
end

--- Whether buffs can be read yet: every param they need can be found, which
--- it can't before config is readable.
---@return boolean
function buffEntries.CanRead()
    return lookupParams() ~= nil
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
function buffEntries.StructName(structID)
    local name = gameApi.StructName(structID)
    if type(name) ~= "string" or name == "" then return nil end
    return cleanStructName(name)
end

--- A struct's value for a param it sets.
---@param struct userdata
---@param param userdata
---@return any value nil if the struct doesn't set it (GetParamValue alone would give the param's default, e.g. 0 for COMBATV2_BUFF_TYPE) or it can't be read.
local function readParam(struct, param)
    if not gameApi.HasParam(struct, param) then return nil end
    return gameApi.ParamValue(struct, param)
end

-- Words at the end of a struct's name that only say how the game keeps the
-- buff. "_COOLDOWN" isn't one: "Vengeance" alone would read as the buff.
local STRUCT_NAME_ENDINGS = { "_TRACKER", "_TIMER", "_ACTIVE", "_EFFECT", "_BUFF", "_DEBUFF" }

--- Drops STRUCT_NAME_ENDINGS from the end of a name, however many there are.
---@param name string
---@return string
local function withoutEndings(name)
    local changed = true
    while changed do
        changed = false
        for _, ending in ipairs(STRUCT_NAME_ENDINGS) do
            if #name > #ending and name:sub(-#ending) == ending then
                name = name:sub(1, -#ending - 1)
                changed = true
            end
        end
    end
    return name
end

--- A readable name made from a struct's name, without the words that only
--- name how the game keeps it ("COMBATV2_GOD_BOOK_TIMER_DUMMY_ABILITY" gives
--- "God book"). "COMBATV2_BUFF_NECROMANCY_DEATH_ESSENCE" gives
--- "Necromancy death essence".
---@param structName string
---@return string
function buffEntries.NameFromStruct(structName)
    local name = structName
    for _, prefix in ipairs({ "COMBATV2_", "ABILITY_", "BUFF_", "DEBUFF_" }) do
        if name:sub(1, #prefix) == prefix then name = name:sub(#prefix + 1) end
    end
    name = withoutEndings((name:gsub("_DUMMY_ABILITY", ""):gsub("_DUMMY", "")))
    name = name:gsub("_", " "):lower()
    return (name:gsub("^%l", string.upper))
end

--- Whether text works as a buff's name: short, and not a sentence.
---@param text string
---@return boolean
local function usableLabel(text)
    return text ~= "" and #text <= MAX_LABEL and text:sub(-1) ~= "."
end

--- A tooltip name up to its first line break ("Enlightenment<br>- Better
--- rewards ..." gives "Enlightenment"), or all of it when nothing comes before one.
---@param text string
---@return string
local function firstLine(text)
    local beforeBreak = text:match("^(.-)<br>")
    if beforeBreak == nil then return text end
    local hasText = beforeBreak:gsub("<[^>]*>", ""):find("%S") ~= nil
    if not hasText then return text end
    return beforeBreak
end

-- How a cooldown debuff's tooltip sentence names what's cooling down
-- ("Your Crackling perk will not activate while this is up.").
local COOLDOWN_SENTENCES = {
    "^Your (.-) will not activate",
    "^Your (.-) is on cooldown",
    "^Your (.-) is cooling down",
    "^Your (.-) has recently activated",
    "^(.-) is on cooldown%.?$",
}
-- Words after what's cooling down that only say what kind of thing it is.
local COOLDOWN_SUBJECT_ENDINGS = { "%s+perk$", "%s+effect$", "%s+ability$" }

--- A cooldown debuff's name from its tooltip sentence: what's cooling down
--- and "cooldown" ("Crackling cooldown").
---@param sentence string
---@return string? name nil if the sentence isn't one of COOLDOWN_SENTENCES, or the name would be too long.
local function cooldownName(sentence)
    for _, pattern in ipairs(COOLDOWN_SENTENCES) do
        local subject = sentence:match(pattern)
        if subject ~= nil then
            for _, ending in ipairs(COOLDOWN_SUBJECT_ENDINGS) do subject = subject:gsub(ending, "") end
            local name = subject:gsub("^%l", string.upper) .. " cooldown"
            if usableLabel(name) then return name end
            return nil
        end
    end
    return nil
end

--- A buff's name from its tooltip name, which is sometimes "Name - what it
--- does", a name then a description on the next line, "Name Active", or a
--- whole sentence; a cooldown's sentence names what's cooling down, and any
--- other sentence falls back to the struct's own name.
---@param raw any The COMBATV2_ABILITY_NAME param.
---@param structName string
---@return string
local function cleanLabel(raw, structName)
    local label = firstLine(tostring(raw or "")):gsub("<[^>]*>", ""):gsub("^%s+", ""):gsub("%s+$", "")
    local beforeDash = label:match("^(.-)%s+%-%s+")
    if beforeDash ~= nil and beforeDash ~= "" then label = beforeDash end
    -- "Guam Incense:" loses its colon, and "Locate Active." its last word.
    label = label:gsub("%s*:$", ""):gsub("%s+[Aa]ctive%.?$", "")
    if usableLabel(label) then return label end
    -- "Icy Chill: At 10 stacks ..." is a name then a sentence, so it's cut
    -- there; "Legendary Pet Ability: High Level Alchemy" isn't, as the part
    -- after the colon is what tells the pets apart.
    local beforeColon, afterColon = label:match("^(.-):%s+(.*)$")
    if beforeColon ~= nil and usableLabel(beforeColon) and not usableLabel(afterColon) then return beforeColon end
    return cooldownName(label) or buffEntries.NameFromStruct(structName)
end

-- Buffs with no name or icon of their own, to the ability struct whose they
-- show. The game links them only through a var that's empty while the buff
-- is off (<struct>_ABILITY_STRUCT), so they're listed here.
local DETAILS_FROM_ABILITY = {
    -- Living Death's Death form.
    COMBATV2_BUFF_NECROMANCY_UNDEAD_INSTINCT = "COMBATV2_ABILITY_NECROMANCY_LIVING_DEATH",
}

--- What a buff shows and which ability it belongs to, as its struct's params.
---@class BuffDetails
---@field name any
---@field icon any
---@field object any
---@field durationTicks any
---@field abilityID any
---@field skill any

--- A buff's kind.
---@param struct userdata
---@param params BuffParams
---@return "buff"|"debuff"|nil kind nil if it isn't a buff.
local function buffKind(struct, params)
    local buffType = readParam(struct, params.type)
    if buffType ~= nil then return KINDS[buffType] end
    -- A few buffs have no type, only the buff bar's other params (Undead Instinct).
    if params.priority ~= nil and gameApi.HasParam(struct, params.priority) then return "buff" end
    return nil
end

--- A struct's details, nil for each param it doesn't set.
---@param struct userdata
---@param params BuffParams
---@return BuffDetails
local function readDetails(struct, params)
    return {
        name = readParam(struct, params.name),
        icon = readParam(struct, params.icon),
        object = readParam(struct, params.object),
        durationTicks = readParam(struct, params.duration),
        abilityID = params.abilityID and readParam(struct, params.abilityID),
        skill = params.skill and readParam(struct, params.skill),
    }
end

--- A buff's details, with any it lacks taken from its ability (see DETAILS_FROM_ABILITY).
---@param struct userdata
---@param structName string
---@param params BuffParams
---@return BuffDetails
local function buffDetails(struct, structName, params)
    local details = readDetails(struct, params)
    local abilityName = DETAILS_FROM_ABILITY[structName]
    local ability = abilityName and gameApi.Struct(abilityName)
    if ability == nil then return details end
    for key, value in pairs(readDetails(ability, params)) do
        if details[key] == nil then details[key] = value end
    end
    return details
end

--- A buff source's id, from its struct name.
---@param structName string
---@return string
function buffEntries.SourceID(structName)
    return SOURCE_ID_PREFIX .. structName:lower()
end

--- Whether a source id is a buff source's id, listed or not.
---@param sourceID any
---@return boolean
function buffEntries.IsSourceID(sourceID)
    return type(sourceID) == "string" and sourceID:sub(1, #SOURCE_ID_PREFIX) == SOURCE_ID_PREFIX
end

--- A struct as a buff, with its vars.
---@param structID integer
---@return BuffEntry? entry nil if it isn't a buff (or is a channelled ability's or one the game no longer gives), or can't be read.
function buffEntries.Read(structID)
    local params = lookupParams()
    if params == nil then return nil end
    local struct = gameApi.StructByID(structID)
    if struct == nil then return nil end
    local kind = buffKind(struct, params)
    if kind == nil then return nil end
    if params.channelled ~= nil and readParam(struct, params.channelled) == IS_CHANNELLED then return nil end
    local structName = cleanStructName(tostring(gameApi.ConfigName(struct) or structID))
    local details = buffDetails(struct, structName, params)
    local object = gameApi.ItemID(details.object)
    if retiredBuffs.IsRetired(structName, object) then return nil end
    local icon, durationTicks = details.icon, details.durationTicks
    local hasDuration = type(durationTicks) == "number" and durationTicks > 0
    local entry = {
        id = buffEntries.SourceID(structName),
        structID = structID,
        structName = structName,
        name = buffNames.For(structName) or cleanLabel(details.name, structName),
        icon = (type(icon) == "number" and icon >= 0) and icon or nil,
        object = object,
        kind = kind,
        stacks = readParam(struct, params.stacks) == true,
        stacksPercent = params.stacksPercent ~= nil and readParam(struct, params.stacksPercent) == true,
        objectOverride = params.objectOverride ~= nil and readParam(struct, params.objectOverride) == true,
        duration = hasDuration and gameClock.TicksToSeconds(durationTicks) or nil,
        ability = abilityCatalogue.Key(details.abilityID, details.skill),
    }
    buffVars.Resolve(entry)
    return entry
end

--- Whether a buff has an icon (a sprite or an item). Only buffs with one can
--- show in the game's buff bar, so only those may be listed as sources.
---@param entry BuffEntry
---@return boolean
function buffEntries.HasIcon(entry)
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
function buffEntries.IsListed(entry)
    if not buffEntries.HasIcon(entry) or not buffVars.HasAny(entry) then return false end
    local isBossOwn = entry.structName:sub(1, #BOSS_BUFF_PREFIX) == BOSS_BUFF_PREFIX
    if isBossOwn then return false end
    if entry.kind == "buff" then return true end
    return entry.ability == nil and not specialAttackCatalogue.IsCooldownDebuff(entry.structName)
end

return buffEntries
