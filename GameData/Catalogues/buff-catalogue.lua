-- Lists buffs from game config. Every buff and debuff the game's buff bars
-- can show is a struct with a COMBATV2_BUFF_TYPE param (0 buff, 1 debuff,
-- 2 a neutral "stat modified" marker), named by COMBATV2_ABILITY_NAME and
-- drawn with COMBATV2_ABILITY_ICON (a sprite) or COMBATV2_ABILITY_OBJECT (an
-- item). Many are ability structs, which carry the buff params too.
-- Nothing indexes these structs, so finding them means walking every struct
-- id. The ids found are saved (PersistentDB key buffStructIDs), so later loads
-- list buffs straight away from them, and the walk only runs in the
-- background, slowly and once per session, to catch game updates.
-- Usage:
--   local buffCatalogue = require("GameData/Catalogues/buff-catalogue")
--   buffCatalogue.List()             --> { { id, structID, label, icon, object, kind, stacks, duration,
--                                            endVar, stacksVar, inAreaVar, baseStruct }, ... }
-- inAreaVar, for the few buffs that come from standing in an area, names the
-- VarPlayer varbit that's 1 while the player is in it (see IN_AREA_VARS).
-- endVar names the VarClient holding the buff's end time (in client Logic
-- ticks) and stacksVar the VarPlayer holding its stacks, found by name (see
-- endVarName below); GameData/Trackers/buff-vars reads them. Buffs with
-- neither can't be tracked, so the data sources leave them out.
--   buffCatalogue.Scan(onChanged)    -- walk the structs; onChanged() if the list changed
--   buffCatalogue.Stop()

local gameApi = require("GameData/game-api")
local abilityCatalogue = require("GameData/Catalogues/ability-catalogue")
local gameClock = require("GameData/Trackers/game-clock")

local buffCatalogue = {}

local CACHE_KEY = "buffStructIDs"
local EVENT_ID = "runeAuras_buffCatalogue"
local LOAD_EVENT_ID = "runeAuras_buffCatalogueLoad"
-- Saved buffs built per Logic tick when loading: about 300 lookups, a few
-- milliseconds, so the ~600 take about a second and a half.
local LOAD_PER_TICK = 8
-- Structs checked per Logic tick, and how many missing ids in a row mark
-- the end of the struct ids. Buffs are already listed from the saved ids,
-- so the walk can take its time: kept small so no frame does much of it.
-- (There's no clock to budget by time.)
local PER_TICK = 200
local MISS_LIMIT = 5000
local MAX_LABEL = 32

local KINDS = { [0] = "buff", [1] = "debuff", [2] = "buff" }

local params = nil
local entries = {}
local cachedIDs = nil

local function lookupParams()
    if params ~= nil then return params end
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
    -- Only used to share a var between versions of an ability (see
    -- shareAbilityVars), so buffs still list without them.
    found.abilityID = gameApi.Param("COMBATV2_ABILITY_ID")
    found.skill = gameApi.Param("COMBATV2_ABILITY_PARENT_STAT")
    -- Channelled abilities are listed as channels instead (see
    -- GameData/Trackers/channel), so they're left out of the buffs.
    found.channelled = gameApi.Param("COMBATV2_ABILITY_IS_CHANNELLED")
    params = found
    return params
end

-- A struct id's name, or nil past the last struct id (the walk runs on
-- until a long run of these) or if it can't be read.
local function nameOf(structID)
    local name = gameApi.StructName(structID)
    if type(name) ~= "string" or name == "" then return nil end
    return name
end

