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

local buffCatalogue = {}

local CACHE_KEY = "buffStructIDs"
local EVENT_ID = "runeAuras_buffCatalogue"
-- Structs checked per Logic tick, and how many missing ids in a row mark
-- the end of the struct ids. Buffs are already listed from the saved ids,
-- so the walk can take its time: kept small so no frame does much of it.
-- (There's no clock to budget by time.)
local PER_TICK = 200
local MISS_LIMIT = 5000
local MAX_LABEL = 32

local KINDS = { [0] = "buff", [1] = "debuff", [2] = "buff" }
-- COMBATV2_ABILITY_EFFECT_DURATION is in server ticks.
local SECONDS_PER_TICK = 0.6

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

local function stacksVarName(structName, core)
    for _, candidate in ipairs({ structName .. "_STACKS", "COMBATV2_BUFF_" .. core .. "_STACKS",
        "COMBATV2_" .. core .. "_STACKS", core .. "_STACKS" }) do
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
    if label == "" or #label > MAX_LABEL or label:sub(-1) == "." then
        return nameFromStruct(structName)
    end
    return label
end

-- COMBATV2_ABILITY_OBJECT is an ObjType config (or an id).
local function objectID(value)
    if type(value) == "number" then return value end
    return value ~= nil and gameApi.ID(value) or nil
end

-- The entry for one struct id, or nil if it isn't a buff.
local function readEntry(structID)
    local p = lookupParams()
    if p == nil then return nil end
    local struct = gameApi.StructByID(structID)
    if struct == nil then return nil end
    local buffType = readParam(struct, p.type)
    local kind = buffType ~= nil and KINDS[buffType] or nil
    if kind == nil then return nil end
    local structName = tostring(gameApi.ConfigName(struct) or structID)
    local icon = readParam(struct, p.icon)
    local duration = readParam(struct, p.duration)
    local stacks = readParam(struct, p.stacks) == true
    local core = nameCore(structName)
    local abilityID = p.abilityID and readParam(struct, p.abilityID)
    local skill = p.skill and readParam(struct, p.skill)
    return {
        id = "buff_" .. structName:lower(),
        structID = structID,
        structName = structName,
        label = cleanLabel(readParam(struct, p.name), structName),
        icon = (type(icon) == "number" and icon >= 0) and icon or nil,
        object = objectID(readParam(struct, p.object)),
        kind = kind,
        stacks = stacks,
        -- Seconds, for buffs from abilities (Death's Swiftness: 30); nil
        -- for most others.
        duration = (type(duration) == "number" and duration > 0) and duration * SECONDS_PER_TICK or nil,
        endVar = endVarName(structName, core),
        -- The ability it belongs to, if any: COMBATV2_ABILITY_ID is only
        -- unique within a skill, so it's paired with the skill.
        ability = (abilityID ~= nil and skill ~= nil) and (tostring(abilityID) .. ":" .. tostring(skill)) or nil,
        stacksVar = stacks and stacksVarName(structName, core) or nil,
        inAreaVar = inAreaVarName(structName),
    }
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
        if entry.ability ~= nil and entry.endVar ~= nil and byAbility[entry.ability] == nil then
            byAbility[entry.ability] = entry
        end
    end
    for _, entry in ipairs(list) do
        local base = entry.endVar == nil and entry.ability ~= nil and byAbility[entry.ability] or nil
        if base ~= nil then
            entry.endVar = base.endVar
            entry.inAreaVar = entry.inAreaVar or base.inAreaVar
            entry.baseStruct = base.structName
        end
    end
end

-- Labels that clash get the struct's own name added, so the picker can
-- tell them apart.
local function finish(list)
    shareAbilityVars(list)
    local counts = {}
    for _, entry in ipairs(list) do counts[entry.label] = (counts[entry.label] or 0) + 1 end
    for _, entry in ipairs(list) do
        if counts[entry.label] > 1 then
            entry.label = entry.label .. " (" .. nameFromStruct(entry.structName) .. ")"
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

-- Looks the buffs' vars up again if none were found when the list was
-- built: var lookups are guarded, so before entering the game they can
-- quietly come back empty for every buff, and the list (built once) would
-- keep no vars all session. Returns whether any were found now.
function buffCatalogue.ResolveVars()
    for _, entry in ipairs(entries) do
        if entry.endVar ~= nil or entry.stacksVar ~= nil then return false end
    end
    local found = false
    for _, entry in ipairs(entries) do
        local core = nameCore(entry.structName)
        entry.endVar = endVarName(entry.structName, core)
        entry.stacksVar = entry.stacks and stacksVarName(entry.structName, core) or nil
        entry.inAreaVar = inAreaVarName(entry.structName)
        if entry.endVar ~= nil or entry.stacksVar ~= nil then found = true end
    end
    if found then shareAbilityVars(entries) end
    return found
end

-- Builds the list from the saved struct ids, if there are any and config
-- can be read. Returns whether the list changed.
function buffCatalogue.LoadCached()
    if #entries > 0 or lookupParams() == nil then return false end
    cachedIDs = cachedIDs or PersistentDB:GetString(CACHE_KEY) or ""
    local list = {}
    for value in string.gmatch(cachedIDs, "%d+") do
        local structID = tonumber(value)
        -- A saved id may be gone after a game update, and this runs at
        -- plugin load, so check it still has a name (as the walk does)
        -- before reading the struct.
        if nameOf(structID) ~= nil then
            local entry = readEntry(structID)
            if entry ~= nil then list[#list + 1] = entry end
        end
    end
    if #list == 0 then return false end
    entries = finish(list)
    return true
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
end

function buffCatalogue.List()
    return entries
end

return buffCatalogue
