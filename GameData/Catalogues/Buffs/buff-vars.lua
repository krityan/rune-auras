-- Finding a buff's vars: nothing in config links a buff struct to the vars
-- it's read from, so they're found by name. Each kind of var has a list of
-- name templates tried in order, after buff-data's hand-written ones and
-- families. Reading the vars is active-buffs' job.

local gameApi = require("GameData/game-api")
local buffData = require("GameData/Catalogues/Buffs/buff-data")

local buffVars = {}

-- Name templates. {S} is the struct name, {C} its core (see nameCore), and
-- {B} the struct name without a trailing _STACKS (Flow's struct is
-- COMBATV2_BUFF_MAGIC_FLOW_STACKS, its flag _FLOW_ACTIVE).

-- A buff's end-time VarClient, holding the Logic tick it ends on. Special
-- attacks' effects (Instability, Split Soul, Gravitate) leave out the END.
-- Last come names with no END at all, which despite the word hold the end of
-- many perks and boosts (Devoted's is COMBATV2_DEVOTED_PERK_COOLDOWN).
-- COMBATV2_COOLDOWN_<core>_END_CLIENT is the ability's cooldown, so it's
-- never one.
local END_VAR_NAMES = {
    "{S}_END_EFFECT_CLIENT", "{S}_END_CLIENT",
    "COMBATV2_BUFF_{C}_END_EFFECT_CLIENT", "COMBATV2_BUFF_{C}_END_CLIENT",
    "COMBATV2_DEBUFF_{C}_END_EFFECT_CLIENT", "COMBATV2_DEBUFF_{C}_END_CLIENT",
    "COMBATV2_{C}_END_EFFECT_CLIENT", "COMBATV2_{C}_END_CLIENT",
    "{C}_END_EFFECT_CLIENT", "{C}_END_CLIENT",
    "COMBATV2_COOLDOWN_{C}_END_EFFECT_CLIENT",
    "COMBATV2_COOLDOWN_{C}_EFFECT_CLIENT", "COMBATV2_{C}_EFFECT_CLIENT",
    "{S}", "{S}_COOLDOWN", "COMBATV2_{C}_COOLDOWN", "COMBATV2_COOLDOWN_{C}",
}
-- A stacking buff's stacks VarPlayer: an amount (Sprite focus's
-- ARCH_EXCAVATION_FOCUS_COUNT) only where there's no _STACKS. A struct
-- already ending _STACKS can be its own stacks var (Essence Corruption).
local STACKS_VAR_NAMES = {
    "{S}_STACKS", "COMBATV2_BUFF_{C}_STACKS", "COMBATV2_{C}_STACKS", "{C}_STACKS", "{B}_STACKS",
    "{S}_COUNT", "COMBATV2_BUFF_{C}_COUNT", "COMBATV2_{C}_COUNT", "{C}_COUNT",
    "{S}_AMOUNT", "COMBATV2_BUFF_{C}_AMOUNT", "COMBATV2_{C}_AMOUNT", "{C}_AMOUNT",
    "{S}_PERCENT", "COMBATV2_BUFF_{C}_PERCENT", "COMBATV2_{C}_PERCENT", "{C}_PERCENT",
}
-- A toggled buff's VarPlayer (prayers, curses, Bone Shield: no timer,
-- switched on and off), non-zero while on. An _ACTIVE flag first: a
-- same-named var can be a level or count (INVENT_PERK_WISE) where
-- INVENT_PERK_WISE_ACTIVE is the flag. Prayers are varbits
-- COMBATV2_PRAYER_<name>, curses CURSE_<name>.
local ACTIVE_VAR_NAMES = { "{S}_ACTIVE", "COMBATV2_{C}_ACTIVE", "{C}_ACTIVE", "{B}_ACTIVE", "{S}", "COMBATV2_{C}", "{C}" }
-- The _START var of the ability a buff with no end time is timed from
-- (Unsullied): the server tick it was used. It lasts its duration from
-- there; the ability's _END is when the cooldown ends, not the effect.
local START_VAR_NAMES = { "COMBATV2_COOLDOWN_{C}_START" }

local CORE_PREFIXES = { "COMBATV2_", "ABILITY_", "BUFF_", "DEBUFF_" }
local CORE_SUFFIXES = { "_DUMMY_ABILITY", "_DUMMY_EFFECT", "_DUMMY", "_ABILITY", "_COOLDOWN", "_EFFECT", "_STRUCT" }
local STACKS_SUFFIX = "_STACKS"
local NO_STACKS_DATA = {}

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

