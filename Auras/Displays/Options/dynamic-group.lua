-- A Dynamic group aura's options: their defaults, limits and choices, for
-- the display, the store and the editor. Kept apart from the drawing code
-- (Auras/Displays/dynamic-group) so reading them doesn't load it.

--- A dynamic group's own options.
---@class DynamicGroupOptions: Aura
---@field grow GrowID Which way they grow; or centred on the point.
---@field spacing number Pixels apart.
---@field align "start"|"centre"|"end" How they line up across the grow direction (start: top or left).

---@type DisplayOptions
local dynamicGroupOptions = {}

dynamicGroupOptions.defaults = {
    grow = "right",
    spacing = 4,
    align = "centre",
}

dynamicGroupOptions.ALIGN = {
    { id = "start", label = "Start (top or left)" },
    { id = "centre", label = "Centre" },
    { id = "end", label = "End (bottom or right)" },
}

dynamicGroupOptions.limits = { maxSpacing = 100 }

return dynamicGroupOptions
