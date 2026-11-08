-- Load options: what decides whether an aura is loaded (shown at all), and
-- testing them. The editor's Load tab edits them (see UI/Editor/load-tab).

local conditions = require("Auras/Registries/conditions")
local playerState = require("GameData/Trackers/player-state")
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

---@class LoadOption
---@field id string
---@field label string
---@field choices { id: any, label: string }[]
---@field default any
---@field read (fun(): any)? The current value, compared with the chosen one; nil for an option with `passes`.
---@field passes (fun(setting: LoadSetting): boolean)? Tests the setting itself, for an option that's more than one value.
---@field picksItem boolean? Its setting also holds an item for the chosen slot (LoadSetting.item).

--- Whether the item picked for a slot is worn there. Nothing picked yet
--- passes, so ticking the option doesn't unload the aura while it's set up.
---@param setting LoadSetting
---@return boolean
local function isPickedItemWorn(setting)
    if setting.item == nil then return true end
    local slot = wornEquipment.SLOTS[setting.value]
    return slot ~= nil and wornEquipment.Item(slot) == setting.item
end

--- Item equipped's choices: every worn slot, saved by its SLOTS key (which stays
--- put if the game renumbers slots), listed in slot order.
---@return { id: string, label: string }[]
local function slotChoices()
    local slots = wornEquipment.SLOTS
    local keys = {}
    for key in pairs(slots) do keys[#keys + 1] = key end
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
    },
    {
        id = "wearing",
        label = "Item equipped",
        choices = slotChoices(),
        default = "MAIN_HAND",
        passes = isPickedItemWorn,
        picksItem = true,
    },
}

--- An option's setting on a load, if it's ticked.
---@param load AuraLoad
---@param option LoadOption
---@return LoadSetting? setting nil if it isn't enabled.
local function enabledSetting(load, option)
    local setting = load.options and load.options[option.id]
    if setting ~= nil and setting.enabled then return setting end
    return nil
end

--- Whether an aura has anything that can stop it loading.
---@param aura Aura
---@return boolean
function loadOptions.HasAny(aura)
    local load = aura.load
    if load == nil then return false end
    if load.checks ~= nil and #load.checks > 0 then return true end
    for _, option in ipairs(loadOptions.OPTIONS) do
        if enabledSetting(load, option) ~= nil then return true end
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

--- Whether an enabled option's setting passes.
---@param option LoadOption
---@param setting LoadSetting
---@return boolean
local function optionPasses(option, setting)
    if option.passes ~= nil then return option.passes(setting) end
    return optionValue(option) == setting.value
end

--- Whether an aura should load.
---@param aura Aura
---@param ownSource string? The aura's source, for checks that read it.
---@param read ReadCheckValues
---@return boolean
function loadOptions.Passes(aura, ownSource, read)
    local load = aura.load
    if load == nil then return true end
    for _, option in ipairs(loadOptions.OPTIONS) do
        local setting = enabledSetting(load, option)
        if setting ~= nil and not optionPasses(option, setting) then return false end
    end
    for _, check in ipairs(load.checks or {}) do
        if conditions.IsComplete(check) and not conditions.CheckPasses(check, ownSource, read) then
            return false
        end
    end
    return true
end

return loadOptions