--- What a struct's name fills the templates' tokens with.
---@param structName string
---@return table<string, string>
local function tokensFor(structName)
    local base = structName
    if structName:sub(-#STACKS_SUFFIX) == STACKS_SUFFIX then base = structName:sub(1, -#STACKS_SUFFIX - 1) end
    return { S = structName, C = nameCore(structName), B = base }
end

--- Whether a VarClient can be an end time: it exists and holds an integer (a
--- Logic tick). Names found by a rule could match a var of another type,
--- which can't be read every tick (see gameApi.IsIntegerVar).
---@param name string
---@return boolean
local function isEndTimeVar(name)
    local varConfig = gameApi.VarClient(name)
    return varConfig ~= nil and gameApi.IsIntegerVar(varConfig)
end

--- The first var a buff's hand-written name, family or templates give that
--- `isUsable` accepts.
---@param alias string? Its hand-written var.
---@param families { pattern: string, replacement: string }[]
---@param templates string[]
---@param tokens table<string, string> See tokensFor.
---@param isUsable fun(name: string): boolean
---@return string? varName nil if there's none.
local function findVar(alias, families, templates, tokens, isUsable)
    if alias ~= nil and isUsable(alias) then return alias end
    for _, family in ipairs(families) do
        local varName, matched = tokens.S:gsub(family.pattern, family.replacement)
        if matched > 0 and isUsable(varName) then return varName end
    end
    for _, template in ipairs(templates) do
        local varName = template:gsub("{(%a)}", tokens)
        if isUsable(varName) then return varName end
    end
    return nil
end

--- A buff's end-time VarClient (see END_VAR_NAMES and buff-data's END_VARS).
---@param tokens table<string, string> See tokensFor.
---@return string? varName nil if it has none.
local function endVarName(tokens)
    local alias = buffData.END_VARS[tokens.S]
    if alias == false then return nil end
    return findVar(alias, buffData.END_VAR_FAMILIES, END_VAR_NAMES, tokens, isEndTimeVar)
end

--- Buffs that show the same icon on the game's buff bar, so the bar can't
--- say which of them it still shows (see buff-data's SHARED_ICONS).
---@class BuffIconGroup
---@field key string The same for every member of the group.
---@field endVars (string|false)[] Each member's end-time VarClient, in the group's order; false for one without.
---@field index integer This buff's place in the group.

--- The other buffs showing a buff's icon on the bar, with each one's end
--- time (see buff-data's SHARED_ICONS).
---@param structName string
---@return BuffIconGroup? group nil for a buff not in one.
local function iconGroupFor(structName)
    for _, members in ipairs(buffData.SHARED_ICONS) do
        for index, member in ipairs(members) do
            if member == structName then
                local endVars = {}
                for memberIndex, memberName in ipairs(members) do
                    endVars[memberIndex] = endVarName(tokensFor(memberName)) or false
                end
                return { key = table.concat(members, "|"), endVars = endVars, index = index }
            end
        end
    end
    return nil
end

--- Finds every var a buff is read from, setting its endVar, stacksVar,
--- stacksAtFull, stacksWhileUntimed, requiredVar, quietTicks, iconGroup,
--- startVar, activeVar and objectVar. Toggles and start-timed buffs are only
--- looked for without an end time, which is looked for first.
---@param entry BuffEntry Changed in place; its structName, stacks, stacksPercent, duration and objectOverride must be set.
function buffVars.Resolve(entry)
    local structName = entry.structName
    local tokens = tokensFor(structName)
    local stacksData = buffData.STACKS[structName] or NO_STACKS_DATA
    entry.endVar = endVarName(tokens)
    entry.stacksVar = entry.stacks
        and findVar(stacksData.var, buffData.STACKS_VAR_FAMILIES, STACKS_VAR_NAMES, tokens, gameApi.VarExists) or nil
    entry.stacksAtFull = entry.stacksPercent and stacksData.atFull or nil
    entry.stacksWhileUntimed = stacksData.whileUntimed
    local required = buffData.REQUIRES[structName]
    entry.requiredVar = required ~= nil and gameApi.VarExists(required) and required or nil
    entry.quietTicks = buffData.QUIET_TICKS[structName]
    entry.iconGroup = iconGroupFor(structName)
    local untimed = entry.endVar == nil
    -- Only buffs with a duration can be timed from their ability's use.
    entry.startVar = untimed and entry.duration ~= nil
        and findVar(nil, {}, START_VAR_NAMES, tokens, gameApi.VarExists) or nil
    local activeAlias = buffData.ACTIVE_VARS[structName] or buffData.ACTIVE_VARS["COMBATV2_" .. tokens.C]
    entry.activeVar = untimed and findVar(activeAlias, {}, ACTIVE_VAR_NAMES, tokens, gameApi.VarExists) or nil
    -- The quiver's on/off var is the OBJ var holding its ammo.
    entry.objectVar = entry.objectOverride and entry.activeVar or nil
end

--- Whether a buff has any var to be read from (active-buffs reads it if so).
--- Buffs with none can't be tracked, so the data sources leave them out.
---@param entry BuffEntry
---@return boolean
function buffVars.HasAny(entry)
    return entry.endVar ~= nil or entry.startVar ~= nil or entry.stacksVar ~= nil or entry.activeVar ~= nil
        or entry.quietTicks ~= nil
end

--- Whether a buff has a timer: an end time or a start to time from.
---@param entry BuffEntry
---@return boolean
function buffVars.IsTimed(entry)
    return entry.endVar ~= nil or entry.startVar ~= nil
end

return buffVars
