-- Load options: what decides whether an aura is loaded (shown at all), and
-- testing them. The editor's Load tab edits them (see UI/Editor/load-tab).

local conditions = require("Auras/Registries/conditions")
local playerState = require("GameData/Trackers/player-state")
local abilityUnlocks = require("GameData/Trackers/ability-unlocks")
local wornEquipment = require("GameData/Trackers/worn-equipment")

local loadOptions = {}

--- What decides whether an aura loads. Everything enabled must pass, so "In
--- combat: Yes" and "Weapon style: Melee" load it only in combat with a
--- melee weapon; nothing enabled means always loaded. A group that isn't
--- loaded takes everything in it with it.
---@class AuraLoad
---@field options table<string, LoadSetting>? OPTIONS id to its setting.
---@field checks Check[]? All must pass. One with a data type but no source picked yet is skipped, so adding a check doesn't unload the aura.

--- A fixed option's setting. An unticked option keeps its value, so ticking
--- it again brings it back.
---@class LoadSetting
---@field enabled boolean Only tested while enabled.
---@field value any The choice it must match; nil for an option with lines.
---@field items integer[]? For an option that picks items (Item equipped): the items tested against what's worn in the slot `value` names; nil or empty until one is picked.
---@field worn boolean? For an option that picks items: false passes while none of them is worn in the slot; nil or true while one is.
---@field hands HandsChoice? For an option that picks hands (Weapon style): how the weapons must be held; nil for any.
---@field lines LoadLine[]? For an option with lines (Skill level, Ability unlocked): every one must pass; nil or empty until one is added.

--- One line of an option with lines: its own choice and what it must be.
---@class LoadLine
---@field value any The choice (a skill, an ability).
---@field op string? For an option that compares (Skill level): a conditions.OPERATORS id; nil for DEFAULT_OP.
---@field number number? For an option that compares: what the choice's number is compared with; nil for DEFAULT_NUMBER.
---@field unlocked boolean? For Ability unlocked: false passes while the ability isn't unlocked; nil or true while it is.

