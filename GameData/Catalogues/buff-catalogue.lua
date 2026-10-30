-- Buffs, listed from game config, with the vars each is read from. Owns the
-- BuffEntry record, finding the buff structs (a background walk of every
-- struct id, saved so later loads list them straight away), and the naming
-- rules that find a buff's vars. Reading the vars is active-buffs' job.

local gameApi = require("GameData/game-api")
local abilityCatalogue = require("GameData/Catalogues/ability-catalogue")
local gameClock = require("GameData/Trackers/game-clock")

local buffCatalogue = {}

--- A buff or debuff the game's buff bars can show: a struct with a
--- COMBATV2_BUFF_TYPE param. Many are ability structs, which carry the buff
--- params too.
---@class BuffEntry
---@field id string Source id, "buff_<struct name>".
---@field structID integer
---@field structName string
---@field name string The tooltip name, cleaned (see cleanLabel).
---@field label string `name`, plus the struct's name when two clash, so the picker can tell them apart.
---@field icon integer? Sprite id (COMBATV2_ABILITY_ICON).
---@field object integer? An item whose icon it shows instead (COMBATV2_ABILITY_OBJECT).
---@field kind "buff"|"debuff"
---@field stacks boolean Whether it uses stacks.
---@field duration number? Seconds, for buffs from abilities (Death's Swiftness: 30).
---@field ability string? The ability it belongs to (see abilityCatalogue.Key).
---@field endVar string? VarClient holding the Logic tick it ends on.
---@field stacksVar string? VarPlayer holding its stacks.
---@field inAreaVar string? VarPlayer varbit that's 1 while in its area (see IN_AREA_VARS).
---@field startVar string? Its ability's _START VarPlayer, for a buff timed from the cast (see startVarName).
---@field activeVar string? VarPlayer that's on while a toggled buff is (see activeVarName).
---@field baseStruct string? For a greater ability's buff, its base buff's struct (see shareAbilityVars).
---@field duplicateIDs string[]? Ids of duplicates dropped in its favour (see dropDuplicates).

local CACHE_KEY = "buffStructIDs"
local EVENT_ID = "runeAuras_buffCatalogue"
local LOAD_EVENT_ID = "runeAuras_buffCatalogueLoad"
-- Saved buffs built per Logic tick when loading: about 300 lookups, a few
-- milliseconds, so the ~600 take about a second and a half.
local LOAD_PER_TICK = 8
-- Structs checked per Logic tick, about 4 lookups each for one that isn't a
-- buff: small, as buffs are already listed from the saved ids, and the walk
-- reuses those (see buildEntry). (There's no clock to budget by time.)
local SCAN_PER_TICK = 150
-- Buffs the walk reads from config per Logic tick (new ones, after a game
-- update): dozens of lookups each, so a batch ends early after this many,
-- as a run of them would otherwise stall the tick.
local SCAN_READS_PER_TICK = LOAD_PER_TICK
-- A tooltip name longer than this is a sentence, not a name.
local MAX_LABEL = 32
local SOURCE_ID_PREFIX = "buff_"
local STACKS_SUFFIX = "_STACKS"
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
---@field abilityID userdata? Only used to share a var between versions of an ability (see shareAbilityVars), so buffs still list without it.
---@field skill userdata?
---@field channelled userdata? Channelled abilities are listed as channels instead (see the channel tracker), so they're left out.
---@field priority userdata? Marks the few buffs without a type (see buffKind).

---@type BuffParams? nil until every required param has been found.
local buffParams = nil
---@type BuffEntry[]
local entries = {}
---@type table<integer, BuffEntry> Struct id to every buff built this session, duplicates included (see buildEntry).
local builtByID = {}
-- The saved struct ids, as a comma list.
local cachedIDs = nil

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
    buffParams = found
    return buffParams
end

--- A struct id's name.
---@param structID integer
---@return string? name nil if the struct is gone (after a game update) or can't be read.
local function nameOf(structID)
    local name = gameApi.StructName(structID)
    if type(name) ~= "string" or name == "" then return nil end
    return name
end

--- A struct's value for a param it sets.
---@param struct userdata
---@param param userdata
---@return any value nil if the struct doesn't set it (GetParamValue alone would give the param's default, e.g. 0 for COMBATV2_BUFF_TYPE) or it can't be read.
local function readParam(struct, param)
    if not gameApi.HasParam(struct, param) then return nil end
    return gameApi.ParamValue(struct, param)
end

local CORE_PREFIXES = { "COMBATV2_", "ABILITY_", "BUFF_", "DEBUFF_" }
local CORE_SUFFIXES = { "_DUMMY_ABILITY", "_DUMMY_EFFECT", "_DUMMY", "_ABILITY", "_COOLDOWN", "_EFFECT", "_STRUCT" }

--- A struct name without its prefixes and suffixes: the part its vars share.
--- "INVENT_PERK_RELENTLESS_COOLDOWN_DUMMY_ABILITY" gives "INVENT_PERK_RELENTLESS".
---@param name string
---@return string core
local function nameCore(name)
    local changed = true
    while changed do
        changed = false
        for _, prefix in ipairs(CORE_PREFIXES) do
            if name:sub(1, #prefix) == prefix then name = name:sub(#prefix + 1); changed = true end
        end
        for _, suffix in ipairs(CORE_SUFFIXES) do
            if #name > #suffix and name:sub(-#suffix) == suffix then name = name:sub(1, -#suffix - 1); changed = true end
        end
    end
    return name
end

-- Struct name to its end-time VarClient, where the names don't follow the
-- rules (see endVarName).
local END_VAR_ALIASES = {
    -- "Renew" in the struct, "Renewal" in the var.
    COMBATV2_PRAYER_RENEW_DUMMY_ABILITY = "COMBATV2_COOLDOWN_PRAYER_RENEWAL_END_EFFECT_CLIENT",
    -- "Resurgence" in the struct (the ability is Rejuvenate), misspelt in the var.
    COMBATV2_ABILITY_DEFENCE_RESURGENCE = "COMBATV2_COOLDOWN_DEFENCE_REJUVINATE_END_EFFECT_CLIENT",
    COMBATV2_ANTI_DRAGONFIRE_DUMMY_ABILITY = "COMBATV2_COOLDOWN_DRAGONFIRE_END_EFFECT_CLIENT",
    COMBATV2_SUPER_ANTI_DRAGONFIRE_DUMMY_ABILITY = "COMBATV2_COOLDOWN_SUPER_DRAGONFIRE_END_EFFECT_CLIENT",
    COMBATV2_HARVEST_POTION_TIMER = "HERB120_HARVEST_POTION_END_EFFECT_CLIENT",
    COMBATV2_CHARMING_POTION_DUMMY_ABILITY = "HERB120_CHARMING_POTION_END_EFFECT_CLIENT",
    COMBATV2_ARCH_KHARIDET_PYLON_EFFECT_DUMMY_ABILITY = "COMBATV2_ARCH_KHARIDET_PYLON_EFFECT_END_CLIENT",
    MAGIC_SEREN_CRYSTAL_MASK = "COMBATV2_COOLDOWN_SEREN_CRYSTAL_MASK_END_EFFECT_CLIENT",
    COMBATV2_MTX_XP_BOMB_DUMMY_DXP_ABILITY = "COMBATV2_MTX_XP_BOMB_END_EFFECT_CLIENT",
    COMBATV2_MTX_EVENT16_BOOST_JUICE_DURATION_DUMMY_ABILITY = "COMBATV2_EVENT16_BOOST_JUICE_DURATION_END_EFFECT_CLIENT",
    COMBATV2_TRH_PROTEAN_POWERUP_DUMMY_EFFECT = "COMBATV2_COOLDOWN_PROTEAN_POWERUP_END_EFFECT_CLIENT",
    COMBATV2_PORTSARIM_CONCH_DUMMY_ABILITY = "COMBATV2_COOLDOWN_CONCH_END_EFFECT_CLIENT",
    COMBATV2_ELR1_SPIRIT_DRAGON_CHARM_DUMMY_ABILITY = "COMBATV2_COOLDOWN_ELR1_SPIRIT_CHARM_END_EFFECT_CLIENT",
    -- Treasure Hunter items, whose vars carry their promotion's number.
    COMBATV2_TRH44_VALENTINES15_LOVE_POTION_DUMMY_ABILITY = "COMBATV2_COOLDOWN_TRH44_VALENTINES_LOVE_POTION_END_EFFECT_CLIENT",
    COMBATV2_TRH44_VALENTINES15_LOVE_POTION_OTHER_DUMMY_ABILITY = "COMBATV2_COOLDOWN_TRH44_VALENTINES_LOVE_POTION_OTHER_END_EFFECT_CLIENT",
    COMBATV2_PULSE_ESSENCE_DUMMY_ABILITY = "COMBATV2_COOLDOWN_TRH50_PULSE_ESSENCE_END_EFFECT_CLIENT",
    COMBATV2_LUCKY_CLOVER_DUMMY_ABILITY = "COMBATV2_COOLDOWN_TRH78_LUCKY_CLOVER_END_EFFECT_CLIENT",
    COMBATV2_VALENTINES_STAFF_DUMMY_ABILITY = "COMBATV2_COOLDOWN_TRH82_VALENTINES_STAFF_END_EFFECT_CLIENT",
    COMBATV2_SKILLING_BACKPACK_DUMMY_ABILITY = "COMBATV2_COOLDOWN_TRH94_SKILLING_BACKPACK_END_EFFECT_CLIENT",
    TRH_SWEET_REGENERATE_DUMMY_ABILITY = "TRH22_SWEEET_REGENERATE_END_CLIENT",
    TRH_SWEET_SHIELD_DUMMY_ABILITY = "TRH22_SWEEET_SHIELD_END_CLIENT",
    TRH_SWEET_DAMAGE_DUMMY_ABILITY = "TRH22_SWEEET_DAMAGE_END_CLIENT",
    -- The stronger tiers share the base potion's var (confirmed in game).
    COMBATV2_SUPREME_OVERLOAD_DUMMY_ABILITY = "COMBATV2_COOLDOWN_OVERLOAD_END_EFFECT_CLIENT",
    COMBATV2_ELDER_OVERLOAD_DUMMY_ABILITY = "COMBATV2_COOLDOWN_OVERLOAD_END_EFFECT_CLIENT",
    COMBATV2_SUPER_PRAYERRENEW_DUMMY_ABILITY = "COMBATV2_COOLDOWN_PRAYER_RENEWAL_END_EFFECT_CLIENT",
    -- A spell, so its vars are under MAGIC_ rather than BUFF_.
    COMBATV2_BUFF_ANIMATE_DEAD = "COMBATV2_MAGIC_ANIMATE_DEAD_END_EFFECT_CLIENT",
    -- Same words as their var, in another order or wording, found offline
    -- by matching name words (Berserk's struct says STRENGTH, its var MELEE).
    COMBATV2_ABILITY_STRENGTH_BERSERK = "COMBATV2_BUFF_MELEE_BERSERK_END_CLIENT",
    COMBATV2_DINARROW_WEN_CHILL_DUMMY_ABILITY = "COMBATV2_DINARROW_WEN_BUFF_CHILL_END_CLIENT",
    COMBATV2_DINARROW_WEN_PRECISION_DUMMY_ABILITY = "COMBATV2_DINARROW_WEN_BUFF_PRECISION_END_CLIENT",
    COMBATV2_LUNAR_TUNE_BANE_ORE = "COMBATV2_LUNAR_TUNE_BANE_ORE_BUFF_END_CLIENT",
    COMBATV2_ARCH_ORTHEN_REX_EFFECT_DUMMY_ABILITY = "COMBATV2_ARCH_ORTHEN_REX_EFFECT_END_CLIENT",
    COMBATV2_EGWD_BIK_GOD_BOOK_EFFECT_BUFF = "COMBATV2_EGWD_BIK_GOD_BOOK_EFFECT_END_CLIENT",
    COMBATV2_BUFF_DRAGON_BATTLEAXE = "COMBATV2_BUFF_DRAGON_BATTLEAXE_EFFECT_END_CLIENT",
    COMBATV2_BUFF_DRAGON_SCIMITAR = "COMBATV2_BUFF_DRAGON_SCIMITAR_EFFECT_END_CLIENT",
}

-- A Lua pattern on the struct name and its replacement, for whole families.
local END_VAR_PATTERNS = {
    -- Incense sticks: COMBATV2_INCENSE_<HERB>_DUMMY.
    { pattern = "^COMBATV2_INCENSE_(.+)_DUMMY$", replacement = "COMBATV2_INCENSE_BURNER_%1_END_CLIENT" },
}

--- A buff's end-time VarClient. Nothing in config links a buff to its vars,
--- so they're found by name: END_VAR_ALIASES and END_VAR_PATTERNS first,
--- then _END_EFFECT_CLIENT or _END_CLIENT under the struct's own name or its
--- core with a COMBATV2_BUFF_, COMBATV2_DEBUFF_, COMBATV2_ or no prefix, then
--- an ability's effect, COMBATV2_COOLDOWN_<core>_END_EFFECT_CLIENT.
--- (COMBATV2_COOLDOWN_<core>_END_CLIENT is the ability's cooldown, so it's
--- never used.)
---@param structName string
---@param core string Its nameCore.
---@return string? varName nil if there's none.
local function endVarName(structName, core)
    local alias = END_VAR_ALIASES[structName]
    if alias ~= nil and gameApi.VarClient(alias) ~= nil then return alias end
    for _, rule in ipairs(END_VAR_PATTERNS) do
        local varName, matched = structName:gsub(rule.pattern, rule.replacement)
        if matched > 0 and gameApi.VarClient(varName) ~= nil then return varName end
    end
    local candidates = { structName .. "_END_EFFECT_CLIENT", structName .. "_END_CLIENT" }
    for _, prefix in ipairs({ "COMBATV2_BUFF_", "COMBATV2_DEBUFF_", "COMBATV2_", "" }) do
        candidates[#candidates + 1] = prefix .. core .. "_END_EFFECT_CLIENT"
        candidates[#candidates + 1] = prefix .. core .. "_END_CLIENT"
    end
    candidates[#candidates + 1] = abilityCatalogue.COOLDOWN_VAR_PREFIX .. core .. "_END_EFFECT_CLIENT"
    for _, candidate in ipairs(candidates) do
        if gameApi.VarClient(candidate) ~= nil then return candidate end
    end
    return nil
end

-- Buffs that come from standing in an ability's area: the end time belongs
-- to the area, but leaving it loses the buff, so these varbits (1 while the
-- player is in the area) must be set too. Found by logging every var change
-- while stepping in and out of Sunshine: TSD_SUNSHINE_DAMAGE (varp 3537,
-- 0x400) flipped with each step and cleared when the patch ended. Greater
-- versions use their base's (see shareAbilityVars). (Death's Swiftness has
-- a TSD_ varbit too, but it's no longer a ground effect.)
local IN_AREA_VARS = {
    COMBATV2_ABILITY_MAGIC_SUNSHINE = "TSD_SUNSHINE_DAMAGE",
}

--- An area buff's in-area varbit.
---@param structName string
---@return string? varName nil for a buff without an area.
local function inAreaVarName(structName)
    local varName = IN_AREA_VARS[structName]
    if varName ~= nil and gameApi.VarExists(varName) then return varName end
    return nil
end

-- Struct name (or COMBATV2_ plus its core, so a _DUMMY copy finds them too)
-- to its toggle VarPlayer, where the names don't follow the rules (see
-- activeVarName). The tiered prayers (Thick/Rock/Steel Skin, the strength,
-- eye and mystic tiers, Charge, Hand of and Decay) are left out: each set
-- shares one COMBATV2_PRAYER_BOOST_* varbit that can't tell its tiers apart.
local ACTIVE_VARS = {
    -- Found by logging var changes while toggling: 0 while off, its
    -- ability's id (1 for Lesser) while on. (_ABILITY_STRUCT follows it
    -- too, but reads as a struct, never as a number.)
    COMBATV2_BUFF_NECROMANCY_BONE_SHIELD = "COMBATV2_BUFF_NECROMANCY_BONE_SHIELD_ABILITY_ID",
    COMBATV2_PRAYER_PROTECT_MAGIC = "COMBATV2_PRAYER_PROTECT_MAGE",
    COMBATV2_PRAYER_PROTECT_MISSILES = "COMBATV2_PRAYER_PROTECT_RANGE",
    COMBATV2_PRAYER_SUMMONING = "COMBATV2_PRAYER_PROTECT_SUMMONING",
    COMBATV2_PRAYER_RAPID_HEAL = "COMBATV2_PRAYER_HEAL",
    COMBATV2_CURSE_SAP_STRENGTH = "CURSE_SAP_MELEE_STR",
    COMBATV2_CURSE_SAP_RANGE_STRENGTH = "CURSE_SAP_RANGE_STR",
    COMBATV2_CURSE_SAP_MAGIC_STRENGTH = "CURSE_SAP_MAGIC_STR",
    COMBATV2_CURSE_DEFLECT_MISSILES = "CURSE_DEFLECT_RANGED",
    COMBATV2_CURSE_LEECH_RANGE_STRENGTH = "CURSE_LEECH_RANGED_STRENGTH",
    -- The target's id while it's debilitated, -1 once it isn't (logged
    -- while casting it).
    COMBATV2_ABILITY_DEFENCE_DEBILITATE = "COMBATV2_DEBILITATE_NPC_UID",
}

--- A toggled buff's VarPlayer (prayers, curses, Bone Shield, Flow: no
--- timer, switched on and off): non-zero while on. It's ACTIVE_VARS, then
--- one ending _ACTIVE, then one named after the struct itself, with or
--- without COMBATV2_ (prayers are varbits COMBATV2_PRAYER_<name>, curses
--- CURSE_<name>).
---@param structName string
---@param core string Its nameCore.
---@return string? varName nil if there's none.
local function activeVarName(structName, core)
    local alias = ACTIVE_VARS[structName] or ACTIVE_VARS["COMBATV2_" .. core]
    if alias ~= nil and gameApi.VarExists(alias) then return alias end
    -- An _ACTIVE flag first: a same-named var can be a level or count
    -- (INVENT_PERK_WISE) where INVENT_PERK_WISE_ACTIVE is the flag.
    local candidates = { structName .. "_ACTIVE", "COMBATV2_" .. core .. "_ACTIVE", core .. "_ACTIVE" }
    -- Flow's struct is COMBATV2_BUFF_MAGIC_FLOW_STACKS, its flag _FLOW_ACTIVE.
    if structName:sub(-#STACKS_SUFFIX) == STACKS_SUFFIX then
        candidates[#candidates + 1] = structName:sub(1, -#STACKS_SUFFIX - 1) .. "_ACTIVE"
    end
    candidates[#candidates + 1] = structName
    candidates[#candidates + 1] = "COMBATV2_" .. core
    candidates[#candidates + 1] = core
    for _, candidate in ipairs(candidates) do
        if gameApi.VarExists(candidate) then return candidate end
    end
    return nil
end

--- The _START var a buff with no end time of its own is timed from
--- (Unsullied): it lasts COMBATV2_ABILITY_EFFECT_DURATION from the cast,
--- which is the ability's COMBATV2_COOLDOWN_<core>_START (the server tick it
--- was used; its _END is when the cooldown ends, not the effect).
---@param core string The buff's nameCore.
---@return string? varName nil if the ability has none.
local function startVarName(core)
    local varName = abilityCatalogue.COOLDOWN_VAR_PREFIX .. core .. "_START"
    if gameApi.VarExists(varName) then return varName end
    return nil
end

-- Struct name to its stacks VarPlayer, where the names differ.
local STACKS_VAR_ALIASES = {
    COMBATV2_BUFF_ANIMATE_DEAD = "COMBATV2_MAGIC_ANIMATE_DEAD_STACKS",
}

--- A stacking buff's stacks VarPlayer: one ending _STACKS, which only a few
--- buffs have.
---@param structName string
---@param core string Its nameCore.
---@return string? varName nil if there's none.
local function stacksVarName(structName, core)
    local alias = STACKS_VAR_ALIASES[structName]
    if alias ~= nil and gameApi.VarExists(alias) then return alias end
    -- A struct already ending _STACKS can be its own stacks var (Essence
    -- Corruption).
    local isOwnStacksVar = structName:sub(-#STACKS_SUFFIX) == STACKS_SUFFIX
    for _, candidate in ipairs({ structName .. STACKS_SUFFIX, "COMBATV2_BUFF_" .. core .. STACKS_SUFFIX,
        "COMBATV2_" .. core .. STACKS_SUFFIX, core .. STACKS_SUFFIX, isOwnStacksVar and structName or nil }) do
        if gameApi.VarExists(candidate) then return candidate end
    end
    return nil
end

--- A readable name made from a struct's name.
--- "COMBATV2_BUFF_NECROMANCY_DEATH_ESSENCE" gives "Necromancy death essence".
---@param structName string
---@return string
local function nameFromStruct(structName)
    local name = structName
    for _, prefix in ipairs({ "COMBATV2_", "ABILITY_", "BUFF_" }) do
        if name:sub(1, #prefix) == prefix then name = name:sub(#prefix + 1) end
    end
    name = name:gsub("_DUMMY_ABILITY$", ""):gsub("_DUMMY$", ""):gsub("_", " "):lower()
    return (name:gsub("^%l", string.upper))
end

--- Whether text works as a buff's name: short, and not a sentence.
---@param text string
---@return boolean
local function usableLabel(text)
    return text ~= "" and #text <= MAX_LABEL and text:sub(-1) ~= "."
end

--- A buff's name from its tooltip name, which is sometimes "Name - what it
--- does" or a whole sentence; those fall back to the struct's own name.
---@param raw any The COMBATV2_ABILITY_NAME param.
---@param structName string
---@return string
local function cleanLabel(raw, structName)
    local label = tostring(raw or ""):gsub("<[^>]*>", ""):gsub("^%s+", ""):gsub("%s+$", "")
    local beforeDash = label:match("^(.-)%s+%-%s+")
    if beforeDash ~= nil and beforeDash ~= "" then label = beforeDash end
    -- "Guam Incense:" loses its colon.
    label = label:gsub("%s*:$", "")
    if usableLabel(label) then return label end
    -- "Icy Chill: At 10 stacks ..." is a name then a sentence, so it's cut
    -- there; "Legendary Pet Ability: High Level Alchemy" isn't, as the part
    -- after the colon is what tells the pets apart.
    local beforeColon, afterColon = label:match("^(.-):%s+(.*)$")
    if beforeColon ~= nil and usableLabel(beforeColon) and not usableLabel(afterColon) then return beforeColon end
    return nameFromStruct(structName)
end

--- An item id from COMBATV2_ABILITY_OBJECT, which is an ObjType config (or
--- an id).
---@param value any
---@return integer?
local function objectID(value)
    if type(value) == "number" then return value end
    return value ~= nil and gameApi.ID(value) or nil
end

--- Finds every var a buff is read from. Toggles and start-timed buffs are
--- only looked for without an end time, which is looked for first.
---@param entry BuffEntry Changed in place.
local function resolveVars(entry)
    local structName = entry.structName
    local core = nameCore(structName)
    entry.endVar = endVarName(structName, core)
    entry.stacksVar = entry.stacks and stacksVarName(structName, core) or nil
    entry.inAreaVar = inAreaVarName(structName)
    local untimed = entry.endVar == nil
    -- Only buffs with a duration can be timed from their ability's use.
    entry.startVar = untimed and entry.duration ~= nil and startVarName(core) or nil
    entry.activeVar = untimed and activeVarName(structName, core) or nil
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

--- A struct as a buff, with its vars.
---@param structID integer
---@return BuffEntry? entry nil if it isn't a buff (or is a channelled ability's buff), or can't be read.
local function readEntry(structID)
    local params = lookupParams()
    if params == nil then return nil end
    local struct = gameApi.StructByID(structID)
    if struct == nil then return nil end
    local kind = buffKind(struct, params)
    if kind == nil then return nil end
    if params.channelled ~= nil and readParam(struct, params.channelled) == IS_CHANNELLED then return nil end
    local structName = tostring(gameApi.ConfigName(struct) or structID)
    local details = buffDetails(struct, structName, params)
    local icon, durationTicks = details.icon, details.durationTicks
    local hasDuration = type(durationTicks) == "number" and durationTicks > 0
    local entry = {
        id = buffCatalogue.SourceID(structName),
        structID = structID,
        structName = structName,
        name = cleanLabel(details.name, structName),
        icon = (type(icon) == "number" and icon >= 0) and icon or nil,
        object = objectID(details.object),
        kind = kind,
        stacks = readParam(struct, params.stacks) == true,
        duration = hasDuration and gameClock.TicksToSeconds(durationTicks) or nil,
        ability = abilityCatalogue.Key(details.abilityID, details.skill),
    }
    resolveVars(entry)
    return entry
end

--- A struct as a buff, read once a session: game config doesn't change
--- while the client runs, so the walk reuses what Load built. Later
--- `finish` calls change the entry in place, which is safe to repeat.
---@param structID integer
---@return BuffEntry? entry nil if it isn't a buff.
---@return boolean isFresh Whether it was read from config just now.
local function buildEntry(structID)
    local built = builtByID[structID]
    if built ~= nil then return built, false end
    local entry = readEntry(structID)
    builtByID[structID] = entry
    return entry, true
end

--- Whether a buff has a timer: an end time or a start to time from.
---@param entry BuffEntry
---@return boolean
local function isTimed(entry)
    return entry.endVar ~= nil or entry.startVar ~= nil
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
        if entry.ability ~= nil and isTimed(entry) and byAbility[entry.ability] == nil then
            byAbility[entry.ability] = entry
        end
    end
    for _, entry in ipairs(list) do
        local base = not isTimed(entry) and entry.ability ~= nil and byAbility[entry.ability] or nil
        if base ~= nil then
            entry.endVar, entry.startVar = base.endVar, base.startVar
            entry.duration = entry.duration or base.duration
            entry.inAreaVar = entry.inAreaVar or base.inAreaVar
            entry.baseStruct = base.structName
        end
    end
end

--- A buff source's id, from its struct name.
---@param structName string
---@return string
function buffCatalogue.SourceID(structName)
    return SOURCE_ID_PREFIX .. structName:lower()
end

--- Whether a source id is a buff source's id, listed or not.
---@param sourceID any
---@return boolean
function buffCatalogue.IsSourceID(sourceID)
    return type(sourceID) == "string" and sourceID:sub(1, #SOURCE_ID_PREFIX) == SOURCE_ID_PREFIX
end

--- Whether a buff has any var to be read from (active-buffs reads it if so).
--- Buffs with none can't be tracked, so the data sources leave them out.
---@param entry BuffEntry
---@return boolean
function buffCatalogue.HasVars(entry)
    return entry.endVar ~= nil or entry.startVar ~= nil or entry.stacksVar ~= nil or entry.activeVar ~= nil
end

--- Whether a buff's struct is a _DUMMY copy.
---@param entry BuffEntry
---@return boolean
local function isDummy(entry)
    return entry.structName:find("_DUMMY", 1, true) ~= nil
end

--- Which duplicate to keep: not a _DUMMY copy, then one linked to an
--- ability (so it can show the greater version's icon).
---@param candidate BuffEntry
---@param current BuffEntry The one kept so far.
---@return boolean better Whether `candidate` is better than `current`.
local function isBetterDuplicate(candidate, current)
    if isDummy(candidate) ~= isDummy(current) then return isDummy(current) end
    local candidateHasAbility, currentHasAbility = candidate.ability ~= nil, current.ability ~= nil
    if candidateHasAbility ~= currentHasAbility then return candidateHasAbility end
    return false
end

--- What makes two buffs duplicates: the same name and vars.
---@param entry BuffEntry
---@return string? key nil without vars: before the vars can be read none have any, so they aren't compared.
local function duplicateKey(entry)
    if not buffCatalogue.HasVars(entry) then return nil end
    return table.concat({ entry.name, tostring(entry.endVar), tostring(entry.startVar),
        tostring(entry.stacksVar), tostring(entry.activeVar), tostring(entry.inAreaVar) }, "|")
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
        local group = groups[key]
        if group == nil then
            group = {}
            groups[key] = group
            order[#order + 1] = group
        end
        group[#group + 1] = entry
    end
    local kept = {}
    for _, group in ipairs(order) do
        local best = group[1]
        for index = 2, #group do
            if isBetterDuplicate(group[index], best) then best = group[index] end
        end
        if #group > 1 then
            best.duplicateIDs = {}
            for _, entry in ipairs(group) do
                if entry ~= best then best.duplicateIDs[#best.duplicateIDs + 1] = entry.id end
            end
        end
        kept[#kept + 1] = best
    end
    return kept
end

--- Shares vars between an ability's buffs, drops duplicates, and gives names
--- that clash the struct's own name, so the picker can tell them apart.
--- Safe to run again once vars are found.
---@param list BuffEntry[]
---@return BuffEntry[] finished A new list, sorted by label.
local function finish(list)
    shareAbilityVars(list)
    list = dropDuplicates(list)
    local counts = {}
    for _, entry in ipairs(list) do counts[entry.name] = (counts[entry.name] or 0) + 1 end
    for _, entry in ipairs(list) do
        entry.label = entry.name
        if counts[entry.name] > 1 then
            entry.label = entry.name .. " (" .. nameFromStruct(entry.structName) .. ")"
        end
    end
    table.sort(list, function(first, second) return first.label:lower() < second.label:lower() end)
    return list
end

--- A list's struct ids as a sorted comma list, for saving and comparing.
---@param list BuffEntry[]
---@return string
local function idString(list)
    local ids = {}
    for _, entry in ipairs(list) do ids[#ids + 1] = entry.structID end
    table.sort(ids)
    for index, value in ipairs(ids) do ids[index] = tostring(value) end
    return table.concat(ids, ",")
end

local loading = false

--- Builds the list from the saved struct ids. Each buff takes dozens of
--- guarded lookups (its params, and the var names its rules try), so all
--- ~600 at once stalled a frame for about half a second. So the buffs auras
--- use are built at once, after one quick pass over the saved ids' names,
--- so those auras show straight away; the rest follow in the background,
--- LOAD_PER_TICK each Logic tick. Call it in game, where vars can be read.
--- A load cut short by Stop starts over next time.
---@param wanted table<string, boolean> Source ids auras use ("buff_<struct name>").
---@param onReady fun(changed: boolean) Called once the wanted buffs are listed, if any were.
---@param onDone fun(changed: boolean) Called when it's all built, or there was nothing to build.
function buffCatalogue.Load(wanted, onReady, onDone)
    if loading then return end
    if #entries > 0 or lookupParams() == nil then
        onDone(false)
        return
    end
    cachedIDs = cachedIDs or PersistentDB:GetString(CACHE_KEY) or ""
    -- The saved ids still there (one may be gone after a game update) and
    -- their names; the wanted ones are built now.
    local rest, list = {}, {}
    for value in string.gmatch(cachedIDs, "%d+") do
        local structID = tonumber(value)
        local name = nameOf(structID)
        if name ~= nil then
            if wanted[buffCatalogue.SourceID(name)] then
                local entry = buildEntry(structID)
                if entry ~= nil then list[#list + 1] = entry end
            else
                rest[#rest + 1] = structID
            end
        end
    end
    if #list > 0 then
        -- A copy: finish drops duplicates from the list it's given.
        local wantedEntries = {}
        for index, entry in ipairs(list) do wantedEntries[index] = entry end
        entries = finish(wantedEntries)
        onReady(true)
    end
    local nextIndex = 1
    loading = true
    Event.Logic.Subscribe(LOAD_EVENT_ID, function()
        for _ = 1, LOAD_PER_TICK do
            local structID = rest[nextIndex]
            if structID == nil then
                Event.Logic.Unsubscribe(LOAD_EVENT_ID)
                loading = false
                if #list > 0 then entries = finish(list) end
                onDone(#list > 0)
                return
            end
            nextIndex = nextIndex + 1
            local entry = buildEntry(structID)
            if entry ~= nil then list[#list + 1] = entry end
        end
    end)
end

local scanning = false
-- Whether a walk has finished this session. Game config doesn't change while
-- the client runs, so world hops and lobby returns don't walk again.
local scanned = false

--- Ends a finished walk: replaces, saves and reports the list if the buffs
--- found differ from it.
---@param found BuffEntry[]
---@param onChanged fun()?
local function finishScan(found, onChanged)
    Event.Logic.Unsubscribe(EVENT_ID)
    scanning = false
    scanned = true
    local ids = idString(found)
    -- Against the saved ids, not the list: the list has had its duplicates
    -- dropped.
    if ids == cachedIDs then return end
    entries = finish(found)
    cachedIDs = ids
    PersistentDB:SetString(CACHE_KEY, ids)
    if onChanged ~= nil then onChanged() end
end

--- Gives up a failed walk, keeping the current list; the next Scan retries.
local function abandonScan()
    Event.Logic.Unsubscribe(EVENT_ID)
    scanning = false
end

--- Walks every struct in the background, once per session (a walk cut
--- short by Stop starts over next time), to catch game updates. When it's
--- done and the buffs differ from the current list, the list is replaced
--- and saved.
---@param onChanged fun()? Called if the list changed.
function buffCatalogue.Scan(onChanged)
    if scanned or scanning or lookupParams() == nil then return end
    local walk = gameApi.StructWalk()
    if walk == nil then return end
    scanning = true
    local found = {}
    Event.Logic.Subscribe(EVENT_ID, function()
        local reads = 0
        for _ = 1, SCAN_PER_TICK do
            local structID, _, ok = gameApi.NextStruct(walk)
            if not ok then
                abandonScan()
                return
            end
            if structID == nil then
                finishScan(found, onChanged)
                return
            end
            local entry, isFresh = buildEntry(structID)
            if entry ~= nil then
                found[#found + 1] = entry
                if isFresh then reads = reads + 1 end
                if reads >= SCAN_READS_PER_TICK then return end
            end
        end
    end)
end

--- Stops a walk or load in progress.
function buffCatalogue.Stop()
    if scanning then
        Event.Logic.Unsubscribe(EVENT_ID)
        scanning = false
    end
    if loading then
        Event.Logic.Unsubscribe(LOAD_EVENT_ID)
        loading = false
    end
end

--- Forgets the saved struct ids, so the next session loads no buffs up
--- front and its walk finds and saves them all again. The list this session
--- is kept.
function buffCatalogue.ClearSaved()
    cachedIDs = ""
    PersistentDB:SetString(CACHE_KEY, "")
end

--- Every buff listed so far, sorted by label.
---@return BuffEntry[]
function buffCatalogue.List()
    return entries
end

return buffCatalogue