-- A param's value, or nil if the struct doesn't set it (GetParamValue alone
-- would give the param's default, e.g. 0 for COMBATV2_BUFF_TYPE) or it
-- can't be read.
local function readParam(struct, param)
    if not gameApi.HasParam(struct, param) then return nil end
    return gameApi.ParamValue(struct, param)
end

-- The struct name without its prefixes and suffixes, the part its vars
-- share: "INVENT_PERK_RELENTLESS_COOLDOWN_DUMMY_ABILITY" ->
-- "INVENT_PERK_RELENTLESS".
local CORE_PREFIXES = { "COMBATV2_", "ABILITY_", "BUFF_", "DEBUFF_" }
local CORE_SUFFIXES = { "_DUMMY_ABILITY", "_DUMMY_EFFECT", "_DUMMY", "_ABILITY", "_COOLDOWN", "_EFFECT", "_STRUCT" }

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

-- Nothing in config links a buff to its vars, so they're found by name.
-- End times are VarClients ending _END_EFFECT_CLIENT or _END_CLIENT, under
-- the struct's own name or its core with a COMBATV2_BUFF_, COMBATV2_DEBUFF_,
-- COMBATV2_ or no prefix. An ability's effect is
-- COMBATV2_COOLDOWN_<core>_END_EFFECT_CLIENT; COMBATV2_COOLDOWN_<core>_END_CLIENT
-- is its cooldown, so that's never used. Names that don't follow those
-- rules are listed below. Stacks are VarPlayers ending _STACKS, which only
-- a few buffs have.

-- Struct name -> its end-time VarClient, where the names differ.
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

-- { Lua pattern on the struct name, replacement } for whole families.
local END_VAR_PATTERNS = {
    -- Incense sticks: COMBATV2_INCENSE_<HERB>_DUMMY.
    { "^COMBATV2_INCENSE_(.+)_DUMMY$", "COMBATV2_INCENSE_BURNER_%1_END_CLIENT" },
}

local function endVarName(structName, core)
    local alias = END_VAR_ALIASES[structName]
    if alias ~= nil and gameApi.VarClient(alias) ~= nil then return alias end
    for _, rule in ipairs(END_VAR_PATTERNS) do
        local name, matched = structName:gsub(rule[1], rule[2])
        if matched > 0 and gameApi.VarClient(name) ~= nil then return name end
    end
    local candidates = { structName .. "_END_EFFECT_CLIENT", structName .. "_END_CLIENT" }
    for _, prefix in ipairs({ "COMBATV2_BUFF_", "COMBATV2_DEBUFF_", "COMBATV2_", "" }) do
        candidates[#candidates + 1] = prefix .. core .. "_END_EFFECT_CLIENT"
        candidates[#candidates + 1] = prefix .. core .. "_END_CLIENT"
    end
    candidates[#candidates + 1] = "COMBATV2_COOLDOWN_" .. core .. "_END_EFFECT_CLIENT"
    for _, candidate in ipairs(candidates) do
        if gameApi.VarClient(candidate) ~= nil then return candidate end
    end
    return nil
end

-- Buffs that come from standing in an ability's area: the end time is the
-- area's, but leaving it loses the buff, so these varbits (1 while the
-- player is in the area) must be set too. Found by logging every var change
-- while stepping in and out of Sunshine: TSD_SUNSHINE_DAMAGE (varp 3537,
-- 0x400) flipped with each step and cleared when the patch ended. Greater
-- versions use their base's (see shareAbilityVars).
-- (Death's Swiftness has a TSD_ varbit too, but it's no longer a ground
-- effect, so it doesn't need one.)
local IN_AREA_VARS = {
    COMBATV2_ABILITY_MAGIC_SUNSHINE = "TSD_SUNSHINE_DAMAGE",
}

local function inAreaVarName(structName)
    local name = IN_AREA_VARS[structName]
    if name ~= nil and gameApi.VarExists(name) then return name end
    return nil
end

-- Buffs with no timer are toggled on and off (prayers, curses, Bone
-- Shield, Flow), and have a VarPlayer that's non-zero while they're on:
-- one ending _ACTIVE, or one named after the struct itself, with or without
-- COMBATV2_ (prayers are varbits named COMBATV2_PRAYER_<name>, curses
-- CURSE_<name>). Names that don't follow those rules are listed below,
-- under the struct name or COMBATV2_ plus its core (so a _DUMMY copy finds
-- them too).
-- The tiered prayers (Thick/Rock/Steel Skin, the strength, eye and mystic
-- tiers, Charge, Hand of and Decay) are left out: each set shares one
-- COMBATV2_PRAYER_BOOST_* varbit that can't tell its tiers apart.
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

local function activeVarName(structName, core)
    local alias = ACTIVE_VARS[structName] or ACTIVE_VARS["COMBATV2_" .. core]
    if alias ~= nil and gameApi.VarExists(alias) then return alias end
    -- An _ACTIVE flag first: a same-named var can be a level or count
    -- (INVENT_PERK_WISE) where INVENT_PERK_WISE_ACTIVE is the flag.
    local candidates = { structName .. "_ACTIVE", "COMBATV2_" .. core .. "_ACTIVE", core .. "_ACTIVE" }
    -- Flow's struct is COMBATV2_BUFF_MAGIC_FLOW_STACKS, its flag _FLOW_ACTIVE.
    if structName:sub(-7) == "_STACKS" then candidates[#candidates + 1] = structName:sub(1, -8) .. "_ACTIVE" end
    candidates[#candidates + 1] = structName
    candidates[#candidates + 1] = "COMBATV2_" .. core
    candidates[#candidates + 1] = core
    for _, candidate in ipairs(candidates) do
        if gameApi.VarExists(candidate) then return candidate end
    end
    return nil
end

-- Some abilities' buffs (Unsullied) have no end time of their own: they last
-- COMBATV2_ABILITY_EFFECT_DURATION from the cast, which is the ability's
-- COMBATV2_COOLDOWN_<core>_START (the server tick it was used; its _END is
-- when the cooldown ends, not the effect). Only buffs with a duration can be
-- timed this way.
local function startVarName(core)
    local name = "COMBATV2_COOLDOWN_" .. core .. "_START"
    if gameApi.VarExists(name) then return name end
    return nil
end

-- Struct name -> its stacks VarPlayer, where the names differ.
local STACKS_VAR_ALIASES = {
    COMBATV2_BUFF_ANIMATE_DEAD = "COMBATV2_MAGIC_ANIMATE_DEAD_STACKS",
}

local function stacksVarName(structName, core)
    local alias = STACKS_VAR_ALIASES[structName]
    if alias ~= nil and gameApi.VarExists(alias) then return alias end
    -- A struct already ending _STACKS can be its own stacks var (Essence
    -- Corruption).
    for _, candidate in ipairs({ structName .. "_STACKS", "COMBATV2_BUFF_" .. core .. "_STACKS",
        "COMBATV2_" .. core .. "_STACKS", core .. "_STACKS", structName:sub(-7) == "_STACKS" and structName or nil }) do
        if gameApi.VarExists(candidate) then return candidate end
    end
    return nil
end

-- "COMBATV2_BUFF_NECROMANCY_DEATH_ESSENCE" -> "Necromancy death essence".
local function nameFromStruct(structName)
    local name = structName
    for _, prefix in ipairs({ "COMBATV2_", "ABILITY_", "BUFF_" }) do
        if name:sub(1, #prefix) == prefix then name = name:sub(#prefix + 1) end
    end
    name = name:gsub("_DUMMY_ABILITY$", ""):gsub("_DUMMY$", ""):gsub("_", " "):lower()
    return (name:gsub("^%l", string.upper))
end

-- The tooltip name, which is sometimes "Name - what it does" or a whole
-- sentence; those fall back to the struct's own name.
local function cleanLabel(raw, structName)
    local label = tostring(raw or ""):gsub("<[^>]*>", ""):gsub("^%s+", ""):gsub("%s+$", "")
    local short = label:match("^(.-)%s+%-%s+")
    if short ~= nil and short ~= "" then label = short end
    -- "Guam Incense:" loses its colon.
    label = label:gsub("%s*:$", "")
    local function usable(text) return text ~= "" and #text <= MAX_LABEL and text:sub(-1) ~= "." end
    if usable(label) then return label end
    -- "Icy Chill: At 10 stacks ..." is a name then a sentence, so it's cut
    -- there; "Legendary Pet Ability: High Level Alchemy" isn't, as the part
    -- after the colon is what tells the pets apart.
    local rest
    short, rest = label:match("^(.-):%s+(.*)$")
    if short ~= nil and usable(short) and not usable(rest) then return short end
    return nameFromStruct(structName)
end

-- COMBATV2_ABILITY_OBJECT is an ObjType config (or an id).
local function objectID(value)
    if type(value) == "number" then return value end
    return value ~= nil and gameApi.ID(value) or nil
end

-- The entry for one struct id, or nil if it isn't a buff.
-- Looks up every var a buff is read from. Toggles and start-timed buffs
-- are only looked for without an end time, which is read first.
local function resolveVars(entry)
    local structName = entry.structName
    local core = nameCore(structName)
    entry.endVar = endVarName(structName, core)
    entry.stacksVar = entry.stacks and stacksVarName(structName, core) or nil
    entry.inAreaVar = inAreaVarName(structName)
    local untimed = entry.endVar == nil
    entry.startVar = untimed and entry.duration ~= nil and startVarName(core) or nil
    entry.activeVar = untimed and activeVarName(structName, core) or nil
end

local function readEntry(structID)
    local p = lookupParams()
    if p == nil then return nil end
    local struct = gameApi.StructByID(structID)
    if struct == nil then return nil end
    local buffType = readParam(struct, p.type)
    local kind = buffType ~= nil and KINDS[buffType] or nil
    if kind == nil then return nil end
    if p.channelled ~= nil and readParam(struct, p.channelled) == 1 then return nil end
    local structName = tostring(gameApi.ConfigName(struct) or structID)
    local icon = readParam(struct, p.icon)
    local duration = readParam(struct, p.duration)
    local abilityID = p.abilityID and readParam(struct, p.abilityID)
    local skill = p.skill and readParam(struct, p.skill)
    local entry = {
        id = "buff_" .. structName:lower(),
        structID = structID,
        structName = structName,
        -- The tooltip name; `label` adds the struct's name when two clash.
        name = cleanLabel(readParam(struct, p.name), structName),
        icon = (type(icon) == "number" and icon >= 0) and icon or nil,
        object = objectID(readParam(struct, p.object)),
        kind = kind,
        stacks = readParam(struct, p.stacks) == true,
        -- Seconds (the param is in server ticks), for buffs from abilities
        -- (Death's Swiftness: 30); nil for most others.
        duration = (type(duration) == "number" and duration > 0)
            and duration * gameClock.SECONDS_PER_SERVER_TICK or nil,
        -- The ability it belongs to, if any.
        ability = abilityCatalogue.Key(abilityID, skill),
    }
    resolveVars(entry)
    return entry
end

-- A greater ability's buff has a struct of its own, named after nothing its
-- var is (Greater Sunshine is COMBATV2_ABILITY_MAGIC_SOLAR_CHARGE), but it's
-- the same ability as the base, with the same COMBATV2_ABILITY_ID and skill,
-- and uses the base's var. So a buff without a var of its own takes the var
-- of another buff of the same ability, and notes that buff's struct as its
-- baseStruct (so the data sources can show whichever version the player
-- has unlocked).
local function shareAbilityVars(list)
    local byAbility = {}
    for _, entry in ipairs(list) do
        local timed = entry.endVar ~= nil or entry.startVar ~= nil
        if entry.ability ~= nil and timed and byAbility[entry.ability] == nil then
            byAbility[entry.ability] = entry
        end
    end
    for _, entry in ipairs(list) do
        local untimed = entry.endVar == nil and entry.startVar == nil
        local base = untimed and entry.ability ~= nil and byAbility[entry.ability] or nil
        if base ~= nil then
            entry.endVar, entry.startVar = base.endVar, base.startVar
            entry.duration = entry.duration or base.duration
            entry.inAreaVar = entry.inAreaVar or base.inAreaVar
            entry.baseStruct = base.structName
        end
    end
end

-- Whether a buff has any var to be read from (GameData/Trackers/buff-vars
-- reads it if so).
function buffCatalogue.HasVars(entry)
    return entry.endVar ~= nil or entry.startVar ~= nil or entry.stacksVar ~= nil or entry.activeVar ~= nil
end

-- Which twin of a pair to keep: not a _DUMMY copy, then one linked to an
-- ability (so it can show the greater version's icon).
local function better(a, b)
    local aDummy, bDummy = a.structName:find("_DUMMY", 1, true) ~= nil, b.structName:find("_DUMMY", 1, true) ~= nil
    if aDummy ~= bDummy then return bDummy end
    if (a.ability ~= nil) ~= (b.ability ~= nil) then return a.ability ~= nil end
    return false
end

-- Some buffs have twin structs with the same name that read the same vars
-- (Deflect Magic and COMBATV2_CURSE_DEFLECT_MAGIC_DUMMY, or Berserk's buff
-- and ability structs), so only one is listed. The others' ids are kept on
-- it (`twinIDs`), so auras saved with them carry on. Buffs without vars
-- aren't compared: before the vars can be read, none have any.
-- What makes two buffs twins: the same name and vars. nil without vars.
local function twinKey(entry)
    if not buffCatalogue.HasVars(entry) then return nil end
    return table.concat({ entry.name, tostring(entry.endVar), tostring(entry.startVar),
        tostring(entry.stacksVar), tostring(entry.activeVar), tostring(entry.inAreaVar) }, "|")
end

local function dropTwins(list)
    -- Twins grouped by key, in the order first seen; a buff without vars is
    -- a group of its own.
    local groups, order = {}, {}
    for _, entry in ipairs(list) do
        entry.twinIDs = nil
        local key = twinKey(entry) or entry
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
            if better(group[index], best) then best = group[index] end
        end
        if #group > 1 then
            best.twinIDs = {}
            for _, entry in ipairs(group) do
                if entry ~= best then best.twinIDs[#best.twinIDs + 1] = entry.id end
            end
        end
        kept[#kept + 1] = best
    end
    return kept
end

-- Shares vars between an ability's buffs, drops twins, and gives names that
-- clash the struct's own name, so the picker can tell them apart. Safe to
-- run again once vars are found.
local function finish(list)
    shareAbilityVars(list)
    list = dropTwins(list)
    local counts = {}
    for _, entry in ipairs(list) do counts[entry.name] = (counts[entry.name] or 0) + 1 end
    for _, entry in ipairs(list) do
        entry.label = entry.name
        if counts[entry.name] > 1 then
            entry.label = entry.name .. " (" .. nameFromStruct(entry.structName) .. ")"
        end
    end
    table.sort(list, function(a, b) return a.label:lower() < b.label:lower() end)
    return list
end

local function idString(list)
    local ids = {}
    for _, entry in ipairs(list) do ids[#ids + 1] = entry.structID end
    table.sort(ids)
    for index, value in ipairs(ids) do ids[index] = tostring(value) end
    return table.concat(ids, ",")
end

local loading = false

-- Builds the list from the saved struct ids. Each buff takes dozens of
-- guarded lookups (its params, and the var names its rules try), so all
-- ~600 at once stalled a frame for about half a second. So the buffs in
-- `wanted` (source ids auras use, "buff_<struct name>") are built at once,
-- after one quick pass over the saved ids' names, and listed through
-- onReady(true), so those auras show straight away; the rest follow in the
-- background, a few each Logic tick, and onDone(changed) runs when it's
-- all built (or there was nothing to build). Call it in game, where vars
-- can be read. A load cut short by Stop starts over next time.
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
            if wanted["buff_" .. name:lower()] then
                local entry = readEntry(structID)
                if entry ~= nil then list[#list + 1] = entry end
            else
                rest[#rest + 1] = structID
            end
        end
    end
    if #list > 0 then
        -- A copy: finish drops twins from the list it's given.
        local first = {}
        for index, entry in ipairs(list) do first[index] = entry end
        entries = finish(first)
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
            local entry = readEntry(structID)
            if entry ~= nil then list[#list + 1] = entry end
        end
    end)
end

local scanning = false
-- Whether a walk has finished this session. Game config doesn't change while
-- the client runs, so world hops and lobby returns don't walk again.
local scanned = false

-- Walks every struct id in the background, once per session (a walk cut
-- short by Stop starts over next time). When it's done and the buffs differ
-- from the current list, the list is replaced, saved, and onChanged() is
-- called.
function buffCatalogue.Scan(onChanged)
    if scanned or scanning or lookupParams() == nil then return end
    scanning = true
    local found, nextID, misses = {}, 0, 0
    Event.Logic.Subscribe(EVENT_ID, function()
        for _ = 1, PER_TICK do
            local structID = nextID
            nextID = nextID + 1
            if nameOf(structID) ~= nil then
                misses = 0
                local entry = readEntry(structID)
                if entry ~= nil then found[#found + 1] = entry end
            else
                misses = misses + 1
                if misses >= MISS_LIMIT then
                    Event.Logic.Unsubscribe(EVENT_ID)
                    scanning = false
                    scanned = true
                    local ids = idString(found)
                    if ids ~= idString(entries) then
                        entries = finish(found)
                        cachedIDs = ids
                        PersistentDB:SetString(CACHE_KEY, ids)
                        if onChanged ~= nil then onChanged() end
                    end
                    return
                end
            end
        end
    end)
end

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

function buffCatalogue.List()
    return entries
end

return buffCatalogue
