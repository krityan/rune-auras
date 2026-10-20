-- Registry of the ways an aura can be drawn on screen.
-- Each display module provides:
--   defaults                  option values copied onto a new aura
--   new(parent, aura)         creates the display, returning an object with
--                             Apply(aura), SetValue(curr, max, fillCurr)
--                             (fillCurr: the source's unrounded value, if
--                             any, for smooth drawing),
--                             SetOnMoved(callback) and Destroy()
-- Type-specific editor controls live under UI/Editors (see UI/aura-editor).
-- Usage: local displayTypes = require("Auras/display-types")

local displayTypes = {}

local TYPES = {
    { id = "bar", label = "Bar", module = require("Auras/Displays/bar") },
    { id = "icon", label = "Icon", module = require("Auras/Displays/icon") },
}

local TYPES_BY_ID = {}
for _, displayType in ipairs(TYPES) do
    TYPES_BY_ID[displayType.id] = displayType
end

function displayTypes.List()
    return TYPES
end

function displayTypes.Get(typeID)
    return TYPES_BY_ID[typeID]
end

return displayTypes
