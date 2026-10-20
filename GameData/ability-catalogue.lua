-- Lists the player's combat abilities from game config, with their names
-- and icons, so cooldown sources don't need writing by hand.
-- Each skill has an enum COMBATV2_ABILITIES_<SKILL> whose values are
-- structs named COMBATV2_ABILITY_<SKILL>_<ABILITY>, carrying params such as
-- COMBATV2_ABILITY_NAME and COMBATV2_ABILITY_ICON (a sprite id). The struct
-- name matches the ability's cooldown vars, COMBATV2_COOLDOWN_<SKILL>_<ABILITY>
-- _START/_END, so only abilities with that var pair are listed.
-- Usage:
--   local abilityCatalogue = require("GameData/ability-catalogue")
--   for _, ability in ipairs(abilityCatalogue.List()) do ... end
--   -- ability = { label, var (cooldown var base), icon (sprite id or nil) }

local abilityCatalogue = {}

-- Skills with an ability enum; the cooldown vars use the same names.
local SKILLS = {
    "ATTACK", "STRENGTH", "DEFENCE", "RANGED", "MAGIC", "CONSTITUTION", "NECROMANCY",
}
local STRUCT_PREFIX = "COMBATV2_ABILITY_"
local COOLDOWN_PREFIX = "COMBATV2_COOLDOWN_"
local NAME_PARAM = "COMBATV2_ABILITY_NAME"
local ICON_PARAM = "COMBATV2_ABILITY_ICON"

local abilities = nil

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

local function addEntry(entry, seen)
    local struct = entry[2]
    local structName = struct and tostring(struct.configName or "") or ""
    if structName:sub(1, #STRUCT_PREFIX) ~= STRUCT_PREFIX then return end
    local varBase = COOLDOWN_PREFIX .. structName:sub(#STRUCT_PREFIX + 1)
    if seen[varBase] or not varExists(varBase .. "_START") or not varExists(varBase .. "_END") then
        return
    end
    seen[varBase] = true
    local label = readParam(struct, NAME_PARAM)
    local icon = readParam(struct, ICON_PARAM)
    abilities[#abilities + 1] = {
        label = type(label) == "string" and label ~= "" and label or structName,
        var = varBase,
        icon = type(icon) == "number" and icon or nil,
    }
end

local function addSkill(skill, seen)
    local found, values = pcall(function() return config.Enum["COMBATV2_ABILITIES_" .. skill].values end)
    if not found or values == nil then return end
    -- Each entry on its own, so one that can't be read only skips itself.
    for _, entry in ipairs(values) do
        pcall(addEntry, entry, seen)
    end
end

-- Every ability with a cooldown, in skill then enum order. Built on first
-- use; empty if the config can't be read, in which case the next call tries
-- again (config may not be loaded before entering the game).
function abilityCatalogue.List()
    if abilities ~= nil and #abilities > 0 then return abilities end
    abilities = {}
    local seen = {}
    for _, skill in ipairs(SKILLS) do addSkill(skill, seen) end
    return abilities
end

return abilityCatalogue
