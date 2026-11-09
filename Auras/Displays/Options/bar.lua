-- A Bar aura's options: their defaults and limits, for the display, the
-- store and the editor. Kept apart from the drawing code (Auras/Displays/bar)
-- so reading them doesn't load it.

--- A bar aura's own options.
---@class BarOptions: Aura
---@field backgroundColour integer
---@field borderColour integer
---@field borderThickness integer
---@field invertFill boolean Fill as the value drops, e.g. a cooldown filling as it comes back.
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
    width = 200,
    height = 20,
    backgroundColour = 0x000000B4,
    borderColour = 0x000000B4,
    borderThickness = 2,
    invertFill = false,
    smoothFill = false,
    hideWhenEmpty = false,
    showIcon = false,
    iconSide = "left",
    showTicks = false,
    tickColour = 0x000000B4,
}

barOptions.limits = {
    minWidth = 60, maxWidth = 600,
    minHeight = 8, maxHeight = 60,
    maxBorder = 10,
}

return barOptions
