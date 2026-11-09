-- The Stalled ability data type's source (stalled-ability tracker): the time
-- until combat ends while an ability is stalled (used with nothing to hit,
-- so it fires on the next attack, and cleared when combat ends), with the
-- stalled (or last stalled) ability's name and icon.

local abilityCatalogue = require("GameData/Catalogues/ability-catalogue")
local stalledAbility = require("GameData/Trackers/stalled-ability")

local stalledAbilitySources = {}

local STALLED_COLOUR = 0xF39C12FF
local STALLED_NAME = "Stalled ability"
---@type table<string, AbilityEntry> Ability key to its ability, so the stalled ability can be named and shown, greater icon included.
local abilitiesByKey = {}

--- The stalled ability's details: the name and icon of what is (or was
--- last) stalled.
---@return string name
---@return integer? spriteID
---@return nil objectID
local function stalledAbilityDetails()
    local key = stalledAbility.Key()
    local ability = key ~= nil and abilitiesByKey[key] or nil
    if ability == nil then return STALLED_NAME, nil, nil end
    return ability.label, ability.icon, nil
end

--- Builds the stalled ability's source.
---@return DataSource[]
function stalledAbilitySources.Build()
    return {
        {
            id = "stalled_ability",
            type = "stalledAbility",
            label = STALLED_NAME,
            colour = STALLED_COLOUR,
            smooth = true,
            timed = true,
            state = "active",
            read = stalledAbility.Read,
            details = stalledAbilityDetails,
        },
    }
end

--- Maps every ability's key to it, once the ability catalogue is in use, so
--- the stalled ability can be named.
---@param usingCatalogue boolean Whether the ability catalogue could be read (see cooldowns.Build).
function stalledAbilitySources.MapAbilities(usingCatalogue)
    abilitiesByKey = {}
    if not usingCatalogue then return end
    for _, ability in ipairs(abilityCatalogue.List()) do
        -- A greater version is part of its base's entry, so each key is one
        -- ability's; should two entries share one, the first is kept.
        if ability.key ~= nil and abilitiesByKey[ability.key] == nil then abilitiesByKey[ability.key] = ability end
    end
end

return stalledAbilitySources
