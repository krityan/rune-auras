-- Registry of the ways an aura can be drawn on screen.
-- Each display module provides:
--   defaults                  option values copied onto a new aura
--   new(parent, aura)         creates the display, returning an object with
--                             Apply(aura), SetValue(curr, max, fillCurr)
--                             (fillCurr: the source's unrounded value, if
--                             any, for smooth drawing),
--                             SetOnMoved(callback) and Destroy()
-- Type-specific editor controls live under UI/Editors (see UI/Windows/aura-editor).
-- Usage: local displayTypes = require("Auras/Registries/display-types")

local displayTypes = {}

local TYPES = {
    { id = "bar", label = "Bar", module = require("Auras/Displays/bar") },
    { id = "icon", label = "Icon", module = require("Auras/Displays/icon") },
    -- Groups are made with the main window's New button, not by switching
    -- an aura's type, so they're left out of the editor's type list.
    { id = "group", label = "Group", module = require("Auras/Displays/group"), selectable = false },
}

local TYPES_BY_ID = {}
for _, displayType in ipairs(TYPES) do
    TYPES_BY_ID[displayType.id] = displayType
end

function displayTypes.List()
    return TYPES
end

-- The types an aura can be switched between in the editor.
function displayTypes.Selectable()
    local list = {}
    for _, displayType in ipairs(TYPES) do
        if displayType.selectable ~= false then list[#list + 1] = displayType end
    end
    return list
end

function displayTypes.Get(typeID)
    return TYPES_BY_ID[typeID]
end

return displayTypes
