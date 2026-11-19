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
---@field value any The choice it must match.
---@field item integer? For an option that picks an item (Item equipped): the item that must be worn in the slot `value` names; nil until one is picked.
---@field hands HandsChoice? For an option that picks hands (Weapon style): how the weapons must be held; nil for any.
---@field op string? For an option that compares (Skill level): a conditions.OPERATORS id; nil for DEFAULT_OP.
---@field number number? For an option that compares: what its value's number is compared with; nil for DEFAULT_NUMBER.
---@field unlocked boolean? For Ability unlocked: false passes while the ability isn't unlocked; nil or true while it is.

---@class LoadOption
---@field id string
---@field label string
---@field choices { id: any, label: string }[]|fun(): { id: any, label: string }[] A function for a list read from the game (see loadOptions.Choices).
---@field default any nil for the first choice.
---@field read (fun(): any)? The current value, compared with the chosen one; nil for an option with `passes` or `readNumber`.
---@field passes (fun(setting: LoadSetting): boolean)? Tests the setting itself, for an option that's more than one value.
---@field picksItem boolean? Its setting also holds an item for the chosen slot (LoadSetting.item).
---@field picksHands boolean? Its setting also holds how the weapons must be held (LoadSetting.hands).
---@field picksUnlocked boolean? Its setting also says whether the choice must be unlocked or not (LoadSetting.unlocked).
---@field readNumber (fun(choice: any): number?)? For an option that compares: the chosen thing's number now (a skill's level), compared with the setting's op and number as a condition's check is; nil means it fails.

---@alias HandsChoice "any"|"dualWield"|"twoHanded"

--- Weapon style's second choice: how the weapons must be held.
---@type { id: HandsChoice, label: string }[]
loadOptions.HANDS_CHOICES = {
    { id = "any", label = "Any" },
    { id = "dualWield", label = "Dual wield" },
    { id = "twoHanded", label = "2 handed" },
}
loadOptions.DEFAULT_HANDS = "any"

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

--- Whether the item picked for a slot is worn there. Nothing picked yet
--- passes, so ticking the option doesn't unload the aura while it's set up.
---@param setting LoadSetting
---@return boolean
local function isPickedItemWorn(setting)
    if setting.item == nil then
        return true
    end

    local slot = wornEquipment.SLOTS[setting.value]
    return slot ~= nil and wornEquipment.Item(slot) == setting.item
end

-- Worn slots Item equipped doesn't offer, though a setting naming one is
-- still tested.
local UNOFFERED_SLOTS = { AURA = true, WINGS = true }

--- Whether the ability picked is unlocked, or not, as the setting asks.
--- None picked passes, as for an item.
---@param setting LoadSetting
---@return boolean
local function isPickedAbilityUnlocked(setting)
    if setting.value == nil then
        return true
    end

    local wantsUnlocked = setting.unlocked ~= false
    return abilityUnlocks.IsUnlocked(setting.value) == wantsUnlocked
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
        passes = isPickedItemWorn,
        picksItem = true,
    },
    {
        id = "skillLevel",
        label = "Skill level",
        choices = playerState.SKILLS,
        default = "ATTACK",
        readNumber = playerState.SkillLevel,
    },
    {
        id = "abilityUnlocked",
        label = "Ability unlocked",
        choices = abilityUnlocks.Choices,
        passes = isPickedAbilityUnlocked,
        picksUnlocked = true,
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

--- An option's value until one is picked: its default, else its first choice.
---@param option LoadOption
---@return any value nil if it has neither.
function loadOptions.DefaultValue(option)
    if option.default ~= nil then
        return option.default
    end

    local first = loadOptions.Choices(option)[1]
    return first and first.id
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

--- Whether a comparing option's chosen thing's number compares as its
--- setting asks; a number that can't be read fails. Each choice's number is
--- read at most once a step.
---@param option LoadOption
---@param setting LoadSetting
---@return boolean
local function comparisonPasses(option, setting)
    if numberSteps[option.id] ~= step then
        numberSteps[option.id] = step
        numbers[option.id] = {}
    end

    if setting.value == nil then
        return false
    end

    local read = numbers[option.id]
    local number = read[setting.value]
    if number == nil then
        number = option.readNumber(setting.value) or false
        read[setting.value] = number
    end

    if number == false then
        return false
    end

    return conditions.Compare(number, setting.op or loadOptions.DEFAULT_OP, setting.number or loadOptions.DEFAULT_NUMBER)
end

--- Whether an enabled option's setting passes.
---@param option LoadOption
---@param setting LoadSetting
---@return boolean
local function optionPasses(option, setting)
    if option.passes ~= nil then
        return option.passes(setting)
    end

    if option.readNumber ~= nil then
        return comparisonPasses(option, setting)
    end

    if optionValue(option) ~= setting.value then
        return false
    end

    return not option.picksHands or handsMatch(setting)
end

--- Whether an aura should load.
---@param aura Aura
---@param ownSource string? The aura's source, for checks that read it.
---@param read ReadCheckValues
---@param readUsable ReadUsable?
---@return boolean
function loadOptions.Passes(aura, ownSource, read, readUsable)
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
        if conditions.IsComplete(check) and not conditions.CheckPasses(check, ownSource, read, readUsable) then
            return false
        end
    end

    return true
end

return loadOptions
