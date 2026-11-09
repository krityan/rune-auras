-- The Extra action button data type's sources (extra-action tracker):
-- current is the seconds left of the cooldown, max the full cooldown. "Any"
-- is whichever button is showing, then one source per button from the
-- catalogue, once it has loaded. Every button shares one cooldown.

local extraAction = require("GameData/Trackers/extra-action")
local extraActionCatalogue = require("GameData/Catalogues/extra-action-catalogue")
local cooldowns = require("Auras/Registries/Sources/cooldowns")

local extraActions = {}

-- The generic extra action source's label in the picker, under the Extra action button type.
local ANY_EXTRA_ACTION_LABEL = "Any"
-- The generic extra action source's name before any button has shown.
local EXTRA_ACTION_NAME = "Extra action button"
-- The start of every extra action source's id.
local EXTRA_ACTION_ID_PREFIX = "extra_action_"

--- The "Any" extra action source's details: the name and icon of the button
--- showing, or the last one shown.
---@return string name
---@return integer? spriteID
---@return nil objectID
local function extraActionDetails()
    local button = extraAction.Button()
    if button == nil then return EXTRA_ACTION_NAME, nil, nil end
    return button.name, button.icon, nil
end

--- A read for one button: the cooldown while it's the button showing (or
--- the last one shown), else ready, out of its own cooldown.
---@param button ExtraActionButton
---@return fun(): number?, number?, number?
local function extraActionReader(button)
    return function()
        if extraAction.ButtonID() ~= button.id then return 0, extraAction.CooldownSeconds(button), 0 end
        return extraAction.Read()
    end
end

--- Builds "Any", then a source per button in the catalogue.
---@return DataSource[]
function extraActions.Build()
    local sources = {
        {
            id = EXTRA_ACTION_ID_PREFIX .. "button",
            type = "extraAction",
            label = ANY_EXTRA_ACTION_LABEL,
            name = EXTRA_ACTION_NAME,
            colour = cooldowns.COLOUR,
            smooth = true,
            timed = true,
            state = "cooldown",
            read = extraAction.Read,
            details = extraActionDetails,
        },
    }
    for _, button in ipairs(extraActionCatalogue.List()) do
        sources[#sources + 1] = {
            id = EXTRA_ACTION_ID_PREFIX .. button.key:lower(),
            type = "extraAction",
            label = button.label,
            name = button.name,
            colour = cooldowns.COLOUR,
            icon = button.icon,
            smooth = true,
            timed = true,
            state = "cooldown",
            read = extraActionReader(button),
        }
    end
    return sources
end

return extraActions
