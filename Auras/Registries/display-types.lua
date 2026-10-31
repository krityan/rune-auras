-- Display types: the ways an aura can be drawn, and the interface every
-- display module provides. Type-specific editor controls live under
-- UI/Editor/Types (see UI/Editor/aura-editor).

local displayTypes = {}

---@alias DisplayID
---| "bar"
---| "icon"
---| "text"
---| "segments"     # Segmented bar
---| "group"        # A point its contents are placed from
---| "dynamicGroup" # A point its auras are laid out from

--- What a display module provides. Some modules add more (see each one).
---@class DisplayModule
---@field defaults table Option values copied onto an aura that lacks them.
---@field new fun(parent: userdata, aura: Aura, groupPoint: GroupPoint?): Display Creates the display.
---@field usesTextNodes boolean? Draws the aura's `texts` (see Auras/Displays/Parts/text-nodes).
---@field sizesItself boolean? Sizes itself, so the aura's width/height are nominal.
---@field limits table? Upper limits for its options, e.g. `maxSegments`.

--- A group's point on screen, handed to its contents. A group makes a new
--- one only when it moves, so contents re-apply exactly when it moved.
---@class GroupPoint
---@field x number
---@field y number

--- A drawn aura, as a display module's `new` returns it.
---@class Display
---@field root userdata The component everything is drawn in.
---@field Apply fun(self: Display, aura: Aura) Restyles and places it from the aura.
---@field SetValue fun(self: Display, curr: number?, max: number?, fillCurr: number?, stacks: number?) Shows the source's values; fillCurr is the unrounded value of a smooth source.
---@field SetOnMoved fun(self: Display, callback: fun(x: number, y: number)) Called with the new offset when it's dragged.
---@field Destroy fun(self: Display)
---@field SetDetails fun(self: Display, name: string?, spriteID: integer?, objectID: integer?, arrow: string?)? The source's name and icon (and the quiver's arrow, for $arrow), for displays that show them.

---@class DisplayType
---@field id DisplayID
---@field label string Shown in the editor.
---@field module DisplayModule
---@field selectable boolean? false: left out of the editor's type list.

---@type DisplayType[]
local TYPES = {
    { id = "bar", label = "Bar", module = require("Auras/Displays/bar") },
    { id = "icon", label = "Icon", module = require("Auras/Displays/icon") },
    { id = "text", label = "Text", module = require("Auras/Displays/text") },
    { id = "segments", label = "Segmented bar", module = require("Auras/Displays/segments") },
    -- Groups are made with the main window's New button, not by switching
    -- an aura's type, so they're left out of the editor's type list.
    { id = "group", label = "Group", module = require("Auras/Displays/group"), selectable = false },
    { id = "dynamicGroup", label = "Dynamic group", module = require("Auras/Displays/dynamic-group"),
        selectable = false },
}

---@type table<DisplayID, DisplayType>
local TYPES_BY_ID = {}
for _, displayType in ipairs(TYPES) do
    TYPES_BY_ID[displayType.id] = displayType
end

--- Every display type.
---@return DisplayType[]
function displayTypes.List()
    return TYPES
end

--- The types an aura can be switched between in the editor.
---@return DisplayType[]
function displayTypes.Selectable()
    local list = {}
    for _, displayType in ipairs(TYPES) do
        if displayType.selectable ~= false then list[#list + 1] = displayType end
    end
    return list
end

--- A display type by id.
---@param typeID DisplayID?
---@return DisplayType? displayType nil if unknown.
function displayTypes.Get(typeID)
    return TYPES_BY_ID[typeID]
end

return displayTypes
