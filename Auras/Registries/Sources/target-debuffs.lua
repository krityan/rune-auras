-- The Target debuff data type's sources (target-debuffs tracker): current
-- is the seconds left of a DoT or debuff the player put on their target, max
-- its length, and $target and the other target fields its target's details.
-- Other ones (target-effects tracker) are only on or off, unless an aura sets
-- a length to count down (see dataSources.WithDuration).

local targetDebuffCatalogue = require("GameData/Catalogues/target-debuff-catalogue")
local targetDebuffs = require("GameData/Trackers/target-debuffs")
local targetEffects = require("GameData/Trackers/target-effects")
local targetInfo = require("GameData/Trackers/target-info")
local buffs = require("Auras/Registries/Sources/buffs")

local targetDebuffSources = {}

-- Timed from an ability's use or a hex spell's cast, or (Other) only seen
-- on the target info panel.
local TARGET_ABILITIES, TARGET_HEXES, TARGET_OTHER = "abilities", "hexes", "other"

---@type DataCategory[] The type's categories, in the picker's order.
targetDebuffSources.CATEGORIES = {
    { id = TARGET_ABILITIES, label = "Abilities" },
    { id = TARGET_HEXES, label = "Hexes" },
    { id = TARGET_OTHER, label = "Other" },
}

local TARGET_DEBUFF_ID_PREFIX = "target_debuff_"

--- A target debuff's details, with its target's for the target fields.
---@param name string
---@param icon integer
---@return string name
---@return integer icon
---@return nil object
---@return nil ammo
---@return TargetInfo target
local function targetDebuffDetails(name, icon)
    local object, ammo = nil, nil
    return name, icon, object, ammo, targetInfo.Details()
end

--- Builds a source per entry in the target debuff catalogue: its timed
--- abilities and hexes, then the others.
---@return DataSource[]
function targetDebuffSources.Build()
    local sources = {}
    for _, entry in ipairs(targetDebuffCatalogue.ENTRIES) do
        sources[#sources + 1] = {
            id = TARGET_DEBUFF_ID_PREFIX .. entry.key,
            type = "targetDebuff",
            category = entry.spell ~= nil and TARGET_HEXES or TARGET_ABILITIES,
            label = entry.name,
            colour = buffs.DEBUFF_COLOUR,
            icon = entry.icon,
            smooth = true,
            timed = true,
            state = "active",
            read = function() return targetDebuffs.Read(entry) end,
            hasTarget = true,
            -- $target: the name of the target it shows the run of.
            details = function() return targetDebuffDetails(entry.name, entry.icon) end,
        }
    end
    for _, entry in ipairs(targetDebuffCatalogue.OTHER) do
        sources[#sources + 1] = {
            id = TARGET_DEBUFF_ID_PREFIX .. entry.key,
            type = "targetDebuff",
            category = TARGET_OTHER,
            label = entry.name,
            colour = buffs.DEBUFF_COLOUR,
            icon = entry.icon,
            onOff = true,
            state = "active",
            read = function() return targetEffects.Read(entry) end,
            readTimed = function(seconds) return targetEffects.ReadTimed(entry, seconds) end,
            hasTarget = true,
            details = function() return targetDebuffDetails(entry.name, entry.icon) end,
        }
    end
    return sources
end

return targetDebuffSources
