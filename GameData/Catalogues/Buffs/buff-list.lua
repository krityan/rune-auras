-- Finishing the list of buffs read from config: versions of an ability share
-- vars, duplicate structs become one buff, and names that clash get the
-- struct's name added.

local buffVars = require("GameData/Catalogues/Buffs/buff-vars")
local buffEntries = require("GameData/Catalogues/Buffs/buff-entries")

local buffList = {}

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
            entry.requirements = entry.requirements or base.requirements
            entry.baseStruct = base.structName
        end
    end
end

--- Whether a buff's struct is a _DUMMY copy.
---@param entry BuffEntry
---@return boolean
local function isDummy(entry)
    return entry.structName:find("_DUMMY", 1, true) ~= nil
end

--- Which duplicate to keep: one with an icon (see buffEntries.HasIcon), then
--- not a _DUMMY copy, then one linked to an ability (so it can show the
--- greater version's icon).
---@param candidate BuffEntry
---@param current BuffEntry The one kept so far.
---@return boolean better Whether `candidate` is better than `current`.
local function isBetterDuplicate(candidate, current)
    local candidateHasIcon = buffEntries.HasIcon(candidate)
    if candidateHasIcon ~= buffEntries.HasIcon(current) then return candidateHasIcon end
    if isDummy(candidate) ~= isDummy(current) then return isDummy(current) end
    local candidateHasAbility, currentHasAbility = candidate.ability ~= nil, current.ability ~= nil
    if candidateHasAbility ~= currentHasAbility then return candidateHasAbility end
    return false
end

--- A buff's requirements as text, for comparing.
---@param entry BuffEntry
---@return string
local function requirementsKey(entry)
    local parts = {}
    for _, requirement in ipairs(entry.requirements or {}) do
        parts[#parts + 1] = table.concat({ tostring(requirement.var), tostring(requirement.slot), tostring(requirement.item) }, "/")
    end
    return table.concat(parts, ",")
end

--- What makes two buffs duplicates: the same name, vars and requirements.
---@param entry BuffEntry
---@return string? key nil without vars: before the vars can be read none have any, so they aren't compared.
local function duplicateKey(entry)
    if not buffVars.HasAny(entry) then return nil end
    return table.concat({ entry.name, tostring(entry.endVar), tostring(entry.startVar),
        tostring(entry.stacksVar), tostring(entry.activeVar), requirementsKey(entry) }, "|")
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

--- What a buff's name must be unique among: the listed buffs or debuffs
--- (see buffEntries.IsListed), as each kind has its own picker.
---@param entry BuffEntry
---@return string? key nil for one that isn't listed, so it clashes with nothing.
local function clashKey(entry)
    if not buffEntries.IsListed(entry) then return nil end
    return entry.kind .. "|" .. entry.name
end

--- Shares vars between an ability's buffs, drops duplicates, and gives names
--- that clash the struct's own name, so the picker can tell them apart
--- (Feasting Spores is two buffs and a debuff: the buffs get it, the debuff
--- doesn't). Safe to run again once vars are found.
---@param list BuffEntry[] Its entries are changed in place.
---@return BuffEntry[] finished A new list, sorted by label.
function buffList.Finish(list)
    shareAbilityVars(list)
    list = dropDuplicates(list)
    local counts = {}
    for _, entry in ipairs(list) do
        local key = clashKey(entry)
        if key ~= nil then counts[key] = (counts[key] or 0) + 1 end
    end
    for _, entry in ipairs(list) do
        entry.label = entry.name
        local key = clashKey(entry)
        if key ~= nil and counts[key] > 1 then
            entry.label = entry.name .. " (" .. buffEntries.NameFromStruct(entry.structName) .. ")"
        end
    end
    table.sort(list, function(first, second) return first.label:lower() < second.label:lower() end)
    return list
end

return buffList
