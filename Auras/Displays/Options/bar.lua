-- A Bar aura's options: their defaults and limits, for the display, the
-- store and the editor. Kept apart from the drawing code (Auras/Displays/bar)
-- so reading them doesn't load it.

--- A bar aura's options.
---@class BarOptions: Aura
---@field backgroundColour integer
---@field borderColour integer
---@field borderThickness integer
---@field invertFill boolean Fill as the value drops, e.g. a cooldown filling as it comes back.
---@field fillDirection "right"|"left"|"down"|"up" The way the fill grows, as the Icon's linear wipe (see iconOptions.WIPE_DIRECTIONS).
---@field smoothFill boolean Move the fill every frame for sources that extrapolate between server ticks, rather than stepping each 0.6s.
---@field hideWhenEmpty boolean Hide while the value is 0 (an idle channel or buff, a ready cooldown), except while unlocked.
---@field showIcon boolean The source's icon at one end.
---@field iconSide "left"|"right"
---@field showTicks boolean Marks at each 0.6s server tick, for timed sources.
---@field tickColour integer

---@type DisplayOptions
local barOptions = {}

-- Its value texts are text nodes (see auraTexts.Ensure in Auras/Store/aura-texts).
barOptions.usesTextNodes = true

barOptions.defaults = {
    width = 300,
    height = 30,
    backgroundColour = 0x000000B4,
    borderColour = 0x000000B4,
    borderThickness = 2,
    invertFill = false,
    fillDirection = "right",
    smoothFill = false,
    hideWhenEmpty = false,
    showIcon = false,
    iconSide = "left",
    showTicks = false,
    tickColour = 0x000000B4,
}

-- Width and height share a range, so a bar filling up or down can be tall.
barOptions.limits = {
    minWidth = 8, maxWidth = 600,
    minHeight = 8, maxHeight = 600,
    maxBorder = 10,
}

return barOptions