---@class LoadOption
---@field id string
---@field label string
---@field choices { id: any, label: string }[]|fun(): { id: any, label: string }[] A function for a list read from the game (see loadOptions.Choices).
---@field default any nil for the first choice.
---@field read (fun(): any)? The current value, compared with the chosen one; nil for an option with `passes` or `readNumber`.
---@field passes (fun(setting: LoadSetting|LoadLine): boolean)? Tests the setting itself (or each line, for an option with lines), for an option that's more than one value.
---@field picksItems boolean? Its setting also holds items for the chosen slot (LoadSetting.items), and whether one must be worn (LoadSetting.worn).
---@field picksHands boolean? Its setting also holds how the weapons must be held (LoadSetting.hands).
---@field picksUnlocked boolean? Each line also says whether its choice must be unlocked or not (LoadLine.unlocked).
---@field readNumber (fun(choice: any): number?)? For an option that compares: a line's chosen thing's number now (a skill's level), compared with the line's op and number as a condition's check is; nil means it fails.
---@field hasLines boolean? Its setting is a list of lines (LoadSetting.lines), each with its own choice, rather than one value.

---@alias HandsChoice "any"|"dualWield"|"twoHanded"

--- Weapon style's second choice: how the weapons must be held.
---@type { id: HandsChoice, label: string }[]
loadOptions.HANDS_CHOICES = {
    { id = "any", label = "Any" },
    { id = "dualWield", label = "Dual wield" },
    { id = "twoHanded", label = "2 handed" },
}
loadOptions.DEFAULT_HANDS = "any"

--- Item equipped's second choice: whether one of its items must be worn.
---@type { id: boolean, label: string }[]
loadOptions.WORN_CHOICES = {
    { id = true, label = "Is" },
    { id = false, label = "Is not" },
}

-- The most items Item equipped tests, and lines an option with lines has:
-- each is a row of controls in the editor.
loadOptions.MAX_ROWS = 20

--- Ability unlocked's second choice: whether the ability must be unlocked.
---@type { id: boolean, label: string }[]
loadOptions.UNLOCKED_CHOICES = {
    { id = true, label = "Unlocked" },
    { id = false, label = "Not unlocked" },
}

-- A comparing option's comparison until one is set: At least 0, which a
-- level always passes, so ticking it doesn't unload the aura.
loadOptions.DEFAULT_OP = "ge"
loadOptions.DEFAULT_NUMBER = 0

--- Whether one of the items picked for a slot is worn there, or none is,
--- as the setting asks. Nothing picked yet passes, so ticking the option
--- doesn't unload the aura while it's set up.
---@param setting LoadSetting
---@return boolean
local function isWornAsPicked(setting)
    local items = setting.items
    if items == nil or #items == 0 then
        return true
    end

    local slot = wornEquipment.SLOTS[setting.value]
    local wornID = slot ~= nil and wornEquipment.Item(slot) or nil
    local isListed = false
    for _, itemID in ipairs(items) do
        if itemID == wornID then
            isListed = true
            break
        end
    end

    return isListed == (setting.worn ~= false)
end

-- Worn slots Item equipped doesn't offer, though a setting naming one is
-- still tested.
local UNOFFERED_SLOTS = { AURA = true, WINGS = true }

--- Whether a line's ability is unlocked, or not, as the line asks.
---@param line LoadLine
---@return boolean
local function isPickedAbilityUnlocked(line)
    local wantsUnlocked = line.unlocked ~= false
    return abilityUnlocks.IsUnlocked(line.value) == wantsUnlocked
end

--- Item equipped's choices: every worn slot it offers, saved by its SLOTS key
--- (which stays put if the game renumbers slots), listed in slot order.
---@return { id: string, label: string }[]
local function slotChoices()
    local slots = wornEquipment.SLOTS
    local keys = {}
    for key in pairs(slots) do
        if not UNOFFERED_SLOTS[key] then
            keys[#keys + 1] = key
        end
    end

    table.sort(keys, function(first, second) return slots[first] < slots[second] end)
    local choices = {}
    for index, key in ipairs(keys) do
        choices[index] = { id = key, label = wornEquipment.SLOT_LABELS[key] }
    end

    return choices
end

---@type LoadOption[]
loadOptions.OPTIONS = {
    {
        id = "inCombat",
        label = "In combat",
        choices = { { id = true, label = "Yes" }, { id = false, label = "No" } },
        default = true,
        read = playerState.InCombat,
    },
    {
        id = "weaponStyle",
        label = "Weapon style",
        choices = {
            { id = "melee", label = "Melee" },
            { id = "ranged", label = "Ranged" },
            { id = "magic", label = "Magic" },
            { id = "necromancy", label = "Necromancy" },
        },
        default = "melee",
        read = playerState.WeaponStyle,
        picksHands = true,
    },
    {
        id = "wearing",
        label = "Item equipped",
        choices = slotChoices(),
        default = "MAIN_HAND",
        passes = isWornAsPicked,
        picksItems = true,
    },
    {
        id = "skillLevel",
        label = "Skill level",
        choices = playerState.SKILLS,
        readNumber = playerState.SkillLevel,
        hasLines = true,
    },
    {
        id = "abilityUnlocked",
        label = "Ability unlocked",
        choices = abilityUnlocks.Choices,
        passes = isPickedAbilityUnlocked,
        picksUnlocked = true,
        hasLines = true,
    },
}

--- An option's choices now.
---@param option LoadOption
---@return { id: any, label: string }[]
function loadOptions.Choices(option)
    local choices = option.choices
    if type(choices) == "function" then
        return choices()
    end

    return choices
end

--- An option's value until one is picked: its default, otherwise its first choice.
---@param option LoadOption
---@return any value nil if it has neither.
function loadOptions.DefaultValue(option)
    if option.default ~= nil then
        return option.default
    end

    local first = loadOptions.Choices(option)[1]
    return first and first.id
end

--- Gives the settings of an aura saved (or exported) before options took
--- lists the lists they have now: Item equipped's single `item` becomes
--- its first item, and an option with lines has its value, with the op,
--- number or unlocked beside it, as its first line.
---@param load AuraLoad? Changed in place.
function loadOptions.Upgrade(load)
    local settings = load and load.options
    if type(settings) ~= "table" then
        return
    end

    for _, option in ipairs(loadOptions.OPTIONS) do
        local setting = settings[option.id]
        local isOldItem = type(setting) == "table" and option.picksItems and setting.item ~= nil
        if isOldItem then
            setting.items = setting.items or { setting.item }
            setting.item = nil
        end

        local isOldLine = type(setting) == "table" and option.hasLines and setting.value ~= nil
        if isOldLine then
            local line = { value = setting.value, op = setting.op, number = setting.number, unlocked = setting.unlocked }
            setting.lines = setting.lines or { line }
            setting.value, setting.op, setting.number, setting.unlocked = nil, nil, nil, nil
        end
    end
end

--- An option's setting on a load, if it's ticked.
---@param load AuraLoad
---@param option LoadOption
---@return LoadSetting? setting nil if it isn't enabled.
local function enabledSetting(load, option)
    local setting = load.options and load.options[option.id]
    if setting ~= nil and setting.enabled then
        return setting
    end

    return nil
end

--- Whether an aura has anything that can stop it loading.
---@param aura Aura
---@return boolean
function loadOptions.HasAny(aura)
    local load = aura.load
    if load == nil then
        return false
    end

    if load.checks ~= nil and #load.checks > 0 then
        return true
    end

    for _, option in ipairs(loadOptions.OPTIONS) do
        if enabledSetting(load, option) ~= nil then
            return true
        end
    end

    return false
end

-- Each option's value this step, read once however many auras test it.
local step = 0
local readSteps, values = {}, {}

--- Starts a new step, so options are read again. Call before each step's
--- Passes over the auras.
function loadOptions.NewStep()
    step = step + 1
end

--- An option's current value, read at most once a step (see LoadOption.read).
---@param option LoadOption
---@return any
local function optionValue(option)
    if readSteps[option.id] ~= step then
        readSteps[option.id] = step
        values[option.id] = option.read()
    end

    return values[option.id]
end

---@type integer? The step the weapons' hands were last read on.
local handsStep = nil
---@type WeaponHands
local hands = "oneHanded"

--- Whether the weapons are held as a setting asks; any way passes "any"
--- (or a setting from before hands could be picked).
---@param setting LoadSetting
---@return boolean
local function handsMatch(setting)
    local wanted = setting.hands
    if wanted == nil or wanted == loadOptions.DEFAULT_HANDS then
        return true
    end

    if handsStep ~= step then
        handsStep = step
        hands = playerState.WeaponHands()
    end

    return hands == wanted
end

-- Each comparing option's numbers this step, by option id then choice.
local numberSteps, numbers = {}, {}

--- Whether a comparing option's line's chosen thing's number compares as
--- the line asks; a number that can't be read fails. Each choice's number
--- is read at most once a step.
---@param option LoadOption
---@param line LoadLine
---@return boolean
local function comparisonPasses(option, line)
    if numberSteps[option.id] ~= step then
        numberSteps[option.id] = step
        numbers[option.id] = {}
    end

    local read = numbers[option.id]
    local number = read[line.value]
    if number == nil then
        number = option.readNumber(line.value) or false
        read[line.value] = number
    end

    if number == false then
        return false
    end

    return conditions.Compare(number, line.op or loadOptions.DEFAULT_OP, line.number or loadOptions.DEFAULT_NUMBER)
end

--- Whether every line of an option with lines passes; none passes too.
---@param option LoadOption
---@param setting LoadSetting
---@return boolean
local function linesPass(option, setting)
    for _, line in ipairs(setting.lines or {}) do
        local passes
        if option.passes ~= nil then
            passes = option.passes(line)
        else
            passes = comparisonPasses(option, line)
        end

        if not passes then
            return false
        end
    end

    return true
end

--- Whether an enabled option's setting passes.
---@param option LoadOption
---@param setting LoadSetting
---@return boolean
local function optionPasses(option, setting)
    if option.hasLines then
        return linesPass(option, setting)
    end

    if option.passes ~= nil then
        return option.passes(setting)
    end

    if optionValue(option) ~= setting.value then
        return false
    end

    return not option.picksHands or handsMatch(setting)
end

--- Whether an aura should load.
---@param aura Aura
---@param auraSourceID string? Read by checks that name no source.
---@param read ReadCheckValues
---@param readUsable ReadUsable?
---@return boolean
function loadOptions.Passes(aura, auraSourceID, read, readUsable)
    local load = aura.load
    if load == nil then
        return true
    end

    for _, option in ipairs(loadOptions.OPTIONS) do
        local setting = enabledSetting(load, option)
        if setting ~= nil and not optionPasses(option, setting) then
            return false
        end
    end

    for _, check in ipairs(load.checks or {}) do
        if conditions.IsComplete(check) and not conditions.CheckPasses(check, auraSourceID, read, readUsable) then
            return false
        end
    end

    return true
end

return loadOptions
