-- Whether the player has an ability or its greater version, for the Ability
-- unlocked load option: its level met (not boosted) and any unlock flags set.
-- Each answer is kept for a server tick.

local abilityCatalogue = require("GameData/Catalogues/ability-catalogue")
local gameClock = require("GameData/Trackers/game-clock")
local playerState = require("GameData/Trackers/player-state")
local varCache = require("GameData/Trackers/var-cache")

local abilityUnlocks = {}

-- A greater version's choice id is its ability's source id after this.
local GREATER_PREFIX = "greater:"

---@type AbilityEntry[]? The ability list the choices were made from.
local listedFrom = nil
local listedCount = 0
---@type { id: string, label: string }[]
local choices = {}
---@type table<string, AbilityEntry> Each ability's source id to it.
local byID = {}

---@type integer? The server tick the answers are for.
local answeredTick = nil
---@type table<string, boolean>
local answers = {}

--- Orders abilities by name.
---@param first AbilityEntry
---@param second AbilityEntry
---@return boolean
local function byLabel(first, second)
    return first.label < second.label
end

--- Lists the choices again if the ability list has changed (it's empty
--- until the game's config can be read).
local function refreshChoices()
    local abilities = abilityCatalogue.List()
    if abilities == listedFrom and #abilities == listedCount then
        return
    end

    listedFrom, listedCount = abilities, #abilities
    local sorted = {}
    for _, ability in ipairs(abilities) do
        if ability.id ~= nil then
            sorted[#sorted + 1] = ability
        end
    end

    table.sort(sorted, byLabel)
    choices, byID = {}, {}

    for _, ability in ipairs(sorted) do
        byID[ability.id] = ability
        choices[#choices + 1] = { id = ability.id, label = ability.label }

        if ability.greater ~= nil then
            choices[#choices + 1] = { id = GREATER_PREFIX .. ability.id, label = "Greater " .. ability.label }
        end
    end
end

--- Every ability, by name, each followed by its greater version if it has
--- one. Empty until the game's config can be read.
---@return { id: string, label: string }[]
function abilityUnlocks.Choices()
    refreshChoices()
    return choices
end

--- Whether a flag var is set (non-zero).
---@param name string
---@return boolean
local function isFlagSet(name)
    local value = tonumber(varCache.VarPlayer(name))
    return value ~= nil and value ~= 0
end

--- Whether the player has an ability, without its greater version.
---@param ability AbilityEntry
---@return boolean
local function hasAbility(ability)
    if ability.unlockVar ~= nil and not isFlagSet(ability.unlockVar) then
        return false
    end

    if ability.levelReq == nil or ability.levelSkill == nil then
        return true
    end

    local level = playerState.BaseSkillLevel(ability.levelSkill)
    return level ~= nil and level >= ability.levelReq
end

--- Whether a choice's ability is unlocked now.
---@param choiceID string A Choices id.
---@return boolean
local function isUnlockedNow(choiceID)
    refreshChoices()
    local isGreater = choiceID:sub(1, #GREATER_PREFIX) == GREATER_PREFIX
    local ability = byID[isGreater and choiceID:sub(#GREATER_PREFIX + 1) or choiceID]
    if ability == nil or not hasAbility(ability) then
        return false
    end

    if not isGreater then
        return true
    end

    return ability.greater ~= nil and isFlagSet(ability.greater.unlockVar)
end

--- Whether the player has a choice's ability. One not listed (or not yet,
--- before the game's config can be read) isn't.
---@param choiceID any A Choices id.
---@return boolean
function abilityUnlocks.IsUnlocked(choiceID)
    if type(choiceID) ~= "string" then
        return false
    end

    local tick = gameClock.ServerTicks()
    if tick ~= answeredTick then
        answeredTick = tick
        answers = {}
    end

    local answer = answers[choiceID]
    if answer == nil then
        answer = isUnlockedNow(choiceID)
        answers[choiceID] = answer
    end

    return answer
end

return abilityUnlocks
