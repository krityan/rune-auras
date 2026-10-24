-- What decides whether an aura is loaded (shown at all). An aura's `load`:
--   options  option id -> { enabled, value }: a fixed option from OPTIONS,
--            only tested while enabled
--   checks   checks as a condition's (see Auras/Helpers/conditions), all of
--            which must pass; one with a data type but no source picked yet
--            is skipped, so adding a check doesn't unload the aura
-- Everything enabled must pass (ALL), so "In combat: Yes" and "Weapon style:
-- Melee" load the aura only in combat with a melee weapon. An aura with
-- nothing enabled is always loaded. Groups have it too: a group that isn't
-- loaded takes everything in it with it. The editor's Load tab edits it
-- (see UI/Windows/load-tab).
-- Usage: local loadOptions = require("Auras/Registries/load-options")
--        loadOptions.NewFrame()   -- once a frame, before Passes
--        loadOptions.Passes(aura, ownSource, read)

local conditions = require("Auras/Helpers/conditions")
local playerState = require("GameData/Trackers/player-state")

local loadOptions = {}

-- `choices` are { id, label }; `read()` gives the current value, compared
-- with the chosen one.
loadOptions.OPTIONS = {
    {
        id = "inCombat",
        label = "In combat",
        choices = { { id = true, label = "Yes" }, { id = false, label = "No" } },
        default = true,
        read = playerState.InCombat,
        tooltip = "Load only while in combat, or only while out of it.",
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
        tooltip = "Load only while a weapon of this combat style is equipped.",
    },
}

-- Whether an aura has anything that can stop it loading.
function loadOptions.HasAny(aura)
    local load = aura.load
    if load == nil then return false end
    if load.checks ~= nil and #load.checks > 0 then return true end
    for _, option in ipairs(loadOptions.OPTIONS) do
        local setting = load.options and load.options[option.id]
        if setting ~= nil and setting.enabled then return true end
    end
    return false
end

-- Each option's value this frame, read once however many auras test it.
local frame = 0
local readFrames, values = {}, {}

function loadOptions.NewFrame()
    frame = frame + 1
end

local function optionValue(option)
    if readFrames[option.id] ~= frame then
        readFrames[option.id] = frame
        values[option.id] = option.read()
    end
    return values[option.id]
end

-- Whether the aura should load. read(sourceID) -> curr, max, stacks, for
-- its checks (see conditions.Mask).
function loadOptions.Passes(aura, ownSource, read)
    local load = aura.load
    if load == nil then return true end
    for _, option in ipairs(loadOptions.OPTIONS) do
        local setting = load.options and load.options[option.id]
        if setting ~= nil and setting.enabled and optionValue(option) ~= setting.value then return false end
    end
    for _, check in ipairs(load.checks or {}) do
        if conditions.IsComplete(check) and not conditions.CheckPasses(check, ownSource, read) then
            return false
        end
    end
    return true
end

return loadOptions
