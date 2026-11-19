-- The Ability cooldown data type's sources: current is the seconds left (0
-- when ready), max is the full cooldown, so a bar drains as the ability
-- comes back. The list comes from game config (ability-catalogue), falling
-- back to the hand-written abilityCatalogue.FALLBACK if that can't be read
-- yet (e.g. loading at the login screen), until it's built again.

local abilityCatalogue = require("GameData/Catalogues/ability-catalogue")
local abilityCooldowns = require("GameData/Trackers/ability-cooldowns")
local actionBar = require("GameData/Trackers/action-bar")

local cooldowns = {}

-- Also the special attack and extra action button sources' colour.
cooldowns.COLOUR = 0x9B59B6FF
local COOLDOWN_VAR_PREFIX = abilityCatalogue.COOLDOWN_VAR_PREFIX
local COOLDOWN_ID_PREFIX = abilityCatalogue.SOURCE_ID_PREFIX

--- A cooldown source's id, named after its var so it stays stable.
---@param varBase string The cooldown var without _START/_END.
---@return string
local function cooldownID(varBase)
    return COOLDOWN_ID_PREFIX .. string.lower(varBase:sub(#COOLDOWN_VAR_PREFIX + 1))
end

---@type table<string, string> Old source id to current id, for auras saved before ids followed the var.
cooldowns.RENAMED_IDS = {}
for _, ability in ipairs(abilityCatalogue.FALLBACK) do
    cooldowns.RENAMED_IDS[COOLDOWN_ID_PREFIX .. ability.legacyID] = cooldownID(ability.var)
end

--- A cooldown's values: the time to its next charge (see GetNextCharge),
--- and the charges ready as the fourth.
---@param varBase string
---@return number? remaining
---@return number? total
---@return number? unrounded
---@return integer? charges
function cooldowns.Read(varBase)
    local remaining, total, unrounded = abilityCooldowns.GetNextCharge(varBase)
    return remaining, total, unrounded, (abilityCooldowns.GetCharges(varBase))
end

--- The recast stage an ability is on, if any: the last whose flag is set.
---@param ability AbilityEntry
---@return AbilityStage? stage nil while it's the ability itself.
local function currentStage(ability)
    local stages = ability.stages
    if stages == nil then
        return nil
    end

    for index = #stages, 1, -1 do
        local stage = stages[index]
        if (abilityCooldowns.VarValue(stage.activeVar) or 0) ~= 0 then
            return stage
        end
    end

    return nil
end

--- A conjure's command while the conjure is out, as the action bar shows
--- it in the conjure's place.
---@param ability AbilityEntry
---@return AbilityCommand? command nil while it's the conjure itself.
local function activeCommand(ability)
    local command = ability.command
    if command == nil or (abilityCooldowns.VarValue(command.activeVar) or 0) == 0 then
        return nil
    end

    return command
end

--- A cooldown source's read: the ability's cooldown, its command's while a
--- conjure is out, or ready while it's on a recast stage. A stage's own
--- cooldown is only the global cooldown after the stage before, so it isn't
--- shown.
---@param ability AbilityEntry
---@return fun(): number?, number?, number?, integer?
local function cooldownReader(ability)
    local varBase = ability.var
    if ability.stages == nil and ability.command == nil then
        return function() return cooldowns.Read(varBase) end
    end

    return function()
        local command = activeCommand(ability)
        if command ~= nil then
            return cooldowns.Read(command.var)
        end

        if currentStage(ability) == nil then
            return cooldowns.Read(varBase)
        end

        local _, total = abilityCooldowns.GetCooldown(varBase)
        -- One use ready: GetCharges would say 0, as the ability's cooldown runs.
        return 0, total, 0, 1
    end
end

--- The details of an ability the action bar swaps for another: its command's
--- or its current stage's name and icon.
---@param ability AbilityEntry
---@return fun(): string?, integer?, integer?
local function swappedDetails(ability)
    return function()
        local swapped = activeCommand(ability) or currentStage(ability)
        if swapped == nil then
            return ability.label, ability.icon, nil
        end

        return swapped.label or ability.label, swapped.icon or ability.icon, nil
    end
end

--- Every icon the action bar can show for an ability: its own, its greater
--- version's, its recast stages' and, for a conjure, its command's.
---@param ability AbilityEntry
---@return integer[]
local function barIcons(ability)
    local icons = {}
    local function add(icon)
        if icon ~= nil then
            icons[#icons + 1] = icon
        end
    end

    add(ability.baseIcon or ability.icon)
    add(ability.greater and ability.greater.icon)

    for _, stage in ipairs(ability.stages or {}) do
        add(stage.icon)
    end

    add(ability.command and ability.command.icon)
    return icons
end

--- Builds a cooldown source per ability, from the catalogue or FALLBACK.
---@return DataSource[] sources
---@return boolean usingCatalogue Whether they came from the ability catalogue rather than FALLBACK.
function cooldowns.Build()
    local abilities = abilityCatalogue.List()
    local usingCatalogue = #abilities > 0
    if not usingCatalogue then
        abilities = abilityCatalogue.FALLBACK
    end

    local sources = {}
    for _, ability in ipairs(abilities) do
        local varBase = ability.var
        -- Every ability's last use helps show the others are ready before
        -- the cooldown clock is synced.
        abilityCooldowns.Watch(varBase)
        local icons = barIcons(ability)

        for _, stage in ipairs(ability.stages or {}) do
            abilityCooldowns.WatchFlag(stage.activeVar)
        end

        if ability.command ~= nil then
            abilityCooldowns.Watch(ability.command.var)
            abilityCooldowns.WatchFlag(ability.command.activeVar)
        end

        sources[#sources + 1] = {
            -- Abilities sharing a cooldown share a var, so the catalogue names
            -- each one; the hand-written fallback is named by its var.
            id = ability.id or cooldownID(varBase),
            type = "cooldown",
            label = ability.label,
            colour = cooldowns.COLOUR,
            icon = ability.icon,
            ability = ability,
            smooth = true,
            timed = true,
            state = "cooldown",
            read = cooldownReader(ability),
            details = (ability.stages or ability.command) and swappedDetails(ability) or nil,
            movedFrom = ability.movedFrom,
            usable = function() return actionBar.IsUsable(icons) end,
            keybind = function() return actionBar.Keybind(icons) end,
        }
    end

    return sources, usingCatalogue
end

return cooldowns
